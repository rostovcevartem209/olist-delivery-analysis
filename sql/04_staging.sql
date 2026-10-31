-- Выполнять в основной базе olist_delivery после 03_quality_checks.sql.
-- Первый шаг слоя staging: типизированные даты без удаления заказов.
-- Скрипт будет дополняться признаками качества и другими сущностями.
-- Предусловие: заполненные исходные даты преобразуются в timestamp.
-- Исходным меткам не назначается часовой пояс.
CREATE SCHEMA IF NOT EXISTS staging;

CREATE OR REPLACE VIEW staging.orders AS
SELECT
    order_id,
    customer_id,
    order_status,
    NULLIF(TRIM(order_purchase_timestamp), '')::timestamp AS purchased_at,
    NULLIF(TRIM(order_approved_at), '')::timestamp AS approved_at,
    NULLIF(TRIM(order_delivered_carrier_date), '')::timestamp AS carrier_at,
    NULLIF(TRIM(order_delivered_customer_date), '')::timestamp AS delivered_at,
    NULLIF(TRIM(order_estimated_delivery_date), '')::timestamp AS estimated_at
FROM raw.orders;

-- Контроль: ожидается 99 441 строка, без фильтра статусов и качества.
SELECT COUNT(*) AS staging_order_count
FROM staging.orders;

-- Допуск к основным метрикам доставки и отдельный флаг этапов.
-- Проблема промежуточной метки сама по себе не отменяет пригодность
-- покупки, фактической и обещанной доставки; нужна проверка чувствительности.
CREATE OR REPLACE VIEW staging.order_quality AS
SELECT
    o.*,
    COALESCE(
        order_status = 'delivered'
        AND purchased_at IS NOT NULL
        AND delivered_at IS NOT NULL
        AND estimated_at IS NOT NULL
        AND isfinite(purchased_at)
        AND isfinite(delivered_at)
        AND isfinite(estimated_at)
        AND delivered_at >= purchased_at
        AND estimated_at::date >= purchased_at::date,
        FALSE
    ) AS is_delivery_eligible,
    COALESCE(
        approved_at < purchased_at
        OR carrier_at < purchased_at
        OR carrier_at < approved_at
        OR delivered_at < carrier_at
        OR approved_at > delivered_at
        OR delivered_at < purchased_at,
        FALSE
    ) AS has_stage_chronology_issue
FROM staging.orders AS o;

SELECT
    COUNT(*) AS total_orders,
    COUNT(*) FILTER (WHERE is_delivery_eligible) AS eligible_orders,
    COUNT(*) FILTER (
        WHERE order_status = 'delivered' AND has_stage_chronology_issue
    ) AS delivered_with_stage_issues
FROM staging.order_quality;

-- Одна основная причина исключения: при совпадении причин действует
-- порядок CASE. Остальные сведения остаются в orders/order_quality.
CREATE OR REPLACE VIEW staging.order_exclusions AS
SELECT
    order_id,
    CASE
        WHEN order_status IS DISTINCT FROM 'delivered'
            THEN 'status_not_delivered'
        WHEN purchased_at IS NULL
          OR delivered_at IS NULL
          OR estimated_at IS NULL
            THEN 'missing_required_dates'
        WHEN NOT isfinite(purchased_at)
          OR NOT isfinite(delivered_at)
          OR NOT isfinite(estimated_at)
            THEN 'nonfinite_required_dates'
        WHEN delivered_at < purchased_at
            THEN 'delivery_before_purchase'
        WHEN estimated_at::date < purchased_at::date
            THEN 'estimate_before_purchase'
        ELSE 'other_invalid_delivery_data'
    END AS exclusion_reason
FROM staging.order_quality
WHERE NOT is_delivery_eligible;

SELECT exclusion_reason, COUNT(*) AS excluded_orders
FROM staging.order_exclusions
GROUP BY exclusion_reason
ORDER BY excluded_orders DESC;

-- Один отзыв на заказ: правило сортировки проверено в 03_quality_checks.
-- Предусловия: оценки 1–5, даты заполнены и преобразуемы,
-- совпадений всех полей сортировки внутри заказа нет.
CREATE OR REPLACE VIEW staging.selected_reviews AS
WITH ranked_reviews AS (
    SELECT
        review_id,
        order_id,
        review_score::smallint AS review_score,
        review_creation_date::timestamp AS created_at,
        review_answer_timestamp::timestamp AS answered_at,
        COUNT(*) OVER (PARTITION BY order_id) AS review_count,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY review_answer_timestamp::timestamp DESC,
                     review_creation_date::timestamp DESC,
                     review_id COLLATE "C" DESC
        ) AS rn
    FROM raw.order_reviews
)
SELECT review_id, order_id, review_score, created_at, answered_at, review_count
FROM ranked_reviews
WHERE rn = 1;

SELECT
    COUNT(*) AS selected_reviews,
    COUNT(DISTINCT order_id) AS unique_orders,
    COUNT(*) FILTER (WHERE review_count > 1) AS orders_with_multiple_reviews
FROM staging.selected_reviews;

-- Сохраняем все заказы, включая заказы без отзывов.
CREATE OR REPLACE VIEW staging.order_review_quality AS
SELECT
    o.*,
    r.review_id,
    r.review_score,
    r.created_at AS review_created_at,
    r.answered_at AS review_answered_at,
    COALESCE(r.review_count, 0) AS review_count,
    r.order_id IS NOT NULL AS has_review,
    COALESCE(
        o.is_delivery_eligible
        AND r.review_score BETWEEN 1 AND 5
        AND isfinite(r.created_at)
        AND isfinite(r.answered_at)
        AND r.answered_at >= r.created_at
        AND r.answered_at >= o.delivered_at,
        FALSE
    ) AS is_review_eligible
FROM staging.order_quality AS o
LEFT JOIN staging.selected_reviews AS r
    ON r.order_id = o.order_id;

SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT order_id) AS unique_orders,
    COUNT(*) FILTER (WHERE is_delivery_eligible) AS delivery_eligible,
    COUNT(*) FILTER (WHERE is_review_eligible) AS review_eligible
FROM staging.order_review_quality;

-- Минимальный справочник товаров для анализа категорий.
-- Исходные характеристики товара остаются доступны в raw.products.
CREATE OR REPLACE VIEW staging.products AS
WITH categories AS (
    SELECT
        p.product_id,
        NULLIF(TRIM(p.product_category_name), '') AS category_code,
        NULLIF(TRIM(t.product_category_name_english), '') AS category_english
    FROM raw.products AS p
    LEFT JOIN raw.category_translation AS t
        ON t.product_category_name = p.product_category_name
)
SELECT
    product_id,
    category_code,
    COALESCE(category_english, category_code, 'Неизвестно') AS category_name,
    category_code IS NULL AS is_category_unknown,
    category_code IS NOT NULL
        AND category_english IS NULL AS is_translation_missing
FROM categories;

SELECT
    COUNT(*) AS total_products,
    COUNT(DISTINCT product_id) AS unique_products,
    COUNT(*) FILTER (WHERE is_category_unknown) AS unknown_category,
    COUNT(*) FILTER (WHERE is_translation_missing) AS missing_translation
FROM staging.products;

-- Типизированные позиции, без фильтрации и соединений.
-- Предусловия: проверки ключей и типов в 03_quality_checks.sql.
CREATE OR REPLACE VIEW staging.order_items AS
SELECT
    order_id,
    order_item_id::integer AS order_item_id,
    product_id,
    seller_id,
    shipping_limit_date::timestamp AS shipping_limit_at,
    price::numeric AS price,
    freight_value::numeric AS freight_value
FROM raw.order_items;

SELECT
    COUNT(*) AS total_items,
    COUNT(DISTINCT order_id) AS unique_orders,
    COUNT(DISTINCT (order_id, order_item_id)) AS unique_order_items
FROM staging.order_items;

-- Одна строка на заказ, представленный в позициях.
-- Категории считаются по исходному коду, а не по отображаемому переводу.
-- NULL не входит в COUNT(DISTINCT); неизвестные категории считаются отдельно.
CREATE OR REPLACE VIEW staging.order_item_summary AS
SELECT
    i.order_id,
    COUNT(*) AS item_count,
    COUNT(DISTINCT i.seller_id) AS seller_count,
    COUNT(DISTINCT p.category_code) AS known_category_count,
    COUNT(*) FILTER (
        WHERE p.is_category_unknown
    ) AS unknown_category_item_count,
    SUM(i.price) AS total_price,
    SUM(i.freight_value) AS total_freight
FROM staging.order_items AS i
LEFT JOIN staging.products AS p
    ON p.product_id = i.product_id
GROUP BY i.order_id;

SELECT
    COUNT(*) AS summary_rows,
    COUNT(DISTINCT order_id) AS unique_orders,
    SUM(item_count) AS total_items
FROM staging.order_item_summary;
