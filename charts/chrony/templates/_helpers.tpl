{{/*
Expand the name of the chart.
*/}}
{{- define "chrony.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name - <release>-<chart> unless the release already
carries the chart name (avoids chrony-chrony when the release is "chrony").
*/}}
{{- define "chrony.fullname" -}}
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

{{/*
Chart-name label value.
*/}}
{{- define "chrony.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Standard label set - recommended labels + Helm meta.
*/}}
{{- define "chrony.labels" -}}
helm.sh/chart: {{ include "chrony.chart" . }}
{{ include "chrony.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Selector labels - stable subset used in Service and controller selectors.
*/}}
{{- define "chrony.selectorLabels" -}}
app.kubernetes.io/name: {{ include "chrony.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end -}}

{{/*
ServiceAccount name.
*/}}
{{- define "chrony.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "chrony.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Image reference - a digest wins over the tag, the tag defaults to appVersion.
    {{ include "chrony.image" (dict "image" .Values.image "default" .Chart.AppVersion) }}
*/}}
{{- define "chrony.image" -}}
{{- if .image.digest -}}
{{- printf "%s@%s" .image.repository .image.digest -}}
{{- else -}}
{{- printf "%s:%s" .image.repository (toString (default .default .image.tag)) -}}
{{- end -}}
{{- end -}}

{{/*
Validated controller kind.
*/}}
{{- define "chrony.kind" -}}
{{- $kind := .Values.workload.kind -}}
{{- if not (has $kind (list "Deployment" "StatefulSet" "DaemonSet")) -}}
{{- fail (printf "workload.kind=%q is invalid - expected Deployment | StatefulSet | DaemonSet" $kind) -}}
{{- end -}}
{{- $kind -}}
{{- end -}}

{{/*
"true" when several pods can answer behind the same Service.
*/}}
{{- define "chrony.multiPod" -}}
{{- if or (eq (include "chrony.kind" .) "DaemonSet") (gt (int .Values.replicaCount) 1) -}}true{{- end -}}
{{- end -}}

{{/*
Headless Service name (StatefulSet governing service).
*/}}
{{- define "chrony.headlessServiceName" -}}
{{- printf "%s-headless" (include "chrony.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
"true" when chronyd starts as root - only to discipline the node clock.
*/}}
{{- define "chrony.runAsRoot" -}}
{{- if .Values.clockControl.enabled -}}true{{- end -}}
{{- end -}}

{{/*
"true" when the chart mounts a complete chrony.conf.
*/}}
{{- define "chrony.customConfig" -}}
{{- if or .Values.chrony.config.inline .Values.chrony.config.existingConfigMap -}}true{{- end -}}
{{- end -}}

{{/*
ConfigMap holding the complete chrony.conf.
*/}}
{{- define "chrony.configConfigMapName" -}}
{{- default (printf "%s-config" (include "chrony.fullname" .)) .Values.chrony.config.existingConfigMap -}}
{{- end -}}

{{/*
NTS server certificate Secret. Validates that one source is configured.
*/}}
{{- define "chrony.ntsCertSecretName" -}}
{{- $cert := .Values.nts.server.certificate -}}
{{- if $cert.existingSecret -}}
{{- $cert.existingSecret -}}
{{- else if $cert.certManager.enabled -}}
{{- printf "%s-nts-tls" (include "chrony.fullname" .) -}}
{{- else -}}
{{- fail "nts.server.enabled needs a certificate: set nts.server.certificate.existingSecret or nts.server.certificate.certManager.enabled" -}}
{{- end -}}
{{- end -}}

{{/*
"true" when the replicas share one set of NTS cookie keys.
*/}}
{{- define "chrony.ntsSharedKeys" -}}
{{- if .Values.nts.server.enabled -}}
{{- $mode := toString .Values.nts.server.sharedKeys.enabled -}}
{{- if not (has $mode (list "auto" "true" "false")) -}}
{{- fail (printf "nts.server.sharedKeys.enabled=%q is invalid - expected auto | true | false" $mode) -}}
{{- end -}}
{{- $multi := and (ne (include "chrony.kind" .) "DaemonSet") (gt (int .Values.replicaCount) 1) -}}
{{- if or (eq $mode "true") (and (eq $mode "auto") $multi) -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/*
NTS shared keys Secret.
*/}}
{{- define "chrony.ntsKeysSecretName" -}}
{{- default (printf "%s-nts-keys" (include "chrony.fullname" .)) .Values.nts.server.sharedKeys.existingSecret -}}
{{- end -}}

{{/*
Render pod affinity - user-provided `.Values.affinity` wins, otherwise build
it from the `podAntiAffinityPreset` + `nodeAffinityPreset` shorthands. Pod
anti-affinity is meaningless for a DaemonSet and is skipped there.
*/}}
{{- define "chrony.affinity" -}}
{{- if .Values.affinity -}}
{{- toYaml .Values.affinity -}}
{{- else -}}
{{- $out := dict -}}
{{- $preset := .Values.podAntiAffinityPreset -}}
{{- if and $preset (ne (include "chrony.kind" .) "DaemonSet") -}}
{{- if not (has $preset (list "soft" "hard")) -}}
{{- fail (printf "podAntiAffinityPreset=%q is invalid - expected \"\" | soft | hard" $preset) -}}
{{- end -}}
{{- $rule := dict "labelSelector" (dict "matchLabels" (fromYaml (include "chrony.selectorLabels" .))) "topologyKey" "kubernetes.io/hostname" -}}
{{- if eq $preset "hard" -}}
{{- $_ := set $out "podAntiAffinity" (dict "requiredDuringSchedulingIgnoredDuringExecution" (list $rule)) -}}
{{- else -}}
{{- $_ := set $out "podAntiAffinity" (dict "preferredDuringSchedulingIgnoredDuringExecution" (list (dict "weight" 100 "podAffinityTerm" $rule))) -}}
{{- end -}}
{{- end -}}
{{- $na := .Values.nodeAffinityPreset -}}
{{- if and $na.type $na.key $na.values -}}
{{- $term := dict "matchExpressions" (list (dict "key" $na.key "operator" "In" "values" $na.values)) -}}
{{- if eq $na.type "hard" -}}
{{- $_ := set $out "nodeAffinity" (dict "requiredDuringSchedulingIgnoredDuringExecution" (dict "nodeSelectorTerms" (list $term))) -}}
{{- else if eq $na.type "soft" -}}
{{- $_ := set $out "nodeAffinity" (dict "preferredDuringSchedulingIgnoredDuringExecution" (list (dict "weight" 100 "preference" $term))) -}}
{{- else -}}
{{- fail (printf "nodeAffinityPreset.type=%q is invalid - expected \"\" | soft | hard" $na.type) -}}
{{- end -}}
{{- end -}}
{{- if $out -}}
{{- toYaml $out -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Environment of chronyd and of the config init container. Lists are joined
with newlines: chrony-entrypoint splits on commas and newlines, and an entry
may carry spaces (per-source options).
*/}}
{{- define "chrony.env" -}}
{{- $c := .Values.chrony -}}
- name: CHRONY_STATE_DIR
  value: /run/chrony/state
{{- if include "chrony.customConfig" . }}
- name: CHRONY_CONF
  value: /etc/chrony/custom/chrony.conf
{{- end }}
- name: NTP_PORT
  value: {{ .Values.containerPorts.ntp | quote }}
- name: NTS_PORT
  value: {{ .Values.containerPorts.nts | quote }}
- name: CLOCK_CONTROL
  value: {{ .Values.clockControl.enabled | quote }}
- name: SCFILTER_LEVEL
  value: {{ $c.scfilterLevel | quote }}
- name: SOURCE_OPTIONS
  value: {{ $c.sourceOptions | quote }}
- name: NTS
  value: {{ .Values.nts.client.enabled | quote }}
{{- range $env, $list := dict "NTP_SERVERS" $c.servers "NTP_POOLS" $c.pools "NTP_PEERS" $c.peers "REFCLOCKS" $c.refclocks "ALLOW" $c.allow "DENY" $c.deny "BIND_ADDRESS" $c.bindAddresses "NTS_NTP_SERVER" $.Values.nts.server.ntpServer }}
{{- if $list }}
- name: {{ $env }}
  value: {{ join "\n" $list | quote }}
{{- end }}
{{- end }}
{{- if .Values.nts.client.trustedCertsSecret }}
- name: NTS_TRUSTED_CERTS
  value: /etc/chrony/nts-trust
{{- end }}
{{- range $env, $value := dict "MINSOURCES" $c.minSources "MAXDISTANCE" $c.maxDistance "MAXJITTER" $c.maxJitter "AUTHSELECTMODE" $c.authSelectMode "LOCAL_STRATUM" $c.local.stratum "LOCAL_DISTANCE" $c.local.distance "RATELIMIT" $c.rateLimit "NTS_RATELIMIT" $c.ntsRateLimit "CLIENTLOGLIMIT" $c.clientLogLimit "SMOOTHTIME" $c.smoothTime "LEAPSECLIST" $c.leapSecList "LEAPSECMODE" $c.leapSecMode "LOG_LEVEL" $c.logLevel "IP_MODE" $c.ipMode "LOGS" $c.logs "EXTRA_CONF" $c.extraConf "NTS_ROTATE" $.Values.nts.server.rotate }}
{{- if ne (toString $value) "" }}
- name: {{ $env }}
  value: {{ toString $value | quote }}
{{- end }}
{{- end }}
{{- if $c.local.orphan }}
- name: LOCAL_ORPHAN
  value: "true"
{{- end }}
{{- if $c.noClientLog }}
- name: NOCLIENTLOG
  value: "true"
{{- end }}
{{- with $c.extraArgs }}
- name: EXTRA_ARGS
  value: {{ join " " . | quote }}
{{- end }}
- name: READY_MAX_ROOT_DISTANCE
  value: {{ .Values.probes.readyMaxRootDistance | quote }}
- name: HEALTH_MAX_STRATUM
  value: {{ .Values.probes.maxStratum | quote }}
- name: HEALTH_TIMEOUT
  value: {{ .Values.probes.timeout | quote }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Volume mounts shared by chronyd and the config init container. The NTS
material and the sources/conf.d directories must be visible to both, because
chrony-entrypoint decides what to render from what exists on disk.
*/}}
{{- define "chrony.volumeMounts" -}}
- name: state
  mountPath: /run/chrony
{{- if include "chrony.customConfig" . }}
- name: config
  mountPath: /etc/chrony/custom
  readOnly: true
{{- end }}
{{- if .Values.chrony.sourceFiles }}
- name: sources
  mountPath: /etc/chrony/sources.d
  readOnly: true
{{- end }}
{{- if .Values.chrony.confFiles }}
- name: confd
  mountPath: /etc/chrony/conf.d
  readOnly: true
{{- end }}
{{- if .Values.nts.server.enabled }}
- name: nts
  mountPath: /etc/chrony/nts
  readOnly: true
{{- end }}
{{- if .Values.nts.client.trustedCertsSecret }}
- name: nts-trust
  mountPath: /etc/chrony/nts-trust
  readOnly: true
{{- end }}
{{- with .Values.extraVolumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
chronyd security context. Node clock control starts chronyd as root: it binds
its sockets, then drops to uid 65532 keeping CAP_SYS_TIME only. Root needs
SETUID/SETGID for the drop and DAC_OVERRIDE to write the state directory the
config init container created as 65532 (mode 0700).
*/}}
{{- define "chrony.securityContext" -}}
{{- $sc := deepCopy .Values.securityContext -}}
{{- if include "chrony.runAsRoot" . -}}
{{- $_ := set $sc "runAsUser" 0 -}}
{{- $_ := set $sc "runAsGroup" 0 -}}
{{- $_ := set $sc "runAsNonRoot" false -}}
{{- $caps := default dict $sc.capabilities -}}
{{- $_ := set $caps "add" (uniq (concat (default list $caps.add) (list "SYS_TIME" "NET_BIND_SERVICE" "SETUID" "SETGID" "DAC_OVERRIDE"))) -}}
{{- $_ := set $sc "capabilities" $caps -}}
{{- end -}}
{{- toYaml $sc -}}
{{- end -}}

{{/*
Lowest privileged port chronyd binds, or 0 when the sysctl is not needed.
*/}}
{{- define "chrony.portSysctl" -}}
{{- $ports := list (int .Values.containerPorts.ntp) -}}
{{- if .Values.nts.server.enabled -}}
{{- $ports = append $ports (int .Values.containerPorts.nts) -}}
{{- end -}}
{{- $low := 0 -}}
{{- range $ports -}}
{{- if and (gt . 0) (lt . 1024) (or (eq $low 0) (lt . $low)) -}}
{{- $low = . -}}
{{- end -}}
{{- end -}}
{{- if and .Values.unprivilegedPortSysctl (not .Values.hostNetwork) (not (include "chrony.runAsRoot" .)) -}}
{{- $low -}}
{{- else -}}
0
{{- end -}}
{{- end -}}
