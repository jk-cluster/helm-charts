#!/bin/sh
# Recompute a chart's `version:` after Renovate changed something inside its
# directory.
#
# Renovate rewrites `appVersion:` in Chart.yaml (main image) or an image tag in
# values.yaml (sidecar/init image). It has no idea about this repo's scheme
#
#     version: <chart-semver>+up<app-version-with-dashes-normalized-to-dots>
#
# and it never touches `version:` at all — which would leave every Renovate PR
# failing the `build-chart` version-bump check. This script closes that gap and
# is wired up as a `postUpgradeTasks` command in renovate.json5.
#
# Usage: ci/renovate-bump-chart.sh <chart-directory>
#
# Bump level (README "Versioning"):
#   - app major changed  -> chart major, minor/patch reset to 0
#   - anything else      -> chart patch (plain app updates, sidecar images)
#
# Everything is derived from the base commit (HEAD, which during
# postUpgradeTasks still points at the base branch), never from the working
# tree's `version:`. That makes repeated runs on the same branch idempotent —
# Renovate calls the script once per dependency update, and a branch may carry
# more than one update for the same chart.
#
# Runs inside the Renovate container, so: POSIX sh, no bashisms, no jq/yq.

set -eu

dir=${1:-}
[ -n "$dir" ] || exit 0

# Strip a trailing slash so "outline/" and "outline" behave the same.
dir=${dir%/}

# Renovate also calls this for .github/workflows and other non-chart updates.
case "$dir" in
  "" | "." | .github* | ci*) exit 0 ;;
esac

chart="$dir/Chart.yaml"
[ -f "$chart" ] || exit 0

# The scaffold is never published and its version carries no meaning.
[ "$dir" != "template-chart" ] || exit 0

# Reads a top-level scalar field, unquoted and untrimmed of surrounding spaces.
field() {
  sed -n "s/^$1:[[:space:]]*//p" | head -n 1 | tr -d "\"' "
}

base=$(git show "HEAD:$chart" 2>/dev/null) || {
  echo "renovate-bump: $chart is new on this branch, leaving its version alone"
  exit 0
}

base_version=$(printf '%s\n' "$base" | field version)
base_app=$(printf '%s\n' "$base" | field appVersion)
new_app=$(field appVersion <"$chart")

if [ -z "$base_version" ] || [ -z "$new_app" ]; then
  echo "renovate-bump: $chart has no version/appVersion to work with" >&2
  exit 1
fi

# <chart-semver> is everything before the +up build suffix.
semver=${base_version%%+*}
case "$semver" in
  *.*.*) ;;
  *)
    echo "renovate-bump: cannot parse chart semver '$semver' in $chart" >&2
    exit 1
    ;;
esac

major=${semver%%.*}
rest=${semver#*.}
minor=${rest%%.*}
patch=${rest#*.}

for part in "$major" "$minor" "$patch"; do
  case "$part" in
    '' | *[!0-9]*)
      echo "renovate-bump: non-numeric component in chart semver '$semver'" >&2
      exit 1
      ;;
  esac
done

# Leading major of an app version: v1.159.0 -> 1, 3.3.1.0-full -> 3,
# 2025-06-03 -> 2025.
app_major() {
  printf '%s' "$1" | sed -e 's/^[vV]//' -e 's/[^0-9].*$//'
}

if [ "$new_app" != "$base_app" ] && [ "$(app_major "$new_app")" != "$(app_major "$base_app")" ]; then
  reason="app major $base_app -> $new_app"
  new_semver="$((major + 1)).0.0"
else
  reason="patch-level change"
  new_semver="$major.$minor.$((patch + 1))"
fi

# Dashes in the app version become dots in the +up suffix.
suffix=$(printf '%s' "$new_app" | tr '-' '.')
new_version="$new_semver+up$suffix"

sed -i.bak "s|^version:.*|version: $new_version|" "$chart"
rm -f "$chart.bak"

echo "renovate-bump: $chart $base_version -> $new_version ($reason)"
