
CREATE OR REPLACE PROCEDURE etl.load_stg_customers(
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
        INSERT INTO audit.run (batch_name) VALUES (p_batch)
        RETURNING run_id INTO v_run_id;
        v_own_run := true;
    END IF;

    INSERT INTO audit.run_step (run_id, stage, table_name)
    VALUES (v_run_id, 'load_stg', 'customers')
    RETURNING step_id INTO v_step_id;

    SELECT started_at INTO v_loaded_at FROM audit.run WHERE run_id = v_run_id;
    COMMIT;

    BEGIN
        PERFORM etl.assert_prev_stage('load_raw', 'customers', p_batch, v_run_id);

        SELECT count(*) INTO v_read FROM raw.customers;

        CREATE TEMPORARY TABLE tmp_customers ON COMMIT DROP AS
        WITH normalized AS (
            SELECT
                r.source_name,
                NULLIF(lower(trim(r.customer_id)), '') AS customer_id,
                NULLIF(lower(trim(r.customer_unique_id)), '') AS customer_unique_id,
                NULLIF(trim(r.customer_zip_code_prefix), '') AS zip_raw,
                NULLIF(trim(r.customer_city), '') AS customer_city,
                NULLIF(upper(trim(r.customer_state)), '') AS customer_state,
                to_jsonb(r) AS source_row,
                md5(jsonb_build_array(
                    r.customer_id,
                    r.customer_unique_id,
                    r.customer_zip_code_prefix,
                    r.customer_city,
                    r.customer_state)::text) AS src_hash
            FROM raw.customers r
        ), fixed AS (
            SELECT normalized.*,
                   CASE WHEN zip_raw ~ '^[0-9]{1,5}$'
                        THEN lpad(zip_raw, 5, '0')
                        ELSE zip_raw
                   END AS customer_zip_code_prefix
            FROM normalized
        ), validated AS (
            SELECT fixed.*,
                   CASE
                        WHEN customer_id IS NULL THEN 'CUST_ID_EMPTY'
                        WHEN customer_id !~ '^[0-9a-f]{32}$' THEN 'CUST_ID_FORMAT'
                        WHEN customer_unique_id IS NULL
                            OR customer_unique_id !~ '^[0-9a-f]{32}$' THEN 'CUST_UID_FORMAT'
                        WHEN customer_zip_code_prefix IS NULL
                            OR customer_zip_code_prefix !~ '^[0-9]{5}$' THEN 'CUST_ZIP_FORMAT'
                        WHEN customer_city IS NULL THEN 'CUST_CITY_EMPTY'
                        WHEN customer_state IS NULL
                            OR customer_state !~ '^[A-Z]{2}$' THEN 'CUST_STATE_FORMAT'
                   END AS basic_rule
            FROM fixed
        ), deduplicated AS (
            SELECT validated.*,
                row_number() OVER (
                    PARTITION BY customer_id, (basic_rule IS NULL)
                    ORDER BY md5(
                        concat_ws(
                            '|',
                            customer_unique_id,
                            customer_zip_code_prefix,
                            customer_city,
                            customer_state))
                   ) AS rn
            FROM validated
        )
        SELECT deduplicated.*,
               CASE
                    WHEN basic_rule IS NOT NULL THEN basic_rule
                    WHEN rn > 1 THEN 'CUST_ID_DUPLICATE'
               END AS rule_code
        FROM deduplicated;

        INSERT INTO audit.reject (
            step_id,
            table_name,
            rule_code,
            business_key,
            source_row,
            rejected_at)
        SELECT v_step_id,
            'customers',
            t.rule_code,
            coalesce(
                t.customer_id,
                t.source_row ->>
                'customer_id'),
            t.source_row,
            v_loaded_at
        FROM tmp_customers t
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
            'customers',
            t.rule_code,
            t.src_hash,
            min(coalesce(t.customer_id, t.source_row ->> 'customer_id')),
            (array_agg(t.source_row))[1],
            p_batch,
            v_step_id,
            v_step_id,v_loaded_at,
            v_loaded_at,
            count(*)
        FROM tmp_customers t
        WHERE t.rule_code IS NOT NULL
        GROUP BY t.rule_code, t.src_hash
            ON CONFLICT (table_name, rule_code, row_fingerprint) DO UPDATE
                SET batch_name = EXCLUDED.batch_name,
                    last_step_id = EXCLUDED.last_step_id,
                    last_seen_at = EXCLUDED.last_seen_at,
                    occurrences = EXCLUDED.occurrences,
                    source_row = EXCLUDED.source_row,
                    status  = CASE WHEN audit.quarantine.status = 'ignored'
                                THEN 'ignored' ELSE 'open' END,
                    resolved_at = CASE WHEN audit.quarantine.status = 'ignored'
                                THEN audit.quarantine.resolved_at ELSE NULL END,
                    resolution_note = CASE WHEN audit.quarantine.status = 'ignored'
                                        THEN audit.quarantine.resolution_note ELSE NULL END;

        TRUNCATE staging.customers;

        INSERT INTO staging.customers (
            customer_id,
            customer_unique_id,
            customer_zip_code_prefix,
            customer_city,
            customer_state,
            loaded_at,
            source_name,
            row_hash)
        SELECT
            t.customer_id::uuid,
            t.customer_unique_id::uuid,
            t.customer_zip_code_prefix::char(5),
            t.customer_city,
            t.customer_state::char(2),
            v_loaded_at,
            t.source_name,
            staging.hash_key(
                t.customer_unique_id,
                t.customer_zip_code_prefix,
                t.customer_city,
                t.customer_state)
        FROM tmp_customers t
        WHERE t.rule_code IS NULL;
        GET DIAGNOSTICS v_ins = ROW_COUNT;

        UPDATE audit.quarantine q
            SET status = 'resolved',
                resolved_at = v_loaded_at,
                resolution_note = 'не отклонено в batch ' || p_batch
            WHERE q.table_name = 'customers'
                AND q.status = 'open'
                AND q.last_step_id <> v_step_id
                AND (v_type = 'full'
                    OR EXISTS (SELECT 1 FROM staging.customers sc
                        WHERE replace(sc.customer_id::text, '-', '') = q.business_key));

        SELECT count(*) INTO v_fix
        FROM tmp_customers t
        WHERE t.rule_code IS NULL AND t.zip_raw ~ '^[0-9]{1,4}$';

        IF v_read <> v_ins + v_rej THEN
            RAISE EXCEPTION
                'инвариант нарушен: прочитано=%, вставлено=%, отклонено=%', v_read, v_ins, v_rej;
        END IF;

    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        v_read := 0;
        v_ins := 0;
        v_rej := 0;
        v_fix := 0;
    END;

    UPDATE audit.run_step
        SET status = CASE WHEN v_error IS NULL THEN 'success' ELSE 'failed' END,
            rows_read = v_read,
            rows_inserted = v_ins,
            rows_rejected = v_rej,
            rows_fixed = v_fix,
            error_message = v_error,
            finished_at = clock_timestamp()
        WHERE step_id = v_step_id;

    IF v_own_run THEN
        UPDATE audit.run
            SET status = CASE WHEN v_error IS NULL THEN 'success' ELSE 'failed' END,
                finished_at = clock_timestamp()
            WHERE run_id = v_run_id;
    END IF;
    COMMIT;

    IF v_error IS NOT NULL AND v_own_run THEN
        RAISE EXCEPTION 'load_stg_customers провален: %', v_error;
    END IF;
END
$$;
