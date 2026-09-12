-- FOCUS is Preview. A non zero delta is a finding, not a bug to hide. Nobody
-- has published this reconciliation on a real agent workload.
--
-- Verify current FOCUS column names against Google's schema reference first.
-- Run SELECT * ... LIMIT 5 and look, do not assume.
WITH focus AS (
  SELECT ROUND(SUM(BilledCost), 6) AS total
  FROM `BILLING_PROJECT.FOCUS_DATASET.gcp_billing_export_focus_BILLING_ACCOUNT`
  WHERE DATE(ChargePeriodStart) BETWEEN 'START_DATE' AND 'END_DATE'
),
detailed AS (
  SELECT ROUND(SUM(cost), 6) AS total
  FROM `BILLING_PROJECT.DATASET.gcp_billing_export_resource_v1_BILLING_ACCOUNT`
  WHERE DATE(usage_start_time) BETWEEN 'START_DATE' AND 'END_DATE'
)
SELECT
  focus.total                        AS focus_total,
  detailed.total                     AS detailed_total,
  ROUND(focus.total - detailed.total, 6) AS delta,
  ROUND(100 * SAFE_DIVIDE(focus.total - detailed.total, detailed.total), 3) AS delta_pct
FROM focus, detailed;
