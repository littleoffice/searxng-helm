#!/usr/bin/env bash
#
# Resolve chart release tags, tolerating both naming schemes present in this
# repository.
#
# The published tags are bare versions (1.0.0, 1.1.0, 1.2.0), but the release
# workflow builds `${name}-${version}` and the version job greps for
# `searxng-*`. Nothing matched, so the "may not go below the published
# version" guard silently took its "nothing released yet" branch on every run
# and has never actually constrained anything.
#
# chart-releaser's default release-name template is `{{ .Name }}-{{ .Version }}`,
# so future releases may well be prefixed even though the existing ones are
# not. Rather than pick a side and break the other, every call site goes
# through here and both forms are accepted.
#
# Usage:
#   chart-tag.sh --latest             newest released version, bare (empty if none)
#   chart-tag.sh --resolve <version>  the tag that exists for it (empty if none)

set -euo pipefail

NAME="$(sed -n 's/^name:[[:space:]]*//p' Chart.yaml | tr -d '"')"

# Bare semver tags, plus the same versions with the chart-name prefix stripped.
all_versions() {
  git tag --list \
    | sed -n -e "s/^${NAME}-\([0-9].*\)$/\1/p" -e 's/^\([0-9][0-9.]*\)$/\1/p' \
    | sort -V -u
}

case "${1:-}" in
  --latest)
    all_versions | tail -n 1
    ;;
  --resolve)
    version="${2:?usage: chart-tag.sh --resolve <version>}"
    for candidate in "${NAME}-${version}" "${version}"; do
      if git rev-parse --verify --quiet "refs/tags/${candidate}" >/dev/null; then
        printf '%s\n' "${candidate}"
        exit 0
      fi
    done
    ;;
  *)
    echo "usage: chart-tag.sh --latest | --resolve <version>" >&2
    exit 1
    ;;
esac
