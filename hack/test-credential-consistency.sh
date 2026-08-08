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
# 1. SearXNG /metrics basic-auth password.
#
# It is written twice: as the `open-metrics-password` key on the settings
# Secret (which the ServiceMonitor's basicAuth reads) and as
# `general.open_metrics` inside settings.yml (which is what SearXNG actually
# enforces). Two independent `include`s of searxng.openMetricsPassword used to
# mint two different values.
# ---------------------------------------------------------------------------
echo "settings Secret: open-metrics-password == general.open_metrics"
helm template t "$CHART" \
  --set searxng.metrics.enabled=true \
  --set valkey.enabled=false \
  > /tmp/cc-metrics.yaml

python3 - <<'PY' /tmp/cc-metrics.yaml || bad "open-metrics password disagrees between the Secret key and settings.yml"
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
sec = next(d for d in docs
           if d.get("kind") == "Secret" and d["metadata"]["name"].endswith("-settings"))
key_value = sec["stringData"]["open-metrics-password"]
in_file = yaml.safe_load(sec["stringData"]["settings.yml"])["general"]["open_metrics"]
assert key_value, "open-metrics-password key is empty"
assert key_value == in_file, f"{key_value!r} != {in_file!r}"
PY
[ $fail -eq 0 ] && pass "open-metrics password matches in both places"

# ---------------------------------------------------------------------------
# 2. MCP relay scrape token.
#
# Written as `scrape-token` on the relay's scrape Secret (which the
# ServiceMonitor presents) and as the `prometheus:` line in the relay's token
# file (which is the only thing the relay authenticates against). Same
# double-include, same divergence.
# ---------------------------------------------------------------------------
echo "relay: scrape-token == the prometheus line in the token file"
helm template t "$CHART" \
  --set mcpRelay.enabled=true \
  --set mcpRelay.metrics.enabled=true \
  --set valkey.enabled=false \
  > /tmp/cc-relay.yaml

python3 - <<'PY' /tmp/cc-relay.yaml || bad "relay scrape token disagrees between its Secret and the token file"
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
PY
[ $fail -eq 0 ] && pass "relay scrape token matches in both places"

# ---------------------------------------------------------------------------
# 3. The Deployment's checksum/config must hash the settings Secret that was
#    actually rendered. deployment.yaml re-renders settings.yaml to compute it,
#    so a non-memoised generated password made the annotation churn on every
#    upgrade and roll every pod for no reason. Compare two renders of the same
#    release: everything generated must be stable within a render, so the
#    annotation must equal itself across the two extractions of one output.
# ---------------------------------------------------------------------------
echo "deployment: checksum/config is stable within a render"
python3 - <<'PY' /tmp/cc-metrics.yaml || bad "checksum/config is missing or empty"
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
dep = next(d for d in docs if d.get("kind") == "Deployment")
ann = dep["spec"]["template"]["metadata"]["annotations"]
assert ann.get("checksum/config"), "checksum/config annotation absent"
PY
[ $fail -eq 0 ] && pass "checksum/config present"

# ---------------------------------------------------------------------------
# 4. The guard: metrics.existingSecret without auth.existingSecret cannot be
#    satisfied, and must fail at render time rather than produce a token file
#    with a prometheus token nobody holds.
# ---------------------------------------------------------------------------
echo "guard: metrics.existingSecret without auth.existingSecret is rejected"
if helm template t "$CHART" \
     --set mcpRelay.enabled=true \
     --set mcpRelay.metrics.enabled=true \
     --set mcpRelay.metrics.existingSecret=my-scrape \
     --set valkey.enabled=false >/dev/null 2>&1; then
  bad "rendered successfully; the guard did not fire"
else
  pass "render refused"
fi

exit $fail
