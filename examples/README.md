# Examples

| File | What it is |
| --- | --- |
| `gen-secrets.sh` | Generates all Secrets with real random credentials. Prints to stdout. |
| `secrets.example.yaml` | The same Secrets as annotated placeholders, if you would rather fill them in by hand. |
| `settings.example.yml` | A worked settings.yml, for the Secret the chart mounts. |
| `relay-config.example.yaml` | A worked relay ConfigMap, for one MCP relay instance. |
| `values-minimal.yaml` | Smallest working install; chart manages the credentials it can. |
| `values-config.yaml` | The config-file side — pointing at that Secret, limiter.toml, extra files. |
| `values-production.yaml` | Everything on, all credentials from Secrets you manage. GitOps-safe. |
| `values-multi-tenant.yaml` | Two teams, one SearXNG: a relay instance each, scoped to its own private engines. |

## Quick start

```console
./gen-secrets.sh searxng search replication > secrets.yaml
kubectl create namespace search
kubectl -n search apply -f secrets.yaml
helm install searxng ../ -n search -f values-production.yaml
```

The Secrets come first because one of them is settings.yml: the chart mounts
that file but never writes it, and refuses to render without it. `gen-secrets.sh`
emits a starter — upstream defaults and nothing else — which you are meant to
replace with your own configuration. `settings.example.yml` is a fuller one.

`gen-secrets.sh` writes only to stdout, so you can pipe it into `kubeseal` or
`sops` instead of applying it in the clear.

Note that `secrets.example.yaml` is a plain manifest — `kubectl apply` performs
no substitution, so the `replicaof` hostname inside `valkey-replica.conf` has
to be edited by hand. `gen-secrets.sh` computes it for you, including the case
where Helm collapses the name because the release name already contains
"searxng".

## Which Secrets do I actually need?

Some always, the rest under GitOps. `values.yaml` has no field anywhere that
takes secret material, so anything the chart cannot generate for itself has to
arrive as a Secret. What it *can* generate it keeps stable across upgrades with
a cluster lookup — which returns nothing under Argo CD or Flux, so those need
the `existingSecret` form for the generated ones too.

| Secret | Values key | Required when |
| --- | --- | --- |
| `settings.yml` | `searxng.existingSettingsSecret` | **always** |
| `/metrics` basic-auth pair | `searxng.metrics.existingSecret` | `searxng.metrics.enabled` |
| Private-engine tokens | `instances[].searxngTokens.existingSecret` | scoping a relay to private engines |
| Relay fence signing key | `instances[].fenceKey.existingSecret` | something verifies fence signatures |
| Relay `/health` token | `instances[].healthToken.existingSecret` | `/health` is reachable beyond the cluster |
| `secret-key` | `searxng.existingSecret` | generated; always under GitOps |
| Valkey password **and configs** | `valkey.auth.existingSecret` | generated; always under GitOps |
| Valkey URL | `valkey.external.existingSecret` | `valkey.enabled: false` |
| Relay tokens | `instances[].auth.existingSecret` | generated per instance; always under GitOps |
| Relay scrape token | `instances[].metrics.existingSecret` | generated per instance; always under GitOps |

The Valkey one is the awkward member of the set: `valkey.auth.existingSecret`
suppresses the chart's own Valkey Secret, and the config files live in that
same Secret, so your Secret has to carry `valkey.conf` (and
`valkey-replica.conf` under `architecture: replication`) as well as the
password. That is the cost of keeping `requirepass` out of the process list
rather than passing it as a CLI flag. `gen-secrets.sh` handles it.

## Config files

settings.yml is yours: it comes from the Secret named by
`searxng.existingSettingsSecret`, and the chart neither renders nor reads it.
Engine `tokens`, per-engine `api_key` fields and `outgoing.proxies` credentials
have no env-var override upstream and can only live in that file, so keeping it
out of values keeps them out of Helm entirely.

The two files the chart does render are generated from values, because they
have to stay in sync with the environment it injects:

| Object | Kind | Source |
| --- | --- | --- |
| your Secret | Secret | you — `searxng.existingSettingsSecret` |
| `<release>-searxng-limiter` | ConfigMap | `searxng.limiter`, only when the limiter is on |
| `<release>-searxng-extra` | ConfigMap | `searxng.extraConfigFiles` |

Do not put credentials in `extraConfigFiles`; that one is a ConfigMap. The
same goes for the relay ConfigMaps — see `relay-config.example.yaml`, which is
everything non-secret about one MCP relay instance. Each instance names its own,
layered over the fleet-wide `mcpRelay.config`.

Because the chart cannot read your settings.yml, three of its keys are mirrored
in values and have to be kept in step: `server.port` → `searxng.port`, and
`server.limiter` / `server.public_instance` → `searxng.limiter.enabled` /
`.publicInstance`.

See `values-config.yaml`. To preview what the chart itself will render:

```console
helm template searxng ../ -f values-config.yaml -s templates/configmap-limiter.yaml
```
