CREATE OR REPLACE FUNCTION etl.assert_prev_stage(
    p_prev_stage text,
    p_table text,
    p_batch text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_step_id int;
    v_batch text;
BEGIN
    SELECT rs.step_id, r.batch_name
      INTO v_step_id, v_batch
      FROM audit.run_step rs
      JOIN audit.run r ON r.run_id = rs.run_id
     WHERE rs.stage = p_prev_stage
       AND rs.table_name = p_table
       AND rs.status = 'success'
     ORDER BY rs.step_id DESC
     LIMIT 1;

    IF v_step_id IS NULL THEN
        RAISE EXCEPTION 'no successful % step found for table %', p_prev_stage, p_table;
    END IF;

    IF v_batch <> p_batch THEN
        RAISE EXCEPTION 'previous layer (%) of % holds batch %, but batch % was requested',
                        p_prev_stage, p_table, v_batch, p_batch;
    END IF;
END
$$;
