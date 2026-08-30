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
    {{- include "ytdlp-web-player.resources" .Values.<app>.resources | nindent 12 }}

NOTE: this helper is duplicated into every chart's templates/_helpers.tpl with
the chart's name as define prefix; template-chart/templates/_helpers.tpl is the
reference implementation, and ci/run-quantity-render-test.sh renders every
chart on every PR precisely because a copy can carry an old bug into a diff
nobody reads. The copy is not a leftover of the old "charts have no
dependencies" rule: a library chart would be a second thing to publish,
version and pull for a helper that changes about once a year.
*/}}
{{- define "ytdlp-web-player.resources" -}}
{{- $resources := . | default dict -}}
{{- $factor := 3.0 -}}
{{- if not (kindIs "invalid" $resources.limitFactor) -}}
{{- $factor = float64 $resources.limitFactor -}}
{{- end -}}
{{- $requests := dict -}}
{{- range $key, $value := ($resources.requests | default dict) -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $_ := set $requests (include "ytdlp-web-player.resourceKey" $key) $value -}}
{{- end -}}
{{- end -}}
{{- $limits := dict -}}
{{- range $key, $value := ($resources.limits | default dict) -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $_ := set $limits (include "ytdlp-web-player.resourceKey" $key) $value -}}
{{- end -}}
{{- end -}}
{{- range $key, $request := $requests -}}
{{- if and (ne $key "cpu") (not (hasKey $limits $key)) -}}
{{- $_ := set $limits $key (include "ytdlp-web-player.multiplyQuantity" (dict "quantity" $request "factor" $factor)) -}}
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
{{- define "ytdlp-web-player.resourceKey" -}}
{{- if eq . "ephemeralStorage" -}}ephemeral-storage{{- else -}}{{ . }}{{- end -}}
{{- end -}}

{{/*
Multiply a Kubernetes quantity by a factor, keeping its suffix.
Input: dict "quantity" <string|number> "factor" <float64>.
Handles plain numbers ("2", "0.5", 1073741824), decimal ("1.5Gi"), binary
("512Mi", "1Gi", "10Ki") and milli/SI suffixes ("100m", "500M"). Integer
results are printed without a decimal point.
*/}}
{{- define "ytdlp-web-player.multiplyQuantity" -}}
{{- $quantity := include "ytdlp-web-player.formatNumber" .quantity -}}
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
{{- printf "%s%s" (include "ytdlp-web-player.formatNumber" $product) $suffix -}}
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
{{- define "ytdlp-web-player.formatNumber" -}}
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
  replicas: {{ include "ytdlp-web-player.replicas" (dict "scaleDown" .Values.scaleDown "replicas" .Values.<app>.replicas) }}

NOTE: like the resources helper above, this is a copy carrying this chart's
name as define prefix; template-chart holds the reference implementation.
*/}}
{{- define "ytdlp-web-player.replicas" -}}
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

NOTE: like the helpers above, this is a copy carrying this chart's name as
define prefix; template-chart holds the reference implementation.
*/}}
{{- define "ytdlp-web-player.defaultedDict" -}}
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
{{- $_ := set $out $key (fromYaml (include "ytdlp-web-player.defaultedDict" (dict "defaults" $default "given" $value "path" (printf "%s.%s" $path $key)))) -}}
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
{{- define "ytdlp-web-player.subBlock" -}}
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
{{- define "ytdlp-web-player.podSecurityContext" -}}
{{- $given := (fromYaml (include "ytdlp-web-player.subBlock" (dict "block" . "key" "pod" "path" "ytdlpWebPlayer.securityContext"))).value -}}
{{- $defaults := dict
      "runAsNonRoot" true
      "runAsUser" 20000
      "runAsGroup" 1000
      "fsGroup" 1000
      "fsGroupChangePolicy" "Always"
      "seccompProfile" (dict "type" "RuntimeDefault") -}}
{{- include "ytdlp-web-player.defaultedDict" (dict "defaults" $defaults "given" $given "path" "ytdlpWebPlayer.securityContext.pod") -}}
{{- end -}}

{{- define "ytdlp-web-player.containerSecurityContext" -}}
{{- $given := (fromYaml (include "ytdlp-web-player.subBlock" (dict "block" . "key" "container" "path" "ytdlpWebPlayer.securityContext"))).value -}}
{{- $defaults := dict
      "allowPrivilegeEscalation" false
      "readOnlyRootFilesystem" true
      "runAsNonRoot" true
      "capabilities" (dict "drop" (list "ALL") "add" (list)) -}}
{{- include "ytdlp-web-player.defaultedDict" (dict "defaults" $defaults "given" $given "path" "ytdlpWebPlayer.securityContext.container") -}}
{{- end -}}

{{- define "ytdlp-web-player.livenessProbe" -}}
{{- $defaults := dict
      "httpGet" (dict "path" "/" "port" "http")
      "periodSeconds" 10
      "timeoutSeconds" 5
      "failureThreshold" 3 -}}
{{- include "ytdlp-web-player.defaultedDict" (dict "defaults" $defaults "given" . "path" "ytdlpWebPlayer.livenessProbe") -}}
{{- end -}}

{{- define "ytdlp-web-player.readinessProbe" -}}
{{- $defaults := dict
      "httpGet" (dict "path" "/" "port" "http")
      "periodSeconds" 10
      "timeoutSeconds" 5
      "failureThreshold" 3 -}}
{{- include "ytdlp-web-player.defaultedDict" (dict "defaults" $defaults "given" . "path" "ytdlpWebPlayer.readinessProbe") -}}
{{- end -}}

{{- define "ytdlp-web-player.startupProbe" -}}
{{- $defaults := dict
      "httpGet" (dict "path" "/" "port" "http")
      "periodSeconds" 5
      "timeoutSeconds" 5
      "failureThreshold" 30 -}}
{{- include "ytdlp-web-player.defaultedDict" (dict "defaults" $defaults "given" . "path" "ytdlpWebPlayer.startupProbe") -}}
{{- end -}}

{{/*
The effective resources block, fed into the resources helper above so that an
erased "resources:" still yields the chart's requests and computed limits
instead of a container without any resource accounting.
*/}}
{{- define "ytdlp-web-player.effectiveResources" -}}
{{- $defaults := dict
      "limitFactor" 3
      "requests" (dict "cpu" 0.5 "memory" "512Mi" "ephemeral-storage" "2Gi") -}}
{{- $merged := fromYaml (include "ytdlp-web-player.defaultedDict" (dict "defaults" $defaults "given" . "path" "ytdlpWebPlayer.resources")) -}}
{{- include "ytdlp-web-player.resources" $merged -}}
{{- end -}}

{{/*
The application's listening port, taken from the container port named "http".

Deliberately NOT null-safe, unlike the probe and resources helpers above.
Issue #99 covers the silent class of erased values - a probe that vanishes, a
container that renders unhardened. This one is loud: a missing port yields a
Service pointing nowhere and an application told to listen on "", which fails
at once and in the open. An error that shows itself needs no fallback, and
every extra branch has to be read by someone.

Because of this helper the number lives in exactly one place: it becomes the
PORT environment variable, while the Service and all three probes address the
same entry by NAME.
*/}}
{{- define "ytdlp-web-player.port" -}}
{{- $port := "" -}}
{{- range (.Values.ytdlpWebPlayer.ports | default list) -}}
{{- if eq (.name | default "") "http" -}}
{{- $port = .containerPort -}}
{{- end -}}
{{- end -}}
{{- if or (kindIs "invalid" $port) (eq (printf "%v" $port) "") -}}
{{- fail "ytdlpWebPlayer.ports must contain an entry named \"http\" carrying a containerPort - it is the port the application is told to listen on (PORT), the port the Service targets, and the port all three probes address" -}}
{{- end -}}
{{- printf "%v" $port -}}
{{- end -}}

{{/*
The in-cluster address of this release's application Service - the address the
oauth2-proxy subchart has to carry in its upstreams line.

A helper so that NOTES.txt and the default in values.yaml cannot drift apart.
Note what it may NOT be built from on the subchart side: inside the subchart
.Chart.Name is "oauth2-proxy", so the parent chart's name has to be written out
literally there. Only .Release.Name is shared by both.
*/}}
{{- define "ytdlp-web-player.appServiceAddress" -}}
http://{{ .Release.Name }}-{{ .Chart.Name }}-service:80
{{- end -}}

{{/*
Refuse to render two Ingresses for the same host (issue #214).

With the proxy enabled, this chart's Ingress and the subchart's Ingress can
both be switched on, and both then claim the same host. That is not a merge and
not a warning: ingress-nginx's admission webhook rejects whichever arrives
second with "host ... and path ... is already defined in ingress ...". Under
Fleet the bundle goes to ErrApplied and Fleet does not retry a rejected apply
by itself - getting out costs a forceSyncGeneration bump on the GitRepo.
Failing here costs a re-render.

Host-based rather than "both switched on", because a proxy on a host of its own
collides with nothing. That case is not silently blessed either: NOTES.txt says
plainly that the app's own Ingress is then a way past the proxy.

Called from the Deployment - the one template that always renders - so the
guard cannot be skipped by scaling to zero or by rendering a single file with
"helm template -s".
*/}}
{{- define "ytdlp-web-player.validate" -}}
{{- $proxy := (index .Values "oauth2-proxy") | default dict -}}
{{- $proxyIngress := $proxy.ingress | default dict -}}
{{- if and .Values.ingress.enabled $proxy.enabled $proxyIngress.enabled -}}
{{- if has .Values.ingress.domain ($proxyIngress.hosts | default list) -}}
{{- fail (printf "ingress.enabled and oauth2-proxy.ingress.enabled both claim the host %q. ingress-nginx allows only one Ingress per host and path; its admission webhook rejects the second one, which leaves a Fleet bundle in ErrApplied until forceSyncGeneration is bumped. Decide who owns the host: with the proxy in the data path set ingress.enabled=false (the app is then reached through the proxy and its Service), or drop the proxy's Ingress with oauth2-proxy.ingress.enabled=false." .Values.ingress.domain) -}}
{{- end -}}
{{- end -}}
{{- end -}}
