CREATE TABLE IF NOT EXISTS audit.batch (
    batch_name text PRIMARY KEY,
    type text NOT NULL DEFAULT 'full' CHECK (type IN ('full', 'delta')),
    description text
);

CREATE TABLE IF NOT EXISTS audit.run (
    run_id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_name text NOT NULL,
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at timestamptz,
    status text NOT NULL DEFAULT 'running'
        CHECK (status IN ('running','success','failed'))
);

CREATE TABLE IF NOT EXISTS audit.run_step (
    step_id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id int NOT NULL REFERENCES audit.run(run_id),
    stage text NOT NULL,
    table_name text NOT NULL,
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at timestamptz,
    status text NOT NULL DEFAULT 'running'
        CHECK (status IN ('running','success','failed')),
    rows_read int,
    rows_inserted int,
    rows_updated int,
    rows_rejected int,
    error_message text
);

CREATE TABLE IF NOT EXISTS audit.reject_rule (
    rule_code text PRIMARY KEY,
    table_name text NOT NULL,
    column_name text,
    description text NOT NULL,
    action text NOT NULL CHECK (action IN ('reject', 'fix'))
);

CREATE TABLE IF NOT EXISTS audit.reject (
    reject_id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    step_id int NOT NULL REFERENCES audit.run_step(step_id),
    table_name text NOT NULL,
    rule_code text NOT NULL REFERENCES audit.reject_rule(rule_code),
    business_key text,
    source_row jsonb NOT NULL,
    rejected_at  timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS audit.quarantine (
    quarantine_id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name text NOT NULL,
    rule_code text NOT NULL REFERENCES audit.reject_rule(rule_code),
    row_fingerprint text NOT NULL,
    business_key text,
    source_row jsonb NOT NULL,
    batch_name text NOT NULL,
    first_step_id int NOT NULL REFERENCES audit.run_step(step_id),
    last_step_id int NOT NULL REFERENCES audit.run_step(step_id),
    first_seen_at timestamptz NOT NULL,
    last_seen_at timestamptz NOT NULL,
    occurrences int NOT NULL DEFAULT 1,
    status text NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'resolved', 'ignored')),
    resolved_at timestamptz,
    resolution_note text,

    UNIQUE (table_name, rule_code, row_fingerprint)
);

CREATE INDEX IF NOT EXISTS ix_reject_step_key
    ON audit.reject (step_id, business_key);

CREATE INDEX IF NOT EXISTS ix_quarantine_open
    ON audit.quarantine (table_name, status);

CREATE OR REPLACE VIEW audit.v_quarantine AS
SELECT q.*, r.description AS rule_description, r.action AS rule_action
FROM audit.quarantine q
JOIN audit.reject_rule r ON r.rule_code = q.rule_code;

CREATE OR REPLACE VIEW audit.v_quarantine_summary AS
SELECT table_name, rule_code, status, count(*) AS rows_cnt, sum(occurrences) AS copies
FROM audit.quarantine
GROUP BY table_name, rule_code, status;
