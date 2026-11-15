-- Выполнять после 05_marts.sql. Скрипт только читает данные.
-- Ожидаемые значения относятся к исходному набору Olist этого проекта.
WITH order_metrics AS (
    SELECT
        COUNT(*) AS total_rows,
        COUNT(DISTINCT order_id) AS unique_orders,
        COUNT(*) FILTER (WHERE is_delivery_eligible) AS eligible_orders,
        COUNT(*) FILTER (WHERE is_late IS FALSE) AS on_time_orders,
        COUNT(*) FILTER (WHERE is_late IS TRUE) AS late_orders,
        COUNT(*) FILTER (WHERE is_review_eligible) AS eligible_reviews,
        COUNT(*) FILTER (WHERE is_review_eligible AND is_late) AS late_reviews,
        COUNT(*) FILTER (
            WHERE is_late IS DISTINCT FROM CASE
                WHEN is_delivery_eligible
                    THEN delivered_at::date > estimated_at::date
            END
        ) AS wrong_late_flags,
        COUNT(*) FILTER (
            WHERE is_review_eligible
              AND (NOT is_delivery_eligible
                   OR review_score IS NULL
                   OR review_score NOT BETWEEN 1 AND 5
                   OR review_answered_at IS NULL
                   OR review_answered_at < delivered_at)
        ) AS invalid_eligible_reviews,
        COUNT(*) FILTER (
            WHERE is_delivery_eligible AND seller_count = 1
        ) AS single_seller_orders,
        COUNT(*) FILTER (
            WHERE is_delivery_eligible AND known_category_count = 1
              AND unknown_category_item_count = 0
        ) AS single_category_orders,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY delivery_days)
            FILTER (WHERE is_delivery_eligible) AS median_delivery_days,
        PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY delivery_days)
            FILTER (WHERE is_delivery_eligible) AS p90_delivery_days,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY delay_days)
            FILTER (WHERE is_late) AS median_delay_late_days
    FROM mart.order_delivery
),
monthly_metrics AS (
    SELECT
        COUNT(*) AS months,
        COUNT(DISTINCT purchase_month) AS unique_months,
        COUNT(*) FILTER (WHERE is_comparison_month) AS comparison_months,
        SUM(total_orders) AS total_orders,
        SUM(eligible_orders) AS eligible_orders,
        SUM(late_orders) AS late_orders,
        COUNT(*) FILTER (
            WHERE total_orders IS DISTINCT FROM (
                eligible_orders + not_delivered_orders + delivered_excluded
            )
        ) AS bad_monthly_balance
    FROM mart.delivery_monthly
),
seller_metrics AS (
    SELECT
        COUNT(*) AS total_pairs,
        COUNT(DISTINCT (order_id, seller_id)) AS unique_pairs,
        SUM(seller_item_count) AS total_items
    FROM mart.order_seller
),
category_metrics AS (
    SELECT
        COUNT(*) AS total_pairs,
        COUNT(DISTINCT (order_id, category_code)) AS unique_pairs,
        SUM(category_item_count) AS total_items
    FROM mart.order_category
),
checks AS (
    SELECT 1 AS section, v.check_name, v.actual, v.expected
    FROM order_metrics AS m
    CROSS JOIN LATERAL (
        VALUES
            ('order_rows', m.total_rows::numeric, 99441),
            ('unique_orders', m.unique_orders, 99441),
            ('eligible_orders', m.eligible_orders, 96470),
            ('on_time_orders', m.on_time_orders, 89936),
            ('late_orders', m.late_orders, 6534),
            ('late_rate_pct', ROUND(100.0 * m.late_orders / NULLIF(m.eligible_orders, 0), 2), 6.77),
            ('median_delivery_days', m.median_delivery_days::numeric, 10),
            ('p90_delivery_days', m.p90_delivery_days::numeric, 23),
            ('median_delay_late_days', m.median_delay_late_days::numeric, 7),
            ('eligible_reviews', m.eligible_reviews, 91171),
            ('eligible_reviews_for_late_orders', m.late_reviews, 1908),
            ('wrong_late_flags', m.wrong_late_flags, 0),
            ('invalid_eligible_reviews', m.invalid_eligible_reviews, 0),
            ('single_seller_orders', m.single_seller_orders, 95195),
            ('single_category_orders', m.single_category_orders, 94358)
    ) AS v(check_name, actual, expected)

    UNION ALL

    SELECT 2, v.check_name, v.actual, v.expected
    FROM monthly_metrics AS m
    CROSS JOIN LATERAL (
        VALUES
            ('monthly_rows', m.months::numeric, 26),
            ('monthly_unique_months', m.unique_months, 26),
            ('comparison_months', m.comparison_months, 19),
            ('monthly_total_orders', m.total_orders, 99441),
            ('monthly_eligible_orders', m.eligible_orders, 96470),
            ('monthly_late_orders', m.late_orders, 6534),
            ('bad_monthly_balance', m.bad_monthly_balance, 0)
    ) AS v(check_name, actual, expected)

    UNION ALL

    SELECT 3, 'seller_pairs', total_pairs, 100010 FROM seller_metrics
    UNION ALL
    SELECT 3, 'seller_duplicate_pairs', total_pairs - unique_pairs, 0 FROM seller_metrics
    UNION ALL
    SELECT 3, 'seller_items', total_items, 112650 FROM seller_metrics
    UNION ALL
    SELECT 4, 'category_pairs', total_pairs, 99470 FROM category_metrics
    UNION ALL
    SELECT 4, 'category_duplicate_pairs', total_pairs - unique_pairs, 0 FROM category_metrics
    UNION ALL
    SELECT 4, 'category_items', total_items, 112650 FROM category_metrics
)
SELECT
    check_name,
    actual,
    expected,
    CASE WHEN actual = expected THEN 'OK' ELSE 'FAIL' END AS status
FROM checks
ORDER BY section, check_name;
