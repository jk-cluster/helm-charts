#!/bin/bash
# Throwaway PR watcher (not committed). Exits when the PR leaves OPEN state
# or any review/issue comment appears.
REPO=jk-cluster/helm-charts
PR=21
while true; do
  STATE=$(gh pr view $PR --repo $REPO --json state --jq .state 2>/dev/null)
  RC=$(gh api repos/$REPO/pulls/$PR/comments --jq length 2>/dev/null)
  IC=$(gh api repos/$REPO/issues/$PR/comments --jq length 2>/dev/null)
  if [ -n "$STATE" ] && [ "$STATE" != "OPEN" ]; then break; fi
  if [ -n "$RC" ] && [ "$RC" != "0" ]; then break; fi
  if [ -n "$IC" ] && [ "$IC" != "0" ]; then break; fi
  sleep 90
done
echo "STATE=$STATE REVIEW_COMMENTS=$RC ISSUE_COMMENTS=$IC"
