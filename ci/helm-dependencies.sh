#!/usr/bin/env bash
# Fetch a chart's declared dependencies into its charts/ directory.
#
# WHY THIS EXISTS (issue #214)
#
# Until ytdlp-web-player every chart here was dependency-free, so no pipeline
# ever ran "helm dependency update" - and none of them tolerates a chart that
# needs it. All three of the commands this repo builds on refuse to work while
# a declared dependency is missing from charts/, each with its own wording:
#
#   helm lint --strict   [WARNING] chart directory is missing these dependencies: <name>
#   helm package         Error: found in Chart.yaml, but missing in charts/ directory: <name>
#   helm template        Error: An error occurred while checking for chart dependencies. ...
#
# All three exit 1, which is why this call sits in FIVE places rather than the
# three the plan expected: the two build steps of validate-charts.yml, the
# publish workflow - and the three ci/ scripts that render or install a chart
# (install-test, quantity-render, trivy-config). The quantity-render one is the
# easiest to overlook and the one that would have gone red first: it runs over
# EVERY chart on EVERY pull request, so a dependency-carrying chart breaks it
# from a PR that does not touch that chart at all.
#
# WHY "update" AND NOT "build"
#
# "helm dependency build" installs what Chart.lock names and fails when the
# lock disagrees with Chart.yaml. Renovate rewrites the version in Chart.yaml
# and cannot regenerate the lock, so every dependency PR would arrive red.
# "update" resolves from Chart.yaml and writes the lock itself, which is also
# why neither the lock nor the fetched .tgz is committed (see .gitignore).
#
# WHAT IT COSTS, NAMED HERE SO NOBODY HAS TO REDISCOVER IT
#
# A network fetch from a third-party Helm repository in every job that renders
# the chart. That repository going away, or serving a version that no longer
# exists, turns into a red pipeline on a PR that changed nothing related. This
# is the price of the dependency, and it is the reason the README asks for one
# to be justified rather than assumed.
#
# Charts without a "dependencies:" block are skipped without a word, so this is
# safe to call unconditionally for every chart.

set -euo pipefail

CHART_DIR="${1:?usage: ci/helm-dependencies.sh <chart-directory>}"

if [ ! -f "$CHART_DIR/Chart.yaml" ]; then
  echo "ci/helm-dependencies.sh: $CHART_DIR/Chart.yaml not found" >&2
  exit 1
fi

# Deliberately a grep for the top-level key rather than a YAML parse: the
# runners have no yq and no pyyaml (the same constraint ci/run-trivy-config.sh
# and ci/run-quantity-render-test.sh work under). A commented-out block does
# not match, because the anchor requires the key in column one.
if ! grep -q '^dependencies:' "$CHART_DIR/Chart.yaml"; then
  exit 0
fi

echo "==> helm dependency update $CHART_DIR"
helm dependency update "$CHART_DIR"
