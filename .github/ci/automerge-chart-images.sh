#!/usr/bin/env bash
#
# Merge Renovate's grouped chart-image PR once it has been open for a week, but
# only when it moves an image that matters.
#
# The PR batches every values.yaml digest (renovate.json, `groupName: chart
# images`). Two of those images are worth shipping without a human:
#   - searxng/searxng: engine fixes. Upstream sites change under the scrapers
#     constantly, and a stale image is a search instance that quietly returns
#     less.
#   - littleoffice/mcp-searxng-relay: the relay's security and feature set.
# The others (chainguard/curl for `helm test`, valkey and its exporter) are not
# mission critical, so a PR that moves only those keeps waiting for a person.
#
# A PR is merged only if ALL of the following hold; anything else is skipped
# with the reason in the log and the job summary, and retried on the next run:
#   1. it is the Renovate chart-image branch (head `renovate/chart-images` in
#      this repository, label `chart-image`), open and not a draft;
#   2. it was opened at least MIN_AGE_DAYS ago (default 7);
#   3. it touches nothing but Chart.yaml and values.yaml, and in values.yaml
#      nothing but `digest:` lines -- the same shape ci.yaml's version job
#      treats as a patch. Anything more is a change someone has to read;
#   4. the searxng and/or mcp-searxng-relay digest differs from the merge base;
#   5. GitHub reports it mergeable, and every check run and commit status on
#      the head commit has finished as success, neutral or skipped (and there
#      is at least one);
# and the merge is pinned to the head commit that was checked, so a Renovate
# push landing between the check and the merge makes the merge fail instead of
# shipping something unchecked.
#
# Usage: automerge-chart-images.sh
# Env:
#   GH_TOKEN      token used for reading and merging (required)
#   GH_REPO       owner/repo (required)
#   MIN_AGE_DAYS  minimum PR age in days (default 7)
#   DRY_RUN       "true" to report what would be merged without merging
# Requires: gh, jq, yq (mikefarah v4, as on the GitHub runner).

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GH_REPO:?GH_REPO is required (owner/repo)}"
min_age_days="${MIN_AGE_DAYS:-7}"
dry_run="${DRY_RUN:-false}"

head_branch="renovate/chart-images"
label="chart-image"

# The images whose bump makes the PR worth merging unattended, as yq paths
# into values.yaml.
critical_paths=(
  ".image.digest"           # searxng/searxng
  ".mcpRelay.image.digest"  # littleoffice/mcp-searxng-relay
)

summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
note() {
  echo "$*"
  echo "- $*" >> "${summary}"
}

# Contents of values.yaml at a commit.
values_at() {
  gh api -H "Accept: application/vnd.github.raw+json" \
    "repos/${GH_REPO}/contents/values.yaml?ref=$1"
}

echo "### Chart-image auto-merge" >> "${summary}"
echo >> "${summary}"

prs="$(gh pr list --state open --head "${head_branch}" --label "${label}" \
  --json number --jq '.[].number')"
if [ -z "${prs}" ]; then
  note "No open \`${head_branch}\` PR; nothing to do."
  exit 0
fi

now="$(date -u +%s)"
min_age_s=$((min_age_days * 86400))

for pr in ${prs}; do
  info="$(gh pr view "${pr}" --json \
    number,title,url,isDraft,createdAt,headRefOid,headRepository,headRepositoryOwner,baseRefName,mergeable,files,statusCheckRollup)"
  title="$(jq -r .title <<< "${info}")"
  ref="#${pr} (${title})"

  # 1. Same-repository branch, not a draft.
  owner="$(jq -r '.headRepositoryOwner.login + "/" + .headRepository.name' <<< "${info}")"
  if [ "${owner,,}" != "${GH_REPO,,}" ]; then
    note "${ref}: head is in ${owner}, not ${GH_REPO}; skipped."
    continue
  fi
  if [ "$(jq -r .isDraft <<< "${info}")" = "true" ]; then
    note "${ref}: draft; skipped."
    continue
  fi

  # 2. Age.
  created="$(jq -r .createdAt <<< "${info}")"
  age_s=$((now - $(date -u -d "${created}" +%s)))
  age_d=$((age_s / 86400))
  if [ "${age_s}" -lt "${min_age_s}" ]; then
    note "${ref}: open ${age_d}d, needs ${min_age_days}d; waiting."
    continue
  fi

  # 3. Shape: only Chart.yaml + values.yaml, and only digests in values.yaml.
  others="$(jq -r '.files[].path | select(. != "Chart.yaml" and . != "values.yaml")' <<< "${info}")"
  if [ -n "${others}" ]; then
    note "${ref}: also changes $(tr '\n' ' ' <<< "${others}")- needs review; skipped."
    continue
  fi

  head_sha="$(jq -r .headRefOid <<< "${info}")"
  base_ref="$(jq -r .baseRefName <<< "${info}")"
  base_sha="$(gh api "repos/${GH_REPO}/compare/${base_ref}...${head_sha}" \
    --jq .merge_base_commit.sha)"

  non_digest="$(gh api "repos/${GH_REPO}/compare/${base_sha}...${head_sha}" \
    --jq '.files[] | select(.filename == "values.yaml") | .patch' \
    | grep -E '^[+-]' \
    | grep -Ev '^(\+\+\+|---)' \
    | grep -Evc '^[+-][[:space:]]*digest:[[:space:]]*"sha256:[0-9a-f]{64}"' \
    || true)"
  if [ "${non_digest:-0}" -ne 0 ]; then
    note "${ref}: values.yaml changes more than image digests; skipped."
    continue
  fi

  # 4. A critical image moved.
  base_values="$(values_at "${base_sha}")"
  head_values="$(values_at "${head_sha}")"
  bumped=()
  for path in "${critical_paths[@]}"; do
    old="$(yq -r "${path}" <<< "${base_values}")"
    new="$(yq -r "${path}" <<< "${head_values}")"
    if [ "${old}" != "${new}" ]; then
      bumped+=("$(yq -r "${path%.digest}.repository" <<< "${head_values}")")
    fi
  done
  if [ "${#bumped[@]}" -eq 0 ]; then
    note "${ref}: bumps neither searxng nor mcp-searxng-relay; left for review."
    continue
  fi

  # 5. Mergeable and green.
  mergeable="$(jq -r .mergeable <<< "${info}")"
  if [ "${mergeable}" != "MERGEABLE" ]; then
    note "${ref}: GitHub reports mergeable=${mergeable}; skipped."
    continue
  fi

  # statusCheckRollup mixes check runs (status/conclusion) and commit statuses
  # (state). Anything not finished-and-passing blocks the merge.
  total="$(jq '.statusCheckRollup | length' <<< "${info}")"
  failing="$(jq -r '
    .statusCheckRollup[]
    | if .__typename == "StatusContext" then
        select(.state != "SUCCESS") | "\(.context): \(.state)"
      else
        select(.status != "COMPLETED"
               or ((.conclusion // "") | IN("SUCCESS", "NEUTRAL", "SKIPPED") | not))
        | "\(.name): \(if (.conclusion // "") == "" then .status else .conclusion end)"
      end' <<< "${info}")"
  if [ "${total}" -eq 0 ]; then
    note "${ref}: no checks reported on ${head_sha:0:7}; skipped."
    continue
  fi
  if [ -n "${failing}" ]; then
    note "${ref}: checks not green on ${head_sha:0:7}: $(paste -sd ',' <<< "${failing}"); skipped."
    continue
  fi

  what="$(printf '%s, ' "${bumped[@]}")"
  what="${what%, }"
  if [ "${dry_run}" = "true" ]; then
    note "${ref}: open ${age_d}d, bumps ${what}, all ${total} checks green -- would merge ${head_sha:0:7} (dry run)."
    continue
  fi

  if gh pr merge "${pr}" --merge --match-head-commit "${head_sha}" \
       --subject "Merge pull request #${pr} from ${GH_REPO%%/*}/${head_branch}" \
       --body "Auto-merged after ${age_d} days open: bumps ${what}, all ${total} checks green on ${head_sha}."; then
    note "${ref}: merged ${head_sha:0:7} (bumps ${what})."
  else
    echo "::warning::${ref}: merge of ${head_sha:0:7} failed (branch protection, or the head moved); retrying next run."
    note "${ref}: merge failed; retrying next run."
  fi
done
