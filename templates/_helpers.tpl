{{/* vim: set filetype=mustache: */}}

{{- define "searxng.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "searxng.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "searxng.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels shared by every object in the release. */}}
{{- define "searxng.labels" -}}
helm.sh/chart: {{ include "searxng.chart" . }}
app.kubernetes.io/name: {{ include "searxng.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- with .Chart.AppVersion }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
app.kubernetes.io/part-of: searxng
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Selector for the SearXNG server pods. */}}
{{- define "searxng.selectorLabels" -}}
app.kubernetes.io/name: {{ include "searxng.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: server
{{- end -}}

{{- define "searxng.serverLabels" -}}
{{ include "searxng.labels" . }}
app.kubernetes.io/component: server
{{- end -}}

{{- define "searxng.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "searxng.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* ------------------------------------------------------------------ */}}
{{/* Images                                                              */}}
{{/* ------------------------------------------------------------------ */}}

{{/*
One image reference, built one way, for every image in the chart.

Every workload here is pinned the same way and reads the same three keys, so
the construction lives in one place rather than being spelled out per call
site. The test pod used to interpolate `registry/repository:tag` inline, which
is how it ended up as the only image in the chart that could not be pinned by
digest at all.

Digest wins over tag when both are set — that is the ordering the image blocks
already document. `defaultTag` is the per-image fallback for when neither is
given; only the SearXNG image has a meaningful one (.Chart.AppVersion), and the
rest pass nothing, so a missing pin fails at render rather than resolving to
something arbitrary.

Call with:
  (dict "name" "<values path>" "img" <the image map> "registry" "<default>" "tag" "<default>")
*/}}
{{- define "searxng.imageRef" -}}
{{- $img := .img -}}
{{- $registry := $img.registry | default .registry -}}
{{- $ref := $img.repository -}}
{{- if $registry -}}
{{- $ref = printf "%s/%s" $registry $img.repository -}}
{{- end -}}
{{- if $img.digest -}}
{{- printf "%s@%s" $ref $img.digest -}}
{{- else -}}
{{- $tag := $img.tag | default .tag -}}
{{- if not $tag -}}
{{- fail (printf "%s: neither .digest nor .tag is set, and there is no default for this image. Pin it." .name) -}}
{{- end -}}
{{- printf "%s:%s" $ref $tag -}}
{{- end -}}
{{- end -}}

{{/*
Reject a malformed digest at render time. A typo in a 64-character hex string
is otherwise invisible until a pod sits in ImagePullBackOff with an error that
names the image but not the values key that produced it.
*/}}
{{- define "searxng.validateImages" -}}
{{- $images := list
      (dict "name" "image" "img" .Values.image)
      (dict "name" "tests.image" "img" .Values.tests.image) -}}
{{- if .Values.valkey.enabled -}}
{{- $images = append $images (dict "name" "valkey.image" "img" .Values.valkey.image) -}}
{{- if .Values.valkey.metrics.enabled -}}
{{- $images = append $images (dict "name" "valkey.metrics.image" "img" .Values.valkey.metrics.image) -}}
{{- end -}}
{{- end -}}
{{- if .Values.mcpRelay.enabled -}}
{{- $images = append $images (dict "name" "mcpRelay.image" "img" .Values.mcpRelay.image) -}}
{{- end -}}
{{- range $images -}}
{{/* Bind the name before `with` rebinds the dot to the digest string. */}}
{{- $key := .name -}}
{{- with .img.digest -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" .) -}}
{{- fail (printf "%s.digest is not a well-formed digest (%q). Expected \"sha256:\" followed by 64 lowercase hex characters." $key .) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "searxng.image" -}}
{{- include "searxng.imageRef" (dict "name" "image" "img" .Values.image "registry" "docker.io" "tag" .Chart.AppVersion) -}}
{{- end -}}

{{- define "searxng.valkey.image" -}}
{{- include "searxng.imageRef" (dict "name" "valkey.image" "img" .Values.valkey.image "registry" "docker.io") -}}
{{- end -}}

{{/* ------------------------------------------------------------------ */}}
{{/* Valkey names / labels                                               */}}
{{/* ------------------------------------------------------------------ */}}

{{- define "searxng.valkey.fullname" -}}
{{- printf "%s-valkey" (include "searxng.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "searxng.valkey.selectorLabels" -}}
app.kubernetes.io/name: {{ include "searxng.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: valkey
{{- end -}}

{{- define "searxng.valkey.labels" -}}
{{ include "searxng.labels" . }}
app.kubernetes.io/component: valkey
{{- end -}}

{{/* ------------------------------------------------------------------ */}}
{{/* Secrets                                                             */}}
{{/* ------------------------------------------------------------------ */}}

{{/*
Generated credentials are memoised for the lifetime of one render pass.

`.Values` is the same map for every template in a release, so a key written
into it is visible to every later `include` in the same install/upgrade/template
run, and is gone by the next one. That is exactly the lifetime a generated
credential needs, and the reason each helper below writes through
`.Values.__memo` instead of recomputing.

Without it a helper that falls through to `randAlphaNum` returns a *different*
value on every call, and several of these are legitimately called more than
once per render: once to populate the Secret, and again when a Deployment
re-renders the same template to hash it into a `checksum/` annotation. The two
copies then disagree. Where the value also lands in two different places — the
open-metrics password goes into settings.yml *and* into its own key, the relay
scrape token into the token file *and* into its own Secret — the disagreement
is a silent authentication failure rather than a visible error.

The key is `__memo` at the root of `.Values` and deliberately not under
`.Values.searxng`, so `deepCopy .Values.searxng.settings` in
searxng.settingsYaml cannot pick it up and emit it into settings.yml. Nothing
in this chart serialises `.Values` wholesale.
*/}}

{{- define "searxng.secretName" -}}
{{- if .Values.searxng.existingSecret -}}
{{- .Values.searxng.existingSecret -}}
{{- else -}}
{{- include "searxng.fullname" . -}}
{{- end -}}
{{- end -}}

{{- define "searxng.secretKeyRefKey" -}}
{{- if .Values.searxng.existingSecret -}}
{{- .Values.searxng.existingSecretKey -}}
{{- else -}}
secret-key
{{- end -}}
{{- end -}}

{{/*
Resolve the SearXNG secret_key.
Order: explicit value > value already stored in the cluster > freshly generated.
The lookup keeps the key stable across `helm upgrade`. It returns nothing during
`helm template`/`--dry-run`, so GitOps tooling must use `existingSecret`.
*/}}
{{- define "searxng.secretKeyValue" -}}
{{- if not (hasKey .Values "__memo") -}}{{- $_ := set .Values "__memo" dict -}}{{- end -}}
{{- $memo := index .Values "__memo" -}}
{{- if not (hasKey $memo "secretKey") -}}
{{- $value := .Values.searxng.secretKey -}}
{{- if not $value -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "searxng.fullname" .) -}}
{{- if and $existing $existing.data (hasKey $existing.data "secret-key") -}}
{{- $value = index $existing.data "secret-key" | b64dec -}}
{{- end -}}
{{- end -}}
{{- if not $value -}}{{- $value = randAlphaNum 64 -}}{{- end -}}
{{- $_ := set $memo "secretKey" $value -}}
{{- end -}}
{{- index $memo "secretKey" -}}
{{- end -}}

{{- define "searxng.valkey.secretName" -}}
{{- if .Values.valkey.enabled -}}
{{- if .Values.valkey.auth.existingSecret -}}
{{- .Values.valkey.auth.existingSecret -}}
{{- else -}}
{{- include "searxng.valkey.fullname" . -}}
{{- end -}}
{{- else -}}
{{- .Values.valkey.external.existingSecret -}}
{{- end -}}
{{- end -}}

{{- define "searxng.valkey.secretPasswordKey" -}}
{{- if .Values.valkey.auth.existingSecret -}}
{{- .Values.valkey.auth.existingSecretPasswordKey -}}
{{- else -}}
valkey-password
{{- end -}}
{{- end -}}

{{/* Resolve the Valkey password, preserving any already in the cluster. */}}
{{- define "searxng.valkey.passwordValue" -}}
{{- if not (hasKey .Values "__memo") -}}{{- $_ := set .Values "__memo" dict -}}{{- end -}}
{{- $memo := index .Values "__memo" -}}
{{- if not (hasKey $memo "valkeyPassword") -}}
{{- $value := .Values.valkey.auth.password -}}
{{- if not $value -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "searxng.valkey.fullname" .) -}}
{{- if and $existing $existing.data (hasKey $existing.data "valkey-password") -}}
{{- $value = index $existing.data "valkey-password" | b64dec -}}
{{- end -}}
{{- end -}}
{{- if not $value -}}{{- $value = randAlphaNum 32 -}}{{- end -}}
{{- $_ := set $memo "valkeyPassword" $value -}}
{{- end -}}
{{- index $memo "valkeyPassword" -}}
{{- end -}}

{{/* Headless service DNS name SearXNG connects to (always the primary). */}}
{{- define "searxng.valkey.host" -}}
{{- include "searxng.valkey.primaryHost" . -}}
{{- end -}}

{{/* ------------------------------------------------------------------ */}}
{{/* Derived application settings                                        */}}
{{/* ------------------------------------------------------------------ */}}

{{/* True when the limiter (and therefore Valkey) is required. */}}
{{- define "searxng.limiterEnabled" -}}
{{- $server := .Values.searxng.settings.server | default dict -}}
{{- if or $server.limiter $server.public_instance -}}true{{- end -}}
{{- end -}}

{{/* Public base URL: explicit value, else derived from the first ingress host. */}}
{{- define "searxng.baseUrl" -}}
{{- if .Values.searxng.baseUrl -}}
{{- .Values.searxng.baseUrl -}}
{{- else if and .Values.ingress.enabled .Values.ingress.hosts -}}
{{- $host := (first .Values.ingress.hosts).host -}}
{{- $scheme := "http" -}}
{{- range .Values.ingress.tls -}}
{{- if has $host .hosts -}}{{- $scheme = "https" -}}{{- end -}}
{{- end -}}
{{- printf "%s://%s/" $scheme $host -}}
{{- end -}}
{{- end -}}

{{/*
Guard rails: fail loudly rather than silently doing something insecure or
producing a pod that cannot start.
*/}}
{{- define "searxng.validate" -}}
{{- include "searxng.validateImages" . -}}
{{- if and .Values.searxng.baseUrl (regexMatch "\\$\\(" .Values.searxng.baseUrl) }}
{{- fail (printf "searxng.baseUrl contains a $(...) reference (%q). This gets expanded by Kubernetes and corrupts the URL. Use a literal base URL such as https://search.example.com/ with no port variable." .Values.searxng.baseUrl) }}
{{- end }}
{{- $server := .Values.searxng.settings.server | default dict -}}
{{- if hasKey $server "secret_key" -}}
{{- fail "searxng.settings.server.secret_key must not be set: it is injected as $SEARXNG_SECRET from a dedicated Secret, so a copy here would only add a second place to rotate and leak from. Use searxng.secretKey or searxng.existingSecret instead." -}}
{{- end -}}
{{- if hasKey .Values.searxng.settings "valkey" -}}
{{- fail "searxng.settings.valkey must not be set: the connection URL contains the password and is injected from a Secret. Use the valkey.* values instead." -}}
{{- end -}}
{{- if include "searxng.externalSettings" . -}}
{{- if not .Values.searxng.existingSettingsSecretKey -}}
{{- fail "searxng.existingSettingsSecretKey must not be empty when searxng.existingSettingsSecret is set: the chart has to know which key of your Secret to mount at /etc/searxng/settings.yml." -}}
{{- end -}}
{{- if and (include "searxng.metricsEnabled" .) (not .Values.searxng.metrics.password) -}}
{{- fail "searxng.metrics.enabled is true with searxng.existingSettingsSecret set, but searxng.metrics.password is empty. general.open_metrics has no env-var override, so it can only come from your settings.yml — which the chart cannot read or edit. A generated password would be written into the ServiceMonitor's basicAuth and match nothing, so every scrape would 401. Set general.enable_metrics: true and general.open_metrics: <password> in your own settings.yml and put the same password in searxng.metrics.password." -}}
{{- end -}}
{{- end -}}
{{- if and (include "searxng.limiterEnabled" .) (not .Values.valkey.enabled) (not .Values.valkey.external.url) (not .Values.valkey.external.existingSecret) -}}
{{- fail "The limiter / public_instance requires Valkey. Set valkey.enabled=true or provide valkey.external.url." -}}
{{- end -}}
{{- if and .Values.podDisruptionBudget.enabled .Values.podDisruptionBudget.minAvailable .Values.podDisruptionBudget.maxUnavailable -}}
{{- fail "Set only one of podDisruptionBudget.minAvailable or podDisruptionBudget.maxUnavailable." -}}
{{- end -}}
{{- if .Values.valkey.enabled -}}
{{- if not (has .Values.valkey.architecture (list "standalone" "replication")) -}}
{{- fail (printf "valkey.architecture must be \"standalone\" or \"replication\", got %q." .Values.valkey.architecture) -}}
{{- end -}}
{{- if and (eq .Values.valkey.architecture "replication") (lt (int .Values.valkey.replica.count) 1) -}}
{{- fail "valkey.architecture is \"replication\" but valkey.replica.count is less than 1." -}}
{{- end -}}
{{- if and (eq .Values.valkey.architecture "replication") (not .Values.valkey.auth.enabled) -}}
{{- fail "valkey replication requires auth: replicas authenticate to the primary with masterauth. Set valkey.auth.enabled=true." -}}
{{- end -}}
{{- end -}}
{{- if .Values.metrics.serviceMonitor.enabled -}}
{{- if not (or (include "searxng.metricsEnabled" .) (and .Values.mcpRelay.enabled .Values.mcpRelay.metrics.enabled) (and .Values.valkey.enabled .Values.valkey.metrics.enabled)) -}}
{{- fail "metrics.serviceMonitor.enabled is true but no component exposes metrics. Enable at least one of searxng.metrics.enabled, mcpRelay.metrics.enabled, valkey.metrics.enabled." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* ------------------------------------------------------------------ */}}
{{/* MCP relay                                                           */}}
{{/* ------------------------------------------------------------------ */}}

{{- define "searxng.relay.fullname" -}}
{{- printf "%s-mcp-relay" (include "searxng.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "searxng.relay.selectorLabels" -}}
app.kubernetes.io/name: {{ include "searxng.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: mcp-relay
{{- end -}}

{{- define "searxng.relay.labels" -}}
{{ include "searxng.labels" . }}
app.kubernetes.io/component: mcp-relay
{{- end -}}

{{- define "searxng.relay.image" -}}
{{- include "searxng.imageRef" (dict "name" "mcpRelay.image" "img" .Values.mcpRelay.image "registry" "ghcr.io") -}}
{{- end -}}

{{/* The helm test pod. Same three keys, same helper as every other image. */}}
{{- define "searxng.tests.image" -}}
{{- include "searxng.imageRef" (dict "name" "tests.image" "img" .Values.tests.image "registry" "docker.io") -}}
{{- end -}}

{{- define "searxng.relay.serviceAccountName" -}}
{{- if .Values.mcpRelay.serviceAccount.create -}}
{{- default (include "searxng.relay.fullname" .) .Values.mcpRelay.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.mcpRelay.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "searxng.relay.secretName" -}}
{{- if .Values.mcpRelay.auth.existingSecret -}}
{{- .Values.mcpRelay.auth.existingSecret -}}
{{- else -}}
{{- include "searxng.relay.fullname" . -}}
{{- end -}}
{{- end -}}

{{- define "searxng.relay.secretKey" -}}
{{- if .Values.mcpRelay.auth.existingSecret -}}
{{- .Values.mcpRelay.auth.existingSecretKey -}}
{{- else -}}
tokens
{{- end -}}
{{- end -}}

{{/*
Build the `identity:token` token file.
Tokens already present in the cluster are reused so that upgrading the chart
does not invalidate every configured MCP client.
*/}}
{{- define "searxng.relay.tokenFile" -}}
{{- if not (hasKey .Values "__memo") -}}{{- $_ := set .Values "__memo" dict -}}{{- end -}}
{{- $memo := index .Values "__memo" -}}
{{- if not (hasKey $memo "relayTokenFile") -}}
{{- $existingRaw := "" -}}
{{- $sec := lookup "v1" "Secret" .Release.Namespace (include "searxng.relay.fullname" .) -}}
{{- if $sec -}}
{{- if $sec.data -}}
{{- if hasKey $sec.data "tokens" -}}
{{- $existingRaw = index $sec.data "tokens" | b64dec -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $known := dict -}}
{{- range (splitList "\n" $existingRaw) -}}
{{- $line := trim . -}}
{{- if and $line (not (hasPrefix "#" $line)) -}}
{{- $parts := splitn ":" 2 $line -}}
{{- $_ := set $known $parts._0 $parts._1 -}}
{{- end -}}
{{- end -}}
{{- $out := list "# Managed by Helm. Each line is identity:token." -}}
{{- range .Values.mcpRelay.auth.identities -}}
{{- $token := .token -}}
{{- if not $token -}}
{{- $token = index $known .name | default (randAlphaNum 64) -}}
{{- end -}}
{{- $out = append $out (printf "%s:%s" .name $token) -}}
{{- end -}}
{{- if .Values.mcpRelay.metrics.enabled -}}
{{- $out = append $out (printf "%s:%s" (include "searxng.relay.scrapeIdentity" .) (include "searxng.relay.scrapeToken" .)) -}}
{{- end -}}
{{- $_ := set $memo "relayTokenFile" (join "\n" $out) -}}
{{- end -}}
{{- index $memo "relayTokenFile" -}}
{{- end -}}

{{/*
Name and key of the Secret holding the SearXNG private-engine tokens.
Kept separate from the agent token file so read access to one does not imply
read access to the other.
*/}}
{{- define "searxng.relay.engineTokensSecretName" -}}
{{- if .Values.mcpRelay.searxngTokens.existingSecret -}}
{{- .Values.mcpRelay.searxngTokens.existingSecret -}}
{{- else -}}
{{- printf "%s-engine-tokens" (include "searxng.relay.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "searxng.relay.engineTokensSecretKey" -}}
{{- if .Values.mcpRelay.searxngTokens.existingSecret -}}
{{- .Values.mcpRelay.searxngTokens.existingSecretKey -}}
{{- else -}}
searxng-tokens
{{- end -}}
{{- end -}}

{{/* Whether SEARXNG_TOKENS should be injected at all. */}}
{{- define "searxng.relay.engineTokensEnabled" -}}
{{- if or .Values.mcpRelay.searxngTokens.existingSecret .Values.mcpRelay.searxngTokens.tokens -}}
true
{{- end -}}
{{- end -}}

{{/* Comma-separated token list, as the relay expects SEARXNG_TOKENS. */}}
{{- define "searxng.relay.engineTokens" -}}
{{- join "," .Values.mcpRelay.searxngTokens.tokens -}}
{{- end -}}

{{/* URL of the in-cluster SearXNG service, as the relay should reach it. */}}
{{- define "searxng.relay.searxngUrl" -}}
{{- printf "http://%s.%s.svc:%v" (include "searxng.fullname" .) .Release.Namespace .Values.service.port -}}
{{- end -}}

{{/* Validation specific to the relay. */}}
{{- define "searxng.relay.validate" -}}
{{- if .Values.mcpRelay.enabled -}}
{{- if not (or .Values.mcpRelay.auth.existingSecret .Values.mcpRelay.auth.identities) -}}
{{- fail "mcpRelay: at least one auth identity is required. Set mcpRelay.auth.identities or mcpRelay.auth.existingSecret." -}}
{{- end -}}
{{- range .Values.mcpRelay.auth.identities -}}
{{- if contains ":" .name -}}
{{- fail (printf "mcpRelay: identity name %q must not contain a colon." .name) -}}
{{- end -}}
{{- if and .token (lt (len .token) 32) -}}
{{- fail (printf "mcpRelay: token for identity %q is shorter than the 32 character minimum." .name) -}}
{{- end -}}
{{- end -}}
{{- if and .Values.mcpRelay.metrics.enabled .Values.mcpRelay.metrics.existingSecret (not .Values.mcpRelay.auth.existingSecret) -}}
{{- fail "mcpRelay: metrics.existingSecret is set but auth.existingSecret is not. The relay authenticates every request against one token file, /metrics included, so the scrape token has to appear both in your Secret and on a `prometheus` line in the token file — and the chart cannot read your Secret to copy it there. Either manage both externally (see examples/gen-secrets.sh) or let the chart manage both." -}}
{{- end -}}
{{- if and .Values.mcpRelay.searxngTokens.existingSecret .Values.mcpRelay.searxngTokens.tokens -}}
{{- fail "mcpRelay.searxngTokens: set either .tokens or .existingSecret, not both." -}}
{{- end -}}
{{- range .Values.mcpRelay.searxngTokens.tokens -}}
{{- if contains "," . -}}
{{- fail "mcpRelay.searxngTokens.tokens: a token must not contain a comma; the list is joined into a comma-separated SEARXNG_TOKENS." -}}
{{- end -}}
{{- if ne . (trim .) -}}
{{- fail "mcpRelay.searxngTokens.tokens: a token must not have leading or trailing whitespace." -}}
{{- end -}}
{{- end -}}
{{- if and .Values.mcpRelay.ingress.enabled (not .Values.mcpRelay.ingress.hosts) -}}
{{- fail "mcpRelay.ingress.enabled is true but mcpRelay.ingress.hosts is empty." -}}
{{- end -}}
{{- end -}}
{{- if and .Values.ingress.enabled (not .Values.ingress.hosts) -}}
{{- fail "ingress.enabled is true but ingress.hosts is empty." -}}
{{- end -}}
{{- end -}}

{{/*
Build a NetworkPolicy `from` list out of allowSameNamespace + fromNamespaces +
raw from entries.
Call with (dict "ctx" . "cfg" <the .networkPolicy.ingress map>).
*/}}
{{- define "searxng.netpolFrom" -}}
{{- $cfg := .cfg -}}
{{- $from := list -}}
{{- if $cfg.allowSameNamespace -}}
{{- $from = append $from (dict "podSelector" (dict)) -}}
{{- end -}}
{{- range ($cfg.fromNamespaces | default list) -}}
{{- $from = append $from (dict "namespaceSelector" (dict "matchLabels" (dict "kubernetes.io/metadata.name" .))) -}}
{{- end -}}
{{- $from = concat $from ($cfg.from | default list) -}}
{{- toYaml $from -}}
{{- end -}}

{{/* ------------------------------------------------------------------ */}}
{{/* Security context enforcement                                        */}}
{{/* ------------------------------------------------------------------ */}}

{{/*
Refuse to render if any workload could run as, or be grouped as, uid/gid 0.
This is a chart-level backstop: the cluster already rejects a root *process*
via runAsNonRoot, but nothing stops someone overriding runAsUser to 0 in a
values file, so we catch it before it reaches the API server.
Call with (dict "name" "<workload>" "pod" <podSecurityContext> "container" <containerSecurityContext>).
*/}}
{{- define "searxng.assertNonRoot" -}}
{{- $name := .name -}}
{{- $pod := .pod | default dict -}}
{{- $ctr := .container | default dict -}}
{{- range $f := list "runAsUser" "runAsGroup" "fsGroup" -}}
{{- if not (hasKey $pod $f) -}}
{{- fail (printf "%s: podSecurityContext.%s must be set explicitly — this chart never runs or groups anything as root." $name $f) -}}
{{- end -}}
{{- if eq (int (index $pod $f)) 0 -}}
{{- fail (printf "%s: podSecurityContext.%s is 0 (root). Set a non-zero id." $name $f) -}}
{{- end -}}
{{- end -}}
{{- range $f := list "runAsUser" "runAsGroup" -}}
{{- if not (hasKey $ctr $f) -}}
{{- fail (printf "%s: containerSecurityContext.%s must be set explicitly." $name $f) -}}
{{- end -}}
{{- if eq (int (index $ctr $f)) 0 -}}
{{- fail (printf "%s: containerSecurityContext.%s is 0 (root). Set a non-zero id." $name $f) -}}
{{- end -}}
{{- end -}}
{{- range $sg := ($pod.supplementalGroups | default list) -}}
{{- if eq (int $sg) 0 -}}
{{- fail (printf "%s: podSecurityContext.supplementalGroups contains 0 (root group)." $name) -}}
{{- end -}}
{{- end -}}
{{- if not $pod.runAsNonRoot -}}
{{- fail (printf "%s: podSecurityContext.runAsNonRoot must be true." $name) -}}
{{- end -}}
{{- if not $ctr.runAsNonRoot -}}
{{- fail (printf "%s: containerSecurityContext.runAsNonRoot must be true." $name) -}}
{{- end -}}
{{- end -}}

{{/*
The rest of the hardening the README promises, on the same terms as the root
check above: refuse to render rather than leave it to an admission controller
that may not be installed.

Root was singled out first because it is the one people override deliberately.
These are the ones people lose by accident — a securityContext copied from
somewhere else, or a block rewritten to add one field and dropped the others.
Every control in the "Security posture" table is asserted here, so the table
cannot quietly stop being true.

Call with (dict "name" "<workload>" "pod" <podSecurityContext> "container" <containerSecurityContext>).
*/}}
{{- define "searxng.assertHardened" -}}
{{- $name := .name -}}
{{- $pod := .pod | default dict -}}
{{- $ctr := .container | default dict -}}
{{- include "searxng.assertNonRoot" . -}}
{{- if $ctr.privileged -}}
{{- fail (printf "%s: containerSecurityContext.privileged is true. Nothing in this chart needs it." $name) -}}
{{- end -}}
{{- if not (hasKey $ctr "allowPrivilegeEscalation") -}}
{{- fail (printf "%s: containerSecurityContext.allowPrivilegeEscalation must be set explicitly." $name) -}}
{{- end -}}
{{- if $ctr.allowPrivilegeEscalation -}}
{{- fail (printf "%s: containerSecurityContext.allowPrivilegeEscalation is true." $name) -}}
{{- end -}}
{{- if not $ctr.readOnlyRootFilesystem -}}
{{- fail (printf "%s: containerSecurityContext.readOnlyRootFilesystem must be true. Everything these containers write to is a mounted emptyDir." $name) -}}
{{- end -}}
{{- $caps := $ctr.capabilities | default dict -}}
{{- if not (has "ALL" ($caps.drop | default list)) -}}
{{- fail (printf "%s: containerSecurityContext.capabilities.drop must contain \"ALL\"." $name) -}}
{{- end -}}
{{- with $caps.add -}}
{{- fail (printf "%s: containerSecurityContext.capabilities.add is set (%v). This chart adds no capabilities." $name .) -}}
{{- end -}}
{{/*
A container without a profile of its own inherits the pod's, so this is
satisfied by either. Checking the container alone would reject a perfectly
valid config that sets it once at pod level.
*/}}
{{- $seccomp := $ctr.seccompProfile | default $pod.seccompProfile | default dict -}}
{{- if not (has ($seccomp.type | default "") (list "RuntimeDefault" "Localhost")) -}}
{{- fail (printf "%s: seccompProfile.type must be RuntimeDefault or Localhost, on the pod or the container. Got %q." $name ($seccomp.type | default "<unset>")) -}}
{{- end -}}
{{- end -}}

{{/* Run every workload in the release through the checks. */}}
{{- define "searxng.assertHardenedAll" -}}
{{- include "searxng.assertHardened" (dict "name" "searxng" "pod" .Values.podSecurityContext "container" .Values.containerSecurityContext) -}}
{{- if .Values.valkey.enabled -}}
{{- include "searxng.assertHardened" (dict "name" "valkey" "pod" .Values.valkey.podSecurityContext "container" .Values.valkey.containerSecurityContext) -}}
{{/*
The exporter sidecar shares the pod's securityContext but carries its own
container one, and was not covered by the root check at all.
*/}}
{{- if .Values.valkey.metrics.enabled -}}
{{- include "searxng.assertHardened" (dict "name" "valkey.metrics" "pod" .Values.valkey.podSecurityContext "container" .Values.valkey.metrics.containerSecurityContext) -}}
{{- end -}}
{{- end -}}
{{- if .Values.mcpRelay.enabled -}}
{{- include "searxng.assertHardened" (dict "name" "mcpRelay" "pod" .Values.mcpRelay.podSecurityContext "container" .Values.mcpRelay.containerSecurityContext) -}}
{{- end -}}
{{- end -}}

{{/*
Annotations, with every value coerced to a string.
Kubernetes rejects non-string annotation values, and it is very easy to write
`nginx.ingress.kubernetes.io/proxy-read-timeout: 300` in a values file and have
YAML hand Helm an integer. Quoting here means such values just work.
*/}}
{{- define "searxng.renderAnnotations" -}}
{{- $lines := list -}}
{{- range $k, $v := . -}}
{{- $lines = append $lines (printf "%s: %s" $k ($v | quote)) -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{/* ------------------------------------------------------------------ */}}
{{/* Valkey primary / replica                                            */}}
{{/* ------------------------------------------------------------------ */}}

{{- define "searxng.valkey.primaryName" -}}
{{- printf "%s-primary" (include "searxng.valkey.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "searxng.valkey.replicaName" -}}
{{- printf "%s-replica" (include "searxng.valkey.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "searxng.valkey.primarySelectorLabels" -}}
app.kubernetes.io/name: {{ include "searxng.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: valkey-primary
{{- end -}}

{{- define "searxng.valkey.replicaSelectorLabels" -}}
app.kubernetes.io/name: {{ include "searxng.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: valkey-replica
{{- end -}}

{{- define "searxng.valkey.primaryLabels" -}}
{{ include "searxng.labels" . }}
app.kubernetes.io/component: valkey-primary
{{- end -}}

{{- define "searxng.valkey.replicaLabels" -}}
{{ include "searxng.labels" . }}
app.kubernetes.io/component: valkey-replica
{{- end -}}

{{- define "searxng.valkey.replicationEnabled" -}}
{{- if and .Values.valkey.enabled (eq .Values.valkey.architecture "replication") -}}true{{- end -}}
{{- end -}}

{{/* FQDN SearXNG writes to. Always the primary — the client has no failover. */}}
{{- define "searxng.valkey.primaryHost" -}}
{{- printf "%s.%s.svc" (include "searxng.valkey.primaryName" .) .Release.Namespace -}}
{{- end -}}

{{- define "searxng.valkey.exporterImage" -}}
{{- include "searxng.imageRef" (dict "name" "valkey.metrics.image" "img" .Values.valkey.metrics.image "registry" "docker.io") -}}
{{- end -}}

{{/* ------------------------------------------------------------------ */}}
{{/* Metrics                                                             */}}
{{/* ------------------------------------------------------------------ */}}

{{- define "searxng.metricsEnabled" -}}
{{- if .Values.searxng.metrics.enabled -}}true{{- end -}}
{{- end -}}

{{/*
SearXNG's OpenMetrics endpoint is gated by a password in general.open_metrics.
There is no environment-variable override for it, so it has to live in the
settings file. settings.yml is a Secret in all cases, so there is nowhere for
this to leak to.
*/}}
{{- define "searxng.openMetricsPassword" -}}
{{- if not (hasKey .Values "__memo") -}}{{- $_ := set .Values "__memo" dict -}}{{- end -}}
{{- $memo := index .Values "__memo" -}}
{{- if not (hasKey $memo "openMetricsPassword") -}}
{{- $value := .Values.searxng.metrics.password -}}
{{- if not $value -}}
{{/*
Look this up on the settings Secret, which is where it is written. It used to
look on searxng.fullname — the secret_key object — where the key has never
existed, so the lookup could never hit and a new password was minted on every
render.
*/}}
{{- $sec := lookup "v1" "Secret" .Release.Namespace (include "searxng.settingsSecretName" .) -}}
{{- if $sec -}}
{{- if $sec.data -}}
{{- if hasKey $sec.data "open-metrics-password" -}}
{{- $value = index $sec.data "open-metrics-password" | b64dec -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if not $value -}}{{- $value = randAlphaNum 32 -}}{{- end -}}
{{- $_ := set $memo "openMetricsPassword" $value -}}
{{- end -}}
{{- index $memo "openMetricsPassword" -}}
{{- end -}}

{{/*
Name of the Secret this chart renders. It holds settings.yml unless
searxng.existingSettingsSecret is set, and the open-metrics basic-auth keys
whenever metrics are on — in both cases. Keep lookups and the ServiceMonitor
pointed here rather than at settingsObjectName: those keys are chart-managed
even when the settings file is not, and an external Secret has no reason to
carry them.
*/}}
{{- define "searxng.settingsSecretName" -}}
{{- printf "%s-settings" (include "searxng.fullname" .) -}}
{{- end -}}

{{/* True when settings.yml comes from a Secret the user manages. */}}
{{- define "searxng.externalSettings" -}}
{{- if .Values.searxng.existingSettingsSecret -}}true{{- end -}}
{{- end -}}

{{/* True when the chart has anything to put in its own settings Secret. */}}
{{- define "searxng.settingsSecretRendered" -}}
{{- if or (not (include "searxng.externalSettings" .)) (include "searxng.metricsEnabled" .) -}}true{{- end -}}
{{- end -}}

{{/* Name of the Secret settings.yml is actually mounted from. */}}
{{- define "searxng.settingsObjectName" -}}
{{- if include "searxng.externalSettings" . -}}
{{- .Values.searxng.existingSettingsSecret -}}
{{- else -}}
{{- include "searxng.settingsSecretName" . -}}
{{- end -}}
{{- end -}}

{{/*
Key inside that Secret. Projected to the fixed path settings.yml on mount, so
an external Secret is free to name its key anything.
*/}}
{{- define "searxng.settingsObjectKey" -}}
{{- if include "searxng.externalSettings" . -}}
{{- .Values.searxng.existingSettingsSecretKey -}}
{{- else -}}
settings.yml
{{- end -}}
{{- end -}}

{{/* Dedicated scrape identity so Prometheus never uses a human's token. */}}
{{- define "searxng.relay.scrapeIdentity" -}}prometheus{{- end -}}

{{- define "searxng.relay.scrapeSecretName" -}}
{{- if .Values.mcpRelay.metrics.existingSecret -}}
{{- .Values.mcpRelay.metrics.existingSecret -}}
{{- else -}}
{{- printf "%s-scrape" (include "searxng.relay.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "searxng.relay.scrapeSecretKey" -}}
{{- if .Values.mcpRelay.metrics.existingSecret -}}
{{- .Values.mcpRelay.metrics.existingSecretKey -}}
{{- else -}}
scrape-token
{{- end -}}
{{- end -}}

{{- define "searxng.relay.scrapeToken" -}}
{{- if not (hasKey .Values "__memo") -}}{{- $_ := set .Values "__memo" dict -}}{{- end -}}
{{- $memo := index .Values "__memo" -}}
{{- if not (hasKey $memo "relayScrapeToken") -}}
{{- $value := "" -}}
{{/*
Resolve the object and key through the same helpers the Secret itself uses,
rather than hardcoding "<relay>-scrape" / "scrape-token". Hardcoding meant that
with metrics.existingSecret set the lookup missed and a fresh token was minted
into the token file, which is not the one Prometheus presents.
*/}}
{{- $name := include "searxng.relay.scrapeSecretName" . -}}
{{- $key := include "searxng.relay.scrapeSecretKey" . -}}
{{- $sec := lookup "v1" "Secret" .Release.Namespace $name -}}
{{- if $sec -}}
{{- if $sec.data -}}
{{- if hasKey $sec.data $key -}}
{{- $value = index $sec.data $key | b64dec -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if not $value -}}{{- $value = randAlphaNum 64 -}}{{- end -}}
{{- $_ := set $memo "relayScrapeToken" $value -}}
{{- end -}}
{{- index $memo "relayScrapeToken" -}}
{{- end -}}
