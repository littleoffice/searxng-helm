#!/usr/bin/env bash
#
# Decide whether a CVE in a pinned image is something this repository can act
# on, and fail only when it is.
#
# Trivy on its own cannot tell those apart. "HIGH, fixed in openssl 3.5.4"
# means the *distro* shipped a fix; it says nothing about whether anyone has
# rebuilt and published an image containing it. Gating on that conflates two
# situations with opposite responses:
#
#   a newer digest exists and drops the CVE   bump values.yaml — fail the build
#   the newest digest still has the CVE       wait for upstream — do not fail
#
# So: scan the pinned digest. If it is clean, done. If it is not, scan what
# the tracked tag resolves to *now* and diff the two sets of CVE IDs. A CVE in
# the pin but not upstream is fixable by bumping. A CVE in both is not fixable
# here, and failing on it would only train people to ignore this job.
#
# The second scan runs only when the first found something, so the extra pull
# lands on the runs that already need a human.
#
# Freshness ("is the pin current?") is reported as a by-product — Trivy
# records the digest it actually scanned in .Metadata.RepoDigests — but it is
# never a gate on its own. A stale pin with no CVEs is Renovate's job, and
# Renovate's PR list says it better than a CI annotation does.
#
# Exit status: 1 only when at least one finding is fixable by bumping a pin.
# --report-only forces 0 (used by the release workflow, which records state
# rather than gating it).
#
# Requires: helm, trivy, jq. Nothing that is not already installed.

set -euo pipefail

# The tag that defines "current". MUST match the `currentValueTemplate` of the
# values.yaml custom manager in renovate.json — if the two disagree, this
# script diffs against an image Renovate will never propose a bump to.
TRACK_TAG="${IMAGE_TRACK_TAG:-latest}"

OUT_DIR="${SCAN_OUT_DIR:-scan}"
REPORT_ONLY=0
[ "${1:-}" = "--report-only" ] && REPORT_ONLY=1

mkdir -p "${OUT_DIR}/sarif" "${OUT_DIR}/raw"

log() { printf '%s\n' "$*" >&2; }

# GitHub annotations degrade to plain lines off-runner, so this stays readable
# when run by hand.
annotate() {
  local level="$1" msg="$2"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::%s::%s\n' "${level}" "${msg}"
  else
    printf '[%s] %s\n' "${level}" "${msg}" >&2
  fi
}

# Every image the chart can render, with every optional component on.
collect_images() {
  helm template searxng . \
    --set mcpRelay.enabled=true \
    --set valkey.metrics.enabled=true \
  | grep -oE 'image: "[^"]+"' \
  | sed 's/image: "//; s/"$//' \
  | sort -u
}

# Fixable HIGH/CRITICAL only. Unfixed CVEs never gate — there is nothing to
# bump to — but they still reach code scanning through the SARIF.
scan_json() {
  trivy image \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --scanners vuln \
    --format json \
    --no-progress \
    --output "$2" \
    "$1"
}

vuln_ids() {
  jq -r '[.Results[]?.Vulnerabilities[]?.VulnerabilityID] | unique | .[]' "$1"
}

severity_count() {
  jq --arg s "$2" \
    '[.Results[]?.Vulnerabilities[]? | select(.Severity == $s)] | length' "$1"
}

# The digest Trivy actually resolved. Empty when Trivy recorded none; treated
# as "unknown" everywhere rather than as a mismatch, so a registry that
# reports digests differently cannot invent a failure.
scanned_digest() {
  jq -r '(.Metadata.RepoDigests // []) | .[0] // "" | split("@")[1] // ""' "$1"
}

main() {
  local images
  images="$(collect_images)"
  log "images:"
  log "${images}"

  local entries="[]" exit_code=0

  for pinned in ${images}; do
    local repo digest slug
    repo="${pinned%@*}"
    digest="${pinned#*@}"
    slug="$(printf '%s' "${repo}" | tr '/:' '__')"

    echo "::group::${repo}"

    local pinned_json="${OUT_DIR}/raw/${slug}.pinned.json"
    scan_json "${pinned}" "${pinned_json}"

    trivy image --severity HIGH,CRITICAL --ignore-unfixed --scanners vuln \
      --format sarif --no-progress \
      --output "${OUT_DIR}/sarif/${slug}.sarif" "${pinned}"

    local crit high pinned_ids
    crit="$(severity_count "${pinned_json}" CRITICAL)"
    high="$(severity_count "${pinned_json}" HIGH)"
    pinned_ids="$(vuln_ids "${pinned_json}" | paste -sd' ' -)"

    local verdict fixable="" current="" freshness="unchecked"

    if [ -z "${pinned_ids}" ]; then
      # Clean pin. Whether it is also the newest digest is Renovate's
      # business, and not worth a second pull to find out.
      verdict="ok"
    else
      local current_json="${OUT_DIR}/raw/${slug}.current.json"
      if scan_json "${repo}:${TRACK_TAG}" "${current_json}"; then
        current="$(scanned_digest "${current_json}")"
        if [ -z "${current}" ]; then
          freshness="unknown"
        elif [ "${current}" = "${digest}" ]; then
          freshness="current"
        else
          freshness="stale"
        fi
        fixable="$(comm -23 \
          <(vuln_ids "${pinned_json}") \
          <(vuln_ids "${current_json}") | paste -sd' ' -)"
      else
        # Tag gone, registry down, rate limited. Not a reason to fail a build.
        freshness="unknown"
        log "${repo}: cannot scan :${TRACK_TAG}; comparison skipped"
      fi

      if [ -n "${fixable}" ]; then
        verdict="actionable"
        annotate error "${repo}: :${TRACK_TAG} is a newer digest that fixes ${fixable}. Bump the pin in values.yaml."
        exit_code=1
      else
        verdict="no-fix"
        case "${freshness}" in
          current) annotate warning "${repo}: ${crit} critical / ${high} high (${pinned_ids}). Pin is already the newest published digest; upstream must rebuild." ;;
          stale)   annotate warning "${repo}: ${crit} critical / ${high} high (${pinned_ids}). A newer digest exists but carries the same CVEs; bumping would not help." ;;
          *)       annotate warning "${repo}: ${crit} critical / ${high} high (${pinned_ids}). Could not compare against :${TRACK_TAG}." ;;
        esac
      fi
    fi

    entries="$(jq \
      --arg repo "${repo}" \
      --arg pinned "${digest}" \
      --arg current "${current}" \
      --arg freshness "${freshness}" \
      --arg verdict "${verdict}" \
      --argjson crit "${crit}" \
      --argjson high "${high}" \
      --arg ids "${pinned_ids}" \
      --arg fixable "${fixable}" \
      '. + [{
         image: $repo,
         pinned_digest: $pinned,
         current_digest: (if $current == "" then null else $current end),
         freshness: $freshness,
         verdict: $verdict,
         critical: $crit,
         high: $high,
         vulnerabilities: ($ids | split(" ") | map(select(. != ""))),
         fixable_by_bump: ($fixable | split(" ") | map(select(. != "")))
       }]' <<< "${entries}")"

    echo "::endgroup::"
  done

  jq -n \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg chart "$(sed -n 's/^version:[[:space:]]*//p' Chart.yaml | tr -d '"')" \
    --arg track "${TRACK_TAG}" \
    --arg commit "${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}" \
    --argjson images "${entries}" \
    '{generated: $generated, chart_version: $chart, tracked_tag: $track,
      commit: $commit, images: $images,
      verdict: (if ([$images[] | select(.verdict == "actionable")] | length) > 0
                then "actionable"
                elif ([$images[] | select(.verdict == "no-fix")] | length) > 0
                then "no-fix"
                else "ok" end)}' \
    > "${OUT_DIR}/report.json"

  write_markdown

  if [ "${REPORT_ONLY}" -eq 1 ]; then
    return 0
  fi
  return "${exit_code}"
}

write_markdown() {
  local md="${OUT_DIR}/report.md" report="${OUT_DIR}/report.json"
  {
    echo "# Image scan"
    echo
    printf '%s\n' "Chart $(jq -r .chart_version "${report}") · \
tracking \`:$(jq -r .tracked_tag "${report}")\` · \
generated $(jq -r .generated "${report}")"
    echo
    echo "| image | pinned | crit | high | state |"
    echo "|---|---|---:|---:|---|"
    jq -r '.images[] |
      "| `\(.image)` | `\(.pinned_digest[7:19])` | \(.critical) | \(.high) | " +
      (if .verdict == "actionable" then "**bump the pin**"
       elif .verdict == "no-fix" and .freshness == "current"
         then "no fix published yet"
       elif .verdict == "no-fix" and .freshness == "stale"
         then "newer digest has it too"
       elif .verdict == "no-fix" then "could not compare"
       else "clean" end) + " |"' "${report}"
    echo

    if [ "$(jq -r '[.images[] | select(.fixable_by_bump | length > 0)] | length' \
            "${report}")" != "0" ]; then
      echo "## Fixable by bumping"
      echo
      jq -r '.images[] | select(.fixable_by_bump | length > 0) |
        "- `\(.image)` → \(.fixable_by_bump | join(", "))"' "${report}"
      echo
    fi

    if [ "$(jq -r '[.images[] | select(.verdict == "no-fix")] | length' \
            "${report}")" != "0" ]; then
      echo "## Awaiting an upstream rebuild"
      echo
      echo "Present in the newest published digest too. Not actionable here."
      echo
      jq -r '.images[] | select(.verdict == "no-fix") |
        "- `\(.image)` → \(.vulnerabilities | join(", "))"' "${report}"
      echo
    fi
  } > "${md}"

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "${md}" >> "${GITHUB_STEP_SUMMARY}"
  fi
}

main "$@"
