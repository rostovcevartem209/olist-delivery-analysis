-- Условные сценарии, а не прогноз достигнутого эффекта.
-- После 01–05. Вся пригодная историческая выборка, без месячного фильтра.
-- Снижается число просрочек в SP/RJ; знаменатель и остальные штаты неизменны.
-- Заказы условно становятся своевременными, а не исключаются из анализа.
WITH baseline AS MATERIALIZED (
    SELECT
        COUNT(*) AS eligible_orders,
        COUNT(*) FILTER (WHERE is_late) AS late_orders,
        COUNT(*) FILTER (WHERE customer_state IN ('SP', 'RJ')) AS target_orders,
        COUNT(*) FILTER (
            WHERE customer_state IN ('SP', 'RJ') AND is_late
        ) AS target_late_orders
    FROM mart.order_delivery
    WHERE is_delivery_eligible
), scenarios(reduction_fraction) AS (
    VALUES (0.05::numeric), (0.10::numeric), (0.20::numeric)
), calculated AS (
    SELECT
        b.*,
        s.reduction_fraction,
        ROUND(b.target_late_orders * s.reduction_fraction, 0)::bigint
            AS avoided_late_orders
    FROM baseline b
    CROSS JOIN scenarios s
)
SELECT
    eligible_orders,
    late_orders AS baseline_late_orders,
    target_orders,
    target_late_orders,
    ROUND(100.0 * target_late_orders / NULLIF(late_orders, 0), 2)
        AS target_share_of_late_pct,
    ROUND(100.0 * reduction_fraction, 0) AS target_reduction_pct,
    avoided_late_orders,
    late_orders - avoided_late_orders AS scenario_late_orders,
    ROUND(100.0 * late_orders / NULLIF(eligible_orders, 0), 2)
        AS baseline_late_rate_pct,
    ROUND(100.0 * (late_orders - avoided_late_orders)
        / NULLIF(eligible_orders, 0), 2) AS scenario_late_rate_pct,
    ROUND(100.0 * avoided_late_orders / NULLIF(eligible_orders, 0), 2)
        AS improvement_pp
FROM calculated
ORDER BY reduction_fraction;
