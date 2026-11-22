-- Выполнять после 05_marts.sql. Один выбранный отзыв на заказ.
-- Покрытие пригодными отзывами среди своевременных и просроченных заказов.
WITH delivery_reviews AS (
    SELECT
        delivered_at::date > estimated_at::date AS is_late,
        has_review,
        is_review_eligible
    FROM staging.order_review_quality
    WHERE is_delivery_eligible
)
SELECT
    CASE WHEN is_late THEN 'Просрочен'
         ELSE 'Вовремя или раньше'
    END AS delivery_group,
    COUNT(*) AS total_orders,
    COUNT(*) FILTER (WHERE NOT has_review) AS orders_without_review,
    COUNT(*) FILTER (
        WHERE has_review AND NOT is_review_eligible
    ) AS orders_with_ineligible_review,
    COUNT(*) FILTER (WHERE is_review_eligible) AS eligible_reviews,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_review_eligible) / COUNT(*),
        2
    ) AS review_coverage_pct
FROM delivery_reviews
GROUP BY is_late
ORDER BY is_late;

-- Средняя оценка и доля оценок 1–2 среди пригодных отзывов каждой группы.
WITH delivery_reviews AS (
    SELECT
        delivered_at::date > estimated_at::date AS is_late,
        review_score,
        is_review_eligible
    FROM staging.order_review_quality
    WHERE is_delivery_eligible
),
review_metrics AS (
    SELECT
        is_late,
        COUNT(*) FILTER (WHERE is_review_eligible) AS eligible_reviews,
        AVG(review_score) FILTER (WHERE is_review_eligible) AS avg_score,
        COUNT(*) FILTER (
            WHERE is_review_eligible AND review_score BETWEEN 1 AND 2
        ) AS low_score_reviews
    FROM delivery_reviews
    GROUP BY is_late
)
SELECT
    CASE WHEN is_late THEN 'Просрочен'
         ELSE 'Вовремя или раньше'
    END AS delivery_group,
    eligible_reviews,
    ROUND(avg_score, 2) AS avg_score,
    low_score_reviews,
    ROUND(
        100.0 * low_score_reviews / NULLIF(eligible_reviews, 0),
        2
    ) AS low_score_pct
FROM review_metrics
ORDER BY is_late;

-- Покрытие и оценки по существующим группам длительности просрочки.
WITH review_metrics AS (
    SELECT
        delay_group,
        MIN(deviation_days) AS first_day,
        COUNT(*) AS total_orders,
        COUNT(*) FILTER (WHERE is_review_eligible) AS eligible_reviews,
        AVG(review_score) FILTER (WHERE is_review_eligible) AS avg_score,
        COUNT(*) FILTER (
            WHERE is_review_eligible AND review_score BETWEEN 1 AND 2
        ) AS low_score_reviews
    FROM mart.order_delivery
    WHERE is_delivery_eligible
    GROUP BY delay_group
)
SELECT
    delay_group,
    total_orders,
    eligible_reviews,
    ROUND(100.0 * eligible_reviews / total_orders, 2) AS coverage_pct,
    ROUND(avg_score, 2) AS avg_score,
    low_score_reviews,
    ROUND(
        100.0 * low_score_reviews / NULLIF(eligible_reviews, 0),
        2
    ) AS low_score_pct
FROM review_metrics
ORDER BY first_day;

-- Штат покупателя. Сравниваем при наличии минимум 30 отзывов в обеих группах.
WITH state_reviews AS (
    SELECT
        customer_state,
        is_late,
        COUNT(*) AS total_orders,
        COUNT(*) FILTER (WHERE is_review_eligible) AS eligible_reviews,
        COUNT(*) FILTER (
            WHERE is_review_eligible AND review_score BETWEEN 1 AND 2
        ) AS low_score_reviews
    FROM mart.order_delivery
    WHERE is_delivery_eligible
    GROUP BY customer_state, is_late
),
state_rates AS (
    SELECT
        customer_state,
        is_late,
        eligible_reviews,
        100.0 * eligible_reviews / total_orders AS coverage_pct,
        100.0 * low_score_reviews / eligible_reviews AS low_score_pct
    FROM state_reviews
    WHERE eligible_reviews >= 30
)
SELECT
    t.customer_state,
    t.eligible_reviews AS on_time_reviews,
    l.eligible_reviews AS late_reviews,
    ROUND(t.coverage_pct, 2) AS on_time_coverage_pct,
    ROUND(l.coverage_pct, 2) AS late_coverage_pct,
    ROUND(t.low_score_pct, 2) AS on_time_low_score_pct,
    ROUND(l.low_score_pct, 2) AS late_low_score_pct,
    ROUND(l.low_score_pct - t.low_score_pct, 2) AS low_score_gap_pp
FROM state_rates AS t
JOIN state_rates AS l USING (customer_state)
WHERE t.is_late = FALSE
  AND l.is_late = TRUE
ORDER BY low_score_gap_pp DESC, t.customer_state;

-- Одна известная категория на заказ. Минимум 30 отзывов в обеих группах.
WITH delivery AS MATERIALIZED (
    SELECT
        order_id, is_late, is_delivery_eligible, is_review_eligible,
        review_score, known_category_count, unknown_category_item_count
    FROM mart.order_delivery
),
categories AS MATERIALIZED (
    SELECT order_id, category_code, category_name
    FROM mart.order_category
),
category_reviews AS (
    SELECT
        c.category_code,
        c.category_name,
        o.is_late,
        COUNT(*) AS total_orders,
        COUNT(*) FILTER (WHERE o.is_review_eligible) AS eligible_reviews,
        COUNT(*) FILTER (
            WHERE o.is_review_eligible AND o.review_score BETWEEN 1 AND 2
        ) AS low_score_reviews
    FROM delivery AS o
    JOIN categories AS c ON c.order_id = o.order_id
    WHERE o.is_delivery_eligible
      AND o.known_category_count = 1
      AND o.unknown_category_item_count = 0
    GROUP BY c.category_code, c.category_name, o.is_late
),
category_rates AS (
    SELECT
        category_code, category_name, is_late, eligible_reviews,
        100.0 * eligible_reviews / total_orders AS coverage_pct,
        100.0 * low_score_reviews / eligible_reviews AS low_score_pct
    FROM category_reviews
    WHERE eligible_reviews >= 30
)
SELECT
    t.category_code,
    t.category_name,
    t.eligible_reviews AS on_time_reviews,
    l.eligible_reviews AS late_reviews,
    ROUND(t.coverage_pct, 2) AS on_time_coverage_pct,
    ROUND(l.coverage_pct, 2) AS late_coverage_pct,
    ROUND(t.low_score_pct, 2) AS on_time_low_score_pct,
    ROUND(l.low_score_pct, 2) AS late_low_score_pct,
    ROUND(l.low_score_pct - t.low_score_pct, 2) AS low_score_gap_pp
FROM category_rates AS t
JOIN category_rates AS l USING (category_code)
WHERE t.is_late = FALSE
  AND l.is_late = TRUE
ORDER BY low_score_gap_pp DESC, t.category_code;

-- Чувствительность к допуску ответов, полученных до вручения.
WITH delivery_reviews AS (
    SELECT
        delivered_at::date > estimated_at::date AS is_late,
        review_score,
        is_review_eligible,
        review_score BETWEEN 1 AND 5
            AND isfinite(review_created_at)
            AND isfinite(review_answered_at)
            AND review_answered_at >= review_created_at AS has_valid_review
    FROM staging.order_review_quality
    WHERE is_delivery_eligible
)
SELECT
    v.review_rule,
    CASE WHEN o.is_late THEN 'Просрочен'
         ELSE 'Вовремя или раньше'
    END AS delivery_group,
    COUNT(*) FILTER (WHERE v.use_review) AS review_count,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE v.use_review) / COUNT(*), 2
    ) AS coverage_pct,
    ROUND(AVG(o.review_score) FILTER (WHERE v.use_review), 2) AS avg_score,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE v.use_review AND o.review_score BETWEEN 1 AND 2
        ) / NULLIF(COUNT(*) FILTER (WHERE v.use_review), 0), 2
    ) AS low_score_pct
FROM delivery_reviews AS o
CROSS JOIN LATERAL (
    VALUES
        (1, 'Ответ в момент вручения или позже', o.is_review_eligible),
        (2, 'Ответы в любое время относительно вручения', o.has_valid_review)
) AS v(rule_number, review_rule, use_review)
GROUP BY v.rule_number, v.review_rule, o.is_late
ORDER BY v.rule_number, o.is_late;

-- Контроль для распределения оценок 1–5 в Power BI.
-- Знаменатель — все пригодные отзывы внутри соответствующей группы доставки.
WITH score_counts AS (
    SELECT
        delivered_at::date > estimated_at::date AS is_late,
        review_score,
        COUNT(*) AS review_count
    FROM staging.order_review_quality
    WHERE is_delivery_eligible
      AND is_review_eligible
    GROUP BY
        delivered_at::date > estimated_at::date,
        review_score
)
SELECT
    CASE WHEN is_late THEN 'С опозданием'
         ELSE 'Вовремя или раньше'
    END AS delivery_group,
    review_score,
    review_count,
    ROUND(
        100.0 * review_count
        / SUM(review_count) OVER (PARTITION BY is_late),
        2
    ) AS score_pct
FROM score_counts
ORDER BY is_late, review_score;
