# Documentation

Reference documentation for searxng-helm. The project overview, features and quick start are in the [top-level README](../README.md).

| Document | Contents |
|---|---|
| [Installation](installation.md) | Requirements, the published chart, installing from a clone, examples, validating changes, known limitations |
| [Configuration](configuration.md) | settings.yml, custom engines, the limiter, Valkey, ingress, Open WebUI, notable values |
| [MCP relay](mcp-relay.md) | Instances and identities, configuration layers, engine scoping, exposing it, fence-gateway |
| [Architecture](architecture.md) | What the chart renders, every NetworkPolicy rule, starting without an init container |
| [Security model](security-model.md) | The security posture, render-time enforcement, where each credential lives, GitOps |
| [Metrics](observability.md) | ServiceMonitors, what each `/metrics` endpoint exposes, scrape credentials |
| [Upgrading to 2.0.0](upgrading.md) | Values that moved, settings.yml out of values, the NetworkPolicy behaviour change |
| [Examples](../examples/README.md) | Ready-made values files and Secrets, and which Secrets an install needs |
| [Supply-chain statement](supply-chain.md) | How the code was written, the images and their pins, build provenance, verification, known gaps |
| [Security policy](SECURITY.md) | Supported versions and how to report a vulnerability |
