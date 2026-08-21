# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
- Hardened defaults: `automountServiceAccountToken: false`, non-root user, `readOnlyRootFilesystem: true`, all capabilities dropped; probes and resource requests/limits always set.
- Stateful apps use a StatefulSet in a `<app>.sfs.yaml` template instead of a deployment.
- No chart has dependencies; `charts/` directories are empty.
