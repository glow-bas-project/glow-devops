{{/*
Expand the name of the chart.
*/}}
{{- define "glow.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "glow.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "glow.pathPrefix" -}}
{{- .Values.global.pathPrefix | default "" }}
{{- end }}

{{- define "glow.authPath" -}}
{{- .Values.global.authPath | default "/auth" }}
{{- end }}

{{- define "glow.apiBasePath" -}}
{{- $prefix := include "glow.pathPrefix" . }}
{{- printf "%s/api" $prefix }}
{{- end }}

{{- define "glow.ingressHost" -}}
{{- .Values.global.edgeHost | default "localhost" }}
{{- end }}

{{- define "glow.keycloakInternalUrl" -}}
http://keycloak:8080{{- include "glow.authPath" . }}
{{- end }}

{{- define "glow.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}
