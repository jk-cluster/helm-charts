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
{{- $quantity := include "minecraft-server.formatNumber" .quantity -}}
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
{{- printf "%s%s" (include "minecraft-server.formatNumber" $product) $suffix -}}
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
{{- define "minecraft-server.formatNumber" -}}
{{- if kindIs "float64" . -}}
{{- regexReplaceAll "\\.?0+$" (printf "%.10f" .) "" -}}
{{- else -}}
{{- printf "%v" . -}}
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

Since chart 4.0.0 the values block first goes through "defaultedDict" (issue
#99), so an erased "server.resources:" falls back to the chart's requests and
computed limits instead of rendering a container without any resource
accounting. The fallback deliberately leaves the memory request unset, exactly
as values.yaml does, so the derivation from the JVM heap below still applies.

Input: the root context.
*/}}
{{- define "minecraft-server.serverResources" -}}
{{- $defaults := dict
      "limitFactor" 3
      "requests" (dict "cpu" "2" "ephemeral-storage" "100Mi") -}}
{{- $resources := fromYaml (include "minecraft-server.defaultedDict" (dict "defaults" $defaults "given" .Values.server.resources "path" "server.resources")) -}}
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

{{/*
The tag of the itzg/minecraft-server image this release actually runs.

Default: .Chart.AppVersion, exactly as before chart 5.0.0. image.tagOverride
replaces it when set - that is the one way to run a Java line other than the
one this chart version publishes, now that only the newest line is maintained
(see Chart.yaml). The value is deliberately NOT called image.tag: it is an
emergency exit, not a knob to turn in passing, and it is not managed by
Renovate (renovate.json5 tracks appVersion only).
*/}}
{{- define "minecraft-server.imageTag" -}}
{{- $override := "" -}}
{{- if kindIs "map" .Values.image -}}
{{- if not (kindIs "invalid" .Values.image.tagOverride) -}}
{{- $override = printf "%v" .Values.image.tagOverride | trim -}}
{{- end -}}
{{- end -}}
{{- if $override -}}{{ $override }}{{- else -}}{{ .Chart.AppVersion }}{{- end -}}
{{- end -}}

{{/*
Where the effective tag came from - used in the guard's message so the reader
knows which of the two values to change.
*/}}
{{- define "minecraft-server.imageTagSource" -}}
{{- $override := "" -}}
{{- if kindIs "map" .Values.image -}}
{{- if not (kindIs "invalid" .Values.image.tagOverride) -}}
{{- $override = printf "%v" .Values.image.tagOverride | trim -}}
{{- end -}}
{{- end -}}
{{- if $override -}}image.tagOverride{{- else -}}.Chart.AppVersion{{- end -}}
{{- end -}}

{{/*
The Java line the effective image tag carries ("java25", "java17", ...), or the
empty string when the tag does not name one.

regexFind rather than a suffix comparison, so flavoured tags keep working:
"2026.8.2-java25", "java21-alpine" and "latest-java17-jdk" all resolve.
*/}}
{{- define "minecraft-server.javaLine" -}}
{{- regexFind "java[0-9]+" (include "minecraft-server.imageTag" .) -}}
{{- end -}}

{{/*
The Java line minecraft.version requires, or the empty string when the value is
not a version this chart can compare.

The boundaries are Mojang's, not this chart's: they are javaVersion.majorVersion
from the piston-meta version manifest, swept over all 102 releases on 2026-09-02.
The transitions are exactly four, and monotonic in release order:

  1.0    - 1.16.5   java 8    (1.6.1-1.6.4 predate the field and carry none)
  1.17   - 1.17.1   java 16
  1.18   - 1.20.4   java 17
  1.20.5 - 1.21.11  java 21
  26.1   and later  java 25

DELIBERATE GAP: a minecraft.version that is not a plain numeric "x", "x.y" or
"x.y.z" - a snapshot ("26w13a"), a pre-release ("1.21.11-pre1"), "LATEST" -
yields the empty string and is let through unchecked. The chart cannot compare
it, and a guard that rejects everything it does not understand gets worked
around instead of respected. The mismatch then still surfaces the old way:
CrashLoopBackOff once the startup budget is spent, with the reason in the log.
*/}}
{{- define "minecraft-server.requiredJavaLine" -}}
{{- $v := printf "%v" .Values.minecraft.version | trim -}}
{{- if regexMatch "^[0-9]+(\\.[0-9]+){0,2}$" $v -}}
{{- $n := len (splitList "." $v) -}}
{{- $sv := $v -}}
{{- if eq $n 1 -}}{{- $sv = printf "%s.0.0" $v -}}{{- else if eq $n 2 -}}{{- $sv = printf "%s.0" $v -}}{{- end -}}
{{- if semverCompare "< 1.17.0" $sv -}}java8
{{- else if semverCompare "< 1.18.0" $sv -}}java16
{{- else if semverCompare "< 1.20.5" $sv -}}java17
{{- else if semverCompare "< 26.1.0" $sv -}}java21
{{- else -}}java25
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Guard: minecraft.version must fit the Java line of the effective image tag.

Until chart 5.0.0 nothing checked this - a mismatch rendered and installed
without a word, and only the container failed afterwards. It now fails at render
time, which is a behaviour change for an installation that already runs a
mismatched pair (it does not run: it fails earlier and visibly instead).

The check runs ALWAYS, not only when image.tagOverride is set: Helm merges user
values into the chart defaults indistinguishably, so a template cannot tell a
deliberately set minecraft.version from the chart's own default.

DELIBERATE GAP, the second one: an image tag without a recognizable java<N> part
is let through - see minecraft-server.javaLine. Same reasoning as for an
uncomparable minecraft.version.
*/}}
{{- define "minecraft-server.validateJavaLine" -}}
{{- $tag := include "minecraft-server.imageTag" . -}}
{{- $line := include "minecraft-server.javaLine" . -}}
{{- $required := include "minecraft-server.requiredJavaLine" . -}}
{{- if and $line $required -}}
{{- if ne $line $required -}}
{{- $source := include "minecraft-server.imageTagSource" . -}}
{{- $swapped := regexReplaceAll "java[0-9]+" $tag $required -}}
{{- fail (printf (join "\n" (list
  "minecraft-server: the image tag and minecraft.version belong to different Java lines."
  ""
  "  image tag          %-22s is the %s line   (from %s)"
  "  minecraft.version  %-22s needs the %s line"
  ""
  "Java 8 runs Minecraft up to 1.16.5, 1.17-1.17.1 need Java 16, 1.18-1.20.4 need"
  "Java 17, 1.20.5-1.21.11 need Java 21, and 26.1 and later need Java 25 (Mojang's"
  "version manifest, javaVersion.majorVersion per release)."
  ""
  "Change one of the two:"
  "  - set minecraft.version to a release of the %s line, or"
  "  - set image.tagOverride to an itzg/minecraft-server tag of the %s line"
  "    (this tag with its line swapped would be \"%s\" - check that upstream"
  "    published it before using it)."))
  (printf "%q" $tag) $line $source
  (printf "%q" (printf "%v" .Values.minecraft.version)) $required
  $line $required $swapped) -}}
{{- end -}}
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
in this repo deliberately have no dependencies. The reference implementation
lives in template-chart.
*/}}
{{- define "minecraft-server.defaultedDict" -}}
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
{{- $_ := set $out $key (fromYaml (include "minecraft-server.defaultedDict" (dict "defaults" $default "given" $value "path" (printf "%s.%s" $path $key)))) -}}
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
".Values.securityContext" can itself be erased, and indexing into nil inside a
template is not an error but silently yields nothing.
*/}}
{{- define "minecraft-server.subBlock" -}}
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
The effective security contexts and probes (issue #99); the resources block is
covered by "minecraft-server.serverResources" above.

The defaults below MUST stay in sync with the corresponding blocks in
values.yaml, which stays the documented, user-facing place for them; this copy
is only the fallback for the case where an override has erased the block. The
sync is not left to discipline: rendering with every one of these blocks set to
null is byte-identical to rendering the defaults, so a drift shows up.

This chart's deviations from the repo baseline, which a "cleaned up" standard
fallback would silently undo:

  - uid/gid are pinned to 1000, the image's "minecraft" user. The image's
    entrypoint normally starts as root and drops to that user via gosu;
    starting as the user directly takes the non-root branch, which skips the
    recursive chown of /data and the write to /etc/nsswitch.conf that would
    fail on a read-only root filesystem. It is also the uid that owns the
    existing world data on the PVC.
  - fsGroupChangePolicy is OnRootMismatch, not Always: a recursive chown of a
    32Gi world on every pod start costs minutes.
  - the capabilities block carries an explicit empty "add" list alongside
    "drop: [ALL]", matching values.yaml.
  - all three probes run the image's own mc-health script as an EXEC probe -
    a real Minecraft server-list ping via mc-monitor against SERVER_PORT.
    There is no HTTP endpoint to fall back to, so a probe default rebuilt as
    an httpGet would leave this workload with no working probe at all.
  - the startup budget is 15s x 80 = 20 minutes, because on a fresh volume the
    image downloads the server jar and, for FTB/CurseForge modpacks, the whole
    modpack before the world even starts loading.
*/}}
{{- define "minecraft-server.podSecurityContext" -}}
{{- $given := (fromYaml (include "minecraft-server.subBlock" (dict "block" . "key" "pod" "path" "securityContext"))).value -}}
{{- $defaults := dict
      "runAsNonRoot" true
      "runAsUser" 1000
      "runAsGroup" 1000
      "fsGroup" 1000
      "fsGroupChangePolicy" "OnRootMismatch" -}}
{{- include "minecraft-server.defaultedDict" (dict "defaults" $defaults "given" $given "path" "securityContext.pod") -}}
{{- end -}}

{{- define "minecraft-server.containerSecurityContext" -}}
{{- $given := (fromYaml (include "minecraft-server.subBlock" (dict "block" . "key" "container" "path" "securityContext"))).value -}}
{{- $defaults := dict
      "allowPrivilegeEscalation" false
      "readOnlyRootFilesystem" true
      "runAsNonRoot" true
      "capabilities" (dict "drop" (list "ALL") "add" (list)) -}}
{{- include "minecraft-server.defaultedDict" (dict "defaults" $defaults "given" $given "path" "securityContext.container") -}}
{{- end -}}

{{- define "minecraft-server.livenessProbe" -}}
{{- $defaults := dict
      "exec" (dict "command" (list "mc-health"))
      "periodSeconds" 30
      "timeoutSeconds" 10
      "failureThreshold" 3 -}}
{{- include "minecraft-server.defaultedDict" (dict "defaults" $defaults "given" . "path" "livenessProbe") -}}
{{- end -}}

{{- define "minecraft-server.readinessProbe" -}}
{{- $defaults := dict
      "exec" (dict "command" (list "mc-health"))
      "periodSeconds" 15
      "timeoutSeconds" 10
      "failureThreshold" 3 -}}
{{- include "minecraft-server.defaultedDict" (dict "defaults" $defaults "given" . "path" "readinessProbe") -}}
{{- end -}}

{{- define "minecraft-server.startupProbe" -}}
{{- $defaults := dict
      "exec" (dict "command" (list "mc-health"))
      "periodSeconds" 15
      "timeoutSeconds" 10
      "failureThreshold" 80 -}}
{{- include "minecraft-server.defaultedDict" (dict "defaults" $defaults "given" . "path" "startupProbe") -}}
{{- end -}}
