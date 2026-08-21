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
#   ci/<chart>/settings.env       optional overrides, e.g. INSTALL_TIMEOUT=600
#   ci/excluded-charts.txt        charts that cannot run in CI, with reasons
set -euo pipefail

CHART="${1:?usage: $0 <chart-name>}"
NAMESPACE="default"
RELEASE="ci"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_DIR="$ROOT/ci"

# Per-chart override via ci/<chart>/settings.env (INSTALL_TIMEOUT in seconds).
INSTALL_TIMEOUT=300
FIXTURE_JOB_TIMEOUT=600
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
