CREATE OR REPLACE VIEW component_status AS
WITH ranked_checks AS (
    SELECT components.name AS component_name,
           checks.*,
           ROW_NUMBER() OVER (PARTITION BY component_id ORDER BY checked_at DESC) AS rn
    FROM checks
    JOIN components ON components.id = checks.component_id
    WHERE checked_at > now() - interval '15 minutes'
      AND is_active
),
check_counts AS (
    SELECT component_id,
           component_name,
           count(id) AS total,
           count(id) FILTER (WHERE status_code IS NULL OR status_code < 200 OR status_code > 399) AS failed,
           count(id) FILTER (WHERE duration_ms > 1000 AND status_code BETWEEN 200 AND 399) AS slow
    FROM ranked_checks
    WHERE rn <= 5
    GROUP BY component_id, component_name
)
SELECT s.*,
       component_states.description AS status,
       component_states.severity
FROM (
    SELECT *,
           CASE
               WHEN failed = total THEN 'down'
               WHEN failed > 0     THEN 'partial_outage'
               WHEN slow >= 3      THEN 'degraded'
               ELSE 'operational'
           END AS status_code
    FROM check_counts
) AS s
JOIN component_states ON component_states.code = s.status_code;
