# Configuration

SearXNG's own configuration is a settings.yml you keep in a Secret; everything
about how the chart deploys it is in `values.yaml`. This page covers both. The
MCP relay has a page of its own: [MCP relay](mcp-relay.md).

## Contents

- [settings.yml](#settingsyml)
  - [Why it is not in values](#why-it-is-not-in-values)
  - [What the chart cannot do for you](#what-the-chart-cannot-do-for-you)
  - [Pods do not roll when you edit it](#pods-do-not-roll-when-you-edit-it)
- [Custom / additional search providers](#custom--additional-search-providers)
- [The limiter](#the-limiter)
- [Valkey](#valkey)
- [Ingress annotations](#ingress-annotations)
- [Open WebUI](#open-webui)
- [Values](#values)

## settings.yml

**settings.yml comes from a Secret you manage, and from nowhere else.** The
chart does not render that file, does not ship a default for it, and refuses to
render without one:

```console
kubectl -n <ns> create secret generic searxng-settings \
  --from-file=settings.yml=./settings.yml
```

```yaml
searxng:
  existingSettingsSecret: searxng-settings
  existingSettingsSecretKey: settings.yml   # projected to /etc/searxng/settings.yml
```

The key is projected to the fixed mount path, so it can be named anything —
useful when the Secret comes from External Secrets or SealedSecrets and the key
name is not yours to pick. There is a worked example in
[`examples/settings.example.yml`](../examples/settings.example.yml).

Anything from the [settings reference](https://docs.searxng.org/admin/settings/)
is valid in that file. Start it with `use_default_settings: true` unless you are
writing a complete configuration — SearXNG reads the file as a whole one
otherwise, and fails on whatever is missing.

### Why it is not in values

Several things that are unambiguously credentials can only live in that file.
SearXNG resolves environment variables for a fixed allowlist of settings —
`SEARXNG_SECRET`, `SEARXNG_VALKEY_URL`, `SEARXNG_BASE_URL`, `SEARXNG_PORT`,
`SEARXNG_BIND_ADDRESS`, `SEARXNG_LIMITER`, `SEARXNG_PUBLIC_INSTANCE`,
`SEARXNG_IMAGE_PROXY`, `SEARXNG_METHOD`, `SEARXNG_DEBUG` — and none of these are
on it:

| In settings.yml | What it is |
| --- | --- |
| `engines[].tokens` | Token list gating a [private engine](https://docs.searxng.org/admin/engines/settings.html) |
| `engines[].api_key`, `.password`, `.token` | Per-engine upstream credentials |
| `outgoing.proxies` | Can carry inline `user:pass@` credentials |
| `general.open_metrics` | HTTP Basic password for `/metrics` |

Rendering the file from values would put all of that in a values file, a
rendered manifest and a Helm release history. Keeping the file in a Secret you
own keeps it out of the chart's reach entirely — including the chart's own
`helm template` output.

`searxng.extraConfigFiles` is still a ConfigMap. Do not put credentials in it.

### What the chart cannot do for you

It never reads the file, so anything that used to be injected into it is yours
to write:

| In your settings.yml | When |
| --- | --- |
| `use_default_settings: true` | unless the file is a complete configuration |
| `search.formats` containing `json` | `mcpRelay.enabled` — the relay cannot read results otherwise |
| `general.enable_metrics: true` and `general.open_metrics: <password>` | `searxng.metrics.enabled`, with the same password in the Secret named by `searxng.metrics.existingSecret` |

The render is refused if `searxng.metrics.enabled` is on without
`searxng.metrics.existingSecret`, rather than sending the ServiceMonitor a
credential that matches nothing.

Three settings drive objects *outside* the file — the container port, the
probes, the NetworkPolicy, `limiter.toml` and whether Valkey is required — so
they are mirrored as values in their own right. Keep them in step with your
file:

| In settings.yml | In values |
| --- | --- |
| `server.port` | `searxng.port` |
| `server.limiter` | `searxng.limiter.enabled` |
| `server.public_instance` | `searxng.limiter.publicInstance` |

`secret_key` and the Valkey URL are unaffected: they arrive as
`$SEARXNG_SECRET` and `$SEARXNG_VALKEY_URL` from their own Secrets and override
whatever the file says.

### Pods do not roll when you edit it

The chart cannot hash a file it does not render, so there is no `checksum` for
settings.yml on the Deployment. After editing the Secret:

```console
kubectl -n <ns> rollout restart deployment/<release>-searxng
```

or annotate the Deployment for a reloader.

Coming from a 1.x release, where the file was rendered from
`searxng.settings`: [Moving settings.yml out of values](upgrading.md#moving-settingsyml-out-of-values).

## Custom / additional search providers

In your settings.yml, with `use_default_settings: true`, `engines` entries are
merged into the built-in list **by `name`** — so you can flip a built-in on or
add your own:

```yaml
engines:
  - name: wikipedia
    disabled: false
  - name: my gitea
    engine: gitea
    base_url: https://git.example.com
    shortcut: gt
    categories: [it, repos]
    timeout: 5.0
```

A private engine's `tokens:` list belongs here too — which is the main reason
this file is a Secret and not values. Giving each relay instance only its own
engines: [Scoping a relay to specific engines](mcp-relay.md#scoping-a-relay-to-specific-engines).

Other config files (`favicons.toml`, …) go in `searxng.extraConfigFiles`, a
filename → content map mounted alongside `settings.yml`. That one is a
ConfigMap: no credentials in it.

## The limiter

Off by default. It is set in two places: `server.limiter` in your settings.yml,
which is what SearXNG reads, and `searxng.limiter.enabled` in values, which is
what tells the chart to render and mount `limiter.toml`. The chart cannot read
your file, so it has to be told. Enabling it requires Valkey, and the chart
refuses to render without one:

```yaml
searxng:
  limiter:
    enabled: true      # and server.limiter: true in your settings.yml
```

The trap here is `trusted_proxies`. The limiter takes the client IP from
`X-Forwarded-For` only when the immediate peer is trusted; behind an ingress
controller that peer is a pod IP. If your controller's network isn't in
`searxng.limiter.trustedProxies`, every request is attributed to one client and
the instance rate-limits itself into the ground. The default covers all of
RFC1918 to make it work out of the box — narrow it to your controller's CIDR if
you can, since anything in that range can then spoof client IPs.

## Valkey

Runs as `999:1000` (the image puts `valkey` in gid 1000 because alpine already
occupies 999). Ephemeral by default (`save ""`); set
`valkey.persistence.enabled` for PVCs.

Two topologies:

```yaml
valkey:
  architecture: replication   # or: standalone
  replica:
    count: 2
```

`replication` gives you a primary StatefulSet plus a replica StatefulSet whose
config carries `replicaof <primary> 6379` — no init container and no per-pod
role election, because the role is baked into which config file each
StatefulSet mounts. Replicas get soft anti-affinity against the primary and
each other, and their own PDB.

**What replication does not give you is failover.** SearXNG connects with
`valkey.Valkey.from_url()` against a single URL and has no Sentinel support, so
it always writes to the primary and will not move on its own if that primary
dies. What you get is a warm, consistent copy you can promote by hand:

```console
kubectl exec <release>-searxng-valkey-replica-0 -c valkey -- valkey-cli replicaof no one
```

For genuine HA, put a failover-aware proxy in front and use
`valkey.enabled: false` with `valkey.external.*`. The chart is explicit about
this rather than implying a resilience it can't deliver.

Replication requires auth — replicas authenticate to the primary with
`masterauth` — so the chart refuses to render with
`architecture: replication` and `auth.enabled: false`.

To use one you already run:

```yaml
valkey:
  enabled: false
  external:
    existingSecret: my-valkey   # key: valkey-url
```

Note that the generated egress policy won't cover it — add a rule under
`networkPolicy.egress.extra`.

## Ingress annotations

Both ingress blocks (`ingress.annotations` and an instance's
`ingress.annotations`) pass through verbatim, so cert-manager,
controller-specific and any other annotations work as normal:

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-read-timeout: 300   # unquoted is fine
  hosts:
    - host: search.example.com
      paths: [{ path: /, pathType: Prefix }]
  tls:
    - secretName: searxng-tls
      hosts: [search.example.com]
```

cert-manager needs both halves: the issuer annotation *and* a `tls` entry whose
`secretName` is where it should write the certificate. Values are coerced to
strings on render, so an unquoted `300` or `true` won't be rejected by the API
server the way a raw `toYaml` would leave it.

`commonAnnotations` is merged in underneath; per-ingress keys win on conflict.

`ingress.className` is empty by default, meaning "use the cluster's default
IngressClass". Set it if you run more than one controller — and remember the
controller also needs to be let through the NetworkPolicy
([Before you install](installation.md#before-you-install)).

## Open WebUI

In your settings.yml:

```yaml
search:
  formats: [html, json]
```

and in values:

```yaml
networkPolicy:
  ingress:
    allowSameNamespace: true
```

Then point Open WebUI at `http://searxng.<namespace>.svc:8080/search?q=<query>`.

## Values

See [`values.yaml`](../values.yaml) — every key is commented inline, including the
reasoning behind non-obvious defaults.

Notable ones:

| Key | Default | Notes |
| --- | --- | --- |
| `replicaCount` | `2` | PDB `maxUnavailable: 1`, surge-first rollout |
| `autoscaling.enabled` | `false` | HPA v2, CPU + optional memory |
| `resources.limits.cpu` | unset | deliberate — throttling a search aggregator hurts latency |
| `networkPolicy.enabled` | `true` | needs a CNI that enforces them |
| `networkPolicy.defaultDeny.enabled` | `false` | namespace-wide, affects other releases |
| `searxng.existingSettingsSecret` | `""` | **required** — the Secret holding settings.yml |
| `searxng.port` | `8080` | mirrors `server.port` in that file |
| `searxng.limiter.enabled` | `false` | mirrors `server.limiter`; requires Valkey |
| `searxng.bindAddress` | `"::"` | set `0.0.0.0` on IPv4-only pod networks |
| `image.digest` | pinned | takes precedence over `image.tag`, which falls back to `appVersion` |

The [examples](../examples/README.md) are complete values files for the common
shapes: minimal, production, multi-tenant.
