CREATE TABLE raw.orders (
    order_id text, 
    customer_id text, 
    order_status text,
    order_purchase_timestamp text, 
    order_approved_at text,
    order_delivered_carrier_date text, 
    order_delivered_customer_date text,
    order_estimated_delivery_date text,
    load_id int NOT NULL,
    loaded_at timestamptz NOT NULL,
    source_name text NOT NULL
);
