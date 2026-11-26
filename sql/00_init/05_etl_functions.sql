DROP FUNCTION IF EXISTS etl.assert_prev_stage(text, text, text);

CREATE OR REPLACE FUNCTION etl.assert_prev_stage(
    p_prev_stage text,
    p_table text,
    p_batch text,
    p_run_id int DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
    v_step_id int;
    v_status text;
    v_batch text;
BEGIN
    SELECT rs.step_id, rs.status, r.batch_name
    INTO v_step_id, v_status, v_batch
    FROM audit.run_step rs
    JOIN audit.run r ON r.run_id = rs.run_id
    WHERE rs.stage = p_prev_stage
        AND rs.table_name = p_table
    ORDER BY (rs.run_id = p_run_id) DESC, rs.step_id DESC
    LIMIT 1;

    IF v_step_id IS NULL THEN
        RAISE EXCEPTION 'для таблицы % не найден шаг %', p_table, p_prev_stage;
    END IF;

    IF v_status <> 'success' THEN
        RAISE EXCEPTION
            'последний % шаг из % имеет статус %, ожидается успех', p_prev_stage, p_table, v_status;
    END IF;

    IF v_batch <> p_batch THEN
        RAISE EXCEPTION
            'Предыдущий слой (%) из % содержит пакет %, однако был запрошен пакет %', p_prev_stage, p_table, v_batch, p_batch;
    END IF;

    RETURN v_step_id;
END
$$;

CREATE OR REPLACE FUNCTION etl.batch_type(p_batch text)
RETURNS text
LANGUAGE sql STABLE
AS $$
    SELECT coalesce((SELECT type FROM audit.batch WHERE batch_name = p_batch), 'full');
$$;

CREATE OR REPLACE FUNCTION etl.count_failed(p_run_id int, p_stage text)
RETURNS int
LANGUAGE sql STABLE
AS $$
    SELECT count(*)::int
    FROM audit.run_step
    WHERE run_id = p_run_id AND stage = p_stage AND status <> 'success';
$$;

CREATE OR REPLACE PROCEDURE etl.set_quarantine_status(
    p_quarantine_id int,
    p_status text,
    p_note text DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_status NOT IN ('open', 'resolved', 'ignored') THEN
        RAISE EXCEPTION 'неблагоприятный карантинный статус: %', p_status;
    END IF;

    UPDATE audit.quarantine
       SET status = p_status,
           resolved_at = CASE WHEN p_status = 'open' THEN NULL ELSE clock_timestamp() END,
           resolution_note = CASE WHEN p_status = 'open' THEN NULL ELSE p_note END
     WHERE quarantine_id = p_quarantine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'quarantine_id % не найден', p_quarantine_id;
    END IF;
END
$$;
