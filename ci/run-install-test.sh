#!/usr/bin/env bash
# Install-test harness: installs one chart into the cluster of the current
# kubectl context (an ephemeral k3d cluster in CI) using only the committed
# fixtures under ci/<chart>/ and requires every workload to become Ready.
#
# Usage: ci/run-install-test.sh <chart-name>
#        ci/run-install-test.sh --list-excluded
#
# Layout (repo root):
#   ci/common/            fixtures applied for every chart (OnePasswordItem stub CRD)
#   ci/<chart>/test-values.yaml   values for the CI install (required)
#   ci/<chart>/fixtures.yaml      dummy secrets / throwaway infra / static PVs (optional)
#   ci/<chart>/fixtures.env.yaml  fixtures with ${VARS} filled in from the environment (optional)
#   ci/<chart>/settings.env       optional overrides, e.g. INSTALL_TIMEOUT=600, REQUIRED_ENV=...
#   ci/excluded-charts.txt        charts that cannot run in CI, with reasons
set -euo pipefail

NAMESPACE="default"
RELEASE="ci"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_DIR="$ROOT/ci"

# --- The exclusion list, parsed in exactly one place ------------------------
# Two consumers read ci/excluded-charts.txt: this script, and the install-test
# matrix in .github/workflows/validate-charts.yml, which drops the excluded
# charts before the matrix is built (issue #231). Two parsers would be two
# chances to select different charts - and the failure would be silent in the
# worst direction, a chart the workflow believes excluded and the script
# believes testable, or the reverse. So there is one parser, here, and the
# workflow calls it through "--list-excluded" instead of re-implementing it.
#
# The format is one chart per line: first whitespace-separated field the chart
# name, the rest of the line its mandatory justification. Blank lines and lines
# starting with "#" are comments. A line carrying only a name and no reason is
# deliberately NOT an exclusion (the "NF > 1" below): the justification is what
# the README requires, and a bare name would silently drop a chart out of CI
# with nothing to review.
list_excluded() {
  [ -f "$CI_DIR/excluded-charts.txt" ] || return 0
  { grep -vE '^[[:space:]]*(#|$)' "$CI_DIR/excluded-charts.txt" || true; } \
    | awk 'NF > 1 { name = $1; $1 = ""; sub(/^[[:space:]]+/, ""); print name "\t" $0 }'
}

# The reason a chart is excluded, empty if it is not. Exact string match on the
# name, not a regex, so a chart name is never read as a pattern.
excluded_reason() {
  list_excluded | awk -F'\t' -v chart="$1" '$1 == chart { print $2; exit }'
}

# Emits "<chart><TAB><reason>" for every excluded chart. Read by the detect job
# of validate-charts.yml before any chart is picked, which is why this runs
# before the argument is required.
if [ "${1:-}" = "--list-excluded" ]; then
  list_excluded
  exit 0
fi

CHART="${1:?usage: $0 <chart-name> | --list-excluded}"

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
# The diagnostics echo application output, and an app may well print a value it
# was given: gluetun logs its Wireguard address on startup. So everything the
# failure path prints runs through a filter that replaces the values of the
# declared REQUIRED_ENV variables with the variable name. GitHub masks them as
# well, but that is the platform's promise rather than this harness's - and the
# script runs locally too, where nothing masks anything.
redact_secrets() {
  if [ -z "$REQUIRED_ENV" ]; then
    cat
    return
  fi
  local SED_ARGS=()
  local VAR
  for VAR in $REQUIRED_ENV; do
    SED_ARGS+=(-e "s|${!VAR}|<redacted:$VAR>|g")
  done
  sed "${SED_ARGS[@]}"
}

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
trap 'RC=$?; if [ $RC -ne 0 ]; then diagnose | redact_secrets; fi; exit $RC' EXIT

# --- 1. Apply fixtures ------------------------------------------------------
echo "::group::Apply fixtures"
kubectl apply -f "$CI_DIR/common/"
if [ -f "$CI_DIR/$CHART/fixtures.yaml" ]; then
  kubectl apply -f "$CI_DIR/$CHART/fixtures.yaml"
fi
# Fixtures with values that must not be committed are rendered before they are
# applied: the checked-in fixtures.env.yaml holds ${VARIABLE} placeholders only.
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
# Same reason as in the lint and package steps: helm install refuses to touch a
# chart whose declared dependencies are not in charts/. No-op for a chart
# without dependencies; see ci/helm-dependencies.sh.
"$ROOT/ci/helm-dependencies.sh" "$ROOT/$CHART"
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
