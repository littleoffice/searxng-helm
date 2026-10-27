# Upgrading to 2.0.0

2.0.0 makes one rule true everywhere: **no values key anywhere takes secret
material.** Anything the chart cannot generate for itself now arrives as a
Secret it only references. Every removed key is *rejected* by the schema rather
than ignored, so a 1.x values file fails the render naming what to do instead —
you will not silently lose a credential you thought was set.

## Contents

- [Values that moved](#values-that-moved)
- [Moving settings.yml out of values](#moving-settingsyml-out-of-values)
- [Objects that change](#objects-that-change)
- [One behaviour change that is not a rename](#one-behaviour-change-that-is-not-a-rename)
- [Before you upgrade](#before-you-upgrade)

## Values that moved

| 1.x | 2.0.0 |
| --- | --- |
| `searxng.settings` | `searxng.existingSettingsSecret` — the file itself, in a Secret |
| `searxng.settings.server.port` | `searxng.port` |
| `searxng.settings.server.limiter` | `searxng.limiter.enabled` |
| `searxng.settings.server.public_instance` | `searxng.limiter.publicInstance` |
| `searxng.metrics.password` / `.username` | `searxng.metrics.existingSecret` — both halves live in it |
| `searxng.secretKey` | generated, or `searxng.existingSecret` |
| `valkey.auth.password` | generated, or `valkey.auth.existingSecret` |
| `valkey.external.url` | `valkey.external.existingSecret` |
| `mcpRelay.auth.identities[].token` | generated, or `mcpRelay…auth.existingSecret` |
| `mcpRelay.searxngTokens.tokens` | `mcpRelay…searxngTokens.existingSecret` |
| `mcpRelay.<everything else>` | `mcpRelay.defaults.<same>`, overridable per instance |
| `mcpRelay.logLevel`, `.logFormat`, `.stateless`, `.session`, `.rateLimit`, `.fetch` | keys in the ConfigMap named by `instances[].existingConfigMap` |

The relay's shape changed as well as its keys: `mcpRelay.instances` is a list,
one relay Deployment per entry. A single-relay release becomes one entry named
`default`, which deliberately keeps the object names and the Deployment
selector it already had — so it upgrades in place rather than being replaced.
How instances and their ConfigMaps work now: [MCP relay](mcp-relay.md).

## Moving settings.yml out of values

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
`secret_key` and Valkey Secrets are untouched. What the file now has to say for
itself, since the chart no longer writes into it:
[What the chart cannot do for you](configuration.md#what-the-chart-cannot-do-for-you).

## Objects that change

- `<release>-searxng-settings` is gone. The chart no longer renders settings.yml
  at all; the Secret you name is mounted instead.
- `<release>-searxng-metrics` is no longer chart-rendered. The ServiceMonitor
  reads the basic-auth pair straight out of the Secret you name.
- The Deployment's `checksum/config` is gone, and the relay's `checksum/auth`
  disappears when `auth.existingSecret` is set. The chart cannot hash a Secret
  it does not write, so edit yours and `kubectl rollout restart`. The upside is
  that relays with an external token Secret stop rolling on every upgrade.

## One behaviour change that is not a rename

An ingress allow-list that resolved to nothing used to render `from: null`,
which Kubernetes reads as **admit every source** — the inverse of what an empty
allow-list means. It now renders no rule at all, so the traffic is denied.

If you run with `networkPolicy.ingress.allowSameNamespace: false` and no
`fromNamespaces` or `from` entries, traffic that reached SearXNG before this
release will stop. That was never the configuration you asked for, but check
before upgrading:

```console
helm get values <release> -n <ns> -o yaml | yq '.networkPolicy.ingress'
```

## Before you upgrade

1. Create the settings Secret, and the metrics Secret if `searxng.metrics` is
   on. [`examples/settings.example.yml`](../examples/settings.example.yml) is a
   worked settings.yml.
2. Rewrite your values against the table above. `helm template` locally — every
   removed key fails the render with the replacement named.
3. Check the NetworkPolicy note above if your ingress allow-list is empty.
4. Generated credentials — `secret_key`, the Valkey password, relay tokens — are
   read back from the cluster and survive the upgrade untouched.
