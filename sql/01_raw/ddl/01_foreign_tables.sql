CREATE FOREIGN TABLE ext.olist_orders_dataset (
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
    filename '/data/snapshots/batch_001_initial/olist_orders_dataset.csv',
    format 'csv', 
    header 'true'
);
