#!/usr/bin/env bash
# Create the Secrets ci/04-full-values.yaml expects, in $1.
#
#   .github/ci/make-secrets.sh <namespace>
#
# Everything here is a credential, which is why none of it lives in the values
# file: the chart has no field that takes secret material, so a scenario that
# exercises these paths has to create the objects the way a user would. All of
# it is generated per run and dies with the kind cluster.
#
# The open-metrics password is the one value that has to agree in two places —
# general.open_metrics inside the settings.yml Secret, and the password half of
# the basic-auth Secret the ServiceMonitor presents — so this script generates
# it once and writes both, which is exactly the coupling an operator has to
# reproduce by hand.
set -euo pipefail

NAMESPACE="${1:?usage: make-secrets.sh <namespace>}"
SETTINGS="${2:-ci/04-settings.yml}"

command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }

metrics_password="$(openssl rand -hex 32)"
engine_token="$(openssl rand -hex 32)"
agents_engine_token="$(openssl rand -hex 32)"

# settings.yml, with the generated password inlined into general.open_metrics.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed "s|@OPEN_METRICS_PASSWORD@|${metrics_password}|; s|@ENGINE_TOKEN@|${engine_token}|; \
     s|@AGENTS_ENGINE_TOKEN@|${agents_engine_token}|" "$SETTINGS" > "$tmp"

kubectl -n "$NAMESPACE" create secret generic ci-settings \
  --from-file=settings.yml="$tmp"

kubectl -n "$NAMESPACE" create secret generic ci-metrics \
  --from-literal=username=prometheus \
  --from-literal=password="${metrics_password}"

# One engine token per relay instance. Each unlocks only its own private
# engine in the settings.yml above, which is the whole point of running two
# instances rather than two identities on one.
kubectl -n "$NAMESPACE" create secret generic ci-relay-engine-tokens \
  --from-literal=searxng-tokens="${engine_token}"

kubectl -n "$NAMESPACE" create secret generic ci-relay-agents-engine-tokens \
  --from-literal=searxng-tokens="${agents_engine_token}"

# Non-secret per-instance config. The chart takes none of this from values, so
# a scenario exercising it has to create the ConfigMaps a user would. Both
# override MAX_PDF_BYTES from mcpRelay.config, in opposite directions, so the
# envFrom ordering is observable in the running pods.
kubectl -n "$NAMESPACE" create configmap ci-relay-default-config \
  --from-literal=LOG_LEVEL=info \
  --from-literal=LOG_FORMAT=json \
  --from-literal=MCP_RATE_LIMIT_RPS=5 \
  --from-literal=MAX_PDF_BYTES=30000000

kubectl -n "$NAMESPACE" create configmap ci-relay-agents-config \
  --from-literal=LOG_LEVEL=debug \
  --from-literal=LOG_FORMAT=json \
  --from-literal=MCP_RATE_LIMIT_RPS=1 \
  --from-literal=MCP_STATELESS=true \
  --from-literal=MAX_PDF_BYTES=10000000

# Ed25519 signing key for the relay's <sec:fence> elements. Generated here
# rather than committed: a private key in a repository is a private key in a
# repository, however throwaway.
openssl genpkey -algorithm ed25519 |
  kubectl -n "$NAMESPACE" create secret generic ci-relay-fence \
    --from-file=fence-key=/dev/stdin

kubectl -n "$NAMESPACE" create secret generic ci-relay-health \
  --from-literal=health-token="$(openssl rand -hex 32)"

echo "created settings/metrics/engine-token/fence/health Secrets and the two" \
     "relay ConfigMaps in ${NAMESPACE}"
