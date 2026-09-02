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
    {{- include "satisfactory.resources" .Values.<app>.resources | nindent 12 }}

NOTE: charts in this repo deliberately have no dependencies, so this helper is
duplicated into every chart's templates/_helpers.tpl with the chart's name as
define prefix. This file in template-chart is the reference implementation.
*/}}
{{- define "satisfactory.resources" -}}
{{- $resources := . | default dict -}}
{{- $factor := 3.0 -}}
{{- if not (kindIs "invalid" $resources.limitFactor) -}}
{{- $factor = float64 $resources.limitFactor -}}
{{- end -}}
{{- $requests := dict -}}
{{- range $key, $value := ($resources.requests | default dict) -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $_ := set $requests (include "satisfactory.resourceKey" $key) $value -}}
{{- end -}}
{{- end -}}
{{- $limits := dict -}}
{{- range $key, $value := ($resources.limits | default dict) -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $_ := set $limits (include "satisfactory.resourceKey" $key) $value -}}
{{- end -}}
{{- end -}}
{{- range $key, $request := $requests -}}
{{- if and (ne $key "cpu") (not (hasKey $limits $key)) -}}
{{- $_ := set $limits $key (include "satisfactory.multiplyQuantity" (dict "quantity" $request "factor" $factor)) -}}
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
{{- define "satisfactory.resourceKey" -}}
{{- if eq . "ephemeralStorage" -}}ephemeral-storage{{- else -}}{{ . }}{{- end -}}
{{- end -}}

{{/*
Multiply a Kubernetes quantity by a factor, keeping its suffix.
Input: dict "quantity" <string|number> "factor" <float64>.
Handles plain numbers ("2", "0.5", 1073741824), decimal ("1.5Gi"), binary
("512Mi", "1Gi", "10Ki") and milli/SI suffixes ("100m", "500M"). Integer
results are printed without a decimal point.
*/}}
{{- define "satisfactory.multiplyQuantity" -}}
{{- $quantity := include "satisfactory.formatNumber" .quantity -}}
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
{{- printf "%s%s" (include "satisfactory.formatNumber" $product) $suffix -}}
{{- end -}}
{{- end -}}

{{/*
Render a number as a plain decimal string, never in exponential notation.

Why this exists (issue #157): the null-safe fallback helpers pass values
through fromYaml, which parses every number as float64. Go's "%v" switches
float64 to exponential notation from about 1e6 upwards, so a bare byte count
like 1048576 became "1.048576e+06" - not a valid Kubernetes quantity, and the
render aborted. Strings ("512Mi") are passed through untouched.
*/}}
{{- define "satisfactory.formatNumber" -}}
{{- if kindIs "float64" . -}}
{{- regexReplaceAll "\\.?0+$" (printf "%.10f" .) "" -}}
{{- else -}}
{{- printf "%v" . -}}
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
  replicas: {{ include "satisfactory.replicas" (dict "scaleDown" .Values.scaleDown "replicas" .Values.<app>.replicas) }}

NOTE: like the resources helper above, this is duplicated into every chart's
templates/_helpers.tpl with the chart's name as define prefix. This file in
template-chart is the reference implementation.
*/}}
{{- define "satisfactory.replicas" -}}
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

after deleting its last remaining sub-key — is YAML null. Where the chart
defines a default, Helm treats that null as a deletion of the default; the
template then renders "securityContext: null": no readOnlyRootFilesystem, no
dropped capabilities, no allowPrivilegeEscalation: false. The workload starts
and reports healthy while being unhardened, so nothing points at the mistake.
The same shape erases a probe (it disappears) or the resources block (no
requests, no computed limits). This helper defines the opposite semantics: an
empty block means "chart defaults apply".

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
{{- define "satisfactory.defaultedDict" -}}
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
{{- $_ := set $out $key (fromYaml (include "satisfactory.defaultedDict" (dict "defaults" $default "given" $value "path" (printf "%s.%s" $path $key)))) -}}
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
".Values.securityContext" can itself be erased.
*/}}
{{- define "satisfactory.subBlock" -}}
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
The effective security contexts, probes and resources (issue #99).

The defaults below MUST stay in sync with the corresponding blocks in
values.yaml, which stays the documented, user-facing place for them; this copy
is only the fallback for the case where an override has erased the block.

Like teamspeak-server, this chart keeps these blocks at the TOP level of
values.yaml, so the paths in the error messages have no chart-name prefix.

Probe specifics that a rebuilt default must not lose:
  - liveness and startup run the image's own healthcheck script via exec. It
    queries the server's HTTPS API on SERVERGAMEPORT, so it keeps working when
    the port is overridden - which a tcpSocket default could not do.
  - readiness uses the named "api" port.
  - the startup budget is deliberately huge (30s x 40 = 20 minutes): the
    server downloads and updates the game files via Steam on first start.
*/}}
{{- define "satisfactory.podSecurityContext" -}}
{{- $given := (fromYaml (include "satisfactory.subBlock" (dict "block" . "key" "pod" "path" "securityContext"))).value -}}
{{- $defaults := dict
      "runAsNonRoot" true
      "runAsUser" 1000
      "runAsGroup" 1000
      "fsGroup" 1000
      "fsGroupChangePolicy" "OnRootMismatch"
      "seccompProfile" (dict "type" "RuntimeDefault") -}}
{{- include "satisfactory.defaultedDict" (dict "defaults" $defaults "given" $given "path" "securityContext.pod") -}}
{{- end -}}

{{- define "satisfactory.containerSecurityContext" -}}
{{- $given := (fromYaml (include "satisfactory.subBlock" (dict "block" . "key" "container" "path" "securityContext"))).value -}}
{{- $defaults := dict
      "allowPrivilegeEscalation" false
      "readOnlyRootFilesystem" true
      "runAsNonRoot" true
      "capabilities" (dict "drop" (list "ALL") "add" (list)) -}}
{{- include "satisfactory.defaultedDict" (dict "defaults" $defaults "given" $given "path" "securityContext.container") -}}
{{- end -}}

{{- define "satisfactory.healthcheckExec" -}}
{{- dict "command" (list "/bin/sh" "-c" "/home/steam/healthcheck.sh") | toYaml -}}
{{- end -}}

{{- define "satisfactory.livenessProbe" -}}
{{- $defaults := dict
      "exec" (fromYaml (include "satisfactory.healthcheckExec" .))
      "failureThreshold" 4
      "successThreshold" 1
      "periodSeconds" 30
      "timeoutSeconds" 10 -}}
{{- include "satisfactory.defaultedDict" (dict "defaults" $defaults "given" . "path" "livenessProbe") -}}
{{- end -}}

{{- define "satisfactory.readinessProbe" -}}
{{- $defaults := dict
      "tcpSocket" (dict "port" "api")
      "periodSeconds" 10
      "timeoutSeconds" 5
      "failureThreshold" 3 -}}
{{- include "satisfactory.defaultedDict" (dict "defaults" $defaults "given" . "path" "readinessProbe") -}}
{{- end -}}

{{- define "satisfactory.startupProbe" -}}
{{- $defaults := dict
      "exec" (fromYaml (include "satisfactory.healthcheckExec" .))
      "periodSeconds" 30
      "timeoutSeconds" 10
      "failureThreshold" 40 -}}
{{- include "satisfactory.defaultedDict" (dict "defaults" $defaults "given" . "path" "startupProbe") -}}
{{- end -}}

{{/*
The effective game block (issue #99, found alongside #215).

"--set game=null" — or a leftover "game:" with all sub-keys deleted — used to
abort the render with a nil-pointer error at .Values.game.maxPlayers, because
this block never got the null-safe treatment the probes, security contexts and
resources have. It now falls back to the same defaults values.yaml documents.

The defaults below MUST stay in sync with the game block in values.yaml.
Note that enableSeasonalEvents defaults to FALSE: that is what keeps
DISABLESEASONALEVENTS at "true", the value this chart has always rendered.
*/}}
{{- define "satisfactory.game" -}}
{{- $defaults := dict
      "experimental" false
      "maxPlayers" 4
      "enableSeasonalEvents" false -}}
{{- include "satisfactory.defaultedDict" (dict "defaults" $defaults "given" . "path" "game") -}}
{{- end -}}

{{/*
Render the DISABLESEASONALEVENTS env value from game.enableSeasonalEvents
(issue #215).

The image only offers the negative switch, so the chart negates the positive
value here — that is the whole point of the rename: the key says what it does
and the env var keeps the name the image expects.

Go's "not" cannot do this: it treats every non-empty string as true, so the
string form "false" (which fleet bundles habitually write for booleans, and
which the schema therefore accepts) would flip the wrong way. Hence the
explicit comparison — and an explicit fail for anything that is neither, so a
typo like "yes" cannot be silently read as "events off". Null never reaches
here; satisfactory.game has already replaced it with the default.
*/}}
{{- define "satisfactory.disableSeasonalEvents" -}}
{{- $raw := printf "%v" . -}}
{{- if eq (lower $raw) "true" -}}
false
{{- else if eq (lower $raw) "false" -}}
true
{{- else -}}
{{- fail (printf "game.enableSeasonalEvents must be true or false (boolean or string), got %q" $raw) -}}
{{- end -}}
{{- end -}}

{{/*
The effective resources block, fed into the resources helper above so that an
erased "resources:" still yields the chart's requests and computed limits.
The limitFactor default stays 2 here (not the repo-wide 3): the game server
holds a large world in memory and the factor keeps the memory limit at the
previously published 8Gi.
*/}}
{{- define "satisfactory.effectiveResources" -}}
{{- $defaults := dict
      "limitFactor" 2
      "requests" (dict "memory" "4Gi" "cpu" "1" "ephemeral-storage" "5Gi") -}}
{{- $merged := fromYaml (include "satisfactory.defaultedDict" (dict "defaults" $defaults "given" . "path" "server.resources")) -}}
{{- include "satisfactory.resources" $merged -}}
{{- end -}}
