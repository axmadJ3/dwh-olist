CREATE TABLE audit.run (
    run_id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at timestamptz,
    status text NOT NULL DEFAULT 'running'
        CHECK (status IN ('running','success','failed'))
);

CREATE TABLE audit.run_step (
    step_id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id int NOT NULL REFERENCES audit.run(run_id),
    stage text NOT NULL,
    table_name text,
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at timestamptz,
    statustext NOT NULL DEFAULT 'running' 
        CHECK (status IN ('running','success','failed')),
    rows_read int,
    error_message text
);
