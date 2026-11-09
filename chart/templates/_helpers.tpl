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
Selector labels of the vigil Deployment.
*/}}
{{- define "k8s-scale-app-rs.vigilSelectorLabels" -}}
app.kubernetes.io/name: {{ include "k8s-scale-app-rs.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: vigil
{{- end -}}

{{/*
Name of the target workload. target.deployment is the name before target.name existed.
*/}}
{{- define "k8s-scale-app-rs.targetName" -}}
{{ .Values.target.name | default .Values.target.deployment }}
{{- end -}}

{{/*
The kinds the jobs of this release act on, comma-separated, for RBAC.
*/}}
{{- define "k8s-scale-app-rs.targetKinds" -}}
{{- $kinds := list .Values.target.kind -}}
{{- if .Values.vigil.enabled -}}
{{- range $name, $job := .Values.vigil.jobs -}}
{{- $kinds = append $kinds ($job.kind | default $.Values.target.kind) -}}
{{- end -}}
{{- end -}}
{{- range $kinds -}}
{{- if not (has . (list "deployment" "statefulset")) -}}
{{- fail (printf "kind must be \"deployment\" or \"statefulset\", got %q" .) -}}
{{- end -}}
{{- end -}}
{{- $kinds | uniq | join "," -}}
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
