-- Выполнять после 04_staging.sql в базе olist_delivery.
-- Основная витрина: одна строка на заказ, метрики по календарным дням.
-- Дополнительные витрины будут добавлены далее.
CREATE SCHEMA IF NOT EXISTS mart;

CREATE OR REPLACE VIEW mart.order_delivery AS
WITH base AS (
SELECT
    o.*,
    c.customer_state,
    s.order_id IS NOT NULL AS has_item_details,
    COALESCE(s.item_count, 0) AS item_count,
    COALESCE(s.seller_count, 0) AS seller_count,
    COALESCE(s.known_category_count, 0) AS known_category_count,
    COALESCE(s.unknown_category_item_count, 0) AS unknown_category_item_count,
    s.total_price,
    s.total_freight,
    e.exclusion_reason
FROM staging.order_review_quality AS o
LEFT JOIN raw.customers AS c
    ON c.customer_id = o.customer_id
LEFT JOIN staging.order_item_summary AS s
    ON s.order_id = o.order_id
LEFT JOIN staging.order_exclusions AS e
    ON e.order_id = o.order_id
), metrics AS (
    SELECT
        base.*,
        CASE WHEN is_delivery_eligible
            THEN delivered_at::date - purchased_at::date
        END AS delivery_days,
        CASE WHEN is_delivery_eligible
            THEN delivered_at::date - estimated_at::date
        END AS deviation_days,
        CASE WHEN is_delivery_eligible
            THEN GREATEST(delivered_at::date - estimated_at::date, 0)
        END AS delay_days,
        CASE WHEN is_delivery_eligible
            THEN delivered_at::date > estimated_at::date
        END AS is_late
    FROM base
)
SELECT
    metrics.*,
    CASE
        WHEN NOT is_delivery_eligible THEN NULL
        WHEN deviation_days <= 0 THEN 'Вовремя или раньше'
        WHEN deviation_days <= 3 THEN '1–3 дня'
        WHEN deviation_days <= 7 THEN '4–7 дней'
        WHEN deviation_days <= 14 THEN '8–14 дней'
        ELSE '15 дней и более'
    END AS delay_group
FROM metrics;

SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT order_id) AS unique_orders,
    COUNT(*) FILTER (WHERE is_delivery_eligible) AS delivery_eligible,
    COUNT(*) FILTER (WHERE is_review_eligible) AS review_eligible
FROM mart.order_delivery;

-- Проверяем разбиение выборки и отсутствие расчётов для исключённых.
SELECT
    COUNT(*) FILTER (WHERE is_delivery_eligible) AS eligible_orders,
    COUNT(*) FILTER (WHERE is_late = FALSE) AS on_time_orders,
    COUNT(*) FILTER (WHERE is_late = TRUE) AS late_orders,
    COUNT(*) FILTER (
        WHERE is_delivery_eligible AND (
            delivery_days IS NULL OR deviation_days IS NULL
            OR delay_days IS NULL OR is_late IS NULL OR delay_group IS NULL
        )
    ) AS eligible_without_metrics,
    COUNT(*) FILTER (
        WHERE NOT is_delivery_eligible AND (
            delivery_days IS NOT NULL OR deviation_days IS NOT NULL
            OR delay_days IS NOT NULL OR is_late IS NOT NULL OR delay_group IS NOT NULL
        )
    ) AS excluded_with_metrics
FROM mart.order_delivery;
