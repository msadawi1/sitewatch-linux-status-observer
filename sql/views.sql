-- Site Watch views
-- Run as the sitewatch role:
--   sudo -u sitewatch psql -d sitewatch_db -v ON_ERROR_STOP=1 -f sql/views.sql
-- Safe to re-run. Runs in one transaction.

begin;

-- ---------------------------------------------------------------------------
-- component_status: one row per active component, its state worked out from
-- its last 5 checks within the last 15 minutes.
--   down            every recent check failed
--   partial_outage  some failed
--   degraded        all succeeded, but 3 or more were slow (over 1000 ms)
--   operational     otherwise
-- A check succeeded if it has a status code from 200 to 399.
--
-- Dropped and recreated (not CREATE OR REPLACE) because the column list changed:
-- CREATE OR REPLACE VIEW can only add new columns at the end.
-- ---------------------------------------------------------------------------

drop view if exists component_status;

create view component_status as
with ranked_checks as (
    select components.name as component_name,
           checks.*,
           row_number() over (partition by component_id order by checked_at desc) as rn
    from checks
    join components on components.id = checks.component_id
    where checked_at > now() - interval '15 minutes'
      and is_active
),
check_counts as (
    select component_id,
           component_name,
           max(checked_at) as last_checked_at,
           count(id) as total,
           count(id) filter (where status_code is null or status_code < 200 or status_code > 399) as failed,
           count(id) filter (where duration_ms > 1000 and status_code between 200 and 399) as slow
    from ranked_checks
    where rn <= 5
    group by component_id, component_name
),
with_state as (
    select *,
           case
               when failed = total then 'down'
               when failed > 0     then 'partial_outage'
               when slow >= 3      then 'degraded'
               else 'operational'
           end as status_code
    from check_counts
)
select w.component_id,
       w.component_name,
       w.last_checked_at,
       w.total,
       w.failed,
       w.slow,
       w.status_code,
       component_states.description as status,
       component_states.severity
from with_state w
join component_states on component_states.code = w.status_code;

-- ---------------------------------------------------------------------------
-- checker_health: one row. Is the checker still running?
-- Stale = no check in the last 5 minutes, or no checks at all
-- (max() of an empty table is NULL, and NULL must count as stale, never as fine).
-- Looks at all checks, not just the last 15 minutes, so it also catches a checker
-- that has been dead for days.
-- ---------------------------------------------------------------------------

create or replace view checker_health as
select max(checked_at) as last_checked_at,
       max(checked_at) is null
           or max(checked_at) < now() - interval '5 minutes' as is_stale
from checks;

commit;
