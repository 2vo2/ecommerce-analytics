-- ============================================================
-- ecommerce-analytics — Бізнес-аналіз
-- Датасет: Brazilian E-Commerce Public Dataset by Olist (Kaggle)
-- ============================================================
-- Передумова: усі перевірки якості даних виконано і задокументовано
-- в data_quality_checks.sql. Тут — тільки запити для відповіді на
-- бізнес-питання.
-- ============================================================


-- ============================================================
-- 1. ВОРОНКА ЗАМОВЛЕНЬ ПО СТАТУСАХ
-- ============================================================

SELECT
    order_status,
    COUNT(order_id)
FROM olist_orders_dataset
GROUP BY 1
ORDER BY 2 DESC;

-- Частка delivered (з правильним приведенням до decimal, без
-- цілочисельного ділення)
SELECT
    COUNT(order_id) AS total_order_count,
    ROUND((COUNT(order_id) FILTER (WHERE order_status = 'delivered') * 100)::decimal / COUNT(order_id), 2) AS delivered_pct
FROM olist_orders_dataset;
-- Результат: 97.02%

-- Групування статусів у бізнес-категорії + частка кожної (SUM OVER
-- замість окремого скалярного підзапиту для загальної суми)
SELECT
    CASE
        WHEN order_status IN ('shipped', 'processing') THEN 'Process. Is not an error'
        WHEN order_status = 'delivered' THEN 'Finished'
        ELSE 'Error'
    END AS status,
    COUNT(order_status) AS orders_count,
    ROUND((COUNT(order_status) * 100)::decimal / SUM(COUNT(order_status)) OVER (), 2) AS pct
FROM olist_orders_dataset
GROUP BY 1
ORDER BY 2 DESC;


-- ============================================================
-- 2. ВИРУЧКА ПО КАТЕГОРІЯХ ТОВАРУ + AOV (середній чек)
-- ============================================================

SELECT
    opd.product_category_name,
    pcnt.product_category_name_english,
    SUM(ooid.price) AS total_revenue,
    COUNT(DISTINCT ooid.order_id) AS orders_count,
    ROUND(SUM(ooid.price)::decimal / COUNT(DISTINCT ooid.order_id), 2) AS aov
FROM olist_order_items_dataset ooid
INNER JOIN olist_products_dataset opd ON ooid.product_id = opd.product_id
INNER JOIN product_category_name_translation pcnt ON opd.product_category_name = pcnt.product_category_name
GROUP BY 1, 2
ORDER BY 3 DESC
LIMIT 10;
-- Інсайт: relogios_presentes (watches_gifts) має найвищий AOV ($214)
-- в топ-10, при меншій кількості замовлень, ніж у лідерів за сумою.


-- ============================================================
-- 3. ТИПИ ОПЛАТИ
-- ============================================================

SELECT
    payment_type,
    COUNT(DISTINCT order_id) AS payments_count,
    SUM(payment_value) AS total_value,
    ROUND(AVG(payment_installments), 2) AS avg_installments
FROM olist_order_payments_dataset
GROUP BY 1;
-- credit_card домінує: 76505 платежів, ~$12.5M, avg_installments 3.51


-- ============================================================
-- 4. ЧАСОВИЙ ТРЕНД ВИРУЧКИ (12 повних місяців, без розриву зими)
-- ============================================================

-- Місячна динаміка з MoM-приростом (CTE, щоб не дублювати LAG)
WITH monthly_revenue AS (
    SELECT
        DATE_TRUNC('month', ood.order_purchase_timestamp) AS month_year,
        SUM(ooid.price) AS current_sum,
        COUNT(DISTINCT ood.order_id) AS orders_count,
        LAG(SUM(ooid.price)) OVER (ORDER BY DATE_TRUNC('month', ood.order_purchase_timestamp))::decimal AS previous_sum
    FROM olist_orders_dataset ood
    LEFT JOIN olist_order_items_dataset ooid ON ood.order_id = ooid.order_id
    WHERE ood.order_purchase_timestamp >= '2017-03-01'
      AND ood.order_purchase_timestamp < '2018-03-01'
    GROUP BY 1
)
SELECT
    *,
    ROUND((current_sum - previous_sum) / previous_sum * 100, 2) AS mom_growth_pct
FROM monthly_revenue
ORDER BY month_year;
-- Листопад: +52.1% (Black Friday). Грудень: -26.4% (спад після піку).

-- Сезонність (межі "зсунуті" на 2 місяці, щоб зима не розривалась
-- між двома календарними роками)
SELECT
    CASE
        WHEN ood.order_purchase_timestamp >= '2017-03-01' AND ood.order_purchase_timestamp < '2017-06-01' THEN 'spring'
        WHEN ood.order_purchase_timestamp >= '2017-06-01' AND ood.order_purchase_timestamp < '2017-09-01' THEN 'summer'
        WHEN ood.order_purchase_timestamp >= '2017-09-01' AND ood.order_purchase_timestamp < '2017-12-01' THEN 'autumn'
        ELSE 'winter'
    END AS season,
    SUM(ooid.price) AS total_sales,
    COUNT(DISTINCT ooid.order_id) AS total_orders
FROM olist_orders_dataset ood
LEFT JOIN olist_order_items_dataset ooid ON ood.order_id = ooid.order_id
WHERE ood.order_purchase_timestamp >= '2017-03-01'
  AND ood.order_purchase_timestamp < '2018-03-01'
GROUP BY 1
ORDER BY total_sales DESC;
-- winter: $2,538,179 (найсильніший сезон, грудень 2017 + січень-лютий 2018)
-- autumn: $2,298,878 / summer: $1,504,988 / spring: $1,240,310

-- Деталізація листопада по днях — пошук причини сплеску
SELECT
    DATE(order_purchase_timestamp) AS order_date,
    SUM(price),
    COUNT(DISTINCT order_id)
FROM olist_orders_dataset o
LEFT JOIN olist_order_items_dataset oi ON o.order_id = oi.order_id
WHERE order_purchase_timestamp >= '2017-11-01' AND order_purchase_timestamp < '2017-12-01'
GROUP BY 1
ORDER BY 2 DESC
LIMIT 10;
-- 24.11.2017 (Black Friday): $152,653 — у 2.5 раза більше за 2-й найкращий день


-- ============================================================
-- 5. ТОП-3 ПРОДАВЦІ ЗА ВИРУЧКОЮ В КОЖНІЙ КАТЕГОРІЇ
-- ============================================================

WITH category_rank_cte AS (
    SELECT
        ooid.seller_id,
        pcnt.product_category_name_english,
        SUM(ooid.price) AS total_revenue,
        ROW_NUMBER() OVER (PARTITION BY pcnt.product_category_name_english ORDER BY SUM(ooid.price) DESC) AS category_rank
    FROM olist_order_items_dataset ooid
    INNER JOIN olist_products_dataset opd ON ooid.product_id = opd.product_id
    INNER JOIN product_category_name_translation pcnt ON opd.product_category_name = pcnt.product_category_name
    GROUP BY 1, 2
)
SELECT *
FROM category_rank_cte
WHERE category_rank <= 3;

-- У скількох різних категоріях продавець входить у ТОП-3
-- (другий рівень агрегації поверх першого)
WITH category_rank_cte AS (
    SELECT
        ooid.seller_id,
        pcnt.product_category_name_english,
        SUM(ooid.price) AS total_revenue,
        ROW_NUMBER() OVER (PARTITION BY pcnt.product_category_name_english ORDER BY SUM(ooid.price) DESC) AS category_rank
    FROM olist_order_items_dataset ooid
    INNER JOIN olist_products_dataset opd ON ooid.product_id = opd.product_id
    INNER JOIN product_category_name_translation pcnt ON opd.product_category_name = pcnt.product_category_name
    GROUP BY 1, 2
),
count_category_rank_cte AS (
    SELECT
        seller_id,
        COUNT(product_category_name_english) AS top3_categories_count
    FROM category_rank_cte
    WHERE category_rank <= 3
    GROUP BY 1
)
SELECT *
FROM count_category_rank_cte
ORDER BY top3_categories_count DESC;
-- Продавець 955fee9216a65b617aa5c0531780ce60: топ-3 у 6 різних категоріях
-- (генераліст, на відміну від переважної більшості продавців з count=1)


-- ============================================================
-- 6. ШВИДКІСТЬ ДОСТАВКИ VS ОЦІНКА ВІДГУКУ
-- ============================================================

-- Приведення дат доставки з порожніх рядків '' до справжнього NULL
-- (одноразова корекція схеми, виконується один раз):
-- ALTER TABLE olist_orders_dataset
-- ALTER COLUMN order_delivered_customer_date TYPE timestamp
-- USING NULLIF(order_delivered_customer_date, '')::timestamp;

SELECT
    CASE
        WHEN (ood.order_delivered_customer_date::date - ood.order_purchase_timestamp::date) <= 7 THEN 'up to 7 days'
        WHEN (ood.order_delivered_customer_date::date - ood.order_purchase_timestamp::date) BETWEEN 8 AND 14 THEN '8-14 days'
        WHEN (ood.order_delivered_customer_date::date - ood.order_purchase_timestamp::date) >= 15 THEN '15+ days'
        WHEN ood.order_delivered_customer_date IS NULL THEN 'NULL - Unknown'
    END AS delivery_time_basket,
    COUNT(DISTINCT ood.order_id) AS all_orders_in_basket,
    COUNT(ood.order_id) FILTER (WHERE oord.order_id IS NULL) AS orders_without_review,
    ROUND(COUNT(ood.order_id) FILTER (WHERE oord.order_id IS NULL)::decimal / COUNT(DISTINCT ood.order_id) * 100, 2) AS pct_without_review,
    ROUND(AVG(oord.review_score), 2) AS avg_review_score
FROM olist_orders_dataset ood
LEFT JOIN olist_order_reviews_dataset oord ON ood.order_id = oord.order_id
GROUP BY 1
ORDER BY 1;
-- up to 7 days: 4.41 / 8-14 days: 4.30 / 15+ days: 3.68
-- NULL-Unknown (недоставлені): 1.76, і в 7-8 разів вища частка без відгуку


-- ============================================================
-- 7. ГЕОГРАФІЯ — ТОП-5 ШТАТІВ ЗА ВИРУЧКОЮ
-- ============================================================

WITH customer_state_sum_count_cte AS (
    SELECT
        ocd.customer_state,
        ROUND(SUM(ooid.price::numeric), 2) AS price_sum,
        COUNT(DISTINCT ood.order_id) AS count_order
    FROM olist_customers_dataset ocd
    LEFT JOIN olist_orders_dataset ood ON ocd.customer_id = ood.customer_id
    LEFT JOIN olist_order_items_dataset ooid ON ood.order_id = ooid.order_id
    GROUP BY 1
),
customer_state_avg_delivery_date AS (
    SELECT
        ocd.customer_state,
        ROUND(AVG(ood.order_delivered_customer_date::date - ood.order_purchase_timestamp::date), 2) AS avg_delivery_date
    FROM olist_customers_dataset ocd
    LEFT JOIN olist_orders_dataset ood ON ocd.customer_id = ood.customer_id
    GROUP BY 1
),
customer_state_review_score_cte AS (
    SELECT
        ocd.customer_state,
        ROUND(AVG(oord.review_score), 2) AS avg_review_score
    FROM olist_customers_dataset ocd
    LEFT JOIN olist_orders_dataset ood ON ocd.customer_id = ood.customer_id
    LEFT JOIN olist_order_reviews_dataset oord ON ood.order_id = oord.order_id
    GROUP BY 1
)
SELECT
    cssc.customer_state,
    cssc.price_sum,
    cssc.count_order,
    csrsc.avg_review_score,
    csadd.avg_delivery_date
FROM customer_state_sum_count_cte cssc
LEFT JOIN customer_state_review_score_cte csrsc ON cssc.customer_state = csrsc.customer_state
LEFT JOIN customer_state_avg_delivery_date csadd ON cssc.customer_state = csadd.customer_state
ORDER BY 2 DESC
LIMIT 5;
-- SP домінує ($5.2M, найшвидша доставка 8.70 днів, найвища оцінка 4.17)
-- RJ vs RS: однакова швидкість доставки (~15.2 дні), різні оцінки (3.87 vs 4.13)
