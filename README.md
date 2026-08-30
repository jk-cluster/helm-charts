# helm-charts

Collection of some self-made helm-charts. Each top-level directory is a standalone Helm chart that gets packaged and pushed to a private OCI registry (JK-Registry) via GitHub Actions.

## Charts

| Chart | Deploys | Notes |
|---|---|---|
| `apache-tika` | Apache Tika | Deployment + Service only (no ingress) |
| `bentopdf` | BentoPDF | Stateless Deployment + `config.json` ConfigMap, `subPath`-mounted into the web root and always rendered (empty renders as `{}`) |
| `calibre-web-automated` | Calibre-Web Automated | StatefulSet, extra consume-PVC |
| `cyberchef` | CyberChef | Stateless Deployment |
| `freesailarr` | gluetun VPN media stack (qbittorrent, prowlarr, flaresolverr, radarr, recyclarr, sonarr, seerr, bazarr) | Single-pod StatefulSet: all apps share gluetun's network namespace; config volumes via volumeClaimTemplates, media PVCs as existingClaims (optional per-category `subPath`, so one claim can serve all three categories). One ClusterIP Service per app; no global `ingress.domain`. Ingress in two shapes that mix: one host per app (default, each app's host required), or one shared `ingress.host` with the apps as sub-paths (documented ingress exception below) |
| `gotenberg` | Gotenberg | Deployment + Service only (no ingress) |
| `homeassistant` | Home Assistant | StatefulSet; the only chart carrying Helm tests (`templates/tests/`) |
| `matrix-synapse` | Matrix Synapse | StatefulSet plus an nginx delegation Deployment/Service |
| `minecraft-router` | itzg/mc-router | Deployment + routing ConfigMap + NodePort Service (TCP only, no ingress); `mappings` is a required value |
| `minecraft-server` | itzg/minecraft-server | StatefulSet + PVC + Service + init-script ConfigMap (no ingress); service type is a value (`ClusterIP` by default, routed via `minecraft-router`). Published once per Java line — the image tag comes from `.Chart.AppVersion`, so the Java line is chosen by picking the chart version, and `minecraft.version` ships a default matching that line. Since chart 2.0.0 the tag is an **immutable dated upstream release** (`appVersion: <release>-java8` / `-java17` / `-java21`, e.g. `2026.8.2-java8`) instead of the continuously rebuilt rolling line tag. Pilot for the strict `values.schema.json` (#68), which is now binding for every chart |
| `outline` | Outline | StatefulSet, separate DB/Redis secrets |
| `paperless-ngx` | Paperless-ngx | Largest chart: consume CronJob, SMB-connector PV/PVC, pre/post-consumption scripts ConfigMap |
| `patchmon` | PatchMon | Two Deployments (frontend + backend), OIDC secret |
| `rallly` | Rallly | Deployment, DB/OIDC/SMTP secrets |
| `rss-bridge` | RSS-Bridge | Deployment + whitelist ConfigMap; `ingress.hosts` is a required list of host + optional `tlsSecretName`, so several hosts can keep their own existing certificates (documented deviation from the one-TLS-secret rule, see its `values.yaml`) |
| `samba` | Samba | StatefulSet, users secret + config ConfigMap |
| `satisfactory` | Satisfactory game server | StatefulSet, no ingress |
| `searxng` | SearXNG | Stateless Deployment + settings ConfigMap (`use_default_settings: true` plus a free-form `settings.extra` passthrough); the signing key is a required `OnePasswordItem`, an external Valkey an optional second one. `ingress.domain` is read twice — Ingress host and `SEARXNG_BASE_URL` — so it stays required with the Ingress switched off |
| `teamspeak-server` | TeamSpeak server | StatefulSet, no ingress |
| `template-chart` | — | Scaffold for new charts (placeholder `xxx`), never published |
| `urlaubsverwaltung` | Urlaubsverwaltung | Deployment, DB + OIDC secrets |
| `voucher-vault` | VoucherVault | StatefulSet, DB + OIDC secrets |
| `ytdlp-web-player` | ytdlp_web_player | Stateless Deployment, video cache and tool cache as emptyDirs (no PVC). **The only chart with a dependency**: an optional `oauth2-proxy` subchart, off by default, wired in front of the app because the application ships no authentication at all — see "Chart dependencies" below |
| `zipline` | Zipline | StatefulSet, DB secret |

## Versioning

`Chart.yaml` uses the scheme `version: <chart-semver>+up<app-version>` (e.g. `1.4.0+up1.9.2`) — see the [chart style guidelines](#chart-style-guidelines) for the full rules (suffix normalization, semver bump levels).

- Bump the **chart version** in every change that touches a chart directory — a push to `main` publishes the chart.
- **App-version updates go through PRs** (so the validate and install-test pipelines run). The manually dispatched `Change App-Version` workflow (rewrites `version:`/`appVersion:` and commits directly to `main`) exists but bypasses both pipelines. For app **major** jumps, update stepwise: first to the last release of the old major line (own PR, merge, publish), then to the newest major.

## CI/CD (GitHub Actions)

- `publish-<chart>.yml` — one thin workflow per chart; triggers on pushes to `main` touching `<chart>/**` (or manually) and calls the reusable workflow below. **A push to a chart directory on `main` publishes that chart**, so the chart version must be bumped in the same change.
- `publish-helm-chart.yml` — reusable workflow: `helm package`, then `helm push` to the private JK-Registry. Registry credentials come from 1Password Connect (`OP_CONNECT_TOKEN` secret, items under `op://GitHub-Actions/`). The loaded values are read via **`steps.<id>.outputs.*`**, mapped into each step's own `env:` block and used as quoted shell variables — never interpolated into the command line. `load-secrets-action` **v5 no longer exports them as environment variables** for later steps the way v4 did, so after the v5 bump every `${{ env.JK_CR_* }}` reference resolved to an empty string while the loading step still logged `Populating variable` and stayed green. Each value is additionally guarded with `:?`, because an empty one used to collapse into a missing argument rather than an error: `-u` consumed the following `--password-stdin`, helm fell back to an interactive prompt and the job died with `inappropriate ioctl for device` — a terminal error for what was really an unset variable.
- `change-app-version.yml` — manually dispatched app-version bump; the chart must be listed in its `chart-name` choice list.
- `ci/helm-dependencies.sh <chart-dir>` — not a workflow but the step they all share: fetches a chart's declared dependencies into `charts/`, and returns silently for the charts that declare none (all but one). It runs in **five** places, because every helm command this repo builds on exits 1 while a declared dependency is missing: before lint and package in `validate-charts.yml`, before package in `publish-helm-chart.yml`, and inside `ci/run-install-test.sh`, `ci/run-quantity-render-test.sh` and `ci/run-trivy-config.sh`. See "Chart dependencies" in the style guidelines for what that costs.
- `validate-charts.yml` — PR pipeline: detects which charts a PR touches and, for exactly those, runs `helm lint --strict`, `helm package`, and a chart-version bump check (`template-chart` is exempt from the version check). PRs without chart changes skip the build matrix. After the build stage, an **install-test** job (same changed-charts matrix) installs each changed chart into an ephemeral [k3d](https://k3d.io) cluster on the runner and requires every workload to become Ready — see below. Both matrices follow the changed chart directories, so a PR that only changes the harness under `ci/` exercises nothing by itself; the Trivy scan has a fixed-sample fallback for that case, the install-test has none — bump the affected chart's patch version to pull it into the matrix. The **resource-quantity render test** is the exception to that rule: it runs over every chart on every PR — see below.

### Resource-quantity render test (all charts, every PR)

`ci/run-quantity-render-test.sh [chart …]` (no argument = all charts) renders every chart twice with the fixtures the install-test and the Trivy scan already use, injecting a bare integer memory request at **every** `resources` block the chart's `values.schema.json` declares:

| Case | Injected | Expected limit | Catches |
|---|---|---|---|
| `bare-int` | `requests.memory: 1048576`, `limitFactor: 2` | `2097152` | render aborts |
| `fraction` | `requests.memory: 999999`, `limitFactor: 1.5` | `1499998.5` | quantity in exponential notation |

The two cases exist because the bug behind #157 — quantities formatted with `printf "%v"`, where the `float64` the null-safe fallback helpers produce flips to exponential notation from about `1e6` — has a loud and a silent half. Loud: the reformatted quantity carries the suffix `e+06`, the helper rejects it, `helm template` exits non-zero. Silent: the *product* of a fractional `limitFactor` and a bare number is reformatted **after** the suffix check, so the render succeeds and the manifest carries `memory: "1.4999985e+06"` — rejected by nothing until the API server sees it at apply time. A check on the exit code alone therefore proves only half the case; the second case searches the **rendered text** for a resource quantity in exponential notation. `999999` stays below `1e6` on purpose, so the fraction case isolates the second formatting site instead of tripping over the first.

Why all charts rather than the changed ones: the resources helper is copied into every chart's `templates/_helpers.tpl` rather than shared through a library chart. The regression arrives by copy — a new chart started from an older chart, or from `template-chart` before the fix — and in that PR the copied bug is in no diff anyone reads. Running over everything also removes the list nobody would maintain: adding a chart enrolls it automatically. Two renders per chart, no cluster, a few seconds for the whole repo; the job depends on nothing else and finishes well inside the `build-chart` runtime.

Two details worth knowing before touching it:

- **The resources paths come from `values.schema.json`, not `values.yaml`** — it is JSON, so `python3` reads it without pyyaml (same runner constraint as `ci/run-trivy-config.sh`), and every chart-owned key must appear there anyway. A block counts when it is `#/definitions/resources` or carries `limitFactor`/`requests` itself, which is what keeps `minecraft-server`'s JVM-sizing `minecraft.resources` out. A chart whose templates render a resources block while its schema declares none **fails** the test with exactly that message: the schema is then out of sync with the chart.
- **A chart that never reaches the helper is reported, not counted as passing.** `gotenberg` sets every computable limit explicitly in its fallback defaults, and since a `null` never deletes a default there, no override can free them — nothing is multiplied, so nothing is proven. Those charts appear under "helper not reached" in the job summary rather than as a green tick for a code path that was never entered.

### Install-test (PR pipeline stage 2)

For every chart a PR changes, `ci/run-install-test.sh <chart>` runs against a throwaway k3d cluster: it applies the stub `OnePasswordItem` CRD plus the chart's fixtures, `helm install`s the chart with its CI values, and waits for all Deployments/StatefulSets to roll out (per-chart timeout). Since probes and security hardening are active on all workloads, "Ready" means the app actually answers. On failure the job dumps pod descriptions, events and container logs.

Fixtures live at the **repo root** under `ci/` (deliberately *not* inside the chart directories, so they are neither packaged into the chart tgz nor trigger the publish workflows on merge):

- `ci/common/` — fixtures applied for every chart (schema-less stub CRD for `OnePasswordItem`)
- `ci/<chart>/test-values.yaml` — values for the CI install (required for every installable chart)
- `ci/<chart>/fixtures.yaml` — dummy secrets with in-cluster connection data, throwaway infrastructure (postgres/redis/dex), static hostPath PVs/StorageClasses where the chart pins a storage class or needs RWX, and seed jobs (e.g. `synapse generate`)
- `ci/<chart>/fixtures.env.yaml` — fixtures that need a value which must not be committed. The file holds `${VARIABLE}` placeholders and nothing else; `ci/run-install-test.sh` renders it with `envsubst` and pipes the result straight into `kubectl` (never printed). Substitution is restricted to the names from `REQUIRED_ENV`, so an undeclared variable is never filled in and no unrelated `$…` in the manifest is touched
- `ci/<chart>/settings.env` — optional overrides: `INSTALL_TIMEOUT` for slow starters, and `REQUIRED_ENV="VAR_A VAR_B"` to declare the variables `fixtures.env.yaml` needs. **A missing or empty declared variable fails the install-test loudly, naming the variable — it never skips the chart.** Skipping would restore exactly the green-but-meaningless signal this mechanism exists to remove; the one legitimate case of absent secrets, a PR from a fork, belongs in an `if` on the workflow job rather than in the script
- `ci/excluded-charts.txt` — charts that cannot run in CI, each with a justification. Currently: `satisfactory` (multi-GB image + 10GB+ Steam download), `template-chart` (scaffold with placeholder image)

`freesailarr` is the only chart using `fixtures.env.yaml` today: gluetun needs a real Wireguard key, or it never completes a handshake and no app container behind its kill switch becomes Ready. The install-test job loads the key from 1Password Connect for that chart only, using the same pattern as `publish-helm-chart.yml` — `steps.<id>.outputs.*` into the step's own `env:`, quoted, with `:?` guards that name the missing `op://` field before the cluster is even created. The key in that item is a **CI-only Mullvad key**, deliberately not the production one: Mullvad ties an address to a key and routes the tunnel to the endpoint it saw last, so a shared key would make every PR run pull the tunnel out from under the running stack — with the symptom in the cluster and the cause in a pull request.

Fixture images avoid Docker Hub where possible (`public.ecr.aws`/`ghcr.io`) to dodge runner rate limits. The job **blocks the PR** on failure — the stabilization phase of #22 ended when Renovate started automerging patch/minor updates, since a chart that no longer starts must not reach `main` and publish unattended. When adding a new chart, add its `ci/<chart>/` fixtures (or an entry in `ci/excluded-charts.txt`) — the install-test fails if both are missing. The script also runs locally against any existing cluster: `k3d cluster create t && ci/run-install-test.sh <chart> && k3d cluster delete t`.

## Dependency updates (Renovate)

Renovate runs as the self-hosted `jlab-renovate` GitHub App. Its config is **`renovate.json5`** in the repo root (JSON5 for the inline reasoning; requires Renovate >= 41 for `managerFilePatterns`/`customType`). There must be exactly one config file — do not add a second `renovate.json` or `.github/renovate.json`.

What Renovate keeps current:

| What | How |
| --- | --- |
| Chart app versions (`appVersion:` in `Chart.yaml`) | One `customManagers` entry per chart, hard-coding the image repository |
| Sidecar/init images in `values.yaml` (nginx, guacd, busybox, alpine) | Built-in `helm-values` manager |
| **All** images of `freesailarr`, including its main one | Built-in `helm-values` manager — the chart pins every tag in `values.yaml` and has no app-version block |
| GitHub Actions | Built-in `github-actions` manager |
| Tool versions pinned as workflow env vars (`TRIVY_VERSION`) | `# renovate: datasource=… depName=…` comment above the line |

Each chart renders its main image as `<repo>:{{ .Chart.AppVersion }}` — repository in the template, version in `Chart.yaml`. Renovate cannot join two files, so the mapping lives in `renovate.json5`, one block per chart. It is deliberately *not* a `# renovate:` comment inside each `Chart.yaml`: that would touch all chart directories and force a version bump plus a publish per chart for a pure comment change. Charts whose tags carry a flavour or date suffix (`apache-tika`, `minecraft-server`, `rss-bridge`, `searxng`, `teamspeak-server`) override `versioning` in their block; the reasoning sits next to each one.

One rule those overrides share, learned from `searxng` and worth knowing before writing the next one: **a capture group is a claim about how the value is compared.** Renovate's regex versioning parses `major`, `minor`, `patch`, `build` and `revision` with `Number.parseInt` (`modules/versioning/regex/index.js`, `_parse`), so a non-numeric commit hash captured as `build` becomes whatever digits lead it — `9fea41204` is `9`, `777ba8fa4` is `777`, and a hash starting with a letter is `NaN`. Measured on renovate 41.173.1 and 44.48.0, that makes Renovate offer an image pushed *earlier the same day* as an update to a newer one, unattended under the patch/minor automerge rule. Parts of a tag that carry no ordering belong **outside** every group: the anchored pattern still requires them to be there, they simply take no part in the comparison. `prerelease` is not the way out either — it sorts correctly but marks every tag `isStable === false`, which hands the whole chart to `ignoreUnstable`. `freesailarr` has no block on purpose — see the images exception above; a block would either duplicate the `helm-values` updates or rewrite an `appVersion` that selects no image.

A consequence of pinning every tag in `values.yaml`: `ci/renovate-bump-chart.sh` sees an unchanged `appVersion` and bumps the chart **patch**. That holds for all nine images alike — none of them is special — and it is the intended outcome, since `appVersion` here is the chart's own marker rather than a tracked upstream version.

Two dependencies are constrained beyond their versioning. **nginx** (the Synapse delegation sidecar) is limited to **even minors** via `allowedVersions`. nginx numbers its release branches by minor — even is stable, odd is mainline — and the chart belongs on stable. Patch updates inside the stable branch still flow through normally. The constraint tolerates a variant suffix (`1.30.4-alpine`) on purpose: docker versioning only ever offers candidates carrying the current tag's suffix, so a suffix-blind constraint would silently freeze nginx the day the sidecar moves to a slimmer base image — a switch to `1.30.4-alpine` that #84 has commissioned a check on — with no error and no warning.

**linuxserver/qbittorrent** (freesailarr) excludes two tags by name, `14.3.9` and `20.04.1`. They are leftovers from earlier linuxserver tagging schemes, and docker versioning sorts both above every real release, so Renovate offers them as major updates — PRs #152 and #153 were exactly that. They are named rather than cut off with an upper bound like `<10`, because a bound would eventually reject a genuine major, while two finished artifacts cannot grow and therefore cannot hide a future release. The same guard as for nginx applies and was run: a lookup from `currentValue 4.6.4` still offers `5.2.3` as a **major**, so the filter does not silently empty the update list. That fixture also shows the cost of leaving it alone — without the rule the very same lookup offers `20.04.1` and never mentions the real `5.2.3`, since Renovate fills the major bucket only once.

Not managed: `ci/**` (install-test fixtures pin throwaway infrastructure to major lines on purpose) and `template-chart/**` (placeholder image). A consequence worth knowing: `ci/matrix-synapse/fixtures.yaml` pins a Synapse image that Renovate will not follow — bump it by hand when the chart moves a major.

### The version-bump hook

Renovate only rewrites `appVersion:` or an image tag; it knows nothing about `version: <chart-semver>+up<app-version>`. Left alone, every chart PR would fail the `build-chart` version check. `ci/renovate-bump-chart.sh <chart-dir>` closes that gap and is wired up as a `postUpgradeTasks` command:

- **app major changed** → chart major (`6.0.0` → `7.0.0`), matching "runtime behavior changes" in the semver conventions
- **anything else** (plain app update, sidecar image) → chart patch
- the `+up` suffix is recomputed from the new `appVersion`, dashes normalized to dots

Everything is derived from the base commit, so the script is idempotent across the multiple updates a single Renovate branch can carry.

> **One-time setup outside this repo:** `postUpgradeTasks` only runs on self-hosted Renovate **and** only when the command is allow-listed in the *instance* config:
>
> ```yaml
> allowedCommands: ["^ci/renovate-bump-chart\\.sh"]
> ```
>
> Without that entry Renovate skips the task without an error and every chart PR stays red on the version check.

If the dependency dashboard reports `Failed to look up github-releases package …: no-result` for third-party repos, that is the instance's GitHub credentials, not this config: a GitHub App installation token is not a good fit for looking up repos the app is not installed on. Give the instance a separate read-only PAT as `GITHUB_COM_TOKEN` for github.com datasource lookups.

### PR policy

- **Automerge** for `patch`, `minor` and `digest` updates, after a `minimumReleaseAge` of 3 days and only once the PR pipeline is green — install-test included, which is why that job no longer runs with `continue-on-error`. Minor is in scope because the sidecar images barely move in patch steps (`alpine 3.22` → `3.24`, `nginx 1.30.4` → `1.31.4` are both minor), so a patch-only rule would practically never fire. Renovate merges itself rather than using GitHub auto-merge, which would merge immediately as long as `main` has no required status checks. Majors are merged by hand.
- **Majors** arrive one line at a time (`separateMultipleMajor`): a v1 → v3 jump produces a PR for the latest v2 first and then one for v3 — the stepwise procedure the versioning section requires.
- `prConcurrentLimit: 10` / `prHourlyLimit: 4` keep the k3d install-tests from all starting at once.
- The manually dispatched `change-app-version.yml` still exists for one-off bumps, but the normal path for app updates is now a Renovate PR.

## Creating a new chart

1. Copy `template-chart/` to `<chart-name>/` and replace every `xxx` placeholder: template file names (`xxx.deployment.yaml` → `<app>.deployment.yaml`), `Chart.yaml`, the `values.yaml` keys, the `.Values.xxx.*` references inside the templates, **and both the `xxx.` helper prefixes and the values paths in `values.schema.json`**. Then walk the five points in "Values that must not lie" below — the schema and the null-safe fallbacks are copied with the template, but their content is chart-specific and wrong until you adapt it. The same goes for `templates/NOTES.txt`: it comes with the template as a worked example and is placeholder text until you replace it with what an operator of *your* app needs after the install (see "Everything else" below); its leading `{{/* … */}}` block explains the bar and is meant to be deleted.
2. Add `.github/workflows/publish-<chart-name>.yml` (copy an existing one, e.g. `publish-outline.yml`).
3. Add the chart name to the choice list in `.github/workflows/change-app-version.yml`.
4. Add a `customManagers` block for the chart's main image in `renovate.json5` (copy a neighbouring one, swap `managerFilePatterns` and `depNameTemplate`) — without it the chart's app version is never updated. Check the image's tag list first: if it carries a flavour, date or prerelease suffix, add a `versioningTemplate` with a comment saying why. **Floating tags belong outside the pattern**: `ytdlp-web-player` anchors its versioning regex on the `v` prefix precisely so `latest` and `stable` — both of which move — can never be selected.
5. Only if the chart needs a **dependency**: read "Chart dependencies" in the style guidelines first, it is a bar rather than a formality. Nothing has to be added to the pipelines — `ci/helm-dependencies.sh` already runs everywhere and keys off the `dependencies:` block — but the subchart's own updates then depend entirely on Renovate's built-in `helmv3` manager plus a chart-version bump, which is the part to write down at the pinned version.

Validate locally with:

```bash
helm lint --strict <chart-name>
helm template <chart-name> --set ingress.domain=example.com --set ingress.clusterIssuer=letsencrypt
```

(required values vary per chart)

For runtime verification (do the workloads actually start, do probes/security settings hold?), use a throwaway local [k3d](https://k3d.io) cluster: `k3d cluster create <name>`, apply a stub CRD for `OnePasswordItem` plus dummy secrets (and throwaway postgres/redis pods where the app needs them), `helm install` the chart, watch pod readiness/events, then `k3d cluster delete <name>`.

## Chart style guidelines

These guidelines are **binding for every current and future chart** in this repo. They are the consolidated end state of the conventions overhaul (#32, batches 0–4); `template-chart/` is the reference implementation.

### 1. Naming

- Resources are named `{{ .Release.Name }}-{{ .Chart.Name }}-<kind>` (e.g. `...-deployment`, `...-sfs`, `...-service`, `...-secret`, `...-configmap`, `...-ingress`, `...-pvc`).
- Template files are named `<app>.<kind>.yaml`; stateful apps use a StatefulSet in a `<app>.sfs.yaml` template instead of a deployment.
- **Documented exception — existing PVC names**: PVCs of already-published charts keep their historical names even where they deviate from the scheme. Renaming a PVC makes Kubernetes provision a new, empty volume, so a rename would orphan the existing data. New charts name PVCs `{{ .Release.Name }}-{{ .Chart.Name }}-pvc` per the scheme.
- StatefulSet renames are possible (data survives because the charts use standalone PVC templates, not `volumeClaimTemplates`) but only ship in a major-bump PR with a one-time migration note: `kubectl delete statefulset <old> --cascade=orphan` (and delete the leftover old pod) before upgrading.

### 2. Versioning

- `Chart.yaml` uses `version: <chart-semver>+up<appVersion>`; the `+up` suffix matches `appVersion`, with dashes normalized to dots (e.g. `0.0.36-beta` → `+up0.0.36.beta`). `appVersion` is the **exact image tag** of the main app image.
- Semver rules for the chart part:
  - **Patch**: bug fixes without behavior or values-schema change; plain app-version updates.
  - **Minor**: additive, backward-compatible changes (new optional values with unchanged defaults).
  - **Major**: runtime behavior changes or breaking values changes (e.g. resource renames, probes, security hardening, values that become required).
- Any push to `main` touching a chart directory publishes that chart, so the version must be bumped in the same change.

### 3. Images

- The main app image tag comes from `{{ .Chart.AppVersion }}` — never hardcoded.
- **Documented exception — freesailarr**: the chart bundles nine independently versioned upstreams, so none of them is "the" app version. **No** tag comes from `appVersion`; all nine images are pinned as `<app>.image.repository` / `<app>.image.tag` in `values.yaml`, which is also what puts every one of them under the built-in `helm-values` manager. Its `appVersion` is the chart's own version marker, freely chosen and tied to no upstream — raised by hand when a new edition of the chart is marked as a whole. Consequently the chart has **no** block in `renovate.json5` and is **not** in the `change-app-version.yml` choice list.
- Auxiliary images (sidecars, init containers, secondary workloads — e.g. the delegation nginx in matrix-synapse, guacd in patchmon, busybox init/consume images in paperless-ngx) are pinned via values instead of being hardcoded in templates, and their pinned versions are reviewed alongside every app-version update round.

### 4. Ingress

- `ingress.domain` and `ingress.clusterIssuer` (cert-manager) are `required` values **without defaults** — every installation sets both explicitly; they are the only values needed for a default install.
- `ingress.className` selects the ingress class and defaults to `nginx`.
- `ingress.annotations` takes optional extra annotations that are merged with the cert-manager `cluster-issuer` annotation the chart always sets.
- The TLS secret is named `tls-<release>-<chart>-ingress`.
- **Documented exception — homeassistant**: keeps its upstream-style flexible ingress values (host/tls lists, no required values); only its `ingress.className` default follows the standard (`nginx`, clearable to omit the field).
- **A shared domain with sub-paths is the second admissible ingress shape.** Where a chart exposes several apps, they may either each take a host of their own or share one host and be told apart by path (`domain.tld/sonarr`, `domain.tld/radarr`, …) — one DNS name and one certificate for the whole bundle. The rules for the shared shape: the domain is a single value (`ingress.host`), each app's path is its own value defaulting to `/<app>`, the paths render in one Ingress object `<release>-<chart>-ingress` with the standard TLS secret `tls-<release>-<chart>-ingress`, and an app that carries a host of its own always wins and keeps its own object — so both shapes mix without extra values. An app that needs a per-path proxy annotation (`rewrite-target` is per **object**, not per path) gets its own object on the same host, repeating the same TLS secret name and **omitting** the cert-manager annotation, so that exactly one certificate is requested. Apps that cannot serve a base path must be rendered at `/` or refused with a `fail` — never rendered somewhere they provably cannot work.
- **Documented exception — freesailarr**: the chart bundles several independently exposed apps in one pod, so it has **no** `ingress.domain`. It offers both shapes. By default each app carries its own `<app>.ingress.enabled` plus a required `<app>.ingress.host` (required only while that app's ingress is enabled and it is not on the shared domain) and renders its own Ingress object `<release>-<chart>-<app>-ingress` with its own TLS secret `tls-<release>-<chart>-<app>-ingress`. Setting the global `ingress.host` switches every app without a host of its own to the shared-domain shape under `<app>.ingress.path`; qBittorrent (no base path, needs a prefix-stripping rewrite) gets the extra object described above, and seerr is pinned to `/`. `clusterIssuer`, `className` and `annotations` stay global defaults under `ingress.` and are overridable per app.

### 5. Security hardening

- Defaults on every workload: `automountServiceAccountToken: false`, non-root user, `readOnlyRootFilesystem: true`, all capabilities dropped, `allowPrivilegeEscalation: false`.
- Pod and container contexts are values-configurable via `securityContext.pod` / `securityContext.container`.
- Writable paths (e.g. `/tmp`, nginx cache dirs, s6-overlay's `/run`) are emptyDirs so the root filesystem stays read-only.
- Where an image cannot satisfy the full standard (e.g. Home Assistant must start as root for s6-overlay, paperless needs a root init container to hand over `/run`, samba needs its capabilities), the deviation is minimal and **must** be justified with a comment in that chart's `values.yaml`.

### 6. Probes

- Every workload has liveness, readiness and startup probes (documented exception: the paperless-ngx consume CronJob).
- Probes are values-configurable with calibrated defaults (the startup probe gates liveness/readiness; its budget is documented in a values comment per chart).

### 7. Resources (auto-limits)

- Resource requests ship as chart defaults in `values.yaml` and are user-overridable.
- Limits are computed by a per-chart `_helpers.tpl` helper (reference implementation in `template-chart/templates/_helpers.tpl`): an explicitly set limit always wins, missing memory and ephemeral-storage limits default to `resources.limitFactor` × the request (factor default `3`), and a CPU limit is only rendered when set explicitly — otherwise CPU stays unlimited (it is compressible, throttling instead of OOM-killing). The helper is copied into every chart rather than shared through a library chart — which would be a second artifact to publish, version and pull for a helper that changes about once a year; the resource-quantity render test above exists because a copy can carry an old bug into a diff nobody reads.

### 8. Secrets

- Secrets are **1Password `OnePasswordItem` CRs**: values expose `secrets.<name>SecretRef` holding an `op://` item path; the 1Password operator materializes the Kubernetes Secret in-cluster.

### 9. Config changes must restart the workload (#82)

- **Every workload that consumes a ConfigMap carries a `checksum/config` annotation on its pod template** — one line per ConfigMap it consumes:

  ```yaml
  template:
    metadata:
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/<chart>.configmap.yaml") . | sha256sum }}
  ```

  Reference implementation: `template-chart/templates/xxx.deployment.yaml` and `xxx.sfs.yaml`. Where a workload consumes several ConfigMaps, use one annotation per file with a distinguishing suffix (`checksum/config-<name>`).
- **Why it is mandatory, not optional**: without it a changed ConfigMap does not change the pod template, so nothing restarts and the running container keeps the old config — silently. `subPath` mounts (the usual form here) are never refreshed by the kubelet at all, and most apps read their config only at start. In #82 this produced a real outage: the router kept routing to Services that no longer existed while every bundle was green and the pod was Ready.
- **The annotation is content-based, not time-based**: the hash is taken over the rendered ConfigMap, so an unchanged config renders an identical hash and `helm upgrade` is a no-op. It never degenerates into a restart-on-every-upgrade.
- Adding the annotation to an existing chart is a **major** bump (§2): runtime behavior changes — a config change now costs a restart. Name that cost in the PR (some workloads take minutes to come back).
- **Secrets from `OnePasswordItem` cannot use this mechanism.** Helm never sees their content — the 1Password operator fills the Secret in-cluster after rendering, so there is nothing to hash. A chart that mounts such a Secret as a file documents the limitation in its `values.yaml` where it cannot close the gap.
- **What *can* be covered is the secret's `op://` path**, via a **separately named** `checksum/secret-ref` annotation over the rendered `OnePasswordItem`:

  ```yaml
  checksum/secret-ref: {{ include (print $.Template.BasePath "/<chart>.secret.yaml") . | sha256sum }}
  ```

  Repointing `secrets.<name>SecretRef` at a different vault item then takes effect instead of silently leaving the old credentials in the running pod. The separate name is deliberate: `checksum/config` promises "the config changed", `checksum/secret-ref` only "the config *source* changed" — merging them into one annotation would overstate the weaker guarantee. Reference implementations: `minecraft-server`, `homeassistant`.
- **`operator.1password.io/auto-restart` only works for Deployments — do not set it on a StatefulSet.** Verified against onepassword-operator **1.12.0** (`pkg/onepassword/secret_update_handler.go`): `restartWorkloadsWithUpdatedSecrets` enumerates exactly one workload type, `appsv1.DeploymentList`, and `getPodTemplate` accepts only `*appsv1.Deployment`. The RBAC role grants `statefulsets`, and v1.11.0 generalized the restart code (`restartWorkload`, pod-template stamping via `operator.1password.io/last-restarted`), but the PR that would add StatefulSets is still open — so the annotation on a StatefulSet is a silent no-op. Setting it there is **worse than not setting it**: it advertises a guarantee that does not exist. Affected charts (`matrix-synapse`, `samba`, `homeassistant`) instead document the manual `kubectl rollout restart statefulset <release>-<chart>-sfs`. Re-check this when the operator version is bumped; a Deployment-based chart may set the annotation.
- If a Deployment-based chart ever does set it, mind the precedence: the annotation on the **`OnePasswordItem`** is copied onto the Kubernetes Secret and read first, so a `false` there **overrides** a `true` on the workload — the opposite of what the operator's usage guide suggests. Lookup order is Secret (from the `OnePasswordItem`) → workload → namespace → the operator-global `AUTO_RESTART` env var. The trigger is the 1Password item's **version counter**, not its content, so a re-save with identical values still restarts.

### 10. Environment variables

- Every workload container offers an additive `env` value block, appended to the env entries the chart always sets.
- Entries are rendered through `tpl` (so values may contain Helm templating) and support the `value`, `secretKeyRef` and `configMapKeyRef` forms (pattern: `template-chart/templates/xxx.deployment.yaml`).

### 11. Scaling

- Every Deployment/StatefulSet has a `replicas` value (default `1`, the values path per workload matches its section) that also accepts an explicit `0` for per-workload fine control.
- Every chart has a global `scaleDown` flag (default `false`): `scaleDown: true` takes precedence over all `replicas` values, renders every Deployment/StatefulSet with `replicas: 0` and suspends CronJobs. It **stops** the app but does not uninstall it — PVCs, Secrets, Services and Ingress stay in place; setting it back to `false` brings the workloads back up.
- Implemented via a per-chart `<chart>.replicas` helper in `_helpers.tpl` (reference in `template-chart`); the helper uses an explicit nil check (`kindIs "invalid"`) because Helm's `default` would swallow an explicit `0`.

### 12. Values that must not lie (#68, #93, #99)

Every chart ships a **`values.schema.json`** with `additionalProperties: false` on **every chart-owned object level** — not just the top one. The gap this closes is a key that looks like configuration and does nothing: the pilot (#68) found three of them in one chart, one of them nested three levels deep and quietly leaving a game world unpinned. Objects that are passed **verbatim** into the pod spec stay open (probes, `securityContext.pod`/`.container`, `global`, free-form annotation maps): Kubernetes owns their schema, and restricting them would only reject fields that do not exist yet. The schema **adds to** `required()`, it does not replace it.

Reference implementation: `template-chart/values.schema.json` and `template-chart/templates/_helpers.tpl`.

**1. A value read outside its obvious template needs its own guard.** Before putting an Ingress behind `ingress.enabled`, check whether anything else reads `ingress.domain` — **in `templates/` and in `values.yaml`**, because `env` entries are rendered through `tpl` and hide such reads. If something does, that read needs its own `required()`; the gate then frees `clusterIssuer` but *not* `domain`. This happened in six charts, and matrix-synapse shows why it matters more than the count: its delegation nginx serves `ingress.domain` in the `/.well-known/matrix/{server,client}` endpoints through which **federation finds the homeserver**. Gating without the guard publishes

```
{"m.server": ":443"}     {"m.homeserver": {"base_url": "https://"}}
```

— rendered cleanly, pod green, federation broken. Check per chart and in both directions: in `calibre-web-automated` nothing outside the Ingress reads the domain, and there the gate frees both values.

**2. Probes, security contexts and resources go through the null-safe helper, never behind an `if`.** An override written without children is YAML null and erases the block: the container renders `securityContext: null` (unhardened, healthy, silent), a probe disappears, or `resources` loses its requests and computed limits. The `defaultedDict` helper defines the opposite semantics — an empty block means "chart defaults apply" — while an explicitly set value still wins, **including `false` and `0`** (hence the `kindIs "invalid"` check; `default` and `mergeOverwrite` both swallow zero values). Do **not** wrap these blocks in `{{- if }}`: a guard does not render a visible `null`, it removes the probe entirely, which is the same bug with no evidence left.

**3. Do not hang liveness on an external dependency where a dependency-free path exists.** `zipline` deliberately probes `/` for liveness and `/api/healthcheck` only for readiness and startup, so a database outage cannot restart the pod. Where no such path exists — `outline` returns 500 on `/` when the database is down — all three probes may share the endpoint, but the reason belongs in a comment on the helper, or the next reader will "fix" the inconsistency.

**4. A fallback reproduces *this chart's* defaults, not the repo standard.** Five charts deviate from the hardening baseline on purpose. A "cleaned up" standard default is not tidying, it is an outage: `calibre-web-automated` must keep `readOnlyRootFilesystem: false`, because in read-only mode the image disables its PUID/PGID remapping and the runtime uid silently moves from 1000 to 911 — **making existing volume data inaccessible**. The same applies to non-standard values that look like mistakes: `satisfactory` keeps `limitFactor: 2` (that is what holds the memory limit at the published 8Gi) and `fsGroupChangePolicy: OnRootMismatch` (which avoids a recursive chown of multi-GB game files on every start).

**5. A probe default carries the probe's context, not just its timings.** Two different symptoms, both from real charts: `teamspeak-server` addresses its TCP port by the name `file-transfer` because the voice service is UDP and cannot be probed — a default without that name leaves the workload **with no working probe at all**. `patchmon` sends a `Host` header because the server answers **403** to any request whose Host is neither loopback nor a CORS_ORIGIN host — a default without it means the pod never becomes Ready. Port names, `Host` headers and `exec` commands belong in the fallback; where the context is dynamic, pass the root context in and rebuild it (patchmon derives the header from `ingress.domain`).

**Two things about the mechanics that are easy to lose:**

- **`null` reaches the schema in one case and not the other.** For a key **with** a chart default, Helm's coalescing treats the `null` as a deletion and removes it *before* schema validation — the schema never sees it, and only the helper can catch it. For a key **without** a default (e.g. `resources.limits`), there is nothing to delete, the `null` survives into validation, and a strict `"type": "object"` aborts the render. That is why the helper **and** the widened `["object", "null"]` types are both needed: each covers a case the other cannot. Everything else stays strictly typed.
- **Validate every schema against the real values, not only against chart defaults.** Defaults are valid by construction, so they prove nothing. Render each chart against its bundle in `cluster-config/fleet-cd/` **and** against `helm get values` — the two differ more often than expected (four of ten bundles in one wave, always with the repo file being the worse one). This step caught a schema of mine that would have broken three live paperless releases, because all three write `tikaGotenberg.enabled` as the string `"true"` and the first draft demanded a boolean. Result per chart is a **list of rejected keys**, which is the cluster side's work order before the version is pulled up.

### 13. Everything else

- `icon:` is mandatory in every `Chart.yaml`. **Documented exception — freesailarr, the only chart without one**: the rule everywhere else is "the icon is this chart's one upstream's logo", and a chart bundling nine independently versioned projects has no such upstream — picking one of the nine would imply a "main app" the stack deliberately does not have. That is the whole criterion, and it applies to no other chart in the repo: a single-upstream chart without an icon is a missing icon, not an exception. The omission costs an INFO line in `helm lint --strict` (`icon is recommended`), which still exits 0.
- `helm lint --strict` must pass without findings.
- **Every chart ships a `templates/NOTES.txt`** (#43), `template-chart` included — so this is a requirement for a new chart, not a nice-to-have it can defer. No list of names here on purpose: a count goes stale the moment the next chart lands, which is exactly how the previous wording came to claim a number it never matched. Reference implementation: `template-chart/templates/NOTES.txt`, a placeholder-carrying template rather than finished prose, so a new chart adapts it instead of starting from an empty file. The bar it sets: print what an operator would otherwise have to look up in the templates (the rendered access URL, **which fields the 1Password item must carry**, the options actually active in this release, and the chart's known traps), conditional on the values really set. A `NOTES.txt` that only repeats the values is skimmed once and never read again. **No real domain anywhere** — the URL renders from `ingress.domain`, and where an example is unavoidable it is `example.com`. A `NOTES.txt` renders no Kubernetes object, so writing or reworking one is purely additive: a minor bump.
- CI: every installable chart has fixtures under `ci/<chart>/` (`test-values.yaml`, optionally `fixtures.yaml`/`fixtures.env.yaml`/`settings.env`) or a justified entry in `ci/excluded-charts.txt` — the install-test fails if both are missing.
### 14. Chart dependencies

Until `ytdlp-web-player` (#214) this section read "charts have no dependencies (`charts/` directories are empty)". That rule is gone, replaced by a bar rather than a ban — a dependency is **admissible, not free**, and the reason it stopped being a ban is worth keeping: the chart needed an oauth2-proxy in the data path in front of an application that ships no authentication at all, and proxy and app are only useful wired to each other.

**When a dependency earns its place.** All three, not two of three:

1. The dependent piece would otherwise be a second Helm release that only exists to serve this one, with the wiring between them living in neither chart.
2. Upstream is the right owner of it. We consume their chart as it comes: **we do not patch it, do not re-harden it, do not re-implement its values.** Where their defaults fall short of the guidelines above, that is **documented in our `values.yaml`**, not fixed by us — and a values-level fix stays available to whoever installs it.
3. It is **optional and off by default** (`condition:` in `Chart.yaml`), so the chart is complete without it and a default install renders none of its objects.

**What it costs, all of it visible before the next one is added:**

- **The subchart is invisible to everything downstream.** Its version is inside our packaged `.tgz`, so anything that watches Helm release versions — Fleet's `fleet.yaml` in `cluster-config` included — sees only *our* chart version. A new upstream release, security fix included, reaches a cluster **only** when we publish a new version of the outer chart. Nothing reports the gap. Renovate's built-in `helmv3` manager opens the PR (no `customManagers` entry needed — the repository URL and version sit together in one file) and `ci/renovate-bump-chart.sh` bumps the chart patch that ships it; that chain is the entire safety net. State this in a comment at the pinned version, not only in a review.
- **Every pipeline that touches the chart needs a network fetch first.** `helm lint`, `helm package`, `helm template` and `helm install` all exit 1 while a declared dependency is missing from `charts/`, so `ci/helm-dependencies.sh` runs before each of them (see CI/CD above). One of those call sites is the resource-quantity render test, which runs over **every** chart on **every** PR — a dependency-carrying chart can therefore turn a third-party Helm repository's bad day into a red pipeline on a PR that touched nothing related.
- **`charts/*.tgz` and `Chart.lock` are not committed** (`.gitignore` says why): the archive is a third-party binary nobody reviews in a diff, and a committed lock would arrive stale because Renovate rewrites `Chart.yaml` and cannot regenerate it — which is also why the pipelines run `helm dependency update` and not `helm dependency build`.
- **The repo's own mechanisms stop at the subchart boundary.** `checksum/config`, the 1Password auto-restart annotation and the `scaleDown` flag reach our templates only. A chart that renders a `OnePasswordItem` for its subchart documents the manual `kubectl rollout restart` that replaces the missing restart-on-change.

Two implementation notes that cost time otherwise: a values key containing a dash is unreachable as `.Values.oauth2-proxy` (that parses as a subtraction) and needs `index .Values "oauth2-proxy"`, while `condition:` in `Chart.yaml` splits on dots only and needs no escaping. And inside a subchart `.Chart.Name` is the **subchart's** name — a value templated into it (`config.configFile` in this case) must spell the parent chart out literally; only `.Release.Name` is shared.

Charts that need no dependency still have none, and `charts/` stays empty for all of them. `template-chart` remains dependency-free: the scaffold should not carry a `dependencies:` block a new chart has to remember to delete.
