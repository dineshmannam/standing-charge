-- The thinking token finding.
--
-- Gemini returns thoughtsTokenCount separately. Those tokens are billed at the
-- output rate and never appear in the response text. Summing the visible parts
-- undercounts the bill.
--
-- This is its own segment in the video: you are paying for output you cannot
-- read.
SELECT
  profile,
  session_mode,
  COUNT(*)                                                    AS invocations,
  SUM(prompt_tokens)                                          AS prompt_tokens,
  SUM(completion_tokens)                                      AS visible_output,
  SUM(thoughts_tokens)                                        AS hidden_thinking,
  SUM(total_tokens)                                           AS billed_total,
  SUM(prompt_tokens + completion_tokens)                      AS naive_sum,
  SUM(total_tokens) - SUM(prompt_tokens + completion_tokens)  AS undercount,
  ROUND(100 * SAFE_DIVIDE(
    SUM(total_tokens) - SUM(prompt_tokens + completion_tokens),
    SUM(total_tokens)), 1)                                    AS undercount_pct,
  ROUND(100 * SAFE_DIVIDE(SUM(thoughts_tokens),
    SUM(completion_tokens) + SUM(thoughts_tokens)), 1)        AS pct_of_output_unseen
FROM `BILLING_PROJECT.DATASET.load_results`
WHERE status = 200
  AND profile != 'filmdemo'
GROUP BY 1, 2
ORDER BY 1, 2;
