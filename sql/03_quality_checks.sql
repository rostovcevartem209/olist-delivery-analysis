-- Выполнять в базе olist_delivery.
-- Проверка количества строк и идентификаторов заказов.
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT order_id) AS unique_orders,
    COUNT(*) FILTER (
        WHERE order_id IS NULL OR TRIM(order_id) = ''
    ) AS missing_order_ids
FROM raw.orders;

-- Проверка случайной загрузки заголовка CSV как строки данных.
SELECT *
FROM raw.orders
WHERE order_id = 'order_id';

-- Покупатели: сверка с CSV и проверка ключа связи с заказами.
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT customer_id) AS unique_customer_ids,
    COUNT(*) FILTER (
        WHERE customer_id IS NULL OR TRIM(customer_id) = ''
    ) AS missing_customer_ids
FROM raw.customers;

-- Проверяем наличие покупателя для каждого заказа.
SELECT COUNT(*) AS orders_without_customer
FROM raw.orders AS o
WHERE NOT EXISTS (
    SELECT 1
    FROM raw.customers AS c
    WHERE c.customer_id = o.customer_id
);

-- Позиции: order_id может повторяться, проверяем составной ключ.
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT order_id) AS unique_orders,
    COUNT(DISTINCT (order_id, order_item_id)) AS unique_order_items,
    COUNT(*) FILTER (
        WHERE order_id IS NULL OR TRIM(order_id) = ''
           OR order_item_id IS NULL OR TRIM(order_item_id) = ''
    ) AS missing_keys
FROM raw.order_items;

-- Позиции без соответствующего заказа.
SELECT COUNT(*) AS items_without_order
FROM raw.order_items AS i
WHERE NOT EXISTS (
    SELECT 1 FROM raw.orders AS o
    WHERE o.order_id = i.order_id
);

-- Заказы без позиций: распределение по статусам.
SELECT o.order_status, COUNT(*) AS orders_without_items
FROM raw.orders AS o
WHERE NOT EXISTS (
    SELECT 1 FROM raw.order_items AS i
    WHERE i.order_id = o.order_id
)
GROUP BY o.order_status
ORDER BY orders_without_items DESC;

-- Исследование отправленных заказов без позиций.
SELECT o.order_id, o.order_status, o.order_purchase_timestamp,
       o.order_approved_at, o.order_delivered_carrier_date,
       o.order_delivered_customer_date, o.order_estimated_delivery_date
FROM raw.orders AS o
WHERE o.order_status = 'shipped'
  AND NOT EXISTS (
      SELECT 1 FROM raw.order_items AS i
      WHERE i.order_id = o.order_id
  );

-- Проверка импорта продавцов.
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT seller_id) AS unique_sellers,
    COUNT(*) FILTER (
        WHERE seller_id IS NULL OR TRIM(seller_id) = ''
    ) AS missing_seller_ids
FROM raw.sellers;

-- Проверка связи позиций с продавцами.
SELECT COUNT(*) AS items_without_seller
FROM raw.order_items AS i
WHERE NOT EXISTS (
    SELECT 1 FROM raw.sellers AS s
    WHERE s.seller_id = i.seller_id
);

-- Проверка импорта товаров.
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT product_id) AS unique_products,
    COUNT(*) FILTER (
        WHERE product_id IS NULL OR TRIM(product_id) = ''
    ) AS missing_product_ids
FROM raw.products;

-- Проверка связи позиций с товарами.
SELECT COUNT(*) AS items_without_product
FROM raw.order_items AS i
WHERE NOT EXISTS (
    SELECT 1 FROM raw.products AS p
    WHERE p.product_id = i.product_id
);

-- Проверка импорта перевода категорий.
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT product_category_name) AS unique_categories,
    COUNT(*) FILTER (
        WHERE product_category_name IS NULL
           OR TRIM(product_category_name) = ''
    ) AS missing_category_names,
    COUNT(*) FILTER (
        WHERE product_category_name_english IS NULL
           OR TRIM(product_category_name_english) = ''
    ) AS missing_translations
FROM raw.category_translation;

-- Отсутствующая категория и отсутствующий перевод — разные случаи.
SELECT COUNT(*) AS products_without_category
FROM raw.products
WHERE product_category_name IS NULL
   OR TRIM(product_category_name) = '';

SELECT p.product_category_name, COUNT(*) AS product_count
FROM raw.products AS p
WHERE p.product_category_name IS NOT NULL
  AND TRIM(p.product_category_name) <> ''
  AND NOT EXISTS (
      SELECT 1 FROM raw.category_translation AS t
      WHERE t.product_category_name = p.product_category_name
  )
GROUP BY p.product_category_name
ORDER BY product_count DESC, p.product_category_name;

-- Проверка импорта отзывов. Повторение ID ещё не доказывает полный дубль.
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT review_id) AS unique_review_ids,
    COUNT(DISTINCT order_id) AS unique_orders,
    COUNT(*) FILTER (
        WHERE review_id IS NULL OR TRIM(review_id) = ''
           OR order_id IS NULL OR TRIM(order_id) = ''
    ) AS missing_ids
FROM raw.order_reviews;

-- Отзывы без соответствующего заказа.
SELECT COUNT(*) AS reviews_without_order
FROM raw.order_reviews AS r
WHERE NOT EXISTS (
    SELECT 1 FROM raw.orders AS o
    WHERE o.order_id = r.order_id
);

-- Распределение заказов по числу записей отзывов.
-- Заказы без отзывов в этот запрос не входят.
SELECT review_count, COUNT(*) AS order_count
FROM (
    SELECT order_id, COUNT(*) AS review_count
    FROM raw.order_reviews
    GROUP BY order_id
) AS reviews_per_order
GROUP BY review_count
ORDER BY review_count;

-- Полные дубли: совпадение всех семи исходных полей отзыва.
SELECT
    COUNT(*) AS duplicate_groups,
    COALESCE(SUM(row_count - 1), 0) AS extra_duplicate_rows
FROM (
    SELECT COUNT(*) AS row_count
    FROM raw.order_reviews
    GROUP BY review_id, order_id, review_score,
             review_comment_title, review_comment_message,
             review_creation_date, review_answer_timestamp
    HAVING COUNT(*) > 1
) AS duplicates;
