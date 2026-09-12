#!/usr/bin/env python3
"""
Drive an ADK agent on Cloud Run at a target rate and record every request.

The ADK server exposes two endpoints (codelab section 8):

  POST /apps/{app}/users/{user}/sessions/{session}   create a session
  POST /run                                          send a turn

/run returns a LIST of events. Token usage arrives as usageMetadata on whichever
events carry it. Use totalTokenCount, never prompt+completion: Gemini bills
reasoning tokens (thoughtsTokenCount) that never appear in the response text,
charged at the output rate. On a trivial prompt they were 37 of 95 tokens.

Session handling is a deliberate choice, not a detail:

  --fresh-session  (default)  new session per request. Context stays constant,
                              so lever A measures hosting, not context growth.
  --same-session              one session for the whole run. Context grows every
                              turn. This is what lever B needs.

Scheduling is absolute, not cumulative. Requests land on fixed offsets from the
run start, so request latency does not eat into the send rate. Sleeping between
requests instead would make fast (warm) arms send more requests than slow (cold)
arms in the same hour, which is a confound rather than a rounding error.

Emits CSV:
  run_id,lever,profile,seq,utc_time,status,latency_ms,prompt_tokens,
  completion_tokens,thoughts_tokens,total_tokens,model_version,traffic_type,
  session_mode,scheduled_offset_s,drift_ms,cold_hint

Also appends start and done rows to evidence/wallclock.csv, so every run is
time bounded without you remembering to call the shell `mark` helper twelve
times during a six run sweep. The cost queries filter on those exact UTC
bounds, which matters because the projects are reused and a whole day filter
would sweep in unrelated spend.

cold_hint values:
  first   request 0 of the run. Always suspect, never provable from timing alone.
  likely  more than 3x the median of the trailing 8 requests.

Both are proxies, not measurements. Cloud Run does not report cold starts on the
response, so confirm against the logs before putting a number on screen.

Two hosts, two entirely different invocation contracts:

  --url     Cloud Run. HTTP service, identity token, POST /run.
  --engine  Agent Engine. No service URL. A resource name and class methods,
            access token, POST {name}:streamQuery. Streaming only, there is no
            unary query method at all.

That difference is lever C's first finding: the same agent code is not callable
the same way on both hosts.

Usage:
  python3 loadgen.py --url "$AGENT_URL" --profile steady
  python3 loadgen.py --engine "$AGENT_ENGINE" --profile steady
  python3 loadgen.py --url "$AGENT_URL" --profile filmdemo --dry-run
  python3 loadgen.py --url "$AGENT_URL" --profile steady --same-session
  python3 loadgen.py --url "$AGENT_URL" --profile steady --wait-for-cold
"""
import argparse
import csv
import json
import os
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

# Cloud Run scales an idle service to zero after roughly this long. Waiting it
# out is the only way to guarantee the first request of a min-instances=0 run
# actually pays for a cold start.
SCALE_TO_ZERO_SECONDS = int(os.environ.get("SCALE_TO_ZERO_SECONDS", "900"))

# cold_hint needs some history before a median means anything, but requiring
# five samples leaves the first five requests of every run unflaggable. Two is
# a reasonable floor for a ten request profile.
COLD_HINT_MIN_SAMPLES = 2
COLD_HINT_MULTIPLE = 3.0
# Compare against a trailing window, not the whole run. An 8s cold start at
# request 0 otherwise lifts the running median enough to mask a 9s spike later.
COLD_HINT_WINDOW = 8


# gcloud identity tokens last about an hour. A 60 minute profile sits exactly on
# that boundary: the steady min0 run on 3 Sep lost its last two requests to 401s
# because the token was fetched once at startup. Refresh well before expiry.
TOKEN_TTL_SECONDS = int(os.environ.get("TOKEN_TTL_SECONDS", "1800"))


class Token:
    """Identity token that refreshes itself before it expires.

    Needed unless the service is public. Org policy usually blocks allUsers.
    """

    def __init__(self, kind="identity"):
        # Cloud Run takes an identity token. Vertex AI takes an access token.
        # Getting this wrong returns 401 with no hint which kind was expected.
        self.kind = kind
        self.value = ""
        self.fetched_at = 0.0
        self.refreshes = 0
        self._fetch(initial=True)

    def _fetch(self, initial=False):
        cmd = ("print-access-token" if getattr(self, "kind", "identity") == "access"
               else "print-identity-token")
        try:
            self.value = subprocess.check_output(
                ["gcloud", "auth", cmd],
                text=True, stderr=subprocess.DEVNULL).strip()
            self.fetched_at = time.time()
            if not initial:
                self.refreshes += 1
                print(f"    [token refreshed, #{self.refreshes}]", flush=True)
        except Exception:
            self.value = ""

    def refresh(self):
        self._fetch()

    def get(self):
        if self.value and time.time() - self.fetched_at > TOKEN_TTL_SECONDS:
            self._fetch()
        return self.value


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def wallclock(run_id, lever, phase, event):
    """Append a phase boundary to evidence/wallclock.csv.

    Same file and columns as the `mark` helper in env.sh, so hand written and
    generated rows interleave cleanly. postflight.sh checks every phase has a
    matching start and done.
    """
    d = os.path.join(os.environ.get("SC_DIR", "."), "evidence")
    os.makedirs(d, exist_ok=True)
    f = os.path.join(d, "wallclock.csv")
    fresh = not os.path.exists(f) or os.path.getsize(f) == 0
    with open(f, "a", newline="") as fh:
        w = csv.writer(fh)
        if fresh:
            w.writerow(["run_id", "lever", "phase", "event", "utc_time"])
        w.writerow([run_id, lever, phase, event, now()])
    return f


def post(url, payload, token, timeout=180):
    data = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:
        return 0, str(e)


def tokens_from_events(body):
    """Sum usageMetadata across the event list.

    Returns (prompt, completion, thoughts, total, model_version, traffic_type).
    Always prefer the returned totalTokenCount over a sum of the parts.
    """
    try:
        events = json.loads(body)
    except Exception:
        return (None,) * 6
    if not isinstance(events, list):
        events = [events]

    p = c = th = tot = 0
    model_version = traffic_type = ""
    found = False

    def g(d, *keys):
        for k in keys:
            v = d.get(k)
            if v is not None:
                return v
        return 0

    for ev in events:
        if not isinstance(ev, dict):
            continue
        model_version = ev.get("modelVersion") or model_version
        um = ev.get("usageMetadata") or ev.get("usage_metadata")
        if isinstance(um, dict):
            found = True
            p += g(um, "promptTokenCount", "prompt_token_count")
            c += g(um, "candidatesTokenCount", "candidates_token_count")
            th += g(um, "thoughtsTokenCount", "thoughts_token_count")
            tot += g(um, "totalTokenCount", "total_token_count")
            traffic_type = um.get("trafficType") or traffic_type

    if not found:
        return (None,) * 6
    return p, c, th, tot, model_version, traffic_type


# ---------------------------------------------------------------------------
# Agent Engine
#
# Agent Engine has no service URL and no /run endpoint. It exposes a resource
# name and class methods, invoked through the Vertex AI API:
#
#   POST {name}:query        unary methods   (create_session)
#   POST {name}:streamQuery  streaming ones  (stream_query)
#
# There is no unary query method at all. The query surface is streaming only,
# so latency includes consuming the whole stream. That matches how the Cloud
# Run path reads the full response body, so the two remain comparable.
# ---------------------------------------------------------------------------

def ae_base(engine, location):
    return f"https://{location}-aiplatform.googleapis.com/v1beta1/{engine}"


def ae_create_session(engine, location, user, token):
    st, body = post(f"{ae_base(engine, location)}:query",
                    {"class_method": "create_session",
                     "input": {"user_id": user}}, token)
    sid = ""
    try:
        d = json.loads(body)
        out = d.get("output", d)
        sid = out.get("id") or out.get("session_id") or ""
    except Exception:
        pass
    return st, sid, body


def ae_stream_query(engine, location, user, session, message, token):
    payload = {"class_method": "stream_query",
               "input": {"message": message, "user_id": user}}
    if session:
        payload["input"]["session_id"] = session
    return post(f"{ae_base(engine, location)}:streamQuery?alt=sse", payload, token)


def tokens_from_stream(body):
    """Agent Engine streams events. Normalise SSE, NDJSON or a JSON array
    into a list, then reuse the same usageMetadata extraction."""
    events = []
    txt = (body or "").strip()
    try:
        d = json.loads(txt)
        events = d if isinstance(d, list) else [d]
    except Exception:
        for line in txt.splitlines():
            line = line.strip()
            if line.startswith("data:"):
                line = line[5:].strip()
            if not line or line == "[DONE]":
                continue
            try:
                obj = json.loads(line)
                events.extend(obj if isinstance(obj, list) else [obj])
            except Exception:
                continue

    flat = []
    for e in events:
        if isinstance(e, dict) and isinstance(e.get("output"), dict):
            flat.append(e["output"])
        else:
            flat.append(e)
    if not flat:
        return (None,) * 6
    return tokens_from_events(json.dumps(flat))


def offsets(p):
    """Absolute send offsets in seconds from run start."""
    dur = p["duration_minutes"] * 60
    out, t = [], 0.0
    if p.get("shape") == "constant":
        gap = 3600.0 / p["requests_per_hour"]
        while t < dur:
            out.append(t)
            t += gap
        return out
    b = p["burst"]
    gap = 3600.0 / b["active_rate_per_hour"]
    while t < dur:
        t += b["idle_minutes"] * 60.0
        active_end = t + b["active_minutes"] * 60.0
        while t < active_end and t < dur:
            out.append(t)
            t += gap
        t = active_end
    return out


def wait_for_scale_to_zero(seconds):
    print(f"\n  waiting {seconds}s for the service to scale to zero.")
    print("  without this the first request is served by a warm instance and")
    print("  the cold start you are trying to measure never happens.")
    end = time.time() + seconds
    while True:
        left = int(end - time.time())
        if left <= 0:
            break
        print(f"\r  {left:4d}s remaining ", end="", flush=True)
        time.sleep(min(10, left))
    print("\r  scale to zero wait complete.   \n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", help="Cloud Run service URL")
    ap.add_argument("--engine",
                    help="Agent Engine resource name: "
                         "projects/N/locations/L/reasoningEngines/ID. "
                         "Mutually exclusive with --url.")
    ap.add_argument("--location",
                    default=os.environ.get("VERTEX_LOCATION", "us-central1"),
                    help="Vertex location, used with --engine")
    ap.add_argument("--profile", required=True)
    ap.add_argument("--profiles-file", default="traffic-profiles.json")
    ap.add_argument("--app", default=os.environ.get("APP_NAME", "my_agent"))
    ap.add_argument("--out", default=None)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--wait-for-cold", action="store_true",
                    help=f"idle {SCALE_TO_ZERO_SECONDS}s first so the run starts cold")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--fresh-session", dest="fresh", action="store_true",
                   default=True, help="new session per request (default)")
    g.add_argument("--same-session", dest="fresh", action="store_false",
                   help="one session for the whole run, context grows")
    a = ap.parse_args()

    if bool(a.url) == bool(a.engine):
        sys.exit("give exactly one of --url (Cloud Run) or --engine (Agent Engine)")

    if a.url and not a.url.startswith(("http://", "https://")):
        sys.exit(f"--url is not a URL: {a.url!r}\n"
                 f"Did $CLOUD_RUN_URL / $AGENT_URL resolve? Check with: echo \"[$AGENT_URL]\"")

    if a.engine and not a.engine.startswith("projects/"):
        sys.exit(f"--engine is not a resource name: {a.engine!r}\n"
                 f"Expected projects/N/locations/L/reasoningEngines/ID")

    ae = bool(a.engine)

    cfg = json.load(open(a.profiles_file))
    prof = next((x for x in cfg["profiles"] if x["id"] == a.profile), None)
    if not prof:
        sys.exit(f"no profile '{a.profile}' in {a.profiles_file}")

    sched = offsets(prof)
    run_id = os.environ.get("RUN_ID", "unset")
    lever = os.environ.get("LEVER", "unset")
    mode = "fresh" if a.fresh else "same"
    out = a.out or f"evidence/load-{lever}-{a.profile}-{run_id}.csv"

    print(f"profile {a.profile}: {len(sched)} requests over "
          f"{prof['duration_minutes']} min")
    print(f"  {prof['description']}")
    print(f"  session mode: {mode}   app: {a.app}")
    print(f"  host:         {'Agent Engine (streamQuery)' if ae else 'Cloud Run (/run)'}")
    print(f"  target rate:  {prof['requests_per_hour']} req/hr")
    print(f"  schedule:     absolute offsets, latency does not shift the rate")
    if a.dry_run:
        print(f"  first offsets: {[round(x, 1) for x in sched[:5]]}")
        print("dry run, nothing sent")
        return

    if a.wait_for_cold:
        wait_for_scale_to_zero(SCALE_TO_ZERO_SECONDS)

    base = (a.url or "").rstrip("/")
    token = Token(kind="access" if ae else "identity")
    user = f"u_{uuid.uuid4().hex[:8]}"
    lat = []

    shared_session = None
    if not a.fresh:
        if ae:
            st, shared_session, why = ae_create_session(
                a.engine, a.location, user, token.get())
            if st not in (200, 201) or not shared_session:
                sys.exit(f"could not create Agent Engine session (HTTP {st}): {why[:300]}")
        else:
            shared_session = f"s_{uuid.uuid4().hex[:8]}"
            st, _ = post(f"{base}/apps/{a.app}/users/{user}/sessions/{shared_session}",
                         {}, token.get())
            if st not in (200, 201):
                sys.exit(f"could not create session (HTTP {st}). "
                         f"Check --app matches the package directory name.")
        print(f"  session: {shared_session}")

    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    started = time.time()
    wc = wallclock(run_id, lever, a.profile, "start")
    print(f"  wallclock: {wc}")
    na = lambda v: v if v is not None else "NA"

    with open(out, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["run_id", "lever", "profile", "seq", "utc_time", "status",
                    "latency_ms", "prompt_tokens", "completion_tokens",
                    "thoughts_tokens", "total_tokens", "model_version",
                    "traffic_type", "session_mode", "scheduled_offset_s",
                    "drift_ms", "cold_hint"])

        for i, offset in enumerate(sched):
            due = started + offset
            wait = due - time.time()
            if wait > 0:
                time.sleep(wait)
            drift_ms = int((time.time() - due) * 1000)
            if drift_ms > 60000:
                print(f"    [WARNING {drift_ms/1000:.0f}s behind schedule. "
                      f"Did the machine sleep? Use: caffeinate -dimsu python3 loadgen.py ...]",
                      flush=True)

            session = shared_session
            t0 = time.time()

            if a.fresh:
                if ae:
                    st, session, _ = ae_create_session(
                        a.engine, a.location, user, token.get())
                    if st == 401:
                        token.refresh()
                        st, session, _ = ae_create_session(
                            a.engine, a.location, user, token.get())
                else:
                    session = f"s_{uuid.uuid4().hex[:8]}"
                    st, _ = post(
                        f"{base}/apps/{a.app}/users/{user}/sessions/{session}",
                        {}, token.get())
                    if st == 401:
                        token.refresh()
                        st, _ = post(
                            f"{base}/apps/{a.app}/users/{user}/sessions/{session}",
                            {}, token.get())
                if st not in (200, 201):
                    ms = int((time.time() - t0) * 1000)
                    w.writerow([run_id, lever, a.profile, i, now(), st, ms,
                                "NA", "NA", "NA", "NA", "", "", mode,
                                round(offset, 1), drift_ms, ""])
                    fh.flush()
                    print(f"  {i+1}/{len(sched)}  session HTTP {st}", flush=True)
                    continue

            if ae:
                status, body = ae_stream_query(
                    a.engine, a.location, user, session, cfg["prompt"], token.get())
                if status == 401:
                    token.refresh()
                    status, body = ae_stream_query(
                        a.engine, a.location, user, session, cfg["prompt"], token.get())
            else:
                payload = {
                    "appName": a.app,
                    "userId": user,
                    "sessionId": session,
                    "newMessage": {"role": "user",
                                   "parts": [{"text": cfg["prompt"]}]},
                }
                status, body = post(f"{base}/run", payload, token.get())
                if status == 401:
                    token.refresh()
                    status, body = post(f"{base}/run", payload, token.get())
            ms = int((time.time() - t0) * 1000)

            if status == 200:
                parse = tokens_from_stream if ae else tokens_from_events
                pt, ct, tht, tot, mv, tt = parse(body)
            else:
                pt = ct = tht = tot = None
                mv = tt = ""

            # Request 0 is where cold starts live, and a median needs history,
            # so it can never be flagged by the ratio rule. Mark it explicitly.
            # Later requests compare against a trailing window rather than the
            # whole run, so one early spike does not raise the median enough to
            # hide a genuine second cold start mid-run.
            cold = ""
            if i == 0:
                cold = "first"
            else:
                window = lat[-COLD_HINT_WINDOW:]
                if (len(window) >= COLD_HINT_MIN_SAMPLES
                        and ms > COLD_HINT_MULTIPLE * statistics.median(window)):
                    cold = "likely"
            lat.append(ms)

            w.writerow([run_id, lever, a.profile, i, now(), status, ms,
                        na(pt), na(ct), na(tht), na(tot), mv, tt, mode,
                        round(offset, 1), drift_ms, cold])
            fh.flush()
            print(f"  {i+1}/{len(sched)}  {status}  {ms:>6}ms  "
                  f"in={na(pt)} out={na(ct)} think={na(tht)} total={na(tot)}"
                  f"{'  drift=' + str(drift_ms) + 'ms' if abs(drift_ms) > 1000 else ''}"
                  f"{'  ' + cold if cold else ''}", flush=True)

    wallclock(run_id, lever, a.profile, "done")
    elapsed = time.time() - started
    print(f"\nwrote {out}")
    if lat:
        print(f"  latency  median {int(statistics.median(lat))}ms  max {max(lat)}ms  n={len(lat)}")
        actual_rate = 3600.0 * len(lat) / elapsed
        print(f"  actual rate {actual_rate:.1f} req/hr against a target of "
              f"{prof['requests_per_hour']}")
        if abs(actual_rate - prof["requests_per_hour"]) > prof["requests_per_hour"] * 0.05:
            print("  WARNING: rate is more than 5% off target. Check the drift column.")
    w_start = datetime.fromtimestamp(started, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    w_end = now()
    print(f"\n  window for the cost queries:")
    print(f"    WINDOW_START  {w_start}")
    print(f"    WINDOW_END    {w_end}")
    if token.refreshes:
        print(f"  token refreshed {token.refreshes} time(s) during the run")
    print("\n  thoughts_tokens is billed at the output rate and never appears in")
    print("  the response text. Use total_tokens for cost, not prompt+completion.")


if __name__ == "__main__":
    main()
