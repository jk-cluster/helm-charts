# helm-charts

Collection of some self-made helm-charts. Each top-level directory is a standalone Helm chart that gets packaged and pushed to a private OCI registry (JK-Registry) via GitHub Actions.

## Charts

| Chart | Deploys | Notes |
|---|---|---|
| `apache-tika` | Apache Tika | Deployment + Service only (no ingress) |
| `calibre-web-automated` | Calibre-Web Automated | StatefulSet, extra consume-PVC |
| `cyberchef` | CyberChef | Stateless Deployment |
| `gotenberg` | Gotenberg | Deployment + Service only (no ingress) |
| `homeassistant` | Home Assistant | StatefulSet, has `NOTES.txt` and Helm tests |
| `matrix-synapse` | Matrix Synapse | StatefulSet plus an nginx delegation Deployment/Service |
| `minecraft-router` | itzg/mc-router | Deployment + routing ConfigMap + NodePort Service (TCP only, no ingress); `mappings` is a required value |
| `minecraft-server` | itzg/minecraft-server | StatefulSet + PVC + NodePort Service + init-script ConfigMap (no ingress); pre-existing chart, still on its legacy conventions. Published once per Java line (`appVersion: java8` / `java17` / `java21`) — the image tag comes from `.Chart.AppVersion`, so the Java line is chosen by picking the chart version |
| `outline` | Outline | StatefulSet, separate DB/Redis secrets |
| `paperless-ngx` | Paperless-ngx | Largest chart: consume CronJob, SMB-connector PV/PVC, pre/post-consumption scripts ConfigMap |
| `patchmon` | PatchMon | Two Deployments (frontend + backend), OIDC secret |
| `rallly` | Rallly | Deployment, DB/OIDC/SMTP secrets |
| `samba` | Samba | StatefulSet, users secret + config ConfigMap |
| `satisfactory` | Satisfactory game server | StatefulSet, no ingress |
| `teamspeak-server` | TeamSpeak server | StatefulSet, no ingress |
| `template-chart` | — | Scaffold for new charts (placeholder `xxx`), never published |
| `urlaubsverwaltung` | Urlaubsverwaltung | Deployment, DB + OIDC secrets |
| `voucher-vault` | VoucherVault | StatefulSet, DB + OIDC secrets |
| `zipline` | Zipline | StatefulSet, DB secret |

## Versioning

`Chart.yaml` uses the scheme `version: <chart-semver>+up<app-version>` (e.g. `1.4.0+up1.9.2`) — see the [chart style guidelines](#chart-style-guidelines) for the full rules (suffix normalization, semver bump levels).

- Bump the **chart version** in every change that touches a chart directory — a push to `main` publishes the chart.
- **App-version updates go through PRs** (so the validate and install-test pipelines run). The manually dispatched `Change App-Version` workflow (rewrites `version:`/`appVersion:` and commits directly to `main`) exists but bypasses both pipelines. For app **major** jumps, update stepwise: first to the last release of the old major line (own PR, merge, publish), then to the newest major.

## CI/CD (GitHub Actions)

- `publish-<chart>.yml` — one thin workflow per chart; triggers on pushes to `main` touching `<chart>/**` (or manually) and calls the reusable workflow below. **A push to a chart directory on `main` publishes that chart**, so the chart version must be bumped in the same change.
- `publish-helm-chart.yml` — reusable workflow: `helm package`, then `helm push` to the private JK-Registry. Registry credentials come from 1Password Connect (`OP_CONNECT_TOKEN` secret, items under `op://GitHub-Actions/`).
- `change-app-version.yml` — manually dispatched app-version bump; the chart must be listed in its `chart-name` choice list.
- `validate-charts.yml` — PR pipeline: detects which charts a PR touches and, for exactly those, runs `helm lint --strict`, `helm package`, and a chart-version bump check (`template-chart` is exempt from the version check). PRs without chart changes skip the build matrix. After the build stage, an **install-test** job (same changed-charts matrix) installs each changed chart into an ephemeral [k3d](https://k3d.io) cluster on the runner and requires every workload to become Ready — see below.

### Install-test (PR pipeline stage 2)

For every chart a PR changes, `ci/run-install-test.sh <chart>` runs against a throwaway k3d cluster: it applies the stub `OnePasswordItem` CRD plus the chart's fixtures, `helm install`s the chart with its CI values, and waits for all Deployments/StatefulSets to roll out (per-chart timeout). Since probes and security hardening are active on all workloads, "Ready" means the app actually answers. On failure the job dumps pod descriptions, events and container logs.

Fixtures live at the **repo root** under `ci/` (deliberately *not* inside the chart directories, so they are neither packaged into the chart tgz nor trigger the publish workflows on merge):

- `ci/common/` — fixtures applied for every chart (schema-less stub CRD for `OnePasswordItem`)
- `ci/<chart>/test-values.yaml` — values for the CI install (required for every installable chart)
- `ci/<chart>/fixtures.yaml` — dummy secrets with in-cluster connection data, throwaway infrastructure (postgres/redis/dex), static hostPath PVs/StorageClasses where the chart pins a storage class or needs RWX, and seed jobs (e.g. `synapse generate`)
- `ci/<chart>/settings.env` — optional overrides (e.g. `INSTALL_TIMEOUT` for slow starters)
- `ci/excluded-charts.txt` — charts that cannot run in CI, each with a justification. Currently: `satisfactory` (multi-GB image + 10GB+ Steam download), `template-chart` (scaffold with placeholder image)

Fixture images avoid Docker Hub where possible (`public.ecr.aws`/`ghcr.io`) to dodge runner rate limits. The job currently runs with `continue-on-error: true` (stabilization phase); it will be promoted to a required check once it has proven stable across several chart PRs. When adding a new chart, add its `ci/<chart>/` fixtures (or an entry in `ci/excluded-charts.txt`) — the install-test fails if both are missing. The script also runs locally against any existing cluster: `k3d cluster create t && ci/run-install-test.sh <chart> && k3d cluster delete t`.

## Creating a new chart

1. Copy `template-chart/` to `<chart-name>/` and replace every `xxx` placeholder: template file names (`xxx.deployment.yaml` → `<app>.deployment.yaml`), `Chart.yaml`, the `values.yaml` keys, and the `.Values.xxx.*` references inside the templates.
2. Add `.github/workflows/publish-<chart-name>.yml` (copy an existing one, e.g. `publish-outline.yml`).
3. Add the chart name to the choice list in `.github/workflows/change-app-version.yml`.

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
- Auxiliary images (sidecars, init containers, secondary workloads — e.g. the delegation nginx in matrix-synapse, guacd in patchmon, busybox init/consume images in paperless-ngx) are pinned via values instead of being hardcoded in templates, and their pinned versions are reviewed alongside every app-version update round.

### 4. Ingress

- `ingress.domain` and `ingress.clusterIssuer` (cert-manager) are `required` values **without defaults** — every installation sets both explicitly; they are the only values needed for a default install.
- `ingress.className` selects the ingress class and defaults to `nginx`.
- `ingress.annotations` takes optional extra annotations that are merged with the cert-manager `cluster-issuer` annotation the chart always sets.
- The TLS secret is named `tls-<release>-<chart>-ingress`.
- **Documented exception — homeassistant**: keeps its upstream-style flexible ingress values (host/tls lists, no required values); only its `ingress.className` default follows the standard (`nginx`, clearable to omit the field).

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
- Limits are computed by a per-chart `_helpers.tpl` helper (reference implementation in `template-chart/templates/_helpers.tpl`): an explicitly set limit always wins, missing memory and ephemeral-storage limits default to `resources.limitFactor` × the request (factor default `3`), and a CPU limit is only rendered when set explicitly — otherwise CPU stays unlimited (it is compressible, throttling instead of OOM-killing). The helper is duplicated into every chart because charts have no dependencies.

### 8. Secrets

- Secrets are **1Password `OnePasswordItem` CRs**: values expose `secrets.<name>SecretRef` holding an `op://` item path; the 1Password operator materializes the Kubernetes Secret in-cluster.

### 9. Environment variables

- Every workload container offers an additive `env` value block, appended to the env entries the chart always sets.
- Entries are rendered through `tpl` (so values may contain Helm templating) and support the `value`, `secretKeyRef` and `configMapKeyRef` forms (pattern: `template-chart/templates/xxx.deployment.yaml`).

### 10. Scaling

- Every Deployment/StatefulSet has a `replicas` value (default `1`, the values path per workload matches its section) that also accepts an explicit `0` for per-workload fine control.
- Every chart has a global `scaleDown` flag (default `false`): `scaleDown: true` takes precedence over all `replicas` values, renders every Deployment/StatefulSet with `replicas: 0` and suspends CronJobs. It **stops** the app but does not uninstall it — PVCs, Secrets, Services and Ingress stay in place; setting it back to `false` brings the workloads back up.
- Implemented via a per-chart `<chart>.replicas` helper in `_helpers.tpl` (reference in `template-chart`); the helper uses an explicit nil check (`kindIs "invalid"`) because Helm's `default` would swallow an explicit `0`.

### 11. Everything else

- `icon:` is mandatory in every `Chart.yaml`.
- `helm lint --strict` must pass without findings.
- `NOTES.txt` for every chart is planned (#43); currently only homeassistant ships one.
- CI: every installable chart has fixtures under `ci/<chart>/` (`test-values.yaml`, optionally `fixtures.yaml`/`settings.env`) or a justified entry in `ci/excluded-charts.txt` — the install-test fails if both are missing.
- Charts have no dependencies (`charts/` directories are empty).
