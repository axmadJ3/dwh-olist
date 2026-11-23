CREATE TABLE staging.customers (
    customer_id uuid PRIMARY KEY,
    customer_unique_id uuid NOT NULL,
    customer_zip_code_prefix char(5) NOT NULL CHECK (customer_zip_code_prefix ~ '^[0-9]{5}$'),
    customer_city text NOT NULL,
    customer_state char(2) NOT NULL CHECK (customer_state ~ '^[A-Z]{2}$'),
    raw_load_id int NOT NULL,
    stg_load_id int NOT NULL,
    loaded_at timestamptz NOT NULL,
    source_name text NOT NULL,
    row_hash varchar(32) NOT NULL
);
