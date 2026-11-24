CREATE TABLE staging.customers (
    customer_id uuid PRIMARY KEY,
    customer_unique_id uuid NOT NULL,
    customer_zip_code_prefix char(5) NOT NULL
        CHECK (customer_zip_code_prefix ~ '^[0-9]{5}$'),
    customer_city text NOT NULL,
    customer_state char(2) NOT NULL
        CHECK (customer_state ~ '^[A-Z]{2}$'),
    raw_load_id int NOT NULL,
    stg_load_id int NOT NULL,
    loaded_at timestamptz NOT NULL,
    source_name text NOT NULL,
    row_hash varchar(32) NOT NULL
);

CREATE TABLE staging.orders (
    order_id uuid PRIMARY KEY,
    customer_id uuid NOT NULL,
    order_status text NOT NULL
        CHECK (order_status IN
            ('shipped',
            'unavailable',
            'invoiced',
            'created',
            'approved',
            'processing',
            'delivered',
            'canceled')),
    order_purchase_timestamp timestamp NOT NULL,
    order_approved_at timestamp,
    order_delivered_carrier_date timestamp,
    order_delivered_customer_date timestamp,
    order_estimated_delivery_date timestamp,
    raw_load_id int NOT NULL,
    stg_load_id int NOT NULL,
    loaded_at timestamptz NOT NULL,
    source_name text NOT NULL,
    row_hash varchar(32) NOT NULL
);

CREATE TABLE staging.order_items (
    order_id uuid NOT NULL,
    order_item_id smallint NOT NULL
        CHECK (order_item_id >= 1),
    product_id uuid NOT NULL,
    seller_id uuid NOT NULL,
    shipping_limit_date timestamp NOT NULL,
    price numeric(10,2) NOT NULL CHECK (price >= 0),
    freight_value numeric(10,2) NOT NULL CHECK (freight_value >= 0),
    raw_load_id int NOT NULL,
    stg_load_id int NOT NULL,
    loaded_at timestamptz NOT NULL,
    source_name text NOT NULL,
    row_hash varchar(32) NOT NULL,

    PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE staging.order_payments (
    order_id uuid NOT NULL,
    payment_sequential smallint NOT NULL
        CHECK (payment_sequential >= 1),
    payment_type text NOT NULL 
        CHECK (payment_type IN
            ('credit_card',
            'boleto',
            'voucher',
            'debit_card',
            'not_defined')),
    payment_installments smallint NOT NULL
        CHECK (payment_installments >= 0),
    payment_value numeric(10,2) NOT NULL
        CHECK (payment_value >= 0),
    raw_load_id int NOT NULL,
    stg_load_id int NOT NULL,
    loaded_at timestamptz NOT NULL,
    source_name text NOT NULL,
    row_hash varchar(32) NOT NULL,

    PRIMARY KEY (order_id, payment_sequential)
);

CREATE TABLE staging.products (
    product_id uuid PRIMARY KEY,
    product_category_name text,
    product_name_length smallint
        CHECK (product_name_length >= 0),
    product_description_length smallint
        CHECK (product_description_length >= 0),
    product_photos_qty smallint
        CHECK (product_photos_qty >= 0),
    product_weight_g int 
        CHECK (product_weight_g >= 0),
    product_length_cm smallint
        CHECK (product_length_cm >= 0),
    product_height_cm smallint 
        CHECK (product_height_cm >= 0),
    product_width_cm smallint
        CHECK (product_width_cm >= 0),
    raw_load_id int NOT NULL,
    stg_load_id int NOT NULL,
    loaded_at timestamptz NOT NULL,
    source_name text NOT NULL,
    row_hash varchar(32) NOT NULL
);

CREATE TABLE staging.sellers (
    seller_id uuid PRIMARY KEY,
    seller_zip_code_prefix char(5) NOT NULL
        CHECK (seller_zip_code_prefix ~ '^[0-9]{5}$'),
    seller_city text,
    seller_state char(2) NOT NULL
        CHECK (seller_state ~ '^[A-Z]{2}$'),
    raw_load_id int NOT NULL,
    stg_load_id int NOT NULL,
    loaded_at timestamptz NOT NULL,
    source_name text NOT NULL,
    row_hash varchar(32) NOT NULL
);

CREATE TABLE staging.product_category_name (
    product_category_name text PRIMARY KEY,
    product_category_name_english text NOT NULL,
    raw_load_id int NOT NULL,
    stg_load_id int NOT NULL,
    loaded_at timestamptz NOT NULL,
    source_name text NOT NULL,
    row_hash varchar(32) NOT NULL
);

CREATE TABLE staging.order_reviews (
    review_id uuid NOT NULL,
    order_id uuid NOT NULL,
    review_score smallint NOT NULL 
        CHECK (review_score BETWEEN 1 AND 5),
    review_comment_title text,
    review_comment_message text,
    review_creation_date timestamp NOT NULL,
    review_answer_timestamp timestamp,
    raw_load_id int NOT NULL,
    stg_load_id int NOT NULL,
    loaded_at timestamptz NOT NULL,
    source_name text NOT NULL,
    row_hash varchar(32) NOT NULL,

    PRIMARY KEY (review_id, order_id)
);
