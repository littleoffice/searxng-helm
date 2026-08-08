# Examples

| File | What it is |
| --- | --- |
| `gen-secrets.sh` | Generates all Secrets with real random credentials. Prints to stdout. |
| `secrets.example.yaml` | The same Secrets as annotated placeholders, if you would rather fill them in by hand. |
| `values-minimal.yaml` | Smallest working install; chart manages the credentials. |
| `values-config.yaml` | The ConfigMap side — settings.yml, custom engines, limiter.toml, extra files. |
| `values-production.yaml` | Everything on, all credentials from Secrets you manage. GitOps-safe. |

## Quick start

```console
./gen-secrets.sh searxng search replication > secrets.yaml
kubectl create namespace search
kubectl -n search apply -f secrets.yaml
helm install searxng ../ -n search -f values-production.yaml
```

`gen-secrets.sh` writes only to stdout, so you can pipe it into `kubeseal` or
`sops` instead of applying it in the clear.

Note that `secrets.example.yaml` is a plain manifest — `kubectl apply` performs
no substitution, so the `replicaof` hostname inside `valkey-replica.conf` has
to be edited by hand. `gen-secrets.sh` computes it for you, including the case
where Helm collapses the name because the release name already contains
"searxng".

## Which Secrets do I actually need?

None of them — leave every `existingSecret` empty and the chart generates and
maintains all of it. You need them when you deploy through Argo CD or Flux,
because those render with `helm template`, where the chart's cluster lookup
returns nothing and every credential would be regenerated on each sync.

| Secret | Values key | Required when |
| --- | --- | --- |
| `secret-key` | `searxng.existingSecret` | always, under GitOps |
| Valkey password **and configs** | `valkey.auth.existingSecret` | `valkey.enabled` |
| Valkey URL | `valkey.external.existingSecret` | `valkey.enabled: false` |
| Relay tokens | `mcpRelay.auth.existingSecret` | `mcpRelay.enabled` |
| Relay scrape token | `mcpRelay.metrics.existingSecret` | `mcpRelay.metrics.enabled` |

The Valkey one is the awkward member of the set: `valkey.auth.existingSecret`
suppresses the chart's own Valkey Secret, and the config files live in that
same Secret, so your Secret has to carry `valkey.conf` (and
`valkey-replica.conf` under `architecture: replication`) as well as the
password. That is the cost of keeping `requirepass` out of the process list
rather than passing it as a CLI flag. `gen-secrets.sh` handles it.

## ConfigMaps

There is no bring-your-own-ConfigMap path. The chart renders them from values
so the settings file cannot drift out of sync with the environment variables
it injects alongside it:

| Object | Source |
| --- | --- |
| `<release>-searxng-settings` | `searxng.settings` — a ConfigMap, or a Secret if `searxng.metrics.enabled` |
| `<release>-searxng-limiter` | `searxng.limiter`, only when the limiter is on |
| `<release>-searxng-extra` | `searxng.extraConfigFiles` |

See `values-config.yaml`. To preview exactly what you will get:

```console
helm template searxng ../ -f values-config.yaml -s templates/settings.yaml
```
