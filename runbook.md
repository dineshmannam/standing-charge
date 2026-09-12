# Standing Charge: Command Runbook

Everything here is **in addition to** a codelab, or **replaces** a step in one.
Anything not mentioned, run the codelab as written.

Codelabs used:

- **A** Ultimate Cloud Run guide: `codelabs.developers.google.com/next26/ultimate-cloud-run-guide`
- **B** Debugging Agents at Scale: `codelabs.developers.google.com/next26/dev-keynote/debugging-agents`
- **C** Both of the above

Markers:

- `[NEW]` does not exist in any codelab
- `[REPLACES]` use this instead of the codelab's version
- `[CODELAB]` run unchanged

---

## 0. Setup, once

### 0.1 Three projects, one billing account

`[NEW]` Vertex AI calls bill at project level with no resource to label. The
project is the only attribution boundary that works, so the levers cannot share
one.

```bash
for p in sc-lever-a-idle sc-lever-b-context sc-lever-c-hosting; do
  gcloud projects create "$p"
  gcloud billing projects link "$p" --billing-account="$BILLING_ACCOUNT"
done
```

All three link to the same billing account. Exports are enabled once, at the
billing account, and every project's rows land in one dataset. **Separation
happens in the query, not the export.** If a project is not linked, its spend
never appears at all.

### 0.2 Exports

`[NEW]` Console only, no gcloud command. Billing, then Billing export:

1. FOCUS usage cost export (Preview). Dataset location is permanent.
2. Detailed usage cost export.
3. Pricing export.

Discover the FOCUS dataset name rather than guessing it:

```bash
bq ls --project_id="$BILLING_PROJECT" | grep billing_immutable
```

Pin the result in `env.local.sh`.

### 0.3 Verify the project column

`[NEW]` Before trusting any query, confirm how the project appears in each
export. In the detailed export it is `project.id`. In FOCUS it maps to whichever
column Google chose, and FOCUS is Preview.

```sql
SELECT * FROM `BILLING_PROJECT.FOCUS_DATASET.gcp_billing_export_focus_ACCOUNT`
LIMIT 5
```

Look at the columns. Then write the queries.

### 0.4 Preflight

```bash
source env.sh
./preflight.sh A
```

---

# Lever A: idle capacity

**Question:** at what requests per hour does a warm min-instance beat scale to
zero?

## A.1 Deploy

`[CODELAB §8]` Follow the codelab's ADK section for the agent itself. Three
things it gets wrong or leaves implicit, all of which broke a deploy:

**The codelab writes `__init.py__`.** That is a typo. Python needs
`__init__.py` or the package will not import and the buildpack finds nothing.

**`requirements.txt` sits at the agent ROOT, not inside the package.** The
layout is:

```
agent/
  requirements.txt
  my_agent/
    __init__.py
    agent.py
```

**You deploy from the agent root**, not from the repo root and not from the
package directory. `--source .` from the repo root uploads your preflight
script, evidence CSVs and queries to Cloud Build, which then fails with no
buildpack detected.

`[NEW]` Scaffold it correctly:

```bash
./scaffold-agent.sh ./agent
echo 'export AGENT_DIR="./agent"' >> env.local.sh
echo 'export APP_NAME="my_agent"' >> env.local.sh
```

`APP_NAME` must match the package directory name. It is also the `appName` in
every `/run` call, so a mismatch fails at request time, not deploy time.

### Service account

`[CODELAB §8]` The agent needs its own service account with Vertex access:

```bash
gcloud iam service-accounts create agent-sa \
  --project="$PROJECT_ID" \
  --display-name="Agent Service Account"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:agent-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/aiplatform.user" --condition=None
```

`[NEW]` And the default compute service account needs Cloud Build roles. Google
stopped granting Editor to it on new projects, so source deploys fail with an
opaque storage 403 until you do this:

```bash
PN=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
for role in roles/storage.objectViewer roles/artifactregistry.writer \
            roles/logging.logWriter roles/cloudbuild.builds.builder; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${PN}-compute@developer.gserviceaccount.com" \
    --role="$role" --condition=None
done
```

IAM takes a minute or two to propagate. A deploy that 403s straight after a
grant is usually just impatience.

### Artifact Registry, labelled

`[NEW]` Source deploy auto-creates `cloud-run-source-deploy` without labels, so
its cost is unattributable. Create it yourself first:

```bash
gcloud artifacts repositories create cloud-run-source-deploy \
  --project="$PROJECT_ID" --repository-format=docker \
  --location="$REGION" --labels="$LABELS"
```

### The deploy

`[REPLACES §8]` Adds `--project`, `--labels`, `--min-instances`, and the model
as an environment variable.

```bash
source env.sh
mark deploy start

gcloud run deploy "$SERVICE_NAME" \
  --project="$PROJECT_ID" \
  --source "$AGENT_DIR" \
  --region "$REGION" \
  --allow-unauthenticated \
  --service-account="agent-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --set-env-vars="GOOGLE_GENAI_USE_VERTEXAI=TRUE,GOOGLE_CLOUD_PROJECT=${PROJECT_ID},GOOGLE_CLOUD_LOCATION=${VERTEX_LOCATION},AGENT_MODEL=${VERTEX_MODEL}" \
  --labels="$LABELS" \
  --min-instances=0

mark deploy done

export AGENT_URL=$(gcloud run services describe "$SERVICE_NAME" \
  --project="$PROJECT_ID" --region "$REGION" --format 'value(status.url)')
echo "$AGENT_URL" | tee evidence/agent-url
```

**Never omit `--project`.** `gcloud run deploy` falls back to `gcloud config`,
and with three projects in play that puts one lever's spend in another lever's
billing rows.

### Two model decisions

**Region versus location.** `REGION` is where Cloud Run runs. `VERTEX_LOCATION`
is where the model is served, and the codelab sets it to `global`. They are
independent. Keep both identical across all three levers.

**Avoid preview models.** The codelab uses `gemini-3-flash-preview`. Preview
models frequently have no published list price, and the entire comparison rests
on having one. Use a GA model such as `gemini-2.5-flash` and record the price
with the date, or the analysis has nothing to compare against.

### Smoke test

`[CODELAB §8]` Session first, then a turn. `appName` must equal `APP_NAME`.

```bash
curl -X POST "$AGENT_URL/apps/${APP_NAME}/users/u_1/sessions/s_1" \
  -H "Content-Type: application/json" -d '{}'

curl -X POST "$AGENT_URL/run" -H "Content-Type: application/json" -d "{
  \"appName\": \"${APP_NAME}\",
  \"userId\": \"u_1\",
  \"sessionId\": \"s_1\",
  \"newMessage\": {\"role\": \"user\", \"parts\": [{\"text\": \"hello\"}]}
}"
```

`/run` returns a **list of events**, not a single object. Check whether any
event carries `usageMetadata`. If none do, `loadgen.py` will write `NA` in the
token columns and lever B has to read tokens from Cloud Trace instead. Worth
knowing tonight rather than Sunday.

## A.2 The sweep

`[NEW]` Six runs. Three traffic profiles, two min-instance settings. One hour
each, run sequentially, never overlapping.

```bash
for MIN in 0 1; do
  gcloud run services update "$SERVICE_NAME" \
    --region "$REGION" --min-instances="$MIN"

  # Let the change settle and any warm instance actually start billing
  sleep 120

  for PROFILE in steady bursty sparse; do
    newrun "min${MIN}-${PROFILE}"
    mark "$PROFILE" start
    python3 loadgen.py --url "$AGENT_URL" --profile "$PROFILE" --fresh-session
    mark "$PROFILE" done
    sleep 300        # let the service scale down before the next profile
  done
done
```

**The `sleep 300` matters.** Without it, a warm instance from the previous
profile serves the first requests of the next one and the cold start data is
contaminated.

**`--fresh-session` matters here.** A new session per request keeps context
constant, so lever A measures hosting rather than context growth. Lever B is the
opposite and needs `--same-session`.

`steady` and `bursty` deliver the same 120 invocations, so any cost difference
between them is arrival shape rather than volume. `sparse` deliberately differs,
so compare it on cost per invocation only, never total cost.

## A.3 Load results into BigQuery

`[NEW]`

```bash
./queries/00-load-results.sh
```

**Do not use `bq load --autodetect` here.** Token columns contain `NA` on failed
requests, so autodetect infers STRING and every downstream `SUM()` breaks
silently. The loader passes an explicit schema with `--null_marker=NA`, treats a
column-count mismatch as a hard failure, and exits 1 if it loaded nothing.

## A.4 Teardown

```bash
gcloud run services update "$SERVICE_NAME" --region "$REGION" --min-instances=0
./verify-teardown.sh
```

**Set min-instances back to zero even if you plan to continue tomorrow.** A
forgotten warm instance is roughly fifty cents a day, which is small money and a
bad habit.

---

# Lever B: context size

**Question:** what does EventCompaction actually save per invocation?

## B.1 Deploy

`[CODELAB]` Follow Debugging Agents at Scale. It deploys the Marathon Simulator
Agent to Agent Runtime and walks you through finding a bug in
`EventCompactionConfig` using Cloud Trace and Cloud Monitoring.

`[NEW]` Before you start:

```bash
source env.sh B
./preflight.sh B
```

**`source env.sh B`, not `LEVER=B source env.sh`.** The assignment prefix does
not reliably reach a sourced file in zsh, and it fails silently: you stay on the
previous lever pointing at the wrong project (F13).

## B.2 Two runs, one variable

`[NEW]` The codelab is a debugging exercise. You are turning it into a
measurement. The only difference between the two runs is the compaction config.

```bash
# Run 1: compaction disabled
newrun b-nocompaction
mark nocompaction start
# drive the agent with the same prompt set, same count
mark nocompaction done

# Run 2: compaction enabled, correctly configured
newrun b-compaction
mark compaction start
# identical workload
mark compaction done
```

Nothing else changes. Not the prompt, not the count, not the model, not the
time of day if you can help it.

## B.3 Capture tokens

`[NEW]` The codelab has you observe that session token counts exceed the model's
million-token context limit. That observation is your data.

Token counts come from `loadgen.py`, which reads `usageMetadata` off each
response and writes `prompt_tokens`, `completion_tokens`, `thoughts_tokens` and
`total_tokens` as columns in `evidence/load-B-*.csv`. Every lever B number in
`findings.md` (F17) is computed from those columns. Nothing further is needed.

Cloud Trace is the other route. It was tried and it is not what the published
numbers rest on:

```bash
# Tried, not used. Returned an empty result on the lever B run, so the artifact
# it wrote is not published. Left here because it is the obvious thing to reach
# for, and because you may have tracing configured where this run did not.
gcloud trace list --project="$PROJECT_ID" --format=json > evidence/traces-B-${RUN_ID}.json
```

If you want a second source for the token counts, cross check the CSV columns
against the Usage view in Agent Observability.

The cost story: compaction spends tokens summarising in order to save tokens on
subsequent turns. **It is not automatically cheaper.** Whether it pays depends on
conversation length, and finding the crossover is the deliverable.

---

# Lever C: hosting model

**Question:** does Agent Runtime cost a premium over Cloud Run?

## C.1 Same agent, both hosts

`[NEW]` This is the one that breaks if you are careless. The comparison is only
valid if the agent is identical.

```bash
source env.sh C
./preflight.sh C
```

`[NEW]` Lever C needs one package the other two do not. `adk deploy agent_engine`
does `import vertexai`, and `google-adk` does not pull it in, so a venv built from
`agent/requirements.txt` alone passes every other check and then fails at the
deploy. `./preflight.sh C` now catches this; install it first:

```bash
pip install 'google-cloud-aiplatform[adk,agent_engines]==2.1.0'
```

Deploy the same agent code to Cloud Run and to Agent Runtime. Same model, same
region, same prompt set, same invocation count.

## C.2 Compare on the right unit

`[NEW]` Cloud Run bills for instance time. Agent Runtime bills differently.
Comparing cost per hour is meaningless.

**Compare cost per thousand invocations.** Run the same workload against both,
then divide.

```bash
newrun c-cloudrun
# workload against the Cloud Run URL
newrun c-agentruntime
# identical workload against the Agent Runtime endpoint
```

## C.3 Teardown

Agent Runtime instances are deleted through the console: Agent Runtime, select
the engine, delete. Then:

```bash
./verify-teardown.sh
```

---

# Analysis

## Cost by lever

```sql
SELECT project.id AS project, service.description AS service, SUM(cost) AS cost
FROM `BILLING_PROJECT.DATASET.gcp_billing_export_resource_v1_ACCOUNT`
WHERE DATE(usage_start_time) BETWEEN 'START' AND 'END'
  AND project.id IN ('sc-lever-a-idle','sc-lever-b-context','sc-lever-c-hosting')
GROUP BY 1, 2
ORDER BY project, cost DESC
```

## Cost per thousand invocations

See `queries/cost-per-1k-invocations.sql`. It splits hosting from model spend,
because that split is likely the finding: most people assume the model dominates,
and at low traffic it may not.

## The Lever A chart

Cost per thousand invocations on the y axis, requests per hour on the x axis, one
line for `min-instances=1` and one for `min-instances=0`. Where they cross is the
answer to the whole video.

Expect the min-instance line to be flat and high at low traffic and to fall as
traffic rises. Expect scale to zero to be nearly flat. If they never cross within
your range, say so. **That is also a finding**, and a more useful one than a
manufactured crossover.

---

# Discipline

Three things that will quietly ruin the data:

**Overlapping runs.** Separate projects give attribution, but two levers running
at once in the same hour muddy the story anyway. One at a time.

**Changing more than one variable.** The temptation in lever B is to also fix
something else you noticed. Do not.

**Forgetting min-instances.** Cheap enough not to hurt, expensive enough to
embarrass you in a video about cost discipline.
