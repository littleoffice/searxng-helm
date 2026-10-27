# Architecture

What the chart deploys, how traffic is allowed to move between the parts, and
how SearXNG is made to start on a read-only root filesystem without an init
container.

## Contents

- [Components](#components)
- [Network policies](#network-policies)
- [Starting SearXNG without an init container](#starting-searxng-without-an-init-container)

## Components

| Component | Kind | Present when |
| --- | --- | --- |
| SearXNG | Deployment, Service, ServiceAccount, PDB; optional HPA and Ingress | always |
| Valkey primary | StatefulSet, headless Service | `valkey.enabled` (the default) |
| Valkey replicas | StatefulSet, headless Service, PDB | `valkey.architecture: replication` |
| `redis_exporter` | sidecar next to each Valkey pod | `valkey.metrics.enabled` |
| MCP relay | per entry in `mcpRelay.instances`: Deployment, Service, ServiceAccount, NetworkPolicy, and a token Secret unless you bring your own; optional Ingress and PDB | `mcpRelay.enabled` |
| ServiceMonitors | one per component whose metrics are on | `metrics.serviceMonitor.enabled` |
| Test pod | Pod run by `helm test` | `tests.enabled` (the default) |

settings.yml is not on the list: it is a Secret you create, and the chart only
mounts it ([settings.yml](configuration.md#settingsyml)). The chart does render
a Secret for each credential it generates, and a ConfigMap for each of
`limiter.toml` (when the limiter is on), `searxng.extraConfigFiles` and
`mcpRelay.config` (when they are set).

How Valkey's two topologies are wired: [Valkey](configuration.md#valkey). How
relay instances relate to each other and to SearXNG:
[MCP relay](mcp-relay.md).

## Network policies

`networkPolicy.enabled` is on by default and renders one NetworkPolicy per
workload, each listing both `Ingress` and `Egress`, so anything not matched by
a rule below is denied. They need a CNI that enforces NetworkPolicy; on one that
does not (stock Flannel) they render and do nothing.

| Workload | May be reached by | May connect to |
| --- | --- | --- |
| SearXNG `:8080` | pods in the release namespace (`networkPolicy.ingress.allowSameNamespace`, on by default); namespaces in `fromNamespaces`; peers in `from`; each relay instance when same-namespace access is off; Prometheus from `metrics.allowScrapeFromNamespaces` when its metrics are on | DNS; the Valkey primary on `6379`; `0.0.0.0/0` on `80`/`443` except `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16` and `100.64.0.0/10`; anything under `networkPolicy.egress.extra` |
| Valkey primary `:6379` | SearXNG; the replicas; Prometheus on the exporter port | nothing — replies ride on established connections |
| Valkey replicas `:6379` | SearXNG, as read-only consumers; Prometheus on the exporter port | DNS; the primary, for replication |
| Relay instance | the instance's own `networkPolicy.ingress` allow-list, same shape as SearXNG's; Prometheus when its metrics are on | DNS; SearXNG; the same internet-minus-private-ranges rule as SearXNG, unless `networkPolicy.egress.internet.enabled: false`; anything under its `networkPolicy.egress.extra` |

Three things worth knowing:

- **An empty allow-list denies.** With `allowSameNamespace: false` and no
  `fromNamespaces` or `from` entries, the chart renders no ingress rule at all,
  so nothing reaches SearXNG. Before 2.0.0 it rendered `from: null`, which
  Kubernetes reads as *admit every source*
  ([behaviour change](upgrading.md#one-behaviour-change-that-is-not-a-rename)).
- **The private-range exclusion is deliberate.** A compromised SearXNG or relay
  pod cannot pivot into the cluster, the VPC or a cloud metadata endpoint. An
  external Valkey, a fetch proxy on a private address, or an internal host the
  relay is allowed to read each needs its own rule under `egress.extra`
  ([Reaching internal URLs](mcp-relay.md#reaching-internal-urls)). Add `::/0`
  to `networkPolicy.egress.internet.ipv6Cidrs` on a dual-stack cluster whose
  engines resolve over IPv6.
- **`networkPolicy.defaultDeny.enabled` is namespace-wide.** It renders a
  policy selecting every pod in the namespace, not just this release's, so it
  is off by default; turn it on only if you own the whole namespace.

## Starting SearXNG without an init container

Most SearXNG charts use an init container because the image's entrypoint wants to
write `settings.yml`, which fails against a read-only projected mount. Reading
[`container/entrypoint.sh`](https://github.com/searxng/searxng/blob/master/container/entrypoint.sh)
shows that isn't actually necessary:

- `setup()` copies the template **only when `$CONFIG_PATH/settings.yml` does not
  exist**. Mount the file and it writes nothing.
- `setup_ownership()` chowns only when `FORCE_OWNERSHIP=true` **and** `id -u` is
  0. As a non-root user it prints a warning and carries on.

So the chart mounts `settings.yml` from a Secret, gives the container
`emptyDir`s for `/var/cache/searxng` and `/tmp`, and runs with
`readOnlyRootFilesystem: true`.

You will see this in the logs on every start. It is expected — it is the
`fsGroup` ownership on the emptyDir, not a fault:

```
!!! WARNING
!!! "/var/cache/searxng" directory is not owned by "searxng:searxng"
```

Valkey replication avoids one the same way: the replica role is baked into
which config file each StatefulSet mounts, so there is no per-pod role election
([Valkey](configuration.md#valkey)).
