INSERT INTO audit.reject_rule (rule_code, table_name, column_name, description, action) VALUES
 -- customers
 ('CUST_ID_EMPTY', 'customers', 'customer_id', 'customer_id отсутствует', 'reject'),
 ('CUST_ID_FORMAT', 'customers', 'customer_id', 'customer_id не состоит из 32 шестнадцатеричных символов', 'reject'),
 ('CUST_UID_FORMAT', 'customers', 'customer_unique_id', 'customer_unique_id отсутствует или не состоит из 32 шестнадцатеричных символов', 'reject'),
 ('CUST_ZIP_LPAD', 'customers', 'customer_zip_code_prefix', 'zip из 1-4 цифр дополняется нулями слева до 5',  'fix'),
 ('CUST_ZIP_FORMAT', 'customers', 'customer_zip_code_prefix', 'Почтовый индекс отсутствует или не состоит ровно из 5 цифр', 'reject'),
 ('CUST_CITY_EMPTY', 'customers', 'customer_city', 'customer_city пуст', 'reject'),
 ('CUST_STATE_FORMAT', 'customers', 'customer_state', 'Код штата отсутствует или не состоит из 2 букв', 'reject'),
 ('CUST_ID_DUPLICATE', 'customers', 'customer_id', 'customer_id встречается более одного раза', 'reject'),

 -- orders
 ('ORD_ID_EMPTY', 'orders', 'order_id', 'order_id отсутствует', 'reject'),
 ('ORD_ID_FORMAT', 'orders', 'order_id', 'order_id отсутствует или не состоит из 32 шестнадцатеричных символов', 'reject'),
 ('ORD_CUST_ID_EMPTY', 'orders', 'customer_id', 'customer_id отсутствует', 'reject'),
 ('ORD_CUST_ID_FORMAT', 'orders', 'customer_id', 'customer_id не состоит из 32 шестнадцатеричных символов', 'reject'),
 ('ORD_STATUS_INVALID', 'orders', 'order_status', 'Статус заказа отсутствует или не входит в список допустимых значений', 'reject'),
 ('ORD_PURCHASE_FORMAT', 'orders', 'order_purchase_timestamp', 'Время оформления заказа отсутствует или имеет неверный формат даты и времени', 'reject'),
 ('ORD_APPROVED_FORMAT', 'orders', 'order_approved_at', 'Дата подтверждения заказа указана, но имеет неверный формат даты и времени', 'reject'),
 ('ORD_CARRIER_FORMAT', 'orders', 'order_delivered_carrier_date', 'Дата передачи заказа перевозчику указана, но имеет неверный формат даты и времени', 'reject'),
 ('ORD_DELIVERED_FORMAT', 'orders', 'order_delivered_customer_date', 'Дата доставки заказа покупателю указана, но имеет неверный формат даты и времени', 'reject'),
 ('ORD_ESTIMATED_FORMAT', 'orders', 'order_estimated_delivery_date', 'Предполагаемая дата доставки указана, но имеет неверный формат даты и времени', 'reject'),
 ('ORD_ID_DUPLICATE', 'orders', 'order_id', 'order_id встречается более одного раза', 'reject'),

 -- order_items
 ('ITEM_ORDER_ID_EMPTY', 'order_items', 'order_id', 'order_id отсутствует', 'reject'),
 ('ITEM_ORDER_ID_FORMAT', 'order_items', 'order_id', 'order_id не состоит из 32 шестнадцатеричных символов', 'reject'),
 ('ITEM_NO_EMPTY', 'order_items', 'order_item_id', 'order_item_id отсутствует', 'reject'),
 ('ITEM_NO_FORMAT', 'order_items', 'order_item_id', 'order_item_id отсутствует или не является целым числом', 'reject'),
 ('ITEM_NO_RANGE', 'order_items', 'order_item_id', 'order_item_id меньше 1 или не помещается в тип smallint', 'reject'),
 ('ITEM_PRODUCT_ID_EMPTY', 'order_items', 'product_id', 'product_id отсутствует', 'reject'),
 ('ITEM_PRODUCT_ID_FORMAT', 'order_items', 'product_id', 'product_id отсутствует или не состоит из 32 шестнадцатеричных символов', 'reject'),
 ('ITEM_SELLER_ID_EMPTY', 'order_items', 'seller_id', 'seller_id отсутствует', 'reject'),
 ('ITEM_SELLER_ID_FORMAT', 'order_items', 'seller_id', 'seller_id отсутствует или не состоит из 32 шестнадцатеричных символов', 'reject'),
 ('ITEM_SHIPLIM_FORMAT', 'order_items', 'shipping_limit_date', 'Крайний срок отправки отсутствует или имеет неверный формат даты и времени', 'reject'),
 ('ITEM_PRICE_FORMAT', 'order_items', 'price', 'Цена отсутствует или не является числом', 'reject'),
 ('ITEM_PRICE_RANGE', 'order_items', 'price', 'Цена отрицательная или не помещается в тип numeric(10,2)', 'reject'),
 ('ITEM_FREIGHT_FORMAT', 'order_items', 'freight_value', 'Стоимость доставки отсутствует или не является числом', 'reject'),
 ('ITEM_FREIGHT_RANGE', 'order_items', 'freight_value', 'Стоимость доставки отрицательная или не помещается в тип numeric(10,2)', 'reject'),
 ('ITEM_KEY_DUPLICATE', 'order_items', 'order_id, order_item_id', 'Комбинация (order_id, order_item_id) встречается более одного раза', 'reject'),

 -- order_payments
 ('PAY_ORDER_ID_FORMAT', 'order_payments', 'order_id', 'order_id отсутствует или не состоит из 32 шестнадцатеричных символов', 'reject'),
 ('PAY_SEQ_FORMAT', 'order_payments', 'payment_sequential', 'payment_sequential отсутствует или не является целым числом', 'reject'),
 ('PAY_SEQ_RANGE', 'order_payments', 'payment_sequential', 'payment_sequential меньше 1 или не помещается в тип smallint', 'reject'),
 ('PAY_TYPE_INVALID', 'order_payments', 'payment_type', 'Тип оплаты отсутствует или не входит в список допустимых значений', 'reject'),
 ('PAY_INST_FORMAT', 'order_payments', 'payment_installments', 'Количество платежных частей отсутствует или не является целым числом', 'reject'),
 ('PAY_INST_RANGE', 'order_payments', 'payment_installments', 'Количество платежных частей отрицательное или не помещается в тип smallint', 'reject'),
 ('PAY_VALUE_FORMAT', 'order_payments', 'payment_value', 'Сумма платежа отсутствует или не является числом', 'reject'),
 ('PAY_VALUE_RANGE', 'order_payments', 'payment_value', 'Сумма платежа отрицательная или не помещается в тип numeric(10,2)', 'reject'),
 ('PAY_KEY_DUPLICATE', 'order_payments', 'order_id, payment_sequential', 'Комбинация (order_id, payment_sequential) встречается более одного раза', 'reject'),

 -- products
 ('PROD_ID_FORMAT', 'products', 'product_id', 'product_id отсутствует или не состоит из 32 шестнадцатеричных символов', 'reject'),
 ('PROD_ID_DUPLICATE', 'products', 'product_id', 'product_id встречается более одного раза', 'reject'),
 ('PROD_NAMELEN_FORMAT', 'products', 'product_name_length', 'product_name_length указано, но не является целым числом', 'reject'),
 ('PROD_NAMELEN_RANGE', 'products', 'product_name_length', 'product_name_length отрицательное или не помещается в тип smallint', 'reject'),
 ('PROD_DESCLEN_FORMAT', 'products', 'product_description_length', 'product_description_length указано, но не является целым числом', 'reject'),
 ('PROD_DESCLEN_RANGE', 'products', 'product_description_length', 'product_description_length отрицательное или не помещается в тип smallint', 'reject'),
 ('PROD_PHOTOS_FORMAT', 'products', 'product_photos_qty', 'product_photos_qty указано, но не является целым числом', 'reject'),
 ('PROD_PHOTOS_RANGE', 'products', 'product_photos_qty', 'product_photos_qty отрицательное или не помещается в тип smallint', 'reject'),
 ('PROD_WEIGHT_FORMAT', 'products', 'product_weight_g', 'product_weight_g указано, но не является целым числом', 'reject'),
 ('PROD_WEIGHT_RANGE', 'products', 'product_weight_g', 'product_weight_g отрицательное или не помещается в тип integer', 'reject'),
 ('PROD_LENGTH_FORMAT', 'products', 'product_length_cm', 'product_length_cm указано, но не является целым числом', 'reject'),
 ('PROD_LENGTH_RANGE', 'products', 'product_length_cm', 'product_length_cm отрицательное или не помещается в тип smallint', 'reject'),
 ('PROD_HEIGHT_FORMAT', 'products', 'product_height_cm', 'product_height_cm указано, но не является целым числом', 'reject'),
 ('PROD_HEIGHT_RANGE', 'products', 'product_height_cm', 'product_height_cm отрицательное или не помещается в тип smallint', 'reject'),
 ('PROD_WIDTH_FORMAT', 'products', 'product_width_cm', 'product_width_cm указано, но не является целым числом', 'reject'),
 ('PROD_WIDTH_RANGE', 'products', 'product_width_cm', 'product_width_cm отрицательное или не помещается в тип smallint', 'reject'),

 -- sellers
 ('SELL_ID_FORMAT', 'sellers', 'seller_id', 'seller_id отсутствует или не состоит из 32 шестнадцатеричных символов', 'reject'),
 ('SELL_ID_DUPLICATE', 'sellers', 'seller_id', 'seller_id встречается более одного раза', 'reject'),
 ('SELL_ZIP_FORMAT', 'sellers', 'seller_zip_code_prefix', 'Почтовый индекс отсутствует или не состоит ровно из 5 цифр', 'reject'),
 ('SELL_STATE_FORMAT', 'sellers', 'seller_state', 'Код штата отсутствует или не состоит из 2 букв', 'reject'),

 -- product_category_name
 ('CAT_NAME_FORMAT', 'product_category_name', 'product_category_name', 'Название категории отсутствует', 'reject'),
 ('CAT_NAME_EN_FORMAT', 'product_category_name', 'product_category_name_english', 'Английское название категории отсутствует', 'reject'),
 ('CAT_NAME_DUPLICATE', 'product_category_name', 'product_category_name', 'Название категории встречается более одного раза', 'reject'),

 -- order_reviews
 ('REV_ID_FORMAT', 'order_reviews', 'review_id', 'review_id отсутствует или не состоит из 32 шестнадцатеричных символов', 'reject'),
 ('REV_ORDER_ID_FORMAT', 'order_reviews', 'order_id', 'order_id отсутствует или не состоит из 32 шестнадцатеричных символов', 'reject'),
 ('REV_SCORE_FORMAT', 'order_reviews', 'review_score', 'Оценка отсутствует или не является целым числом', 'reject'),
 ('REV_SCORE_RANGE', 'order_reviews', 'review_score', 'Оценка не входит в диапазон от 1 до 5', 'reject'),
 ('REV_CREATED_FORMAT', 'order_reviews', 'review_creation_date', 'Дата создания отзыва отсутствует или имеет неверный формат даты и времени', 'reject'),
 ('REV_ANSWER_FORMAT', 'order_reviews', 'review_answer_timestamp', 'Время ответа на отзыв указано, но имеет неверный формат даты и времени', 'reject'),
 ('REV_KEY_DUPLICATE', 'order_reviews', 'review_id, order_id', 'Комбинация (review_id, order_id) встречается более одного раза', 'reject')
ON CONFLICT (rule_code) DO UPDATE
   SET table_name  = EXCLUDED.table_name,
       column_name = EXCLUDED.column_name,
       description = EXCLUDED.description,
       action      = EXCLUDED.action;
