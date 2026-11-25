-- Исторический ориентир: первый полный календарный год наблюдений, 2017.
-- Выбран целый год, а не лучший месяц. Это не оценка причинного эффекта.
-- Для SP и RJ переносим собственную долю 2017 года на весь исторический объём
-- соответствующего штата, сохраняя вес штатов; остальные штаты не меняются.
-- Состав/сезонность внутри штатов не стандартизированы, периоды пересекаются.
WITH delivery AS MATERIALIZED (
    SELECT customer_state, purchased_at, is_late
    FROM mart.order_delivery
    WHERE is_delivery_eligible
), totals AS (
    SELECT COUNT(*) AS all_orders,
           COUNT(*) FILTER (WHERE is_late) AS all_late
    FROM delivery
), by_state AS (
    SELECT
        customer_state,
        COUNT(*) AS baseline_orders,
        COUNT(*) FILTER (WHERE is_late) AS baseline_late,
        COUNT(*) FILTER (
            WHERE purchased_at >= TIMESTAMP '2017-01-01'
              AND purchased_at < TIMESTAMP '2018-01-01'
        ) AS reference_orders,
        COUNT(*) FILTER (
            WHERE purchased_at >= TIMESTAMP '2017-01-01'
              AND purchased_at < TIMESTAMP '2018-01-01' AND is_late
        ) AS reference_late
    FROM delivery
    WHERE customer_state IN ('SP', 'RJ')
    GROUP BY customer_state
), projected AS (
    SELECT *, baseline_orders::numeric * reference_late
        / NULLIF(reference_orders, 0) AS target_late_unrounded
    FROM by_state
), rolled AS (
    SELECT
        GROUPING(customer_state) AS is_total,
        COALESCE(customer_state, 'SP + RJ') AS segment,
        SUM(baseline_orders) AS baseline_orders,
        SUM(baseline_late) AS baseline_late,
        SUM(reference_orders) AS reference_orders,
        SUM(reference_late) AS reference_late,
        SUM(target_late_unrounded) AS target_late_unrounded
    FROM projected
    GROUP BY ROLLUP(customer_state)
)
SELECT
    r.segment, r.baseline_orders, r.baseline_late,
    ROUND(100.0 * r.baseline_late / NULLIF(r.baseline_orders, 0), 2)
        AS baseline_rate_pct,
    r.reference_orders AS orders_2017,
    r.reference_late AS late_2017,
    ROUND(100.0 * r.reference_late / NULLIF(r.reference_orders, 0), 2)
        AS observed_2017_rate_pct,
    ROUND(100.0 * r.target_late_unrounded / NULLIF(r.baseline_orders, 0), 2)
        AS weighted_target_rate_pct,
    ROUND(r.target_late_unrounded, 0) AS scenario_target_late,
    r.baseline_late - ROUND(r.target_late_unrounded, 0) AS avoided_late_orders,
    CASE WHEN r.is_total = 1 THEN
        ROUND(100.0 * (t.all_late - r.baseline_late
            + ROUND(r.target_late_unrounded, 0)) / NULLIF(t.all_orders, 0), 2)
    END AS overall_scenario_rate_pct,
    CASE WHEN r.is_total = 1 THEN
        ROUND(100.0 * (r.baseline_late - ROUND(r.target_late_unrounded, 0))
            / NULLIF(t.all_orders, 0), 2)
    END AS overall_improvement_pp
FROM rolled r
CROSS JOIN totals t
ORDER BY r.is_total, r.segment;
