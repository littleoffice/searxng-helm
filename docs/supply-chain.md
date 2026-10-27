# Supply-chain statement

This document answers one question for anyone evaluating `searxng-helm` for a
controlled environment: **if I install this chart, what am I actually trusting,
and how do I verify it hasn't been tampered with?**

It is a factual statement, not a marketing one. Where the project has gaps, they
are listed in [Known gaps](#known-gaps) rather than omitted.

For vulnerability reporting and disclosure, see [SECURITY.md](SECURITY.md).

## Contents

- [Development process](#development-process)
- [What the package contains](#what-the-package-contains)
- [Images](#images)
- [Build provenance](#build-provenance)
- [Verification](#verification)
- [Testing](#testing)
- [Known gaps](#known-gaps)

## Development process

This section is part of the supply-chain statement because how the code came to
exist is a provenance fact, and a reviewer is entitled to it.

**The project is entirely AI-generated.** The templates, `values.yaml` and its
schema, the documentation, the examples, the CI workflows, and the helper
scripts were all written by an AI assistant (Claude) working from the
maintainer's direction; the maintainer has written none of it. That includes
the commits under the maintainer's own GitHub account: git's author field
records who committed a change, not who wrote it. Image digest bumps are the
exception: Renovate opens those ([Images](#images)).

**A single human maintainer is accountable for everything that ships.** The
maintainer is the holder of the GitHub account with admin rights on the
repository. Their role is not nominal:

- Every change is **reviewed** by the maintainer before it is merged.
- Every release is **built and tested** before it is published: CI installs
  the chart on real clusters ([Testing](#testing)), and a release is published
  only from `main`, which changes through pull requests the maintainer merges. The AI
  assistant does not have a path to publish — it produces changes, the
  maintainer decides whether they ship.
- **Design decisions are ratified by the maintainer.** Where this documentation
  says "the chart does X," a human chose X.

**What this means for a reviewer.** AI-generated code can contain subtle errors
that read as plausible. The mitigation this project relies on is human review
by an accountable maintainer, plus checks that fail rather than warn: the chart
refuses to render an override that would weaken the
[security posture](security-model.md#nothing-runs-as-root), and CI asserts the
posture, the credential handling and the upgrade path on every change. It is not
a claim of perfection. A reviewer who would independently audit any third-party
chart before deploying it in a sensitive environment should do so here too; the
provenance does not change that obligation, it just makes it explicit.

## What the package contains

A Helm chart is configuration, not code: `Chart.yaml`, `values.yaml`,
`values.schema.json`, `templates/`, the examples, the README and the license.
There is no binary and no dependency chart. `.helmignore` keeps the CI inputs
(`ci/`, `.github/`), the developer tooling (`hack/`) and this `docs/` directory
out of the package.

What the chart runs is the images below. It pins them; it does not build them.

## Images

Every image is pinned by digest in `values.yaml`, and the digest takes
precedence over the tag:

| Image | Used for | Present when |
| --- | --- | --- |
| `docker.io/searxng/searxng` | SearXNG | always |
| `cgr.dev/chainguard/valkey` | Valkey primary and replicas | `valkey.enabled` |
| `docker.io/oliver006/redis_exporter` | Valkey metrics sidecar | `valkey.metrics.enabled` |
| `ghcr.io/littleoffice/mcp-searxng-relay` | MCP relay instances | `mcpRelay.enabled` |
| `cgr.dev/chainguard/curl` | `helm test` pod | `tests.enabled` |

A chart version is therefore a claim about five specific image digests.
`appVersion` names the SearXNG version behind the pinned digest, and CI fails
when the two disagree.

**How the pins move.** A self-hosted Renovate run watches each image's `latest`
tag. When any of them resolves to a new digest it opens one grouped pull request
rewriting every changed digest, and a post-upgrade task raises the chart's patch
version and refreshes `appVersion`. CI then runs on it like any other change,
and merging it publishes a new patch release. A newer upstream image never
reaches you without a chart release, or your own `digest` override.

**How the pins are scanned.** CI scans every pinned digest with Trivy on each
pull request, on `main`, and daily. It fails only when a newer digest of the
same image would drop a CVE — that is, when a bump would fix it. A CVE present
in the newest upstream image too is reported but does not fail the build:
nothing in this repository can fix it, and failing on it would train people to
ignore the job. The reasoning is in
[`scan-images.sh`](../.github/ci/scan-images.sh).

The relay image has its own supply-chain statement:
[mcp-searxng-relay](https://github.com/littleoffice/mcp-searxng-relay/blob/main/docs/supply-chain.md).

## Build provenance

Releases are cut by [`release.yaml`](../.github/workflows/release.yaml) on a
push to `main` that changes packaged content. It is a no-op when `Chart.yaml`'s
version already has a tag, so a version is published once, and CI refuses a
pull request that changes packaged content without raising the version. Every
action in the workflows is pinned by commit SHA. The release job:

1. Packages the chart with `helm package`, writing an `artifacthub.io/changes`
   changelog generated from the conventional-commit subjects since the last
   tag into the packaged `Chart.yaml` only.
2. Pushes it to `ghcr.io/littleoffice/charts/searxng` as an OCI artifact. This
   is the distribution Artifact Hub tracks.
3. Attests build provenance for both the OCI artifact (pushed to the registry
   beside it) and the `.tgz`.
4. Signs the OCI artifact with cosign, keyless: the certificate is bound to the
   release workflow's OIDC identity and expires in minutes, so there is no
   private key held anywhere and no public key to distribute. The workflow
   verifies the signature before it continues.
5. Creates a GitHub Release under the bare version tag, carrying the `.tgz`.

A second job then records what was shipped: it scans every pinned image with
Trivy, generates a CycloneDX SBOM per image, and attaches the scan report, the
machine-readable pin list (`searxng-<version>-images.json`) and the SBOM bundle
to the same GitHub Release, with a provenance attestation of its own. That job
never fails the release — the gate already ran on the commit being released —
so the report is a record of the images' state at release time, not a second
gate.

## Verification

The identity is the thing you check, not a fingerprint:

```console
cosign verify ghcr.io/littleoffice/charts/searxng:1.0.0 \
  --certificate-identity-regexp '^https://github.com/littleoffice/searxng-helm/\.github/workflows/release\.yaml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Build provenance, for the OCI artifact and for the `.tgz` attached to the
GitHub Release:

```console
gh attestation verify oci://ghcr.io/littleoffice/charts/searxng:1.0.0 \
  --repo littleoffice/searxng-helm
gh attestation verify searxng-1.0.0.tgz --repo littleoffice/searxng-helm
```

Note that `helm install` does not check either of these. Neither does the
`--verify` flag, which looks for a PGP-signed `.prov` file that this chart
does not ship. Run the checks above as a separate step, or enforce them in
an admission controller.

## Testing

Every pull request runs [`ci.yaml`](../.github/workflows/ci.yaml): lint under
Helm 3 and Helm 4, a render of every scenario against each supported Kubernetes
version through `kubeconform -strict`, render-time assertions (no init
containers, no generated credential in an argv or a plain env value, settings.yml
only from a Secret), kube-linter against the
[security posture](security-model.md#security-posture), the image scan, and
installs of six scenarios on real clusters that are then upgraded in place and
required to keep every Secret byte-identical. The last published release is
also installed and upgraded to the change, so an upgrade that would re-mint
credentials fails. What each job proves:
[`.github/ci/README.md`](../.github/ci/README.md#jobs).

## Known gaps

- **Single-maintainer project.** See [Development process](#development-process)
  and [SECURITY.md](SECURITY.md). There is no committed response time for
  security reports.
- **No independent review.** The chart has not been externally audited.
- **The images are third-party.** The chart pins and scans them; it does not
  build them, and a CVE in the newest upstream image stays until upstream ships
  a fix.
- **No `.prov` file.** `helm install --verify` cannot be used; verification is
  the separate cosign and attestation step above.
- **No reproducible package build.** The `.tgz` is attested, but nothing asserts
  that rebuilding the same commit produces the same bytes.

If any of these gaps is a blocker for your environment, that is worth raising
before adoption rather than after.
