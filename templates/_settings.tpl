{{/*
Body of settings.yml. Rendered into the settings Secret.
*/}}
{{- define "searxng.settingsYaml" -}}
{{- $settings := deepCopy .Values.searxng.settings -}}
{{- if not $settings.engines -}}
{{- $_ := unset $settings "engines" -}}
{{- end -}}
{{- if .Values.mcpRelay.enabled -}}
{{- $search := $settings.search | default dict -}}
{{- $formats := $search.formats | default (list "html") -}}
{{- if not (has "json" $formats) -}}
{{- $formats = append $formats "json" -}}
{{- end -}}
{{- $_ := set $search "formats" $formats -}}
{{- $_ := set $settings "search" $search -}}
{{- end -}}
{{- if .Values.searxng.metrics.enabled -}}
{{- $general := $settings.general | default dict -}}
{{- $_ := set $general "enable_metrics" true -}}
{{- $_ := set $general "open_metrics" (include "searxng.openMetricsPassword" .) -}}
{{- $_ := set $settings "general" $general -}}
{{- end -}}
{{- toYaml $settings -}}
{{- end -}}

{{/* Header comment explaining what the chart injected. */}}
{{- define "searxng.settingsHeader" -}}
# Managed by Helm — do not edit in place.
# This file is rendered into a Secret, never a ConfigMap: engine tokens,
# per-engine api_key fields and proxy credentials have no env-var override
# upstream and can only live here.
# secret_key comes from $SEARXNG_SECRET, valkey.url from $SEARXNG_VALKEY_URL.
{{- if .Values.mcpRelay.enabled }}
# `json` was added to search.formats automatically because mcpRelay is
# enabled; the relay cannot read results without it.
{{- end }}
{{- if .Values.searxng.metrics.enabled }}
# general.open_metrics was injected from searxng.metrics.password; it is the
# HTTP Basic password for /metrics.
{{- end }}
{{- end -}}
