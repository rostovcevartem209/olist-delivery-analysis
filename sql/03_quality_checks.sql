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

-- Хронология отзывов; запускать после проверки преобразуемости дат.
-- Creation хранится с датой и нулевым временем: различаем timestamp и день.
WITH review_dates AS (
    SELECT
        NULLIF(TRIM(review_creation_date), '')::timestamp AS created_at,
        NULLIF(TRIM(review_answer_timestamp), '')::timestamp AS answered_at
    FROM raw.order_reviews
)
SELECT
    COUNT(*) FILTER (WHERE answered_at < created_at) AS answer_before_creation,
    COUNT(*) FILTER (
        WHERE answered_at::date < created_at::date
    ) AS answer_on_earlier_day
FROM review_dates;

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

-- Распределение исходных оценок без преобразования в число.
-- Включает все записи отзывов до выбора одной записи на заказ.
SELECT review_score, COUNT(*) AS review_count
FROM raw.order_reviews
GROUP BY review_score
ORDER BY review_score NULLS LAST;

-- Оставшиеся типы позиций перед созданием staging.order_items.
-- Заполненность order_item_id ранее проверена в составе ключа.
SELECT
    COUNT(*) AS total_items,
    COUNT(*) FILTER (
        WHERE NOT pg_input_is_valid(
            NULLIF(TRIM(order_item_id), ''), 'integer'
        )
    ) AS invalid_item_number,
    COUNT(*) FILTER (
        WHERE NULLIF(TRIM(shipping_limit_date), '') IS NULL
    ) AS missing_shipping_limit,
    COUNT(*) FILTER (
        WHERE NOT pg_input_is_valid(
            NULLIF(TRIM(shipping_limit_date), ''), 'timestamp'
        )
    ) AS invalid_shipping_limit
FROM raw.order_items;

-- Исследование самых долгих доставок до решения о выбросах.
-- Предварительная группа: delivered с необходимыми датами,
-- фактическая доставка не раньше покупки по timestamp.
WITH dates AS (
    SELECT
        order_id,
        NULLIF(TRIM(order_purchase_timestamp), '')::timestamp AS purchased_at,
        NULLIF(TRIM(order_delivered_customer_date), '')::timestamp AS delivered_at,
        NULLIF(TRIM(order_estimated_delivery_date), '')::timestamp AS estimated_at
    FROM raw.orders
    WHERE order_status = 'delivered'
)
SELECT
    order_id,
    purchased_at::date AS purchase_date,
    delivered_at::date AS delivered_date,
    estimated_at::date AS estimated_date,
    delivered_at::date - purchased_at::date AS delivery_days,
    delivered_at::date - estimated_at::date AS deviation_days
FROM dates
WHERE purchased_at IS NOT NULL
  AND delivered_at IS NOT NULL
  AND estimated_at IS NOT NULL
  AND delivered_at >= purchased_at
ORDER BY delivery_days DESC, order_id
LIMIT 10;

-- Масштаб хвоста распределения: пороги только исследовательские.
WITH dates AS (
    SELECT
        NULLIF(TRIM(order_purchase_timestamp), '')::timestamp AS purchased_at,
        NULLIF(TRIM(order_delivered_customer_date), '')::timestamp AS delivered_at,
        NULLIF(TRIM(order_estimated_delivery_date), '')::timestamp AS estimated_at
    FROM raw.orders
    WHERE order_status = 'delivered'
), durations AS (
    SELECT delivered_at::date - purchased_at::date AS delivery_days
    FROM dates
    WHERE purchased_at IS NOT NULL
      AND delivered_at IS NOT NULL
      AND estimated_at IS NOT NULL
      AND delivered_at >= purchased_at
)
SELECT
    COUNT(*) AS examined_orders,
    PERCENTILE_CONT(0.99) WITHIN GROUP (
        ORDER BY delivery_days
    ) AS p99_delivery_days,
    COUNT(*) FILTER (WHERE delivery_days > 90) AS over_90_days,
    COUNT(*) FILTER (WHERE delivery_days > 180) AS over_180_days,
    MAX(delivery_days) AS max_delivery_days
FROM durations;

-- Первичная проверка заполненности и преобразуемости денежных полей.
SELECT
    COUNT(*) AS total_items,
    COUNT(*) FILTER (WHERE NULLIF(TRIM(price), '') IS NULL) AS missing_price,
    COUNT(*) FILTER (WHERE NULLIF(TRIM(freight_value), '') IS NULL) AS missing_freight,
    COUNT(*) FILTER (
        WHERE NOT pg_input_is_valid(NULLIF(TRIM(price), ''), 'numeric')
    ) AS invalid_price,
    COUNT(*) FILTER (
        WHERE NOT pg_input_is_valid(NULLIF(TRIM(freight_value), ''), 'numeric')
    ) AS invalid_freight
FROM raw.order_items;

-- Запускать после проверки преобразуемости денежных полей.
WITH amounts AS (
    SELECT price::numeric AS price_value,
           freight_value::numeric AS freight_amount
    FROM raw.order_items
)
SELECT
    MIN(price_value) AS min_price,
    MAX(price_value) AS max_price,
    COUNT(*) FILTER (WHERE price_value < 0) AS negative_price,
    MIN(freight_amount) AS min_freight,
    MAX(freight_amount) AS max_freight,
    COUNT(*) FILTER (WHERE freight_amount < 0) AS negative_freight
FROM amounts;

-- Штаты: заполненность и формат, без исправлений raw.
-- Две заглавные латинские буквы ещё не доказывают существование кода.
WITH regions AS (
    SELECT 'customers' AS source_table, customer_state AS state_code
    FROM raw.customers
    UNION ALL
    SELECT 'sellers', seller_state
    FROM raw.sellers
)
SELECT
    source_table,
    COUNT(*) AS total_rows,
    COUNT(DISTINCT state_code) AS distinct_states,
    COUNT(*) FILTER (
        WHERE NULLIF(TRIM(state_code), '') IS NULL
    ) AS missing_state,
    COUNT(*) FILTER (
        WHERE NULLIF(TRIM(state_code), '') IS NOT NULL
          AND state_code !~ '^[A-Z]{2}$'
    ) AS invalid_format
FROM regions
GROUP BY source_table
ORDER BY source_table;

-- Допустимые UF: https://www.ibge.gov.br/superintendencias-estaduais.html
-- Список сверен 2026-10-31. Пропуски проверяются отдельным запросом выше.
WITH regions AS (
    SELECT 'customers' AS source_table, customer_state AS state_code
    FROM raw.customers
    UNION ALL
    SELECT 'sellers', seller_state
    FROM raw.sellers
)
SELECT source_table, state_code, COUNT(*) AS row_count
FROM regions
WHERE state_code NOT IN (
    'AC', 'AL', 'AP', 'AM', 'BA', 'CE', 'DF', 'ES', 'GO',
    'MA', 'MT', 'MS', 'MG', 'PA', 'PB', 'PR', 'PE', 'PI',
    'RJ', 'RN', 'RS', 'RO', 'RR', 'SC', 'SP', 'SE', 'TO'
)
GROUP BY source_table, state_code
ORDER BY source_table, state_code;

-- Диапазоны дат всей таблицы orders, без фильтра по статусу.
-- MIN/MAX игнорируют NULL; отсутствие доставки не исключает заказ
-- из диапазона покупок. Преобразуемость дат проверяется заранее.
SELECT
    MIN(NULLIF(TRIM(order_purchase_timestamp), '')::timestamp) AS first_purchase,
    MAX(NULLIF(TRIM(order_purchase_timestamp), '')::timestamp) AS last_purchase,
    MIN(NULLIF(TRIM(order_delivered_customer_date), '')::timestamp) AS first_delivery,
    MAX(NULLIF(TRIM(order_delivered_customer_date), '')::timestamp) AS last_delivery
FROM raw.orders;

-- Цены и стоимость доставки: безопасная типизация для проверки значений.
-- Некорректные строки и пропуски считаются вместе как непригодные суммы.
WITH amounts AS (
    SELECT
        CASE WHEN pg_input_is_valid(NULLIF(TRIM(price), ''), 'numeric')
             THEN NULLIF(TRIM(price), '')::numeric END AS price_value,
        CASE WHEN pg_input_is_valid(NULLIF(TRIM(freight_value), ''), 'numeric')
             THEN NULLIF(TRIM(freight_value), '')::numeric END AS freight_value_number
    FROM raw.order_items
)
SELECT
    COUNT(*) AS total_items,
    COUNT(*) FILTER (
        WHERE price_value IS NULL OR price_value::text IN ('NaN', 'Infinity', '-Infinity')
    ) AS invalid_or_missing_price,
    COUNT(*) FILTER (
        WHERE freight_value_number IS NULL
           OR freight_value_number::text IN ('NaN', 'Infinity', '-Infinity')
    ) AS invalid_or_missing_freight,
    COUNT(*) FILTER (
        WHERE price_value < 0 AND price_value::text <> '-Infinity'
    ) AS negative_price,
    COUNT(*) FILTER (
        WHERE freight_value_number < 0 AND freight_value_number::text <> '-Infinity'
    ) AS negative_freight
FROM amounts;

-- Демонстрация выбора одного отзыва на заказ.
-- Перед окончательным использованием требуется проверка совпадения
-- всех трёх полей сортировки внутри одного заказа.
WITH ranked_reviews AS (
    SELECT
        order_id,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY
                NULLIF(TRIM(review_answer_timestamp), '')::timestamp DESC NULLS LAST,
                NULLIF(TRIM(review_creation_date), '')::timestamp DESC NULLS LAST,
                review_id COLLATE "C" DESC NULLS LAST
        ) AS rn
    FROM raw.order_reviews
)
SELECT
    COUNT(*) AS all_review_rows,
    COUNT(*) FILTER (WHERE rn = 1) AS selected_reviews,
    COUNT(*) FILTER (WHERE rn > 1) AS other_review_rows
FROM ranked_reviews;

-- Предварительное покрытие отзывами всех delivered, до окончательного
-- отбора пригодных заказов доставки. Ранжирование до проверки даты ответа.
WITH ranked_reviews AS (
    SELECT
        order_id,
        review_answer_timestamp::timestamp AS answered_at,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY review_answer_timestamp::timestamp DESC,
                     review_creation_date::timestamp DESC,
                     review_id COLLATE "C" DESC
        ) AS rn
    FROM raw.order_reviews
), selected_reviews AS (
    SELECT order_id, answered_at
    FROM ranked_reviews
    WHERE rn = 1
)
SELECT
    COUNT(*) AS delivered_orders,
    COUNT(*) FILTER (WHERE r.order_id IS NULL) AS without_review,
    COUNT(*) FILTER (
        WHERE r.order_id IS NOT NULL
          AND NULLIF(TRIM(o.order_delivered_customer_date), '') IS NULL
    ) AS review_without_delivery_date,
    COUNT(*) FILTER (
        WHERE r.answered_at < NULLIF(TRIM(o.order_delivered_customer_date), '')::timestamp
    ) AS review_before_delivery,
    COUNT(*) FILTER (
        WHERE r.answered_at >= NULLIF(TRIM(o.order_delivered_customer_date), '')::timestamp
    ) AS review_at_or_after_delivery
FROM raw.orders AS o
LEFT JOIN selected_reviews AS r ON r.order_id = o.order_id
WHERE o.order_status = 'delivered';

-- Совпадение всех полей сортировки внутри заказа может сделать выбор
-- ROW_NUMBER неоднозначным. Проверяем после проверки преобразуемости дат.
SELECT
    order_id,
    review_answer_timestamp::timestamp AS answered_at,
    review_creation_date::timestamp AS created_at,
    review_id COLLATE "C" AS review_id,
    COUNT(*) AS row_count
FROM raw.order_reviews
GROUP BY
    order_id,
    review_answer_timestamp::timestamp,
    review_creation_date::timestamp,
    review_id COLLATE "C"
HAVING COUNT(*) > 1
ORDER BY order_id, answered_at, created_at, review_id;

-- Пропуски и преобразуемость дат отзывов (PostgreSQL 16+).
SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (
        WHERE NULLIF(TRIM(review_creation_date), '') IS NULL
    ) AS missing_creation,
    COUNT(*) FILTER (
        WHERE NULLIF(TRIM(review_answer_timestamp), '') IS NULL
    ) AS missing_answer,
    COUNT(*) FILTER (
        WHERE NOT pg_input_is_valid(
            NULLIF(TRIM(review_creation_date), ''), 'timestamp'
        )
    ) AS invalid_creation,
    COUNT(*) FILTER (
        WHERE NOT pg_input_is_valid(
            NULLIF(TRIM(review_answer_timestamp), ''), 'timestamp'
        )
    ) AS invalid_answer
FROM raw.order_reviews;

-- Доставка раньше передачи перевозчику: один день или разные дни.
WITH dates AS (
    SELECT
        NULLIF(TRIM(order_delivered_carrier_date), '')::timestamp AS carrier_at,
        NULLIF(TRIM(order_delivered_customer_date), '')::timestamp AS delivered_at
    FROM raw.orders
    WHERE order_status = 'delivered'
)
SELECT
    COUNT(*) AS affected_orders,
    COUNT(*) FILTER (
        WHERE delivered_at::date = carrier_at::date
    ) AS same_calendar_day,
    COUNT(*) FILTER (
        WHERE delivered_at::date < carrier_at::date
    ) AS earlier_calendar_day,
    MAX(carrier_at - delivered_at) AS max_discrepancy
FROM dates
WHERE delivered_at < carrier_at;

-- Запускать после проверки преобразуемости дат.
-- Хронология delivered: каждый показатель имеет свои необходимые даты.
WITH delivered_dates AS (
    SELECT
        order_id,
        NULLIF(TRIM(order_purchase_timestamp), '')::timestamp AS purchased_at,
        NULLIF(TRIM(order_approved_at), '')::timestamp AS approved_at,
        NULLIF(TRIM(order_delivered_carrier_date), '')::timestamp AS carrier_at,
        NULLIF(TRIM(order_delivered_customer_date), '')::timestamp AS delivered_at,
        NULLIF(TRIM(order_estimated_delivery_date), '')::timestamp AS estimated_at
    FROM raw.orders
    WHERE order_status = 'delivered'
)
SELECT
    COUNT(*) FILTER (WHERE delivered_at < purchased_at) AS delivery_before_purchase,
    COUNT(*) FILTER (WHERE approved_at < purchased_at) AS approval_before_purchase,
    COUNT(*) FILTER (WHERE carrier_at < approved_at) AS carrier_before_approval,
    COUNT(*) FILTER (WHERE delivered_at < carrier_at) AS delivery_before_carrier,
    COUNT(*) FILTER (WHERE estimated_at::date < purchased_at::date) AS estimate_before_purchase
FROM delivered_dates;

-- Примеры самых больших расхождений: передача раньше подтверждения.
WITH dates AS (
    SELECT
        order_id,
        NULLIF(TRIM(order_purchase_timestamp), '')::timestamp AS purchased_at,
        NULLIF(TRIM(order_approved_at), '')::timestamp AS approved_at,
        NULLIF(TRIM(order_delivered_carrier_date), '')::timestamp AS carrier_at,
        NULLIF(TRIM(order_delivered_customer_date), '')::timestamp AS delivered_at
    FROM raw.orders
    WHERE order_status = 'delivered'
)
SELECT order_id, purchased_at, approved_at, carrier_at, delivered_at,
       approved_at - carrier_at AS discrepancy
FROM dates
WHERE carrier_at < approved_at
ORDER BY discrepancy DESC, order_id
LIMIT 10;

-- Дополнительные нарушения и объединение групп без двойного подсчёта.
WITH dates AS (
    SELECT
        NULLIF(TRIM(order_purchase_timestamp), '')::timestamp AS purchased_at,
        NULLIF(TRIM(order_approved_at), '')::timestamp AS approved_at,
        NULLIF(TRIM(order_delivered_carrier_date), '')::timestamp AS carrier_at,
        NULLIF(TRIM(order_delivered_customer_date), '')::timestamp AS delivered_at
    FROM raw.orders
    WHERE order_status = 'delivered'
)
SELECT
    COUNT(*) FILTER (WHERE carrier_at < purchased_at) AS carrier_before_purchase,
    COUNT(*) FILTER (WHERE approved_at > delivered_at) AS approval_after_delivery,
    COUNT(*) FILTER (
        WHERE carrier_at < approved_at AND delivered_at < carrier_at
    ) AS both_previous_issues,
    COUNT(*) FILTER (
        WHERE carrier_at < purchased_at
           OR approved_at < purchased_at
           OR carrier_at < approved_at
           OR delivered_at < carrier_at
           OR approved_at > delivered_at
           OR delivered_at < purchased_at
    ) AS any_chronology_issue
FROM dates;

-- Исследование delivered без даты фактической доставки.
SELECT order_id, order_status, order_purchase_timestamp,
       order_approved_at, order_delivered_carrier_date,
       order_delivered_customer_date, order_estimated_delivery_date
FROM raw.orders
WHERE order_status = 'delivered'
  AND NULLIF(TRIM(order_delivered_customer_date), '') IS NULL
ORDER BY order_purchase_timestamp, order_id;

-- Статусы и пропуски дат: пустые строки и пробелы также считаем пропусками.
-- Проверка преобразуемости заполненных дат (PostgreSQL 16+).
-- Не проверяет хронологию, бизнес-смысл или конечность timestamp.
SELECT
    COUNT(*) FILTER (WHERE NOT pg_input_is_valid(NULLIF(TRIM(order_purchase_timestamp), ''), 'timestamp')) AS invalid_purchase,
    COUNT(*) FILTER (WHERE NOT pg_input_is_valid(NULLIF(TRIM(order_approved_at), ''), 'timestamp')) AS invalid_approved,
    COUNT(*) FILTER (WHERE NOT pg_input_is_valid(NULLIF(TRIM(order_delivered_carrier_date), ''), 'timestamp')) AS invalid_carrier,
    COUNT(*) FILTER (WHERE NOT pg_input_is_valid(NULLIF(TRIM(order_delivered_customer_date), ''), 'timestamp')) AS invalid_delivered,
    COUNT(*) FILTER (WHERE NOT pg_input_is_valid(NULLIF(TRIM(order_estimated_delivery_date), ''), 'timestamp')) AS invalid_estimated
FROM raw.orders;

SELECT order_status, COUNT(*) AS order_count
FROM raw.orders
GROUP BY order_status
ORDER BY order_count DESC;

SELECT
    order_status,
    COUNT(*) AS order_count,
    COUNT(*) FILTER (WHERE NULLIF(TRIM(order_purchase_timestamp), '') IS NULL) AS missing_purchase,
    COUNT(*) FILTER (WHERE NULLIF(TRIM(order_approved_at), '') IS NULL) AS missing_approved,
    COUNT(*) FILTER (WHERE NULLIF(TRIM(order_delivered_carrier_date), '') IS NULL) AS missing_carrier,
    COUNT(*) FILTER (WHERE NULLIF(TRIM(order_delivered_customer_date), '') IS NULL) AS missing_delivered,
    COUNT(*) FILTER (WHERE NULLIF(TRIM(order_estimated_delivery_date), '') IS NULL) AS missing_estimated
FROM raw.orders
GROUP BY order_status
ORDER BY order_count DESC;
