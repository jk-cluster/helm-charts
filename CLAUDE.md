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

A collection of self-made Helm charts, one directory per chart, published to a private OCI registry via GitHub Actions. There is no build system or test suite — validation is done with Helm itself:

```bash
helm lint <chart-name>
helm template <chart-name> --set ingress.domain=example.com --set ingress.clusterIssuer=letsencrypt   # render locally; required values vary per chart
```

## Creating a new chart

Copy `template-chart/` and replace every `xxx` placeholder — in file names (`templates/xxx.deployment.yaml` → `templates/<app>.deployment.yaml`), in `Chart.yaml`, and in the `values.yaml` keys and their `.Values.xxx.*` references inside templates. Then wire up CI:

1. Add `.github/workflows/publish-<chart-name>.yml` (copy an existing one, e.g. `publish-outline.yml`) — it triggers on pushes to `<chart-name>/**` and calls the reusable `publish-helm-chart.yml`.
2. Add the chart name to the `chart-name` choice list in `.github/workflows/change-app-version.yml`.

## Versioning scheme

`Chart.yaml` versions follow `version: <chart-semver>+up<appVersion>` (e.g. `1.4.0+up1.9.2`), with `appVersion` matching the suffix (dashes in the app version are normalized to dots in the suffix). When changing a chart's templates or values, bump the semver part; when only updating the app version, the `change-app-version.yml` workflow does it (it commits directly to main). Any push touching a chart directory publishes that chart, so the version must be bumped in the same change.

## Chart conventions (from template-chart)

- All resources are named `{{ .Release.Name }}-{{ .Chart.Name }}-<kind>` (e.g. `...-deployment`, `...-service`, `...-secret`).
- Image tags come from `{{ .Chart.AppVersion }}`.
- Secrets are 1Password `OnePasswordItem` CRs: values expose `secrets.<name>SecretRef` holding an `op://` item path; the operator materializes the Kubernetes Secret.
- Ingress assumes `ingressClassName: nginx` and cert-manager: `ingress.clusterIssuer` and `ingress.domain` are `required` values, TLS secret named `tls-<release>-<chart>-ingress`.
- `env` entries in values support Helm templating — the deployment renders them through `tpl`, and supports `value`, `secretKeyRef`, and `configMapKeyRef` forms.
- Hardened defaults: `automountServiceAccountToken: false`, non-root user, `readOnlyRootFilesystem: true`, all capabilities dropped; probes and resource requests/limits always set. Security contexts are values-configurable (`securityContext.pod` / `securityContext.container`); image-forced deviations are documented with a comment in the chart's `values.yaml`.
- Stateful apps use a StatefulSet in a `<app>.sfs.yaml` template instead of a deployment.
- No chart has dependencies; `charts/` directories are empty.
