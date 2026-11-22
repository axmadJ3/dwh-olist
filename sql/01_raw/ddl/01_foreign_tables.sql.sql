CREATE FOREIGN TABLE raw.olist_customers_dataset (
    customer_id text,
    customer_unique_id text,
    customer_zip_code_prefix text,
    customer_city text,
    customer_state text
) SERVER olist
OPTIONS (
    filename '/data/csv/olist_customers_dataset.csv',
    format 'csv',
    header 'true'
);

CREATE FOREIGN TABLE raw.olist_orders_dataset (
    order_id text,
    customer_id text,
    order_status text,
    order_purchase_timestamp text,
    order_approved_at text,
    order_delivered_carrier_date text,
    order_delivered_customer_date text,
    order_estimated_delivery_date text
) SERVER olist
OPTIONS (
    filename '/data/csv/olist_orders_dataset.csv',
    format 'csv',
    header 'true'
);

CREATE FOREIGN TABLE raw.olist_sellers_dataset (
    seller_id text,
    seller_zip_code_prefix text,
    seller_city text,
    seller_state text
) SERVER olist
OPTIONS (
    filename '/data/csv/olist_sellers_dataset.csv',
    format 'csv',
    header 'true'
);

CREATE FOREIGN TABLE raw.olist_products_dataset (
    product_id text,
    product_category_name text,
    product_name_lenght text,
    product_description_lenght text,
    product_photos_qty text,
    product_weight_g text,
    product_length_cm text,
    product_height_cm text,
    product_width_cm text
) SERVER olist
OPTIONS (
    filename '/data/csv/olist_products_dataset.csv',
    format 'csv',
    header 'true'
);

CREATE FOREIGN TABLE raw.product_category_name_translation (
    product_category_name text,
    product_category_name_english text
) SERVER olist
OPTIONS (
    filename '/data/csv/product_category_name_translation.csv',
    format 'csv',
    header 'true'
);

CREATE FOREIGN TABLE raw.olist_order_reviews_dataset (
    review_id text,
    order_id text,
    review_score text,
    review_comment_title text,
    review_comment_message text,
    review_creation_date text,
    review_answer_timestamp text
) SERVER olist
OPTIONS (
    filename '/data/csv/olist_order_reviews_dataset.csv',
    format 'csv',
    header 'true'
);

CREATE FOREIGN TABLE raw.olist_geolocation_dataset (
    geolocation_zip_code_prefix text,
    geolocation_lat text,
    geolocation_lng text,
    geolocation_city text,
    geolocation_state text
) SERVER olist
OPTIONS (
    filename '/data/csv/olist_geolocation_dataset.csv',
    format 'csv',
    header 'true'
);

CREATE FOREIGN TABLE raw.olist_order_items_dataset (
    order_id text,
    order_item_id text,
    product_id text,
    seller_id text,
    shipping_limit_date text,
    price text,
    freight_value text
) SERVER olist
OPTIONS (
    filename '/data/csv/olist_order_items_dataset.csv',
    format 'csv',
    header 'true'
);

CREATE FOREIGN TABLE raw.olist_order_payments_dataset (
    order_id text,
    payment_sequential text,
    payment_type text,
    payment_installments text,
    payment_value text
) SERVER olist
OPTIONS (
    filename '/data/csv/olist_order_payments_dataset.csv',
    format 'csv',
    header 'true'
);
