#!/usr/bin/env bash
# Publish the unsigned IPA to a GitHub release so it can be downloaded without
# signing into Actions. Re-runs replace the assets of the same tag.
set -uo pipefail

TAG="v0.1.64"
IPA="dist/WeBox-unsigned.ipa"
TIPA="dist/WeBox-unsigned.tipa"
if [ ! -f "$IPA" ]; then
  echo "no ipa to publish"
  exit 1
fi

SHA=$(shasum -a 256 "$IPA" | cut -d" " -f1)
mkdir -p dist
{
  echo "WeBox for iOS 0.1.64 (Android 0.1.64 / versionCode 67 的 SwiftUI 复刻)"
  echo ""
  echo "- 构建: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  echo "- 提交: $GITHUB_SHA"
  echo "- SHA-256: $SHA"
  echo ""
  echo "未签名 IPA，需要通过 Sideloadly / AltStore 用 Apple ID 重签后安装，"
  echo "或配置仓库 secrets 让工作流产出已签名版本。"
} > dist/notes.md

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$IPA" "$TIPA" --clobber
  gh release edit "$TAG" --notes-file dist/notes.md --latest
else
  gh release create "$TAG" --title "WeBox 0.1.64" --notes-file dist/notes.md --latest "$IPA" "$TIPA"
fi
echo "release: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/releases/tag/$TAG"
