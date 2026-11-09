# Installation

## Contents

- [Requirements](#requirements)
- [Installing the published chart](#installing-the-published-chart)
- [Installing from a clone](#installing-from-a-clone)
- [Examples](#examples)
- [Before you install](#before-you-install)
- [Validating changes](#validating-changes)
- [Known limitations](#known-limitations)

## Requirements

- Kubernetes 1.25 or later — the floor `Chart.yaml` claims, and the oldest
  version CI renders against.
- Helm 4, or a current Helm 3. CI installs and upgrades under both.
- A CNI that enforces NetworkPolicy (Cilium, Calico, Antrea, …). On one that
  does not, the policies render and do nothing.
- A settings.yml for SearXNG, in a Secret. The chart has no default for it and
  refuses to render without one — see [settings.yml](configuration.md#settingsyml).
- The Prometheus Operator CRDs, only if you turn on the ServiceMonitors
  ([Metrics](observability.md)).

## Installing the published chart

Releases are published as a signed OCI artifact at
`oci://ghcr.io/littleoffice/charts/searxng`; there is no classic `helm repo add`
index. Create the settings Secret first, then install:

```console
kubectl create namespace search
kubectl -n search create secret generic searxng-settings \
  --from-file=settings.yml=./settings.yml

helm install searxng oci://ghcr.io/littleoffice/charts/searxng -n search \
  --version <version> \
  --set searxng.existingSettingsSecret=searxng-settings
```

The versions are listed on
[Artifact Hub](https://artifacthub.io/packages/search?repo=littleoffice-searxng)
and the repository's GitHub Releases, each with its changelog, the packaged
`.tgz`, SBOMs for the images it pins and the image scan report from the moment
it shipped.

`helm install` does not check the signature. Verify it as a separate step:
[Verification](supply-chain.md#verification).

The namespace is whatever you pass to `-n` — nothing in the chart assumes one.

## Installing from a clone

The chart is the repository root, so a clone installs as it is:

```console
git clone https://github.com/littleoffice/searxng-helm
cd searxng-helm
kubectl -n search create secret generic searxng-settings \
  --from-file=settings.yml=examples/settings.example.yml
helm install searxng . -n search --create-namespace \
  --set searxng.existingSettingsSecret=searxng-settings
```

`main` is unreleased work; pin a published version for anything you depend on.

## Examples

Ready-to-use manifests and values live in [`examples/`](../examples/):

```console
examples/gen-secrets.sh <release> <namespace> [standalone|replication] > secrets.yaml
kubectl -n <namespace> apply -f secrets.yaml
helm install <release> oci://ghcr.io/littleoffice/charts/searxng -n <namespace> \
  -f examples/values-production.yaml
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

Which Secrets a given install needs, and why the Valkey one carries config files
as well as a password: [examples/README.md](../examples/README.md#which-secrets-do-i-actually-need).

## Before you install

Look at two values first:

| Value | Why |
| --- | --- |
| `networkPolicy.ingress.fromNamespaces` | Empty by default. The chart makes no guess about which ingress controller you run or where it lives; if you enable the Ingress without setting this, the controller is blocked and requests time out. |
| `image.digest` | Pinned by default to the SearXNG image the chart was released with, and it takes precedence over `image.tag`. Override it to move to another image, and keep a digest rather than a bare tag. |

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

## Validating changes

From a clone, with a placeholder name for the settings Secret, since the chart
refuses to render without one:

```console
helm lint . --set searxng.existingSettingsSecret=searxng-settings
helm template searxng . --set searxng.existingSettingsSecret=searxng-settings \
  | kubeconform -strict -
```

What CI checks on every pull request, and how to run it locally:
[`.github/ci/README.md`](../.github/ci/README.md).

## Known limitations

- NetworkPolicy has no effect on CNIs that don't implement it (e.g. stock
  Flannel).
- Valkey replication has no automatic failover: SearXNG takes a single URL and
  does not speak Sentinel ([Valkey](configuration.md#valkey)). No Sentinel, no
  proxy, no operator.
- SearXNG's `/metrics` is engine telemetry only — six `engine_name`-labelled
  series, no process or request-level metrics for the instance itself. Its
  counters are in-process and reset on restart. See
  [What SearXNG's /metrics actually is](observability.md#what-searxngs-metrics-actually-is).
- ServiceMonitors assume the Prometheus Operator CRDs are installed; they are
  not gated on a capability check, so enabling them on a cluster without
  `monitoring.coreos.com/v1` will fail at apply time.
- Each image is pinned by digest, and a newer upstream image reaches you only
  through a new chart release (or your own `digest` override). How the pins are
  kept current: [Images](supply-chain.md#images).
