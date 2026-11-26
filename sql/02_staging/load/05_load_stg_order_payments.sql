
CREATE OR REPLACE PROCEDURE etl.load_stg_payments(
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
        'order_payments')
    RETURNING step_id INTO v_step_id;

    SELECT started_at
    INTO v_loaded_at
    FROM audit.run
    WHERE run_id = v_run_id;
    COMMIT;

    BEGIN
        PERFORM etl.assert_prev_stage(
            'load_raw',
            'order_payments',
            p_batch,
            v_run_id
        );

        SELECT count(*)
        INTO v_read
        FROM raw.order_payments;

        CREATE TEMPORARY TABLE tmp_payments
        ON COMMIT DROP AS
        WITH normalized AS (
            SELECT
                r.source_name,
                NULLIF(
                    lower(trim(r.order_id)),
                    ''
                ) AS order_id,
                NULLIF(
                    trim(r.payment_sequential),
                    ''
                ) AS payment_sequential_raw,
                NULLIF(
                    lower(trim(r.payment_type)),
                    ''
                ) AS payment_type,
                NULLIF(
                    trim(r.payment_installments),
                    ''
                ) AS payment_installments_raw,
                NULLIF(
                    trim(r.payment_value),
                    ''
                ) AS payment_value_raw,
                to_jsonb(r) AS source_row,
                md5(
                    jsonb_build_array(
                        r.order_id,
                        r.payment_sequential,
                        r.payment_type,
                        r.payment_installments,
                        r.payment_value
                    )::text
                ) AS src_hash
            FROM raw.order_payments r
        ),
        validated AS (
            SELECT normalized.*,
                CASE
                    WHEN order_id IS NULL
                        OR order_id !~ '^[0-9a-f]{32}$'
                        THEN 'PAY_ORDER_ID_FORMAT'
                    WHEN payment_sequential_raw IS NULL
                        OR payment_sequential_raw !~ '^[0-9]+$'
                        THEN 'PAY_SEQ_FORMAT'
                    WHEN payment_sequential_raw::numeric < 1
                        OR payment_sequential_raw::numeric > 32767
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
                    WHEN payment_installments_raw IS NULL
                        OR payment_installments_raw !~ '^[0-9]+$'
                        THEN 'PAY_INST_FORMAT'
                    WHEN payment_installments_raw::numeric > 32767
                        THEN 'PAY_INST_RANGE'
                    WHEN payment_value_raw IS NULL
                        OR payment_value_raw !~ '^[0-9]+([.][0-9]+)?$'
                        THEN 'PAY_VALUE_FORMAT'
                    WHEN payment_value_raw::numeric < 0
                        OR payment_value_raw::numeric >= 100000000
                        OR round(payment_value_raw::numeric, 2)
                            <> payment_value_raw::numeric
                        THEN 'PAY_VALUE_RANGE'
                END AS basic_rule
            FROM normalized
        ),
        deduplicated AS (
            SELECT validated.*,
                row_number() OVER (
                    PARTITION BY
                        order_id,
                        payment_sequential_raw,
                        (basic_rule IS NULL)
                    ORDER BY src_hash
                ) AS rn
            FROM validated
        )
        SELECT deduplicated.*,
            CASE
                WHEN basic_rule IS NOT NULL
                    THEN basic_rule
                WHEN rn > 1
                    THEN 'PAY_KEY_DUPLICATE'
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
            'order_payments',
            t.rule_code,
            concat_ws(
                ',',
                t.order_id,
                t.payment_sequential_raw),
            t.source_row,
            v_loaded_at
        FROM tmp_payments t
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
            occurrences)
        SELECT
            'order_payments',
            t.rule_code,
            t.src_hash,
            min(
                concat_ws(
                    ',',
                    t.order_id,
                    t.payment_sequential_raw)),
            (array_agg(t.source_row))[1],
            p_batch,
            v_step_id,
            v_step_id,
            v_loaded_at,
            v_loaded_at,
            count(*)
        FROM tmp_payments t
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

        TRUNCATE staging.order_payments;

        INSERT INTO staging.order_payments (
            order_id,
            payment_sequential,
            payment_type,
            payment_installments,
            payment_value,
            loaded_at,
            source_name,
            row_hash)
        SELECT
            t.order_id::uuid,
            t.payment_sequential_raw::smallint,
            t.payment_type,
            t.payment_installments_raw::smallint,
            t.payment_value_raw::numeric(10,2),
            v_loaded_at,
            t.source_name,
            staging.hash_key(
                t.order_id,
                t.payment_sequential_raw,
                t.payment_type,
                t.payment_installments_raw,
                t.payment_value_raw)
        FROM tmp_payments t
        WHERE t.rule_code IS NULL;
        GET DIAGNOSTICS v_ins = ROW_COUNT;

        UPDATE audit.quarantine q
        SET
            status = 'resolved',
            resolved_at = v_loaded_at,
            resolution_note = 'не отклонено в batch ' || p_batch
        WHERE q.table_name = 'order_payments'
            AND q.status = 'open'
            AND q.last_step_id <> v_step_id
            AND (
                v_type = 'full'
                OR EXISTS (
                    SELECT 1
                    FROM staging.order_payments sp
                    WHERE
                        replace(sp.order_id::text, '-', '')
                            || ','
                            || sp.payment_sequential::text
                        = q.business_key));

        SELECT count(*)
        INTO v_fix
        FROM tmp_payments t
        WHERE t.rule_code IS NULL;

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
            'load_stg_payments провален: %',
            v_error;
    END IF;
END
$$;
