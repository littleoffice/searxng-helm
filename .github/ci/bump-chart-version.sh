#!/usr/bin/env bash
#
# Bump Chart.yaml's patch version, and keep appVersion in step with the pinned
# SearXNG image.
#
# Renovate's custom manager rewrites image digests in values.yaml but never
# touches Chart.yaml, so its bump PR would fail two of ci.yaml's gates:
#   - the `version` job's "a digest-only change must be a patch bump" rule, and
#   - `check-appversion.sh`, which fails when appVersion no longer matches the
#     SearXNG image's org.opencontainers.image.version label.
#
# This runs as a postUpgradeTask on the chart-image rule (see renovate.json) in
# branch mode, so it fires once per grouped branch: one patch bump for the whole
# batch of image updates, plus one appVersion refresh. Renovate regenerates the
# branch from the base on every run, so Chart.yaml is always at the released
# version when this executes -- the result is deterministic however many times
# the task reruns or rebases.
#
# The appVersion refresh is best-effort: a registry hiccup leaves appVersion
# untouched rather than failing the task (which would block the PR), and CI's
# check-appversion.sh still catches a genuine mismatch.
#
# Usage: bump-chart-version.sh [Chart.yaml]
# Requires: sed, curl, jq — all already on the runner.

set -euo pipefail

file="${1:-Chart.yaml}"

# --- chart version: patch bump -----------------------------------------------

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

# --- appVersion: track the pinned SearXNG image ------------------------------

# Print the pinned SearXNG image's OCI version label, or nothing. Never fails
# the caller. The SearXNG image is the first image block in values.yaml (the
# same convention check-appversion.sh uses) and lives on docker.io.
searxng_image_version() {
  local values="$1"
  local repo digest token manifest arch_digest config_digest reg accept

  repo="$(sed -n 's/^[[:space:]]*repository:[[:space:]]*//p' "${values}" | head -n1)"
  digest="$(sed -n 's/.*digest:[[:space:]]*"\?\(sha256:[0-9a-f]\{64\}\)"\?.*/\1/p' "${values}" | head -n1)"
  [ -n "${repo}" ] && [ -n "${digest}" ] || return 0

  reg="https://registry-1.docker.io/v2/${repo}"
  accept="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

  token="$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" 2>/dev/null | jq -r '.token // empty' 2>/dev/null)" || return 0
  [ -n "${token}" ] || return 0

  manifest="$(curl -fsSL -H "Authorization: Bearer ${token}" -H "Accept: ${accept}" "${reg}/manifests/${digest}" 2>/dev/null)" || return 0
  [ -n "${manifest}" ] || return 0

  # Multi-arch index: descend to the linux/amd64 manifest before reading config.
  arch_digest="$(printf '%s' "${manifest}" | jq -r '(.manifests // []) | map(select(.platform.os=="linux" and .platform.architecture=="amd64")) | (.[0].digest // empty)' 2>/dev/null)" || return 0
  if [ -n "${arch_digest}" ]; then
    manifest="$(curl -fsSL -H "Authorization: Bearer ${token}" -H "Accept: ${accept}" "${reg}/manifests/${arch_digest}" 2>/dev/null)" || return 0
  fi

  config_digest="$(printf '%s' "${manifest}" | jq -r '.config.digest // empty' 2>/dev/null)" || return 0
  [ -n "${config_digest}" ] || return 0

  curl -fsSL -H "Authorization: Bearer ${token}" "${reg}/blobs/${config_digest}" 2>/dev/null \
    | jq -r '(.config.Labels // {}) | (."org.opencontainers.image.version" // ."org.label-schema.version" // empty)' 2>/dev/null \
    || return 0
}

values="$(dirname "${file}")/values.yaml"
if [ -f "${values}" ]; then
  app="$(searxng_image_version "${values}")"
  if [ -n "${app}" ]; then
    app_current="$(sed -n 's/^appVersion:[[:space:]]*//p' "${file}" | tr -d '"')"
    if [ "${app_current}" != "${app}" ]; then
      sed -i "s|^appVersion:.*|appVersion: \"${app}\"|" "${file}"
      echo "synced appVersion ${app_current} -> ${app} (from the pinned SearXNG image)"
    else
      echo "appVersion already matches the pinned SearXNG image (${app})"
    fi
  else
    echo "could not resolve the SearXNG image version label; leaving appVersion unchanged" >&2
  fi
fi
