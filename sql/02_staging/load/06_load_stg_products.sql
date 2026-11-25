
CREATE OR REPLACE PROCEDURE etl.load_stg_products(
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
    VALUES (v_run_id, 'load_stg', 'products')
    RETURNING step_id INTO v_step_id;

    SELECT started_at
    INTO v_loaded_at
    FROM audit.run
    WHERE run_id = v_run_id;

    COMMIT;

    BEGIN
        PERFORM etl.assert_prev_stage('load_raw', 'products', p_batch);

        SELECT count(*) INTO v_read FROM raw.products;

        CREATE TEMPORARY TABLE tmp_products
        ON COMMIT DROP AS

        WITH n AS (
            SELECT
                r.load_id AS raw_load_id,
                r.source_name,
                NULLIF(lower(trim(r.product_id)), '')
                    AS product_id,
                NULLIF(trim(r.product_category_name), '')
                    AS product_category_name,
                NULLIF(trim(r.product_name_lenght), '')
                    AS product_name_length,
                NULLIF(trim(r.product_description_lenght), '')
                    AS product_description_length,
                NULLIF(trim(r.product_photos_qty), '')
                    AS product_photos_qty,
                NULLIF(trim(r.product_weight_g), '')
                    AS product_weight_g,
                NULLIF(trim(r.product_length_cm), '')
                    AS product_length_cm,
                NULLIF(trim(r.product_height_cm), '')
                    AS product_height_cm,
                NULLIF(trim(r.product_width_cm), '')
                    AS product_width_cm,
                to_jsonb(r) AS source_row
            FROM raw.products r
        )

        SELECT
            n.*,
            CASE
                WHEN product_id IS NULL
                    OR product_id !~ '^[0-9a-f]{32}$'
                    THEN 'PROD_ID_FORMAT'
                WHEN product_name_length IS NOT NULL
                    AND product_name_length !~ '^[0-9]+$'
                    THEN 'PROD_NAMELEN_FORMAT'
                WHEN product_name_length IS NOT NULL
                    AND (
                        product_name_length::numeric < 0
                        OR product_name_length::numeric > 32767
                    )
                    THEN 'PROD_NAMELEN_RANGE'
                WHEN product_description_length IS NOT NULL
                    AND product_description_length !~ '^[0-9]+$'
                    THEN 'PROD_DESCLEN_FORMAT'
                WHEN product_description_length IS NOT NULL
                    AND (
                        product_description_length::numeric < 0
                        OR product_description_length::numeric > 32767
                    )
                    THEN 'PROD_DESCLEN_RANGE'
                WHEN product_photos_qty IS NOT NULL
                    AND product_photos_qty !~ '^[0-9]+$'
                    THEN 'PROD_PHOTOS_FORMAT'
                WHEN product_photos_qty IS NOT NULL
                    AND (
                        product_photos_qty::numeric < 0
                        OR product_photos_qty::numeric > 32767
                    )
                    THEN 'PROD_PHOTOS_RANGE'
                WHEN product_weight_g IS NOT NULL
                    AND product_weight_g !~ '^[0-9]+$'
                    THEN 'PROD_WEIGHT_FORMAT'
                WHEN product_weight_g IS NOT NULL
                    AND (
                        product_weight_g::numeric < 0
                        OR product_weight_g::numeric > 2147483647
                    )
                    THEN 'PROD_WEIGHT_RANGE'
                WHEN product_length_cm IS NOT NULL
                    AND product_length_cm !~ '^[0-9]+$'
                    THEN 'PROD_LENGTH_FORMAT'
                WHEN product_length_cm IS NOT NULL
                    AND (
                        product_length_cm::numeric < 0
                        OR product_length_cm::numeric > 32767
                    )
                    THEN 'PROD_LENGTH_RANGE'
                WHEN product_height_cm IS NOT NULL
                    AND product_height_cm !~ '^[0-9]+$'
                    THEN 'PROD_HEIGHT_FORMAT'
                WHEN product_height_cm IS NOT NULL
                    AND (
                        product_height_cm::numeric < 0
                        OR product_height_cm::numeric > 32767
                    )
                    THEN 'PROD_HEIGHT_RANGE'
                WHEN product_width_cm IS NOT NULL
                    AND product_width_cm !~ '^[0-9]+$'
                    THEN 'PROD_WIDTH_FORMAT'
                WHEN product_width_cm IS NOT NULL
                    AND (
                        product_width_cm::numeric < 0
                        OR product_width_cm::numeric > 32767
                    )
                    THEN 'PROD_WIDTH_RANGE'
                WHEN count(*) OVER (
                    PARTITION BY product_id
                ) > 1
                    THEN 'PROD_ID_DUPLICATE'
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
            'products',
            t.rule_code,
            t.source_row ->> 'product_id',
            t.source_row,
            v_loaded_at
        FROM tmp_products t
        WHERE t.rule_code IS NOT NULL;
        GET DIAGNOSTICS v_rej = ROW_COUNT;

        TRUNCATE staging.products;

        INSERT INTO staging.products (
            product_id,
            product_category_name,
            product_name_length,
            product_description_length,
            product_photos_qty,
            product_weight_g,
            product_length_cm,
            product_height_cm,
            product_width_cm,
            loaded_at,
            source_name,
            row_hash
        )
        SELECT
            t.product_id::uuid,
            t.product_category_name,
            t.product_name_length::smallint,
            t.product_description_length::smallint,
            t.product_photos_qty::smallint,
            t.product_weight_g::int,
            t.product_length_cm::smallint,
            t.product_height_cm::smallint,
            t.product_width_cm::smallint,
            v_loaded_at,
            t.source_name,
            staging.hash_key(
                t.product_id,
                t.product_category_name,
                t.product_name_length,
                t.product_description_length,
                t.product_photos_qty,
                t.product_weight_g,
                t.product_length_cm,
                t.product_height_cm,
                t.product_width_cm
            )
        FROM tmp_products t
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
            'load_stg_products failed: %',
            v_error;
    END IF;
END;
$$;
