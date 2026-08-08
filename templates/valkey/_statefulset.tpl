{{/*
Shared Valkey StatefulSet body.
Call with (dict "ctx" $ "role" "primary"|"replica").
Keeping both roles in one define means the security context, exporter sidecar
and probe wiring cannot drift apart between them.
*/}}
{{- define "searxng.valkey.statefulset" -}}
{{- $ctx := .ctx -}}
{{- $role := .role -}}
{{- $v := $ctx.Values.valkey -}}
{{- $isReplica := eq $role "replica" -}}
{{- $name := ternary (include "searxng.valkey.replicaName" $ctx) (include "searxng.valkey.primaryName" $ctx) $isReplica -}}
{{- $labels := ternary (include "searxng.valkey.replicaLabels" $ctx) (include "searxng.valkey.primaryLabels" $ctx) $isReplica -}}
{{- $selector := ternary (include "searxng.valkey.replicaSelectorLabels" $ctx) (include "searxng.valkey.primarySelectorLabels" $ctx) $isReplica -}}
{{- $confKey := ternary "valkey-replica.conf" "valkey.conf" $isReplica -}}
{{- $replicas := ternary $v.replica.count 1 $isReplica -}}
{{- $resources := ternary $v.replica.resources $v.resources $isReplica -}}
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ $name }}
  namespace: {{ $ctx.Release.Namespace }}
  labels:
    {{- $labels | nindent 4 }}
  {{- with $ctx.Values.commonAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  replicas: {{ $replicas }}
  serviceName: {{ $name }}
  revisionHistoryLimit: {{ $ctx.Values.revisionHistoryLimit }}
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      {{- $selector | nindent 6 }}
  template:
    metadata:
      annotations:
        checksum/config: {{ include (print $ctx.Template.BasePath "/valkey/secret.yaml") $ctx | sha256sum }}
        {{- with $ctx.Values.commonAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      labels:
        {{- $labels | nindent 8 }}
    spec:
      {{- with $ctx.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      automountServiceAccountToken: false
      enableServiceLinks: false
      {{- if $ctx.Values.userNamespaces.enabled }}
      hostUsers: false
      {{- end }}
      terminationGracePeriodSeconds: 30
      {{- with $v.priorityClassName }}
      priorityClassName: {{ . | quote }}
      {{- end }}
      securityContext:
        {{- toYaml $v.podSecurityContext | nindent 8 }}
      containers:
        - name: valkey
          image: {{ include "searxng.valkey.image" $ctx | quote }}
          imagePullPolicy: {{ $v.image.pullPolicy }}
          securityContext:
            {{- toYaml $v.containerSecurityContext | nindent 12 }}
          # The image entrypoint prepends `valkey-server` when arg 1 ends in
          # .conf, and skips its chown/setpriv path when already non-root.
          args:
            - /etc/valkey/{{ $confKey }}
          {{- if $v.auth.enabled }}
          env:
            # Lets valkey-cli authenticate for the probes without putting the
            # password on a command line.
            - name: VALKEYCLI_AUTH
              valueFrom:
                secretKeyRef:
                  name: {{ include "searxng.valkey.secretName" $ctx }}
                  key: {{ include "searxng.valkey.secretPasswordKey" $ctx }}
          {{- end }}
          ports:
            - name: valkey
              containerPort: 6379
              protocol: TCP
          startupProbe:
            tcpSocket:
              port: valkey
            periodSeconds: 3
            failureThreshold: 20
          livenessProbe:
            exec:
              command: ["valkey-cli", "ping"]
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            exec:
              command: ["valkey-cli", "ping"]
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          resources:
            {{- toYaml $resources | nindent 12 }}
          volumeMounts:
            - name: config
              mountPath: /etc/valkey
              readOnly: true
            - name: data
              mountPath: /data
            - name: tmp
              mountPath: /tmp
        {{- if $v.metrics.enabled }}
        - name: metrics
          image: {{ include "searxng.valkey.exporterImage" $ctx | quote }}
          imagePullPolicy: {{ $v.metrics.image.pullPolicy }}
          securityContext:
            {{- toYaml $v.metrics.containerSecurityContext | nindent 12 }}
          env:
            - name: REDIS_ADDR
              value: "redis://127.0.0.1:6379"
            {{- if $v.auth.enabled }}
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ include "searxng.valkey.secretName" $ctx }}
                  key: {{ include "searxng.valkey.secretPasswordKey" $ctx }}
            {{- end }}
            - name: REDIS_EXPORTER_WEB_LISTEN_ADDRESS
              value: ":{{ $v.metrics.port }}"
          ports:
            - name: metrics
              containerPort: {{ $v.metrics.port }}
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /health
              port: metrics
            periodSeconds: 30
            timeoutSeconds: 5
          readinessProbe:
            httpGet:
              path: /health
              port: metrics
            periodSeconds: 15
            timeoutSeconds: 5
          resources:
            {{- toYaml $v.metrics.resources | nindent 12 }}
        {{- end }}
      volumes:
        - name: config
          secret:
            secretName: {{ include "searxng.valkey.secretName" $ctx }}
            defaultMode: 0440
            items:
              - key: {{ $confKey }}
                path: {{ $confKey }}
        - name: tmp
          emptyDir:
            sizeLimit: 16Mi
        {{- if not $v.persistence.enabled }}
        - name: data
          emptyDir:
            sizeLimit: {{ $v.emptyDir.sizeLimit }}
        {{- end }}
      {{- if and $isReplica (eq $v.replica.podAntiAffinityPreset "soft") (not $v.affinity) }}
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchExpressions:
                    - key: app.kubernetes.io/instance
                      operator: In
                      values:
                        - {{ $ctx.Release.Name }}
                    - key: app.kubernetes.io/component
                      operator: In
                      values:
                        - valkey-primary
                        - valkey-replica
      {{- else if and $isReplica (eq $v.replica.podAntiAffinityPreset "hard") (not $v.affinity) }}
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - topologyKey: kubernetes.io/hostname
              labelSelector:
                matchExpressions:
                  - key: app.kubernetes.io/instance
                    operator: In
                    values:
                      - {{ $ctx.Release.Name }}
                  - key: app.kubernetes.io/component
                    operator: In
                    values:
                      - valkey-primary
                      - valkey-replica
      {{- else }}
      {{- with $v.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- end }}
      {{- with $v.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
  {{- if $v.persistence.enabled }}
  volumeClaimTemplates:
    - metadata:
        name: data
        labels:
          {{- $labels | nindent 10 }}
        {{- with $v.persistence.annotations }}
        annotations:
          {{- toYaml . | nindent 10 }}
        {{- end }}
      spec:
        accessModes:
          {{- toYaml $v.persistence.accessModes | nindent 10 }}
        resources:
          requests:
            storage: {{ $v.persistence.size | quote }}
        {{- if $v.persistence.storageClass }}
        storageClassName: {{ $v.persistence.storageClass | quote }}
        {{- end }}
  {{- end }}
{{- end -}}
