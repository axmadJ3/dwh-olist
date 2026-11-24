
CREATE OR REPLACE PROCEDURE etl.load_stg_sellers(
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
    VALUES (v_run_id, 'load_stg', 'sellers')
    RETURNING step_id INTO v_step_id;

    SELECT started_at
    INTO v_loaded_at
    FROM audit.run
    WHERE run_id = v_run_id;
    COMMIT;

    BEGIN
        SELECT count(*)
        INTO v_read
        FROM raw.sellers;

        CREATE TEMPORARY TABLE tmp_sellers
        ON COMMIT DROP AS

        WITH n AS (
            SELECT
                r.load_id AS raw_load_id,
                r.source_name,
                NULLIF(lower(trim(r.seller_id)), '')
                    AS seller_id,
                NULLIF(trim(r.seller_zip_code_prefix), '')
                    AS seller_zip_code_prefix,
                NULLIF(trim(r.seller_city), '')
                    AS seller_city,
                NULLIF(upper(trim(r.seller_state)), '')
                    AS seller_state,
                to_jsonb(r) AS source_row
            FROM raw.sellers r
        )

        SELECT
            n.*,
            CASE
                WHEN seller_id IS NULL
                    OR seller_id !~ '^[0-9a-f]{32}$'
                    THEN 'SELL_ID_FORMAT'
                WHEN seller_zip_code_prefix IS NULL
                    OR seller_zip_code_prefix !~ '^[0-9]{5}$'
                    THEN 'SELL_ZIP_FORMAT'
                WHEN seller_state IS NULL
                    OR seller_state !~ '^[A-Z]{2}$'
                    THEN 'SELL_STATE_FORMAT'
                WHEN count(*) OVER (
                    PARTITION BY seller_id
                ) > 1
                    THEN 'SELL_ID_DUPLICATE'
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
            'sellers',
            t.rule_code,
            t.source_row ->> 'seller_id',
            t.source_row,
            v_loaded_at
        FROM tmp_sellers t
        WHERE t.rule_code IS NOT NULL;
        GET DIAGNOSTICS v_rej = ROW_COUNT;

        TRUNCATE staging.sellers;

        INSERT INTO staging.sellers (
            seller_id,
            seller_zip_code_prefix,
            seller_city,
            seller_state,
            raw_load_id,
            stg_load_id,
            loaded_at,
            source_name,
            row_hash
        )
        SELECT
            t.seller_id::uuid,
            t.seller_zip_code_prefix::char(5),
            t.seller_city,
            t.seller_state::char(2),
            t.raw_load_id,
            v_step_id,
            v_loaded_at,
            t.source_name,
            staging.hash_key(
                t.seller_id,
                t.seller_zip_code_prefix,
                t.seller_city,
                t.seller_state
            )
        FROM tmp_sellers t
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
            'load_stg_sellers failed: %',
            v_error;
    END IF;
END;
$$;
