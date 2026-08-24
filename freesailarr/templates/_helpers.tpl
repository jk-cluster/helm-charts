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

{{/*
Recursive merge of an override onto defaults where null never deletes and set
values always win, including false and 0 (issue #99).

Input: dict "defaults" <dict> "given" <dict|nil> "path" <values path, for errors>.

NOTE: like the resources helper above, this is duplicated into every chart's
templates/_helpers.tpl with the chart's name as define prefix. The reference
implementation lives in template-chart.
*/}}
{{- define "freesailarr.defaultedDict" -}}
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
{{- $_ := set $out $key (fromYaml (include "freesailarr.defaultedDict" (dict "defaults" $default "given" $value "path" (printf "%s.%s" $path $key)))) -}}
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
Needed because ".Values.<app>.securityContext" can itself be erased, and
indexing into nil inside a template is not an error but silently yields
nothing.
*/}}
{{- define "freesailarr.subBlock" -}}
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
The chart's own defaults for every block of the "silent class" from issue #99 -
security contexts, probes and resources. An override that erases one of these
blocks (`key:` with no children, i.e. null) would otherwise render a container
without hardening, without a probe or without resource accounting: it comes up,
reports green and is quietly weaker. The accessors below merge the user's block
onto these defaults with freesailarr.defaultedDict, where null never deletes.

These MUST stay in sync with values.yaml, which remains the documented,
user-facing place for them; this copy is only the fallback. The sync is not left
to discipline: rendering the chart with every one of these blocks explicitly set
to null must produce byte-identical output to rendering it with the defaults,
which is how the table was verified and how a drift shows up.

Two rules this table exists to honour (README, "Chart style guidelines"):

  - It reproduces THIS chart's defaults, deviations included, not the repo
    standard. The five linuxserver.io containers deliberately run without
    runAsNonRoot and with a writable root filesystem, because their s6-overlay
    init starts as root and drops to PUID/PGID; "restoring" the clean standard
    here would leave them on the image's built-in uid 911 and make the existing
    media volumes inaccessible - the exact failure calibre-web-automated hit.
    flaresolverr's numerically pinned uid/gid 1000 and gluetun's NET_ADMIN are
    reproduced for the same reason.
  - The probe defaults carry their CONTEXT, not just timings: every httpGet
    keeps its path and port, and recyclarr - which serves no HTTP port in
    daemon mode - keeps its exec command. A probe default without them is worse
    than no default.
*/}}
{{- define "freesailarr.fallbacks" -}}
gluetun:
  livenessProbe:
    httpGet:
      path: /
      port: 9999
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 6
  readinessProbe:
    httpGet:
      path: /
      port: 9999
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  startupProbe:
    httpGet:
      path: /
      port: 9999
    periodSeconds: 5
    timeoutSeconds: 5
    failureThreshold: 30
  resources:
    limitFactor: 3
    requests:
      cpu: 0.1
      memory: 128Mi
      ephemeralStorage: 50Mi
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: false
    capabilities:
      drop:
        - ALL
      add:
        - NET_ADMIN
qbittorrent:
  livenessProbe:
    httpGet:
      path: /
      port: 8080
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  readinessProbe:
    httpGet:
      path: /
      port: 8080
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  startupProbe:
    httpGet:
      path: /
      port: 8080
    periodSeconds: 5
    timeoutSeconds: 5
    failureThreshold: 30
  resources:
    limitFactor: 3
    requests:
      cpu: 0.2
      memory: 512Mi
      ephemeralStorage: 100Mi
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: false
    capabilities:
      drop:
        - ALL
      add:
        - CHOWN
        - DAC_OVERRIDE
        - FOWNER
        - SETGID
        - SETUID
prowlarr:
  livenessProbe:
    httpGet:
      path: /ping
      port: 9696
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  readinessProbe:
    httpGet:
      path: /ping
      port: 9696
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  startupProbe:
    httpGet:
      path: /ping
      port: 9696
    periodSeconds: 5
    timeoutSeconds: 5
    failureThreshold: 30
  resources:
    limitFactor: 3
    requests:
      cpu: 0.1
      memory: 256Mi
      ephemeralStorage: 100Mi
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: false
    capabilities:
      drop:
        - ALL
      add:
        - CHOWN
        - DAC_OVERRIDE
        - FOWNER
        - SETGID
        - SETUID
flaresolverr:
  livenessProbe:
    httpGet:
      path: /health
      port: 8191
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  readinessProbe:
    httpGet:
      path: /health
      port: 8191
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  startupProbe:
    httpGet:
      path: /health
      port: 8191
    periodSeconds: 5
    timeoutSeconds: 5
    failureThreshold: 30
  resources:
    limitFactor: 3
    requests:
      cpu: 0.2
      memory: 512Mi
      ephemeralStorage: 200Mi
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: false
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    capabilities:
      drop:
        - ALL
radarr:
  livenessProbe:
    httpGet:
      path: /ping
      port: 7878
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  readinessProbe:
    httpGet:
      path: /ping
      port: 7878
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  startupProbe:
    httpGet:
      path: /ping
      port: 7878
    periodSeconds: 5
    timeoutSeconds: 5
    failureThreshold: 30
  resources:
    limitFactor: 3
    requests:
      cpu: 0.1
      memory: 256Mi
      ephemeralStorage: 100Mi
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: false
    capabilities:
      drop:
        - ALL
      add:
        - CHOWN
        - DAC_OVERRIDE
        - FOWNER
        - SETGID
        - SETUID
recyclarr:
  livenessProbe:
    exec:
      command:
        - recyclarr
        - --version
    periodSeconds: 30
    timeoutSeconds: 10
    failureThreshold: 3
  readinessProbe:
    exec:
      command:
        - recyclarr
        - --version
    periodSeconds: 30
    timeoutSeconds: 10
    failureThreshold: 3
  startupProbe:
    exec:
      command:
        - recyclarr
        - --version
    periodSeconds: 5
    timeoutSeconds: 10
    failureThreshold: 30
  resources:
    limitFactor: 3
    requests:
      cpu: 0.05
      memory: 128Mi
      ephemeralStorage: 50Mi
  securityContext:
    runAsUser: {{ .Values.puid }}
    runAsGroup: {{ .Values.pgid }}
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    capabilities:
      drop:
        - ALL
sonarr:
  livenessProbe:
    httpGet:
      path: /ping
      port: 8989
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  readinessProbe:
    httpGet:
      path: /ping
      port: 8989
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  startupProbe:
    httpGet:
      path: /ping
      port: 8989
    periodSeconds: 5
    timeoutSeconds: 5
    failureThreshold: 30
  resources:
    limitFactor: 3
    requests:
      cpu: 0.1
      memory: 256Mi
      ephemeralStorage: 100Mi
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: false
    capabilities:
      drop:
        - ALL
      add:
        - CHOWN
        - DAC_OVERRIDE
        - FOWNER
        - SETGID
        - SETUID
seerr:
  livenessProbe:
    httpGet:
      path: /api/v1/settings/public
      port: 5055
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  readinessProbe:
    httpGet:
      path: /api/v1/settings/public
      port: 5055
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  startupProbe:
    httpGet:
      path: /api/v1/settings/public
      port: 5055
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 30
  resources:
    limitFactor: 3
    requests:
      cpu: 0.1
      memory: 256Mi
      ephemeralStorage: 100Mi
  securityContext:
    runAsUser: {{ .Values.puid }}
    runAsGroup: {{ .Values.pgid }}
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    capabilities:
      drop:
        - ALL
bazarr:
  livenessProbe:
    httpGet:
      path: /
      port: 6767
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  readinessProbe:
    httpGet:
      path: /
      port: 6767
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  startupProbe:
    httpGet:
      path: /
      port: 6767
    periodSeconds: 5
    timeoutSeconds: 5
    failureThreshold: 30
  resources:
    limitFactor: 3
    requests:
      cpu: 0.1
      memory: 256Mi
      ephemeralStorage: 100Mi
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: false
    capabilities:
      drop:
        - ALL
      add:
        - CHOWN
        - DAC_OVERRIDE
        - FOWNER
        - SETGID
        - SETUID
configInit:
  resources:
    limitFactor: 3
    requests:
      cpu: 10m
      memory: 16Mi
      ephemeralStorage: 1Mi
  securityContext:
    runAsUser: {{ .Values.puid }}
    runAsGroup: {{ .Values.pgid }}
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
{{- end -}}

{{/*
The effective pod security context. Separate from the per-container table
because it is the one block shared by all nine containers.
*/}}
{{- define "freesailarr.podSecurityContext" -}}
{{- $given := (fromYaml (include "freesailarr.subBlock" (dict "block" .Values.securityContext "key" "pod" "path" "securityContext"))).value -}}
{{- $defaults := dict
      "fsGroup" 1000
      "fsGroupChangePolicy" "OnRootMismatch"
      "seccompProfile" (dict "type" "RuntimeDefault") -}}
{{- include "freesailarr.defaultedDict" (dict "defaults" $defaults "given" $given "path" "securityContext.pod") -}}
{{- end -}}

{{/*
The effective probe / security context / resources for one container.

Input: dict "root" $ "app" <key in the fallback table> "given" <the values block>
       and, for probes, "kind" <livenessProbe|readinessProbe|startupProbe>.

"given" is passed in rather than derived from "app" because the qbittorrent init
container's blocks live under qbittorrent.configInit, not under a top-level key
of the same name.
*/}}
{{- define "freesailarr.probeFor" -}}
{{- $fb := fromYaml (include "freesailarr.fallbacks" .root) -}}
{{- $defaults := index $fb .app .kind -}}
{{- include "freesailarr.defaultedDict" (dict "defaults" $defaults "given" .given "path" (printf "%s.%s" .app .kind)) -}}
{{- end -}}

{{- define "freesailarr.securityContextFor" -}}
{{- $fb := fromYaml (include "freesailarr.fallbacks" .root) -}}
{{- $defaults := index $fb .app "securityContext" -}}
{{- include "freesailarr.defaultedDict" (dict "defaults" $defaults "given" .given "path" (printf "%s.securityContext" .app)) -}}
{{- end -}}

{{- define "freesailarr.resourcesFor" -}}
{{- $fb := fromYaml (include "freesailarr.fallbacks" .root) -}}
{{- $defaults := index $fb .app "resources" -}}
{{- $merged := fromYaml (include "freesailarr.defaultedDict" (dict "defaults" $defaults "given" .given "path" (printf "%s.resources" .app))) -}}
{{- include "freesailarr.resources" $merged -}}
{{- end -}}
