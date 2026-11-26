
CREATE OR REPLACE PROCEDURE etl.load_raw_customers(
    p_batch  text,
    p_run_id int DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    c_file constant text := 'olist_customers_dataset.csv';
    v_run_id int := p_run_id;
    v_own_run boolean := false;
    v_step_id int;
    v_loaded_at timestamptz;
    v_read int := 0;
    v_ins int := 0;
    v_error text;
BEGIN
    IF v_run_id IS NULL THEN
        INSERT INTO audit.run (batch_name) VALUES (p_batch)
        RETURNING run_id INTO v_run_id;
        v_own_run := true;
    END IF;

    INSERT INTO audit.run_step (run_id, stage, table_name)
    VALUES (v_run_id, 'load_raw', 'customers')
    RETURNING step_id INTO v_step_id;

    SELECT started_at INTO v_loaded_at FROM audit.run WHERE run_id = v_run_id;
    COMMIT;

    BEGIN
        EXECUTE format(
            'ALTER FOREIGN TABLE ext.olist_customers_dataset OPTIONS (SET filename %L)',
            format('/data/snapshots/%s/%s', p_batch, c_file));

        SELECT count(*) INTO v_read FROM ext.olist_customers_dataset;

        TRUNCATE raw.customers;

        INSERT INTO raw.customers (
            customer_id,
            customer_unique_id,
            customer_zip_code_prefix,
            customer_city,
            customer_state,
            load_id,
            loaded_at,
            source_name)
        SELECT
            customer_id,
            customer_unique_id,
            customer_zip_code_prefix,
            customer_city,
            customer_state,
            v_step_id,
            v_loaded_at,
            c_file
        FROM ext.olist_customers_dataset;
        GET DIAGNOSTICS v_ins = ROW_COUNT;

        IF v_read <> v_ins THEN
            RAISE EXCEPTION 'инвариант нарушен: прочитано=%, вставлено=%', v_read, v_ins;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        v_read := 0; v_ins := 0;
    END;

    UPDATE audit.run_step
        SET status = CASE WHEN v_error IS NULL THEN 'success' ELSE 'failed' END,
            rows_read = v_read,
            rows_inserted = v_ins,
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
        RAISE EXCEPTION 'olist_customers_dataset провален: %', v_error;
    END IF;
END
$$;
