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

`Chart.yaml` uses the scheme `version: <chart-semver>+up<app-version>` (e.g. `1.4.0+up1.9.2`), where `appVersion` matches the `+up` suffix (dashes in the app version are normalized to dots in the suffix, e.g. `0.0.36-beta` → `+up0.0.36.beta`).

- Bump the **semver part** when the chart itself (templates/values) changes.
- The **app version** is bumped via the `Change App-Version` workflow, which rewrites `version:`/`appVersion:` and commits directly to `main`.

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

## Chart conventions

- Resources are named `{{ .Release.Name }}-{{ .Chart.Name }}-<kind>`; template files are named `<app>.<kind>.yaml` (StatefulSets use `.sfs.yaml`).
  - **Deliberate exception — existing PVC names**: PVCs of already-published charts keep their historical names even where they deviate from the scheme. Renaming a PVC makes Kubernetes provision a new, empty volume, so a rename would orphan the existing data. New charts name PVCs `{{ .Release.Name }}-{{ .Chart.Name }}-pvc` per the scheme. StatefulSet names *are* being aligned (data survives because the charts use standalone PVC templates, not `volumeClaimTemplates`); each rename ships in its own major-bump PR with a one-time migration note (`kubectl delete statefulset <old> --cascade=orphan` before upgrading).
- Image tags come from `{{ .Chart.AppVersion }}`.
- Auxiliary/sidecar images (images other than the app image, currently only the delegation nginx in matrix-synapse) are pinned via values (`<workload>.image.repository` / `<workload>.image.tag`) instead of being hardcoded in templates, and their pinned versions are reviewed alongside every app-version update round.
- Secrets are **1Password `OnePasswordItem` CRs**: values expose `secrets.<name>SecretRef` holding an `op://` item path; the 1Password operator materializes the Kubernetes Secret in-cluster.
- Ingress standard: `ingress.domain` and `ingress.clusterIssuer` (cert-manager) are the only required values. `ingress.className` selects the ingress class and defaults to `nginx`; `ingress.annotations` takes optional extra annotations that are merged with the cert-manager `cluster-issuer` annotation the chart always sets. The TLS secret is named `tls-<release>-<chart>-ingress`. (homeassistant deliberately keeps its upstream-style flexible ingress values instead.)
- `env` entries in `values.yaml` are rendered through `tpl`, so values may contain Helm templating; `value`, `secretKeyRef` and `configMapKeyRef` forms are supported.
- Hardened defaults: `automountServiceAccountToken: false`, non-root user, `readOnlyRootFilesystem: true`, all capabilities dropped, probes and resource requests always set. Pod and container contexts are configurable via `securityContext.pod` / `securityContext.container` in each chart's values; writable paths (e.g. `/tmp`, nginx cache dirs, s6-overlay's `/run`) are emptyDirs. Where an image cannot satisfy the full standard (e.g. Home Assistant must start as root for s6-overlay, paperless needs a root init container to hand over `/run`), the deviation is minimal and justified with a comment in that chart's `values.yaml`.
- Resource requests ship as chart defaults and are user-overridable; limits are computed by a per-chart `_helpers.tpl` helper (reference implementation in `template-chart/templates/_helpers.tpl`): an explicitly set limit always wins, missing memory and ephemeral-storage limits default to `resources.limitFactor` × the request (factor default `3`), and a CPU limit is only rendered when set explicitly — otherwise CPU stays unlimited (it is compressible, throttling instead of OOM-killing). The helper is duplicated into every chart because charts have no dependencies.
- Replica counts and scale-to-zero: every Deployment/StatefulSet has a `replicas` value (default `1`, the values path per workload matches its section, e.g. `patchmon.frontend.replicas`) that also accepts an explicit `0` for per-workload fine control. In addition, every chart has a global `scaleDown` flag (default `false`): `scaleDown: true` takes precedence over all `replicas` values, renders every Deployment/StatefulSet with `replicas: 0` and suspends CronJobs (paperless-ngx consume job). `scaleDown` **stops** the app but does not uninstall it — PVCs, Secrets, Services and Ingress stay in place, and setting it back to `false` brings the workloads back up. Implemented via a per-chart `<chart>.replicas` helper in `_helpers.tpl` (reference in `template-chart`); the helper uses an explicit nil check (`kindIs "invalid"`) because Helm's `default` would swallow an explicit `0`.
- Charts have no dependencies (`charts/` directories are empty).
