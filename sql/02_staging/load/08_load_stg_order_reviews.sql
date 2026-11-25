
CREATE OR REPLACE PROCEDURE etl.load_stg_order_reviews(
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
        INSERT INTO audit.run(batch_name)
        VALUES (p_batch)
        RETURNING run_id INTO v_run_id;
        v_own_run := true;
    END IF;

    INSERT INTO audit.run_step(
        run_id,
        stage,
        table_name
    )
    VALUES (
        v_run_id,
        'load_stg',
        'order_reviews'
    )
    RETURNING step_id INTO v_step_id;

    SELECT started_at
    INTO v_loaded_at
    FROM audit.run
    WHERE run_id = v_run_id;
    COMMIT;

    BEGIN
        PERFORM etl.assert_prev_stage('load_raw', 'order_reviews', p_batch);

        SELECT count(*) INTO v_read FROM raw.order_reviews;

        CREATE TEMP TABLE tmp_order_reviews
        ON COMMIT DROP
        AS
        WITH n AS (
            SELECT
                r.load_id AS raw_load_id,
                r.source_name,
                NULLIF(lower(trim(r.review_id)), '') AS review_id,
                NULLIF(lower(trim(r.order_id)), '') AS order_id,
                NULLIF(trim(r.review_score), '') AS review_score,
                NULLIF(trim(r.review_comment_title), '')
                    AS review_comment_title,
                NULLIF(trim(r.review_comment_message), '')
                    AS review_comment_message,
                NULLIF(trim(r.review_creation_date), '')
                    AS review_creation_date,
                NULLIF(trim(r.review_answer_timestamp), '')
                    AS review_answer_timestamp,
                to_jsonb(r) AS source_row

            FROM raw.order_reviews r
        ),
        checked AS (
            SELECT
                n.*,
                CASE
                    WHEN review_id IS NULL
                      OR review_id !~ '^[0-9a-f]{32}$'
                        THEN 'REV_ID_FORMAT'
                    WHEN order_id IS NULL
                      OR order_id !~ '^[0-9a-f]{32}$'
                        THEN 'REV_ORDER_ID_FORMAT'
                    WHEN review_score IS NULL
                      OR review_score !~ '^[0-9]+$'
                        THEN 'REV_SCORE_FORMAT'
                    WHEN review_score::numeric NOT BETWEEN 1 AND 5
                        THEN 'REV_SCORE_RANGE'
                    WHEN review_creation_date IS NULL
                      OR review_creation_date !~
                         '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?$'
                        THEN 'REV_CREATED_FORMAT'
                    WHEN review_answer_timestamp IS NOT NULL
                     AND review_answer_timestamp !~
                         '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?$'
                        THEN 'REV_ANSWER_FORMAT'
                    WHEN count(*) OVER (
                        PARTITION BY review_id, order_id
                    ) > 1
                        THEN 'REV_KEY_DUPLICATE'
                    ELSE NULL
                END AS rule_code
            FROM n
        )
        SELECT *
        FROM checked;

        INSERT INTO audit.reject(
            step_id,
            table_name,
            rule_code,
            business_key,
            source_row,
            rejected_at
        )
        SELECT
            v_step_id,
            'order_reviews',
            t.rule_code,
            concat_ws(',', t.review_id, t.order_id),
            t.source_row,
            clock_timestamp()
        FROM tmp_order_reviews t
        WHERE t.rule_code IS NOT NULL;
        GET DIAGNOSTICS v_rej = ROW_COUNT;

        TRUNCATE TABLE staging.order_reviews;

        INSERT INTO staging.order_reviews(
            review_id,
            order_id,
            review_score,
            review_comment_title,
            review_comment_message,
            review_creation_date,
            review_answer_timestamp,
            loaded_at,
            source_name,
            row_hash
        )
        SELECT
            t.review_id::uuid,
            t.order_id::uuid,
            t.review_score::smallint,
            t.review_comment_title,
            t.review_comment_message,
            t.review_creation_date::timestamp,
            t.review_answer_timestamp::timestamp,
            v_loaded_at,
            t.source_name,
            staging.hash_key(
                t.review_id,
                t.order_id,
                t.review_score,
                t.review_comment_title,
                t.review_comment_message,
                t.review_creation_date,
                t.review_answer_timestamp
            )
        FROM tmp_order_reviews t
        WHERE t.rule_code IS NULL;
        GET DIAGNOSTICS v_ins = ROW_COUNT;

        IF v_read <> v_ins + v_rej THEN
            RAISE EXCEPTION
                'Row count mismatch: read %, inserted %, rejected %',
                v_read, v_ins, v_rej;
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
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
            'etl.load_stg_order_reviews failed: %',
            v_error;
    END IF;
END;
$$;
