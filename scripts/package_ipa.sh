#!/usr/bin/env bash
# Package an unsigned .app into an IPA and a TrollStore .tipa.
# Usage: bash scripts/package_ipa.sh [Release|Debug]
set -euo pipefail

CONFIGURATION="${1:-Release}"
APP_PATH="build/Build/Products/${CONFIGURATION}-iphoneos/WeBox.app"

if [ ! -d "$APP_PATH" ]; then
  echo "error: $APP_PATH not found; run the xcodebuild build step first" >&2
  exit 1
fi

rm -rf Payload dist/WeBox-unsigned.ipa dist/WeBox-unsigned.tipa
mkdir -p Payload dist
cp -R "$APP_PATH" Payload/WeBox.app
# An unsigned build must not carry stale signature artifacts.
rm -rf Payload/WeBox.app/_CodeSignature Payload/WeBox.app/embedded.mobileprovision

zip -qry dist/WeBox-unsigned.ipa Payload
cp dist/WeBox-unsigned.ipa dist/WeBox-unsigned.tipa
rm -rf Payload

echo "built:"
ls -lh dist/WeBox-unsigned.ipa dist/WeBox-unsigned.tipa
