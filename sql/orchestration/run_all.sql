CREATE OR REPLACE PROCEDURE etl.run_all(p_batch text)
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id int;
    v_failed int;
BEGIN
    INSERT INTO audit.run (batch_name) VALUES (p_batch)
    RETURNING run_id INTO v_run_id;
    COMMIT;

    CALL etl.load_raw_customers(p_batch, v_run_id);
    CALL etl.load_raw_orders(p_batch, v_run_id);
    CALL etl.load_raw_order_items(p_batch, v_run_id);
    CALL etl.load_raw_order_payments(p_batch, v_run_id);
    CALL etl.load_raw_order_reviews(p_batch, v_run_id);
    CALL etl.load_raw_products(p_batch, v_run_id);
    CALL etl.load_raw_sellers(p_batch, v_run_id);
    CALL etl.load_raw_product_category_name(p_batch, v_run_id);
    CALL etl.load_raw_geolocation(p_batch, v_run_id);

    CALL etl.load_stg_customers(p_batch, v_run_id);

    SELECT count(*) INTO v_failed
      FROM audit.run_step
     WHERE run_id = v_run_id AND status <> 'success';

    UPDATE audit.run
       SET status      = CASE WHEN v_failed = 0 THEN 'success' ELSE 'failed' END,
           finished_at = clock_timestamp()
     WHERE run_id = v_run_id;
    COMMIT;

    IF v_failed > 0 THEN
        RAISE EXCEPTION 'run % failed, see audit.run_step', v_run_id;
    END IF;
END
$$;

CALL etl.run_all('batch_001_initial');
