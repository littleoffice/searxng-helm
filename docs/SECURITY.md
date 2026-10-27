# Security Policy

This document describes how to report security issues in `searxng-helm` and
what to expect once you do. For the project's image, build-provenance, and
development-process statement — the "what am I actually trusting if I install
this" question — see [supply-chain.md](supply-chain.md).

This project is maintained by a single individual: the holder of the GitHub
account with admin rights on the repository. References to "the maintainer"
below mean that person. The project is entirely AI-generated and
human-reviewed; [supply-chain.md](supply-chain.md#development-process) describes
that process in full, and it is relevant context for how security reports are
handled — every fix, like every other change, is reviewed and tested by the
maintainer before release.

## Supported versions

The latest released chart version receives security fixes. There is no
backport window for older releases — if a fix ships, it ships in a new
release, and the expectation is that operators move forward to it.

If you are installing from an untagged commit on `main`, treat it as
unsupported for security purposes — pin to a release.

## Reporting a vulnerability

**Do not open a public issue for security problems.** Public issues are visible
to everyone, including before a fix exists.

Report privately through GitHub's private vulnerability reporting:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Fill in the advisory form with as much detail as you can — affected chart
   version, the values that reproduce it, and the impact you believe it has.

This routes the report privately to the maintainer and gives both sides a shared
space to coordinate a fix and a disclosure timeline.

### What happens next

This is a single-maintainer project. It is honest to be plain about what that
means rather than promise a service level that cannot be backed:

- There is **no committed response time**. There is no team, no rotation, and no
  on-call.
- GitHub notifies the maintainer when a report is filed, so reports are *seen* —
  they do not vanish into an unwatched inbox.
- The maintainer will review and respond as soon as they are reasonably able,
  and will keep you informed once they have engaged with the report.
- You will be credited in the published advisory unless you ask not to be.

If that uncertainty is a problem for your environment, it is better to know
before adoption than after — and worth weighing against the fact that the
project is small enough that a report goes directly to the person who can act
on it, with no triage layer in between.

## Disclosure policy

The project follows coordinated disclosure:

1. You report the issue privately.
2. The maintainer confirms it and develops a fix.
3. A disclosure date is agreed with you. The aim is for disclosure to be
   reasonably prompt once a fix exists — the goal is to protect users, not to
   sit on findings — but no specific timeline is committed to in advance.
4. The fix ships in a new chart version, and a GitHub Security Advisory is
   published describing the issue, the affected versions, and the fix, crediting
   the reporter.

If an issue is already being exploited in the wild, the maintainer will move
faster and may disclose alongside the fix rather than waiting.

## Scope

**In scope** — report these here:

- The templates, `values.yaml` defaults and `values.schema.json` in this
  repository, and the manifests they render.
- The release pipeline and the published chart artifact — its signature,
  provenance attestations and the image digests it pins.
- The examples and helper scripts, such as `examples/gen-secrets.sh`.
- Cases where the documentation steers an operator toward an unsafe
  configuration, or where an unsafe configuration is too easy to reach by
  accident — a credential that can end up in a values file or a rendered
  manifest, a NetworkPolicy that admits more than it says, a hardening control
  an override can drop without the render failing. Even if the configuration
  itself is "operator error," a footgun in the docs or defaults is a project
  bug.

**Out of scope** — please report these to the relevant upstream project
instead:

- **SearXNG itself.** This chart deploys SearXNG; it does not fork it.
  Vulnerabilities in SearXNG go to <https://github.com/searxng/searxng>.
- **The relay.** Vulnerabilities in the MCP relay's code or image go to
  <https://github.com/littleoffice/mcp-searxng-relay>.
- **The other images** — Valkey, `redis_exporter`, and the `helm test` image.
  Report those to their publishers. A CVE in a pinned digest that a newer
  digest already fixes is worth a heads-up here, so the pin can move; CI
  should catch it first ([Images](supply-chain.md#images)).
- **Deployment-specific issues** arising from configurations the documentation
  explicitly warns against — for example, exposing a relay instance through an
  Ingress with no `tls` block, or running the NetworkPolicies on a CNI that
  does not enforce them. If the docs told you not to do it, that is not a
  project vulnerability. (But see the in-scope note above: if the docs
  *didn't* warn clearly enough, that gap is in scope.)

## Existing security posture

The chart already addresses several classes of risk by design. A reviewer
evaluating it for a sensitive environment may find the following useful
starting points:

- **Hardening enforced at render time** — non-root users, a read-only root
  filesystem, all capabilities dropped and `RuntimeDefault` seccomp on every
  workload, with the render refused if an override weakens any of them. See
  [Nothing runs as root](security-model.md#nothing-runs-as-root).
- **No credential in values** — every credential comes from a Secret you name
  or is generated straight into one, and the schema rejects the old inline
  fields. See [No credential is ever a values field](security-model.md#no-credential-is-ever-a-values-field).
- **Deny-by-default NetworkPolicies**, with egress to private ranges excluded
  so a compromised pod cannot pivot into the cluster. See
  [Network policies](architecture.md#network-policies).
- **Signed, attested releases** with SBOMs and a scan report per release. See
  [supply-chain.md](supply-chain.md).

Pointing at these is not a claim that the project is free of vulnerabilities —
it is not, no project is. It is context for where the considered effort has
gone, so a reviewer knows what has already been thought about and what has not.
