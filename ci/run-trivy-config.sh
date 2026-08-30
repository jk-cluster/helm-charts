#!/usr/bin/env bash
# Misconfiguration scan for one chart: renders the chart with Helm and runs
# `trivy config` over the *rendered* manifests.
#
# Usage: ci/run-trivy-config.sh <chart-name>
#
# Why the manifests and not the chart directory: `trivy config <chart-dir>`
# renders the chart itself, with default values only. Every chart here has
# `required()` values, so that render fails - and Trivy does not fail with it,
# it logs "WARN Skipping chart" and prints an empty, green report. A scan that
# silently reports "clean" for every chart in the repo is worse than no scan.
# Rendering with Helm puts the failure where it belongs: this script exits
# non-zero when the render breaks.
#
# Which values (see README "Install-test"): the same committed fixtures the
# install-test uses, ci/<chart>/test-values.yaml. They exist, they are
# maintained, and they are proven to produce a running workload. They also do
# not touch the security posture - no test-values file overrides
# securityContext, images or capabilities (only minecraft-server sets
# resources.requests), so what Trivy sees is the chart's own hardening, not a
# CI-specific one.
#
# Charts without install-test fixtures (ci/excluded-charts.txt) are still
# scanned - rendering costs nothing, and the reason for excluding them is the
# image size, which a static scan never touches. They get their values from
# ci/trivy/values/<chart>.yaml, or none at all if the chart renders on defaults.
#
# Exceptions live in ci/trivy/trivyignore.yaml in Trivy's native ignore-file
# schema, one `statement` per entry (same rule as ci/excluded-charts.txt: no
# entry without a reason). Findings covered by it are reported separately, not
# hidden. The trusted-registry check is configured rather than excepted, via
# ci/trivy/data/ksv0125.yaml - see the comment in that file.
#
# Mode (TRIVY_CONFIG_MODE, default "report"):
#   report  always exits 0 - findings are reported, the PR is not blocked.
#   gate    exits 1 when a finding is not covered by ci/trivy/trivyignore.yaml.
# Promotion to a gate is this one variable, once the seccomp gap (#84 part 2)
# is closed and the actionable set is genuinely empty.
set -euo pipefail

CHART="${1:?usage: $0 <chart-name>}"
MODE="${TRIVY_CONFIG_MODE:-report}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_DIR="$ROOT/ci"
IGNORE_FILE="$CI_DIR/trivy/trivyignore.yaml"
DATA_DIR="$CI_DIR/trivy/data"
RELEASE="scan"

if [ ! -f "$ROOT/$CHART/Chart.yaml" ]; then
  echo "ERROR: '$CHART' is not a chart directory" >&2
  exit 1
fi
if [ ! -f "$IGNORE_FILE" ]; then
  echo "ERROR: missing $IGNORE_FILE" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The rendered file is named after the chart: ignore entries scope themselves to
# a single chart via `paths: ["**/<chart>.yaml"]`, which is how a chart-specific
# deviation (samba's writable root filesystem) stays an exception for that chart
# and keeps being reported for every other one.
RENDERED="$WORK/$CHART.yaml"

# --- 1. Pick the values ------------------------------------------------------
VALUES_ARGS=()
VALUES_LABEL="chart defaults (no values file)"
if [ -f "$CI_DIR/$CHART/test-values.yaml" ]; then
  VALUES_ARGS=(-f "$CI_DIR/$CHART/test-values.yaml")
  VALUES_LABEL="ci/$CHART/test-values.yaml"
elif [ -f "$CI_DIR/trivy/values/$CHART.yaml" ]; then
  VALUES_ARGS=(-f "$CI_DIR/trivy/values/$CHART.yaml")
  VALUES_LABEL="ci/trivy/values/$CHART.yaml"
fi

# --- 2. Every ignore entry needs a reason ------------------------------------
python3 - "$IGNORE_FILE" <<'PY'
import re, sys
# Deliberately not a YAML parser: runners have python3 but not pyyaml, and the
# file is a flat list. Trivy is the one that must parse it; this only enforces
# the repo rule that no exception exists without a written reason.
text = open(sys.argv[1]).read()
entries = re.findall(r'^\s*-\s+id:\s*(\S+)(.*?)(?=^\s*-\s+id:|\Z)', text, re.M | re.S)
if not entries:
    print("NOTE: no exceptions declared in the ignore file")
bad = [i for i, body in entries if not re.search(r'^\s+statement:\s*\S', body, re.M)]
if bad:
    print(f"ERROR: ignore entries without a statement: {', '.join(bad)}", file=sys.stderr)
    print("Every exception needs a written reason (same rule as ci/excluded-charts.txt).", file=sys.stderr)
    sys.exit(1)
PY

# --- 3. Render ---------------------------------------------------------------
# helm template refuses to run at all while a declared dependency is missing
# from charts/, so this has to happen before the render. No-op for a chart
# without dependencies; see ci/helm-dependencies.sh.
"$ROOT/ci/helm-dependencies.sh" "$ROOT/$CHART"
echo "::group::helm template $CHART ($VALUES_LABEL)"
# ${a[@]+"${a[@]}"} - an empty array under `set -u` is an error on bash 3.2
# (the macOS default), where this script also runs locally.
if ! helm template "$RELEASE" "$ROOT/$CHART" ${VALUES_ARGS[@]+"${VALUES_ARGS[@]}"} > "$RENDERED"; then
  echo "::endgroup::"
  echo "ERROR: rendering '$CHART' failed - nothing was scanned." >&2
  echo "Add the values the chart needs to ci/trivy/values/$CHART.yaml." >&2
  exit 1
fi
DOCS="$(grep -c '^kind:' "$RENDERED" || true)"
echo "Rendered $DOCS manifests."
echo "::endgroup::"

# --- 4. Scan -----------------------------------------------------------------
# Two passes so the split between "actionable" and "covered by an exception" is
# made by Trivy's own matching (including the path globs), not re-implemented
# here: one pass with the ignore file, one without. A suppressed finding is
# dropped from the report entirely - `trivy config` has no --show-suppressed.
echo "::group::trivy config $CHART"
TRIVY=(trivy config --quiet --disable-telemetry --config-data "$DATA_DIR")
"${TRIVY[@]}" -f json -o "$WORK/all.json" "$RENDERED"
"${TRIVY[@]}" -f json -o "$WORK/open.json" --ignorefile "$IGNORE_FILE" "$RENDERED"
"${TRIVY[@]}" --ignorefile "$IGNORE_FILE" "$RENDERED" || true
echo "::endgroup::"

# --- 5. Report ---------------------------------------------------------------
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
export CHART VALUES_LABEL DOCS MODE
python3 - "$WORK/all.json" "$WORK/open.json" "$IGNORE_FILE" "$SUMMARY" <<'PY'
import json, os, re, sys
from collections import Counter

all_json, open_json, ignore_file, summary_path = sys.argv[1:5]
chart = os.environ["CHART"]

def findings(path):
    doc = json.load(open(path))
    out = []
    for res in doc.get("Results", []):
        for m in res.get("Misconfigurations", []):
            if m.get("Status") != "FAIL":
                continue
            resource = (m.get("CauseMetadata") or {}).get("Resource") or ""
            out.append((m["ID"], m.get("Severity", "UNKNOWN"), m.get("Title", ""), resource))
    return out

every, still_open = findings(all_json), findings(open_json)
open_counter = Counter(f[0] for f in still_open)
suppressed = Counter(f[0] for f in every) - open_counter

# The same ID appears several times, scoped to different charts by `paths`.
# Trivy decides what is suppressed; this only picks the matching reason to
# print, preferring an entry scoped to this chart over a repo-wide one.
statements = {}
text = open(ignore_file).read()
for ident, body in re.findall(r'^\s*-\s+id:\s*(\S+)(.*?)(?=^\s*-\s+id:|\Z)', text, re.M | re.S):
    key = ident.strip('"\'').removeprefix("AVD-")
    st = re.search(r'^\s+statement:\s*(.+?)\s*$', body, re.M)
    reason = st.group(1).strip('"\'') if st else ""
    paths = re.search(r'^\s+paths:\s*(.+?)\s*$', body, re.M)
    if paths:
        if f"{chart}.yaml" not in paths.group(1):
            continue          # scoped to a different chart
        statements[key] = reason
    else:
        statements.setdefault(key, reason)

meta = {f[0]: (f[1], f[2]) for f in every}
RANK = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3, "UNKNOWN": 4}
def order(item):
    return (RANK.get(meta[item[0]][0], 9), item[0])

lines = [f"### `{chart}`", ""]
lines.append(
    f"{len(still_open)} finding(s) to act on, {sum(suppressed.values())} covered by a "
    f"documented exception - from {os.environ['DOCS']} manifests rendered with "
    f"`{os.environ['VALUES_LABEL']}`."
)
lines.append("")

if still_open:
    lines += ["| ID | Severity | Occurrences | Check |", "|---|---|---|---|"]
    for ident, count in sorted(open_counter.items(), key=order):
        sev, title = meta[ident]
        lines.append(f"| [{ident}](https://avd.aquasec.com/misconfig/{ident.lower()}) "
                     f"| {sev} | {count} | {title} |")
else:
    lines.append("No findings outside the documented exceptions.")
lines.append("")

if suppressed:
    lines += ["<details><summary>Covered by a documented exception "
              f"({sum(suppressed.values())})</summary>", "",
              "| ID | Occurrences | Why |", "|---|---|---|"]
    for ident, count in sorted(suppressed.items(), key=order):
        lines.append(f"| {ident} | {count} | {statements.get(ident, '(no statement)')} |")
    lines += ["", "</details>", ""]

with open(summary_path, "a") as fh:
    fh.write("\n".join(lines) + "\n")

# Annotations, capped: GitHub shows only the first handful, and a wall of them
# trains people to scroll past.
for ident, count in sorted(open_counter.items(), key=order)[:5]:
    sev, title = meta[ident]
    print(f"::warning title=trivy {chart}::{ident} ({sev}, x{count}): {title}")

print(f"{chart}: {len(still_open)} to act on, {sum(suppressed.values())} excepted")
sys.exit(1 if (still_open and os.environ["MODE"] == "gate") else 0)
PY
