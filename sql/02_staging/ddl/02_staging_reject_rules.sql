INSERT INTO audit.reject_rule (
    rule_code, 
    table_name, 
    column_name, 
    description, 
    action) 
VALUES
 ('CUST_ID_EMPTY', 'customers', 'customer_id', 'customer_id is empty', 'reject'),
 ('CUST_ID_FORMAT', 'customers', 'customer_id', 'customer_id is not 32 hex characters', 'reject'),
 ('CUST_UID_FORMAT', 'customers', 'customer_unique_id', 'customer_unique_id is empty or malformed', 'reject'),
 ('CUST_ZIP_FORMAT', 'customers', 'customer_zip_code_prefix', 'zip prefix is not exactly 5 digits', 'reject'),
 ('CUST_CITY_EMPTY', 'customers', 'customer_city', 'city is empty', 'reject'),
 ('CUST_STATE_FORMAT', 'customers', 'customer_state', 'state is not 2 letters', 'reject'),
 ('CUST_ID_DUPLICATE', 'customers', 'customer_id', 'customer_id occurs more than once', 'reject')
ON CONFLICT (rule_code) DO UPDATE
   SET description = EXCLUDED.description, action = EXCLUDED.action;
