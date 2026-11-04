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
