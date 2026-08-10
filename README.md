[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/littleoffice-searxng)](https://artifacthub.io/packages/search?repo=littleoffice-searxng)


# SearXNG — hardened Helm chart

A production-oriented chart for [SearXNG](https://docs.searxng.org) built around
four constraints:

- **No init containers.** Anywhere.
- **Rootless**, with a read-only root filesystem and all capabilities dropped.
- **Secrets stay secrets** — settings.yml is a Secret, never a ConfigMap, and no
  credential is ever passed in an argv.
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
| `values-config.yaml` | settings.yml, custom engines, limiter.toml, extra files. |
| `values-production.yaml` | Everything on, all credentials external, GitOps-safe. |

## Install

```console
helm install searxng ./searxng -n search --create-namespace
```

The namespace is whatever you pass to `-n` — nothing in the chart assumes one.

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
| Root | rejected at render time — see below |

### Nothing runs as root

Every workload sets `runAsNonRoot: true` with an explicit non-zero
`runAsUser` / `runAsGroup` / `fsGroup`: SearXNG `977`, Valkey `999:1000`, the
MCP relay `1001`. The chart also **refuses to render** if a values override
would set any of those to `0`, adds `0` to `supplementalGroups`, or flips
`runAsNonRoot` off — so a bad override fails at `helm template` rather than
being rejected by your admission controller later.

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
`server.secret_key` at load time — so the ConfigMap never contains it. The chart
**refuses to render** if you put `server.secret_key` into
`searxng.settings`.

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

### GitOps caveat

With no `searxng.secretKey` set, the chart generates one and keeps it stable
across upgrades with a cluster `lookup`. Argo CD and Flux render via
`helm template`, where `lookup` returns nothing — the key would be regenerated
on every sync and log every user out. **Use `searxng.existingSecret` under
GitOps.**

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

`searxng.settings` is a structured dict rendered straight into the Secret, so
anything from the [settings reference](https://docs.searxng.org/admin/settings/)
works:

```yaml
searxng:
  settings:
    search:
      safe_search: 1
      formats: [html, json]
```

### settings.yml is a Secret

Not a ConfigMap, in every configuration. SearXNG resolves environment variables
for a fixed allowlist of settings only — `SEARXNG_SECRET`, `SEARXNG_VALKEY_URL`,
`SEARXNG_BASE_URL`, `SEARXNG_PORT`, `SEARXNG_BIND_ADDRESS`, `SEARXNG_LIMITER`,
`SEARXNG_PUBLIC_INSTANCE`, `SEARXNG_IMAGE_PROXY`, `SEARXNG_METHOD`,
`SEARXNG_DEBUG` — and several things that are unambiguously credentials are not
on it and will not be joining it:

| In settings.yml | What it is |
| --- | --- |
| `engines[].tokens` | Token list gating a [private engine](https://docs.searxng.org/admin/engines/settings.html) |
| `engines[].api_key`, `.password`, `.token` | Per-engine upstream credentials |
| `outgoing.proxies` | Can carry inline `user:pass@` credentials |
| `general.open_metrics` | HTTP Basic password for `/metrics` |

Since these can only live in the file, the file is a Secret. The container
mounts only the `settings.yml` key, at the same path and with the same content
it always had.

Two things this does **not** solve:

- **The values file still holds the plaintext.** A Secret in the cluster does
  not help if `values.yaml` is committed to git. Keep engine credentials in a
  values file you hold outside the repo, or in SOPS / sealed-secrets.
- **`searxng.extraConfigFiles` is still a ConfigMap.** Do not put credentials
  in it.

`kubectl describe` no longer shows the rendered config. To read it back:

```console
kubectl -n <ns> get secret <release>-searxng-settings \
  -o jsonpath='{.data.settings\.yml}' | base64 -d
```

`helm diff` redacts Secret contents by default; pass `--show-secrets` if you
need to see what a change does to this file.

### Custom / additional search providers

With `use_default_settings: true`, entries in `searxng.settings.engines` are
merged into the built-in list **by `name`** — so you can flip a built-in on or
add your own:

```yaml
searxng:
  settings:
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

Other config files (`favicons.toml`, …) go in `searxng.extraConfigFiles`, a
filename → content map mounted alongside `settings.yml`.

### The limiter

Off by default. Enabling it requires Valkey, and the chart will refuse to render
without one:

```yaml
searxng:
  settings:
    server:
      limiter: true
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

```yaml
searxng:
  settings:
    search:
      formats: [html, json]
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
  auth:
    identities:
      - name: claude-desktop      # token generated if omitted
      - name: agent-ci
        token: "<64 hex chars>"   # or bring your own, min 32 chars
```

Enabling it wires up, without you doing anything else:

- `SEARXNG_URL` pointed at this release's SearXNG Service
- `json` appended to `searxng.settings.search.formats` — the relay cannot read
  results without it, and the rendered ConfigMap says so in a comment
- a Secret holding `identity:token` lines, mounted at `/etc/mcp-auth/tokens`
  and read through `MCP_AUTH_TOKEN_FILE`
- NetworkPolicies: relay → SearXNG, relay → DNS, relay → internet (minus
  private ranges, matching the relay's own SSRF policy)

Pull a token out for a client:

```console
kubectl -n <ns> get secret <release>-searxng-mcp-relay \
  -o jsonpath='{.data.tokens}' | base64 -d
```

Tokens already in the cluster are reused on upgrade, so bumping the chart does
not invalidate configured clients. Same GitOps caveat as `secret_key` — use
`mcpRelay.auth.existingSecret` under Argo CD or Flux.

### Scoping a relay to specific engines

Several relays can share one SearXNG instance while each reaches only its own
engines — useful when separate teams have separate internal search backends and
must not read each other's.

Mark the engine private. `tokens:` gates who may *select* the engine; the
engine's own credential is what limits what it can *see*:

```yaml
searxng:
  settings:
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

Then give each relay only its own token:

```yaml
mcpRelay:
  searxngTokens:
    tokens:
      - ENGINE-TOKEN-A
```

This renders a Secret `<release>-searxng-mcp-relay-engine-tokens`, separate
from the agent token file, and injects it as `SEARXNG_TOKENS`. Under GitOps use
`mcpRelay.searxngTokens.existingSecret` with a key of `searxng-tokens`, the
same way `mcpRelay.auth.existingSecret` works.

Four things worth knowing:

- **`disabled: true` is not redundant.** Without it the engine sits in its
  category and fires on every ordinary web search. Naming an engine explicitly
  through the relay's `engines` parameter still works while disabled.
- **The boundary is SearXNG's, not the relay's.** SearXNG resolves the whole
  engine reference list — categories, the `engines` parameter and `!bang`
  syntax inside the query alike — and only then drops engines whose `tokens:`
  are unsatisfied. A relay-side filter would miss the bang path.
- **Tokens are per-relay, not per-identity.** Every identity in
  `mcpRelay.auth.identities` shares them; those identities are audit labels.
  Two groups of callers that must be separated need two relay deployments,
  which today means two releases with `searxng.enabled` handled accordingly.
- **Search only.** `searxng_read_url` does not use these tokens. Keeping a
  relay away from another team's internal hosts is `mcpRelay.fetch.allowedHosts`
  / `allowedCIDRs`, set per relay.

Note that `tokens` as a *request parameter* is undocumented upstream — SearXNG
documents engine tokens only as a Preferences-page setting. It follows from
`webapp.pre_request` merging request args into the preferences it parses, and
is long-standing, but pin `image.digest` and keep a smoke test asserting the
negative case: a search naming another team's engine without its token returns
no results.

### Ingress annotations

Both ingress blocks (`ingress.annotations` and `mcpRelay.ingress.annotations`)
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
ID is only valid on the pod that issued it, so either stay at 1 replica, set
`mcpRelay.stateless: true` (trading server-validated session IDs for
restart-survivability), or add session affinity at the ingress. The chart warns
if you scale out without doing one of those.

### Reaching internal URLs

`searxng_read_url` refuses non-public IPs by default. To let it read an internal
wiki:

```yaml
mcpRelay:
  fetch:
    allowedHosts: [wiki.internal]
    allowedCIDRs: ["10.0.0.0/8"]
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
  metrics: { enabled: true }
mcpRelay:
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
ServiceMonitor sends `searxng.metrics.username` (default `prometheus`) at all.

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

**The metrics password lives in settings.yml.** Upstream gates `/metrics` on
`general.open_metrics` and provides no environment-variable override for it, so
the password can only be supplied through the settings file. That file is a
Secret in all cases (see [settings.yml is a Secret](#settingsyml-is-a-secret)),
so enabling `searxng.metrics.enabled` changes nothing about where it is stored —
it only adds `open-metrics-username` / `open-metrics-password` keys alongside
`settings.yml` for the ServiceMonitor's `basicAuth` to reference.

**The relay scrape uses its own identity, in its own Secret.** Enabling
`mcpRelay.metrics.enabled` appends a `prometheus` identity to the relay's token
file and writes the same token, bare, into a separate
`<release>-searxng-mcp-relay-scrape` Secret. Two objects rather than one so
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
