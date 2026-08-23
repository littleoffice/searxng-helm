[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/littleoffice-searxng)](https://artifacthub.io/packages/search?repo=littleoffice-searxng)


# SearXNG — hardened Helm chart

A production-oriented chart for [SearXNG](https://docs.searxng.org) built around
four constraints:

- **No init containers.** Anywhere.
- **Rootless**, with a read-only root filesystem and all capabilities dropped.
- **Secrets stay secrets** — settings.yml is a Secret you own, never rendered
  from values and never a ConfigMap; no credential is ever passed in an argv.
- **NetworkPolicies** that deny by default in both directions.

Owes its shape to [kubitodev/searxng](https://github.com/kubitodev/helm), which
is the only actively maintained SearXNG chart at time of writing (the official
`searxng/searxng-helm-chart` was archived in May 2025).

## Examples

Ready-to-use manifests and values live in [`examples/`](examples/):

```console
examples/gen-secrets.sh <release> <namespace> [standalone|replication] > secrets.yaml
kubectl -n <namespace> apply -f secrets.yaml
helm install <release> ./searxng -n <namespace> -f examples/values-production.yaml
```

| File | What it is |
| --- | --- |
| `gen-secrets.sh` | Generates every Secret with real random credentials, to stdout (pipe into `kubeseal` / `sops`). |
| `secrets.example.yaml` | The same Secrets as annotated placeholders. |
| `values-minimal.yaml` | Smallest working install. |
| `settings.example.yml` | A worked settings.yml, for the Secret the chart mounts. |
| `values-config.yaml` | limiter.toml, extra files, and how to point at that Secret. |
| `values-production.yaml` | Everything on, all credentials external, GitOps-safe. |
| `values-multi-tenant.yaml` | Two teams, one SearXNG, a relay instance each. |
| `relay-config.example.yaml` | A worked relay ConfigMap for one instance. |

## Install

```console
kubectl -n search create secret generic searxng-settings \
  --from-file=settings.yml=examples/settings.example.yml

helm install searxng ./searxng -n search --create-namespace \
  --set searxng.existingSettingsSecret=searxng-settings
```

settings.yml is not optional and the chart has no default for it — see
[settings.yml](#settingsyml). The namespace is whatever you pass to `-n` —
nothing in the chart assumes one.

Before anything else, look at two values:

| Value | Why |
| --- | --- |
| `networkPolicy.ingress.fromNamespaces` | Empty by default. The chart makes no guess about which ingress controller you run or where it lives; if you enable the Ingress without setting this, the controller is blocked and requests time out. |
| `image.tag` | Defaults to `latest`. Pin it. |

Find your controller's namespace:

```console
kubectl get pods -A -l app.kubernetes.io/component=controller
```

Then:

```yaml
networkPolicy:
  ingress:
    fromNamespaces: [ingress-nginx]   # or traefik, istio-system, kube-system, ...
```

`ingress.className` is likewise empty by default, meaning "use the cluster's
default IngressClass". Set it if you run more than one controller.

## Verifying the chart

Every published version is signed keyless with cosign: the certificate is
bound to the release workflow's OIDC identity and expires in minutes, so
there is no private key held anywhere and no public key to distribute. The
identity is the thing you check, not a fingerprint.

```console
cosign verify ghcr.io/littleoffice/charts/searxng:1.0.0 \
  --certificate-identity-regexp '^https://github.com/littleoffice/searxng-helm/\.github/workflows/release\.yaml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Build provenance is attested as well, for both the OCI artifact and the
`.tgz` attached to the GitHub Release:

```console
gh attestation verify oci://ghcr.io/littleoffice/charts/searxng:1.0.0 \
  --repo littleoffice/searxng-helm
```

Note that `helm install` does not check either of these. Neither does the
`--verify` flag, which looks for a PGP-signed `.prov` file that this chart
does not ship. Run the checks above as a separate step, or enforce them in
an admission controller.

## How the "no init container" requirement is met

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

## Security posture

| Control | Setting |
| --- | --- |
| User | `977:977` — the `searxng` user in the official image |
| Root filesystem | read-only; writable scratch via sized `emptyDir`s |
| Capabilities | `drop: [ALL]`, `allowPrivilegeEscalation: false` |
| Seccomp | `RuntimeDefault` on pod and container |
| API access | ServiceAccount token not mounted; `enableServiceLinks: false` |
| Ingress | deny by default, allow-list via `networkPolicy.ingress.from` |
| Egress | DNS + Valkey + internet-minus-RFC1918 only |
| Secrets | `secret_key` and Valkey password in `Secret`s, injected as env |
| Enforcement | every row above is asserted at render time — see below |

### Nothing runs as root

Every workload sets `runAsNonRoot: true` with an explicit non-zero
`runAsUser` / `runAsGroup` / `fsGroup`: SearXNG `977`, Valkey `999:1000`, the
MCP relay `1001`. The chart also **refuses to render** if a values override
would set any of those to `0`, adds `0` to `supplementalGroups`, or flips
`runAsNonRoot` off — so a bad override fails at `helm template` rather than
being rejected by your admission controller later.

The same backstop covers the rest of the table: rendering fails on
`privileged: true`, on `allowPrivilegeEscalation: true` or unset, on
`readOnlyRootFilesystem` other than true, on a `capabilities.drop` that does
not contain `ALL` or any `capabilities.add`, and on a `seccompProfile.type`
that is neither `RuntimeDefault` nor `Localhost` on the pod or the container.
Root was worth checking first because it is the control people override
deliberately; these are the ones that go missing by accident, when a
`securityContext` block is copied from elsewhere or rewritten to add one field
and drops the others.

One thing to be clear about, because it looks like root and isn't: files inside
`ConfigMap`, `Secret` and `emptyDir` mounts are written by the kubelet onto a
tmpfs it owns, and it writes them as `uid 0` with the group set to your
`fsGroup`. `ls -l` inside the container shows `root:977`. That is *file
ownership on a kubelet-managed filesystem*, not a process identity — no
container in this chart ever has a root process, and no admission controller
(PSA restricted, Kyverno, Gatekeeper) inspects file ownership, because it isn't
part of the pod spec they validate.

Kubernetes offers no way to change that ownership without an init container
doing a `chown`, which this chart deliberately does not have. If you want it
gone anyway, user namespaces are the mechanism:

```yaml
userNamespaces:
  enabled: true    # sets hostUsers: false on all three workloads
```

In-pod root then maps to an unprivileged uid on the node, so the files are no
longer host-root-owned. This needs the `UserNamespacesSupport` feature gate, a
runtime with idmap mount support and a recent kernel — verify your cluster
supports it before enabling, because pods will not start if it doesn't. Off by
default for that reason.

### Where the credentials live

`secret_key` is injected as `$SEARXNG_SECRET`, which overrides
`server.secret_key` at load time, so nothing the chart renders contains it. If
your settings.yml sets `server.secret_key` as well, the env var wins — but keep
it out of there anyway: a second copy is a second thing to rotate.

The Valkey password is assembled inside the pod using Kubernetes' `$(VAR)`
expansion:

```yaml
- name: VALKEY_PASSWORD
  valueFrom: { secretKeyRef: { name: …, key: valkey-password } }
- name: SEARXNG_VALKEY_URL
  value: "valkey://:$(VALKEY_PASSWORD)@…:6379/0"
```

Valkey itself reads its password from a Secret-mounted `valkey.conf` rather than
`--requirepass`, so it never appears in `ps`. Probes authenticate through
`VALKEYCLI_AUTH`.

### No credential is ever a values field

There is no key anywhere in `values.yaml` that takes secret material. Every
credential either comes from a Secret you name, or is generated by the chart
straight into a Secret — never through a values file, a rendered manifest or a
release history:

| Credential | Where it comes from |
| --- | --- |
| settings.yml (engine `tokens`, `api_key`, proxy credentials) | `searxng.existingSettingsSecret` |
| `/metrics` basic-auth pair | `searxng.metrics.existingSecret` |
| `secret_key` | generated, or `searxng.existingSecret` |
| Valkey password | generated, or `valkey.auth.existingSecret` |
| External Valkey URL (carries a password) | `valkey.external.existingSecret` |
| Relay bearer tokens | generated per instance, or `instances[].auth.existingSecret` |
| Relay scrape credential | generated per instance, or `instances[].metrics.existingSecret` |
| SearXNG private-engine tokens | `instances[].searxngTokens.existingSecret` |
| Relay fence signing key | `instances[].fenceKey.existingSecret` |
| Relay `/health` token | `instances[].healthToken.existingSecret` |

The schema rejects the old inline fields rather than ignoring them, so a 1.x
values file naming one fails the render instead of quietly dropping a
credential you thought was set. `hack/test-credential-consistency.sh` asserts
that, key by key.

### GitOps caveat

The chart generates `secret_key` and keeps it stable across upgrades with a
cluster `lookup`. Argo CD and Flux render via `helm template`, where `lookup`
returns nothing — the key would be regenerated on every sync and log every user
out. **Use `searxng.existingSecret` under GitOps**, and the matching
`existingSecret` for every other generated credential.

```console
kubectl -n search create secret generic searxng-secret \
  --from-literal=secret-key="$(openssl rand -hex 32)"
```

```yaml
searxng:
  existingSecret: searxng-secret
```

## Configuration

### settings.yml

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
[`examples/settings.example.yml`](examples/settings.example.yml).

Anything from the [settings reference](https://docs.searxng.org/admin/settings/)
is valid in that file. Start it with `use_default_settings: true` unless you are
writing a complete configuration — SearXNG reads the file as a whole one
otherwise, and fails on whatever is missing.

#### Why it is not in values

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

#### What the chart cannot do for you

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

#### Pods do not roll when you edit it

The chart cannot hash a file it does not render, so there is no `checksum` for
settings.yml on the Deployment. After editing the Secret:

```console
kubectl -n <ns> rollout restart deployment/<release>-searxng
```

or annotate the Deployment for a reloader.

#### Upgrading from 1.x

`searxng.settings` was removed in 2.0.0. Move its contents into the Secret and
translate the three mirrored keys above; the render fails with those
instructions if the old scope is still present.

```console
helm get values <release> -n <ns> -o yaml \
  | yq '.searxng.settings' > settings.yml
kubectl -n <ns> create secret generic searxng-settings --from-file=settings.yml
```

Then set `searxng.existingSettingsSecret` and drop `searxng.settings`. The
chart-owned `<release>-searxng-settings` Secret is removed by the upgrade; the
`secret_key` and Valkey Secrets are untouched.

### Custom / additional search providers

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
this file is a Secret and not values.

Other config files (`favicons.toml`, …) go in `searxng.extraConfigFiles`, a
filename → content map mounted alongside `settings.yml`. That one is a
ConfigMap: no credentials in it.

### The limiter

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

### Valkey

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

### Open WebUI

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

See [`values.yaml`](values.yaml) — every key is commented inline, including the
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

## Validating changes

```console
helm lint ./searxng
helm template searxng ./searxng --set networkPolicy.enabled=true | kubeconform -strict -
```

## MCP relay

Optional integration with
[littleoffice/mcp-searxng-relay](https://github.com/littleoffice/mcp-searxng-relay)
— an MCP server that exposes this SearXNG to Claude Desktop and other agents
over Streamable HTTP, with bearer auth, per-identity audit logging and
SSRF-protected URL fetching.

```yaml
mcpRelay:
  enabled: true
  instances:
    - name: default
      existingConfigMap: relay-config
      auth:
        identities:
          - name: claude-desktop
          - name: agent-ci
```

Two words that are easy to confuse, and this chart uses both:

- an **instance** is one relay Deployment, with its own tokens, engine scope,
  config and ingress;
- an **identity** is one caller of an instance — a row in that instance's token
  file, used as an audit label and a rate-limit bucket.

Identities of one instance share that instance's engine scope, so callers that
must not reach each other's engines need separate instances. Identity names are
names only: each token is generated into that instance's Secret and preserved
across upgrades, because a token in a values file is a token in git. Bring your
own with `auth.existingSecret`, whose Secret holds the `identity:token` file —
the chart then stops stamping a `checksum/auth` for it, since it cannot hash a
Secret it does not write, so `kubectl rollout restart` after editing yours.

Enabling it wires up, per instance, without you doing anything else:

- `SEARXNG_URL` pointed at this release's SearXNG Service
- a Secret holding `identity:token` lines, mounted at `/etc/mcp-auth/tokens`
  and read through `MCP_AUTH_TOKEN_FILE`
- NetworkPolicies: relay → SearXNG, relay → DNS, relay → internet (minus
  private ranges, matching the relay's own SSRF policy)

One thing it cannot do for you: `search.formats` in your settings.yml must
contain `json`, or the relay gets HTML back and fails every call. The chart does
not write that file, so it cannot add it.

### Where a relay's configuration comes from

Nothing non-secret about a relay lives in values. Each instance names a
ConfigMap you manage, whose keys become environment variables:

```console
kubectl -n <ns> create configmap relay-config \
  --from-literal=MCP_RATE_LIMIT_RPS=5 \
  --from-literal=LOG_LEVEL=info \
  --from-literal=MCP_STATELESS=true
```

Four layers, and Kubernetes decides the winner — later `envFrom` entries beat
earlier ones, explicit `env` beats every `envFrom`:

| Layer | Source | Notes |
| --- | --- | --- |
| 1 | `mcpRelay.config` | Rendered into `<release>-searxng-mcp-relay-config` and applied to every instance. Fleet-wide limits. |
| 2 | `instances[].existingConfigMap` | Yours. Overrides layer 1 for that instance. |
| 3 | chart-owned `env` | `MCP_PORT`, `SEARXNG_URL`, `MCP_AUTH_TOKEN_FILE`, `FENCE_SIGNING_KEY_FILE`, and the `secretKeyRef`s for `SEARXNG_TOKENS`, `MCP_HEALTH_TOKEN`, `MCP_METRICS_TOKEN`. Naming any of these in a ConfigMap is ignored — the container would otherwise be able to disagree with the Service, the mounted Secret, or the SearXNG it is wired to. |
| 4 | `instances[].extraEnv` | For a `valueFrom` the chart does not model. Wins over everything. |

Two consequences worth stating. The chart cannot read a ConfigMap, so it cannot
validate what is in one: a bad `LOG_LEVEL` or `FETCH_PROXY_ALL` without
`FETCH_PROXY` fails the relay's own startup rather than the render. And it
cannot hash one either, so editing it does not roll the pods —
`kubectl rollout restart deployment/<release>-searxng-mcp-relay[-<instance>]`.

`mcpRelay.config` is guarded: credential-shaped keys (`MCP_AUTH_TOKEN`,
`MCP_METRICS_TOKEN`, `SEARXNG_TOKENS`, `FENCE_SIGNING_KEY`, …) are refused,
because that map ends up in a ConfigMap and each of them has a Secret of its
own.

### Several relays, one SearXNG

Each entry in `instances` is a relay Deployment of its own — its own Service,
ServiceAccount, NetworkPolicy, token Secret and ingress — all against the one
SearXNG in the release. That is how two teams share an instance without sharing
engines:

```yaml
mcpRelay:
  enabled: true
  config:
    MAX_PDF_BYTES: "50000000"        # both instances
  defaults:
    replicaCount: 1                  # every instance, unless it says otherwise
  instances:
    - name: team-a
      existingConfigMap: relay-team-a-config
      searxngTokens:
        existingSecret: relay-team-a-engines
      auth:
        identities:
          - name: claude-desktop
          - name: ci-agent
      replicaCount: 2                # MCP_STATELESS=true in its ConfigMap
    - name: team-b
      existingConfigMap: relay-team-b-config
      searxngTokens:
        existingSecret: relay-team-b-engines
```

Each team's engine token unlocks only the engines whose `tokens:` list carries
it, and SearXNG enforces that after resolving the whole engine reference list —
categories, the `engines` parameter and `!bang` syntax alike. `searxng_read_url`
does not use engine tokens at all, so keeping one team's relay away from
another's hosts is `FETCH_ALLOWED_HOSTS` in its ConfigMap.

Names are lowercase DNS-1123 labels, because they become object names:
`team-a`, not `teamA`. The instance named `default` keeps the unsuffixed object
names (`<release>-searxng-mcp-relay`), so a single-relay release does not have
to replace its Deployment — whose selector is immutable — when it grows a
second instance.

### Relay options worth knowing

| Value | What it does |
| --- | --- |
| `instances[].fenceKey.existingSecret` | Ed25519 key the relay signs `<sec:fence>` elements with, mounted as a file. Without one each process generates its own at startup, so the fingerprint changes on every restart and differs between replicas — fine until something verifies those signatures and needs a key to pin. |
| `instances[].healthToken.existingSecret` | Bearer token gating `GET /health`, separate from the MCP tokens. Setting it switches the readiness probe to the relay's own `--healthcheck` self-probe, which reads the token from its environment — a Kubernetes `httpGet` probe can only carry a literal header. |
| `FETCH_PROXY` / `FETCH_PROXY_ALL` (ConfigMap) | Egress proxy for the fetch tool. `FETCH_PROXY_ALL` routes every fetch through it and hands the per-IP SSRF policy to the proxy. A proxy on a private address needs a rule under that instance's `networkPolicy.egress.extra` — the relay's internet egress rule excludes private ranges. |
| `instances[].metrics.mcpIdentity` | Keeps the scrape credential in the MCP token file as identity `prometheus`. Relay images up to v1.3.0 gate `/metrics` on that table; newer ones gate it on `MCP_METRICS_TOKEN` alone, which the chart also sets. Turn it off once yours does, and the scraper loses tool access. |
| `instances[].terminationGracePeriodSeconds` | Defaults to 45. The relay drains for up to 30s and exits non-zero if the window closes with requests in flight, so the Kubernetes default of 30 would cut every rollout's drain short. |
| `mcpRelay.config` / `instances[].existingConfigMap` | Every other upstream env var — cache sizes, body limits, rate limits, log level, session mode, `EXTRACT_LINKS`, `PRUNE_SELECTOR`, `USER_AGENT`. See the relay README's config table. |

Pull a token out for a client:

```console
kubectl -n <ns> get secret <release>-searxng-mcp-relay \
  -o jsonpath='{.data.tokens}' | base64 -d
```

Tokens already in the cluster are reused on upgrade, so bumping the chart does
not invalidate configured clients. Same GitOps caveat as `secret_key` — use
`auth.existingSecret` on each instance under Argo CD or Flux.

### Scoping a relay to specific engines

Several relays can share one SearXNG instance while each reaches only its own
engines — useful when separate teams have separate internal search backends and
must not read each other's.

Mark the engine private. `tokens:` gates who may *select* the engine; the
engine's own credential is what limits what it can *see*:

In your settings.yml — which is a Secret precisely so that `api_key` and
`tokens` have somewhere to live:

```yaml
engines:
  - name: teama-confluence
    engine: json_engine
    base_url: https://confluence-a.corp/rest/api/search
    api_key: "<team A service account token>"
    shortcut: cfa
    categories: [general]
    disabled: true
    tokens: ['ENGINE-TOKEN-A']
```

Then give each relay only its own token, through a Secret — these are engine
credentials out of your settings.yml, so the chart has neither a copy nor a way
to generate them:

```console
kubectl -n <ns> create secret generic relay-engine-tokens \
  --from-literal=searxng-tokens='ENGINE-TOKEN-A'
```

```yaml
mcpRelay:
  instances:
    - name: team-a
      searxngTokens:
        existingSecret: relay-engine-tokens
        existingSecretKey: searxng-tokens
```

It is injected as `SEARXNG_TOKENS`, from an object separate from the agent
token file so the two can have different readers. `SEARXNG_TOKENS` is read once
at startup and the chart cannot hash a Secret it does not render, so
`kubectl rollout restart` after editing it.

Four things worth knowing:

- **`disabled: true` is not redundant.** Without it the engine sits in its
  category and fires on every ordinary web search. Naming an engine explicitly
  through the relay's `engines` parameter still works while disabled.
- **The boundary is SearXNG's, not the relay's.** SearXNG resolves the whole
  engine reference list — categories, the `engines` parameter and `!bang`
  syntax inside the query alike — and only then drops engines whose `tokens:`
  are unsatisfied. A relay-side filter would miss the bang path.
- **Tokens are per-instance, not per-identity.** Every identity in one
  instance's `auth.identities` shares that instance's tokens; those identities
  are audit labels and rate-limit buckets. Two groups of callers that must be
  separated are two entries in `mcpRelay.instances` — same release, same
  SearXNG, different Deployments.
- **Search only.** `searxng_read_url` does not use these tokens. Keeping a
  relay away from another team's internal hosts is `FETCH_ALLOWED_HOSTS` in
  that instance's ConfigMap.

Note that `tokens` as a *request parameter* is undocumented upstream — SearXNG
documents engine tokens only as a Preferences-page setting. It follows from
`webapp.pre_request` merging request args into the preferences it parses, and
is long-standing, but pin `image.digest` and keep a smoke test asserting the
negative case: a search naming another team's engine without its token returns
no results.

### Ingress annotations

Both ingress blocks (`ingress.annotations` and an instance's
`ingress.annotations`)
pass through verbatim, so cert-manager, controller-specific and any other
annotations work as normal:

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

### Exposing it

The MCP endpoint is `/` on the relay Service; `/health` is unauthenticated and
`/metrics` requires a bearer token. The relay speaks plain HTTP, so terminate
TLS in front of it — the chart warns at install time if you enable
`mcpRelay.ingress` with no `tls` block, because bearer tokens would otherwise
cross the network in clear.

```yaml
mcpRelay:
  instances:
    - name: default
      ingress:
        enabled: true
        className: ""
        hosts:
          - host: mcp.example.com
            paths:
              - path: /
                pathType: Prefix
        tls:
          - secretName: mcp-tls
            hosts: [mcp.example.com]
```

### Replicas and sessions

Sessions live in each pod's memory. With `replicaCount > 1` a client's session
ID is only valid on the pod that issued it, so either stay at 1 replica, put
`MCP_STATELESS=true` in that instance's ConfigMap (trading server-validated
session IDs for restart-survivability), or add session affinity at the ingress.

The chart notes the risk when an instance has more than one replica, but it
cannot check whether you did anything about it: `MCP_STATELESS` lives in a
ConfigMap it does not read.

### Reaching internal URLs

`searxng_read_url` refuses non-public IPs by default. To let one instance read
an internal wiki, in its ConfigMap:

```console
kubectl -n <ns> create configmap relay-config \
  --from-literal=FETCH_ALLOWED_HOSTS=wiki.internal:443 \
  --from-literal=FETCH_ALLOWED_CIDRS=10.0.0.0/8:443
```

and, in values, the NetworkPolicy hole to match — the relay's internet egress
rule excludes private ranges, so the ACL alone would still be blocked at the
network layer:

```yaml
mcpRelay:
  instances:
    - name: default
      existingConfigMap: relay-config
      networkPolicy:
        egress:
          extra:
            - to:
                - ipBlock: { cidr: 10.0.0.0/8 }
              ports:
                - { port: 443, protocol: TCP }
```

Both layers have to agree — the relay's own SSRF guard *and* the NetworkPolicy.

## Metrics

Every component that exposes metrics gets a ServiceMonitor. None of the
endpoints exist until you enable them, so each is gated on its own toggle:

```yaml
searxng:
  metrics:
    enabled: true
    # Holds username + password; the password must equal general.open_metrics
    # in your settings.yml.
    existingSecret: searxng-metrics
mcpRelay:
  instances:
    - name: default
      metrics: { enabled: true }
valkey:
  metrics: { enabled: true }
metrics:
  serviceMonitor:
    enabled: true
    labels: { release: kube-prometheus-stack }   # must match serviceMonitorSelector
  allowScrapeFromNamespaces: [monitoring]        # required when NetworkPolicy is on
```

| Component | Endpoint | Format | Auth |
| --- | --- | --- | --- |
| SearXNG | `:8080/metrics` | OpenMetrics | HTTP Basic, password = `general.open_metrics` |
| MCP relay | `:8080/metrics` | Prometheus text | Bearer, dedicated `prometheus` identity |
| Valkey | `:9121/metrics` | Prometheus text | none — reachable only via NetworkPolicy |

Four things worth knowing:

**What SearXNG's `/metrics` actually is.** It is genuine OpenMetrics text
(`Content-Type: text/plain`), served by the `/metrics` route — not to be
confused with `/stats`, which is a separate route rendering an HTML engine
statistics page for humans. The endpoint is gated on `general.enable_metrics`
being true *and* `general.open_metrics` being a non-empty password: with either
unset it returns `404 open metrics is disabled`, not `401`, so a 404 from a
scrape means the settings never took effect rather than that the credential is
wrong. Only the password is compared — the username is ignored, but an
`Authorization: Basic` header still has to parse, which is why the
ServiceMonitor sends a username from your Secret at all.

The exposed series are engine-scoped and nothing else, six of them, all labelled
by `engine_name`:

| Series | Type |
| --- | --- |
| `searxng_engines_response_time_total_seconds` | gauge |
| `searxng_engines_response_time_processing_seconds` | gauge |
| `searxng_engines_response_time_http_seconds` | gauge |
| `searxng_engines_result_count_total` | counter |
| `searxng_engines_request_count_total` | counter |
| `searxng_engines_reliability_total` | counter |

So this endpoint answers "which engines are slow or failing", not "is this
instance healthy" — there are no process, request-rate, latency or error-rate
metrics for SearXNG itself. Pair it with the relay's `/metrics` and the usual
kubelet/cAdvisor series if you want the second question answered. Note also
that the counters live in process memory and are never written to Valkey: they
reset on restart, and each replica reports only its own traffic, so aggregate
across the `instance` label in PromQL rather than reading a single target's
value as instance-wide.

**The metrics password lives in settings.yml, which the chart does not write.**
Upstream gates `/metrics` on `general.open_metrics` and provides no
environment-variable override, so the password can only come from that file —
and the file is yours (see [settings.yml](#settingsyml)). The ServiceMonitor's
`basicAuth` presents the pair from the Secret named by
`searxng.metrics.existingSecret`, whose password half must equal
`general.open_metrics`. The chart reads neither, so nothing checks that for
you: a mismatch is a 401 on every scrape. The render is refused if metrics are
on with no Secret named.

```console
pw="$(openssl rand -hex 32)"
kubectl -n <ns> create secret generic searxng-metrics \
  --from-literal=username=prometheus --from-literal=password="$pw"
# ...and general.open_metrics: "$pw" in your settings.yml.
```

**The relay scrape uses its own identity, in its own Secret, per instance.**
Enabling an instance's `metrics.enabled` appends a `prometheus` identity to
*that instance's* token file and writes the same token, bare, into a separate
`<release>-searxng-mcp-relay[-<instance>]-scrape` Secret. Two objects rather than one so
Prometheus's read access can be scoped to the scrape credential alone:

```yaml
rules:
  - apiGroups: [""]
    resources: [secrets]
    resourceNames: [searxng-mcp-relay-scrape]
    verbs: [get]
```

The token is still duplicated inside the token file, and that part is not
fixable here — the relay authenticates every request, `/metrics` included,
against one `MCP_AUTH_TOKEN_FILE`, so anything that reads that file sees every
token. What the split removes is the need for the monitoring stack to be one of
those things. The separate identity is what keeps a compromised Prometheus from
being able to call the tools at all, and lets you rotate the scrape credential
without touching your agents.

**Valkey has no native endpoint,** so a `redis_exporter` sidecar
(`59000:59000`, read-only rootfs) runs next to both the primary and each
replica. One ServiceMonitor selects both via a `matchExpressions` on the
component label.

If `networkPolicy.enabled` is true and `metrics.allowScrapeFromNamespaces` is
empty, Prometheus is blocked by the deny-by-default ingress rules unless it
happens to run in the release namespace. The chart warns about this at install
time.

## Known limitations

- SearXNG's `/metrics` is engine telemetry only — six `engine_name`-labelled
  series, no process or request-level metrics for the instance itself. Its
  counters are in-process and reset on restart. See [Metrics](#metrics).
- NetworkPolicy has no effect on CNIs that don't implement it (e.g. stock
  Flannel).
- Valkey replication has no automatic failover, for the reason described above.
  No Sentinel, no proxy, no operator.
- ServiceMonitors assume the Prometheus Operator CRDs are installed; they are
  not gated on a capability check, so enabling them on a cluster without
  `monitoring.coreos.com/v1` will fail at apply time.
- The relay image tag defaults to `latest`. Upstream publishes `vX.Y.Z` tags —
  pin one.
