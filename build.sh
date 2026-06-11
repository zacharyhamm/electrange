#!/bin/bash
#
# Builds a Release version of Electragne and places the app bundle at the
# repository root as Electragne.app. Run it from anywhere; requires Xcode.
#
# Usage: ./build.sh

set -euo pipefail

cd "$(dirname "$0")"

PRODUCT="build/Build/Products/Release/electragne.app"
DEST="Electragne.app"

echo "Building Release configuration..."
xcodebuild \
    -project electragne.xcodeproj \
    -scheme electragne \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath build \
    -quiet \
    build

rm -rf "$DEST"
cp -R "$PRODUCT" "$DEST"

echo "Done: $(pwd)/$DEST"
echo "Run it with: open $(pwd)/$DEST"
