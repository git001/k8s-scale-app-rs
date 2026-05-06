{{/*
Chart name (truncated to 63 chars).
*/}}
{{- define "k8s-scale-app-rs.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name.
*/}}
{{- define "k8s-scale-app-rs.fullname" -}}
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
Common labels.
*/}}
{{- define "k8s-scale-app-rs.labels" -}}
app.kubernetes.io/name: {{ include "k8s-scale-app-rs.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
ServiceAccount name.
*/}}
{{- define "k8s-scale-app-rs.serviceAccountName" -}}
{{ .Values.serviceAccount.name }}
{{- end -}}

{{/*
Container image reference.
*/}}
{{- define "k8s-scale-app-rs.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}

{{/*
Resolved name of the ConfigMap holding the extra CA bundle.
*/}}
{{- define "k8s-scale-app-rs.extraCAConfigMapName" -}}
{{- if .Values.extraCA.existingConfigMap -}}
{{- .Values.extraCA.existingConfigMap -}}
{{- else -}}
{{- printf "%s-extra-ca" (include "k8s-scale-app-rs.fullname" .) -}}
{{- end -}}
{{- end -}}
