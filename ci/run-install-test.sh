#!/usr/bin/env bash
# Install-test harness: installs one chart into the cluster of the current
# kubectl context (an ephemeral k3d cluster in CI) using only the committed
# fixtures under ci/<chart>/ and requires every workload to become Ready.
#
# Usage: ci/run-install-test.sh <chart-name>
#
# Layout (repo root):
#   ci/common/            fixtures applied for every chart (OnePasswordItem stub CRD)
#   ci/<chart>/test-values.yaml   values for the CI install (required)
#   ci/<chart>/fixtures.yaml      dummy secrets / throwaway infra / static PVs (optional)
#   ci/<chart>/fixtures.env.yaml  fixtures with ${VARS} filled in from the environment (optional)
#   ci/<chart>/settings.env       optional overrides, e.g. INSTALL_TIMEOUT=600, REQUIRED_ENV=...
#   ci/excluded-charts.txt        charts that cannot run in CI, with reasons
set -euo pipefail

CHART="${1:?usage: $0 <chart-name>}"
NAMESPACE="default"
RELEASE="ci"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_DIR="$ROOT/ci"

# Per-chart override via ci/<chart>/settings.env (INSTALL_TIMEOUT in seconds).
# REQUIRED_ENV is a space-separated list of environment variables the chart's
# fixtures need; see the check below.
INSTALL_TIMEOUT=300
FIXTURE_JOB_TIMEOUT=600
REQUIRED_ENV=""
if [ -f "$CI_DIR/$CHART/settings.env" ]; then
  # shellcheck disable=SC1090
  source "$CI_DIR/$CHART/settings.env"
fi

# --- Exclusion list ---------------------------------------------------------
if [ -f "$CI_DIR/excluded-charts.txt" ]; then
  REASON="$(grep -E "^$CHART([[:space:]]|$)" "$CI_DIR/excluded-charts.txt" | sed -E "s/^$CHART[[:space:]]*//" || true)"
  if [ -n "$REASON" ]; then
    echo "SKIP: chart '$CHART' is excluded from the install-test: $REASON"
    exit 0
  fi
fi

if [ ! -d "$ROOT/$CHART" ] || [ ! -f "$ROOT/$CHART/Chart.yaml" ]; then
  echo "ERROR: '$CHART' is not a chart directory" >&2
  exit 1
fi
if [ ! -f "$CI_DIR/$CHART/test-values.yaml" ]; then
  echo "ERROR: missing ci/$CHART/test-values.yaml — every installable chart needs CI fixtures." >&2
  echo "Add test values (and fixtures.yaml if the app needs secrets/infra), or add the chart" >&2
  echo "to ci/excluded-charts.txt with a justification." >&2
  exit 1
fi

# --- Required environment for ci/<chart>/fixtures.env.yaml ------------------
# A chart whose fixtures need a value that must never be committed (freesailarr
# needs a real Wireguard key, or gluetun's kill switch keeps every app container
# from becoming Ready) declares the variable NAMES in settings.env:
#
#   REQUIRED_ENV="FREESAILARR_WG_KEY FREESAILARR_WG_ADDRESSES"
#
# The values come from the environment - in CI from 1Password Connect, see the
# install-test job in .github/workflows/validate-charts.yml.
#
# A missing or empty value is a hard error on purpose. Skipping the chart
# instead would restore exactly the green-but-meaningless signal this mechanism
# exists to remove, and an empty key produces a gluetun without a handshake,
# which reads as a broken chart rather than as a missing secret. The one
# legitimate case of absent secrets - a pull request from a fork - belongs in an
# "if" on the workflow job, not in this script.
# Only the variable name is ever printed, never the value.
for VAR in $REQUIRED_ENV; do
  if [ -z "${!VAR:-}" ]; then
    echo "ERROR: required environment variable '$VAR' is unset or empty." >&2
    echo "ci/$CHART/settings.env declares REQUIRED_ENV=\"$REQUIRED_ENV\"; ci/$CHART/fixtures.env.yaml" >&2
    echo "cannot be rendered without it, and the install-test does not skip charts over missing values." >&2
    exit 1
  fi
done

# --- Failure diagnostics ----------------------------------------------------
diagnose() {
  echo "=================== INSTALL-TEST FAILED: DIAGNOSTICS ==================="
  echo "--- pods ---"
  kubectl -n "$NAMESPACE" get pods -o wide || true
  echo "--- events (most recent last) ---"
  kubectl -n "$NAMESPACE" get events --sort-by=.metadata.creationTimestamp | tail -60 || true
  echo "--- describe pods ---"
  kubectl -n "$NAMESPACE" describe pods || true
  echo "--- container logs ---"
  for POD in $(kubectl -n "$NAMESPACE" get pods -o name); do
    echo "--- logs $POD ---"
    kubectl -n "$NAMESPACE" logs "$POD" --all-containers --tail=150 --prefix || true
    kubectl -n "$NAMESPACE" logs "$POD" --all-containers --tail=50 --previous --prefix 2>/dev/null || true
  done
  echo "========================================================================"
}
trap 'RC=$?; if [ $RC -ne 0 ]; then diagnose; fi; exit $RC' EXIT

# --- 1. Apply fixtures ------------------------------------------------------
echo "::group::Apply fixtures"
kubectl apply -f "$CI_DIR/common/"
if [ -f "$CI_DIR/$CHART/fixtures.yaml" ]; then
  kubectl apply -f "$CI_DIR/$CHART/fixtures.yaml"
fi
# Fixtures with values that must not be committed are rendered first: the
# checked-in fixtures.env.yaml holds ${VARIABLE} placeholders and nothing else.
# envsubst is restricted to the names from REQUIRED_ENV (its SHELL-FORMAT
# argument), so a variable that is not declared there is never substituted, no
# unrelated "$..." in the manifest is touched, and no other variable of the
# runner environment can end up in the cluster. The rendered document is piped
# straight into kubectl and never printed - kubectl reports object names only.
if [ -f "$CI_DIR/$CHART/fixtures.env.yaml" ]; then
  SHELL_FORMAT=""
  for VAR in $REQUIRED_ENV; do
    SHELL_FORMAT="$SHELL_FORMAT\${$VAR}"
  done
  envsubst "$SHELL_FORMAT" < "$CI_DIR/$CHART/fixtures.env.yaml" | kubectl apply -f -
fi
echo "::endgroup::"

# --- 2. Wait for fixture jobs (node setup, data seeding) and infra ----------
echo "::group::Wait for fixture jobs and infrastructure"
JOBS="$(kubectl -n "$NAMESPACE" get jobs -o name 2>/dev/null || true)"
for JOB in $JOBS; do
  echo "Waiting for $JOB to complete..."
  kubectl -n "$NAMESPACE" wait --for=condition=complete "$JOB" --timeout="${FIXTURE_JOB_TIMEOUT}s"
done
for RES in $(kubectl -n "$NAMESPACE" get deploy,sts -o name 2>/dev/null || true); do
  echo "Waiting for fixture $RES..."
  kubectl -n "$NAMESPACE" rollout status "$RES" --timeout="${FIXTURE_JOB_TIMEOUT}s"
done
echo "::endgroup::"

# --- 3. Install the chart ---------------------------------------------------
echo "::group::helm install"
helm install "$RELEASE" "$ROOT/$CHART" \
  --namespace "$NAMESPACE" \
  -f "$CI_DIR/$CHART/test-values.yaml"
echo "::endgroup::"

# --- 4. Require every workload to become Ready ------------------------------
echo "::group::Wait for workloads (timeout ${INSTALL_TIMEOUT}s each)"
WORKLOADS="$(kubectl -n "$NAMESPACE" get deploy,sts -o name)"
if [ -z "$WORKLOADS" ]; then
  echo "ERROR: the release created no Deployments/StatefulSets" >&2
  exit 1
fi
for RES in $WORKLOADS; do
  echo "Waiting for $RES..."
  kubectl -n "$NAMESPACE" rollout status "$RES" --timeout="${INSTALL_TIMEOUT}s"
done
echo "::endgroup::"

echo "--- final state ---"
kubectl -n "$NAMESPACE" get pods -o wide
echo "OK: chart '$CHART' installed and all workloads are Ready."
