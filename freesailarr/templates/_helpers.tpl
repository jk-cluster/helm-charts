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

Usage:
  resources:
    {{- include "freesailarr.resources" .Values.<app>.resources | nindent 12 }}

NOTE: charts in this repo deliberately have no dependencies, so this helper is
duplicated into every chart's templates/_helpers.tpl with the chart's name as
define prefix. The reference implementation lives in template-chart.
*/}}
{{- define "freesailarr.resources" -}}
{{- $resources := . | default dict -}}
{{- $factor := 3.0 -}}
{{- if not (kindIs "invalid" $resources.limitFactor) -}}
{{- $factor = float64 $resources.limitFactor -}}
{{- end -}}
{{- $requests := dict -}}
{{- range $key, $value := ($resources.requests | default dict) -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $_ := set $requests (include "freesailarr.resourceKey" $key) $value -}}
{{- end -}}
{{- end -}}
{{- $limits := dict -}}
{{- range $key, $value := ($resources.limits | default dict) -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $_ := set $limits (include "freesailarr.resourceKey" $key) $value -}}
{{- end -}}
{{- end -}}
{{- range $key, $request := $requests -}}
{{- if and (ne $key "cpu") (not (hasKey $limits $key)) -}}
{{- $_ := set $limits $key (include "freesailarr.multiplyQuantity" (dict "quantity" $request "factor" $factor)) -}}
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
{{- define "freesailarr.resourceKey" -}}
{{- if eq . "ephemeralStorage" -}}ephemeral-storage{{- else -}}{{ . }}{{- end -}}
{{- end -}}

{{/*
Multiply a Kubernetes quantity by a factor, keeping its suffix.
Input: dict "quantity" <string|number> "factor" <float64>.
Handles plain numbers ("2", "0.5", 1073741824), decimal ("1.5Gi"), binary
("512Mi", "1Gi", "10Ki") and milli/SI suffixes ("100m", "500M"). Integer
results are printed without a decimal point.
*/}}
{{- define "freesailarr.multiplyQuantity" -}}
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

Usage:
  replicas: {{ include "freesailarr.replicas" (dict "scaleDown" .Values.scaleDown "replicas" .Values.replicas) }}

NOTE: like the resources helper above, this is duplicated into every chart's
templates/_helpers.tpl with the chart's name as define prefix. The reference
implementation lives in template-chart.
*/}}
{{- define "freesailarr.replicas" -}}
{{- if .scaleDown -}}
0
{{- else if not (kindIs "invalid" .replicas) -}}
{{- .replicas -}}
{{- else -}}
1
{{- end -}}
{{- end -}}

{{/*
Render additive env entries (the repo-wide <app>.env convention: tpl-rendered,
supporting the value, secretKeyRef and configMapKeyRef forms). Shared as a
helper here because this chart has nine containers, each with its own env block.

Usage:
  {{- include "freesailarr.env" (dict "root" $ "env" .Values.<app>.env) | nindent 12 }}
*/}}
{{- define "freesailarr.env" -}}
{{- $root := .root -}}
{{- range $value := .env }}
{{- if $value.value }}
- name: {{ $value.name }}
  value: {{ tpl $value.value $root | quote }}
{{- else if $value.valueFrom }}
{{- if $value.valueFrom.secretKeyRef }}
- name: {{ $value.name }}
  valueFrom:
    secretKeyRef:
      name: {{ tpl $value.valueFrom.secretKeyRef.name $root | quote }}
      key: {{ tpl $value.valueFrom.secretKeyRef.key $root | quote }}
{{- else if $value.valueFrom.configMapKeyRef }}
- name: {{ $value.name }}
  valueFrom:
    configMapKeyRef:
      name: {{ tpl $value.valueFrom.configMapKeyRef.name $root | quote }}
      key: {{ tpl $value.valueFrom.configMapKeyRef.key $root | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
The enabled app containers that listen on a port, as a JSON array of
{name, port} dicts (container port name == app name == service name suffix).
Consumed by the per-app services, the per-app ingresses and the firewall-ports
helper below:

  {{- $apps := include "freesailarr.portApps" . | fromJsonArray }}

recyclarr is deliberately absent: in daemon mode it serves no port, so it gets
no container port, no service and no ingress. flaresolverr is present - it
listens on 8191 and therefore gets a service - but it has no ingress block in
values and is never exposed from outside the cluster.
*/}}
{{- define "freesailarr.portApps" -}}
{{- $apps := list -}}
{{- range $app := list
  (dict "name" "qbittorrent" "port" 8080)
  (dict "name" "prowlarr" "port" 9696)
  (dict "name" "flaresolverr" "port" 8191)
  (dict "name" "radarr" "port" 7878)
  (dict "name" "sonarr" "port" 8989)
  (dict "name" "seerr" "port" 5055)
  (dict "name" "bazarr" "port" 6767) -}}
{{- if (index $.Values $app.name).enabled -}}
{{- $apps = append $apps $app -}}
{{- end -}}
{{- end -}}
{{- toJson $apps -}}
{{- end -}}

{{/*
The apps that render an Ingress: the enabled port apps whose values carry an
ingress block with enabled: true. Used by the ingress template.

  {{- $apps := include "freesailarr.ingressApps" . | fromJsonArray }}
*/}}
{{- define "freesailarr.ingressApps" -}}
{{- $apps := list -}}
{{- range $app := include "freesailarr.portApps" . | fromJsonArray -}}
{{- $config := index $.Values $app.name -}}
{{- if and $config.ingress $config.ingress.enabled -}}
{{- $apps = append $apps $app -}}
{{- end -}}
{{- end -}}
{{- toJson $apps -}}
{{- end -}}

{{/*
Comma-separated FIREWALL_INPUT_PORTS for gluetun: the ports of the enabled app
containers (ingress traffic and the kubelet probes both arrive on the pod IP)
plus 9999 for gluetun's own health server.

Measured caveat: inside a pod network these rules never actually match. gluetun
detects the pod's own subnet and inserts
"-A INPUT -d <pod-subnet> -i eth0 -j ACCEPT" ahead of the per-port rules, and
every packet arriving at the pod IP matches it by destination - the packet
counters on the --dport rules stayed at 0 while the subnet rule absorbed the
traffic. The declaration is kept as an explicit statement of which ports are
meant to be reachable, and because that subnet detection is gluetun's, not a
guarantee of the chart's: a CNI that hands out a /32 or a future gluetun that
drops the rule would make these the only thing keeping probes and ingress
alive. It is not what opens the ports today.
*/}}
{{- define "freesailarr.firewallInputPorts" -}}
{{- $ports := list -}}
{{- range $app := include "freesailarr.portApps" . | fromJsonArray -}}
{{- $ports = append $ports (int $app.port) -}}
{{- end -}}
{{- $ports = append $ports 9999 -}}
{{- join "," $ports -}}
{{- end -}}
