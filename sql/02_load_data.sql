-- Run with psql from the repository root, not in pgAdmin Query Tool.
-- Tables must already exist and be empty. No data is deleted.
\set ON_ERROR_STOP on
BEGIN;

LOCK TABLE raw.orders, raw.customers, raw.order_items, raw.sellers,
           raw.products, raw.category_translation, raw.order_reviews
IN EXCLUSIVE MODE;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM raw.orders)
       OR EXISTS (SELECT 1 FROM raw.customers)
       OR EXISTS (SELECT 1 FROM raw.order_items)
       OR EXISTS (SELECT 1 FROM raw.sellers)
       OR EXISTS (SELECT 1 FROM raw.products)
       OR EXISTS (SELECT 1 FROM raw.category_translation)
       OR EXISTS (SELECT 1 FROM raw.order_reviews) THEN
        RAISE EXCEPTION 'Import stopped: raw tables must be empty. Use a new test database; existing data was not changed.';
    END IF;
END
$$;

\copy raw.orders (order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at, order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date) FROM 'data/raw/olist_orders_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy raw.customers (customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state) FROM 'data/raw/olist_customers_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy raw.order_items (order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value) FROM 'data/raw/olist_order_items_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy raw.sellers (seller_id, seller_zip_code_prefix, seller_city, seller_state) FROM 'data/raw/olist_sellers_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy raw.products (product_id, product_category_name, product_name_lenght, product_description_lenght, product_photos_qty, product_weight_g, product_length_cm, product_height_cm, product_width_cm) FROM 'data/raw/olist_products_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy raw.category_translation (product_category_name, product_category_name_english) FROM 'data/raw/product_category_name_translation.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy raw.order_reviews (review_id, order_id, review_score, review_comment_title, review_comment_message, review_creation_date, review_answer_timestamp) FROM 'data/raw/olist_order_reviews_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

COMMIT;

SELECT 'orders' AS table_name, COUNT(*) AS row_count FROM raw.orders
UNION ALL SELECT 'customers', COUNT(*) FROM raw.customers
UNION ALL SELECT 'order_items', COUNT(*) FROM raw.order_items
UNION ALL SELECT 'sellers', COUNT(*) FROM raw.sellers
UNION ALL SELECT 'products', COUNT(*) FROM raw.products
UNION ALL SELECT 'category_translation', COUNT(*) FROM raw.category_translation
UNION ALL SELECT 'order_reviews', COUNT(*) FROM raw.order_reviews
ORDER BY table_name;
