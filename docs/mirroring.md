# Running from your own registry

How to install the chart and its images from a registry you run, such as Harbor,
Artifactory, Nexus or a cloud registry, so that no node and no GitOps
controller pulls from `ghcr.io`, `docker.io` or `cgr.dev` at deploy time.

## Contents

- [Why mirror](#why-mirror)
- [What to mirror](#what-to-mirror)
- [1. Pull and verify the chart](#1-pull-and-verify-the-chart)
- [2. Copy the images by digest](#2-copy-the-images-by-digest)
- [3. Push the chart](#3-push-the-chart)
- [4. Install from the mirror](#4-install-from-the-mirror)
- [GitOps](#gitops)
- [Upgrading](#upgrading)
- [Limitations](#limitations)

## Why mirror

SearXNG queries the public internet, so this is not about air-gapping the
workload. Mirroring takes the public registries out of the deploy path:

- **You decide what enters the cluster.** The signature check happens once,
  when a version is admitted into the mirror, instead of being trusted on every
  pull.
- **Deploys no longer depend on someone else's uptime and rate limits.** A
  controller that resolves the chart every minute, or a node that pulls on
  every restart, does it against your registry.
- **The pins still hold.** Images are pinned by digest, and a digest names
  content. A copy under the same digest is the same bytes, so nothing the chart
  promises is lost in the move.

The trust chain is short: the chart's provenance is verified, the chart pins
each image by digest, and the kubelet refuses any image whose content does not
match that digest. Verify the chart and you have verified everything it runs.

## What to mirror

The chart, and the images for the components you enable:

| Values path | Upstream | Needed when |
| --- | --- | --- |
| `image` | `docker.io/searxng/searxng` | always |
| `valkey.image` | `cgr.dev/chainguard/valkey` | `valkey.enabled` |
| `valkey.metrics.image` | `docker.io/oliver006/redis_exporter` | `valkey.metrics.enabled` |
| `mcpRelay.image` | `ghcr.io/littleoffice/mcp-searxng-relay` | `mcpRelay.enabled` |
| `tests.image` | `cgr.dev/chainguard/curl` | `tests.enabled` (`helm test`) |

Mirroring all five is simplest. Then enabling a component later doesn't
fail with `ImagePullBackOff`.

The examples below use these names. Replace them with your own:

```console
VERSION=2.1.0                         # the chart version you are admitting
MIRROR=harbor.example.com/searxng     # what global.imageRegistry will be
CHARTS=oci://harbor.example.com/charts
```

## 1. Pull and verify the chart

Pull the packaged chart once and verify that exact file, not the tag. A tag can
move between the check and the copy, but the file can't:

```console
helm pull oci://ghcr.io/littleoffice/charts/searxng --version "$VERSION"
gh attestation verify "searxng-$VERSION.tgz" --repo littleoffice/searxng-helm
```

This checks that the `.tgz` was built by this repository's release workflow.
The keyless cosign signature on the OCI artifact can be checked as well:
[Verification](supply-chain.md#verification). If verification fails, stop:
nothing from this version goes into the mirror.

## 2. Copy the images by digest

Read the pinned references out of the chart you just verified, so the digests
come from the signed artifact and not from a web page or a copy of
values.yaml:

```console
helm show values "searxng-$VERSION.tgz" > values-$VERSION.yaml
for p in image valkey.image valkey.metrics.image mcpRelay.image tests.image; do
  yq ".$p | .registry + \"/\" + .repository + \"@\" + .digest" "values-$VERSION.yaml"
done > images-$VERSION.txt
```

Then copy each image into the mirror **under its upstream repository path, by
digest**. The chart builds an image reference as
`<global.imageRegistry>/<repository>@<digest>`, so the path below `$MIRROR`
must be the upstream repository unchanged:

```console
while read -r src; do
  repo_digest="${src#*/}"            # drop the upstream registry host
  crane copy "$src" "$MIRROR/$repo_digest"
done < images-$VERSION.txt
```

`crane copy` copies the full multi-architecture index, so the digest in the
mirror is the digest the chart pins. `skopeo copy --all` and `oras cp` also
work. Use whichever your registry tooling standardises on, as long as it copies
the index and not just one platform's image.

Check the result. Every line should print the same digest it was copied with:

```console
while read -r src; do crane digest "$MIRROR/${src#*/}"; done < images-$VERSION.txt
```

## 3. Push the chart

Push the same `.tgz` you verified:

```console
helm push "searxng-$VERSION.tgz" "$CHARTS"
```

## 4. Install from the mirror

Point the chart at the mirror with one value. If the mirror needs credentials,
create a pull Secret and list it in `imagePullSecrets`. It reaches every pod the
chart creates, the `helm test` pod included:

```console
kubectl -n search create secret docker-registry mirror-pull \
  --docker-server=harbor.example.com --docker-username=… --docker-password=…

helm install searxng "$CHARTS/searxng" -n search --version "$VERSION" \
  --set searxng.existingSettingsSecret=searxng-settings \
  --set global.imageRegistry="$MIRROR" \
  --set 'imagePullSecrets[0].name=mirror-pull'
```

Or in a values file:

```yaml
global:
  imageRegistry: harbor.example.com/searxng
imagePullSecrets:
  - name: mirror-pull
```

Confirm nothing still points upstream before you deploy:

```console
helm template searxng "$CHARTS/searxng" --version "$VERSION" -f values.yaml \
  | grep 'image:'
```

`global.imageRegistry` replaces every image's registry, the per-image
`registry` keys included. It takes a host, an optional port and an optional
path, with no scheme and no trailing slash. The schema rejects anything else
at render time.

## GitOps

Point the controller at the mirror, not at `ghcr.io`:

- **Flux:** a `HelmRepository` with `type: oci` and
  `url: oci://harbor.example.com/charts`, with `secretRef` set to the mirror's
  credentials if needed, and a `HelmRelease` that pins `version` and sets the
  values above.
- **Argo CD:** an OCI Helm repository for `harbor.example.com/charts`
  (`enableOCI: true`), with an Application that pins `targetRevision` and sets
  the values above.

Pin an exact chart version. A version range makes the controller resolve the
chart on every reconcile, and a short interval multiplies that. With a mirror,
that load lands on your registry, but a pinned version doesn't need it at all.

## Upgrading

Every chart release can move image digests. Renovate bumps them in patch
releases, see [Images](supply-chain.md#images). So admitting a new version is
the same four steps again: pull, verify, copy what `images-$VERSION.txt` lists,
push. Copying an image that is already in the mirror is a no-op, so rerunning
the loop for every release is safe.

Keep the old digests in the mirror until nothing deployed references them.
Rolling back to a chart version whose images were garbage-collected fails at
pull time.

## Limitations

- **One registry for every image.** `global.imageRegistry` assumes a mirror
  that serves all five images under their upstream paths. A setup with
  separate per-upstream proxy caches, for example one Harbor proxy project for
  `docker.io` and another for `cgr.dev`, doesn't fit that shape. Leave
  `global.imageRegistry` empty and set each image's own `registry` key
  instead.
- **Repository paths can't be renamed.** The mirror must keep each upstream
  repository path. If yours flattens or renames paths, override each image's
  `registry` and `repository` instead.
- **A digest override is your own pin.** If you set an image's `digest` to
  something other than the chart's value, mirror that digest. It isn't covered
  by the chart's provenance.
