{{/*
Body of settings.yml. Shared by the ConfigMap and Secret variants so the two
cannot drift.
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
# secret_key comes from $SEARXNG_SECRET, valkey.url from $SEARXNG_VALKEY_URL.
{{- if .Values.mcpRelay.enabled }}
# `json` was added to search.formats automatically because mcpRelay is
# enabled; the relay cannot read results without it.
{{- end }}
{{- if .Values.searxng.metrics.enabled }}
# general.open_metrics holds the /metrics basic-auth password, which is why
# this file is a Secret rather than a ConfigMap.
{{- end }}
{{- end -}}
