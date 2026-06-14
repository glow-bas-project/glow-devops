{{- define "ui.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "ui.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "ui.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "ui.runtimeConfigChecksum" -}}
{{- printf "%s|%s|%s" (.Values.global.pathPrefix | default "") (.Values.global.authBaseUrl | default "") (.Values.global.publicOrigin | default "") | sha256sum -}}
{{- end }}
