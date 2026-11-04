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

-- Месячные когорты по покупке; календарь сохраняет месяцы без заказов.
-- Окно сравнения и оговорки крайних месяцев описаны в monthly_coverage.md.
CREATE OR REPLACE VIEW mart.delivery_monthly AS
WITH calendar AS (
    SELECT GENERATE_SERIES(
        DATE_TRUNC('month', MIN(purchased_at)),
        DATE_TRUNC('month', MAX(purchased_at)),
        INTERVAL '1 month'
    )::date AS purchase_month
    FROM mart.order_delivery
), monthly AS (
    SELECT
        DATE_TRUNC('month', purchased_at)::date AS purchase_month,
        COUNT(*) AS total_orders,
        COUNT(*) FILTER (WHERE is_delivery_eligible) AS eligible_orders,
        COUNT(*) FILTER (
            WHERE order_status IS DISTINCT FROM 'delivered'
        ) AS not_delivered_orders,
        COUNT(*) FILTER (
            WHERE order_status = 'delivered' AND NOT is_delivery_eligible
        ) AS delivered_excluded,
        COUNT(*) FILTER (WHERE is_late) AS late_orders,
        COUNT(*) FILTER (
            WHERE order_status IN ('created', 'approved', 'invoiced', 'processing', 'shipped')
        ) AS open_status_orders,
        COUNT(*) FILTER (
            WHERE order_status IN ('canceled', 'unavailable')
        ) AS canceled_or_unavailable_orders,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY delivery_days
        ) FILTER (WHERE is_delivery_eligible) AS median_delivery_days,
        PERCENTILE_CONT(0.9) WITHIN GROUP (
            ORDER BY delivery_days
        ) FILTER (WHERE is_delivery_eligible) AS p90_delivery_days,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY delay_days
        ) FILTER (WHERE is_delivery_eligible AND is_late) AS median_delay_late_days
    FROM mart.order_delivery
    GROUP BY DATE_TRUNC('month', purchased_at)::date
)
SELECT
    c.purchase_month,
    COALESCE(m.total_orders, 0) AS total_orders,
    COALESCE(m.eligible_orders, 0) AS eligible_orders,
    COALESCE(m.not_delivered_orders, 0) AS not_delivered_orders,
    COALESCE(m.delivered_excluded, 0) AS delivered_excluded,
    COALESCE(m.late_orders, 0) AS late_orders,
    ROUND(
        100.0 * m.late_orders / NULLIF(m.eligible_orders, 0), 2
    ) AS late_rate_pct,
    (
        c.purchase_month BETWEEN DATE '2017-01-01' AND DATE '2018-07-01'
        AND COALESCE(m.eligible_orders, 0) > 0
    ) AS is_comparison_month,
    CASE
        WHEN COALESCE(m.total_orders, 0) = 0 THEN 'Нет заказов'
        WHEN COALESCE(m.eligible_orders, 0) = 0 THEN 'Нет пригодных заказов'
        WHEN c.purchase_month < DATE '2017-01-01' THEN 'Начальный фрагмент данных'
        WHEN c.purchase_month >= DATE '2018-08-01' THEN 'Край наблюдения: возможна неполнота'
        ELSE NULL
    END AS comparison_note,
    m.median_delivery_days,
    m.p90_delivery_days,
    m.median_delay_late_days,
    COALESCE(m.open_status_orders, 0) AS open_status_orders,
    COALESCE(m.canceled_or_unavailable_orders, 0) AS canceled_or_unavailable_orders
FROM calendar AS c
LEFT JOIN monthly AS m ON m.purchase_month = c.purchase_month;

SELECT purchase_month, total_orders, eligible_orders, late_orders, late_rate_pct
FROM mart.delivery_monthly
ORDER BY purchase_month;

SELECT purchase_month, eligible_orders, is_comparison_month, comparison_note
FROM mart.delivery_monthly
WHERE NOT is_comparison_month
ORDER BY purchase_month;

-- Одна строка на пару заказ–продавец, все заказы с позициями.
-- Несколько товаров одного продавца внутри заказа сворачиваются.
CREATE OR REPLACE VIEW mart.order_seller AS
SELECT
    i.order_id,
    i.seller_id,
    s.seller_state,
    COUNT(*) AS seller_item_count
FROM staging.order_items AS i
LEFT JOIN raw.sellers AS s
    ON s.seller_id = i.seller_id
GROUP BY i.order_id, i.seller_id, s.seller_state;

SELECT
    COUNT(*) AS order_seller_pairs,
    COUNT(DISTINCT (order_id, seller_id)) AS unique_pairs,
    COUNT(DISTINCT order_id) AS unique_orders,
    SUM(seller_item_count) AS total_items
FROM mart.order_seller;
