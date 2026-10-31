-- Site Watch schema
-- Run as the sitewatch role
-- The whole file runs in one transaction: if any statement fails, nothing is created.

begin;

-- ---------------------------------------------------------------------------
-- Lookup tables (fixed rows, seeded at the bottom of this file)
-- ---------------------------------------------------------------------------

create table component_states (
    id          smallint primary key,
    code        text     not null unique,
    description text     not null,                 -- shown on the board
    severity    smallint not null unique check (severity between 0 and 3)
);

create table incident_states (
    id          smallint primary key,
    code        text     not null unique,
    description text     not null,                 -- shown on the board
    step        smallint not null unique check (step between 1 and 4)
);

-- ---------------------------------------------------------------------------
-- Components: what is monitored. Rows come from sql/components.sql.
-- Retire a component with is_active = false; never delete it (history depends on it).
-- ---------------------------------------------------------------------------

create table components (
    id          smallint    generated always as identity primary key,
    name        text        not null unique,
    url         text        not null,
    is_internal boolean     not null,
    is_active   boolean     not null default true,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Checks: one row per component per minute. Everything else is calculated from here.
-- ---------------------------------------------------------------------------

create table checks (
    id           bigint      generated always as identity primary key,
    component_id smallint    not null references components (id),
    checked_at   timestamptz not null default now(),
    status_code  smallint    check (status_code between 100 and 599),  -- null = no answer
    duration_ms  integer     not null check (duration_ms >= 0),        -- how long the check took, whatever the outcome
    error        text,                                                 -- null = got an answer

    -- exactly one of the two: an answer (status_code) or a failure reason (error)
    constraint checks_status_code_xor_error check (num_nonnulls(status_code, error) = 1)
);

-- almost every query asks "this component, its most recent checks"
create index checks_component_checked_at_idx on checks (component_id, checked_at desc);

-- ---------------------------------------------------------------------------
-- Incidents and their timeline
-- ---------------------------------------------------------------------------

create table incidents (
    id           integer     generated always as identity primary key,
    component_id smallint    not null references components (id),
    title        text        not null,
    started_at   timestamptz not null default now(),
    resolved_at  timestamptz,                                          -- null = still open; set by trigger
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now(),

    constraint incidents_resolved_after_started check (resolved_at is null or resolved_at >= started_at)
);

-- a component never has two open incidents
create unique index incidents_one_open_per_component on incidents (component_id) where resolved_at is null;

create table incident_updates (
    id                integer     generated always as identity primary key,
    incident_id       integer     not null references incidents (id),
    incident_state_id smallint    not null references incident_states (id),
    message           text        not null,
    created_at        timestamptz not null default now()
);

-- "latest update for this incident" and the timeline on the board
create index incident_updates_incident_created_idx on incident_updates (incident_id, created_at);

-- ---------------------------------------------------------------------------
-- Trigger: keep updated_at current on every UPDATE
-- ---------------------------------------------------------------------------

create function set_updated_at() returns trigger
language plpgsql as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

create trigger components_set_updated_at
    before update on components
    for each row execute function set_updated_at();

create trigger incidents_set_updated_at
    before update on incidents
    for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- Trigger: the incident timeline rules
--   1. no updates once an incident is resolved
--   2. the state never moves backwards (staying on the same step is allowed)
--   3. a "resolved" update closes the incident (sets incidents.resolved_at)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION check_incident_update() RETURNS trigger AS $$
        DECLARE
                v_incident_resolved_at TIMESTAMPTZ;
                v_state_code TEXT;
                v_new_step SMALLINT;
                v_latest_step SMALLINT;
        BEGIN
                -- 1. Throw error if incident is already resolved
                --    FOR UPDATE locks the incident row until this transaction ends,
                --    so two updates posted at the same moment are checked one after the other
                SELECT resolved_at INTO v_incident_resolved_at
                FROM incidents
                WHERE id = NEW.incident_id
                FOR UPDATE;

                IF v_incident_resolved_at IS NOT NULL THEN
                        RAISE EXCEPTION 'Incident with id % was already resolved at %', NEW.incident_id, v_incident_resolved_at;
                END IF;

                -- Look up the new update's state
                SELECT code, step INTO v_state_code, v_new_step
                FROM incident_states
                WHERE id = NEW.incident_state_id;

                -- 2. Throw error if the state moves backwards (staying on the same step is allowed)
                SELECT s.step INTO v_latest_step
                FROM incident_updates u
                JOIN incident_states s ON s.id = u.incident_state_id
                WHERE u.incident_id = NEW.incident_id
                ORDER BY u.created_at DESC, u.id DESC
                LIMIT 1;

                IF v_latest_step IS NOT NULL AND v_new_step < v_latest_step THEN
                        RAISE EXCEPTION 'Incident with id % cannot move back from step % to step %', NEW.incident_id, v_latest_step, v_new_step;
                END IF;

                -- 3. Resolve the incident if the update is `resolved`
                IF v_state_code = 'resolved' THEN
                        UPDATE incidents SET resolved_at = NEW.created_at WHERE id = NEW.incident_id;
                END IF;

                RETURN NEW;
        END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER incident_update_check BEFORE INSERT ON incident_updates
FOR EACH ROW EXECUTE FUNCTION check_incident_update();

-- ---------------------------------------------------------------------------
-- Seed the lookup tables
-- ---------------------------------------------------------------------------

insert into component_states (id, code, description, severity) values
    (1, 'operational',    'Operational',          0),
    (2, 'degraded',       'Degraded Performance', 1),
    (3, 'partial_outage', 'Partial Outage',       2),
    (4, 'down',           'Major Outage',         3);

insert into incident_states (id, code, description, step) values
    (1, 'investigating', 'Investigating', 1),
    (2, 'identified',    'Identified',    2),
    (3, 'monitoring',    'Monitoring',    3),
    (4, 'resolved',      'Resolved',      4);

commit;
