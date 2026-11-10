#!/usr/bin/env bash
# Publish a short success report (artifact sizes, IPA contents, sha256) as an
# issue comment so the result is reviewable without downloading artifacts.
set -uo pipefail

mkdir -p dist
{
  echo "Run: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  echo ""
  echo "### artifacts"
  echo "<pre>"
  ls -lh dist 2>/dev/null || true
  echo "</pre>"
  if [ -f dist/WeBox-unsigned.ipa ]; then
    echo "### ipa contents"
    echo "<pre>"
    unzip -l dist/WeBox-unsigned.ipa | head -n 20
    echo "</pre>"
    echo "### sha256"
    echo "<pre>"
    shasum -a 256 dist/WeBox-unsigned.ipa
    echo "</pre>"
  fi
  echo "### app info"
  echo "<pre>"
  plutil -p Payload/WeBox.app/Info.plist 2>/dev/null | head -n 20 || true
  echo "</pre>"
} > dist/report.md

TITLE="[ci] build report"
NUM=$(gh issue list --state open --search "$TITLE in:title" --json number --jq ".[0].number // empty" 2>/dev/null || true)
if [ -n "$NUM" ]; then
  gh issue comment "$NUM" --body-file dist/report.md
else
  gh issue create --title "$TITLE" --body-file dist/report.md
fi
