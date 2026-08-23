{{/*
Render the body of a container "resources:" block from a values dict of the form

  resources:
    limitFactor: 3          # optional, default 3
    requests: { cpu, memory, ephemeral-storage / ephemeralStorage, ... }
    limits:   { ... }       # optional, every entry optional

Rules (variant B, see issue #19):
  - requests are rendered as given (camelCase "ephemeralStorage" is normalized
    to the Kubernetes key "ephemeral-storage").
  - an explicitly set limit always wins.
  - a missing memory / ephemeral-storage limit is computed as
    limitFactor x the corresponding request.
  - a missing cpu limit is NOT set at all (the kubelet then treats CPU as
    unlimited; CPU is compressible, so this cannot kill the workload).

Usage (the values path to the resources dict varies per chart):
  resources:
    {{- include "minecraft-server.resources" .Values.<app>.resources | nindent 12 }}

NOTE: charts in this repo deliberately have no dependencies, so this helper is
duplicated into every chart's templates/_helpers.tpl with the chart's name as
define prefix. The reference implementation lives in template-chart.
*/}}
{{- define "minecraft-server.resources" -}}
{{- $resources := . | default dict -}}
{{- $factor := 3.0 -}}
{{- if not (kindIs "invalid" $resources.limitFactor) -}}
{{- $factor = float64 $resources.limitFactor -}}
{{- end -}}
{{- $requests := dict -}}
{{- range $key, $value := ($resources.requests | default dict) -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $_ := set $requests (include "minecraft-server.resourceKey" $key) $value -}}
{{- end -}}
{{- end -}}
{{- $limits := dict -}}
{{- range $key, $value := ($resources.limits | default dict) -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $_ := set $limits (include "minecraft-server.resourceKey" $key) $value -}}
{{- end -}}
{{- end -}}
{{- range $key, $request := $requests -}}
{{- if and (ne $key "cpu") (not (hasKey $limits $key)) -}}
{{- $_ := set $limits $key (include "minecraft-server.multiplyQuantity" (dict "quantity" $request "factor" $factor)) -}}
{{- end -}}
{{- end -}}
{{- $out := dict -}}
{{- with $requests }}{{- $_ := set $out "requests" . }}{{- end -}}
{{- with $limits }}{{- $_ := set $out "limits" . }}{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Normalize a resource name from values to its Kubernetes key.
*/}}
{{- define "minecraft-server.resourceKey" -}}
{{- if eq . "ephemeralStorage" -}}ephemeral-storage{{- else -}}{{ . }}{{- end -}}
{{- end -}}

{{/*
Multiply a Kubernetes quantity by a factor, keeping its suffix.
Input: dict "quantity" <string|number> "factor" <float64>.
Handles plain numbers ("2", "0.5", 1073741824), decimal ("1.5Gi"), binary
("512Mi", "1Gi", "10Ki") and milli/SI suffixes ("100m", "500M"). Integer
results are printed without a decimal point.
*/}}
{{- define "minecraft-server.multiplyQuantity" -}}
{{- $quantity := printf "%v" .quantity -}}
{{- $number := regexFind "^[0-9]+(\\.[0-9]+)?" $quantity -}}
{{- if not $number -}}
{{- fail (printf "cannot parse resource quantity %q" $quantity) -}}
{{- end -}}
{{- $suffix := trimPrefix $number $quantity -}}
{{- if not (regexMatch "^(m|k|M|G|T|P|E|Ki|Mi|Gi|Ti|Pi|Ei)?$" $suffix) -}}
{{- fail (printf "unsupported resource quantity suffix %q in %q" $suffix $quantity) -}}
{{- end -}}
{{- $product := mulf (float64 $number) .factor -}}
{{- if eq $product (floor $product) -}}
{{- printf "%d%s" (int64 $product) $suffix -}}
{{- else -}}
{{- printf "%v%s" $product $suffix -}}
{{- end -}}
{{- end -}}

{{/*
Resolve the server container's resources.

The JVM heap (minecraft.resources.memory, in GiB) and the container's memory
request used to be configured in two unrelated places - the heap was a value,
the request and limit were hardcoded in the template - so raising the heap did
not raise the container's memory. Here an unset memory request is derived from
the heap instead, which keeps the two from drifting apart; an explicitly set
request always wins. The limit follows from the request via the limitFactor
rule in "minecraft-server.resources".

Input: the root context.
*/}}
{{- define "minecraft-server.serverResources" -}}
{{- $resources := deepCopy (.Values.server.resources | default dict) -}}
{{- $requests := deepCopy ($resources.requests | default dict) -}}
{{- if kindIs "invalid" $requests.memory -}}
{{- $_ := set $requests "memory" (printf "%vGi" .Values.minecraft.resources.memory) -}}
{{- end -}}
{{- $_ := set $resources "requests" $requests -}}
{{- include "minecraft-server.resources" $resources -}}
{{- end -}}

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

NOTE: like the resources helper above, this is duplicated into every chart's
templates/_helpers.tpl with the chart's name as define prefix. The reference
implementation lives in template-chart.
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

{{/*
Guard: curseforge, ftb and curseforgeServerpack are mutually exclusive.

Enabling more than one used to render a duplicate TYPE env entry, where the
last one silently won. Fail loudly instead.
*/}}
{{- define "minecraft-server.validateModpackSources" -}}
{{- $enabled := list -}}
{{- if .Values.curseforge.enabled -}}{{- $enabled = append $enabled "curseforge" -}}{{- end -}}
{{- if .Values.ftb.enabled -}}{{- $enabled = append $enabled "ftb" -}}{{- end -}}
{{- if .Values.curseforgeServerpack.enabled -}}{{- $enabled = append $enabled "curseforgeServerpack" -}}{{- end -}}
{{- if gt (len $enabled) 1 -}}
{{- fail (printf "minecraft-server: curseforge, ftb and curseforgeServerpack are mutually exclusive, but these are enabled at the same time: %s - enable at most one modpack source" (join ", " $enabled)) -}}
{{- end -}}
{{- if and .Values.curseforgeServerpack.enabled (not .Values.curseforgeServerpack.downloadUrl) -}}
{{- fail "minecraft-server: curseforgeServerpack.enabled is true but curseforgeServerpack.downloadUrl is not set - the init container would download an empty URL" -}}
{{- end -}}
{{- end -}}
