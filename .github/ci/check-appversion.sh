#!/usr/bin/env bash
#
# Chart.yaml's appVersion has to say what is actually in the pinned image.
#
# It is emitted as `app.kubernetes.io/version` on every object in the release
# — the label people query to answer "what is running" — and Artifact Hub
# shows it as the application version. `appVersion: "latest"` makes both of
# those say nothing, in a chart that otherwise pins every image by digest and
# refuses to render if a digest is malformed.
#
# The check reads the image's own OCI labels out of the Trivy JSON that
# scan-images.sh already wrote, so it needs no registry call and no new tool.
# Whenever Renovate bumps the digest, this is what notices that appVersion was
# left behind — and the failure message carries the value to set.
#
# Two levels, deliberately:
#
#   appVersion is empty or "latest"   always fails. This is a statement the
#                                     chart is making about itself and it is
#                                     never correct.
#   label present and disagrees       fails, naming the expected value.
#   label absent                      notice only. Not every image publishes
#                                     org.opencontainers.image.version, and a
#                                     missing label is not a chart defect.
#
# Usage: check-appversion.sh [scan dir]   (default: scan)

set -euo pipefail

SCAN_DIR="${1:-${SCAN_OUT_DIR:-scan}}"

annotate() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::%s::%s\n' "$1" "$2"
  else
    printf '[%s] %s\n' "$1" "$2" >&2
  fi
}

app_version="$(sed -n 's/^appVersion:[[:space:]]*//p' Chart.yaml | tr -d '"')"

# The SearXNG image is the one appVersion describes; the sidecars have their
# own versions and are not the application.
repo="$(sed -n 's/^[[:space:]]*repository:[[:space:]]*//p' values.yaml | head -n 1)"
slug="$(printf '%s' "docker.io/${repo}" | tr '/:' '__')"
scan="${SCAN_DIR}/raw/${slug}.pinned.json"

if [ -z "${app_version}" ] || [ "${app_version}" = "latest" ]; then
  fail=1
else
  fail=0
fi

image_version=""
if [ -f "${scan}" ]; then
  image_version="$(jq -r '
    (.Metadata.ImageConfig.config.Labels // {}) as $l
    | $l["org.opencontainers.image.version"]
      // $l["org.label-schema.version"]
      // ""' "${scan}")"
else
  annotate notice "check-appversion: no scan output at ${scan}; label comparison skipped."
fi

if [ -n "${image_version}" ]; then
  echo "image label org.opencontainers.image.version = ${image_version}"
  if [ "${app_version}" != "${image_version}" ]; then
    annotate error "Chart.yaml appVersion is \"${app_version}\" but the pinned ${repo} image reports ${image_version}. Set appVersion to ${image_version}."
    exit 1
  fi
  echo "appVersion ${app_version} matches the pinned image."
  exit 0
fi

annotate notice "${repo} publishes no version label; appVersion cannot be verified against the image."

if [ "${fail}" -eq 1 ]; then
  annotate error "Chart.yaml appVersion is \"${app_version}\". It is rendered as app.kubernetes.io/version on every object and shown by Artifact Hub, so it has to name the SearXNG build the digest pins — not a floating tag."
  exit 1
fi

echo "appVersion ${app_version} is set; could not cross-check it against the image."
