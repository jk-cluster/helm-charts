# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Working on issues — mandatory workflow

The main Claude session acts as the **task manager** and does not implement issues itself:

1. **Plan first, get approval**: The manager presents a plan for the issue and waits for the user's explicit approval. No implementation before approval.
2. **Document the final plan on the issue**: Once approved, the plan is posted as a comment on the GitHub issue before implementation starts (skip if the issue body already contains the full plan; later decisions go there as comments too).
3. **Delegate implementation**: After approval, the manager launches a dedicated **development agent**. The agent implements the issue completely on its own branch and opens a PR.
4. **PR comment handling by the agent**: After opening the PR, the development agent watches it for review comments. New comments are addressed automatically (code changes, reply on the thread), and addressed threads are marked as **resolved**.
5. **Agent lifetime**: The development agent terminates itself once its PR has been merged (or closed).
6. Only after the PR has been **merged by the user** may work on the next issue begin. The user merges; never merge yourself.
7. **After the merge, verify the linked issue was closed** (auto-close via "Fixes #n"); close it manually if not.

Additional rules for all commits, PRs, issues, and comments:

- Do **not** add a `Co-Authored-By` trailer and do **not** append "Generated with Claude Code" footers.

## Keep the docs current

- Changes to this issue workflow always go into this CLAUDE.md file.
- General repository information (charts, CI pipelines, conventions, tooling) always lives in README.md. Any PR that changes repo-wide behavior must update README.md in the same PR.
- Runtime verification of chart changes is done in a local, throwaway k3d cluster (k3d is installed on the maintainer's machine): stub CRD for `OnePasswordItem`, dummy secrets, throwaway infrastructure (postgres/redis) where needed.

## What this repo is

A collection of self-made Helm charts, one directory per chart, published to a private, classic (index-based) Helm registry via GitHub Actions — an HTTP `POST` of the packaged `.tgz`, not an OCI `helm push`; the target URL and its credentials live in 1Password and never in this repository. Validation happens on three levels: locally with Helm, in the PR pipeline (`validate-charts.yml`: strict lint, package, version-bump check), and in the PR install-test stage (k3d, fixtures under `ci/` — see README):

```bash
helm lint --strict <chart-name>
helm template <chart-name> --set ingress.domain=example.com --set ingress.clusterIssuer=letsencrypt   # render locally; required values vary per chart
```

## Creating a new chart

Copy `template-chart/` and replace every `xxx` placeholder — in file names (`templates/xxx.deployment.yaml` → `templates/<app>.deployment.yaml`), in `Chart.yaml`, in the `values.yaml` keys and their `.Values.xxx.*` references inside templates, and in `values.schema.json` (both the values paths and the `xxx.` helper prefixes). The schema and the null-safe fallback helpers come with the template but their content is chart-specific — adapt them along the six points of the README section "Values that must not lie", and validate the result against the chart's real bundle values, not only against its defaults. Then wire up CI:

1. Add `.github/workflows/publish-<chart-name>.yml` (copy an existing one, e.g. `publish-outline.yml`) — it triggers on pushes to `main` touching `<chart-name>/**` and calls the reusable `publish-helm-chart.yml`.
2. Add the chart name to the `chart-name` choice list in `.github/workflows/change-app-version.yml`.
3. Add install-test fixtures under `ci/<chart-name>/` (`test-values.yaml`, `fixtures.yaml`) or an entry with justification in `ci/excluded-charts.txt` — the PR install-test fails if both are missing.
4. Add a `customManagers` block for the chart's main image in `renovate.json5` (one per chart, since the image repository lives in the template and the version in `Chart.yaml`) — without it Renovate never updates that chart's app version. See README section "Dependency updates (Renovate)".

## Versioning scheme

`Chart.yaml` versions follow `version: <chart-semver>+up<appVersion>` (e.g. `1.4.0+up1.9.2`), with `appVersion` matching the suffix (dashes in the app version are normalized to dots in the suffix). Any push to `main` touching a chart directory publishes that chart, so the version must be bumped in the same change.

Semver conventions for the chart part:

- **Patch**: bug fixes without behavior or values-schema change; plain app-version updates.
- **Minor**: additive, backward-compatible changes (new optional values with unchanged defaults).
- **Major**: runtime behavior changes or breaking values changes (e.g. probes, security hardening, computed limits, values that become required).

App-version updates go through PRs (so the validate and install-test pipelines run), not through the `change-app-version.yml` dispatch workflow (which commits directly to main and bypasses both). For app **major** jumps, update stepwise: first to the last release of the old major line (own PR, merge, publish), then to the newest major.

## Chart conventions

The binding style guide for all current and future charts lives in **README.md ("Chart style guidelines")**; `template-chart/` is the reference implementation. Compact summary:

- Resources named `{{ .Release.Name }}-{{ .Chart.Name }}-<kind>`; template files `<app>.<kind>.yaml`; stateful apps use a StatefulSet (`<app>.sfs.yaml`). Documented exception: historical PVC names stay (renames would orphan data); StatefulSet renames only with a `--cascade=orphan` migration note in a major PR.
- Main image tag from `{{ .Chart.AppVersion }}`; auxiliary/sidecar/init images pinned via values and reviewed on app-update rounds.
- Ingress: `ingress.domain` and `ingress.clusterIssuer` `required` **without defaults**; `ingress.className` defaults to `nginx`; optional `ingress.annotations` merged with the cert-manager annotation; TLS secret `tls-<release>-<chart>-ingress`. Documented exception: homeassistant keeps its flexible upstream ingress style (className default `nginx`).
- Secrets are 1Password `OnePasswordItem` CRs: values expose `secrets.<name>SecretRef` holding an `op://` item path; the operator materializes the Kubernetes Secret.
- Config changes must restart the workload (#82): every pod template consuming a ConfigMap carries `checksum/config: {{ include (print $.Template.BasePath "/<chart>.configmap.yaml") . | sha256sum }}` (one line per ConfigMap). Without it a changed ConfigMap restarts nothing — `subPath` mounts are never refreshed and apps read config only at start. Adding it to an existing chart is a **major** bump. Secrets from `OnePasswordItem` cannot be hashed (Helm never sees their content); charts mounting them document the limitation in `values.yaml`.
- Every container offers an additive `env` block rendered through `tpl` with `value`, `secretKeyRef`, and `configMapKeyRef` forms.
- Hardening: `automountServiceAccountToken: false`, non-root, `readOnlyRootFilesystem: true`, caps dropped, `allowPrivilegeEscalation: false`; contexts values-configurable (`securityContext.pod` / `securityContext.container`); writable paths as emptyDirs; image-forced deviations MUST be documented with a comment in the chart's `values.yaml`.
- Probes: liveness/readiness/startup on every workload (exception: paperless consume CronJob), values-configurable with calibrated defaults.
- Resources: requests as values defaults; limits auto-computed by the `_helpers.tpl` helper (`limitFactor` default 3; no CPU limits unless set explicitly).
- Replicas per workload (explicit `0` allowed) plus a chart-global `scaleDown` flag that overrides them.
- `icon:` mandatory in every `Chart.yaml`; `helm lint --strict` without findings; CI fixtures under `ci/<chart>/` or a justified exclusion.
- **Chart dependencies are admissible but expensive** (the former "no dependencies" rule fell with #214; `ytdlp-web-player` is the only chart using one). A dependency has to be optional and off by default via `condition:`, and upstream's chart is consumed as it comes — where its defaults fall short of these conventions, that is **documented in our `values.yaml`, never patched**. The price to know before adding the next one: a subchart is invisible to everything downstream that watches Helm release versions, so a new upstream version — a security fix included — reaches a cluster only when the outer chart is republished (Renovate's built-in `helmv3` manager plus `ci/renovate-bump-chart.sh` is the whole safety net, and it belongs in a comment at the pinned version); and every helm command exits 1 while `charts/` is unfilled, which is why `ci/helm-dependencies.sh` runs before lint, package, render and install — including the render test that covers **all** charts on **every** PR. Full rules and the rest of the cost: README, "Chart dependencies".
