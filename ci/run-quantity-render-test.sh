#!/usr/bin/env bash
# Resource-quantity render test: renders every chart with values that hit both
# failure modes of issue #157 and checks the *output*, not just the exit code.
#
# Usage: ci/run-quantity-render-test.sh [chart ...]   (no argument = all charts)
#
# What went wrong (#157): the resources helper formatted numbers with
# printf "%v". The null-safe fallback helpers pass values through fromYaml,
# which parses every number as float64, and Go's "%v" switches float64 to
# exponential notation from about 1e6 upwards. A bare byte count like
# 1048576 became "1.048576e+06". That produced two different failures, and only
# one of them is loud:
#
#   1. LOUD - the quantity itself is reformatted before it is parsed, the
#      helper sees the suffix "e+06" and aborts the render with
#      `unsupported resource quantity suffix "e+06"`. A broken render stops the
#      pipeline by itself.
#   2. SILENT - the *product* of a fractional limitFactor and a bare number is
#      reformatted after the suffix check. The render succeeds and the manifest
#      looks fine; it carries `memory: "1.4999985e+06"`, which no suffix check
#      ever sees and which only the API server rejects, at apply time. This one
#      was reachable in all eleven charts checked with ordinary, schema-valid
#      values, because limitFactor is typed "number", not "integer".
#
# So the loud case is covered by "does helm template exit 0", and the silent
# case is not - it needs the rendered text to be searched for a quantity in
# exponential notation. Both are checked here, per chart.
#
# Why over *all* charts instead of the changed ones: charts in this repo have
# no dependencies, so the helper is copied into every chart's
# templates/_helpers.tpl. The regression this guards against arrives by copy -
# a new chart started from an older chart, or from template-chart before the
# fix. That chart is new to the repo, but its copy of the bug is not something
# any diff of *this* PR would point at. The test is cheap enough (two renders
# per chart, no cluster) to simply run over everything, and adding a chart
# enrolls it automatically: there is no list to maintain here.
#
# Which values: the same committed fixtures the install-test and the Trivy scan
# use, ci/<chart>/test-values.yaml (or ci/trivy/values/<chart>.yaml, or the
# chart defaults) - they exist, they are maintained, and they satisfy the
# required() values every chart has. On top of them this script sets, at every
# resources block the chart's values schema declares:
#
#   case "bare-int":  requests.memory = 1048576, limitFactor = 2   -> limit 2097152
#   case "fraction":  requests.memory = 999999,  limitFactor = 1.5 -> limit 1499998.5
#
# 999999 stays below 1e6 on purpose: it keeps the quantity itself out of
# exponential range, so the "fraction" case isolates the second, silent
# formatting site instead of tripping over the first one.
#
# Where the resources blocks come from: values.schema.json, not values.yaml.
# It is JSON (python3 without pyyaml can read it, same constraint as
# ci/run-trivy-config.sh), and every chart-owned key must appear in it anyway -
# the schemas carry additionalProperties: false on every chart-owned level. A
# chart whose templates use the resources helper but whose schema declares no
# resources block fails the test with that as the message: the schema is then
# out of sync with the chart, which is a finding of its own.
#
# Charts that never reach the helper: a chart can set every computable limit
# explicitly (gotenberg and rss-bridge do - their fallback defaults pin the
# memory and ephemeral-storage limits, and in that helper a null never deletes a
# default, so no override can free them). Nothing is multiplied there, so
# nothing can be proven there either. Those charts are reported as "not
# exercised" rather than counted as passing - a green tick for a code path that
# was never entered is the kind of signal this repo removes rather than adds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_DIR="$ROOT/ci"
RELEASE="quantity"

# Probe values and the limits they must produce. Kept together because the
# expected products are what tells "the helper ran and was correct" apart from
# "the helper never ran" - see the reachability check below.
BARE_INT_REQUEST=1048576
BARE_INT_FACTOR=2
BARE_INT_LIMIT=2097152
FRACTION_REQUEST=999999
FRACTION_FACTOR=1.5
FRACTION_LIMIT=1499998.5

# A resource quantity written in exponential notation. Matched on the resource
# keys only, so the line in the failure message is the offending one and not
# some unrelated number that happens to look similar.
EXP_RE='^[[:space:]]*(cpu|memory|ephemeral-storage|storage):[[:space:]]*"?[0-9]+(\.[0-9]+)?[eE][-+]?[0-9]+[A-Za-z]*"?[[:space:]]*$'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Which charts -----------------------------------------------------------
CHARTS=()
if [ "$#" -gt 0 ]; then
  CHARTS=("$@")
else
  for DIR in "$ROOT"/*/; do
    [ -f "$DIR/Chart.yaml" ] || continue
    CHARTS+=("$(basename "$DIR")")
  done
fi
if [ "${#CHARTS[@]}" -eq 0 ]; then
  echo "ERROR: no chart directories found under $ROOT" >&2
  exit 1
fi

FAILED=""
EXERCISED=""
NOT_EXERCISED=""

for CHART in "${CHARTS[@]}"; do
  if [ ! -f "$ROOT/$CHART/Chart.yaml" ]; then
    echo "ERROR: '$CHART' is not a chart directory" >&2
    exit 1
  fi
  SCHEMA="$ROOT/$CHART/values.schema.json"
  if [ ! -f "$SCHEMA" ]; then
    echo "::error title=quantity-render $CHART::$CHART has no values.schema.json - every chart in this repo ships one (README, \"Values that must not lie\"), and this test reads the resources paths from it."
    FAILED="$FAILED $CHART"
    continue
  fi

  # --- 1. Find every resources block the schema declares ---------------------
  # A block counts when it is the shared #/definitions/resources or carries
  # limitFactor / requests itself. That distinction matters: minecraft-server
  # has a "minecraft.resources" block that is JVM/storage configuration and has
  # nothing to do with container resources.
  PATHS="$(python3 - "$SCHEMA" <<'PY'
import json, sys

schema = json.load(open(sys.argv[1]))
found = []

def is_resources(node):
    if not isinstance(node, dict):
        return False
    if node.get("$ref") == "#/definitions/resources":
        return True
    props = node.get("properties")
    return isinstance(props, dict) and ("limitFactor" in props or "requests" in props)

def walk(node, path):
    if not isinstance(node, dict):
        return
    props = node.get("properties")
    if not isinstance(props, dict):
        return
    for key, value in props.items():
        here = path + [key]
        if key == "resources" and is_resources(value):
            found.append(".".join(here))
            continue
        walk(value, here)

walk(schema, [])
print("\n".join(found))
PY
)"

  if [ -z "$PATHS" ]; then
    # No resources block in the schema. Fine for a chart that has none - but a
    # chart whose templates call the helper and whose schema hides the block
    # would slip through this test unnoticed, so that combination is an error.
    if grep -REq 'include[[:space:]]+"[^"]*\.(effective)?[Rr]esources"' "$ROOT/$CHART/templates"; then
      echo "::error title=quantity-render $CHART::$CHART renders a resources block in its templates, but values.schema.json declares none - the schema is out of sync with the chart, and this test cannot reach the resource helper."
      FAILED="$FAILED $CHART"
    else
      echo "$CHART: no resources block in the values schema - nothing to render."
      NOT_EXERCISED="$NOT_EXERCISED $CHART"
    fi
    continue
  fi

  # --- 2. Values, same precedence as ci/run-trivy-config.sh ------------------
  VALUES_ARGS=()
  VALUES_LABEL="chart defaults"
  REPRO_VALUES=""
  if [ -f "$CI_DIR/$CHART/test-values.yaml" ]; then
    VALUES_ARGS=(-f "$CI_DIR/$CHART/test-values.yaml")
    VALUES_LABEL="ci/$CHART/test-values.yaml"
    REPRO_VALUES="-f ci/$CHART/test-values.yaml"
  elif [ -f "$CI_DIR/trivy/values/$CHART.yaml" ]; then
    VALUES_ARGS=(-f "$CI_DIR/trivy/values/$CHART.yaml")
    VALUES_LABEL="ci/trivy/values/$CHART.yaml"
    REPRO_VALUES="-f ci/trivy/values/$CHART.yaml"
  fi

  SET_BARE_INT=()
  SET_FRACTION=()
  for P in $PATHS; do
    SET_BARE_INT+=(--set-json "$P.limitFactor=$BARE_INT_FACTOR" --set-json "$P.requests.memory=$BARE_INT_REQUEST")
    SET_FRACTION+=(--set-json "$P.limitFactor=$FRACTION_FACTOR" --set-json "$P.requests.memory=$FRACTION_REQUEST")
  done

  echo "::group::$CHART ($VALUES_LABEL; $(echo "$PATHS" | wc -l | tr -d ' ') resources block(s))"
  echo "$PATHS" | sed 's/^/  /'

  CHART_FAILED=""
  CHART_HITS=0

  # --- 3. Both cases ---------------------------------------------------------
  # Case order matters only for readability; both run either way, so a chart
  # broken in both places reports both.
  for CASE in bare-int fraction; do
    OUT="$WORK/$CHART.$CASE.yaml"
    ERR="$WORK/$CHART.$CASE.err"
    if [ "$CASE" = "bare-int" ]; then
      SET_ARGS=("${SET_BARE_INT[@]}")
      DESC="bare integer request ($BARE_INT_REQUEST) x limitFactor $BARE_INT_FACTOR"
      MARKER="$BARE_INT_LIMIT"
    else
      SET_ARGS=("${SET_FRACTION[@]}")
      DESC="bare integer request ($FRACTION_REQUEST) x fractional limitFactor $FRACTION_FACTOR"
      MARKER="$FRACTION_LIMIT"
    fi

    # The reproduce line is logged rather than folded into the annotation: with
    # ten resources blocks (freesailarr) it is several hundred characters, and
    # an annotation that long is unreadable in the GitHub UI.
    REPRO="helm template t $CHART $REPRO_VALUES ${SET_ARGS[*]}"

    if ! helm template "$RELEASE" "$ROOT/$CHART" \
        ${VALUES_ARGS[@]+"${VALUES_ARGS[@]}"} "${SET_ARGS[@]}" >"$OUT" 2>"$ERR"; then
      echo "--- $CASE: helm stderr ---"
      sed 's/^/  /' "$ERR"
      echo "--- reproduce (from the repo root) ---"
      echo "  $REPRO"
      echo "::error title=quantity-render $CHART ($CASE)::$CHART aborts rendering on a $DESC - the loud half of issue #157: the quantity is formatted with printf \"%v\", float64 flips to exponential notation above ~1e6, and the helper rejects the suffix it produced itself. Fix: run numbers through the chart's formatNumber helper (reference: template-chart/templates/_helpers.tpl). Reproduce command in the job log."
      CHART_FAILED=1
      continue
    fi

    if grep -nE "$EXP_RE" "$OUT" >"$WORK/hits" 2>/dev/null; then
      echo "--- $CASE: quantities in exponential notation ---"
      sed 's/^/  /' "$WORK/hits"
      echo "--- reproduce (from the repo root) ---"
      echo "  $REPRO"
      echo "::error title=quantity-render $CHART ($CASE)::$CHART renders resource quantities in exponential notation on a $DESC - $(wc -l <"$WORK/hits" | tr -d ' ') occurrence(s), first: '$(head -1 "$WORK/hits" | sed 's/^[0-9]*:[[:space:]]*//')'. This is the silent half of issue #157: the render succeeds, the manifest looks valid, and only the API server rejects it at apply time. Fix: run numbers through the chart's formatNumber helper (reference: template-chart/templates/_helpers.tpl). Reproduce command in the job log."
      CHART_FAILED=1
      continue
    fi

    if grep -qE "^[[:space:]]*memory:[[:space:]]*\"?$MARKER\"?[[:space:]]*$" "$OUT"; then
      CHART_HITS=$((CHART_HITS + 1))
      echo "  $CASE: computed limit memory: $MARKER - helper exercised, no exponential notation."
    else
      echo "  $CASE: renders clean, but no computed limit appeared (expected memory: $MARKER)."
    fi
  done
  echo "::endgroup::"

  if [ -n "$CHART_FAILED" ]; then
    FAILED="$FAILED $CHART"
    echo "$CHART: FAILED"
  elif [ "$CHART_HITS" -eq 2 ]; then
    EXERCISED="$EXERCISED $CHART"
    echo "$CHART: ok (both cases exercised the resource helper)"
  else
    # Renders are clean but the helper was not reached - see the header comment
    # on gotenberg. Reported, never counted as proof.
    NOT_EXERCISED="$NOT_EXERCISED $CHART"
    echo "$CHART: renders clean, but $((2 - CHART_HITS)) of 2 cases never reached the resource helper (all computable limits set explicitly) - nothing proven for this chart."
  fi
done

# --- 4. Report ---------------------------------------------------------------
count() { set -- $1; echo "$#"; }
listing() { set -- $1; [ "$#" -eq 0 ] && { echo "–"; return; }; printf '`%s`' "$1"; shift; for C in "$@"; do printf ', `%s`' "$C"; done; echo; }
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
{
  echo "### Resource-quantity render test (issue #157)"
  echo
  echo "Every chart rendered twice - once with a bare integer memory request, once with a"
  echo "bare integer request and a fractional \`limitFactor\` - and the output searched for"
  echo "resource quantities in exponential notation."
  echo
  echo "| Result | Count | Charts |"
  echo "|---|---|---|"
  echo "| Helper exercised, quantities plain | $(count "$EXERCISED") | $(listing "$EXERCISED") |"
  echo "| Renders clean, helper not reached | $(count "$NOT_EXERCISED") | $(listing "$NOT_EXERCISED") |"
  echo "| Failed | $(count "$FAILED") | $(listing "$FAILED") |"
} >>"$SUMMARY"

echo "===================== quantity render test ====================="
echo "exercised:     $(count "$EXERCISED")${EXERCISED:+ -$EXERCISED}"
echo "not exercised: $(count "$NOT_EXERCISED")${NOT_EXERCISED:+ -$NOT_EXERCISED}"
echo "failed:        $(count "$FAILED")${FAILED:+ -$FAILED}"
echo "================================================================"

if [ -n "$FAILED" ]; then
  echo "ERROR: resource quantities render wrong in:$FAILED" >&2
  exit 1
fi
