#!/usr/bin/env bash
# Install, test, upgrade and re-test every scenario under ci/ against the
# cluster the current kubeconfig points at.
#
#   .github/ci/install-scenarios.sh [chart-dir]
#
# Each ci/*-values.yaml may carry directives in its leading comment block:
#
#   # ci-release: <name>       fix the release name (default: derived from file)
#   # ci-needs: <feature>      required cluster prerequisite; currently only
#                              `prometheus-crds`, installed by the workflow
#   # ci-pre-install: <cmd>    run before `helm install`, with $NAMESPACE and
#                              $RELEASE exported. Runs through `bash -c`.
#
# The upgrade half is the point of this script rather than an afterthought.
# This chart generates credentials and preserves them across upgrades with a
# cluster `lookup`; that path cannot be exercised by `helm template`, because
# `lookup` returns nothing there. So after the first install we snapshot the
# generated secret material and the Deployment's checksum/config annotation,
# run an upgrade with identical inputs, and require both to be byte-identical.
# A regression makes every upgrade re-mint credentials and roll every pod.

set -euo pipefail

CHART="${1:-.}"
CHART_ABS="$(cd "$CHART" && pwd)"
FAILED=0

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILED=1; }

# Read a `# key: value` directive out of a values file's comment block.
directive() {
  local file="$1" key="$2"
  sed -n "s/^#[[:space:]]*${key}:[[:space:]]*//p" "$file" | head -n 1
}

dump_diagnostics() {
  local ns="$1" release="$2"
  printf '::group::diagnostics for %s in %s\n' "$release" "$ns"
  kubectl -n "$ns" get all,secrets,networkpolicies,ingress,servicemonitors 2>&1 || true
  kubectl -n "$ns" describe pods 2>&1 || true
  kubectl -n "$ns" logs --all-containers --tail=200 --selector=app.kubernetes.io/instance="$release" 2>&1 || true
  kubectl -n "$ns" get events --sort-by=.lastTimestamp 2>&1 | tail -50 || true
  printf '::endgroup::\n'
}

# Everything the chart may have generated, in a form that can be diffed. Sorted
# so map ordering cannot produce a spurious difference.
snapshot_secrets() {
  local ns="$1"
  kubectl -n "$ns" get secrets \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.data}{"\n"}{end}' \
    2>/dev/null | grep -v 'sh.helm.release' | sort
}

snapshot_checksums() {
  local ns="$1"
  kubectl -n "$ns" get deployments,statefulsets \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.metadata.annotations['"'"'checksum/config'"'"']}{"\n"}{end}' \
    2>/dev/null | sort
}

run_scenario() {
  local file="$1"
  local base release namespace pre_install
  base="$(basename "$file" .yaml)"
  base="${base%-values}"

  release="$(directive "$file" 'ci-release')"
  [ -n "$release" ] || release="ci-${base##*-}"
  namespace="ci-${base}"
  pre_install="$(directive "$file" 'ci-pre-install')"

  log "scenario ${base}  (release=${release} namespace=${namespace})"

  kubectl create namespace "$namespace" >/dev/null

  if [ -n "$pre_install" ]; then
    printf '  pre-install: %s\n' "$pre_install"
    NAMESPACE="$namespace" RELEASE="$release" bash -c "$pre_install"
  fi

  if ! helm install "$release" "$CHART_ABS" \
        --namespace "$namespace" \
        --values "$file" \
        --wait --wait-for-jobs --timeout 10m; then
    bad "${base}: install failed"
    dump_diagnostics "$namespace" "$release"
    kubectl delete namespace "$namespace" --wait=false >/dev/null 2>&1 || true
    return
  fi
  ok "${base}: installed"

  if ! helm test "$release" --namespace "$namespace" --logs --timeout 5m; then
    bad "${base}: helm test failed"
    dump_diagnostics "$namespace" "$release"
    helm uninstall "$release" --namespace "$namespace" --wait >/dev/null 2>&1 || true
    kubectl delete namespace "$namespace" --wait=false >/dev/null 2>&1 || true
    return
  fi
  ok "${base}: helm test passed"

  local secrets_before checksums_before secrets_after checksums_after
  secrets_before="$(snapshot_secrets "$namespace")"
  checksums_before="$(snapshot_checksums "$namespace")"

  if ! helm upgrade "$release" "$CHART_ABS" \
        --namespace "$namespace" \
        --values "$file" \
        --wait --wait-for-jobs --timeout 10m; then
    bad "${base}: upgrade failed"
    dump_diagnostics "$namespace" "$release"
    kubectl delete namespace "$namespace" --wait=false >/dev/null 2>&1 || true
    return
  fi
  ok "${base}: upgraded in place"

  secrets_after="$(snapshot_secrets "$namespace")"
  checksums_after="$(snapshot_checksums "$namespace")"

  if [ "$secrets_before" != "$secrets_after" ]; then
    bad "${base}: secret material changed across a no-op upgrade"
    printf '::group::secret diff\n'
    diff <(printf '%s\n' "$secrets_before") <(printf '%s\n' "$secrets_after") || true
    printf '::endgroup::\n'
  else
    ok "${base}: generated credentials survived the upgrade"
  fi

  if [ "$checksums_before" != "$checksums_after" ]; then
    bad "${base}: checksum/config churned across a no-op upgrade (pods rolled for nothing)"
    printf '::group::checksum diff\n'
    diff <(printf '%s\n' "$checksums_before") <(printf '%s\n' "$checksums_after") || true
    printf '::endgroup::\n'
  else
    ok "${base}: checksum/config stable"
  fi

  if ! helm test "$release" --namespace "$namespace" --logs --timeout 5m; then
    bad "${base}: helm test failed after upgrade"
    dump_diagnostics "$namespace" "$release"
  else
    ok "${base}: helm test passed after upgrade"
  fi

  helm uninstall "$release" --namespace "$namespace" --wait --timeout 5m >/dev/null
  kubectl delete namespace "$namespace" --wait=false >/dev/null
  ok "${base}: uninstalled cleanly"
}

shopt -s nullglob
scenarios=("$CHART_ABS"/ci/*-values.yaml)
shopt -u nullglob

if [ ${#scenarios[@]} -eq 0 ]; then
  echo "no scenarios found under ${CHART_ABS}/ci" >&2
  exit 1
fi

for scenario in "${scenarios[@]}"; do
  run_scenario "$scenario"
done

log "summary"
if [ "$FAILED" -ne 0 ]; then
  echo "one or more scenarios failed" >&2
  exit 1
fi
echo "all ${#scenarios[@]} scenarios passed"
