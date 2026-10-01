{{/* Chart name, truncated to the DNS label limit. */}}
{{- define "notes.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified app name; the release name is reused when it already contains the chart name. */}}
{{- define "notes.fullname" -}}
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

{{- define "notes.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "notes.selectorLabels" -}}
app.kubernetes.io/name: {{ include "notes.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "notes.labels" -}}
helm.sh/chart: {{ include "notes.chart" . }}
{{ include "notes.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: selfhosted-ops-kit
{{- end }}

{{/* Label that grants network access to PostgreSQL (see networkpolicies.yaml). */}}
{{- define "notes.dbClientLabel" -}}
selfhosted-ops-kit/db-client: "true"
{{- end }}

{{/*
Render an image reference.
Usage: include "notes.image" (dict "image" .Values.api.image "global" .Values.global "default" .Chart.AppVersion)
*/}}
{{- define "notes.image" -}}
{{- $repo := .image.repository }}
{{- if .global.imageRegistry }}
{{- $repo = printf "%s/%s" (trimSuffix "/" .global.imageRegistry) .image.repository }}
{{- end }}
{{- if .image.digest }}
{{- printf "%s@%s" $repo .image.digest }}
{{- else }}
{{- printf "%s:%s" $repo (default .default .image.tag | toString) }}
{{- end }}
{{- end }}

{{- define "notes.apiImage" -}}
{{- include "notes.image" (dict "image" .Values.api.image "global" .Values.global "default" .Chart.AppVersion) }}
{{- end }}

{{- define "notes.postgresImage" -}}
{{- include "notes.image" (dict "image" .Values.postgres.image "global" .Values.global "default" "") }}
{{- end }}

{{- define "notes.postgresSecretName" -}}
{{- default (printf "%s-postgres" (include "notes.fullname" .)) .Values.postgres.existingSecret }}
{{- end }}

{{- define "notes.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}

{{/* Environment shared by every PostgreSQL client container (pg_dump, pg_restore, psql). */}}
{{- define "notes.pgClientEnv" -}}
- name: PGHOST
  value: {{ include "notes.fullname" . }}-postgres
- name: PGPORT
  value: "5432"
- name: PGDATABASE
  value: {{ .Values.postgres.database | quote }}
- name: PGUSER
  value: {{ .Values.postgres.username | quote }}
- name: PGPASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "notes.postgresSecretName" . }}
      key: password
{{- end }}

{{/* Pod template used by the scheduled backup and the pre-upgrade backup hook. */}}
{{- define "notes.backupPodSpec" -}}
restartPolicy: Never
automountServiceAccountToken: false
# The backup PVC is ReadWriteOnce and also mounted by the PostgreSQL pod:
# backup pods must run on the same node.
affinity:
  podAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            {{- include "notes.selectorLabels" . | nindent 12 }}
            app.kubernetes.io/component: postgres
{{- with (include "notes.imagePullSecrets" .) }}{{ . | nindent 0 }}{{- end }}
securityContext:
  {{- toYaml .Values.podSecurityContext | nindent 2 }}
  runAsUser: 70
  runAsGroup: 70
  fsGroup: 70
containers:
  - name: pg-dump
    image: {{ include "notes.postgresImage" . }}
    imagePullPolicy: {{ .Values.postgres.image.pullPolicy }}
    command: ["/bin/sh", "/scripts/backup.sh"]
    env:
      {{- include "notes.pgClientEnv" . | nindent 6 }}
      - name: RETENTION
        value: {{ .Values.backup.retention | quote }}
    securityContext:
      {{- toYaml .Values.containerSecurityContext | nindent 6 }}
    resources:
      {{- toYaml .Values.backup.resources | nindent 6 }}
    volumeMounts:
      - name: backups
        mountPath: /backups
      - name: scripts
        mountPath: /scripts
      - name: tmp
        mountPath: /tmp
volumes:
  - name: backups
    persistentVolumeClaim:
      claimName: {{ include "notes.fullname" . }}-backups
  - name: scripts
    configMap:
      name: {{ include "notes.fullname" . }}-backup-scripts
  - name: tmp
    emptyDir: {}
{{- end }}

{{- define "notes.apiEnv" -}}
- name: DB_HOST
  value: {{ include "notes.fullname" . }}-postgres
- name: DB_PORT
  value: "5432"
- name: DB_NAME
  value: {{ .Values.postgres.database | quote }}
- name: DB_USER
  value: {{ .Values.postgres.username | quote }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "notes.postgresSecretName" . }}
      key: password
- name: LOG_LEVEL
  value: {{ .Values.api.logLevel | quote }}
{{- end }}
