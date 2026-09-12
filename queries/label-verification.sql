-- THE GATE. Proves a resource label actually reaches billing export.
-- If this returns nothing, the sweep collects data you cannot attribute.
SELECT
  label.value           AS run_id,
  project.id            AS project,
  service.description   AS service,
  COUNT(*)              AS row_count,
  ROUND(SUM(cost), 6)   AS cost,
  MIN(usage_start_time) AS first_seen
FROM `BILLING_PROJECT.DATASET.gcp_billing_export_resource_v1_BILLING_ACCOUNT`,
  UNNEST(labels) AS label
WHERE label.key = 'run-id'
  AND DATE(usage_start_time) >= DATE_SUB(CURRENT_DATE(), INTERVAL 3 DAY)
GROUP BY 1, 2, 3
ORDER BY first_seen DESC;
