CREATE OR REPLACE PROCEDURE etl.run_raw(p_batch text, p_run_id int DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id int := p_run_id;
    v_own boolean := (p_run_id IS NULL);
    v_status text;
BEGIN
    IF v_own THEN
        INSERT INTO audit.run (batch_name) VALUES (p_batch)
        RETURNING run_id INTO v_run_id;
        COMMIT;
    END IF;

    CALL etl.load_raw_customers(p_batch, v_run_id);
    CALL etl.load_raw_orders(p_batch, v_run_id);
    CALL etl.load_raw_order_items(p_batch, v_run_id);
    CALL etl.load_raw_order_payments(p_batch, v_run_id);
    CALL etl.load_raw_order_reviews(p_batch, v_run_id);
    CALL etl.load_raw_products(p_batch, v_run_id);
    CALL etl.load_raw_sellers(p_batch, v_run_id);
    CALL etl.load_raw_product_category_name(p_batch, v_run_id);
    CALL etl.load_raw_geolocation(p_batch, v_run_id);

    IF v_own THEN
        UPDATE audit.run
            SET status = CASE WHEN EXISTS (SELECT 1 FROM audit.run_step
                                            WHERE run_id = v_run_id AND status <> 'success')
                            THEN 'failed' ELSE 'success' END,
                finished_at = clock_timestamp()
            WHERE run_id = v_run_id
        RETURNING status INTO v_status;
        COMMIT;
        IF v_status <> 'success' THEN
            RAISE EXCEPTION 'run_raw: запуск % провален, смотри audit.run_step', v_run_id;
        END IF;
    END IF;
END
$$;
