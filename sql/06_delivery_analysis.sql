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
