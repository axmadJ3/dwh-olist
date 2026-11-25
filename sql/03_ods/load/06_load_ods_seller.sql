CREATE OR REPLACE PROCEDURE etl.load_ods_seller(
    p_batch  text,
    p_run_id int DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    c_min_ratio constant numeric := 0.5;
    v_run_id int := p_run_id;
    v_own_run boolean := false;
    v_step_id int;
    v_loaded_at timestamptz;
    v_read int := 0;
    v_ins int := 0;
    v_upd int := 0;
    v_del int := 0;
    v_active int := 0;
    v_error text;
BEGIN
    IF v_run_id IS NULL THEN
        INSERT INTO audit.run (batch_name)
        VALUES (p_batch)
        RETURNING run_id INTO v_run_id;
        v_own_run := true;
    END IF;

    INSERT INTO audit.run_step (run_id, stage, table_name)
    VALUES (v_run_id, 'load_ods', 'sellers')
    RETURNING step_id INTO v_step_id;

    SELECT started_at INTO v_loaded_at FROM audit.run WHERE run_id = v_run_id;
    COMMIT;

    BEGIN
        PERFORM etl.assert_prev_stage('load_stg', 'sellers', p_batch);

        SELECT count(*) INTO v_read FROM staging.sellers;
        SELECT count(*)INTO v_active FROM ods.ods_seller WHERE NOT is_deleted;
        IF v_read = 0 OR v_read < v_active * c_min_ratio THEN
            RAISE EXCEPTION
                'snapshot looks broken: staging has % rows, ods has % active rows', v_read, v_active;
        END IF;

        UPDATE ods.ods_seller os
            SET seller_zip_code_prefix = ss.seller_zip_code_prefix,
                seller_city = ss.seller_city,
                seller_state = ss.seller_state,
                row_hash = ss.row_hash,
                updated_step_id = v_step_id,
                updated_at = v_loaded_at,
                is_deleted = false,
                deleted_at = NULL
            FROM staging.sellers ss
            WHERE os.seller_id = ss.seller_id
                AND (os.row_hash <> ss.row_hash OR os.is_deleted);
        GET DIAGNOSTICS v_upd = ROW_COUNT;

        INSERT INTO ods.ods_seller (
            seller_id,
            seller_zip_code_prefix,
            seller_city,
            seller_state,
            row_hash,
            created_step_id,
            updated_step_id,
            created_at,
            updated_at
        )
        SELECT
            ss.seller_id,
            ss.seller_zip_code_prefix,
            ss.seller_city,
            ss.seller_state,
            ss.row_hash,
            v_step_id,
            v_step_id,
            v_loaded_at,
            v_loaded_at
        FROM staging.sellers ss
        WHERE NOT EXISTS (
            SELECT 1
            FROM ods.ods_seller os
            WHERE os.seller_id = ss.seller_id
        );
        GET DIAGNOSTICS v_ins = ROW_COUNT;

        UPDATE ods.ods_seller os
            SET is_deleted = true,
                deleted_at = v_loaded_at,
                updated_step_id = v_step_id,
                updated_at = v_loaded_at
            WHERE NOT os.is_deleted
                AND NOT EXISTS (
                    SELECT 1
                    FROM staging.sellers ss
                    WHERE ss.seller_id = os.seller_id);
        GET DIAGNOSTICS v_del = ROW_COUNT;

        SELECT count(*) INTO v_active FROM ods.ods_seller WHERE NOT is_deleted;
        IF v_active <> v_read THEN
            RAISE EXCEPTION
                'invariant violated: ods active=%, staging=%', v_active, v_read;
        END IF;

    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        v_read := 0;
        v_ins := 0;
        v_upd := 0;
        v_del := 0;
    END;

    UPDATE audit.run_step
        SET status = CASE
                        WHEN v_error IS NULL THEN 'success'
                        ELSE 'failed'
                    END,
            rows_read = v_read,
            rows_inserted = v_ins,
            rows_updated = v_upd + v_del,
            rows_rejected = 0,
            error_message = v_error,
            finished_at = clock_timestamp()
    WHERE step_id = v_step_id;

    IF v_own_run THEN
        UPDATE audit.run
           SET status = CASE
                            WHEN v_error IS NULL THEN 'success'
                            ELSE 'failed'
                        END,
               finished_at = clock_timestamp()
        WHERE run_id = v_run_id;
    END IF;
    COMMIT;

    IF v_error IS NOT NULL AND v_own_run THEN
        RAISE EXCEPTION 'load_ods_seller failed: %', v_error;
    END IF;
END
$$;