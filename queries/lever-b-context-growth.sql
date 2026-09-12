-- Lever B, per turn. Shows context growing (or not) across a session.
-- Plot prompt_tokens against seq. Without compaction it climbs. With it, the
-- line should step down each time a summary lands.
SELECT
  run_id,
  seq,
  prompt_tokens,
  completion_tokens,
  thoughts_tokens,
  total_tokens,
  SUM(total_tokens) OVER (PARTITION BY run_id ORDER BY seq) AS cumulative_tokens
FROM `BILLING_PROJECT.DATASET.load_results`
WHERE lever = 'B' AND status = 200
ORDER BY run_id, seq;
