#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

xcodebuild -quiet -project ProcexpMac.xcodeproj -scheme ProcexpMac \
    -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

PRODUCTS="$REPO_ROOT/build/DerivedData/Build/Products/Debug"
APP_MACOS="$PRODUCTS/ProcExp (Dev).app/Contents/MacOS"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/procexp-helper-tests.XXXXXX")"
trap 'rm -f "$TEST_DIR/HelperRecoveryRegression"; rmdir "$TEST_DIR"' EXIT

xcrun swiftc -parse-as-library -I "$PRODUCTS" \
    "$REPO_ROOT/Tests/ProcexpPrivilegedTests/HelperStub.swift" \
    "$REPO_ROOT/Tests/HelperRecoveryRegression/HelperRecoveryRegression.swift" \
    "$APP_MACOS/ProcexpMac.debug.dylib" \
    -Xlinker -rpath -Xlinker "$APP_MACOS" \
    -o "$TEST_DIR/HelperRecoveryRegression"
"$TEST_DIR/HelperRecoveryRegression"
