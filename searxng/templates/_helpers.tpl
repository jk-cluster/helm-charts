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
    {{- include "searxng.resources" .Values.<app>.resources | nindent 12 }}

NOTE: charts in this repo deliberately have no dependencies, so this helper is
duplicated into every chart's templates/_helpers.tpl with the chart's name as
define prefix. template-chart holds the reference implementation.
*/}}
{{- define "searxng.resources" -}}
{{- $resources := . | default dict -}}
{{- $factor := 3.0 -}}
{{- if not (kindIs "invalid" $resources.limitFactor) -}}
{{- $factor = float64 $resources.limitFactor -}}
{{- end -}}
{{- $requests := dict -}}
{{- range $key, $value := ($resources.requests | default dict) -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $_ := set $requests (include "searxng.resourceKey" $key) $value -}}
{{- end -}}
{{- end -}}
{{- $limits := dict -}}
{{- range $key, $value := ($resources.limits | default dict) -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $_ := set $limits (include "searxng.resourceKey" $key) $value -}}
{{- end -}}
{{- end -}}
{{- range $key, $request := $requests -}}
{{- if and (ne $key "cpu") (not (hasKey $limits $key)) -}}
{{- $_ := set $limits $key (include "searxng.multiplyQuantity" (dict "quantity" $request "factor" $factor)) -}}
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
{{- define "searxng.resourceKey" -}}
{{- if eq . "ephemeralStorage" -}}ephemeral-storage{{- else -}}{{ . }}{{- end -}}
{{- end -}}

{{/*
Multiply a Kubernetes quantity by a factor, keeping its suffix.
Input: dict "quantity" <string|number> "factor" <float64>.
Handles plain numbers ("2", "0.5", 1073741824), decimal ("1.5Gi"), binary
("512Mi", "1Gi", "10Ki") and milli/SI suffixes ("100m", "500M"). Integer
results are printed without a decimal point.
*/}}
{{- define "searxng.multiplyQuantity" -}}
{{- $quantity := include "searxng.formatNumber" .quantity -}}
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
{{- printf "%s%s" (include "searxng.formatNumber" $product) $suffix -}}
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
{{- define "searxng.formatNumber" -}}
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
  replicas: {{ include "searxng.replicas" (dict "scaleDown" .Values.scaleDown "replicas" .Values.<app>.replicas) }}

NOTE: like the resources helper above, this is duplicated into every chart's
templates/_helpers.tpl with the chart's name as define prefix. template-chart
holds the reference implementation.
*/}}
{{- define "searxng.replicas" -}}
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

Why this exists (issues #61 and #99): Helm merges values maps recursively, but
an override key written without children — e.g. a leftover

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
in this repo deliberately have no dependencies. template-chart holds the
reference implementation.
*/}}
{{- define "searxng.defaultedDict" -}}
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
{{- $_ := set $out $key (fromYaml (include "searxng.defaultedDict" (dict "defaults" $default "given" $value "path" (printf "%s.%s" $path $key)))) -}}
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
".Values.<app>.securityContext" can itself be erased, and indexing into nil
inside a template is not an error but silently yields nothing.
*/}}
{{- define "searxng.subBlock" -}}
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

Two rules that these fallbacks exist to demonstrate (README, "Chart style
guidelines"):

  - Reproduce THIS chart's defaults, not the repo standard. Where a chart
    deviates on purpose (a root-starting image, a non-default limitFactor, a
    pinned uid), the fallback must reproduce the deviation. Restoring the
    "clean" standard here is not tidying, it is an outage - in one chart it
    would move the runtime uid from 1000 to 911 and make existing volume data
    inaccessible.
  - Carry the probe's CONTEXT, not just its timings. A probe default without
    its port name, Host header or exec command is worse than useless: in one
    chart the probe vanished entirely, in another it answered 403 and the pod
    never became Ready.
*/}}
{{- define "searxng.podSecurityContext" -}}
{{- $given := (fromYaml (include "searxng.subBlock" (dict "block" . "key" "pod" "path" "searxng.securityContext"))).value -}}
{{/* 977 is the image's searxng user, deliberately not the repo's generic
     20000/1000: the image creates /etc/searxng and /var/cache/searxng owned
     977:977 and the entrypoint checks that ownership by name. A "cleaned up"
     standard uid here would leave the config mount unreadable. */}}
{{- $defaults := dict
      "runAsNonRoot" true
      "runAsUser" 977
      "runAsGroup" 977
      "fsGroup" 977
      "fsGroupChangePolicy" "Always"
      "seccompProfile" (dict "type" "RuntimeDefault") -}}
{{- include "searxng.defaultedDict" (dict "defaults" $defaults "given" $given "path" "searxng.securityContext.pod") -}}
{{- end -}}

{{- define "searxng.containerSecurityContext" -}}
{{- $given := (fromYaml (include "searxng.subBlock" (dict "block" . "key" "container" "path" "searxng.securityContext"))).value -}}
{{- $defaults := dict
      "allowPrivilegeEscalation" false
      "readOnlyRootFilesystem" true
      "runAsNonRoot" true
      "capabilities" (dict "drop" (list "ALL") "add" (list)) -}}
{{- include "searxng.defaultedDict" (dict "defaults" $defaults "given" $given "path" "searxng.securityContext.container") -}}
{{- end -}}

{{/* All three probe fallbacks use /healthz, not "/", and that path is part of
     the context this fallback has to carry (guideline 5). /healthz is the only
     path SearXNG's bot detection lets through unconditionally
     (searx/limiter.py, filter_request), and its handler returns a fixed "OK"
     without touching an engine or the cache - so liveness hangs on no external
     dependency either. The port NAME matters just as much: the container port
     is named "http" and a fallback without it would address nothing. */}}
{{- define "searxng.livenessProbe" -}}
{{- $defaults := dict
      "httpGet" (dict "path" "/healthz" "port" "http")
      "periodSeconds" 10
      "timeoutSeconds" 5
      "failureThreshold" 3 -}}
{{- include "searxng.defaultedDict" (dict "defaults" $defaults "given" . "path" "searxng.livenessProbe") -}}
{{- end -}}

{{- define "searxng.readinessProbe" -}}
{{- $defaults := dict
      "httpGet" (dict "path" "/healthz" "port" "http")
      "periodSeconds" 10
      "timeoutSeconds" 5
      "failureThreshold" 3 -}}
{{- include "searxng.defaultedDict" (dict "defaults" $defaults "given" . "path" "searxng.readinessProbe") -}}
{{- end -}}

{{- define "searxng.startupProbe" -}}
{{- $defaults := dict
      "httpGet" (dict "path" "/healthz" "port" "http")
      "periodSeconds" 5
      "timeoutSeconds" 5
      "failureThreshold" 30 -}}
{{- include "searxng.defaultedDict" (dict "defaults" $defaults "given" . "path" "searxng.startupProbe") -}}
{{- end -}}

{{/*
The effective resources block, fed into the resources helper above so that an
erased "resources:" still yields the chart's requests and computed limits
instead of a container without any resource accounting.
*/}}
{{- define "searxng.effectiveResources" -}}
{{- $defaults := dict
      "limitFactor" 3
      "requests" (dict "cpu" 0.1 "memory" "256Mi" "ephemeral-storage" "64Mi") -}}
{{- $merged := fromYaml (include "searxng.defaultedDict" (dict "defaults" $defaults "given" . "path" "searxng.resources")) -}}
{{- include "searxng.resources" $merged -}}
{{- end -}}

{{/*
The effective "settings" block, i.e. this chart's user-facing configuration
keys with the same null-safe semantics as the blocks above: an erased
"settings:" means "chart defaults apply" rather than an instance whose name,
safe-search level and image proxy silently become empty.

The defaults MUST stay in sync with the settings block in values.yaml.
*/}}
{{- define "searxng.effectiveSettings" -}}
{{- $defaults := dict
      "instanceName" "SearXNG"
      "safeSearch" 0
      "autocomplete" "duckduckgo"
      "imageProxy" true
      "limiter" false
      "publicInstance" false
      "extra" dict -}}
{{- include "searxng.defaultedDict" (dict "defaults" $defaults "given" . "path" "settings") -}}
{{- end -}}

{{/*
The body of /etc/searxng/settings.yml.

Two things this is doing, both deliberate:

  - It starts from use_default_settings: true and names ONLY the deviations,
    so the ~3500-line settings.yml of the image stays the source of truth for
    engines and every upstream change to them arrives without a chart release.
  - "settings.extra" is merged OVER the block the first-class keys build, with
    defaultedDict rather than sprig's mergeOverwrite. That difference is
    load-bearing: mergeOverwrite drops zero values from the source, so an
    "extra" entry setting some flag to false or 0 would be silently ignored -
    a config value that looks set and does nothing, which is exactly the class
    of bug the schema work (#68) exists to remove.

server.secret_key is deliberately absent: it arrives as SEARXNG_SECRET from
the 1Password Secret (settings_defaults.py lets the environment override the
file), so the signing key never lands in a ConfigMap.
*/}}
{{- define "searxng.settingsYaml" -}}
{{- $settings := fromYaml (include "searxng.effectiveSettings" .Values.settings) -}}
{{- $base := dict
      "use_default_settings" true
      "general" (dict "instance_name" $settings.instanceName)
      "search" (dict "safe_search" $settings.safeSearch "autocomplete" $settings.autocomplete)
      "server" (dict
        "limiter" $settings.limiter
        "public_instance" $settings.publicInstance
        "image_proxy" $settings.imageProxy) -}}
{{- $merged := fromYaml (include "searxng.defaultedDict" (dict "defaults" $base "given" $settings.extra "path" "settings.extra")) -}}
{{- toYaml $merged -}}
{{- end -}}
