CREATE TABLE ods.ods_customer (
    customer_id uuid PRIMARY KEY,
    customer_unique_id uuid NOT NULL,
    customer_zip_code_prefix char(5) NOT NULL,
    customer_city text NOT NULL,
    customer_state char(2) NOT NULL,
    row_hash varchar(32) NOT NULL,
    created_step_id int NOT NULL,
    updated_step_id int NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    is_deleted boolean NOT NULL DEFAULT false,
    deleted_at timestamptz,

    CONSTRAINT ods_customer_deleted_consistent
        CHECK (is_deleted = (deleted_at IS NOT NULL))
);

CREATE TABLE ods.ods_order (
    order_id uuid PRIMARY KEY,
    customer_id uuid NOT NULL,
    order_status text NOT NULL,
    order_purchase_timestamp timestamp NOT NULL,
    order_approved_at timestamp,
    order_delivered_carrier_date timestamp,
    order_delivered_customer_date timestamp,
    order_estimated_delivery_date timestamp,
    row_hash varchar(32) NOT NULL,
    created_step_id int NOT NULL,
    updated_step_id int NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    is_deleted boolean NOT NULL DEFAULT false,
    deleted_at timestamptz,

    CONSTRAINT ods_order_deleted_consistent
        CHECK (is_deleted = (deleted_at IS NOT NULL))
);

CREATE TABLE ods.ods_order_item (
    order_id uuid NOT NULL,
    order_item_id smallint NOT NULL,
    product_id uuid NOT NULL,
    seller_id uuid NOT NULL,
    shipping_limit_date timestamp NOT NULL,
    price numeric(10,2) NOT NULL,
    freight_value numeric(10,2) NOT NULL,
    row_hash varchar(32) NOT NULL,
    created_step_id int NOT NULL,
    updated_step_id int NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    is_deleted boolean NOT NULL DEFAULT false,
    deleted_at timestamptz,

    PRIMARY KEY (order_id, order_item_id),
    CONSTRAINT ods_order_item_deleted_consistent
        CHECK (is_deleted = (deleted_at IS NOT NULL))
);

CREATE TABLE ods.ods_order_payment (
    order_id uuid NOT NULL,
    payment_sequential smallint NOT NULL,
    payment_type text NOT NULL,
    payment_installments smallint NOT NULL,
    payment_value numeric(10,2) NOT NULL,
    row_hash varchar(32) NOT NULL,
    created_step_id int NOT NULL,
    updated_step_id int NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    is_deleted boolean NOT NULL DEFAULT false,
    deleted_at timestamptz,

    PRIMARY KEY (order_id, payment_sequential),
    CONSTRAINT ods_order_payment_deleted_consistent
        CHECK (is_deleted = (deleted_at IS NOT NULL))
);

CREATE TABLE ods.ods_product (
    product_id uuid PRIMARY KEY,
    product_category_name text,
    product_name_length smallint,
    product_description_length smallint,
    product_photos_qty smallint,
    product_weight_g int,
    product_length_cm smallint,
    product_height_cm smallint,
    product_width_cm smallint,
    row_hash varchar(32) NOT NULL,
    created_step_id int NOT NULL,
    updated_step_id int NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    is_deleted boolean NOT NULL DEFAULT false,
    deleted_at timestamptz,

    CONSTRAINT ods_product_deleted_consistent
        CHECK (is_deleted = (deleted_at IS NOT NULL))
);

CREATE TABLE ods.ods_seller (
    seller_id uuid PRIMARY KEY,
    seller_zip_code_prefix char(5) NOT NULL,
    seller_city text NOT NULL,
    seller_state char(2) NOT NULL,
    row_hash varchar(32) NOT NULL,
    created_step_id int NOT NULL,
    updated_step_id int NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    is_deleted boolean NOT NULL DEFAULT false,
    deleted_at timestamptz,

    CONSTRAINT ods_seller_deleted_consistent
        CHECK (is_deleted = (deleted_at IS NOT NULL))
);

CREATE TABLE ods.ods_product_category_name (
    product_category_name text PRIMARY KEY,
    product_category_name_english text NOT NULL,
    row_hash varchar(32) NOT NULL,
    created_step_id int NOT NULL,
    updated_step_id int NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    is_deleted boolean NOT NULL DEFAULT false,
    deleted_at timestamptz,

    CONSTRAINT ods_product_category_name_deleted_consistent
        CHECK (is_deleted = (deleted_at IS NOT NULL))
);

CREATE TABLE ods.ods_order_reviews (
    review_id uuid NOT NULL,
    order_id uuid NOT NULL,
    review_score smallint NOT NULL 
        CHECK (review_score BETWEEN 1 AND 5),
    review_comment_title text,
    review_comment_message text,
    review_creation_date timestamp NOT NULL,
    review_answer_timestamp timestamp,
    row_hash varchar(32) NOT NULL,
    created_step_id int NOT NULL,
    updated_step_id int NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    is_deleted boolean NOT NULL DEFAULT false,
    deleted_at timestamptz,

    PRIMARY KEY (review_id, order_id),
    CONSTRAINT ods_order_reviews_deleted_consistent
        CHECK (is_deleted = (deleted_at IS NOT NULL))
);
