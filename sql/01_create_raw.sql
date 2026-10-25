-- Выполнять в базе olist_delivery.
-- Скрипт дополняется по мере создания исходных таблиц.
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS mart;

-- Порядок столбцов соответствует olist_orders_dataset.csv.
-- В raw сохраняем исходные значения как текст.
-- Типизация дат и проверки ключей будут выполнены отдельно.
-- IF NOT EXISTS не проверяет структуру уже существующей таблицы.
CREATE TABLE IF NOT EXISTS raw.orders (
    order_id TEXT,
    customer_id TEXT,
    order_status TEXT,
    order_purchase_timestamp TEXT,
    order_approved_at TEXT,
    order_delivered_carrier_date TEXT,
    order_delivered_customer_date TEXT,
    order_estimated_delivery_date TEXT
);

-- Покупатели: связь с заказами по customer_id.
-- customer_unique_id позволяет распознавать повторных покупателей.
-- Почтовый префикс сохраняем как текст, чтобы не терять ведущие нули.
CREATE TABLE IF NOT EXISTS raw.customers (
    customer_id TEXT,
    customer_unique_id TEXT,
    customer_zip_code_prefix TEXT,
    customer_city TEXT,
    customer_state TEXT
);

-- Позиции заказа: ожидаемый ключ — пара (order_id, order_item_id).
-- order_item_id — номер позиции внутри заказа, не идентификатор товара.
CREATE TABLE IF NOT EXISTS raw.order_items (
    order_id TEXT,
    order_item_id TEXT,
    product_id TEXT,
    seller_id TEXT,
    shipping_limit_date TEXT,
    price TEXT,
    freight_value TEXT
);

-- Продавцы: связь с позициями заказа по seller_id.
CREATE TABLE IF NOT EXISTS raw.sellers (
    seller_id TEXT,
    seller_zip_code_prefix TEXT,
    seller_city TEXT,
    seller_state TEXT
);

-- Товары: порядок и написание столбцов сохранены как в CSV.
-- Опечатка lenght в двух исходных названиях намеренно сохранена.
CREATE TABLE IF NOT EXISTS raw.products (
    product_id TEXT,
    product_category_name TEXT,
    product_name_lenght TEXT,
    product_description_lenght TEXT,
    product_photos_qty TEXT,
    product_weight_g TEXT,
    product_length_cm TEXT,
    product_height_cm TEXT,
    product_width_cm TEXT
);

-- Перевод категорий: связь с products по product_category_name.
CREATE TABLE IF NOT EXISTS raw.category_translation (
    product_category_name TEXT,
    product_category_name_english TEXT
);

-- Отзывы: review_id и order_id не считаем уникальными без проверки.
CREATE TABLE IF NOT EXISTS raw.order_reviews (
    review_id TEXT,
    order_id TEXT,
    review_score TEXT,
    review_comment_title TEXT,
    review_comment_message TEXT,
    review_creation_date TEXT,
    review_answer_timestamp TEXT
);
