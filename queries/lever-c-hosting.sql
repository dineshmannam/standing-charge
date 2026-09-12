-- Lever C. Cloud Run versus Agent Runtime.
--
-- These bill on different models, so cost per hour is meaningless. Cost per
-- thousand invocations is the only fair unit.
SELECT
  project.id                     AS host_project,
  service.description            AS service,
  ROUND(SUM(cost), 6)            AS cost
FROM `BILLING_PROJECT.DATASET.gcp_billing_export_resource_v1_BILLING_ACCOUNT`
WHERE usage_start_time >= TIMESTAMP('WINDOW_START')
  AND usage_start_time <  TIMESTAMP('WINDOW_END')
  AND project.id = 'PROJECT_LEVER_C'
GROUP BY 1, 2
ORDER BY cost DESC;
