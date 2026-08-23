{{/*
Render the replica count for a Deployment/StatefulSet.

Input: dict
  "scaleDown"  the chart-global .Values.scaleDown flag (may be nil)
  "replicas"   the workload's replicas value (may be nil)

Rules (issue #25):
  - scaleDown: true takes precedence and always yields 0.
  - otherwise an explicitly set replicas value is used as given, including an
    explicit 0 — Helm's "default" would swallow 0, hence the explicit
    kindIs "invalid" nil check.
  - a missing replicas value defaults to 1.

Usage (the values path to the workload's replicas varies per chart):
  replicas: {{ include "minecraft-server.replicas" (dict "scaleDown" .Values.scaleDown "replicas" .Values.server.replicas) }}

NOTE: charts in this repo deliberately have no dependencies, so this helper is
duplicated into every chart's templates/_helpers.tpl with the chart's name as
define prefix. The reference implementation lives in template-chart.

This chart is a stage-1 import (issue #67) and does not yet follow the repo
conventions; only the replicas helper was taken over, because the scaleDown
flag is needed before the Fleet migration. The resources helper follows in
stage 2 together with the rest of the convention alignment.
*/}}
{{- define "minecraft-server.replicas" -}}
{{- if .scaleDown -}}
0
{{- else if not (kindIs "invalid" .replicas) -}}
{{- .replicas -}}
{{- else -}}
1
{{- end -}}
{{- end -}}
