CREATE OR REPLACE PROCEDURE etl.load_stg_products(p_batch text,p_run_id int DEFAULT NULL)
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
        INSERT INTO audit.run(batch_name) VALUES(p_batch) RETURNING run_id INTO v_run_id;
        v_own_run := true;
    END IF;

    INSERT INTO audit.run_step(run_id,stage,table_name)
    VALUES(v_run_id,'load_stg','products') RETURNING step_id INTO v_step_id;

    SELECT started_at INTO v_loaded_at FROM audit.run WHERE run_id=v_run_id;
    COMMIT;

    BEGIN
        PERFORM etl.assert_prev_stage('load_raw','products',p_batch,v_run_id);
        SELECT count(*) INTO v_read FROM raw.products;

        CREATE TEMP TABLE tmp_products ON COMMIT DROP AS
        WITH normalized AS (
            SELECT r.source_name,
                NULLIF(lower(trim(r.product_id)),'')
                    AS product_id,
                NULLIF(trim(r.product_category_name),'')
                    AS product_category_name,
                NULLIF(trim(r.product_name_length),'')
                    AS name_raw,
                NULLIF(trim(r.product_description_length),'')
                    AS description_raw,
                NULLIF(trim(r.product_photos_qty),'')
                    AS photos_raw,
                NULLIF(trim(r.product_weight_g),'')
                    AS weight_raw,
                NULLIF(trim(r.product_length_cm),'')
                    AS length_raw,
                NULLIF(trim(r.product_height_cm),'')
                    AS height_raw,
                NULLIF(trim(r.product_width_cm),'')
                    AS width_raw,
                to_jsonb(r) AS source_row,
                md5(jsonb_build_array(r.product_id,r.product_category_name,
                    r.product_name_length,r.product_description_length,
                    r.product_photos_qty,r.product_weight_g,r.product_length_cm,
                    r.product_height_cm,r.product_width_cm)::text) AS src_hash
            FROM raw.products r
        ), validated AS (
            SELECT normalized.*,
                CASE
                    WHEN product_id IS NULL OR product_id !~ '^[0-9a-f]{32}$'
                        THEN 'PROD_ID_FORMAT'
                    WHEN name_raw IS NOT NULL AND name_raw !~ '^[0-9]+$'
                        THEN 'PROD_NAMELEN_FORMAT'
                    WHEN name_raw IS NOT NULL AND (name_raw::numeric < 0 OR name_raw::numeric > 32767)
                        THEN 'PROD_NAMELEN_RANGE'
                    WHEN description_raw IS NOT NULL AND description_raw !~ '^[0-9]+$'
                        THEN 'PROD_DESCLEN_FORMAT'
                    WHEN description_raw IS NOT NULL AND (description_raw::numeric < 0 OR description_raw::numeric > 32767)
                        THEN 'PROD_DESCLEN_RANGE'
                    WHEN photos_raw IS NOT NULL AND photos_raw !~ '^[0-9]+$'
                        THEN 'PROD_PHOTOS_FORMAT'
                    WHEN photos_raw IS NOT NULL AND (photos_raw::numeric < 0 OR photos_raw::numeric > 32767)
                        THEN 'PROD_PHOTOS_RANGE'
                    WHEN weight_raw IS NOT NULL AND weight_raw !~ '^[0-9]+$'
                        THEN 'PROD_WEIGHT_FORMAT'
                    WHEN weight_raw IS NOT NULL AND (weight_raw::numeric < 0 OR weight_raw::numeric > 2147483647)
                        THEN 'PROD_WEIGHT_RANGE'
                    WHEN length_raw IS NOT NULL AND length_raw !~ '^[0-9]+$'
                        THEN 'PROD_LENGTH_FORMAT'
                    WHEN length_raw IS NOT NULL AND (length_raw::numeric < 0 OR length_raw::numeric > 32767)
                        THEN 'PROD_LENGTH_RANGE'
                    WHEN height_raw IS NOT NULL AND height_raw !~ '^[0-9]+$'
                        THEN 'PROD_HEIGHT_FORMAT'
                    WHEN height_raw IS NOT NULL AND (height_raw::numeric < 0 OR height_raw::numeric > 32767)
                        THEN 'PROD_HEIGHT_RANGE'
                    WHEN width_raw IS NOT NULL AND width_raw !~ '^[0-9]+$'
                        THEN 'PROD_WIDTH_FORMAT'
                    WHEN width_raw IS NOT NULL AND (width_raw::numeric < 0 OR width_raw::numeric > 32767)
                        THEN 'PROD_WIDTH_RANGE'
                END AS basic_rule
            FROM normalized
        ), deduplicated AS (
            SELECT validated.*,
                row_number() OVER(
                    PARTITION BY product_id,(basic_rule IS NULL)
                    ORDER BY src_hash
                ) AS rn
            FROM validated
        )
        SELECT deduplicated.*,
            CASE
                WHEN basic_rule IS NOT NULL THEN basic_rule
                WHEN rn>1 THEN 'PROD_ID_DUPLICATE'
            END AS rule_code
        FROM deduplicated;

        INSERT INTO audit.reject(
            step_id,
            table_name,
            rule_code,
            business_key,
            source_row,
            rejected_at)
        SELECT 
            v_step_id,
            'products',
            t.rule_code,
            coalesce(t.product_id,t.source_row->>'product_id'),
            t.source_row,
            v_loaded_at
        FROM tmp_products t WHERE t.rule_code IS NOT NULL;
        GET DIAGNOSTICS v_rej = ROW_COUNT;

        INSERT INTO audit.quarantine(
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
            'products',
            t.rule_code,
            t.src_hash,
            min(coalesce(t.product_id,t.source_row->>'product_id')),
            (array_agg(t.source_row))[1],
            p_batch,
            v_step_id,
            v_step_id,
            v_loaded_at,
            v_loaded_at,count(*)
        FROM tmp_products t
        WHERE t.rule_code IS NOT NULL
        GROUP BY t.rule_code,t.src_hash
        ON CONFLICT(table_name,rule_code,row_fingerprint) DO UPDATE
        SET batch_name = EXCLUDED.batch_name,
            last_step_id = EXCLUDED.last_step_id,
            last_seen_at = EXCLUDED.last_seen_at,
            occurrences = EXCLUDED.occurrences,
            source_row = EXCLUDED.source_row,
            status = CASE WHEN audit.quarantine.status='ignored' 
                THEN 'ignored' ELSE 'open' END,
            resolved_at=CASE WHEN audit.quarantine.status='ignored'
                THEN audit.quarantine.resolved_at ELSE NULL END,
            resolution_note=CASE WHEN audit.quarantine.status='ignored'
                THEN audit.quarantine.resolution_note ELSE NULL END;

        TRUNCATE staging.products;

        INSERT INTO staging.products(
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
            row_hash)
        SELECT
            t.product_id::uuid,
            t.product_category_name,
            t.name_raw::smallint,
            t.description_raw::smallint,
            t.photos_raw::smallint,
            t.weight_raw::int,
            t.length_raw::smallint,
            t.height_raw::smallint,
            t.width_raw::smallint,
            v_loaded_at,
            t.source_name,
            staging.hash_key(t.product_category_name,t.name_raw,t.description_raw,
                t.photos_raw,t.weight_raw,t.length_raw,t.height_raw,t.width_raw)
        FROM tmp_products t
        WHERE t.rule_code IS NULL;
        GET DIAGNOSTICS v_ins = ROW_COUNT;

        UPDATE audit.quarantine q
        SET 
            status = 'resolved',
            resolved_at = v_loaded_at,
            resolution_note ='не отклонено в batch '||p_batch
        WHERE q.table_name ='products' AND q.status='open'
            AND q.last_step_id<>v_step_id
            AND (v_type='full' OR EXISTS(
                SELECT 1 FROM staging.products sp
                WHERE replace(sp.product_id::text,'-','')=q.business_key));

        IF v_read<>v_ins+v_rej THEN
            RAISE EXCEPTION
                'инвариант нарушен: прочитано=%, вставлено=%, отклонено=%',v_read,v_ins,v_rej;
        END IF;

    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
        v_read:=0; v_ins:=0; v_rej:=0; v_fix:=0;
    END;

    UPDATE audit.run_step
    SET status=CASE WHEN v_error IS NULL THEN 'success' ELSE 'failed' END,
        rows_read=v_read,rows_inserted=v_ins,rows_rejected=v_rej,
        rows_fixed=v_fix,error_message=v_error,finished_at=clock_timestamp()
    WHERE step_id=v_step_id;

    IF v_own_run THEN
        UPDATE audit.run
        SET status=CASE WHEN v_error IS NULL THEN 'success' ELSE 'failed' END,
            finished_at=clock_timestamp()
        WHERE run_id=v_run_id;
    END IF;
    COMMIT;

    IF v_error IS NOT NULL AND v_own_run THEN
        RAISE EXCEPTION 'load_stg_products провален: %',v_error;
    END IF;
END
$$;
