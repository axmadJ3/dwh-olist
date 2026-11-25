CREATE OR REPLACE PROCEDURE etl.load_stg_orders(
    p_batch text,
    p_run_id int DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id int := p_run_id;
    v_own_run boolean := false;
    v_step_id int;
    v_loaded_at timestamptz;
    v_read int := 0;
    v_ins int := 0;
    v_rej int := 0;
    v_error text;
BEGIN
    IF v_run_id IS NULL THEN
        INSERT INTO audit.run (batch_name)
        VALUES (p_batch)
        RETURNING run_id INTO v_run_id;

        v_own_run := true;
    END IF;

    INSERT INTO audit.run_step (run_id, stage, table_name)
    VALUES (v_run_id, 'load_stg', 'orders')
    RETURNING step_id INTO v_step_id;

    SELECT started_at
    INTO v_loaded_at
    FROM audit.run
    WHERE run_id = v_run_id;

    COMMIT;

    BEGIN
        PERFORM etl.assert_prev_stage( 'load_raw', 'orders', p_batch);

        SELECT count(*) INTO v_read FROM raw.orders;

        CREATE TEMPORARY TABLE tmp_orders
        ON COMMIT DROP AS

        WITH n AS (
            SELECT
                r.load_id AS raw_load_id,
                r.source_name,
                NULLIF(lower(trim(r.order_id)), '') AS order_id,
                NULLIF(lower(trim(r.customer_id)), '') AS customer_id,
                NULLIF(lower(trim(r.order_status)), '') AS order_status,
                NULLIF(trim(r.order_purchase_timestamp), '')
                    AS order_purchase_timestamp,
                NULLIF(trim(r.order_approved_at), '')
                    AS order_approved_at,
                NULLIF(trim(r.order_delivered_carrier_date), '')
                    AS order_delivered_carrier_date,
                NULLIF(trim(r.order_delivered_customer_date), '')
                    AS order_delivered_customer_date,
                NULLIF(trim(r.order_estimated_delivery_date), '')
                    AS order_estimated_delivery_date,
                to_jsonb(r) AS source_row
            FROM raw.orders r
        )

        SELECT
            n.*,
            CASE
                WHEN order_id IS NULL
                    THEN 'ORD_ID_EMPTY'
                WHEN order_id !~ '^[0-9a-f]{32}$'
                    THEN 'ORD_ID_FORMAT'
                WHEN customer_id IS NULL
                    THEN 'ORD_CUST_ID_EMPTY'
                WHEN customer_id !~ '^[0-9a-f]{32}$'
                    THEN 'ORD_CUST_ID_FORMAT'
                WHEN order_status IS NULL
                    OR order_status NOT IN (
                        'shipped',
                        'unavailable',
                        'invoiced',
                        'created',
                        'approved',
                        'processing',
                        'delivered',
                        'canceled'
                    )
                    THEN 'ORD_STATUS_INVALID'
                WHEN order_purchase_timestamp IS NULL
                    OR order_purchase_timestamp !~
                    '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?$'
                    THEN 'ORD_PURCHASE_FORMAT'
                WHEN order_approved_at IS NOT NULL
                    AND order_approved_at !~
                    '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?$'
                    THEN 'ORD_APPROVED_FORMAT'
                WHEN order_delivered_carrier_date IS NOT NULL
                    AND order_delivered_carrier_date !~
                    '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?$'
                    THEN 'ORD_CARRIER_FORMAT'
                WHEN order_delivered_customer_date IS NOT NULL
                    AND order_delivered_customer_date !~
                    '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?$'
                    THEN 'ORD_DELIVERED_FORMAT'
                WHEN order_estimated_delivery_date IS NOT NULL
                    AND order_estimated_delivery_date !~
                    '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?$'
                    THEN 'ORD_ESTIMATED_FORMAT'
                WHEN count(*) OVER (
                    PARTITION BY order_id
                ) > 1
                    THEN 'ORD_ID_DUPLICATE'
            END AS rule_code
        FROM n;

        INSERT INTO audit.reject (
            step_id,
            table_name,
            rule_code,
            business_key,
            source_row,
            rejected_at
        )
        SELECT
            v_step_id,
            'orders',
            t.rule_code,
            t.source_row ->> 'order_id',
            t.source_row,
            v_loaded_at
        FROM tmp_orders t
        WHERE t.rule_code IS NOT NULL;
        GET DIAGNOSTICS v_rej = ROW_COUNT;

        TRUNCATE staging.orders;

        INSERT INTO staging.orders (
            order_id,
            customer_id,
            order_status,
            order_purchase_timestamp,
            order_approved_at,
            order_delivered_carrier_date,
            order_delivered_customer_date,
            order_estimated_delivery_date,
            loaded_at,
            source_name,
            row_hash
        )
        SELECT
            t.order_id::uuid,
            t.customer_id::uuid,
            t.order_status,
            t.order_purchase_timestamp::timestamp,
            t.order_approved_at::timestamp,
            t.order_delivered_carrier_date::timestamp,
            t.order_delivered_customer_date::timestamp,
            t.order_estimated_delivery_date::timestamp,
            v_loaded_at,
            t.source_name,
            staging.hash_key(
                t.order_id,
                t.customer_id,
                t.order_status,
                t.order_purchase_timestamp,
                t.order_approved_at,
                t.order_delivered_carrier_date,
                t.order_delivered_customer_date,
                t.order_estimated_delivery_date
            )
        FROM tmp_orders t
        WHERE t.rule_code IS NULL;

        GET DIAGNOSTICS v_ins = ROW_COUNT;

        IF v_read <> v_ins + v_rej THEN
            RAISE EXCEPTION
                'invariant violated: read=%, inserted=%, rejected=%',
                v_read, v_ins, v_rej;
        END IF;

    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;

        v_read := 0;
        v_ins := 0;
        v_rej := 0;
    END;

    UPDATE audit.run_step
    SET
        status = CASE
            WHEN v_error IS NULL THEN 'success'
            ELSE 'failed'
        END,
        rows_read = v_read,
        rows_inserted = v_ins,
        rows_rejected = v_rej,
        error_message = v_error,
        finished_at = clock_timestamp()
    WHERE step_id = v_step_id;

    IF v_own_run THEN
        UPDATE audit.run
        SET
            status = CASE
                WHEN v_error IS NULL THEN 'success'
                ELSE 'failed'
            END,
            finished_at = clock_timestamp()
        WHERE run_id = v_run_id;
    END IF;
    COMMIT;

    IF v_error IS NOT NULL AND v_own_run THEN
        RAISE EXCEPTION
            'load_stg_orders failed: %',
            v_error;
    END IF;
END;
$$;
