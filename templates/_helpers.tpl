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

{{- define "searxng.image" -}}
{{- $registry := .Values.image.registry | default "docker.io" -}}
{{- if .Values.image.digest -}}
{{- printf "%s/%s@%s" $registry .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end -}}

{{- define "searxng.valkey.image" -}}
{{- $registry := .Values.valkey.image.registry | default "docker.io" -}}
{{- if .Values.valkey.image.digest -}}
{{- printf "%s/%s@%s" $registry .Values.valkey.image.repository .Values.valkey.image.digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry .Values.valkey.image.repository .Values.valkey.image.tag -}}
{{- end -}}
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
{{- if .Values.searxng.secretKey -}}
{{- .Values.searxng.secretKey -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "searxng.fullname" .) -}}
{{- if and $existing $existing.data (hasKey $existing.data "secret-key") -}}
{{- index $existing.data "secret-key" | b64dec -}}
{{- else -}}
{{- randAlphaNum 64 -}}
{{- end -}}
{{- end -}}
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
{{- if .Values.valkey.auth.password -}}
{{- .Values.valkey.auth.password -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "searxng.valkey.fullname" .) -}}
{{- if and $existing $existing.data (hasKey $existing.data "valkey-password") -}}
{{- index $existing.data "valkey-password" | b64dec -}}
{{- else -}}
{{- randAlphaNum 32 -}}
{{- end -}}
{{- end -}}
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
{{- if and .Values.searxng.baseUrl (regexMatch "\\$\\(" .Values.searxng.baseUrl) }}
{{- fail (printf "searxng.baseUrl contains a $(...) reference (%q). This gets expanded by Kubernetes and corrupts the URL. Use a literal base URL such as https://search.example.com/ with no port variable." .Values.searxng.baseUrl) }}
{{- end }}
{{- $server := .Values.searxng.settings.server | default dict -}}
{{- if hasKey $server "secret_key" -}}
{{- fail "searxng.settings.server.secret_key must not be set: it would be written to a ConfigMap in plain text. Use searxng.secretKey or searxng.existingSecret instead." -}}
{{- end -}}
{{- if hasKey .Values.searxng.settings "valkey" -}}
{{- fail "searxng.settings.valkey must not be set: the connection URL contains the password and is injected from a Secret. Use the valkey.* values instead." -}}
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
{{- $registry := .Values.mcpRelay.image.registry | default "ghcr.io" -}}
{{- if .Values.mcpRelay.image.digest -}}
{{- printf "%s/%s@%s" $registry .Values.mcpRelay.image.repository .Values.mcpRelay.image.digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry .Values.mcpRelay.image.repository .Values.mcpRelay.image.tag -}}
{{- end -}}
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
{{- join "\n" $out -}}
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
{{/* Non-root enforcement                                                */}}
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

{{/* Run every workload in the release through the check. */}}
{{- define "searxng.assertNonRootAll" -}}
{{- include "searxng.assertNonRoot" (dict "name" "searxng" "pod" .Values.podSecurityContext "container" .Values.containerSecurityContext) -}}
{{- if .Values.valkey.enabled -}}
{{- include "searxng.assertNonRoot" (dict "name" "valkey" "pod" .Values.valkey.podSecurityContext "container" .Values.valkey.containerSecurityContext) -}}
{{- end -}}
{{- if .Values.mcpRelay.enabled -}}
{{- include "searxng.assertNonRoot" (dict "name" "mcpRelay" "pod" .Values.mcpRelay.podSecurityContext "container" .Values.mcpRelay.containerSecurityContext) -}}
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
{{- $i := .Values.valkey.metrics.image -}}
{{- if $i.digest -}}
{{- printf "%s/%s@%s" ($i.registry | default "docker.io") $i.repository $i.digest -}}
{{- else -}}
{{- printf "%s/%s:%s" ($i.registry | default "docker.io") $i.repository $i.tag -}}
{{- end -}}
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
settings file — which is why enabling metrics moves settings.yml from a
ConfigMap into a Secret.
*/}}
{{- define "searxng.openMetricsPassword" -}}
{{- if .Values.searxng.metrics.password -}}
{{- .Values.searxng.metrics.password -}}
{{- else -}}
{{- $sec := lookup "v1" "Secret" .Release.Namespace (include "searxng.fullname" .) -}}
{{- $found := "" -}}
{{- if $sec -}}
{{- if $sec.data -}}
{{- if hasKey $sec.data "open-metrics-password" -}}
{{- $found = index $sec.data "open-metrics-password" | b64dec -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $found -}}{{- $found -}}{{- else -}}{{- randAlphaNum 32 -}}{{- end -}}
{{- end -}}
{{- end -}}

{{/* Name of the object holding settings.yml — kind depends on metrics. */}}
{{- define "searxng.settingsObjectName" -}}
{{- printf "%s-settings" (include "searxng.fullname" .) -}}
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
{{- $sec := lookup "v1" "Secret" .Release.Namespace (printf "%s-scrape" (include "searxng.relay.fullname" .)) -}}
{{- $found := "" -}}
{{- if $sec -}}
{{- if $sec.data -}}
{{- if hasKey $sec.data "scrape-token" -}}
{{- $found = index $sec.data "scrape-token" | b64dec -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $found -}}{{- $found -}}{{- else -}}{{- randAlphaNum 64 -}}{{- end -}}
{{- end -}}
