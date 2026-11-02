-- Основные показатели на текущей пригодной выборке доставки.
-- Перед запуском выполнить и проверить 01–05.
SELECT
    COUNT(*) FILTER (WHERE is_delivery_eligible) AS eligible_orders,
    COUNT(*) FILTER (WHERE is_late) AS late_orders,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late)
        / NULLIF(COUNT(*) FILTER (WHERE is_delivery_eligible), 0),
        2
    ) AS late_rate_pct
FROM mart.order_delivery;

-- Время доставки — по всем пригодным заказам;
-- медианная задержка — только среди просроченных.
SELECT
    COUNT(*) AS eligible_orders,
    COUNT(*) FILTER (WHERE is_late) AS late_orders,
    PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY delivery_days
    ) AS median_delivery_days,
    PERCENTILE_CONT(0.9) WITHIN GROUP (
        ORDER BY delivery_days
    ) AS p90_delivery_days,
    PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY delay_days
    ) FILTER (WHERE is_late) AS median_delay_late_days
FROM mart.order_delivery
WHERE is_delivery_eligible;

-- Группы задержки, зафиксированные до анализа отзывов.
SELECT
    delay_group,
    COUNT(*) AS order_count,
    ROUND(
        100.0 * COUNT(*) / SUM(COUNT(*)) OVER (),
        2
    ) AS share_pct
FROM mart.order_delivery
WHERE is_delivery_eligible
GROUP BY delay_group
ORDER BY MIN(delay_days);

-- Чувствительность к исключению заказов с нарушениями этапов.
-- Строки двух выборок пересекаются: складывать их количества нельзя.
WITH comparison AS (
    SELECT 'Все пригодные' AS sample_name,
           is_late, delivery_days, delay_days
    FROM mart.order_delivery
    WHERE is_delivery_eligible

    UNION ALL

    SELECT 'Без нарушений этапов',
           is_late, delivery_days, delay_days
    FROM mart.order_delivery
    WHERE is_delivery_eligible
      AND NOT has_stage_chronology_issue
)
SELECT
    sample_name,
    COUNT(*) AS order_count,
    COUNT(*) FILTER (WHERE is_late) AS late_orders,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late)
        / NULLIF(COUNT(*), 0), 2
    ) AS late_rate_pct,
    PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY delivery_days
    ) AS median_delivery_days,
    PERCENTILE_CONT(0.9) WITHIN GROUP (
        ORDER BY delivery_days
    ) AS p90_delivery_days,
    PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY delay_days
    ) FILTER (WHERE is_late) AS median_delay_late_days
FROM comparison
GROUP BY sample_name
ORDER BY sample_name;

-- Первый просмотр месячных когорт: объёмы и исключения, все заказы.
-- Не-delivered включает отменённые и unavailable, а не только ожидающие.
-- Группировка пока показывает только месяцы с покупками.
SELECT
    DATE_TRUNC('month', purchased_at)::date AS purchase_month,
    COUNT(*) AS total_orders,
    COUNT(*) FILTER (WHERE is_delivery_eligible) AS eligible_orders,
    COUNT(*) FILTER (
        WHERE order_status IS DISTINCT FROM 'delivered'
    ) AS not_delivered_orders,
    COUNT(*) FILTER (
        WHERE order_status = 'delivered' AND NOT is_delivery_eligible
    ) AS delivered_excluded
FROM mart.order_delivery
GROUP BY DATE_TRUNC('month', purchased_at)::date
ORDER BY purchase_month;

-- Состав последних месяцев: статус и границы событий покупки/обещания.
SELECT
    DATE_TRUNC('month', purchased_at)::date AS purchase_month,
    order_status,
    COUNT(*) AS order_count,
    MIN(purchased_at)::date AS first_purchase_date,
    MAX(purchased_at)::date AS last_purchase_date,
    MAX(estimated_at)::date AS last_estimated_date
FROM mart.order_delivery
WHERE purchased_at >= DATE '2018-08-01'
GROUP BY DATE_TRUNC('month', purchased_at)::date, order_status
ORDER BY purchase_month, order_count DESC;

-- Длительности по месячным когортам в зафиксированном окне сравнения.
SELECT
    purchase_month,
    eligible_orders,
    late_rate_pct,
    median_delivery_days,
    p90_delivery_days,
    median_delay_late_days
FROM mart.delivery_monthly
WHERE is_comparison_month
ORDER BY purchase_month;

-- Проверка полноты классификации всех заказов в каждой месячной когорте.
SELECT
    COUNT(*) AS month_count,
    SUM(open_status_orders) AS open_status_orders,
    SUM(canceled_or_unavailable_orders) AS canceled_or_unavailable_orders,
    SUM(delivered_excluded) AS delivered_excluded,
    COUNT(*) FILTER (
        WHERE total_orders <> eligible_orders + open_status_orders
                              + canceled_or_unavailable_orders + delivered_excluded
    ) AS months_with_count_mismatch
FROM mart.delivery_monthly;
