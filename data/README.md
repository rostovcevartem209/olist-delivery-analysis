# Данные проекта

По ТЗ используется Brazilian E-Commerce Public Dataset by Olist:
https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce

## Статус

Данные ещё не скачаны. Лицензия, версия набора и доступность файлов будут проверены при получении данных. Дата скачивания, количество строк и диапазоны дат пока не определены.

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

Исходные файлы будут храниться локально в `data/raw/` без изменений. Содержимое каталога данных, кроме этого README, исключено из Git через `.gitignore`.

После скачивания здесь необходимо зафиксировать дату, версию (если указана), лицензию и точную инструкцию повторного получения данных. После загрузки в PostgreSQL — количество строк и диапазоны дат.
