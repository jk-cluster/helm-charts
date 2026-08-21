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
- `validate-charts.yml` — PR pipeline: detects which charts a PR touches and, for exactly those, runs `helm lint --strict`, `helm package`, and a chart-version bump check (`template-chart` is exempt from the version check). PRs without chart changes skip the build matrix.

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
- Image tags come from `{{ .Chart.AppVersion }}`.
- Secrets are **1Password `OnePasswordItem` CRs**: values expose `secrets.<name>SecretRef` holding an `op://` item path; the 1Password operator materializes the Kubernetes Secret in-cluster.
- Ingress assumes ingress-nginx (`ingressClassName: nginx`) and cert-manager: `ingress.clusterIssuer` and `ingress.domain` are required values; the TLS secret is named `tls-<release>-<chart>-ingress`.
- `env` entries in `values.yaml` are rendered through `tpl`, so values may contain Helm templating; `value`, `secretKeyRef` and `configMapKeyRef` forms are supported.
- Hardened defaults: `automountServiceAccountToken: false`, non-root user, `readOnlyRootFilesystem: true`, all capabilities dropped, probes and resource requests/limits always set. Pod and container contexts are configurable via `securityContext.pod` / `securityContext.container` in each chart's values; writable paths (e.g. `/tmp`, nginx cache dirs, s6-overlay's `/run`) are emptyDirs. Where an image cannot satisfy the full standard (e.g. Home Assistant must start as root for s6-overlay, paperless needs a root init container to hand over `/run`), the deviation is minimal and justified with a comment in that chart's `values.yaml`.
- Charts have no dependencies (`charts/` directories are empty).
