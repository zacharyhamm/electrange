#!/bin/bash
#
# Runs the electragne unit tests (Debug). Same invocation used by CI, so
# `./test.sh` locally and CI exercise the identical command.
#
# Usage: ./test.sh

set -euo pipefail

cd "$(dirname "$0")"

ARCH="$(uname -m)"

xcodebuild test \
    -project electragne.xcodeproj \
    -scheme electragne \
    -configuration Debug \
    -destination "platform=macOS,arch=$ARCH" \
    -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO
