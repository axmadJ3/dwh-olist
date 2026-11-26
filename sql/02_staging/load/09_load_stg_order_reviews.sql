
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
    v_type text := etl.batch_type(p_batch);
    v_read int := 0;
    v_ins int := 0;
    v_rej int := 0;
    v_fix int := 0;
    v_error text;
BEGIN
    IF v_run_id IS NULL THEN
        INSERT INTO audit.run (batch_name)
        VALUES (p_batch)
        RETURNING run_id INTO v_run_id;
        v_own_run := true;
    END IF;

    INSERT INTO audit.run_step (run_id, stage, table_name)
    VALUES (v_run_id, 'load_stg', 'order_reviews')
    RETURNING step_id INTO v_step_id;

    SELECT started_at
    INTO v_loaded_at
    FROM audit.run
    WHERE run_id = v_run_id;

    COMMIT;

    BEGIN
        PERFORM etl.assert_prev_stage(
            'load_raw',
            'order_reviews',
            p_batch,
            v_run_id
        );

        SELECT count(*)
        INTO v_read
        FROM raw.order_reviews;

        CREATE TEMPORARY TABLE tmp_order_reviews
        ON COMMIT DROP AS

        WITH normalized AS (
            SELECT
                r.source_name,
                NULLIF(
                    lower(trim(r.review_id)),
                    ''
                ) AS review_id,
                NULLIF(
                    lower(trim(r.order_id)),
                    ''
                ) AS order_id,
                NULLIF(
                    trim(r.review_score),
                    ''
                ) AS score_raw,
                NULLIF(
                    trim(r.review_comment_title),
                    ''
                ) AS review_comment_title,
                NULLIF(
                    trim(r.review_comment_message),
                    ''
                ) AS review_comment_message,
                NULLIF(
                    trim(r.review_creation_date),
                    ''
                ) AS created_raw,
                NULLIF(
                    trim(r.review_answer_timestamp),
                    ''
                ) AS answer_raw,
                to_jsonb(r) AS source_row,
                md5(
                    jsonb_build_array(
                        r.review_id,
                        r.order_id,
                        r.review_score,
                        r.review_comment_title,
                        r.review_comment_message,
                        r.review_creation_date,
                        r.review_answer_timestamp
                    )::text
                ) AS src_hash

            FROM raw.order_reviews r
        ), parsed AS (
            SELECT
                normalized.*,
                CASE
                    WHEN score_raw ~ '^[+-]?[0-9]+$'
                    THEN score_raw::integer
                END AS score_value,
                CASE
                    WHEN created_raw ~
                        '^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?$'
                    THEN
                        CASE
                            WHEN pg_input_is_valid(
                                created_raw,
                                'timestamp'
                            )
                            THEN created_raw::timestamp
                        END
                END AS created_value,
                CASE
                    WHEN answer_raw IS NULL THEN NULL
                    WHEN answer_raw ~
                        '^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?$'
                    THEN
                        CASE
                            WHEN pg_input_is_valid(
                                answer_raw,
                                'timestamp'
                            )
                            THEN answer_raw::timestamp
                        END
                END AS answer_value
            FROM normalized
        ), validated AS (
            SELECT
                parsed.*,
                CASE
                    WHEN review_id IS NULL
                        OR review_id !~ '^[0-9a-f]{32}$'
                        THEN 'REV_ID_FORMAT'
                    WHEN order_id IS NULL
                        OR order_id !~ '^[0-9a-f]{32}$'
                        THEN 'REV_ORDER_ID_FORMAT'
                    WHEN score_raw IS NULL
                        OR score_raw !~ '^[+-]?[0-9]+$'
                        THEN 'REV_SCORE_FORMAT'
                    WHEN score_value NOT BETWEEN 1 AND 5
                        THEN 'REV_SCORE_RANGE'
                    WHEN created_raw IS NULL
                        OR created_value IS NULL
                        THEN 'REV_CREATED_FORMAT'
                    WHEN answer_raw IS NOT NULL
                        AND answer_value IS NULL
                        THEN 'REV_ANSWER_FORMAT'
                END AS basic_rule
            FROM parsed
        ), deduplicated AS (
            SELECT
                validated.*,

                row_number() OVER (
                    PARTITION BY
                        review_id,
                        order_id,
                        (basic_rule IS NULL)
                    ORDER BY src_hash
                ) AS rn

            FROM validated
        )
        SELECT
            deduplicated.*,
            CASE
                WHEN basic_rule IS NOT NULL
                    THEN basic_rule
                WHEN rn > 1
                    THEN 'REV_KEY_DUPLICATE'
            END AS rule_code
        FROM deduplicated;

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
            'order_reviews',
            t.rule_code,

            coalesce(
                t.review_id,
                t.source_row ->> 'review_id'
            ) || '|' ||
            coalesce(
                t.order_id,
                t.source_row ->> 'order_id'
            ),

            t.source_row,
            v_loaded_at
        FROM tmp_order_reviews t
        WHERE t.rule_code IS NOT NULL;
        GET DIAGNOSTICS v_rej = ROW_COUNT;

        INSERT INTO audit.quarantine (
            table_name,
            rule_code,
            row_fingerprint,
            business_key,
            source_row,
            batch_name,
            first_step_id,
            last_step_id,
            first_seen_at,
            last_seen_at,
            occurrences
        )
        SELECT
            'order_reviews',
            t.rule_code,
            t.src_hash,
            min(
                coalesce(
                    t.review_id,
                    t.source_row ->> 'review_id'
                ) || '|' ||
                coalesce(
                    t.order_id,
                    t.source_row ->> 'order_id'
                )),
            (array_agg(t.source_row))[1],
            p_batch,
            v_step_id,
            v_step_id,
            v_loaded_at,
            v_loaded_at,
            count(*)
        FROM tmp_order_reviews t
        WHERE t.rule_code IS NOT NULL
        GROUP BY
            t.rule_code,
            t.src_hash
        ON CONFLICT (
            table_name,
            rule_code,
            row_fingerprint
        )
        DO UPDATE SET
            batch_name = EXCLUDED.batch_name,
            last_step_id = EXCLUDED.last_step_id,
            last_seen_at = EXCLUDED.last_seen_at,
            occurrences = EXCLUDED.occurrences,
            source_row = EXCLUDED.source_row,
            status = CASE
                WHEN audit.quarantine.status = 'ignored'
                    THEN 'ignored'
                ELSE 'open'
            END,
            resolved_at = CASE
                WHEN audit.quarantine.status = 'ignored'
                    THEN audit.quarantine.resolved_at
                ELSE NULL
            END,
            resolution_note = CASE
                WHEN audit.quarantine.status = 'ignored'
                    THEN audit.quarantine.resolution_note
                ELSE NULL
            END;

        TRUNCATE staging.order_reviews;

        INSERT INTO staging.order_reviews (
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
            t.score_value::smallint,
            t.review_comment_title,
            t.review_comment_message,
            t.created_value,
            t.answer_value,
            v_loaded_at,
            t.source_name,
            staging.hash_key(
                t.review_id,
                t.order_id,
                t.score_value::text,
                t.review_comment_title,
                t.review_comment_message,
                t.created_value::text,
                t.answer_value::text
            )
        FROM tmp_order_reviews t
        WHERE t.rule_code IS NULL;
        GET DIAGNOSTICS v_ins = ROW_COUNT;

        UPDATE audit.quarantine q
        SET
            status = 'resolved',
            resolved_at = v_loaded_at,
            resolution_note = 'не отклонено в batch ' || p_batch
        WHERE q.table_name = 'order_reviews'
            AND q.status = 'open'
            AND q.last_step_id <> v_step_id
            AND (
                v_type = 'full'
                OR EXISTS (
                    SELECT 1
                    FROM staging.order_reviews sr
                    WHERE
                        replace(sr.review_id::text, '-', '')
                            || '|' ||
                        replace(sr.order_id::text, '-', '')
                            = q.business_key));
    
        SELECT count(*)
        INTO v_fix
        FROM tmp_order_reviews t
        WHERE t.rule_code IS NULL;

        IF v_read <> v_ins + v_rej THEN
            RAISE EXCEPTION
                'инвариант нарушен: прочитано=%, вставлено=%, отклонено=%',
                v_read,
                v_ins,
                v_rej;
        END IF;

    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        v_read := 0;
        v_ins := 0;
        v_rej := 0;
        v_fix := 0;
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
        rows_fixed = v_fix,
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
            'load_stg_order_reviews провален: %', v_error;
    END IF;
END
$$;
