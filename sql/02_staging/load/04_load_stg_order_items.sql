
CREATE OR REPLACE PROCEDURE etl.load_stg_order_items(
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
    VALUES (v_run_id, 'load_stg', 'order_items')
    RETURNING step_id INTO v_step_id;

    SELECT started_at
    INTO v_loaded_at
    FROM audit.run
    WHERE run_id = v_run_id;

    COMMIT;

    BEGIN
        PERFORM etl.assert_prev_stage('load_raw', 'order_items', p_batch);

        SELECT count(*) INTO v_read FROM raw.order_items;

        CREATE TEMPORARY TABLE tmp_order_items
        ON COMMIT DROP AS

        WITH n AS (
            SELECT
                r.load_id AS raw_load_id,
                r.source_name,
                NULLIF(lower(trim(r.order_id)), '')
                    AS order_id,
                NULLIF(trim(r.order_item_id), '')
                    AS order_item_id,
                NULLIF(lower(trim(r.product_id)), '')
                    AS product_id,
                NULLIF(lower(trim(r.seller_id)), '')
                    AS seller_id,
                NULLIF(trim(r.shipping_limit_date), '')
                    AS shipping_limit_date,
                NULLIF(trim(r.price), '')
                    AS price,
                NULLIF(trim(r.freight_value), '')
                    AS freight_value,
                to_jsonb(r) AS source_row
            FROM raw.order_items r
        )

        SELECT
            n.*,
            CASE
                WHEN order_id IS NULL
                    OR order_id !~ '^[0-9a-f]{32}$'
                    THEN 'ITEM_ORDER_ID_FORMAT'
                WHEN order_item_id IS NULL
                    OR order_item_id !~ '^[0-9]+$'
                    THEN 'ITEM_NO_FORMAT'
                WHEN order_item_id::numeric < 1
                    OR order_item_id::numeric > 32767
                    THEN 'ITEM_NO_RANGE'
                WHEN product_id IS NULL
                    OR product_id !~ '^[0-9a-f]{32}$'
                    THEN 'ITEM_PRODUCT_ID_FORMAT'
                WHEN seller_id IS NULL
                    OR seller_id !~ '^[0-9a-f]{32}$'
                    THEN 'ITEM_SELLER_ID_FORMAT'
                WHEN shipping_limit_date IS NULL
                    OR shipping_limit_date !~
                    '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?$'
                    THEN 'ITEM_SHIPLIM_FORMAT'
                WHEN price IS NULL
                    OR price !~ '^[+-]?[0-9]+(\.[0-9]+)?$'
                    THEN 'ITEM_PRICE_FORMAT'
                WHEN price::numeric < 0
                    OR price::numeric > 99999999.99
                    THEN 'ITEM_PRICE_RANGE'
                WHEN freight_value IS NULL
                    OR freight_value !~ '^[+-]?[0-9]+(\.[0-9]+)?$'
                    THEN 'ITEM_FREIGHT_FORMAT'
                WHEN freight_value::numeric < 0
                    OR freight_value::numeric > 99999999.99
                    THEN 'ITEM_FREIGHT_RANGE'
                WHEN count(*) OVER (
                    PARTITION BY order_id, order_item_id
                ) > 1
                    THEN 'ITEM_KEY_DUPLICATE'
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
            'order_items',
            t.rule_code,
            concat_ws(
                ', ',
                t.order_id,
                t.order_item_id
            ),
            t.source_row,
            v_loaded_at
        FROM tmp_order_items t
        WHERE t.rule_code IS NOT NULL;
        GET DIAGNOSTICS v_rej = ROW_COUNT;

        TRUNCATE staging.order_items;

        INSERT INTO staging.order_items (
            order_id,
            order_item_id,
            product_id,
            seller_id,
            shipping_limit_date,
            price,
            freight_value,
            loaded_at,
            source_name,
            row_hash
        )
        SELECT
            t.order_id::uuid,
            t.order_item_id::smallint,
            t.product_id::uuid,
            t.seller_id::uuid,
            t.shipping_limit_date::timestamp,
            t.price::numeric(10,2),
            t.freight_value::numeric(10,2),
            v_loaded_at,
            t.source_name,
            staging.hash_key(
                t.order_id,
                t.order_item_id,
                t.product_id,
                t.seller_id,
                t.shipping_limit_date,
                t.price,
                t.freight_value
            )
        FROM tmp_order_items t
        WHERE t.rule_code IS NULL;
        GET DIAGNOSTICS v_ins = ROW_COUNT;

        IF v_read <> v_ins + v_rej THEN
            RAISE EXCEPTION
                'invariant violated: read=%, inserted=%, rejected=%',
                v_read,
                v_ins,
                v_rej;
        END IF;

    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            v_error = MESSAGE_TEXT;
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
            'load_stg_order_items failed: %',
            v_error;
    END IF;
END;
$$;
