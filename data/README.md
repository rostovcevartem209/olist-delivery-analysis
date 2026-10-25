# Данные проекта

По ТЗ используется Brazilian E-Commerce Public Dataset by Olist:
https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce

## Статус

Данные скачаны 24 октября 2026 года в ходе работы над проектом и распакованы в data/raw. Семь обязательных CSV загружены пользователем через pgAdmin; количества строк сверены с файлами и приведены в ../reports/data_quality.md. Лицензия и версия набора ещё требуют проверки по источнику; диапазоны дат будут проверены отдельно.

## Необходимые файлы

- `olist_orders_dataset.csv`
- `olist_order_items_dataset.csv`
- `olist_customers_dataset.csv`
- `olist_sellers_dataset.csv`
- `olist_products_dataset.csv`
- `product_category_name_translation.csv`
- `olist_order_reviews_dataset.csv`

Платежи и геолокация не входят в первоначальный объём анализа.

## Хранение

Исходные файлы хранятся локально в `data/raw/` без изменений. Содержимое каталога данных, кроме этого README, исключено из Git через `.gitignore`.

Для получения файлов откройте страницу источника выше, скачайте ZIP всего набора (не отдельного CSV) и распакуйте его в data/raw. Файлы payments и geolocation могут оставаться локально, но в первоначальную загрузку не входят. Повторяемая загрузка подготовлена в sql/02_load_data.sql; инструкция и статус её проверки — в [sql/README.md](../sql/README.md).
