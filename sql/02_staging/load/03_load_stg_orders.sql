
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
    v_type text := etl.batch_type(p_batch);
    v_read int := 0;
    v_ins int := 0;
    v_rej int := 0;
    v_fix int := 0;
    v_error text;
BEGIN
    IF v_run_id IS NULL THEN
        INSERT INTO audit.run (batch_name)
        VALUES (p_batch)
        RETURNING run_id INTO v_run_id;

        v_own_run := true;
    END IF;

    INSERT INTO audit.run_step (
        run_id,
        stage,
        table_name)
    VALUES (
        v_run_id,
        'load_stg',
        'orders')
    RETURNING step_id INTO v_step_id;

    SELECT started_at
    INTO v_loaded_at
    FROM audit.run
    WHERE run_id = v_run_id;
    COMMIT;

    BEGIN
        PERFORM etl.assert_prev_stage(
            'load_raw',
            'orders',
            p_batch,
            v_run_id
);

        SELECT count(*)
        INTO v_read
        FROM raw.orders;

        CREATE TEMPORARY TABLE tmp_orders ON COMMIT DROP AS
        WITH normalized AS (
            SELECT
                r.source_name,
                NULLIF(lower(trim(r.order_id)), '')
                    AS order_id,
                NULLIF(lower(trim(r.customer_id)), '')
                    AS customer_id,
                NULLIF(lower(trim(r.order_status)), '')
                    AS order_status,
                NULLIF(trim(r.order_purchase_timestamp), '')
                    AS purchase_raw,
                NULLIF(trim(r.order_approved_at), '')
                    AS approved_raw,
                NULLIF(trim(r.order_delivered_carrier_date), '')
                    AS carrier_raw,
                NULLIF(trim(r.order_delivered_customer_date), '')
                    AS delivered_raw,
                NULLIF(trim(r.order_estimated_delivery_date), '')
                    AS estimated_raw,
                to_jsonb(r) AS source_row,
                md5(jsonb_build_array(
                    r.order_id,
                    r.customer_id,
                    r.order_status,
                    r.order_purchase_timestamp,
                    r.order_approved_at,
                    r.order_delivered_carrier_date,
                    r.order_delivered_customer_date,
                    r.order_estimated_delivery_date
                )::text) AS src_hash
            FROM raw.orders r
        ), validated AS (
            SELECT
                normalized.*,
                CASE
                    WHEN customer_id IS NULL
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
                            'canceled')
                        THEN 'ORD_STATUS_INVALID'
                    WHEN purchase_raw IS NULL
                        OR NOT pg_input_is_valid(
                            purchase_raw, 'timestamp')
                        THEN 'ORD_PURCHASE_FORMAT'
                    WHEN approved_raw IS NOT NULL
                        AND NOT pg_input_is_valid(
                            approved_raw, 'timestamp')
                        THEN 'ORD_APPROVED_FORMAT'
                    WHEN carrier_raw IS NOT NULL
                        AND NOT pg_input_is_valid(
                            carrier_raw, 'timestamp')
                        THEN 'ORD_CARRIER_FORMAT'
                    WHEN delivered_raw IS NOT NULL
                        AND NOT pg_input_is_valid(
                            delivered_raw, 'timestamp')
                        THEN 'ORD_DELIVERED_FORMAT'
                    WHEN estimated_raw IS NOT NULL
                        AND NOT pg_input_is_valid(
                            estimated_raw, 'timestamp')
                        THEN 'ORD_ESTIMATED_FORMAT'
                END AS basic_rule
            FROM normalized
        ), deduplicated AS (
            SELECT
                validated.*,

                row_number() OVER (
                    PARTITION BY
                        order_id,
                        (basic_rule IS NULL)
                    ORDER BY
                        src_hash
                ) AS rn
            FROM validated
        )
        SELECT
            deduplicated.*,
            CASE
                WHEN basic_rule IS NOT NULL
                    THEN basic_rule
                WHEN rn > 1
                    THEN 'ORD_ID_DUPLICATE'
            END AS rule_code
        FROM deduplicated;

        INSERT INTO audit.reject (
            step_id,
            table_name,
            rule_code,
            business_key,
            source_row,
            rejected_at)
        SELECT
            v_step_id,
            'orders',
            t.rule_code,
            COALESCE(
                t.order_id,
                t.source_row ->> 'order_id'),
            t.source_row,
            v_loaded_at
        FROM tmp_orders t
        WHERE t.rule_code IS NOT NULL;
        GET DIAGNOSTICS v_rej = ROW_COUNT;

        INSERT INTO audit.quarantine (
            table_name,
            rule_code,
            row_fingerprint,
            business_key,
            source_row,
            batch_name,
            first_step_id,
            last_step_id,
            first_seen_at,
            last_seen_at,
            occurrences
        )
        SELECT
            'orders',
            t.rule_code,
            t.src_hash,
            min(
                COALESCE(
                    t.order_id,
                    t.source_row ->> 'order_id'
                )),
            (array_agg(t.source_row))[1],
            p_batch,
            v_step_id,
            v_step_id,
            v_loaded_at,
            v_loaded_at,
            count(*)
        FROM tmp_orders t
        WHERE t.rule_code IS NOT NULL
        GROUP BY
            t.rule_code,
            t.src_hash
        ON CONFLICT (
            table_name,
            rule_code,
            row_fingerprint
        )
        DO UPDATE SET
            batch_name = EXCLUDED.batch_name,
            last_step_id = EXCLUDED.last_step_id,
            last_seen_at = EXCLUDED.last_seen_at,
            occurrences = audit.quarantine.occurrences
                          + EXCLUDED.occurrences,
            source_row = EXCLUDED.source_row,
            status = CASE
                WHEN audit.quarantine.status = 'ignored'
                    THEN 'ignored'
                ELSE 'open'
            END,
            resolved_at = CASE
                WHEN audit.quarantine.status = 'ignored'
                    THEN audit.quarantine.resolved_at
                ELSE NULL
            END,
            resolution_note = CASE
                WHEN audit.quarantine.status = 'ignored'
                    THEN audit.quarantine.resolution_note
                ELSE NULL
            END;

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
            row_hash)
        SELECT
            t.order_id::uuid,
            t.customer_id::uuid,
            t.order_status,
            t.purchase_raw::timestamp,
            t.approved_raw::timestamp,
            t.carrier_raw::timestamp,
            t.delivered_raw::timestamp,
            t.estimated_raw::timestamp,
            v_loaded_at,
            t.source_name,
            staging.hash_key(
                t.customer_id,
                t.order_status,
                t.purchase_raw,
                t.approved_raw,
                t.carrier_raw,
                t.delivered_raw,
                t.estimated_raw)
        FROM tmp_orders t
        WHERE t.rule_code IS NULL
        ON CONFLICT (order_id)
        DO UPDATE SET
            customer_id = EXCLUDED.customer_id,
            order_status = EXCLUDED.order_status,
            order_purchase_timestamp =
                EXCLUDED.order_purchase_timestamp,
            order_approved_at = EXCLUDED.order_approved_at,
            order_delivered_carrier_date =
                EXCLUDED.order_delivered_carrier_date,
            order_delivered_customer_date =
                EXCLUDED.order_delivered_customer_date,
            order_estimated_delivery_date =
                EXCLUDED.order_estimated_delivery_date,
            loaded_at = EXCLUDED.loaded_at,
            source_name = EXCLUDED.source_name,
            row_hash = EXCLUDED.row_hash;
        GET DIAGNOSTICS v_ins = ROW_COUNT;

        UPDATE audit.quarantine q
        SET
            status = 'resolved',
            resolved_at = v_loaded_at,
            resolution_note =
                'не отклонено в batch ' || p_batch
        WHERE q.table_name = 'orders'
            AND q.status = 'open'
            AND q.last_step_id <> v_step_id
            AND (
                v_type = 'full'
                OR EXISTS (
                    SELECT 1
                    FROM staging.orders so
                    WHERE replace(
                        so.order_id::text, '-', '') = q.business_key));

        IF v_read <> v_ins + v_rej THEN
            RAISE EXCEPTION
                'инвариант нарушен: прочитано=%, вставлено=%, отклонено=%',
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
        v_fix := 0;
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
        rows_fixed = v_fix,
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
            'load_stg_orders провален: %',
            v_error;
    END IF;
END
$$;
