-- The headline unit.
--
-- Hosting and model split out deliberately: most people assume the model
-- dominates, and at low traffic it may not. That split is the finding.
--
-- Tokens use total_tokens, never prompt+completion. Gemini bills reasoning
-- tokens that never appear in the response text, charged at the output rate.
-- On a trivial prompt they were 37 of a 95 token total.
WITH spend AS (
  SELECT
    CASE
      WHEN service.description LIKE '%Cloud Run%'        THEN 'hosting'
      WHEN service.description LIKE '%Vertex%'           THEN 'model'
      WHEN service.description LIKE '%Artifact Registry%' THEN 'build'
      WHEN service.description LIKE '%Cloud Build%'      THEN 'build'
      ELSE 'other'
    END AS bucket,
    SUM(cost) AS cost
  FROM `BILLING_PROJECT.DATASET.gcp_billing_export_resource_v1_BILLING_ACCOUNT`
  WHERE usage_start_time >= TIMESTAMP('WINDOW_START')
    AND usage_start_time <  TIMESTAMP('WINDOW_END')
    AND project.id = 'PROJECT_ID'
  GROUP BY 1
),
runs AS (
  SELECT
    COUNT(*)                AS invocations,
    SUM(total_tokens)       AS total_tokens,
    SUM(prompt_tokens)      AS prompt_tokens,
    SUM(completion_tokens)  AS completion_tokens,
    SUM(thoughts_tokens)    AS thoughts_tokens
  FROM `BILLING_PROJECT.DATASET.load_results`
  WHERE run_id = 'RUN_ID'
    AND status = 200
    AND profile != 'filmdemo'          -- camera only, never in the analysis
)
SELECT
  spend.bucket,
  ROUND(spend.cost, 6)                                              AS cost,
  runs.invocations,
  ROUND(SAFE_DIVIDE(spend.cost * 1000, runs.invocations), 6)        AS cost_per_1k_invocations,
  runs.total_tokens,
  ROUND(SAFE_DIVIDE(spend.cost * 1000000, runs.total_tokens), 6)    AS cost_per_1m_tokens
FROM spend, runs
ORDER BY cost DESC;
