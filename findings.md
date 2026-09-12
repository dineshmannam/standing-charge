# Findings

Raw material for the script and the posts. One entry per finding.

Each has a **status**: `confirmed` (measured, reproducible), `provisional`
(seen once, needs the real sweep), or `open` (a question to answer).

Nothing here is a conclusion until it survives Thursday and Friday's data.

---

## F1. Most of what you pay for, you cannot read

**Status:** **CONFIRMED.** Billing mechanism verified against the pricing page
3 Sep. Magnitude verified at n=246 across three profiles the same day.

Gemini returns `thoughtsTokenCount` separately from `candidatesTokenCount`.
Those tokens never appear in the response text.

| | tokens |
|---|---|
| prompt | 470 |
| visible output | 897 |
| **thinking** | **3,131** |
| billed total | 4,498 |
| naive sum (prompt + visible) | 1,367 |

**69.6% of the billed total is thinking.** Of output tokens alone, **77.7% are
invisible.**

**Held at scale.** Across 246 requests on 3 Sep:

| profile | thinking share of billed tokens | cost per 1k invocations | understated if visible-only |
|---|---|---|---|
| steady | 68.4% | $0.971 | 4.10x |
| bursty | 68.5% | $0.985 | 4.12x |
| sparse | 65.1% | $0.859 | 3.69x |

Three profiles, three arrival patterns, same answer to within a couple of
points.

An earlier run of the same profile reported 1,337 tokens because the harness
summed the visible parts. The real figure was 3.4x higher. Any cost estimate
built on `prompt + completion` is wrong by that margin.

### Billing confirmed 3 Sep 2026

Google's Agent Platform pricing page does not merely bill reasoning tokens at
the output rate, it says so in the row label. The Gemini 2.5 Flash line item
reads **"Text output (response and reasoning)"**.

| | rate per 1M tokens |
|---|---|
| Input (text, image, video) | $0.30 |
| Text output (response **and reasoning**) | $2.50 |

Source: cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing
Captured 3 Sep 2026. Screenshot it, the page changes.

There is no discounted reasoning tier. Reasoning tokens cost exactly what
visible output costs.

### What that does to the money

Applying published rates to the filmdemo run (10 invocations):

| | tokens | cost |
|---|---|---|
| input | 470 | $0.000141 |
| visible output | 897 | $0.002243 |
| **reasoning** | **3,131** | **$0.007827** |
| **actual** | | **$0.010211** |
| naive estimate, visible only | | $0.002384 |

**Cost per 1,000 invocations: $1.02 actual, $0.24 if you count only what you can
see. Understated 4.3x.**

The cost understatement (4.3x) is larger than the token understatement (3.4x),
because output bills at 8.3x the input rate and all the hidden tokens are
output.

**76.7% of the model spend was reasoning.**

**Why it matters:** every published cost-per-token estimate for agents is built
on visible tokens. If this ratio holds, they are all low by roughly 4x, and the
error is in the direction that matters.

---

## F2. The same prompt costs wildly different amounts

**Status:** provisional (n=10, identical input every time)

Prompt tokens were constant at 47 across all ten requests. Thinking tokens were
not:

| | thinking tokens |
|---|---|
| min | 126 |
| median | 279 |
| max | 773 |

**6.1x spread on identical input.** Request 8 cost 3.6x request 4 for the same
question.

**Why it matters:** cost per invocation is not purely a property of your
workload. You cannot budget from a single measurement, and an average hides a
long tail. This is arguably more useful to a platform team than F1, because it
changes how you forecast rather than just what you multiply.

**Confirmed at n=120, and it got worse.**

| profile | n | min | p50 | max | spread |
|---|---|---|---|---|---|
| steady | 120 | 113 | 278 | 942 | **8.3x** |
| bursty | 120 | 108 | 274 | 879 | **8.1x** |
| sparse | 6 | 182 | 254 | 320 | 1.8x |

The n=10 sample showed 6.1x. At n=120 it is 8.3x. **The tail is real and the
small sample understated it.**

Prompt tokens were constant at 47 on every one of the 246 requests. The input
did not vary at all.

Sparse looks tighter only because six requests cannot show an eight-times tail.

---

## F3. Cold starts are real, but client latency cannot reliably detect them

**Status:** provisional

First request 8,006ms against a 3,452ms median for the rest. **2.35x.**

An earlier attempt showed no cold start at all, because a curl smoke test had
warmed the service minutes before. Cloud Run scales to zero after roughly 15
minutes idle.

**Method consequence:** every `min-instances=0` run must idle first or it
measures a warm instance. Added `--wait-for-cold` to the harness.

### The detector does not work, and that is the finding

Observed latency across ten identical requests: 2,230ms to 9,324ms. **4.2x
natural spread with no cold start involved.** The cold start itself was 2.35x.

The effect is smaller than the noise. A 3x-over-median rule flags request 0 and
misses request 6 at 9,324ms, because by then the trailing median has absorbed
the early spike. Lowering the threshold until request 6 trips it would flag
half the run.

Tried and rejected: raising the window, trimming the median, lowering the
multiple. Each either misses real spikes or invents them. **Tuning the
threshold until it produces the expected answer is fitting the detector to the
data.**

`cold_hint` stays in the CSV as a weak signal with two values, `first` and
`likely`, and both are explicitly labelled as proxies in the harness docstring.
No number derived from it goes on screen.

**The real source is server side.** Cloud Run publishes
`run.googleapis.com/container/startup_latencies`, and instance startup appears
in the logs. Pull cold starts from there and use client latency only to show
what the caller experiences.

**Why it matters for the video:** F2 says the same prompt varies 6x in thinking
tokens. F3 says the same request varies 4x in latency. Those are probably the
same phenomenon seen from two angles, and together they say something harder
than either alone: **on this stack, a single measurement of anything tells you
very little.**

**Open:** was request 6 a second instance starting under concurrency, or model
variance? Check `startup_latencies` and the instance count for that minute.

---

## F4. The permissions you have are not the permissions your build has

**Status:** confirmed

Two consecutive deploy failures, both service-account IAM, neither caught by a
preflight that checked the caller's permissions thoroughly.

1. Cloud Run service agent lacked `iam.serviceAccounts.getAccessToken`
2. Default compute SA lacked `storage.objectViewer`, so source deploy could not
   read its own uploaded source

Google stopped granting Editor to `PROJECT_NUMBER-compute@developer` on new
projects, so this hits every fresh project doing a source deploy.

**Why it matters:** the error surfaces as a storage 403 pointing at a bucket you
never created. Nothing in it says "grant your build account a role."

---

## F5. Following the codelab literally does not work

**Status:** confirmed. **Reported to Google 4 Sep 2026.**

The codelab writes `touch my_agent/__init.py__`. Python needs `__init__.py`.
Follow it exactly and the package never imports. Appears twice in section 8: in
the `touch` command and again in the prose.

**The failure mode is the interesting part.** It does not fail at build time.
The container builds, deploys, and serves. It fails on the first request, with
`NameError: Fail to load 'my_agent' module` buried in roughly thirty lines of
FastAPI and ADK traceback. The filename appears only at the very bottom.

Related, from our own tooling: a stray `EOF` line pasted from a heredoc produced
`NameError: name 'EOF' is not defined`, same shape, same depth of traceback, and
the cause was line 14 of a 14 line file.

**Why it matters:** read tracebacks bottom-up. The top is the framework telling
you where it noticed. The bottom is your code telling you what you did.

### How this gets said on camera

**As a correction, not a criticism.** The codelab is otherwise sound and the
video should say so. The report was filed before filming, so the video can say
that too, and note that it may already be fixed by the time anyone watches.

The point being made is about the failure mode, not about Google making a typo.
"Builds fine, deploys fine, breaks on first request, and the filename is thirty
lines down" is a useful lesson. "I found a typo" is not.

**If the report has not been filed by Saturday, cut the beat.** Raising an
unreported bug on camera is the version of this that costs you something.

---

## F5b. Three times now, a check confirmed existence rather than correctness

**Status:** confirmed

Same blind spot, three different places, all in one evening:

1. Preflight grepped `agent.py` for `root_agent`. The file contained the string
   and did not parse. Deploy failed.
2. Preflight verified my IAM permissions thoroughly and never checked the
   service accounts that actually run the build. Two deploys failed.
3. Postflight ran a billing query, saw non-empty output, and reported PASS. The
   output was a syntax error. Any query failure would have looked like success.

**The pattern:** each check asked "is something there?" when the question was
"does it work?". A string is present, a role list is non-empty, stdout has
content. None of those are the thing you care about.

**Why it matters for the video:** this is the most transferable lesson in the
whole project and it has nothing to do with GCP. Verification code is code, and
it fails in the direction of saying yes.

---

## F6. GPU quota is refused before it is priced

**Status:** confirmed

Requested 6 L4 GPUs for the original version of this project. Denied within
minutes. Reason given: new project, billing account has insufficient history.

`GPUS_ALL_REGIONS` was at limit 0, a global ceiling that overrides every
regional quota.

**Why it matters:** every break-even analysis for self-hosted inference assumes
GPU capacity is purchasable at list price. None mention that a competent
engineer with a valid use case waits days for permission and may be told no.
Access is a cost input, and it is missing from all of them.

---

## F7. Published break-even figures disagree by three orders of magnitude

**Status:** confirmed (desk research, 2026-09-01)

Surveying published self-host-versus-API analyses:

- 2 to 5 million tokens per day
- 5 to 10 million tokens per month
- 15 to 20 million tokens per day
- against budget APIs, sometimes unreachable on a single GPU

Nearly all are modelled from spec sheets and list prices. Almost none are
measured from a bill.

**Why it matters:** this is the gap the whole project exists in. The one thing
they agree on is that utilisation dominates, and that real systems run at 40 to
70 percent rather than saturated.

---

## F8. Labels are never retroactive, and neither is anything else that matters

**Status:** confirmed

Three things cannot be recovered after the fact:

1. Billing export must be enabled before the spend happens
2. Resource labels are stamped at moment of usage
3. GKE cost allocation only produces data from when the flag is set

Verified with a 10 GiB disk, labelled, then queried in the billing export.
**Confirmed 2026-09-02: 41 billing rows carrying `run-id=label-test`, total
cost $0.037458.** Three and a half cents to prove the measurement pipeline works
before spending anything on the real thing.

The label appeared on rows for a resource created hours earlier. Today's live
run had not appeared yet at the time of checking, which is export lag rather
than a propagation failure. Lag looks identical to breakage if you only check
once, which is why this was done days ahead rather than the night before.

**Why it matters:** the measurement has to be designed before the experiment,
not after. That is the difference between an analysis and an anecdote.

---

## F9. FOCUS dataset naming cannot be guessed

**Status:** confirmed

Google created the dataset as `gcp_billing_immutable_<ACCOUNT>_us`, lowercase.
Our hardcoded guess used `_US`. The suffix depends on the export location chosen
at setup, and it is fixed permanently at creation.

**Related, still open:** how does the GCP project appear in the FOCUS schema? In
the detailed export it is `project.id`. FOCUS is a normalised cross-cloud schema
and is still Preview, so the column must be discovered rather than assumed.

**Second naming trap, same family.** BigQuery table names cannot contain
hyphens, so the billing account id is rewritten with underscores in the export
table name: `012345-6789AB-CDEF01` becomes
`gcp_billing_export_resource_v1_012345_6789AB_CDEF01`. Two different naming
rules apply to the same identifier depending on where it appears, which is the
sort of thing that produces a "table not found" error with no clue in it.

---

## F10. A load generator that sleeps between requests measures the wrong thing

**Status:** confirmed

First harness slept a fixed gap after each request, so each cycle was gap plus
latency. Target 120 req/hr, actual 115.

**The confound:** warm instances respond faster, so a `min-instances=1` arm
would send more requests per hour than a `min-instances=0` arm. The two curve
arms would have had different traffic volumes, which is the exact thing the
experiment is trying to hold constant.

Fixed with absolute scheduling against run start. Drift is now under 5ms.

**Why it matters:** a measurement tool can introduce the bias it is meant to
detect. Worth stating in the method section of the post.

---

## F11. The bursty profile originally sent double the traffic

**Status:** confirmed

First draft: 10 min idle, 5 min at 720 req/hr, repeating. That delivers 240
requests per hour against steady's 120.

Any cost difference between steady and bursty would have been volume, not
arrival shape. Caught before running anything, by testing the schedule
generator rather than reading it.

---

## F12. A one hour test and a one hour credential

**Status:** confirmed 3 Sep

The steady min-instances=0 run lost its last two requests to HTTP 401.
`gcloud auth print-identity-token` returns a token valid for roughly one hour,
and loadgen fetched it once at startup. A 60 minute profile sits exactly on that
boundary.

**Root cause: the machine slept.** Confirmed by the operator. A 368 second gap
appeared before those requests with nothing sent, and the run drifted past the
token's expiry as a result. Without the sleep the final request would have
landed around 15:26:26, roughly thirty seconds inside the window.

So the token was not the cause. It was the thing that broke when the real cause
moved the schedule.

**Two failures out of 246, so the data survives.** But the same profile at
min-instances=1 runs tomorrow, and a mid-run credential failure on a warm
instance would be harder to spot, because the cost is accruing either way.

**Fixed:** loadgen now holds a `Token` object that refreshes every 30 minutes
and retries once on any 401. It also warns when drift exceeds 60 seconds, which
is the signature of a sleeping machine.

**Why it matters beyond this project:** two separate lessons, and it is worth
keeping them apart.

The **cause** is that an unattended measurement ran on a machine free to stop
participating. Sleep produces a silent hole: no error, no retry, just an absence
that only shows up as drift.

The **exposed weakness** is that the test duration and the credential lifetime
were the same number. The run had roughly thirty seconds of margin against a one
hour token, which is not margin at all. Six minutes of sleep was enough to spend
it. Anything measuring for about as long as its credentials last will eventually
fail this way, and the failure will look like an auth problem rather than a
scheduling one.

Both fixes stay: `caffeinate` removes the cause, token refresh removes the
fragility.

---

## F13. A variable assignment prefix does not survive `source` in zsh

**Status:** confirmed 4 Sep

`LEVER=B source env.sh` left the shell on lever A. `scenv` reported lever A and
project `sc-lever-a-idle` while the operator believed they had switched to
lever B.

**Why it matters:** it fails silently and in the worst direction. Nothing errors.
The next deploy would have gone to lever A's project, putting lever B's spend in
lever A's billing rows and quietly invalidating both.

The `scenv` habit caught it, which is the argument for printing state before
every action rather than trusting that a command did what it looked like it did.

**Fixed:** `env.sh` now takes the lever as an argument, `source env.sh B`, which
works in both shells.

---

## F14. A growing agent conversation cannot survive Cloud Run autoscaling

**Status:** confirmed 4 Sep

Lever B's first run died after three requests. Requests 1 to 3 returned 200 with
input tokens climbing exactly as expected (47, 165, 283). Request 4 onward
returned **404** for the rest of the run: 116 wasted requests.

The session had vanished. Cloud Run logs:

```
Using in-memory memory service
Detected Cloud Run/Kubernetes runtime; using in-memory services
  instead of local .adk storage
```

**ADK's default session service is in-memory.** Sessions live inside a single
container's RAM. Nothing writes them anywhere. A second instance, or a
replacement instance, has no idea the session exists, and `/run` returns 404.

The logged container shut down roughly three minutes after the 404s began, so
either a second instance served request 4 onward or the serving instance was
replaced. Either way the cause is the same: **more than one instance existed and
the session only lived on one of them.**

### Why lever A never hit this

Lever A uses `--fresh-session`: a new session per request, created and used
within the same call. Any instance can serve it. Lever B needs `--same-session`
because context growth is the whole mechanism, and that is exactly the pattern
that cannot survive instance churn.

**The measurement design surfaced a real production failure mode.** Not a
contrived one.

### What it means for anyone running agents on Cloud Run

Multi-turn agent conversations on Cloud Run with ADK's default session store are
one autoscale event away from losing the conversation. The failure is a 404,
which reads as a routing problem rather than a state problem.

A production system needs a persistent session service. The default is fine only
for stateless, single-turn traffic.

### It is a configuration you have to opt into

`adk deploy agent_engine --help` documents `--session_service_uri`:

```
--session_service_uri TEXT
    If unset, ADK chooses a default session service.
    - 'agentengine://<agent_engine>' to connect to Agent Engine sessions
    - 'sqlite://<path_to_sqlite_file>' to connect to a SQLite DB
    - 'memory://' to run with the in-memory session service
```

So persistence exists and is documented. **The default is the one that breaks
multi-turn conversations on Cloud Run**, and nothing warns you at deploy time.
The only signal is a startup log line saying "using in-memory services", which
reads as informational rather than as a warning that your sessions will vanish.

This strengthens the finding rather than weakening it. The failure is not a gap
in the platform, it is a default that is wrong for the most common stateful use
case, and it fails as a 404 rather than as anything that points at state.

**Workaround used here:** pinned to exactly one instance
(`--min-instances=1 --max-instances=1`) for both lever B runs. That removes the
confound rather than introducing one, since lever B compares compaction on
against compaction off, not hosting configurations.

Deliberately did **not** switch to a persistent session service. That would
change what lever B measures: sessions become storage reads and writes rather
than RAM, which is a different cost profile. Noted as Q12.

**Caveat to publish:** lever B ran pinned at one instance while lever A swept
min-instances. Hosting cost is not comparable across the two levers.

---

## F15. A check that cannot tell "none" from "wrong command"

**Status:** confirmed 4 Sep

`preflight.sh` verified Agent Runtime with `gcloud beta aiplatform
reasoning-engines list`. That command surface does not exist; it is `gcloud beta
ai`. The check wrapped it in `if ... >/dev/null 2>&1` and, on failure, reported
"could not list reasoning engines, may be unavailable in this region".

Which reads as absence. It was a typo in the command.

**Fifth instance of the same family.** A grep that passed on an unparseable
file. IAM verified for the caller but not the service account. Non-empty `bq`
output treated as success when it was a syntax error. An unrecognised subcommand
indistinguishable from an empty result. And the BigQuery loader, which expected
15 columns after loadgen had grown to 17, printed `SKIP` for all thirteen files
and **exited 0**.

That last one is the purest example. Nothing failed. It reported skipping, which
sounds deliberate, and returned success. The dataset was empty and the exit code
said fine.

Every one of them fails by reporting something benign. **A check that cannot
distinguish "the thing is absent" from "I asked the wrong question" is not a
check.**

**Fixed once, wrongly.** The first fix changed `gcloud beta aiplatform` to
`gcloud beta ai`, which also does not exist. Discovered while trying to delete
the engine during teardown, three commands later.

**There is no gcloud surface for reasoning engines at all.** Not
`gcloud beta aiplatform`, not `gcloud beta ai`. REST is the only path, for
listing and for deleting:

```
GET    /v1beta1/projects/P/locations/L/reasoningEngines
DELETE /v1beta1/{name}?force=true
```

**Loader fixed too:** a column mismatch is now a hard failure, and loading zero
files exits 1 with "NOTHING WAS LOADED. That is a failure, not a no-op."

**Fixed properly:** preflight now calls REST directly, distinguishes an empty
body from an empty list from an error object, and prints the exact delete
command for any engine it finds, because a forgotten reasoning engine bills
while it exists.

**The compounding lesson:** the first correction was as unverified as the
original. Guessing a command surface twice cost more than checking once
would have.

---

## F16. Agent Engine and Cloud Run are not the same product with different pricing

**Status:** confirmed 4 Sep. This is lever C's first result and it arrived before
any cost number.

Lever C asks whether managed hosting carries a premium. Before reaching that,
the two hosts turned out not to be interchangeable at all.

**Agent Engine has no service URL.** No HTTP endpoint, no `/run`. It exposes a
resource name and a set of class methods invoked through the Vertex AI API:

```
projects/PROJECT_NUMBER/locations/us-central1/reasoningEngines/ENGINE_ID
```

Same agent code on both sides. Four differences:

| | Cloud Run | Agent Engine |
|---|---|---|
| Address | HTTPS service URL | resource name |
| Auth | identity token | access token |
| Invocation | `POST /run` | `POST {name}:streamQuery` |
| Session creation | `POST /apps/{app}/users/{u}/sessions/{s}` | `class_method: create_session` |

**There is no unary query method at all.** The exposed methods are
`create_session`, `get_session`, `list_sessions`, `delete_session`,
`stream_query`, `streaming_agent_run_with_events`, plus async variants.
`stream_query` is the only way to ask the agent anything, and it streams.

### Why it matters more than the cost number

The framing "which host is cheaper" assumes a decision you can revisit. It is
not. **Moving between these hosts means rewriting every caller**: different
address, different auth, different endpoint, different response shape, and a
streaming-only query surface where the other was request/response.

The agent code is portable. The client is not.

That is a switching cost that never appears in a pricing table, and for most
teams it will dominate whatever per-invocation difference the billing data
shows.

### What it cost to discover

The load generator needed a second invocation mode: `--engine` for Agent Engine
against `--url` for Cloud Run, a different token kind, session creation via a
class method, and a stream parser handling SSE, NDJSON and JSON-array shapes.
That is not a configuration flag, it is a second client.

### Caveats on the comparison

`adk deploy agent_engine` reported `Using google-adk[a2a]==2.8.0 in
requirements`. The `[a2a]` extra was added by the deploy tooling, not by us.
Same ADK version, so the agent code matches, but the dependency set may not be
byte-identical to the Cloud Run image.

**Agent Engine returns less telemetry.** Its stream events carry
`usageMetadata` but not `modelVersion` or `trafficType`, both of which Cloud
Run's `/run` events include. So the model version serving the Agent Engine arm
cannot be confirmed from the CSV the way it can for levers A and B. Same host,
same agent, less to audit.

### First result from the smoke test (n=10, 4 Sep)

| | Cloud Run (filmdemo, 2 Sep) | Agent Engine (filmdemo, 4 Sep) |
|---|---|---|
| thinking share of billed tokens | 69.6% | 66.5% |
| prompt tokens | 47, constant | 47, constant |
| median latency | ~3,452 ms | ~4,733 ms |
| first request vs median | 2.9x | 1.2x |

**F1 holds on a different host.** Reasoning tokens are roughly two thirds of the
bill on Agent Engine too, so this is a Gemini billing property rather than a
Cloud Run artifact.

**No cold start signature on Agent Engine**, though the instance may simply have
been warm from the deploy. The full run will say.

**Latency is higher on Agent Engine**, which may be the streaming surface rather
than the host: latency here includes consuming the entire stream, where the
Cloud Run path reads a complete response body. See Q13.

---

## F17. Context compaction is not a cost lever at realistic agent scale

**Status:** confirmed 4 Sep, n=240 (120 turns each arm)

Lever B ran the same 120-turn conversation twice, compaction off then on, with
nothing else changed.

| | compaction OFF | compaction ON | difference |
|---|---|---|---|
| billed tokens, whole run | 923,731 | 916,882 | **0.74%** |
| prompt tokens at turn 119 | 15,041 | 14,924 | 0.8% |
| growth per turn | 126 tokens | 125 tokens | flat |

**Compaction never fired.** Both arms climb linearly at effectively the same
rate. There is no step down anywhere in the series, which is the signature of a
summary landing and replacing accumulated context.

| turn | OFF prompt tokens | ON prompt tokens |
|---|---|---|
| 0 | 47 | 47 |
| 20 | 2,567 | 2,450 |
| 60 | 7,607 | 7,490 |
| 100 | 12,647 | 12,530 |
| 119 | 15,041 | 14,924 |

The 0.74% gap is thinking-token variance, not compaction. F2 measured an 8.3x
spread on identical input, which is far larger than this difference.

### Why it did not fire

The conversation reached about 15,000 prompt tokens after 120 turns. Compaction
triggers near the context limit, and Gemini 2.5 Flash carries roughly a million.
This workload got **1.5% of the way there**.

The codelab this lever came from is built around a session *exceeding* the
million token limit. It is targeting a scale two orders of magnitude above a
120-turn conversation.

### The finding

**At realistic small-agent scale, context compaction is not a cost lever.** It
is a safety mechanism for very long sessions, not an optimisation to reach for
when a bill looks high.

For most teams that is a more useful answer than a curve would have been. Most
agent conversations never approach a million tokens, so tuning compaction is
effort spent on a knob that is not connected to anything.

### What was deliberately not done

Lowering the compaction threshold until it fired. That would have manufactured
the expected result rather than measuring the configured one. The question was
whether compaction saves money on a realistic workload, and the answer is that
it does not engage on one.

**Open:** at what conversation length does it start to matter? Answering that
needs a session an order of magnitude longer, which is a separate experiment.

---

## F18. FOCUS and the detailed export disagree, and both are right

**Status:** confirmed 5 Sep, with the arithmetic to close it

The reconciliation between Google's FOCUS export (Preview) and the detailed
usage cost export, over 3 to 4 September across the whole billing account:

| | |
|---|---|
| FOCUS `BilledCost` total | $1.117683 |
| detailed `cost` total | $1.263423 |
| delta | **−$0.14574** |

That delta is exactly the Cloud Run spend for the same window. Not close to it.
Exactly it.

### Where it went

```
ServiceName  billed  effective  list_cost  contracted  rows
Cloud Run    0       0          0.14574    0.14574     415
```

**415 rows of Cloud Run usage. `ListCost` and `ContractedCost` carry the correct
figure. `BilledCost` and `EffectiveCost` are both zero.**

Vertex AI matched to six decimal places in both exports ($1.037732), so this is
specific to Cloud Run.

### It is not a bug

The detailed export closes it:

```
cost      credits     net
0.14574   -0.14574    0.0
```

**Cloud Run's free tier covered every request.** Nothing was billed. FOCUS
`BilledCost` reports what was actually paid, which was nothing. The detailed
export's `cost` reports gross before credits.

Both are correct. They answer different questions, and the word "cost" means
something different in each.

### Why this matters to anyone standing up FinOps reporting

**Build a cost dashboard on FOCUS `BilledCost` and anything inside a free tier
disappears from it.** The usage rows are there. The cost is zero. Build the same
dashboard on the detailed export's `cost` field and the same workload shows a
figure. The two will never agree unless you explicitly account for credits, and
nothing in either export tells you that is what happened.

This is the reconciliation nobody had published on a real agent workload. The
useful result is not a number, it is that the two exports are not
interchangeable and the difference is invisible until you go looking for it.

### Consequence for this project's own numbers

**The Cloud Run figures throughout lever A are gross costs that were never
actually paid.** $0.02389 at min-instances=0 and $0.063437 at min-instances=1
are real usage at list price, fully absorbed by the free tier at this scale.

The 166% increase between arms is a true measure of the usage difference. The
dollars are what someone past the free tier would pay, not what this experiment
cost.

Worth stating on screen. It does not change the ratio, which is the finding, but
it changes what the absolute numbers mean.

---

## Open questions

| # | Question | Resolve by |
|---|---|---|
| ~~Q1~~ | ~~Does Vertex bill thinking tokens at the output rate?~~ | **RESOLVED 3 Sep. Yes. The pricing row is literally named "Text output (response and reasoning)". $2.50/1M for 2.5 Flash.** |
| ~~Q2~~ | ~~Does the 6x thinking variance hold at n=120?~~ | **RESOLVED 3 Sep. Yes, and it widened to 8.3x.** |
| Q3 | Where is the lever A crossover, if there is one in range? | Friday |
| ~~Q4~~ | ~~Does FOCUS reconcile against the detailed export?~~ | **RESOLVED 5 Sep. No, and the reason is free-tier credits. See F18.** |
| ~~Q5~~ | ~~Does compaction actually save money, or spend more?~~ | **RESOLVED 4 Sep. It never fires at this scale. 0.74% difference across 120 turns, within thinking-token noise.** |
| Q14 | At what conversation length does compaction begin to engage? | Separate experiment, needs a much longer session |
| Q12 | Would a persistent session service change lever B's cost? Sessions become storage rather than RAM. | Out of scope, note it |
| Q6 | Does Agent Engine carry a cost premium? | Lever C, Agent Engine arm |
| Q13 | Does the streaming-only surface change measured latency against Cloud Run's request/response? Latency now includes consuming the whole stream. | Compare the two lever C arms |
| Q7 | Was request 6's 9,324ms a second instance starting? | `run.googleapis.com/container/startup_latencies` for that minute |
| Q9 | Do cold starts pulled from server metrics agree with the latency proxy? | Thursday, compare both |
| Q8 | How does the project appear in the FOCUS schema? | One SELECT |
| Q10 | Do billing rows for run-2026-09-02-a appear once export catches up? | Thursday morning, `postflight --billing` |
| Q11 | What did the filmdemo run actually cost? Ten agent invocations, hosting plus model. | Once Q10 resolves |

---

## Candidate headline

Ranked by how surprising it is to someone who builds on this stack:

1. **F1 + F2 + F3 together.** Most of your bill is invisible, and neither the
   invisible part nor the latency is predictable from a single measurement.
   **8.3x spread on tokens at n=120**, 4x on latency, identical input every
   time. Both confirmed against published rates: $0.97 per 1,000 invocations
   actual, $0.24 if you count only what you can see.
2. **F16.** The two hosting options are not interchangeable. Moving between
   them means rewriting every caller, a switching cost absent from every
   pricing table.
3. **F18.** FOCUS and the detailed export disagree by exactly the free-tier
   credit, and neither export says so. Anyone building cost reporting on the
   wrong field loses a whole service from their dashboard.
4. **F6.** You may not be allowed to buy the cheaper option.
5. **F10.** The measurement tool was introducing the bias it exists to detect.

F1 and F2 were not in the plan. They fell out of reading a response body
carefully while debugging something else. Worth saying out loud in the video:
that is how measurement work actually goes, and it is more interesting than
pretending the finding was the hypothesis.
