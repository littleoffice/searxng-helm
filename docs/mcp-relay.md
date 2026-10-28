# MCP relay

Optional integration with
[littleoffice/mcp-searxng-relay](https://github.com/littleoffice/mcp-searxng-relay)
— an MCP server that exposes this SearXNG to Claude Desktop and other agents
over Streamable HTTP, with bearer auth, per-identity audit logging,
SSRF-protected URL fetching and Ed25519-signed responses.

## Contents

- [Enabling it](#enabling-it)
- [Where a relay's configuration comes from](#where-a-relays-configuration-comes-from)
- [Several relays, one SearXNG](#several-relays-one-searxng)
- [Relay options worth knowing](#relay-options-worth-knowing)
- [Scoping a relay to specific engines](#scoping-a-relay-to-specific-engines)
- [Exposing it](#exposing-it)
- [Replicas and sessions](#replicas-and-sessions)
- [Reaching internal URLs](#reaching-internal-urls)
- [Verifying the signatures with fence-gateway](#verifying-the-signatures-with-fence-gateway)

## Enabling it

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
own with `auth.existingSecret`, whose Secret holds the `identity:token` file
([format](https://github.com/littleoffice/mcp-searxng-relay/blob/main/docs/configuration.md#token-file-format)) —
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

Pull a token out for a client:

```console
kubectl -n <ns> get secret <release>-searxng-mcp-relay \
  -o jsonpath='{.data.tokens}' | base64 -d
```

Tokens already in the cluster are reused on upgrade, so bumping the chart does
not invalidate configured clients. Same
[GitOps caveat](security-model.md#gitops-caveat) as `secret_key` — use
`auth.existingSecret` on each instance under Argo CD or Flux.

## Where a relay's configuration comes from

Nothing non-secret about a relay lives in values. Each instance names a
ConfigMap you manage, whose keys become environment variables:

```console
kubectl -n <ns> create configmap relay-config \
  --from-literal=MCP_RATE_LIMIT_RPS=5 \
  --from-literal=LOG_LEVEL=info \
  --from-literal=MCP_STATELESS=true
```

[`examples/relay-config.example.yaml`](../examples/relay-config.example.yaml)
is a worked one. Four layers, and Kubernetes decides the winner — later
`envFrom` entries beat earlier ones, explicit `env` beats every `envFrom`:

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

Every variable the relay reads, with its default, is in the relay's
[configuration reference](https://github.com/littleoffice/mcp-searxng-relay/blob/main/docs/configuration.md).

## Several relays, one SearXNG

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

The whole two-team setup, values and Secrets, is
[`examples/values-multi-tenant.yaml`](../examples/values-multi-tenant.yaml).

## Relay options worth knowing

| Value | What it does |
| --- | --- |
| `instances[].fenceKey.existingSecret` | Ed25519 key the relay signs `<sec:fence>` elements with, mounted as a file. Without one each process generates its own at startup, so the fingerprint changes on every restart and differs between replicas — fine until something verifies those signatures and needs a key to pin. |
| `instances[].healthToken.existingSecret` | Bearer token gating `GET /health`, separate from the MCP tokens. Setting it switches the readiness probe to the relay's own `--healthcheck` self-probe, which reads the token from its environment — a Kubernetes `httpGet` probe can only carry a literal header. |
| `FETCH_PROXY` / `FETCH_PROXY_ALL` (ConfigMap) | Egress proxy for the fetch tool. `FETCH_PROXY_ALL` routes every fetch through it and hands the per-IP SSRF policy to the proxy. A proxy on a private address needs a rule under that instance's `networkPolicy.egress.extra` — the relay's internet egress rule excludes private ranges. |
| `instances[].metrics.mcpIdentity` | Keeps the scrape credential in the MCP token file as identity `prometheus`. Relay images up to v1.3.0 gate `/metrics` on that table; newer ones gate it on `MCP_METRICS_TOKEN` alone, which the chart also sets. Turn it off once yours does, and the scraper loses tool access. |
| `instances[].terminationGracePeriodSeconds` | Defaults to 45. The relay drains for up to 30s and exits non-zero if the window closes with requests in flight, so the Kubernetes default of 30 would cut every rollout's drain short. |
| `mcpRelay.config` / `instances[].existingConfigMap` | Every other upstream env var — cache sizes, body limits, rate limits, log level, session mode, `EXTRACT_LINKS`, `PRUNE_SELECTOR`, `USER_AGENT`. See the relay's [configuration reference](https://github.com/littleoffice/mcp-searxng-relay/blob/main/docs/configuration.md). |

## Scoping a relay to specific engines

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

## Exposing it

The MCP endpoint is `/` on the relay Service; `/health` is unauthenticated
unless `healthToken` is set, and `/metrics` requires a bearer token. The relay
speaks plain HTTP, so terminate TLS in front of it — the chart warns at install
time if you enable an instance's `ingress` with no `tls` block, because bearer
tokens would otherwise cross the network in clear.

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

Its annotations pass through the same way as SearXNG's:
[Ingress annotations](configuration.md#ingress-annotations).

## Replicas and sessions

Sessions live in each pod's memory. With `replicaCount > 1` a client's session
ID is only valid on the pod that issued it, so either stay at 1 replica, put
`MCP_STATELESS=true` in that instance's ConfigMap (trading server-validated
session IDs for restart-survivability), or add session affinity at the ingress.

The chart notes the risk when an instance has more than one replica, but it
cannot check whether you did anything about it: `MCP_STATELESS` lives in a
ConfigMap it does not read.

## Reaching internal URLs

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

## Verifying the signatures with fence-gateway

Every relay response is wrapped in an Ed25519-signed `<sec:fence>` element.
[fence-gateway](https://github.com/littleoffice/fence-gateway) checks those
signatures before content reaches the model. In front of a relay from this
chart it needs three things from the instance: a persistent signing key
(`fenceKey.existingSecret`), so the fingerprint it pins survives rollouts; the
instance's Ingress off, so clients reach the gateway and never the relay; and
the instance's `networkPolicy.ingress` narrowed to the gateway's pods. The
values for that are in fence-gateway's
[Kubernetes deployment guide](https://github.com/littleoffice/fence-gateway/blob/main/docs/deployment.md#kubernetes--searxng-helm).
