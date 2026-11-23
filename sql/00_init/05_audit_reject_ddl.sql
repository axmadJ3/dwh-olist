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

CREATE INDEX IF NOT EXISTS ix_reject_step_id ON audit.reject (step_id);
