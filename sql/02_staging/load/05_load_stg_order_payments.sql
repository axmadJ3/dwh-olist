
CREATE OR REPLACE PROCEDURE etl.load_stg_order_payments(
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
    VALUES (v_run_id, 'load_stg', 'order_payments')
    RETURNING step_id INTO v_step_id;

    SELECT started_at
    INTO v_loaded_at
    FROM audit.run
    WHERE run_id = v_run_id;

    COMMIT;

    BEGIN
        SELECT count(*)
        INTO v_read
        FROM raw.order_payments;

        CREATE TEMPORARY TABLE tmp_order_payments
        ON COMMIT DROP AS

        WITH n AS (
            SELECT
                r.load_id AS raw_load_id,
                r.source_name,
                NULLIF(lower(trim(r.order_id)), '')
                    AS order_id,
                NULLIF(trim(r.payment_sequential), '')
                    AS payment_sequential,
                NULLIF(lower(trim(r.payment_type)), '')
                    AS payment_type,
                NULLIF(trim(r.payment_installments), '')
                    AS payment_installments,
                NULLIF(trim(r.payment_value), '')
                    AS payment_value,
                to_jsonb(r) AS source_row
            FROM raw.order_payments r
        )

        SELECT
            n.*,
            CASE
                WHEN order_id IS NULL
                    OR order_id !~ '^[0-9a-f]{32}$'
                    THEN 'PAY_ORDER_ID_FORMAT'
                WHEN payment_sequential IS NULL
                    OR payment_sequential !~ '^[0-9]+$'
                    THEN 'PAY_SEQ_FORMAT'
                WHEN payment_sequential::numeric < 1
                    OR payment_sequential::numeric > 32767
                    THEN 'PAY_SEQ_RANGE'
                WHEN payment_type IS NULL
                    OR payment_type NOT IN (
                        'credit_card',
                        'boleto',
                        'voucher',
                        'debit_card',
                        'not_defined'
                    )
                    THEN 'PAY_TYPE_INVALID'
                WHEN payment_installments IS NULL
                    OR payment_installments !~ '^[0-9]+$'
                    THEN 'PAY_INST_FORMAT'
                WHEN payment_installments::numeric < 0
                    OR payment_installments::numeric > 32767
                    THEN 'PAY_INST_RANGE'
                WHEN payment_value IS NULL
                    OR payment_value !~ '^[+-]?[0-9]+(\.[0-9]+)?$'
                    THEN 'PAY_VALUE_FORMAT'
                WHEN payment_value::numeric < 0
                    OR payment_value::numeric > 99999999.99
                    THEN 'PAY_VALUE_RANGE'
                WHEN count(*) OVER (
                    PARTITION BY order_id, payment_sequential
                ) > 1
                    THEN 'PAY_KEY_DUPLICATE'
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
            'order_payments',
            t.rule_code,
            concat_ws(
                ', ',
                t.order_id,
                t.payment_sequential
            ),
            t.source_row,
            v_loaded_at
        FROM tmp_order_payments t
        WHERE t.rule_code IS NOT NULL;
        GET DIAGNOSTICS v_rej = ROW_COUNT;

        TRUNCATE staging.order_payments;

        INSERT INTO staging.order_payments (
            order_id,
            payment_sequential,
            payment_type,
            payment_installments,
            payment_value,
            raw_load_id,
            stg_load_id,
            loaded_at,
            source_name,
            row_hash
        )
        SELECT
            t.order_id::uuid,
            t.payment_sequential::smallint,
            t.payment_type,
            t.payment_installments::smallint,
            t.payment_value::numeric(10,2),
            t.raw_load_id,
            v_step_id,
            v_loaded_at,
            t.source_name,
            staging.hash_key(
                t.order_id,
                t.payment_sequential,
                t.payment_type,
                t.payment_installments,
                t.payment_value
            )
        FROM tmp_order_payments t
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
            'load_stg_order_payments failed: %',
            v_error;
    END IF;
END;
$$;
