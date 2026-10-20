{{/*
Pod template shared by the three controller kinds.
*/}}
{{- define "chrony.podTemplate" -}}
{{- $fullName := include "chrony.fullname" . -}}
{{- $root := include "chrony.runAsRoot" . -}}
{{- $sysctlPort := int (include "chrony.portSysctl" .) -}}
{{- $ntsServer := .Values.nts.server.enabled -}}
metadata:
  labels:
    {{- include "chrony.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/component: timeserver
    {{- with .Values.commonLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  annotations:
    # chrony-entrypoint renders the configuration at startup only: roll the
    # pods whenever an input of that rendering changes.
    checksum/env: {{ include "chrony.env" . | sha256sum }}
    {{- if .Values.chrony.config.inline }}
    checksum/config: {{ include (print $.Template.BasePath "/configmap-config.yaml") . | sha256sum }}
    {{- end }}
    {{- if and .Values.chrony.sourceFiles .Values.chrony.sourceFilesRolloutOnChange }}
    checksum/sources: {{ toYaml .Values.chrony.sourceFiles | sha256sum }}
    {{- end }}
    {{- with .Values.chrony.confFiles }}
    checksum/confd: {{ toYaml . | sha256sum }}
    {{- end }}
    {{- if and $ntsServer .Values.nts.server.certificate.reloaderAnnotation }}
    secret.reloader.stakater.com/reload: {{ include "chrony.ntsCertSecretName" . | quote }}
    {{- end }}
    {{- with .Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  serviceAccountName: {{ include "chrony.serviceAccountName" . }}
  automountServiceAccountToken: {{ .Values.serviceAccount.automountServiceAccountToken }}
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if .Values.hostNetwork }}
  hostNetwork: true
  {{- end }}
  dnsPolicy: {{ default (ternary "ClusterFirstWithHostNet" "ClusterFirst" .Values.hostNetwork) .Values.dnsPolicy }}
  enableServiceLinks: false
  terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
  securityContext:
    {{- $psc := deepCopy .Values.podSecurityContext }}
    {{- if gt $sysctlPort 0 }}
    {{- $sysctls := default list $psc.sysctls }}
    {{- $_ := set $psc "sysctls" (append $sysctls (dict "name" "net.ipv4.ip_unprivileged_port_start" "value" (toString $sysctlPort))) }}
    {{- end }}
    {{- toYaml $psc | nindent 4 }}
  {{- with .Values.priorityClassName }}
  priorityClassName: {{ . }}
  {{- end }}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with include "chrony.affinity" . }}
  affinity:
    {{- . | nindent 4 }}
  {{- end }}
  {{- with .Values.topologySpreadConstraints }}
  topologySpreadConstraints:
    {{- range . }}
    {{- $tsc := deepCopy . }}
    {{- if not $tsc.labelSelector }}
    {{- $_ := set $tsc "labelSelector" (dict "matchLabels" (fromYaml (include "chrony.selectorLabels" $))) }}
    {{- end }}
    - {{- toYaml $tsc | nindent 6 }}
    {{- end }}
  {{- end }}
  {{- if or .Values.extraInitContainers .Values.configCheck.enabled $root }}
  initContainers:
    {{- with .Values.extraInitContainers }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- if or .Values.configCheck.enabled $root }}
    # Renders and validates the configuration as uid 65532 (`chronyd -p`) and
    # prints it to this container's log. It also creates the state directory
    # with the owner and mode chronyd insists on before a root chronyd starts.
    - name: config
      image: {{ include "chrony.image" (dict "image" .Values.image "default" .Chart.AppVersion) | quote }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      args: [config]
      env:
        {{- include "chrony.env" . | nindent 8 }}
      {{- with .Values.extraEnvFrom }}
      envFrom:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      securityContext:
        {{- toYaml (mergeOverwrite (deepCopy .Values.securityContext) (dict "runAsUser" 65532 "runAsGroup" 65532 "runAsNonRoot" true)) | nindent 8 }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      volumeMounts:
        {{- include "chrony.volumeMounts" . | nindent 8 }}
    {{- end }}
  {{- end }}
  containers:
    - name: chrony
      image: {{ include "chrony.image" (dict "image" .Values.image "default" .Chart.AppVersion) | quote }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      args: [run]
      env:
        {{- include "chrony.env" . | nindent 8 }}
      {{- with .Values.extraEnvFrom }}
      envFrom:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      ports:
        {{- if ne (int .Values.containerPorts.ntp) 0 }}
        - name: ntp
          containerPort: {{ .Values.containerPorts.ntp }}
          protocol: UDP
        {{- end }}
        {{- if $ntsServer }}
        - name: nts-ke
          containerPort: {{ .Values.containerPorts.nts }}
          protocol: TCP
        {{- end }}
      securityContext:
        {{- include "chrony.securityContext" . | nindent 8 }}
      {{- with .Values.startupProbe }}
      startupProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.livenessProbe }}
      livenessProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.readinessProbe }}
      readinessProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      volumeMounts:
        {{- include "chrony.volumeMounts" . | nindent 8 }}
    {{- if .Values.monitoring.enabled }}
    {{- $exp := .Values.monitoring.exporter }}
    {{- $kernel := toString $exp.kernel }}
    {{- if not (has $kernel (list "auto" "true" "false")) }}
    {{- fail (printf "monitoring.exporter.kernel=%q is invalid - expected auto | true | false" $kernel) }}
    {{- end }}
    {{- $targets := list }}
    {{- if and $exp.measureLocalServer (ne (int .Values.containerPorts.ntp) 0) }}
    {{- $targets = append $targets (printf "127.0.0.1:%d" (int .Values.containerPorts.ntp)) }}
    {{- end }}
    {{- $targets = concat $targets $exp.referenceServers }}
    {{- if gt (len $targets) 2 }}
    {{- fail "monitoring.exporter: the agent mode takes at most 2 servers (measureLocalServer + referenceServers)" }}
    {{- end }}
    # ntp-exporter in agent mode. It reads chronyd over the Unix command socket
    # (the UDP command port is disabled in the image) and creates its reply
    # socket next to it, hence the same uid and the shared state volume.
    - name: exporter
      image: {{ include "chrony.image" (dict "image" $exp.image "default" "latest") | quote }}
      imagePullPolicy: {{ $exp.image.pullPolicy }}
      env:
        - name: NTP_EXPORTER_MODE
          value: agent
        - name: NTP_EXPORTER_PORT
          value: {{ $exp.port | quote }}
        - name: NTP_EXPORTER_COLLECTION_INTERVAL
          value: {{ $exp.collectionInterval | quote }}
        - name: NTP_EXPORTER_CHRONY_ENABLED
          value: "true"
        - name: NTP_EXPORTER_CHRONY_ADDRESS
          value: unix:///run/chrony/state/chronyd.sock
        - name: NTP_EXPORTER_KERNEL_ENABLED
          value: {{ ternary .Values.clockControl.enabled (eq $kernel "true") (eq $kernel "auto") | quote }}
        {{- with $targets }}
        - name: NTP_EXPORTER_SERVERS
          value: {{ join "," . | quote }}
        {{- end }}
        - name: NTP_EXPORTER_LOG_LEVEL
          value: {{ $exp.logLevel | quote }}
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        {{- with $exp.extraEnv }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      ports:
        - name: metrics
          containerPort: {{ $exp.port }}
          protocol: TCP
      securityContext:
        {{- toYaml (mergeOverwrite (deepCopy .Values.exporterSecurityContext) (dict "runAsUser" 65532 "runAsGroup" 65532 "runAsNonRoot" true)) | nindent 8 }}
      livenessProbe:
        httpGet:
          path: /healthz
          port: metrics
        periodSeconds: 30
      resources:
        {{- toYaml $exp.resources | nindent 8 }}
      volumeMounts:
        - name: state
          mountPath: /run/chrony
    {{- end }}
    {{- with .Values.sidecars }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with include "chrony.volumes" . | trim }}
  volumes:
    {{- . | nindent 4 }}
  {{- end }}
{{- end -}}

{{/*
Pod volumes. Empty for a StatefulSet with persistence and nothing optional on:
the caller then omits the key instead of rendering `volumes: null`.
*/}}
{{- define "chrony.volumes" -}}
{{- $fullName := include "chrony.fullname" . -}}
{{- if not (and (eq (include "chrony.kind" .) "StatefulSet") .Values.persistence.enabled) }}
- name: state
  emptyDir:
    {{- with .Values.emptyDir.medium }}
    medium: {{ . }}
    {{- end }}
    {{- with .Values.emptyDir.sizeLimit }}
    sizeLimit: {{ . }}
    {{- end }}
{{- end }}
{{- if include "chrony.customConfig" . }}
- name: config
  configMap:
    name: {{ include "chrony.configConfigMapName" . }}
    items:
      - key: {{ .Values.chrony.config.key }}
        path: chrony.conf
{{- end }}
{{- if .Values.chrony.sourceFiles }}
- name: sources
  configMap:
    name: {{ $fullName }}-sources
{{- end }}
{{- if .Values.chrony.confFiles }}
- name: confd
  configMap:
    name: {{ $fullName }}-confd
{{- end }}
{{- if .Values.nts.server.enabled }}
# chrony-entrypoint picks tls.crt / tls.key up by their default path and
# seeds `ntskeys` into the state directory. 0440 + fsGroup: readable by
# chronyd, not world-readable (chronyd warns about that).
- name: nts
  projected:
    defaultMode: 0440
    sources:
      - secret:
          name: {{ include "chrony.ntsCertSecretName" . }}
          items:
            - key: tls.crt
              path: tls.crt
            - key: tls.key
              path: tls.key
      {{- if include "chrony.ntsSharedKeys" . }}
      - secret:
          name: {{ include "chrony.ntsKeysSecretName" . }}
          items:
            - key: ntskeys
              path: ntskeys
      {{- end }}
{{- end }}
{{- with .Values.nts.client.trustedCertsSecret }}
- name: nts-trust
  secret:
    secretName: {{ . }}
    defaultMode: 0444
{{- end }}
{{- with .Values.extraVolumes }}
{{ toYaml . }}
{{- end }}
{{- end -}}
