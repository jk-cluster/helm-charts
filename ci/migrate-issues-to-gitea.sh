#!/usr/bin/env bash
# Copy this repository's GitHub issues into the Gitea repository, over the API.
#
# Part of the move to JLab-Git (#225). The Gitea repo already exists and keeps
# its history, so Gitea's own "migrate from GitHub" is not available - it
# insists on creating the repository itself. What is left is this: read the
# issues from GitHub, write them to Gitea.
#
# WHAT THIS SCRIPT CANNOT DO - read this before running it
#
# Three losses are inherent to the API path, not bugs to be fixed later. They
# are named here because each of them is invisible in the result: the migrated
# issue looks complete, and only the detail is gone.
#
#   1. COMMENT AUTHORSHIP. Every issue and every comment is created by the
#      token's user. Gitea has no "create as another user" outside the admin
#      sudo API, and the GitHub accounts do not exist on the instance anyway.
#      The script therefore prepends an attribution line to each body naming
#      the original author and date. A thread of three people still reads as
#      three people - but the avatar, the @mention and every "authored by"
#      filter say the token's user wrote all of it.
#
#   2. CROSS-REFERENCES BETWEEN ISSUES. Gitea hands out numbers sequentially,
#      and issues and pull requests share one counter on both systems, so
#      GitHub's #218 does not become Gitea's #218. Every "#<n>" inside a body,
#      a comment, a values.yaml, a NOTES.txt or a commit message then points at
#      a different entry - silently, because a wrong number still renders as a
#      valid link. This script does NOT rewrite them. It writes the mapping to
#      --map-file (old<TAB>new, one per line) so the rewrite can be decided and
#      done separately; #225 lists the options and none of them is decided.
#
#   3. ATTACHMENTS. Images and files in a body live behind GitHub's
#      user-content CDN. The markdown is copied verbatim, so the links keep
#      working exactly as long as the GitHub repo stays reachable - and break
#      the day it does not. Re-uploading them is a separate job (download,
#      POST to Gitea's attachment API, rewrite the link) and deliberately not
#      part of this one.
#
# Smaller ones, for completeness: milestones, assignees, reactions, review
# threads and the closed pull requests are not migrated. Pull requests are
# skipped entirely - a PR without its branch and diff is a dead entry, and
# every branch it referred to is merged or gone.
#
# USAGE
#
#   GITEA_URL=https://<instance> GITEA_TOKEN=<token> \
#     ci/migrate-issues-to-gitea.sh --dry-run
#
#   --state open|closed|all   which issues (default: open)
#   --limit N                 stop after N issues (a trial run on real data)
#   --map-file PATH           where old->new lands (default: issue-map.tsv)
#   --source OWNER/REPO       GitHub source (default: jk-cluster/helm-charts)
#   --target OWNER/REPO       Gitea target  (default: jlab-cluster/helm-charts)
#
# The instance address comes from the environment, never from this file - the
# same rule the publish workflow follows for the registry URL.
#
# IDEMPOTENCE. The map file is also the guard: an issue already listed there is
# skipped. Delete the file and the next run creates everything a second time,
# so keep it next to the migration and do not regenerate it from scratch.
#
# REQUIREMENTS. `gh` authenticated against github.com (in this setup that means
# `op plugin run -- gh`, otherwise the identity falls back to the wrong user),
# plus `curl`, `jq` and a Gitea token with write access to issues on the target
# repo.

set -euo pipefail

DRY_RUN=0
STATE=open
LIMIT=0
MAP_FILE=issue-map.tsv
SOURCE_REPO=jk-cluster/helm-charts
TARGET_REPO=jlab-cluster/helm-charts

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --state) STATE="${2:?--state needs open|closed|all}"; shift ;;
    --limit) LIMIT="${2:?--limit needs a number}"; shift ;;
    --map-file) MAP_FILE="${2:?--map-file needs a path}"; shift ;;
    --source) SOURCE_REPO="${2:?--source needs OWNER/REPO}"; shift ;;
    --target) TARGET_REPO="${2:?--target needs OWNER/REPO}"; shift ;;
    -h | --help) sed -n '2,66p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$STATE" in
  open | closed | all) ;;
  *) echo "--state must be open, closed or all (got: $STATE)" >&2; exit 2 ;;
esac

for tool in gh curl jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing required tool: $tool" >&2
    exit 1
  }
done

# The target address is required even for a dry run: a dry run that skips the
# address proves less than it appears to, and the run would then differ from
# the real one in more than the writes.
: "${GITEA_URL:?set GITEA_URL to the instance base URL, e.g. https://git.example.com}"
GITEA_URL="${GITEA_URL%/}"
if [ "$DRY_RUN" -eq 0 ]; then
  : "${GITEA_TOKEN:?set GITEA_TOKEN to a token with issue write access on $TARGET_REPO}"
fi

API="$GITEA_URL/api/v1"

# The token goes into a curl config file rather than onto the command line, so
# it never appears in the process list - the same reason publish-helm-chart.yml
# pipes its options into `curl --config -`. Here it is a file and not stdin,
# because stdin carries the JSON body. mktemp creates it 0600.
CURL_CFG="$(mktemp)"
trap 'rm -f "$CURL_CFG"' EXIT
if [ "$DRY_RUN" -eq 0 ]; then
  printf 'header = "Authorization: token %s"\n' "$GITEA_TOKEN" >"$CURL_CFG"
fi

# --fail-with-body turns 401/403/422 into a non-zero exit and still prints the
# response. Without it curl exits 0 on all of them and the migration would
# report success having written nothing.
gitea() {
  local method="$1" path="$2"
  if [ "$method" = GET ]; then
    curl --config "$CURL_CFG" --silent --show-error --fail-with-body \
      --request GET "$API/$path"
  else
    curl --config "$CURL_CFG" --silent --show-error --fail-with-body \
      --request "$method" \
      --header "Content-Type: application/json" \
      --data-binary @- "$API/$path"
  fi
}

say() { printf '%s\n' "$*"; }

[ "$DRY_RUN" -eq 1 ] && say "DRY RUN - nothing is written to $GITEA_URL"
say "source: github.com/$SOURCE_REPO   target: $GITEA_URL/$TARGET_REPO"
say "state:  $STATE   map file: $MAP_FILE"
say ""

touch "$MAP_FILE"

# --- labels ------------------------------------------------------------------
#
# A label that does not exist on the target is dropped by Gitea's issue API
# without an error, so they are created on demand below. Names are compared
# case-sensitively, which is how both systems store them.
existing_labels=""
if [ "$DRY_RUN" -eq 0 ]; then
  existing_labels="$(gitea GET "repos/$TARGET_REPO/labels?limit=100" | jq -r '.[].name')"
fi

# --- issues ------------------------------------------------------------------
#
# --paginate walks every page; PRs are filtered out here rather than by an API
# flag, because GitHub's issues endpoint returns them too and only the
# .pull_request key tells them apart. Oldest first, so the Gitea numbers come
# out in the same order as the originals even though the values differ.
issues_json="$(gh api --paginate \
  -H "Accept: application/vnd.github+json" \
  "repos/$SOURCE_REPO/issues?state=$STATE&per_page=100&sort=created&direction=asc" |
  jq -s 'add | map(select(.pull_request == null))')"

total="$(jq 'length' <<<"$issues_json")"
say "found $total issue(s) on GitHub (pull requests excluded)"
say ""

count=0
while read -r number; do
  [ -n "$number" ] || continue

  if grep -qE "^${number}	" "$MAP_FILE"; then
    say "#$number  already migrated (in $MAP_FILE) - skipped"
    continue
  fi

  if [ "$LIMIT" -gt 0 ] && [ "$count" -ge "$LIMIT" ]; then
    say "--limit $LIMIT reached, stopping"
    break
  fi
  count=$((count + 1))

  issue="$(jq --argjson n "$number" '.[] | select(.number == $n)' <<<"$issues_json")"
  title="$(jq -r '.title' <<<"$issue")"
  state="$(jq -r '.state' <<<"$issue")"
  labels="$(jq -c '[.labels[].name]' <<<"$issue")"

  # The provenance line is the only edit made to a body. It carries the old
  # number, which is what makes an un-rewritten "#<n>" elsewhere traceable at
  # all, and it names the original author because the API cannot.
  body="$(jq -r '
    "_Migriert von GitHub: " + .html_url + " - urspruenglich von @" + .user.login
      + " am " + (.created_at | split("T")[0]) + "._\n\n"
      + (.body // "")' <<<"$issue")"

  say "#$number  $title  [$state, labels: $labels]"

  if [ "$DRY_RUN" -eq 1 ]; then
    comment_count="$(jq -r '.comments' <<<"$issue")"
    suffix=""
    [ "$state" = closed ] && suffix=", then close it"
    say "          would create the issue, $comment_count comment(s)$suffix"
    continue
  fi

  # Create any label this issue needs and the target does not have yet.
  while read -r label; do
    [ -n "$label" ] || continue
    if ! grep -qxF "$label" <<<"$existing_labels"; then
      jq -n --arg n "$label" '{name: $n, color: "#ededed"}' |
        gitea POST "repos/$TARGET_REPO/labels" >/dev/null
      existing_labels="$existing_labels"$'\n'"$label"
      say "          created label: $label"
    fi
  done < <(jq -r '.[]' <<<"$labels")

  created="$(jq -n --arg t "$title" --arg b "$body" --argjson l "$labels" \
    '{title: $t, body: $b, labels: $l}' |
    gitea POST "repos/$TARGET_REPO/issues")"
  new_number="$(jq -r '.number' <<<"$created")"
  say "          -> $GITEA_URL/$TARGET_REPO/issues/$new_number"

  # Comments in order. Each gets the same attribution header as the body; see
  # loss (1) in the header of this file.
  while read -r comment; do
    [ -n "$comment" ] || continue
    comment_body="$(jq -r '
      "_@" + .user.login + " am " + (.created_at | split("T")[0])
        + " (migriert von GitHub)._\n\n" + (.body // "")' <<<"$comment")"
    jq -n --arg b "$comment_body" '{body: $b}' |
      gitea POST "repos/$TARGET_REPO/issues/$new_number/comments" >/dev/null
  done < <(gh api --paginate -H "Accept: application/vnd.github+json" \
    "repos/$SOURCE_REPO/issues/$number/comments?per_page=100" |
    jq -s -c 'add // [] | .[]')

  if [ "$state" = closed ]; then
    jq -n '{state: "closed"}' |
      gitea PATCH "repos/$TARGET_REPO/issues/$new_number" >/dev/null
    say "          closed"
  fi

  printf '%s\t%s\n' "$number" "$new_number" >>"$MAP_FILE"
done < <(jq -r '.[].number' <<<"$issues_json")

say ""
if [ "$DRY_RUN" -eq 1 ]; then
  say "dry run finished - $count issue(s) would have been created"
else
  say "finished - $count issue(s) created, mapping appended to $MAP_FILE"
  say "the mapping is the input for the #<n> rewrite, which this script does not do"
fi
