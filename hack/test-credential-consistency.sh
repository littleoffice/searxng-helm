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
# 2. MCP relay scrape token.
#
# One generated value has to reach three places that all have to agree:
#
#   * `scrape-token` on the relay's scrape Secret, which the ServiceMonitor
#     presents;
#   * the `prometheus:` line in the token file, which is what relay images up
#     to v1.3.0 authenticate /metrics against (metrics.mcpIdentity);
#   * $MCP_METRICS_TOKEN on the relay container, which is what newer images
#     authenticate /metrics against instead.
#
# Two independent `include`s of searxng.relay.scrapeToken used to mint two
# different values. Any disagreement here is a silent 401 on every scrape.
# ---------------------------------------------------------------------------
echo "relay: scrape-token == the prometheus line == MCP_METRICS_TOKEN"
helm template t "$CHART" \
  --set searxng.existingSettingsSecret=my-settings \
  --set mcpRelay.enabled=true \
  --set mcpRelay.metrics.enabled=true \
  --set valkey.enabled=false \
  > /tmp/cc-relay.yaml

python3 - <<'PY' /tmp/cc-relay.yaml || bad "relay scrape token disagrees between its Secret, the token file and MCP_METRICS_TOKEN"
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
secs = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "Secret"}
scrape = next(v for k, v in secs.items() if k.endswith("-mcp-relay-scrape"))
tokens = next(v for k, v in secs.items() if k.endswith("-mcp-relay"))
token_value = scrape["stringData"]["scrape-token"]
line = next(l for l in tokens["stringData"]["tokens"].splitlines()
            if l.startswith("prometheus:"))
in_file = line.split(":", 1)[1]
assert token_value, "scrape-token is empty"
assert token_value == in_file, f"{token_value!r} != {in_file!r}"

# The env var must reference that same Secret and key rather than carrying a
# second copy of the value -- a literal here would be a credential in the
# manifest as well as a second thing to keep in step.
dep = next(d for d in docs if d.get("kind") == "Deployment"
           and d["metadata"]["name"].endswith("-mcp-relay"))
env = {e["name"]: e for e in dep["spec"]["template"]["spec"]["containers"][0]["env"]}
ref = env["MCP_METRICS_TOKEN"]["valueFrom"]["secretKeyRef"]
assert ref["name"] == scrape["metadata"]["name"], ref
assert scrape["stringData"][ref["key"]] == token_value, ref
PY
[ $fail -eq 0 ] && pass "scrape token matches in all three places"

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
     --set mcpRelay.metrics.enabled=true \
     --set mcpRelay.metrics.existingSecret=my-scrape \
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
  'mcpRelay.auth.identities[0].token=deadbeefdeadbeefdeadbeefdeadbeef' \
  'mcpRelay.searxngTokens.tokens[0]=deadbeef' \
  mcpRelay.fenceKey.key=deadbeef \
  mcpRelay.healthToken.token=deadbeefdeadbeefdeadbeefdeadbeef
do
  if helm template t "$CHART" \
       --set searxng.existingSettingsSecret=my-settings \
       --set mcpRelay.enabled=true \
       --set "$setting" >/dev/null 2>&1; then
    bad "the schema accepted ${setting%%=*}, which would put a credential in values"
  fi
done
[ $fail -eq 0 ] && pass "every credential-shaped values key is rejected"

exit $fail
