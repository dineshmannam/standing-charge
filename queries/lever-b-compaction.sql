-- Lever B. Same workload, compaction on and off.
--
-- Requires --same-session. Context growth is the whole mechanism, so a fresh
-- session per request would measure nothing.
--
-- Compaction spends tokens summarising in order to save tokens later. It is not
-- automatically cheaper. The crossover is the deliverable.
SELECT
  run_id,
  session_mode,
  COUNT(*)                                        AS turns,
  SUM(prompt_tokens)                              AS prompt_tokens,
  SUM(thoughts_tokens)                            AS thinking_tokens,
  SUM(total_tokens)                               AS billed_total,
  ROUND(AVG(prompt_tokens), 1)                    AS avg_prompt_per_turn,
  MIN(prompt_tokens)                              AS first_turn_prompt,
  MAX(prompt_tokens)                              AS largest_turn_prompt,
  ROUND(SAFE_DIVIDE(SUM(total_tokens), COUNT(*)), 1) AS avg_billed_per_turn
FROM `BILLING_PROJECT.DATASET.load_results`
WHERE lever = 'B' AND status = 200
GROUP BY 1, 2
ORDER BY run_id;
