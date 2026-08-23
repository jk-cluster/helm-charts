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

NOTE: charts in this repo deliberately have no dependencies, so this helper is
duplicated into every chart's templates/_helpers.tpl with the chart's name as
define prefix. template-chart holds the reference implementation.
*/}}
{{- define "rss-bridge.resources" -}}
{{- $resources := . | default dict -}}
{{- $factor := 3.0 -}}
{{- if not (kindIs "invalid" $resources.limitFactor) -}}
{{- $factor = float64 $resources.limitFactor -}}
{{- end -}}
{{- $requests := dict -}}
{{- range $key, $value := ($resources.requests | default dict) -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $_ := set $requests (include "rss-bridge.resourceKey" $key) $value -}}
{{- end -}}
{{- end -}}
{{- $limits := dict -}}
{{- range $key, $value := ($resources.limits | default dict) -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $_ := set $limits (include "rss-bridge.resourceKey" $key) $value -}}
{{- end -}}
{{- end -}}
{{- range $key, $request := $requests -}}
{{- if and (ne $key "cpu") (not (hasKey $limits $key)) -}}
{{- $_ := set $limits $key (include "rss-bridge.multiplyQuantity" (dict "quantity" $request "factor" $factor)) -}}
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
{{- define "rss-bridge.resourceKey" -}}
{{- if eq . "ephemeralStorage" -}}ephemeral-storage{{- else -}}{{ . }}{{- end -}}
{{- end -}}

{{/*
Multiply a Kubernetes quantity by a factor, keeping its suffix.
Input: dict "quantity" <string|number> "factor" <float64>.
Handles plain numbers ("2", "0.5", 1073741824), decimal ("1.5Gi"), binary
("512Mi", "1Gi", "10Ki") and milli/SI suffixes ("100m", "500M"). Integer
results are printed without a decimal point.
*/}}
{{- define "rss-bridge.multiplyQuantity" -}}
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
    explicit 0 - Helm's "default" would swallow 0, hence the explicit
    kindIs "invalid" nil check.
  - a missing replicas value defaults to 1.
*/}}
{{- define "rss-bridge.replicas" -}}
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
an override key written without children - e.g. a leftover

  securityContext:

after deleting its last remaining sub-key - is YAML null. Where the chart
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
  - any other set value wins as given, including an explicit false or 0 -
    Helm's "default" and sprig's "mergeOverwrite" would both swallow those
    zero values, hence the explicit kindIs "invalid" nil check.
  - keys only present in the override are passed through unchanged.
*/}}
{{- define "rss-bridge.defaultedDict" -}}
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
{{- $_ := set $out $key (fromYaml (include "rss-bridge.defaultedDict" (dict "defaults" $default "given" $value "path" (printf "%s.%s" $path $key)))) -}}
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
".Values.rssBridge.securityContext" can itself be erased, and indexing into nil
inside a template is not an error but silently yields nothing.
*/}}
{{- define "rss-bridge.subBlock" -}}
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

Two chart-specific facts a rebuilt default must not lose:

  - uid/gid 33 (www-data) is not a stylistic choice. The image ships /app and
    everything in it owned by www-data, and both nginx and php-fpm are
    configured for that user. A "cleaner" high uid would leave the app unable
    to read its own bridge sources.
  - the ip_unprivileged_port_start sysctl is what lets a non-root nginx bind
    port 80, and this chart has no choice about that port - see the comment on
    it in values.yaml. Dropping it from a rebuilt default does not fail at
    render time; it fails on the first node whose default differs.
  - the probes address the port BY NAME (rss-bridge-port) and use the app's
    own health action. A default that drops the query string would probe the
    1.5 MB front page instead of a 49-byte JSON response, and a default that
    drops the port name would not resolve at all.
*/}}
{{- define "rss-bridge.podSecurityContext" -}}
{{- $given := (fromYaml (include "rss-bridge.subBlock" (dict "block" . "key" "pod" "path" "rssBridge.securityContext"))).value -}}
{{- $defaults := dict
      "runAsNonRoot" true
      "runAsUser" 33
      "runAsGroup" 33
      "fsGroup" 33
      "fsGroupChangePolicy" "Always"
      "seccompProfile" (dict "type" "RuntimeDefault")
      "sysctls" (list (dict "name" "net.ipv4.ip_unprivileged_port_start" "value" "0")) -}}
{{- include "rss-bridge.defaultedDict" (dict "defaults" $defaults "given" $given "path" "rssBridge.securityContext.pod") -}}
{{- end -}}

{{- define "rss-bridge.containerSecurityContext" -}}
{{- $given := (fromYaml (include "rss-bridge.subBlock" (dict "block" . "key" "container" "path" "rssBridge.securityContext"))).value -}}
{{- $defaults := dict
      "allowPrivilegeEscalation" false
      "readOnlyRootFilesystem" true
      "runAsNonRoot" true
      "capabilities" (dict "drop" (list "ALL")) -}}
{{- include "rss-bridge.defaultedDict" (dict "defaults" $defaults "given" $given "path" "rssBridge.securityContext.container") -}}
{{- end -}}

{{/*
The probe target, shared by all three probes.

"/?action=health" is RSS-Bridge's own health action: it renders a fixed JSON
document and touches neither the file cache nor any remote site, so no outage
of a scraped website and no unwritable cache directory can restart the pod
(guideline 3). The front page "/" would be a bad choice for the opposite
reason - it enumerates every bridge and answers with ~1.5 MB.
*/}}
{{- define "rss-bridge.probeHttpGet" -}}
{{- dict "path" "/?action=health" "port" "rss-bridge-port" | toYaml -}}
{{- end -}}

{{- define "rss-bridge.livenessProbe" -}}
{{- $defaults := dict
      "httpGet" (fromYaml (include "rss-bridge.probeHttpGet" .))
      "periodSeconds" 10
      "timeoutSeconds" 5
      "failureThreshold" 3 -}}
{{- include "rss-bridge.defaultedDict" (dict "defaults" $defaults "given" . "path" "rssBridge.livenessProbe") -}}
{{- end -}}

{{- define "rss-bridge.readinessProbe" -}}
{{- $defaults := dict
      "httpGet" (fromYaml (include "rss-bridge.probeHttpGet" .))
      "periodSeconds" 10
      "timeoutSeconds" 5
      "failureThreshold" 3 -}}
{{- include "rss-bridge.defaultedDict" (dict "defaults" $defaults "given" . "path" "rssBridge.readinessProbe") -}}
{{- end -}}

{{- define "rss-bridge.startupProbe" -}}
{{- $defaults := dict
      "httpGet" (fromYaml (include "rss-bridge.probeHttpGet" .))
      "periodSeconds" 5
      "timeoutSeconds" 5
      "failureThreshold" 30 -}}
{{- include "rss-bridge.defaultedDict" (dict "defaults" $defaults "given" . "path" "rssBridge.startupProbe") -}}
{{- end -}}

{{/*
The effective resources block, fed into the resources helper above so that an
erased "resources:" still yields the chart's requests and computed limits
instead of a container without any resource accounting.

The explicit limits are part of the default on purpose - see the measurements
in values.yaml. Reproducing only the requests here would let limitFactor
compute a 384Mi memory limit, which is below the measured concurrent peak.
*/}}
{{- define "rss-bridge.effectiveResources" -}}
{{- $defaults := dict
      "limitFactor" 3
      "requests" (dict "cpu" 0.1 "memory" "128Mi" "ephemeral-storage" "64Mi")
      "limits" (dict "memory" "512Mi" "ephemeral-storage" "2Gi") -}}
{{- $merged := fromYaml (include "rss-bridge.defaultedDict" (dict "defaults" $defaults "given" . "path" "rssBridge.resources")) -}}
{{- include "rss-bridge.resources" $merged -}}
{{- end -}}

{{/*
Group the configured ingress hosts by their TLS secret name.

Returns YAML of dict "order" <list of secret names, in first-appearance order>
and "groups" <secret name -> list of hosts>. Hosts that share a secret name end
up in one tls entry (one certificate with several SANs); hosts with distinct
names keep one certificate each, which is what the existing installation needs
(see the TLS comment in values.yaml).

First-appearance order rather than sorted order, so the rendered tls list can
be compared line by line against the manifest the chart replaces.
*/}}
{{- define "rss-bridge.tlsGroups" -}}
{{- $root := .root -}}
{{- $default := printf "tls-%s-%s-ingress" $root.Release.Name $root.Chart.Name -}}
{{- $groups := dict -}}
{{- $order := list -}}
{{- range $entry := .hosts -}}
{{- $host := required "Every ingress.hosts entry needs a host (ingress.hosts[].host)" $entry.host -}}
{{- $secret := $entry.tlsSecretName | default $default -}}
{{- if not (hasKey $groups $secret) -}}
{{- $_ := set $groups $secret (list) -}}
{{- $order = append $order $secret -}}
{{- end -}}
{{- $_ := set $groups $secret (append (index $groups $secret) $host) -}}
{{- end -}}
{{- toYaml (dict "order" $order "groups" $groups) -}}
{{- end -}}
