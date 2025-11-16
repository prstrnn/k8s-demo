{{- define "demo.ns" -}}
{{ .Values.namespace }}
{{- end -}}

{{- define "demo.fullname" -}}
{{ .Release.Name }}-{{ .Chart.Name }}
{{- end -}}
