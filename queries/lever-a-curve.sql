-- Lever A. The chart the video is built around.
--
-- x: requests per hour.  y: cost per 1k invocations.
-- Two lines: min-instances 1 versus 0. Where they cross is the answer.
--
-- Expect min=1 to be flat and high at low traffic, falling as traffic rises.
-- Expect min=0 to be nearly flat. If they never cross inside your range, say so.
-- That is also a finding, and a more useful one than a manufactured crossover.
--
-- run_id encodes the arm, e.g. run-2026-09-03-min0-steady
WITH runs AS (
  SELECT
    run_id,
    profile,
    REGEXP_EXTRACT(run_id, r'min([01])')             AS min_instances,
    COUNT(*)                                          AS invocations,
    SUM(total_tokens)                                 AS total_tokens,
    MIN(utc_time)                                     AS window_start,
    MAX(utc_time)                                     AS window_end,
    APPROX_QUANTILES(latency_ms, 100)[OFFSET(50)]     AS p50_latency_ms,
    APPROX_QUANTILES(latency_ms, 100)[OFFSET(95)]     AS p95_latency_ms,
    COUNTIF(cold_hint = 'likely')                     AS cold_hints
  FROM `BILLING_PROJECT.DATASET.load_results`
  WHERE lever = 'A' AND status = 200 AND profile != 'filmdemo'
  GROUP BY 1, 2
),
spend AS (
  SELECT
    (SELECT value FROM UNNEST(labels) WHERE key = 'run-id') AS run_id,
    SUM(IF(service.description LIKE '%Cloud Run%', cost, 0)) AS hosting_cost,
    SUM(IF(service.description LIKE '%Vertex%',    cost, 0)) AS model_cost,
    SUM(cost)                                                AS total_cost
  FROM `BILLING_PROJECT.DATASET.gcp_billing_export_resource_v1_BILLING_ACCOUNT`
  WHERE project.id = 'PROJECT_ID'
  GROUP BY 1
)
SELECT
  runs.profile,
  runs.min_instances,
  runs.invocations,
  ROUND(3600 * SAFE_DIVIDE(runs.invocations,
    TIMESTAMP_DIFF(runs.window_end, runs.window_start, SECOND)), 1) AS requests_per_hour,
  ROUND(spend.hosting_cost, 6)                                      AS hosting_cost,
  ROUND(spend.model_cost, 6)                                        AS model_cost,
  ROUND(SAFE_DIVIDE(spend.hosting_cost * 1000, runs.invocations), 6) AS hosting_per_1k,
  ROUND(SAFE_DIVIDE(spend.total_cost   * 1000, runs.invocations), 6) AS total_per_1k,
  runs.p50_latency_ms,
  runs.p95_latency_ms,
  runs.cold_hints
FROM runs
JOIN spend USING (run_id)
ORDER BY runs.min_instances, requests_per_hour;
