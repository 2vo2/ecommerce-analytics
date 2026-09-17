-- ============================================================
-- ecommerce-analytics — Перевірка якості даних
-- Датасет: Brazilian E-Commerce Public Dataset by Olist (Kaggle)
-- ============================================================
-- 9 звʼязаних таблиць: orders, order_items, order_payments,
-- order_reviews, customers, products, sellers, geolocation,
-- product_category_name_translation
-- ============================================================


-- ============================================================
-- 1. ПЕРЕВІРКА КІЛЬКОСТІ РЯДКІВ (по кожній таблиці)
-- Використовується для виявлення дубльованих імпортів —
-- звіряємо з офіційною кількістю рядків, вказаною на Kaggle.
-- ============================================================

SELECT 'orders' AS tbl, COUNT(*) FROM olist_orders_dataset
UNION ALL
SELECT 'order_items', COUNT(*) FROM olist_order_items_dataset
UNION ALL
SELECT 'order_payments', COUNT(*) FROM olist_order_payments_dataset
UNION ALL
SELECT 'order_reviews', COUNT(*) FROM olist_order_reviews_dataset
UNION ALL
SELECT 'customers', COUNT(*) FROM olist_customers_dataset
UNION ALL
SELECT 'products', COUNT(*) FROM olist_products_dataset
UNION ALL
SELECT 'sellers', COUNT(*) FROM olist_sellers_dataset
UNION ALL
SELECT 'geolocation', COUNT(*) FROM olist_geolocation_dataset
UNION ALL
SELECT 'category_translation', COUNT(*) FROM product_category_name_translation;

-- Виправлення застосоване там, де знайдено дубльовані імпорти
-- (order_items, order_payments, customers були задубльовані
-- рівно у 4 рази; order_reviews мала суміш дублів і "побитих"
-- рядків через невдалу спробу імпорту):
--
-- TRUNCATE TABLE olist_order_items_dataset;
-- TRUNCATE TABLE olist_order_payments_dataset;
-- TRUNCATE TABLE olist_customers_dataset;
-- TRUNCATE TABLE olist_order_reviews_dataset;
-- (з наступним одноразовим чистим переімпортом кожного CSV)


-- ============================================================
-- 2. ПЕРЕВІРКА ТИПІВ КОЛОНОК
-- Виявила, що review_score імпортувався як character varying
-- замість integer (побічний ефект проблемного імпорту CSV).
-- ============================================================

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'olist_order_reviews_dataset';


-- ============================================================
-- 3. ПРОПУСКИ ТА БАЗОВІ АНОМАЛІЇ (приклад патерну перевірки)
-- ============================================================

SELECT
    COUNT(*) FILTER (WHERE payment_value <= 0) AS invalid_payment_value,
    COUNT(*) FILTER (WHERE payment_installments < 0) AS invalid_installments
FROM olist_order_payments_dataset;

SELECT COUNT(*)
FROM olist_order_reviews_dataset
WHERE review_score IS NULL
   OR review_score NOT BETWEEN 1 AND 5;


-- ============================================================
-- 4. ІНДЕКСИ
-- Необхідні, щоб перевірки цілісності нижче виконувались за
-- прийнятний час (NOT EXISTS на ~100 тис. рядків без індексу
-- на зовнішньому ключі практично не завершувався).
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_items_order_id ON olist_order_items_dataset(order_id);
CREATE INDEX IF NOT EXISTS idx_payments_order_id ON olist_order_payments_dataset(order_id);
CREATE INDEX IF NOT EXISTS idx_reviews_order_id ON olist_order_reviews_dataset(order_id);


-- ============================================================
-- 5. ЦІЛІСНІСТЬ ЗВʼЯЗКІВ — orders як центральна fact-таблиця
-- Перевірено в обидва боки для кожної дочірньої таблиці.
-- ============================================================

-- orders -> {order_items, order_payments, order_reviews}, все в одному запиті
SELECT
    COUNT(*) FILTER (WHERE NOT EXISTS (
        SELECT 1 FROM olist_order_items_dataset oi WHERE oi.order_id = o.order_id
    )) AS orders_without_items,
    COUNT(*) FILTER (WHERE NOT EXISTS (
        SELECT 1 FROM olist_order_payments_dataset op WHERE op.order_id = o.order_id
    )) AS orders_without_payments,
    COUNT(*) FILTER (WHERE NOT EXISTS (
        SELECT 1 FROM olist_order_reviews_dataset r WHERE r.order_id = o.order_id
    )) AS orders_without_reviews
FROM olist_orders_dataset o;
-- Результат: 775 / 1 / 768 — прийнятно (скасовані замовлення,
-- відсутній запис про оплату, відгук не залишили — жодне
-- з цього не є помилкою даних)

-- зворотний напрямок: дочірня таблиця -> orders (пошук "сиріт")
SELECT COUNT(*) FROM olist_order_items_dataset oi
WHERE NOT EXISTS (SELECT 1 FROM olist_orders_dataset o WHERE o.order_id = oi.order_id);

SELECT COUNT(*) FROM olist_order_payments_dataset op
WHERE NOT EXISTS (SELECT 1 FROM olist_orders_dataset o WHERE o.order_id = op.order_id);

SELECT COUNT(*) FROM olist_order_reviews_dataset r
WHERE NOT EXISTS (SELECT 1 FROM olist_orders_dataset o WHERE o.order_id = r.order_id);
-- Результат: 0 / 0 / 0 — жодних сиріт

-- orders <-> customers
SELECT COUNT(*) FROM olist_customers_dataset c
WHERE NOT EXISTS (SELECT 1 FROM olist_orders_dataset o WHERE o.customer_id = c.customer_id);

SELECT COUNT(*) FROM olist_orders_dataset o
WHERE NOT EXISTS (SELECT 1 FROM olist_customers_dataset c WHERE c.customer_id = o.customer_id);
-- Результат: 0 / 0

-- order_items <-> products
SELECT COUNT(*) FROM olist_order_items_dataset oi
WHERE NOT EXISTS (SELECT 1 FROM olist_products_dataset p WHERE p.product_id = oi.product_id);
-- Результат: 0

-- order_items <-> sellers
SELECT COUNT(*) FROM olist_order_items_dataset oi
WHERE NOT EXISTS (SELECT 1 FROM olist_sellers_dataset s WHERE s.seller_id = oi.seller_id);
-- Результат: 0


-- ============================================================
-- 6. УНІКАЛЬНІСТЬ ПЕРВИННИХ / КОМПОЗИТНИХ КЛЮЧІВ
-- ============================================================

-- order_items: природний первинний ключ = (order_id, order_item_id)
SELECT order_id, order_item_id, COUNT(*)
FROM olist_order_items_dataset
GROUP BY order_id, order_item_id
HAVING COUNT(*) > 1;
-- Результат: 0 рядків — підтверджено, що це справжній первинний ключ

-- order_reviews: сам review_id НЕ є надійним первинним ключем
-- (Olist подекуди перевикористовує той самий review_id для
-- кількох order_id з ідентичним текстом відгуку й тими ж датами)
SELECT COUNT(DISTINCT review_id) FROM olist_order_reviews_dataset;
-- 98410 унікальних review_id проти 99224 рядків загалом — 814 "дублікатів"

SELECT review_id, COUNT(*)
FROM olist_order_reviews_dataset
GROUP BY review_id
HAVING COUNT(*) > 1
LIMIT 10;

-- підтверджено: справжній композитний ключ — (review_id, order_id)
SELECT review_id, order_id, COUNT(*)
FROM olist_order_reviews_dataset
GROUP BY review_id, order_id
HAVING COUNT(*) > 1;
-- Результат: 0 рядків — унікальність підтверджена
