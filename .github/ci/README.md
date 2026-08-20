# CI

Two workflows. `ci.yaml` gates pull requests, `release.yaml` publishes.

## Why this isn't stock chart-testing

The usual answer for a Helm repository is `ct lint --all` plus `ct install`,
driven by `helm/chart-testing-action`. That works when charts live in
`charts/<name>/`. This chart is the repository root, and both `ct install` and
`chart-releaser` derive names and paths from a chart's parent directory —
`ct install` would build a namespace out of the basename `.`, and its upgrade
mode checks the previous chart out over the working tree.

So `ct` is used for what it does well and does not care where the chart lives
(`ct lint`: yamllint, a Yamale schema over `Chart.yaml`, `helm lint` per values
overlay), and install/upgrade is driven directly by
[`install-scenarios.sh`](install-scenarios.sh). `chart-releaser` gets the chart
staged into a temporary subdirectory rather than the repository restructured.

If the chart ever moves to `charts/searxng/`, most of this can be deleted in
favour of `ct lint --all` / `ct install --upgrade`.

## Jobs

| Job | What it proves |
| --- | --- |
| `workflows` | actionlint + shellcheck over the workflows and every `.sh` in the repo. |
| `lint` | `ct lint` and `helm lint --strict` per scenario, under both Helm 3 and Helm 4. Also checks `values.schema.json` is valid draft-07 and that it still rejects unknown keys. |
| `version` | `Chart.yaml`'s version moved forward, if anything that ends up in the package changed. |
| `render` | Every scenario renders at Kubernetes 1.25 → 1.36 and survives `kubeconform -strict`. 1.25 is the floor `Chart.yaml` claims. |
| `unit` | `hack/test-credential-consistency.sh`, plus: no generated credential reaches a container's argv or a plain env value, and no init containers appear. |
| `install` | Six scenarios installed, tested, upgraded in place and re-tested on real clusters — four Kubernetes versions under Helm 4, and 1.36 under Helm 3. |
| `upgrade-from-released` | The last published version installs and upgrades to the working tree without re-minting credentials. Skips itself before the first release. |
| `ci` | Aggregate. Point branch protection here, not at the individual jobs. |

## Scenarios

`ci/*-values.yaml` are install scenarios, not recommended configurations —
several shrink replica counts to fit a two-core runner. Files under `ci/` with
any other name (`ci/06-settings.yml`) are fixtures a scenario feeds to its
pre-install command, deliberately outside the `*-values.yaml` glob that ct and
the render jobs iterate. Each scenario may carry directives in its leading
comment block:

| Directive | Effect |
| --- | --- |
| `# ci-release: <name>` | Fix the release name. Needed when the values file hardcodes Secret names derived from it. |
| `# ci-needs: <feature>` | Declares a cluster prerequisite. Only `prometheus-crds` today, installed unconditionally by the workflow. |
| `# ci-pre-install: <cmd>` | Runs before `helm install` with `$NAMESPACE` and `$RELEASE` exported. Read as a single line, so anything long belongs in a fixture file. |

The upgrade half is the part worth keeping. This chart mints credentials and
preserves them across upgrades via a cluster `lookup`, which returns nothing
under `helm template` — so no amount of render-time testing can cover it. After
the first install the script snapshots every Secret and every
`checksum/config` annotation, upgrades with identical inputs, and requires both
to be byte-identical. A regression there re-mints credentials and rolls every
pod on every upgrade.

## Running it locally

```console
kind create cluster --image kindest/node:v1.36.1
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.93.0/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
.github/ci/install-scenarios.sh .
```

Lint without a cluster:

```console
ct lint --config ct.yaml
helm lint --strict . --values ci/04-full-values.yaml
./hack/test-credential-consistency.sh .
```

## Automated updates

The `scan` job in `ci.yaml` only *detects* that a pinned image digest carries a
CVE a newer digest already fixes — it fails, but it cannot open the PR that
fixes it. `renovate.yaml` is what closes that loop.

The loop, end to end:

1. **Renovate** (`renovate.yaml`, self-hosted on a schedule) sees the tracked
   `:latest` tags resolve to newer digests and opens **one grouped PR**
   (`groupName: chart images`) rewriting every changed digest in `values.yaml`.
2. Its custom manager touches only those digests, so a branch-mode
   `postUpgradeTask` on the chart-image rule runs
   [`bump-chart-version.sh`](bump-chart-version.sh) **once** for the batch. It
   raises `Chart.yaml`'s **patch** version (the whole batch is one bump, never
   one per image) and refreshes `appVersion` from the pinned SearXNG image's
   version label. Without the patch bump the PR fails the `version` job's
   "digest-only change must be a patch bump" rule; without the `appVersion`
   refresh it fails `check-appversion.sh`. A container bump is a patch here,
   never a minor.
3. `ci.yaml` runs on the PR: `scan` goes green (the CVE is gone), `version`
   accepts the digest-only + patch shape, and `check-appversion.sh` sees a
   matching `appVersion`.
4. On merge, `release.yaml` publishes the new patch version. The next scheduled
   scan is green.

The `appVersion` refresh is best-effort — a registry hiccup leaves it untouched
rather than failing the PR, and `check-appversion.sh` still catches a genuine
mismatch in CI.

Self-hosted rather than the hosted Mend app on purpose: `postUpgradeTasks`
(step 2) is only available to a self-hosted run, and it keeps the whole flow
auditable in this repository.

**Prerequisite — `RENOVATE_TOKEN`.** Renovate needs a credential to open PRs,
read as the repo secret `RENOVATE_TOKEN`. Until it is set, `renovate.yaml` is a
no-op that logs and exits 0. Use either:

- **A GitHub App** (preferred — least privilege, no personal account attached):
  install it on this repo with **Contents: read/write** and **Pull requests:
  read/write**, and store an installation token (or the App id + private key,
  via the env vars Renovate reads) as `RENOVATE_TOKEN`.
- **A fine-grained PAT** scoped to this repository with **Contents:
  read/write** and **Pull requests: read/write**.

`allowedPostUpgradeCommands` is a self-hosted admin setting that cannot live in
`renovate.json`; it is set in `renovate.yaml` and permits only
`bump-chart-version.sh`.

## Publishing

`release.yaml` fires on pushes to `main` that touch packaged content, and is a
no-op when `Chart.yaml`'s version already has a tag. The first release is
`1.0.0`; the higher numbers in the git history predate any tag and were never
installable. It publishes to:

- **`ghcr.io/<owner>/charts/searxng`** — OCI, signed with cosign keyless and
  carrying a SLSA provenance attestation pushed to the registry alongside it.
  This is the distribution Artifact Hub tracks.
- **a GitHub Release** under the bare version tag (e.g. `1.2.1`), created
  directly (`gh release create`) — the human-facing record carrying the
  packaged `.tgz`, the changelog, the SBOMs and the release-time scan report.

There is no `gh-pages` classic Helm repo: the chart is consumed over OCI
(`helm install … oci://ghcr.io/<owner>/charts/searxng`), so `chart-releaser`
and the Pages index it maintains were dropped.

Verify a published chart:

```console
cosign verify ghcr.io/littleoffice/charts/searxng:1.0.0 \
  --certificate-identity-regexp '^https://github.com/littleoffice/searxng-helm/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

gh attestation verify oci://ghcr.io/littleoffice/charts/searxng:1.0.0 \
  --owner littleoffice
```
