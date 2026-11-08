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

-- География: вся пригодная выборка, без ограничения окном месяцев.
-- Ранжируем по абсолютному числу просрочек; малые сегменты сохраняем.
-- Флаг < 100 заказов — рабочая отметка объёма, не статистический тест.
WITH state_metrics AS (
    SELECT
        customer_state,
        COUNT(*) AS order_count,
        COUNT(*) FILTER (WHERE is_late) AS late_orders,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY delay_days
        ) FILTER (WHERE is_late) AS median_delay_late_days
    FROM mart.order_delivery
    WHERE is_delivery_eligible
    GROUP BY customer_state
)
SELECT
    customer_state,
    order_count,
    late_orders,
    ROUND(
        100.0 * late_orders / NULLIF(order_count, 0), 2
    ) AS late_rate_pct,
    ROUND(
        100.0 * late_orders / NULLIF(SUM(late_orders) OVER (), 0), 2
    ) AS late_contribution_pct,
    median_delay_late_days,
    order_count < 100 AS is_small_segment
FROM state_metrics
ORDER BY late_orders DESC, customer_state;

-- Накопленный вклад по штатам; знаменатели используют все штаты.
-- Доля заказов помогает отличать концентрацию объёма от частоты просрочек.
WITH state_counts AS (
    SELECT customer_state,
           COUNT(*) AS order_count,
           COUNT(*) FILTER (WHERE is_late) AS late_orders
    FROM mart.order_delivery
    WHERE is_delivery_eligible
    GROUP BY customer_state
), running AS (
    SELECT
        state_counts.*,
        ROW_NUMBER() OVER (
            ORDER BY late_orders DESC, customer_state
        ) AS position,
        SUM(late_orders) OVER (
            ORDER BY late_orders DESC, customer_state
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_late_orders,
        SUM(order_count) OVER (
            ORDER BY late_orders DESC, customer_state
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_orders,
        SUM(late_orders) OVER () AS all_late_orders,
        SUM(order_count) OVER () AS all_orders
    FROM state_counts
)
SELECT
    position, customer_state, order_count, late_orders, cumulative_late_orders,
    ROUND(100.0 * cumulative_late_orders / NULLIF(all_late_orders, 0), 2) AS cumulative_late_pct,
    ROUND(100.0 * cumulative_orders / NULLIF(all_orders, 0), 2) AS cumulative_order_pct
FROM running
ORDER BY position;

-- Устойчивость различий SP/RJ: месяцы покупки в рабочем окне.
-- Даты задают то же окно, что is_comparison_month, без повторного JOIN
-- к вложенной месячной витрине. Верхняя граница исключительная.
SELECT
    DATE_TRUNC('month', purchased_at)::date AS purchase_month,
    customer_state,
    COUNT(*) AS order_count,
    COUNT(*) FILTER (WHERE is_late) AS late_orders,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late)
        / NULLIF(COUNT(*), 0), 2
    ) AS late_rate_pct
FROM mart.order_delivery
WHERE is_delivery_eligible
  AND customer_state IN ('SP', 'RJ')
  AND purchased_at >= DATE '2017-01-01'
  AND purchased_at < DATE '2018-08-01'
GROUP BY DATE_TRUNC('month', purchased_at)::date, customer_state
ORDER BY purchase_month, customer_state;

-- Покрытие основной выборки подвыборкой одного продавца.
SELECT
    COUNT(*) AS eligible_orders,
    COUNT(*) FILTER (WHERE seller_count = 1) AS single_seller_orders,
    COUNT(*) FILTER (WHERE seller_count > 1) AS multiple_seller_orders,
    COUNT(*) FILTER (WHERE seller_count = 0) AS without_seller,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE seller_count = 1)
        / NULLIF(COUNT(*), 0), 2
    ) AS single_seller_coverage_pct
FROM mart.order_delivery
WHERE is_delivery_eligible;

-- Проверка соединения для маршрутов в подвыборке одного продавца.
WITH routes AS (
    SELECT
        o.order_id,
        o.customer_state,
        s.seller_state,
        o.is_late
    FROM mart.order_delivery AS o
    JOIN mart.order_seller AS s ON s.order_id = o.order_id
    WHERE o.is_delivery_eligible
      AND o.seller_count = 1
)
SELECT
    COUNT(*) AS route_orders,
    COUNT(DISTINCT order_id) AS unique_orders,
    COUNT(*) FILTER (
        WHERE seller_state IS NULL OR customer_state IS NULL
    ) AS missing_route_states,
    COUNT(*) FILTER (WHERE is_late) AS late_orders
FROM routes;

-- Маршруты: только пригодные заказы с одним продавцом, весь период.
-- Вклад считается от всех просрочек этой подвыборки (контроль: 6 521).
-- LIMIT применяется после оконного знаменателя по всем маршрутам.
WITH route_metrics AS (
    SELECT
        s.seller_state,
        o.customer_state,
        COUNT(*) AS order_count,
        COUNT(*) FILTER (WHERE o.is_late) AS late_orders,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY o.delay_days
        ) FILTER (WHERE o.is_late) AS median_delay_late_days
    FROM mart.order_delivery AS o
    JOIN mart.order_seller AS s ON s.order_id = o.order_id
    WHERE o.is_delivery_eligible
      AND o.seller_count = 1
    GROUP BY s.seller_state, o.customer_state
)
SELECT
    seller_state,
    customer_state,
    order_count,
    late_orders,
    ROUND(100.0 * late_orders / NULLIF(order_count, 0), 2) AS late_rate_pct,
    ROUND(
        100.0 * late_orders / NULLIF(SUM(late_orders) OVER (), 0), 2
    ) AS late_contribution_pct,
    median_delay_late_days,
    order_count < 100 AS is_small_segment
FROM route_metrics
ORDER BY late_orders DESC, order_count DESC, seller_state, customer_state
LIMIT 20;

-- Чувствительность двух маршрутов к нарушениям хронологии этапов.
-- Подвыборки пересекаются; строки сценариев нельзя складывать.
WITH route_orders AS (
    SELECT
        o.customer_state,
        o.is_late,
        o.delay_days,
        o.has_stage_chronology_issue
    FROM mart.order_delivery AS o
    JOIN mart.order_seller AS s ON s.order_id = o.order_id
    WHERE o.is_delivery_eligible
      AND o.seller_count = 1
      AND s.seller_state = 'SP'
      AND o.customer_state IN ('SP', 'RJ')
), comparison AS (
    SELECT 'Все пригодные' AS sample_name,
           customer_state, is_late, delay_days
    FROM route_orders
    UNION ALL
    SELECT 'Без нарушений этапов',
           customer_state, is_late, delay_days
    FROM route_orders
    WHERE NOT has_stage_chronology_issue
)
SELECT
    sample_name,
    customer_state,
    COUNT(*) AS order_count,
    COUNT(*) FILTER (WHERE is_late) AS late_orders,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late)
        / NULLIF(COUNT(*), 0), 2
    ) AS late_rate_pct,
    PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY delay_days
    ) FILTER (WHERE is_late) AS median_delay_late_days
FROM comparison
GROUP BY sample_name, customer_state
ORDER BY customer_state, sample_name;

-- Основной рейтинг продавцов по числу просроченных заказов.
-- Только пригодные заказы с одним продавцом, вся историческая выборка.
-- Малые сегменты не исключаются из рейтинга абсолютного количества.
WITH seller_metrics AS (
    SELECT
        s.seller_id,
        s.seller_state,
        COUNT(*) AS order_count,
        COUNT(*) FILTER (WHERE o.is_late) AS late_orders,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY o.delay_days
        ) FILTER (WHERE o.is_late) AS median_delay_late_days
    FROM mart.order_delivery AS o
    JOIN mart.order_seller AS s ON s.order_id = o.order_id
    WHERE o.is_delivery_eligible
      AND o.seller_count = 1
    GROUP BY s.seller_id, s.seller_state
)
SELECT
    seller_id,
    seller_state,
    order_count,
    late_orders,
    ROUND(100.0 * late_orders / NULLIF(order_count, 0), 2) AS late_rate_pct,
    ROUND(
        100.0 * late_orders / NULLIF(SUM(late_orders) OVER (), 0), 2
    ) AS late_contribution_pct,
    median_delay_late_days,
    order_count < 100 AS is_small_segment
FROM seller_metrics
ORDER BY late_orders DESC, order_count DESC, seller_id
LIMIT 20;

-- Рейтинг по доле: минимум 100 пригодных заказов.
-- Общий знаменатель вклада вычисляется до фильтра объёма.
WITH seller_metrics AS (
    SELECT
        s.seller_id,
        s.seller_state,
        COUNT(*) AS order_count,
        COUNT(*) FILTER (WHERE o.is_late) AS late_orders,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY o.delay_days
        ) FILTER (WHERE o.is_late) AS median_delay_late_days
    FROM mart.order_delivery AS o
    JOIN mart.order_seller AS s ON s.order_id = o.order_id
    WHERE o.is_delivery_eligible
      AND o.seller_count = 1
    GROUP BY s.seller_id, s.seller_state
), metrics_with_totals AS (
    SELECT seller_metrics.*,
           SUM(late_orders) OVER () AS all_late_orders
    FROM seller_metrics
)
SELECT
    seller_id,
    seller_state,
    order_count,
    late_orders,
    ROUND(100.0 * late_orders / order_count, 2) AS late_rate_pct,
    ROUND(
        100.0 * late_orders / NULLIF(all_late_orders, 0), 2
    ) AS late_contribution_pct,
    median_delay_late_days
FROM metrics_with_totals
WHERE order_count >= 100
ORDER BY late_orders::numeric / order_count DESC, late_orders DESC, seller_id
LIMIT 20;

-- Чувствительность топ-10 продавцов по доле к минимальному объёму.
-- Один продавец может присутствовать в нескольких вариантах порога.
WITH seller_metrics AS (
    SELECT
        s.seller_id,
        COUNT(*) AS order_count,
        COUNT(*) FILTER (WHERE o.is_late) AS late_orders
    FROM mart.order_delivery AS o
    JOIN mart.order_seller AS s ON s.order_id = o.order_id
    WHERE o.is_delivery_eligible
      AND o.seller_count = 1
    GROUP BY s.seller_id
), thresholds(min_orders) AS (
    VALUES (50), (100), (200)
), ranked AS (
    SELECT
        t.min_orders,
        m.seller_id,
        m.order_count,
        m.late_orders,
        ROW_NUMBER() OVER (
            PARTITION BY t.min_orders
            ORDER BY m.late_orders::numeric / m.order_count DESC,
                     m.late_orders DESC, m.seller_id
        ) AS position
    FROM seller_metrics AS m
    CROSS JOIN thresholds AS t
    WHERE m.order_count >= t.min_orders
)
SELECT
    min_orders,
    position,
    seller_id,
    order_count,
    late_orders,
    ROUND(100.0 * late_orders / order_count, 2) AS late_rate_pct
FROM ranked
WHERE position <= 10
ORDER BY min_orders, position;

-- Рейтинг медианной задержки: только продавцы хотя бы с одной просрочкой.
-- Порог 100 применяется к рейтингу по доле; здесь малые группы сохраняем
-- с отметкой и явным числом просрочек, на котором основана медиана.
WITH seller_metrics AS (
    SELECT
        s.seller_id,
        s.seller_state,
        COUNT(*) AS order_count,
        COUNT(*) FILTER (WHERE o.is_late) AS late_orders,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY o.delay_days
        ) FILTER (WHERE o.is_late) AS median_delay_late_days
    FROM mart.order_delivery AS o
    JOIN mart.order_seller AS s ON s.order_id = o.order_id
    WHERE o.is_delivery_eligible
      AND o.seller_count = 1
    GROUP BY s.seller_id, s.seller_state
)
SELECT
    seller_id,
    seller_state,
    order_count,
    late_orders,
    ROUND(100.0 * late_orders / order_count, 2) AS late_rate_pct,
    median_delay_late_days,
    order_count < 100 AS is_small_segment
FROM seller_metrics
WHERE late_orders > 0
ORDER BY median_delay_late_days DESC, late_orders DESC, order_count DESC, seller_id
LIMIT 20;

-- Дополнительный анализ участия: совокупный охват списка продавцов.
-- Список топ-20 фиксируется по основному рейтингу одного продавца.
-- Охват включает все пригодные заказы и дедуплицирует order_id.
WITH eligible AS (
    SELECT order_id, seller_count, is_late
    FROM mart.order_delivery
    WHERE is_delivery_eligible
), top_sellers AS (
    SELECT s.seller_id
    FROM eligible AS o
    JOIN mart.order_seller AS s ON s.order_id = o.order_id
    WHERE o.seller_count = 1
    GROUP BY s.seller_id
    ORDER BY COUNT(*) FILTER (WHERE o.is_late) DESC,
             COUNT(*) DESC, s.seller_id
    LIMIT 20
), participating_orders AS (
    SELECT DISTINCT o.order_id, o.is_late
    FROM eligible AS o
    JOIN mart.order_seller AS s ON s.order_id = o.order_id
    JOIN top_sellers AS t ON t.seller_id = s.seller_id
)
SELECT
    COUNT(*) AS covered_orders,
    COUNT(*) FILTER (WHERE is_late) AS covered_late_orders,
    ROUND(
        100.0 * COUNT(*)
        / NULLIF((SELECT COUNT(*) FROM eligible), 0), 2
    ) AS order_coverage_pct,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late)
        / NULLIF((SELECT COUNT(*) FROM eligible WHERE is_late), 0), 2
    ) AS late_coverage_pct
FROM participating_orders;

-- Покрытие основного анализа категорий среди пригодных заказов.
-- Заказы с неизвестными категориями учитываются отдельной группой,
-- даже если в том же заказе есть известные категории.
SELECT
    COUNT(*) AS eligible_orders,
    COUNT(*) FILTER (
        WHERE known_category_count = 1
          AND unknown_category_item_count = 0
    ) AS single_known_category_orders,
    COUNT(*) FILTER (
        WHERE known_category_count > 1
          AND unknown_category_item_count = 0
    ) AS multiple_known_category_orders,
    COUNT(*) FILTER (
        WHERE unknown_category_item_count > 0
    ) AS orders_with_unknown_category,
    COUNT(*) FILTER (
        WHERE NOT has_item_details
    ) AS orders_without_items,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE known_category_count = 1
              AND unknown_category_item_count = 0
        ) / NULLIF(COUNT(*), 0), 2
    ) AS single_category_coverage_pct
FROM mart.order_delivery
WHERE is_delivery_eligible;

-- Проверка соединения основной подвыборки категорий перед рейтингами.
-- План предыдущего варианта: оценка 1 заказа вместо подтверждённых 94 358
-- и Nested Loop Left Join с ranked_reviews по Join Filter.
-- Материализуем доставку ДО фильтра категорий, чтобы этот фильтр
-- не влиял на выбор внутренних соединений основной витрины.
-- Пользователь подтвердил: 94 358 строк и заказов, 0 неизвестных, 6 422 просрочки.
-- Время выполнения пользователь не сообщил.
WITH delivery AS MATERIALIZED (
    SELECT
        order_id,
        is_late,
        is_delivery_eligible,
        known_category_count,
        unknown_category_item_count
    FROM mart.order_delivery
), eligible_category_orders AS (
    SELECT order_id, is_late
    FROM delivery
    WHERE is_delivery_eligible
      AND known_category_count = 1
      AND unknown_category_item_count = 0
), categories AS MATERIALIZED (
    SELECT order_id, category_code, category_name, is_category_unknown
    FROM mart.order_category
)
SELECT
    COUNT(*) AS joined_rows,
    COUNT(DISTINCT o.order_id) AS unique_orders,
    COUNT(*) FILTER (
        WHERE c.category_code IS NULL
           OR c.category_name IS NULL
           OR c.is_category_unknown
    ) AS rows_without_known_category,
    COUNT(*) FILTER (WHERE o.is_late) AS late_orders
FROM eligible_category_orders AS o
LEFT JOIN categories AS c
    ON c.order_id = o.order_id;

-- Основной рейтинг категорий по числу просрочек.
-- Вклад от всех просрочек подвыборки одной известной категории до LIMIT.
WITH delivery AS MATERIALIZED (
    SELECT
        order_id,
        is_late,
        delay_days,
        is_delivery_eligible,
        known_category_count,
        unknown_category_item_count
    FROM mart.order_delivery
), categories AS MATERIALIZED (
    SELECT order_id, category_code, category_name
    FROM mart.order_category
), category_metrics AS (
    SELECT
        c.category_code,
        c.category_name,
        COUNT(*) AS order_count,
        COUNT(*) FILTER (WHERE o.is_late) AS late_orders,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY o.delay_days
        ) FILTER (WHERE o.is_late) AS median_delay_late_days
    FROM delivery AS o
    JOIN categories AS c ON c.order_id = o.order_id
    WHERE o.is_delivery_eligible
      AND o.known_category_count = 1
      AND o.unknown_category_item_count = 0
    GROUP BY c.category_code, c.category_name
)
SELECT
    category_code,
    category_name,
    order_count,
    late_orders,
    ROUND(100.0 * late_orders / order_count, 2) AS late_rate_pct,
    ROUND(
        100.0 * late_orders / NULLIF(SUM(late_orders) OVER (), 0), 2
    ) AS late_contribution_pct,
    median_delay_late_days,
    order_count < 100 AS is_small_segment
FROM category_metrics
ORDER BY late_orders DESC, order_count DESC, category_code
LIMIT 20;

-- Рейтинг категорий по доле просрочек, минимум 100 пригодных заказов.
-- Общий знаменатель вклада вычисляется до ограничения объёма.
WITH delivery AS MATERIALIZED (
    SELECT
        order_id,
        is_late,
        delay_days,
        is_delivery_eligible,
        known_category_count,
        unknown_category_item_count
    FROM mart.order_delivery
), categories AS MATERIALIZED (
    SELECT order_id, category_code, category_name
    FROM mart.order_category
), category_metrics AS (
    SELECT
        c.category_code,
        c.category_name,
        COUNT(*) AS order_count,
        COUNT(*) FILTER (WHERE o.is_late) AS late_orders,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY o.delay_days
        ) FILTER (WHERE o.is_late) AS median_delay_late_days
    FROM delivery AS o
    JOIN categories AS c ON c.order_id = o.order_id
    WHERE o.is_delivery_eligible
      AND o.known_category_count = 1
      AND o.unknown_category_item_count = 0
    GROUP BY c.category_code, c.category_name
), metrics_with_totals AS (
    SELECT
        category_metrics.*,
        SUM(late_orders) OVER () AS total_late_orders
    FROM category_metrics
)
SELECT
    category_code,
    category_name,
    order_count,
    late_orders,
    ROUND(100.0 * late_orders / order_count, 2) AS late_rate_pct,
    ROUND(
        100.0 * late_orders / NULLIF(total_late_orders, 0), 2
    ) AS late_contribution_pct,
    median_delay_late_days
FROM metrics_with_totals
WHERE order_count >= 100
ORDER BY late_orders::numeric / order_count DESC,
         late_orders DESC, category_code
LIMIT 20;

-- Чувствительность рейтинга категорий: топ-10 при порогах 50/100/200.
WITH delivery AS MATERIALIZED (
    SELECT
        order_id, is_late, is_delivery_eligible,
        known_category_count, unknown_category_item_count
    FROM mart.order_delivery
), categories AS MATERIALIZED (
    SELECT order_id, category_code, category_name
    FROM mart.order_category
), category_metrics AS MATERIALIZED (
    SELECT
        c.category_code,
        c.category_name,
        COUNT(*) AS order_count,
        COUNT(*) FILTER (WHERE o.is_late) AS late_orders
    FROM delivery AS o
    JOIN categories AS c ON c.order_id = o.order_id
    WHERE o.is_delivery_eligible
      AND o.known_category_count = 1
      AND o.unknown_category_item_count = 0
    GROUP BY c.category_code, c.category_name
), thresholds(min_orders) AS (
    VALUES (50), (100), (200)
), ranked AS (
    SELECT
        t.min_orders,
        c.*,
        ROW_NUMBER() OVER (
            PARTITION BY t.min_orders
            ORDER BY c.late_orders::numeric / c.order_count DESC,
                     c.late_orders DESC, c.category_code
        ) AS position
    FROM thresholds AS t
    CROSS JOIN category_metrics AS c
    WHERE c.order_count >= t.min_orders
)
SELECT
    min_orders,
    position,
    category_code,
    category_name,
    order_count,
    late_orders,
    ROUND(100.0 * late_orders / order_count, 2) AS late_rate_pct
FROM ranked
WHERE position <= 10
ORDER BY min_orders, position;

-- Рейтинг категорий по медианной задержке только просроченных.
-- Малые сегменты сохраняются и отмечаются; категории без просрочек исключены.
WITH delivery AS MATERIALIZED (
    SELECT
        order_id, is_late, delay_days, is_delivery_eligible,
        known_category_count, unknown_category_item_count
    FROM mart.order_delivery
), categories AS MATERIALIZED (
    SELECT order_id, category_code, category_name
    FROM mart.order_category
), category_metrics AS (
    SELECT
        c.category_code,
        c.category_name,
        COUNT(*) AS order_count,
        COUNT(*) FILTER (WHERE o.is_late) AS late_orders,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY o.delay_days
        ) FILTER (WHERE o.is_late) AS median_delay_late_days
    FROM delivery AS o
    JOIN categories AS c ON c.order_id = o.order_id
    WHERE o.is_delivery_eligible
      AND o.known_category_count = 1
      AND o.unknown_category_item_count = 0
    GROUP BY c.category_code, c.category_name
)
SELECT
    category_code,
    category_name,
    order_count,
    late_orders,
    ROUND(100.0 * late_orders / order_count, 2) AS late_rate_pct,
    median_delay_late_days,
    order_count < 100 AS is_small_segment
FROM category_metrics
WHERE late_orders > 0
ORDER BY median_delay_late_days DESC,
         late_orders DESC, order_count DESC, category_code
LIMIT 20;

-- Дополнительный совокупный охват топ-20 категорий по числу просрочек.
-- Список из основной подвыборки; участие во всех пригодных заказах.
-- Пересечения категорий устраняются по order_id.
WITH delivery AS MATERIALIZED (
    SELECT
        order_id, is_late, is_delivery_eligible,
        known_category_count, unknown_category_item_count
    FROM mart.order_delivery
), eligible AS MATERIALIZED (
    SELECT *
    FROM delivery
    WHERE is_delivery_eligible
), categories AS MATERIALIZED (
    SELECT order_id, category_code
    FROM mart.order_category
), top_categories AS (
    SELECT c.category_code
    FROM eligible AS o
    JOIN categories AS c ON c.order_id = o.order_id
    WHERE o.known_category_count = 1
      AND o.unknown_category_item_count = 0
    GROUP BY c.category_code
    ORDER BY COUNT(*) FILTER (WHERE o.is_late) DESC,
             COUNT(*) DESC, c.category_code
    LIMIT 20
), participating_orders AS (
    SELECT DISTINCT o.order_id, o.is_late
    FROM eligible AS o
    JOIN categories AS c ON c.order_id = o.order_id
    JOIN top_categories AS t ON t.category_code = c.category_code
)
SELECT
    COUNT(*) AS covered_orders,
    COUNT(*) FILTER (WHERE is_late) AS covered_late_orders,
    ROUND(
        100.0 * COUNT(*)
        / NULLIF((SELECT COUNT(*) FROM eligible), 0), 2
    ) AS order_coverage_pct,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late)
        / NULLIF((SELECT COUNT(*) FROM eligible WHERE is_late), 0), 2
    ) AS late_coverage_pct
FROM participating_orders;
