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
    {{- include "patchmon.resources" .Values.<app>.resources | nindent 12 }}

NOTE: charts in this repo deliberately have no dependencies, so this helper is
duplicated into every chart's templates/_helpers.tpl with the chart's name as
define prefix. This file in template-chart is the reference implementation.
*/}}
{{- define "patchmon.resources" -}}
{{- $resources := . | default dict -}}
{{- $factor := 3.0 -}}
{{- if not (kindIs "invalid" $resources.limitFactor) -}}
{{- $factor = float64 $resources.limitFactor -}}
{{- end -}}
{{- $requests := dict -}}
{{- range $key, $value := ($resources.requests | default dict) -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $_ := set $requests (include "patchmon.resourceKey" $key) $value -}}
{{- end -}}
{{- end -}}
{{- $limits := dict -}}
{{- range $key, $value := ($resources.limits | default dict) -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $_ := set $limits (include "patchmon.resourceKey" $key) $value -}}
{{- end -}}
{{- end -}}
{{- range $key, $request := $requests -}}
{{- if and (ne $key "cpu") (not (hasKey $limits $key)) -}}
{{- $_ := set $limits $key (include "patchmon.multiplyQuantity" (dict "quantity" $request "factor" $factor)) -}}
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
{{- define "patchmon.resourceKey" -}}
{{- if eq . "ephemeralStorage" -}}ephemeral-storage{{- else -}}{{ . }}{{- end -}}
{{- end -}}

{{/*
Multiply a Kubernetes quantity by a factor, keeping its suffix.
Input: dict "quantity" <string|number> "factor" <float64>.
Handles plain numbers ("2", "0.5", 1073741824), decimal ("1.5Gi"), binary
("512Mi", "1Gi", "10Ki") and milli/SI suffixes ("100m", "500M"). Integer
results are printed without a decimal point.
*/}}
{{- define "patchmon.multiplyQuantity" -}}
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

Usage (the values path to the workload's replicas varies per chart):
  replicas: {{ include "patchmon.replicas" (dict "scaleDown" .Values.scaleDown "replicas" .Values.<app>.replicas) }}

NOTE: like the resources helper above, this is duplicated into every chart's
templates/_helpers.tpl with the chart's name as define prefix. This file in
template-chart is the reference implementation.
*/}}
{{- define "patchmon.replicas" -}}
{{- if .scaleDown -}}
0
{{- else if not (kindIs "invalid" .replicas) -}}
{{- .replicas -}}
{{- else -}}
1
{{- end -}}
{{- end -}}

{{/*
Merge a user-supplied values sub-tree onto a dict of chart defaults so that a
null / empty override falls back to the defaults instead of erasing them.

Input: dict "defaults" <dict> "given" <dict|nil> "path" <string, optional
values path used in error messages>. Output: YAML of the merged dict (consume
it with fromYaml).

Why this exists (issue #99): Helm merges values maps recursively, but an
override key written without children — e.g. a leftover

  securityContext:

after deleting its last remaining sub-key — is YAML null and replaces the
whole default sub-tree. The container then renders with "securityContext:
null": no readOnlyRootFilesystem, no dropped capabilities, no
allowPrivilegeEscalation: false. The workload starts and reports healthy while
being unhardened, so nothing points at the mistake. The same shape erases a
probe (it disappears) or the resources block (no requests, no computed
limits). This helper defines the opposite semantics: an empty block means
"chart defaults apply".

Rules:
  - a nil "given" is treated as an empty dict (all defaults apply).
  - a key whose override value is null keeps the default (nulls never delete).
  - a key present in both as a map is merged recursively, so a partially
    filled block only overrides the keys it actually sets.
  - a scalar override for a key the defaults define as a map is rejected with
    a message naming the values path, instead of failing later with a template
    field error.
  - any other set value wins as given, including an explicit false or 0 —
    Helm's "default" and sprig's "mergeOverwrite" would both swallow those
    zero values, hence the explicit kindIs "invalid" nil check.
  - keys only present in the override are passed through unchanged.

NOTE: like the helpers above, this is duplicated into every chart's
templates/_helpers.tpl with the chart's name as define prefix, because charts
in this repo deliberately have no dependencies.
*/}}
{{- define "patchmon.defaultedDict" -}}
{{- $defaults := .defaults | default dict -}}
{{- $given := .given -}}
{{- $path := .path | default "value" -}}
{{- if kindIs "invalid" $given -}}
{{- $given = dict -}}
{{- end -}}
{{- if not (kindIs "map" $given) -}}
{{- fail (printf "%s must be a mapping or null, got %s (%v)" $path (kindOf $given) $given) -}}
{{- end -}}
{{- $out := deepCopy $defaults -}}
{{- range $key, $value := $given -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $default := index $defaults $key -}}
{{- if and (kindIs "map" $value) (kindIs "map" $default) -}}
{{- $_ := set $out $key (fromYaml (include "patchmon.defaultedDict" (dict "defaults" $default "given" $value "path" (printf "%s.%s" $path $key)))) -}}
{{- else if kindIs "map" $default -}}
{{- fail (printf "%s.%s must be a mapping or null, got %s (%v)" $path $key (kindOf $value) $value) -}}
{{- else -}}
{{- $_ := set $out $key $value -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Pick one sub-block out of a values block that may itself be null.

Input: dict "block" <dict|nil> "key" <string> "path" <string>.
Returns YAML of dict "value" <the sub-block, may be nil>, after rejecting a
non-mapping block with a message that names the values path. Needed because
".Values.patchmon.<workload>.securityContext" can itself be erased.
*/}}
{{- define "patchmon.subBlock" -}}
{{- $block := .block -}}
{{- if kindIs "invalid" $block -}}
{{- $block = dict -}}
{{- end -}}
{{- if not (kindIs "map" $block) -}}
{{- fail (printf "%s must be a mapping or null, got %s (%v)" .path (kindOf $block) $block) -}}
{{- end -}}
{{- toYaml (dict "value" (index $block .key)) -}}
{{- end -}}

{{/*
The effective security contexts, probes and resources of both workloads
(issue #99).

The defaults below MUST stay in sync with the corresponding blocks in
values.yaml, which stays the documented, user-facing place for them; this copy
is only the fallback for the case where an override has erased the block.

The server probes carry a Host header, because the 2.x server rejects requests
whose Host is neither loopback nor a CORS_ORIGIN host. The default is built
from .Values.ingress.domain via the passed-in root context, so the probe
helpers take dict "given" <block|nil> "root" $.
*/}}
{{- define "patchmon.server.podSecurityContext" -}}
{{- $given := (fromYaml (include "patchmon.subBlock" (dict "block" . "key" "pod" "path" "patchmon.server.securityContext"))).value -}}
{{- $defaults := dict
      "runAsNonRoot" true
      "runAsUser" 65532
      "runAsGroup" 65532
      "seccompProfile" (dict "type" "RuntimeDefault") -}}
{{- include "patchmon.defaultedDict" (dict "defaults" $defaults "given" $given "path" "patchmon.server.securityContext.pod") -}}
{{- end -}}

{{- define "patchmon.server.containerSecurityContext" -}}
{{- $given := (fromYaml (include "patchmon.subBlock" (dict "block" . "key" "container" "path" "patchmon.server.securityContext"))).value -}}
{{- $defaults := dict
      "allowPrivilegeEscalation" false
      "readOnlyRootFilesystem" true
      "runAsNonRoot" true
      "capabilities" (dict "drop" (list "ALL")) -}}
{{- include "patchmon.defaultedDict" (dict "defaults" $defaults "given" $given "path" "patchmon.server.securityContext.container") -}}
{{- end -}}

{{- define "patchmon.guacd.containerSecurityContext" -}}
{{- $given := (fromYaml (include "patchmon.subBlock" (dict "block" . "key" "container" "path" "patchmon.guacd.securityContext"))).value -}}
{{- $defaults := dict
      "allowPrivilegeEscalation" false
      "readOnlyRootFilesystem" true
      "runAsNonRoot" true
      "runAsUser" 1000
      "runAsGroup" 1000
      "capabilities" (dict "drop" (list "ALL")) -}}
{{- include "patchmon.defaultedDict" (dict "defaults" $defaults "given" $given "path" "patchmon.guacd.securityContext.container") -}}
{{- end -}}

{{- define "patchmon.server.httpGet" -}}
{{- dict "path" "/health" "port" 3000 "httpHeaders" (list (dict "name" "Host" "value" (.root.Values.ingress.domain | default ""))) | toYaml -}}
{{- end -}}

{{- define "patchmon.server.livenessProbe" -}}
{{- $defaults := dict
      "httpGet" (fromYaml (include "patchmon.server.httpGet" .))
      "periodSeconds" 10
      "timeoutSeconds" 5
      "failureThreshold" 3 -}}
{{- include "patchmon.defaultedDict" (dict "defaults" $defaults "given" .given "path" "patchmon.server.livenessProbe") -}}
{{- end -}}

{{- define "patchmon.server.readinessProbe" -}}
{{- $defaults := dict
      "httpGet" (fromYaml (include "patchmon.server.httpGet" .))
      "periodSeconds" 10
      "timeoutSeconds" 5
      "failureThreshold" 3 -}}
{{- include "patchmon.defaultedDict" (dict "defaults" $defaults "given" .given "path" "patchmon.server.readinessProbe") -}}
{{- end -}}

{{- define "patchmon.server.startupProbe" -}}
{{- $defaults := dict
      "httpGet" (fromYaml (include "patchmon.server.httpGet" .))
      "periodSeconds" 10
      "timeoutSeconds" 5
      "failureThreshold" 60 -}}
{{- include "patchmon.defaultedDict" (dict "defaults" $defaults "given" .given "path" "patchmon.server.startupProbe") -}}
{{- end -}}

{{- define "patchmon.guacd.livenessProbe" -}}
{{- $defaults := dict
      "tcpSocket" (dict "port" 4822)
      "periodSeconds" 10
      "timeoutSeconds" 5
      "failureThreshold" 3 -}}
{{- include "patchmon.defaultedDict" (dict "defaults" $defaults "given" . "path" "patchmon.guacd.livenessProbe") -}}
{{- end -}}

{{- define "patchmon.guacd.readinessProbe" -}}
{{- $defaults := dict
      "tcpSocket" (dict "port" 4822)
      "periodSeconds" 10
      "timeoutSeconds" 5
      "failureThreshold" 3 -}}
{{- include "patchmon.defaultedDict" (dict "defaults" $defaults "given" . "path" "patchmon.guacd.readinessProbe") -}}
{{- end -}}

{{- define "patchmon.guacd.startupProbe" -}}
{{- $defaults := dict
      "tcpSocket" (dict "port" 4822)
      "periodSeconds" 5
      "timeoutSeconds" 5
      "failureThreshold" 30 -}}
{{- include "patchmon.defaultedDict" (dict "defaults" $defaults "given" . "path" "patchmon.guacd.startupProbe") -}}
{{- end -}}

{{/*
The effective resources blocks, fed into the resources helper above so that an
erased "resources:" still yields the chart's requests and computed limits
instead of a container without any resource accounting.
*/}}
{{- define "patchmon.server.effectiveResources" -}}
{{- $defaults := dict
      "limitFactor" 3
      "requests" (dict "cpu" 0.1 "memory" "256Mi" "ephemeral-storage" "10Mi") -}}
{{- $merged := fromYaml (include "patchmon.defaultedDict" (dict "defaults" $defaults "given" . "path" "patchmon.server.resources")) -}}
{{- include "patchmon.resources" $merged -}}
{{- end -}}

{{- define "patchmon.guacd.effectiveResources" -}}
{{- $defaults := dict
      "limitFactor" 3
      "requests" (dict "cpu" 0.05 "memory" "64Mi" "ephemeral-storage" "10Mi") -}}
{{- $merged := fromYaml (include "patchmon.defaultedDict" (dict "defaults" $defaults "given" . "path" "patchmon.guacd.resources")) -}}
{{- include "patchmon.resources" $merged -}}
{{- end -}}
