#!/usr/bin/env bash
#
# Bump Chart.yaml's patch version by one.
#
# Renovate's custom manager rewrites an image digest in values.yaml but never
# touches Chart.yaml, so its bump PR would fail the `version` job's "A
# digest-only change must be a patch bump" rule and never merge. This runs as a
# postUpgradeTask on the chart-image rule (see renovate.json) to move the patch
# component in the same branch, turning a stale-pin finding into a mergeable,
# releasable PR.
#
# Renovate regenerates the branch from the base on every run, so Chart.yaml is
# always at the released version when this executes -- the result is one patch
# bump, deterministically, however many times the task reruns or rebases.
#
# Usage: bump-chart-version.sh [Chart.yaml]

set -euo pipefail

file="${1:-Chart.yaml}"

current="$(sed -n 's/^version:[[:space:]]*//p' "${file}" | tr -d '"')"
if ! printf '%s' "${current}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "cannot parse a MAJOR.MINOR.PATCH version from ${file}: '${current}'" >&2
  exit 1
fi

IFS=. read -r major minor patch <<< "${current}"
next="${major}.${minor}.$((patch + 1))"

# Anchor on the leading `version:` key so appVersion and any nested version
# stay untouched.
sed -i "s/^version:[[:space:]]*\"\\?${current}\"\\?\$/version: ${next}/" "${file}"

new="$(sed -n 's/^version:[[:space:]]*//p' "${file}" | tr -d '"')"
if [ "${new}" != "${next}" ]; then
  echo "failed to rewrite ${file}: still reads '${new}'" >&2
  exit 1
fi

echo "bumped chart version ${current} -> ${next}"
