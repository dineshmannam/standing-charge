-- One dataset, three projects. Separation happens here, not in the export.
-- Reused projects mean the boundary is project PLUS time window, so bound the
-- window with the exact UTC times from evidence/wallclock.csv.
SELECT
  project.id                       AS project,
  service.description              AS service,
  sku.description                  AS sku,
  ROUND(SUM(cost), 6)              AS cost,
  ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 6) AS credits
FROM `BILLING_PROJECT.DATASET.gcp_billing_export_resource_v1_BILLING_ACCOUNT`
WHERE usage_start_time >= TIMESTAMP('WINDOW_START')
  AND usage_start_time <  TIMESTAMP('WINDOW_END')
  AND project.id IN ('sc-lever-a-idle','sc-lever-b-context','sc-lever-c-hosting')
GROUP BY 1, 2, 3
ORDER BY project, cost DESC;
