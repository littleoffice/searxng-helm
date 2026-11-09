# Running from your own registry

What a mirror of this chart has to provide, and the one value that points the
chart at it. How you fill the mirror (replication rules, a proxy cache,
`crane`, `skopeo`) is up to you.

## The contract

Set `global.imageRegistry` and every image resolves to:

```
<global.imageRegistry>/<upstream repository>@<digest>
```

- **Paths are kept.** The mirror must serve each image under its upstream
  repository path. With `harbor.example.com/searxng`, SearXNG becomes
  `harbor.example.com/searxng/searxng/searxng@sha256:…`.
- **Digests are kept.** Copy the multi-architecture index, not one platform's
  image, or the pinned digest won't exist in the mirror.
- **It overrides the per-image `registry` keys.** `values.yaml` fills those in,
  so an explicit setting can't be told apart from the default.
- **Format.** Host, optional port, optional path. No scheme, no trailing slash.
  The schema rejects anything else at render time.
- **Credentials.** `imagePullSecrets` reaches every pod the chart creates, the
  `helm test` pod included.

## The images

| Values path | Upstream | Needed when |
| --- | --- | --- |
| `image` | `docker.io/searxng/searxng` | always |
| `valkey.image` | `cgr.dev/chainguard/valkey` | `valkey.enabled` |
| `valkey.metrics.image` | `docker.io/oliver006/redis_exporter` | `valkey.metrics.enabled` |
| `mcpRelay.image` | `ghcr.io/littleoffice/mcp-searxng-relay` | `mcpRelay.enabled` |
| `tests.image` | `cgr.dev/chainguard/curl` | `tests.enabled` |

Digests move with every chart release (Renovate bumps them in patch releases),
so admit images per chart version. Read the pins from the chart file you
verified, not from a copy of values.yaml:

```console
helm pull oci://ghcr.io/littleoffice/charts/searxng --version "$VERSION"
gh attestation verify "searxng-$VERSION.tgz" --repo littleoffice/searxng-helm
helm show values "searxng-$VERSION.tgz" > values.yaml
for p in image valkey.image valkey.metrics.image mcpRelay.image tests.image; do
  yq ".$p | .registry + \"/\" + .repository + \"@\" + .digest" values.yaml
done
```

Push that same `.tgz` to your chart registry. Verifying the chart is enough:
it pins each image by digest, and the kubelet refuses content that doesn't
match. More on the signatures: [Verification](supply-chain.md#verification).

## When the global value doesn't fit

- **Separate proxy caches per upstream**, such as one Harbor proxy project for
  `docker.io` and another for `cgr.dev`. One prefix can't front them all. Leave
  `global.imageRegistry` empty and set each image's `registry`.
- **A mirror that renames or flattens paths.** Set each image's `registry` and
  `repository`.
- **A `digest` you override yourself.** Mirror that digest. The chart's
  provenance doesn't cover it.
