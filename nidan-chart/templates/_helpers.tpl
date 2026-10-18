{{- define "nidan.namespace" -}}
{{ .Values.global.namespace | default "nidan" }}
{{- end -}}
