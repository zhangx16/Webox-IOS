#!/usr/bin/env bash
# Publish xcodebuild diagnostics as a repo issue so the log stays readable
# without downloading artifacts. Requires GH_TOKEN with issues:write.
set -euo pipefail

LOG="dist/xcodebuild.log"
if [ ! -f "$LOG" ]; then
  echo "no build log to publish"
  exit 0
fi

mkdir -p dist
{
  echo "Run: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  echo ""
  echo "### errors"
  echo "<pre>"
  grep -nE "error:|fatal error|BUILD FAILED|The following build commands failed|does not contain a scheme|No such file" "$LOG" | head -n 120 || true
  echo "</pre>"
  echo "### tail"
  echo "<pre>"
  tail -n 60 "$LOG" || true
  echo "</pre>"
} > dist/issue.md

TITLE="[ci] xcodebuild failure log"
NUM=$(gh issue list --state open --search "$TITLE in:title" --json number --jq ".[0].number // empty" 2>/dev/null || true)
if [ -n "$NUM" ]; then
  gh issue comment "$NUM" --body-file dist/issue.md
else
  gh issue create --title "$TITLE" --body-file dist/issue.md
fi
