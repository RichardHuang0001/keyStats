#!/bin/bash
# Build, sign, and vendor KeyStatsHelper.app into vendor/.
#
# Run this whenever you change KeyStatsHelper sources or its entitlements.
# CI checks source.sha256 against inputs and cdhash.txt against the bundle;
# forgetting to run this after a helper change will fail the build.
#
# Usage: ./scripts/rebuild_vendored_helper.sh

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

SOURCE_HASH=$(python3 "$SCRIPT_DIR/helper_source_fingerprint.py" "$PROJECT_DIR")

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "🔨 Building KeyStatsHelper (Release, universal)..."
xcodebuild -project KeyStats.xcodeproj \
    -scheme helper \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/dd" \
    CODE_SIGN_IDENTITY="-" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    -destination 'platform=macOS' \
    build > "$BUILD_DIR/xcodebuild.log" 2>&1 \
    || { tail -50 "$BUILD_DIR/xcodebuild.log"; exit 1; }

HELPER_BUILT="$BUILD_DIR/dd/Build/Products/Release/KeyStatsHelper.app"
if [ ! -d "$HELPER_BUILT" ]; then
    echo "❌ Helper build product not found at $HELPER_BUILT"
    exit 1
fi

echo "🔏 Signing helper with KeyStatsHelper.entitlements..."
codesign --force --sign - \
    --entitlements "$PROJECT_DIR/KeyStatsHelper/KeyStatsHelper.entitlements" \
    "$HELPER_BUILT"

CDHASH=$(codesign -d -vvv "$HELPER_BUILT" 2>&1 | awk -F'=' '/^CDHash=/ {print $2}')
if [ -z "$CDHASH" ]; then
    echo "❌ Failed to extract cdhash from signed helper"
    exit 1
fi

codesign --verify --strict --all-architectures "$HELPER_BUILT"
if [ "$SOURCE_HASH" != "$(python3 "$SCRIPT_DIR/helper_source_fingerprint.py" "$PROJECT_DIR")" ]; then
    echo "❌ Helper inputs changed during build; refusing to vendor. Run again."
    exit 1
fi

echo "📦 Replacing vendor/KeyStatsHelper.app..."
mkdir -p vendor
# Invalidate provenance before replacing the bundle; interrupted copies fail closed.
rm -f vendor/KeyStatsHelper.source.sha256
rm -rf vendor/KeyStatsHelper.app
ditto "$HELPER_BUILT" vendor/KeyStatsHelper.app

echo "$CDHASH" > vendor/KeyStatsHelper.cdhash.txt
echo "$SOURCE_HASH" > vendor/KeyStatsHelper.source.sha256

echo ""
echo "✅ Vendored helper updated."
echo "   Path:   vendor/KeyStatsHelper.app"
echo "   CDHash: $CDHASH"
echo ""
echo "Next: review with 'git status' and commit both vendor/KeyStatsHelper.app"
echo "and vendor/KeyStatsHelper.{cdhash.txt,source.sha256} together."
