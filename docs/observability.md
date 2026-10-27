# Metrics

Every component that exposes metrics gets a ServiceMonitor, each behind a
credential or a NetworkPolicy of its own. None of the endpoints exist until you
enable them, so each is gated on its own toggle.

## Contents

- [Turning it on](#turning-it-on)
- [SearXNG](#searxng)
  - [What SearXNG's /metrics actually is](#what-searxngs-metrics-actually-is)
  - [The metrics password lives in settings.yml](#the-metrics-password-lives-in-settingsyml)
- [MCP relay](#mcp-relay)
- [Valkey](#valkey)
- [Letting Prometheus through the NetworkPolicy](#letting-prometheus-through-the-networkpolicy)

## Turning it on

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
| MCP relay | `:8080/metrics` | Prometheus text | Bearer, a scrape credential per instance |
| Valkey | `:9121/metrics` | Prometheus text | none — reachable only via NetworkPolicy |

The ServiceMonitors need the Prometheus Operator CRDs
(`monitoring.coreos.com/v1`). They are not gated on a capability check, so
enabling them on a cluster without the CRDs fails at apply time.

## SearXNG

### What SearXNG's /metrics actually is

It is genuine OpenMetrics text (`Content-Type: text/plain`), served by the
`/metrics` route — not to be confused with `/stats`, which is a separate route
rendering an HTML engine statistics page for humans. The endpoint is gated on
`general.enable_metrics` being true *and* `general.open_metrics` being a
non-empty password: with either unset it returns
`404 open metrics is disabled`, not `401`, so a 404 from a scrape means the
settings never took effect rather than that the credential is wrong. Only the
password is compared — the username is ignored, but an `Authorization: Basic`
header still has to parse, which is why the ServiceMonitor sends a username
from your Secret at all.

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

### The metrics password lives in settings.yml

Upstream gates `/metrics` on `general.open_metrics` and provides no
environment-variable override, so the password can only come from that file —
and the file is yours (see [settings.yml](configuration.md#settingsyml)). The
ServiceMonitor's `basicAuth` presents the pair from the Secret named by
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

## MCP relay

**The relay scrape uses its own credential, in its own Secret, per instance.**
Enabling an instance's `metrics.enabled` mints a scrape token, passes it to the
relay as `$MCP_METRICS_TOKEN`, and writes it, bare, into a separate
`<release>-searxng-mcp-relay[-<instance>]-scrape` Secret for that instance's
ServiceMonitor to reference. A Secret of its own so Prometheus's read access can
be scoped to the scrape credential alone:

```yaml
rules:
  - apiGroups: [""]
    resources: [secrets]
    resourceNames: [searxng-mcp-relay-scrape]
    verbs: [get]
```

With `metrics.mcpIdentity` on (the default), the same token is also appended to
*that instance's* token file as identity `prometheus`, because relay images up
to v1.3.0 gate `/metrics` on the MCP token table. That copy is the part to get
rid of: the relay authenticates every MCP request against one
`MCP_AUTH_TOKEN_FILE`, so a credential in it can call the tools as well as
scrape. Newer relay images gate `/metrics` on `MCP_METRICS_TOKEN` alone; turn
`mcpIdentity` off once yours does, and a compromised Prometheus can no longer
call the tools at all. Either way the scrape credential rotates without touching
your agents' tokens.

What the relay's series measure: the relay's
[logging and metrics reference](https://github.com/littleoffice/mcp-searxng-relay/blob/main/docs/observability.md).

## Valkey

**Valkey has no native endpoint,** so a `redis_exporter` sidecar
(`59000:59000`, read-only rootfs) runs next to both the primary and each
replica. One ServiceMonitor selects both via a `matchExpressions` on the
component label.

## Letting Prometheus through the NetworkPolicy

If `networkPolicy.enabled` is true and `metrics.allowScrapeFromNamespaces` is
empty, Prometheus is blocked by the deny-by-default ingress rules unless it
happens to run in the release namespace. The chart warns about this at install
time.
