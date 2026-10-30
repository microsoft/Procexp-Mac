#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

xcodebuild -project ProcexpMac.xcodeproj -scheme ProcexpMac \
    -configuration Debug -derivedDataPath build/DerivedData build

PRODUCTS="$REPO_ROOT/build/DerivedData/Build/Products/Debug"
APP_MACOS="$PRODUCTS/ProcExp (Dev).app/Contents/MacOS"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/procexp-outline-tests.XXXXXX")"
trap 'rm -f "$TEST_DIR/ProcessOutlineRegression"; rmdir "$TEST_DIR"' EXIT

xcrun swiftc -parse-as-library -I "$PRODUCTS" \
    "$REPO_ROOT/Tests/ProcessOutlineRegression/ProcessOutlineRegression.swift" \
    "$APP_MACOS/ProcexpMac.debug.dylib" \
    -Xlinker -rpath -Xlinker "$APP_MACOS" \
    -o "$TEST_DIR/ProcessOutlineRegression"
"$TEST_DIR/ProcessOutlineRegression"
