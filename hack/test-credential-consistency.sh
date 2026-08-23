#!/usr/bin/env bash
# Assert that every generated credential this chart writes to two places holds
# the same value in both.
#
#   ./hack/test-credential-consistency.sh [chart-dir]
#
# Neither of the failures below is visible to `helm lint`, and neither produces
# an invalid manifest — the rendered YAML is well-formed and installs cleanly.
# They only surface as an HTTP 401 from a component nobody is watching yet.
#
# Runs entirely against `helm template`, so no cluster is needed. Note that
# `lookup` returns nothing under `helm template`, which is what makes this test
# meaningful: every value here is freshly generated, so if two call sites were
# to generate independently they would disagree, and that is precisely what is
# being asserted against.
set -euo pipefail

CHART="${1:-.}"
command -v helm >/dev/null || { echo "helm not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }

fail=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }

# ---------------------------------------------------------------------------
# 1. Nothing this chart renders carries a credential the user typed.
#
# values.yaml has no field that takes secret material: settings.yml, the
# /metrics basic-auth pair, the relay's engine tokens, its fence key and its
# /health token all come from Secrets the user manages, and the credentials the
# chart does own (secret_key, the Valkey password, the relay bearer tokens) are
# generated straight into Secrets. So the ServiceMonitor's basicAuth must
# resolve to the Secret the operator named, and no object the chart renders may
# carry settings.yml.
# ---------------------------------------------------------------------------
echo "metrics: basicAuth resolves to the Secret the operator named"
helm template t "$CHART" \
  --set searxng.existingSettingsSecret=my-settings \
  --set searxng.metrics.enabled=true \
  --set searxng.metrics.existingSecret=my-metrics \
  --set metrics.serviceMonitor.enabled=true \
  --set valkey.enabled=false \
  > /tmp/cc-metrics.yaml

python3 - <<'PY' /tmp/cc-metrics.yaml || bad "the ServiceMonitor's basicAuth does not resolve to searxng.metrics.existingSecret"
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]

sm = next(d for d in docs if d.get("kind") == "ServiceMonitor"
          and not d["metadata"]["name"].endswith("mcp-relay"))
auth = next(ep["basicAuth"] for ep in sm["spec"]["endpoints"] if "basicAuth" in ep)
assert auth["username"] == {"name": "my-metrics", "key": "username"}, auth
assert auth["password"] == {"name": "my-metrics", "key": "password"}, auth

# The chart must render no object of its own for any of this.
for d in docs:
    if d.get("kind") != "Secret":
        continue
    body = d.get("stringData") or {}
    name = d["metadata"]["name"]
    assert "settings.yml" not in body, f"{name} carries a chart-rendered settings.yml"
    assert "open-metrics-password" not in body, f"{name} carries a chart-rendered metrics password"
PY
[ $fail -eq 0 ] && pass "basicAuth points at the operator's Secret; the chart renders none of its own"

# ---------------------------------------------------------------------------
# 2. MCP relay scrape token, per instance.
#
# One generated value per relay has to reach three places that all have to
# agree: `scrape-token` on that instance's scrape Secret, the `prometheus:` row
# in that instance's token file, and $MCP_METRICS_TOKEN on that instance's
# container. Two independent `include`s of searxng.relay.scrapeToken used to
# mint two different values.
#
# With more than one instance there is a second way to get this wrong: the
# helpers memoise, and a memo key that is not per instance hands every relay
# the first one's tokens. So this renders two instances and also asserts that
# they share nothing.
# ---------------------------------------------------------------------------
echo "relay: scrape-token == the prometheus row == MCP_METRICS_TOKEN, per instance"
helm template t "$CHART" \
  --set searxng.existingSettingsSecret=my-settings \
  --set mcpRelay.enabled=true \
  --set mcpRelay.instances[0].name=default \
  --set mcpRelay.instances[0].metrics.enabled=true \
  --set mcpRelay.instances[1].name=agents \
  --set mcpRelay.instances[1].metrics.enabled=true \
  --set valkey.enabled=false \
  > /tmp/cc-relay.yaml

python3 - <<'PY' /tmp/cc-relay.yaml || bad "a relay instance's scrape token disagrees across its three places"
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
secs = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "Secret"}
deps = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "Deployment"}

tokens_seen = []
for suffix in ("", "-agents"):
    base = f"t-searxng-mcp-relay{suffix}"
    scrape = secs[base + "-scrape"]["stringData"]["scrape-token"]
    row = next(l for l in secs[base]["stringData"]["tokens"].splitlines()
               if l.startswith("prometheus:")).split(":", 1)[1]
    env = {e["name"]: e for e in deps[base]["spec"]["template"]["spec"]["containers"][0]["env"]}
    ref = env["MCP_METRICS_TOKEN"]["valueFrom"]["secretKeyRef"]
    assert scrape, f"{base}: scrape-token is empty"
    assert scrape == row, f"{base}: {scrape!r} != {row!r}"
    assert ref["name"] == base + "-scrape", (base, ref)
    assert secs[ref["name"]]["stringData"][ref["key"]] == scrape, (base, ref)
    tokens_seen.append({l.split(":", 1)[1]
                        for l in secs[base]["stringData"]["tokens"].splitlines()
                        if l and not l.startswith("#")})

shared = tokens_seen[0] & tokens_seen[1]
assert not shared, f"two instances share {len(shared)} token(s) — the memo is not per instance"
PY
[ $fail -eq 0 ] && pass "each instance's scrape token matches in all three places, and instances share none"

# ---------------------------------------------------------------------------
# 3. The Deployment rolls when a config file the chart *does* render changes,
#    and carries no checksum for the one it does not. settings.yml comes from a
#    Secret the chart cannot read, so a checksum for it could only ever hash
#    the wrong thing -- it used to hash the chart's own settings template,
#    which stopped meaning anything when that template went away.
# ---------------------------------------------------------------------------
echo "deployment: checksums cover what the chart renders, and nothing else"
helm template t "$CHART" \
  --set searxng.existingSettingsSecret=my-settings \
  --set searxng.limiter.enabled=true \
  > /tmp/cc-limiter.yaml

python3 - <<'PY' /tmp/cc-limiter.yaml || bad "checksum annotations do not match what the chart renders"
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
dep = next(d for d in docs if d.get("kind") == "Deployment")
ann = dep["spec"]["template"]["metadata"].get("annotations") or {}
assert ann.get("checksum/limiter"), "limiter.toml is mounted but has no checksum"
assert "checksum/config" not in ann, "a checksum survives for a file the chart cannot read"
PY
[ $fail -eq 0 ] && pass "limiter.toml is hashed; settings.yml is not"

# ---------------------------------------------------------------------------
# 4. The guards: combinations that cannot be satisfied must fail at render
#    time rather than produce a running pod that 401s or CrashLoops.
# ---------------------------------------------------------------------------
echo "guard: metrics.existingSecret without auth.existingSecret is rejected"
if helm template t "$CHART" \
     --set searxng.existingSettingsSecret=my-settings \
     --set mcpRelay.enabled=true \
     --set mcpRelay.instances[0].name=default \
     --set mcpRelay.instances[0].metrics.enabled=true \
     --set mcpRelay.instances[0].metrics.existingSecret=my-scrape \
     --set valkey.enabled=false >/dev/null 2>&1; then
  bad "rendered successfully; the guard did not fire"
else
  pass "render refused"
fi

echo "guard: no values field accepts secret material"
for setting in \
  searxng.secretKey=deadbeef \
  searxng.metrics.password=deadbeef \
  valkey.auth.password=deadbeef \
  valkey.external.url=valkey://:pw@host:6379/0 \
  'mcpRelay.instances[0].auth.identities[0].token=deadbeefdeadbeefdeadbeefdeadbeef' \
  'mcpRelay.instances[0].searxngTokens.tokens[0]=deadbeef' \
  'mcpRelay.instances[0].fenceKey.key=deadbeef' \
  'mcpRelay.instances[0].healthToken.token=deadbeefdeadbeefdeadbeefdeadbeef' \
  'mcpRelay.config.MCP_AUTH_TOKEN=deadbeefdeadbeefdeadbeefdeadbeef' \
  'mcpRelay.config.MCP_METRICS_TOKEN=deadbeefdeadbeefdeadbeefdeadbeef' \
  'mcpRelay.config.SEARXNG_TOKENS=deadbeef' \
  'mcpRelay.config.FENCE_SIGNING_KEY=deadbeef' 
do
  if helm template t "$CHART" \
       --set searxng.existingSettingsSecret=my-settings \
       --set mcpRelay.enabled=true \
       --set mcpRelay.instances[0].name=default \
       --set "$setting" >/dev/null 2>&1; then
    bad "the schema accepted ${setting%%=*}, which would put a credential in values"
  fi
done
[ $fail -eq 0 ] && pass "every credential-shaped values key is rejected"

exit $fail
