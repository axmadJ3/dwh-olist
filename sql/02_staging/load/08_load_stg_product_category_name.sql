
CREATE OR REPLACE PROCEDURE etl.load_stg_product_category_name(
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
    VALUES (v_run_id, 'load_stg', 'product_category_name')
    RETURNING step_id INTO v_step_id;

    SELECT started_at
    INTO v_loaded_at
    FROM audit.run
    WHERE run_id = v_run_id;
    COMMIT;

    BEGIN
        PERFORM etl.assert_prev_stage('load_raw', 'product_category_name', p_batch);

        SELECT count(*) INTO v_read FROM raw.product_category_name;

        CREATE TEMPORARY TABLE tmp_product_category_name
        ON COMMIT DROP AS

        WITH n AS (
            SELECT
                r.load_id AS raw_load_id,
                r.source_name,
                NULLIF(lower(trim(r.product_category_name)), '')
                    AS product_category_name,
                NULLIF(trim(r.product_category_name_english), '')
                    AS product_category_name_english,
                to_jsonb(r) AS source_row
            FROM raw.product_category_name r
        )

        SELECT
            n.*,
            CASE
                WHEN product_category_name IS NULL
                    THEN 'CAT_NAME_FORMAT'
                WHEN product_category_name_english IS NULL
                    THEN 'CAT_NAME_EN_FORMAT'
                WHEN count(*) OVER (
                    PARTITION BY product_category_name
                ) > 1
                    THEN 'CAT_NAME_DUPLICATE'
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
            'product_category_name',
            t.rule_code,
            t.product_category_name,
            t.source_row,
            v_loaded_at
        FROM tmp_product_category_name t
        WHERE t.rule_code IS NOT NULL;
        GET DIAGNOSTICS v_rej = ROW_COUNT;

        TRUNCATE staging.product_category_name;

        INSERT INTO staging.product_category_name (
            product_category_name,
            product_category_name_english,
            loaded_at,
            source_name,
            row_hash
        )
        SELECT
            t.product_category_name,
            t.product_category_name_english,
            v_loaded_at,
            t.source_name,
            staging.hash_key(
                t.product_category_name,
                t.product_category_name_english
            )
        FROM tmp_product_category_name t
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
            'load_stg_product_category_name failed: %',
            v_error;
    END IF;
END;
$$;
