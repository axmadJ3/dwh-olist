
CREATE OR REPLACE PROCEDURE etl.load_stg_order_items(
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
    v_type text := etl.batch_kind(p_batch);
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

    INSERT INTO audit.run_step (
        run_id,
        stage,
        table_name)
    VALUES (
        v_run_id,
        'load_stg',
        'order_items')
    RETURNING step_id INTO v_step_id;

    SELECT started_at
    INTO v_loaded_at
    FROM audit.run
    WHERE run_id = v_run_id;

    COMMIT;

    BEGIN
        PERFORM etl.assert_prev_stage(
            'load_raw',
            'order_items',
            p_batch,
            v_run_id
        );

        SELECT count(*)
        INTO v_read
        FROM raw.order_items;

        CREATE TEMPORARY TABLE tmp_order_items ON COMMIT DROP AS
        WITH normalized AS (
            SELECT
                r.source_name,

                NULLIF(lower(trim(r.order_id)), '')
                    AS order_id,
                NULLIF(trim(r.order_item_id), '')
                    AS order_item_id_raw,
                NULLIF(lower(trim(r.product_id)), '')
                    AS product_id,
                NULLIF(lower(trim(r.seller_id)), '')
                    AS seller_id,
                NULLIF(trim(r.shipping_limit_date), '')
                    AS shipping_limit_raw,
                NULLIF(trim(r.price), '')
                    AS price_raw,
                NULLIF(trim(r.freight_value), '')
                    AS freight_raw,
                to_jsonb(r) AS source_row,
                md5(jsonb_build_array(
                    r.order_id,
                    r.order_item_id,
                    r.product_id,
                    r.seller_id,
                    r.shipping_limit_date,
                    r.price,
                    r.freight_value
                )::text) AS src_hash
            FROM raw.order_items r
        ), validated AS (
            SELECT
                normalized.*,
                CASE
                    WHEN order_id IS NULL THEN 'ITEM_ORDER_ID_EMPTY'
                    WHEN order_id !~ '^[0-9a-f]{32}$'
                        THEN 'ITEM_ORDER_ID_FORMAT'
                    WHEN order_item_id_raw IS NULL THEN 'ITEM_NO_EMPTY'
                    WHEN order_item_id_raw !~ '^[0-9]+$'
                        THEN 'ITEM_NO_FORMAT'
                    WHEN order_item_id_raw::numeric < 1
                        OR order_item_id_raw::numeric > 32767
                        THEN 'ITEM_NO_RANGE'
                    WHEN product_id IS NULL THEN 'ITEM_PRODUCT_ID_EMPTY'
                    WHEN product_id !~ '^[0-9a-f]{32}$'
                        THEN 'ITEM_PRODUCT_ID_FORMAT'
                    WHEN seller_id IS NULL THEN 'ITEM_SELLER_ID_EMPTY'
                    WHEN seller_id !~ '^[0-9a-f]{32}$'
                        THEN 'ITEM_SELLER_ID_FORMAT'
                    WHEN shipping_limit_raw IS NULL
                        OR NOT pg_input_is_valid(
                            shipping_limit_raw,
                            'timestamp')
                        THEN 'ITEM_SHIPLIM_FORMAT'
                    WHEN price_raw IS NULL
                        OR NOT pg_input_is_valid(
                            price_raw,
                            'numeric')
                        THEN 'ITEM_PRICE_FORMAT'
                    WHEN price_raw::numeric < 0
                        OR price_raw::numeric >= 100000000
                        OR scale(price_raw::numeric) > 2
                        THEN 'ITEM_PRICE_RANGE'
                    WHEN freight_raw IS NULL
                        OR NOT pg_input_is_valid(
                            freight_raw,
                            'numeric')
                        THEN 'ITEM_FREIGHT_FORMAT'
                    WHEN freight_raw::numeric < 0
                        OR freight_raw::numeric >= 100000000
                        OR scale(freight_raw::numeric) > 2
                        THEN 'ITEM_FREIGHT_RANGE'
                END AS basic_rule
            FROM normalized
        ), deduplicated AS (
            SELECT
                validated.*,
                row_number() OVER (
                    PARTITION BY
                        order_id,
                        order_item_id_raw,
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
                    THEN 'ITEM_KEY_DUPLICATE'
            END AS rule_code
        FROM deduplicated;

        INSERT INTO audit.reject (
            step_id,
            table_name,
            rule_code,
            business_key,
            source_row,
            rejected_at)
        SELECT
            v_step_id,
            'order_items',
            t.rule_code,
            concat_ws(
                '|',
                COALESCE(
                    t.order_id,
                    t.source_row ->> 'order_id'
                ),
                COALESCE(
                    t.order_item_id_raw,
                    t.source_row ->> 'order_item_id'
                )
            ),
            t.source_row,
            v_loaded_at
        FROM tmp_order_items t
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
            occurrences)
        SELECT
            'order_items',
            t.rule_code,
            t.src_hash,
            min(
                concat_ws(
                    '|',
                    COALESCE(
                        t.order_id,
                        t.source_row ->> 'order_id'
                    ),
                    COALESCE(
                        t.order_item_id_raw,
                        t.source_row ->> 'order_item_id'
                    )
                )
            ),
            (array_agg(t.source_row))[1],
            p_batch,
            v_step_id,
            v_step_id,
            v_loaded_at,
            v_loaded_at,
            count(*)
        FROM tmp_order_items t
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
            occurrences =
                audit.quarantine.occurrences
                + EXCLUDED.occurrences,
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

        TRUNCATE staging.order_items;

        INSERT INTO staging.order_items (
            order_id,
            order_item_id,
            product_id,
            seller_id,
            shipping_limit_date,
            price,
            freight_value,
            loaded_at,
            source_name,
            row_hash)
        SELECT
            t.order_id::uuid,
            t.order_item_id_raw::smallint,
            t.product_id::uuid,
            t.seller_id::uuid,
            t.shipping_limit_raw::timestamp,
            t.price_raw::numeric(10,2),
            t.freight_raw::numeric(10,2),
            v_loaded_at,
            t.source_name,
            staging.hash_key(
                t.order_id,
                t.order_item_id_raw,
                t.product_id,
                t.seller_id,
                t.shipping_limit_raw,
                t.price_raw,
                t.freight_raw)
        FROM tmp_order_items t
        WHERE t.rule_code IS NULL
        ON CONFLICT (order_id, order_item_id)
        DO UPDATE SET
            product_id = EXCLUDED.product_id,
            seller_id = EXCLUDED.seller_id,
            shipping_limit_date =
                EXCLUDED.shipping_limit_date,
            price = EXCLUDED.price,
            freight_value = EXCLUDED.freight_value,
            loaded_at = EXCLUDED.loaded_at,
            source_name = EXCLUDED.source_name,
            row_hash = EXCLUDED.row_hash;
        GET DIAGNOSTICS v_ins = ROW_COUNT;

        UPDATE audit.quarantine q
        SET
            status = 'resolved',
            resolved_at = v_loaded_at,
            resolution_note = 'не отклонено в batch ' || p_batch
        WHERE q.table_name = 'order_items'
            AND q.status = 'open'
            AND q.last_step_id <> v_step_id
            AND (
                v_type = 'full'
                OR EXISTS (
                    SELECT 1
                    FROM staging.order_items soi
                    WHERE concat_ws(
                        '|',
                        replace(soi.order_id::text, '-', ''),
                        soi.order_item_id::text
                    ) = q.business_key
                )
            );

        IF v_read <> v_ins + v_rej THEN
            RAISE EXCEPTION
                'инвариант нарушен: прочитано=%, вставлено=%, отклонено=%',
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
            'load_stg_order_items провален: %',
            v_error;
    END IF;
END
$$;
