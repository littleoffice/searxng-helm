#!/usr/bin/env bash
#
# Build the Artifact Hub changelog annotations for the version being released,
# out of the conventional-commit subjects since the last chart tag, and write
# them into a staged Chart.yaml.
#
# Artifact Hub does not read git. It renders its per-version changelog purely
# from `artifacthub.io/changes` in the packaged Chart.yaml, so a chart without
# that annotation shows an empty changelog forever. Deriving the annotation
# from commits is the closest thing to "it comes from git" that Artifact Hub
# will actually accept.
#
# Written into the *staged* copy under .cr-release rather than committed, so
# there is no chicken-and-egg where the release commit has to describe itself,
# and no second commit landing on main after every release.
#
# Commit type -> Artifact Hub kind. The valid kinds are fixed by Artifact Hub:
# added, changed, deprecated, removed, fixed, security.
#
#   feat                      -> added
#   fix                       -> fixed
#   perf refactor build       -> changed
#   revert docs               -> changed
#   anything mentioning a CVE -> security  (and containsSecurityUpdates: true)
#   ci test chore style       -> dropped
#
# ci/test/chore are dropped because they cannot change the packaged chart —
# the release workflow does not even trigger on those paths. A changelog that
# lists "ci: bump actionlint" trains people to stop reading it.
#
# A `!` marker or a BREAKING CHANGE trailer keeps its mapped kind but has the
# description prefixed, because Artifact Hub has no "breaking" kind and
# silently drops entries whose kind it does not recognise.
#
# Usage: gen-changes.sh <path to staged Chart.yaml>

set -euo pipefail

CHART="${1:?usage: gen-changes.sh <staged Chart.yaml>}"
REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-littleoffice/searxng-helm}"

[ -f "${CHART}" ] || { echo "no such file: ${CHART}" >&2; exit 1; }

# Appending under `annotations:` only works while it is the last top-level key.
# If someone adds a key after it, the appended block silently becomes part of
# whatever came last, so refuse rather than corrupt the packaged chart.
last_key="$(grep -nE '^[a-zA-Z_][a-zA-Z0-9_.-]*:' "${CHART}" | tail -n 1 | cut -d: -f2)"
if [ "${last_key}" != "annotations" ]; then
  echo "Chart.yaml: expected 'annotations' to be the last top-level key, found '${last_key}'." >&2
  echo "gen-changes.sh appends to that block; move annotations back to the end." >&2
  exit 1
fi

# Everything since the last published chart tag. Before the first tag, use the
# whole history — that is the 1.0.0 case and the full list is correct there.
last_tag="$(git tag --list 'searxng-*' | sed 's/^searxng-//' | sort -V | tail -n 1)"
if [ -n "${last_tag}" ] && git rev-parse --verify --quiet "refs/tags/searxng-${last_tag}" >/dev/null; then
  range="searxng-${last_tag}..HEAD"
else
  range="HEAD"
fi
echo "collecting changes over ${range}" >&2

entries=""
security="false"
count=0

# Held in a variable: an escaped space inside an inline [[ =~ ]] pattern is
# valid bash but shellcheck cannot parse it.
conventional='^([a-z]+)(\([^)]*\))?(!)?: (.+)$'

while IFS=$'\t' read -r sha subject; do
  [ -n "${subject}" ] || continue

  # type(scope)!: subject
  if [[ ! "${subject}" =~ $conventional ]]; then
    continue
  fi
  type="${BASH_REMATCH[1]}"
  bang="${BASH_REMATCH[3]}"
  text="${BASH_REMATCH[4]}"

  body="$(git log -1 --format='%B' "${sha}")"

  kind=""
  case "${type}" in
    feat)                     kind="added" ;;
    fix)                      kind="fixed" ;;
    perf|refactor|build|revert|docs) kind="changed" ;;
    *)                        continue ;;
  esac

  # A CVE anywhere in the message outranks the type: this is the release note
  # that matters, and it is what flips containsSecurityUpdates.
  if grep -qE 'CVE-[0-9]{4}-[0-9]{4,}' <<< "${body}"; then
    kind="security"
    security="true"
  fi

  if [ -n "${bang}" ] || grep -q 'BREAKING CHANGE' <<< "${body}"; then
    text="BREAKING: ${text}"
  fi

  # The description is a YAML scalar inside a block string; quoting keeps a
  # colon or a leading dash in a subject from reopening the parse.
  esc="${text//\"/\\\"}"
  entries+="    - kind: ${kind}"$'\n'
  entries+="      description: \"${esc}\""$'\n'
  entries+="      links:"$'\n'
  entries+="        - name: Commit"$'\n'
  entries+="          url: ${REPO_URL}/commit/${sha}"$'\n'
  count=$((count + 1))
done < <(git log --reverse --format=$'%H\t%s' "${range}")

if [ "${count}" -eq 0 ]; then
  # Never emit an empty list: Artifact Hub treats a malformed changes value as
  # an invalid annotation and can fail the whole version.
  entries="    - kind: changed"$'\n'
  entries+="      description: \"Maintenance release; see the repository history for details.\""$'\n'
  count=1
fi

{
  echo "  artifacthub.io/changes: |"
  printf '%s' "${entries}"
  echo "  artifacthub.io/containsSecurityUpdates: \"${security}\""
} >> "${CHART}"

echo "wrote ${count} change entries (containsSecurityUpdates=${security})" >&2

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "count=${count}"
    echo "security=${security}"
  } >> "${GITHUB_OUTPUT}"
fi
