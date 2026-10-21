#!/usr/bin/env bash
#
# dev_install_helper.sh — build, sign, install, and launch a ProcexpMac.app that
# can use the privileged root helper (the elevation test path).
#
# This is the everyday "build and run the elevated-capable app" loop. It:
#   1. builds ProcexpMac.app (Debug by default — fast),
#   2. embeds the root helper + launchd plist at the production location,
#   3. signs everything inside-out with a stable (non-ad-hoc) identity,
#   4. installs to /Applications (SMAppService ties the helper registration to
#      the app's signature + this location), and
#   5. launches it.
#
# An accepted signing identity must already exist; this script never creates
# an identity, unlocks a keychain, changes trust or updates its search list.
# Then use the app's
# "Install Privileged Helper…" menu once and approve it in System Settings ▸
# General ▸ Login Items & Extensions. After that, every subsequent run of this
# script checks prerequisites again; registration is not inferred from signing.
#
# NOTE ON HELPER CODE CHANGES: the running root daemon keeps executing the
# already-loaded binary until it is restarted. Changes to the APP are picked up
# on relaunch, but changes to the HELPER's own code require restarting the
# daemon — separately approve RESTART_HELPER=1 (noninteractive sudo) to do that.
#
# Env:
#   CONFIGURATION               Debug or Release (defaults by signing flavor)
#   DEV_SIGN_IDENTITY           signing identity (default: "ProcexpMac Dev")
#   DEV_SIGN_KEYCHAIN           optional dedicated keychain for codesign
#   PROCEXP_LOCAL_FLAVOR        development (default) or explicitly approved official
#   PROCEXP_HELPER_INSTALL_APPROVED   required (value 1)
#   PROCEXP_HELPER_REPLACE_APPROVED   required for an existing target app (value 1)
#   PROCEXP_HELPER_OFFICIAL_APPROVED  required for the official tuple (value 1)
#   PROCEXP_HELPER_RESTART_APPROVED   required with RESTART_HELPER=1 (value 1)
#   INSTALL_DIR                 install destination (default: /Applications)
#   RESTART_HELPER              1 to restart the root daemon after install (sudo)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="${CONFIGURATION:-}"
IDENTITY="${DEV_SIGN_IDENTITY:-ProcexpMac Dev}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
SIGN_KEYCHAIN="${DEV_SIGN_KEYCHAIN:-}"
RESTART_HELPER="${RESTART_HELPER:-0}"
BUILD_DIR="$REPO_ROOT/build"
DERIVED="$BUILD_DIR/DerivedData"
HELPER_ENTITLEMENTS="$REPO_ROOT/Helper/ProcexpHelper.entitlements"

fail() { echo "ERROR: $*" >&2; exit 1; }

move_exact() {
    # Unlike mv, rename cannot silently nest a bundle inside an occupied destination.
    python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$1" "$2"
}

python3 "$REPO_ROOT/Scripts/helper_lifecycle_guard.py" install

IS_OFFICIAL=0
if [[ "${PROCEXP_LOCAL_FLAVOR:-development}" == "official" ]]; then
    IS_OFFICIAL=1
fi

if [[ "$IS_OFFICIAL" -eq 1 ]]; then
    CONFIGURATION="${CONFIGURATION:-Release}"
    APP_BUNDLE_ID="com.sysinternals.procexpmac"
    APP_DISPLAY_NAME="Process Explorer"
    APP_WRAPPER_NAME="ProcexpMac.app"
    APP_INSTALL_NAME="ProcExp.app"
    HELPER_NAME="com.sysinternals.procexpmac.helper"
    HELPER_FLAVOR="official"
    HELPER_CONFIGURATION="release"
else
    DERIVED="$BUILD_DIR/DerivedData-Development"
    CONFIGURATION="${CONFIGURATION:-Debug}"
    APP_BUNDLE_ID="com.sysinternals.procexpmac.dev"
    APP_DISPLAY_NAME="Process Explorer (Dev)"
    APP_WRAPPER_NAME="ProcExp (Dev).app"
    APP_INSTALL_NAME="$APP_WRAPPER_NAME"
    HELPER_NAME="com.sysinternals.procexpmac.dev.helper"
    HELPER_FLAVOR="development"
    HELPER_CONFIGURATION="debug"
fi
APP_SRC="$DERIVED/Build/Products/$CONFIGURATION/$APP_WRAPPER_NAME"
APP_DEST="$INSTALL_DIR/$APP_INSTALL_NAME"
case "$CONFIGURATION" in
    Debug|Release) ;;
    *) fail "CONFIGURATION must be Debug or Release" ;;
esac

SIGNING_READINESS="$(DEV_SIGN_IDENTITY="$IDENTITY" DEV_SIGN_KEYCHAIN="$SIGN_KEYCHAIN" \
    python3 "$REPO_ROOT/Scripts/helper_lifecycle_guard.py" signing)"
IDENTITY="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["certificateSHA1"])' \
    "$SIGNING_READINESS")"

echo "==> Using signing identity: $IDENTITY"
if [[ "$IS_OFFICIAL" -eq 0 ]]; then
    cat <<'NOTE'
    NOTE: this is the isolated development tuple. Signing a bundle does not
    prove macOS will accept its helper registration. The user must approve
    the actual SMAppService flow; denied registration is not qualification.
NOTE
fi

# ---------------------------------------------------------------------------
# 1. Build the app.
# ---------------------------------------------------------------------------
echo "==> Building $CONFIGURATION app…"
if [[ "$CONFIGURATION" == "Release" ]]; then
    PROCEXP_BUILD_FLAVOR="$HELPER_FLAVOR" PACKAGE_DMG=0 \
        bash "$REPO_ROOT/Scripts/build_release.sh"
else
    echo "==> Regenerating Xcode project (xcodegen)…"
    xcodegen generate >/dev/null
    xcodebuild -project ProcexpMac.xcodeproj -scheme ProcexpMac \
        -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED" \
        "PRODUCT_BUNDLE_IDENTIFIER=$APP_BUNDLE_ID" \
        "INFOPLIST_KEY_CFBundleDisplayName=$APP_DISPLAY_NAME" \
        "WRAPPER_NAME=$APP_WRAPPER_NAME" \
        build >/dev/null
fi
[[ -d "$APP_SRC" ]] || fail "expected app not found at $APP_SRC"

# ---------------------------------------------------------------------------
# 2. Embed the helper + plist at the production location.
# ---------------------------------------------------------------------------
if [[ "$CONFIGURATION" == "Debug" ]]; then
    PROCEXP_HELPER_FLAVOR="$HELPER_FLAVOR" \
    PROCEXP_APP_BUNDLE_ID="$APP_BUNDLE_ID" \
    PROCEXP_HELPER_NAME="$HELPER_NAME" \
    HELPER_CONFIGURATION="$HELPER_CONFIGURATION" \
        bash "$REPO_ROOT/Scripts/embed_helper.sh" "$APP_SRC"
fi
HELPER_PATH="$APP_SRC/Contents/Library/LaunchDaemons/$HELPER_NAME"

# ---------------------------------------------------------------------------
# 3. Inside-out code signing with the chosen identity.
#
# The Hardened Runtime enables *library validation*, which rejects any nested
# Mach-O whose Team ID differs from the main binary's. Self-signed certificates
# have no Team ID, so a hardened self-signed app cannot load its own Debug side
# dylibs (ProcexpMac.debug.dylib) — dyld exits with "different Team IDs". For
# self-signed builds we therefore add the cs.disable-library-validation
# entitlement, which turns library validation off even under the Hardened
# Runtime. Developer ID builds keep validation on (their Team ID matches).
# ---------------------------------------------------------------------------
SIGN=(codesign --force --options runtime --timestamp=none --sign "$IDENTITY")
if [[ -n "$SIGN_KEYCHAIN" ]]; then
    SIGN+=(--keychain "$SIGN_KEYCHAIN")
fi

echo "==> Signing nested frameworks/dylibs…"
if [[ -d "$APP_SRC/Contents/Frameworks" ]]; then
    while IFS= read -r -d '' item; do
        "${SIGN[@]}" "$item"
    done < <(find "$APP_SRC/Contents/Frameworks" -type d -name "*.framework" -print0)
    while IFS= read -r -d '' item; do
        "${SIGN[@]}" "$item"
    done < <(find "$APP_SRC/Contents/Frameworks" -type f -name "*.dylib" -print0)
fi

# Debug builds ship side dylibs (ProcexpMac.debug.dylib, __preview.dylib) in
# Contents/MacOS; sign them with the same identity as the app.
echo "==> Signing nested executables in Contents/MacOS…"
while IFS= read -r -d '' item; do
    "${SIGN[@]}" "$item"
done < <(find "$APP_SRC/Contents/MacOS" -type f -name "*.dylib" -print0)

echo "==> Signing embedded helper (with debugger entitlement)…"
"${SIGN[@]}" --identifier "$HELPER_NAME" \
    --entitlements "$HELPER_ENTITLEMENTS" "$HELPER_PATH"

echo "==> Signing app bundle…"
if [[ "$IS_OFFICIAL" -eq 1 ]]; then
    # Developer ID: entitlement-free app with library validation enabled.
    "${SIGN[@]}" "$APP_SRC"
else
    # Self-signed: disable library validation so the Debug side dylibs load, and
    # omit the restricted com.apple.developer.* entitlement (which blocks launch).
    DEV_ENT="$(mktemp -t procexp-dev-ent)"
    trap 'rm -f "$DEV_ENT"' EXIT
    cat > "$DEV_ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
PLIST
    "${SIGN[@]}" --entitlements "$DEV_ENT" "$APP_SRC"
    rm -f "$DEV_ENT"
    trap - EXIT
fi

echo "==> Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP_SRC"
if [[ "$IS_OFFICIAL" -eq 1 ]]; then
    APPLE_DEVELOPER_ID='=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    codesign --verify --strict -R "$APPLE_DEVELOPER_ID" "$APP_SRC"
    codesign --verify --strict -R "$APPLE_DEVELOPER_ID" "$HELPER_PATH"
fi

ACTUAL_APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c \
    'Print :CFBundleIdentifier' "$APP_SRC/Contents/Info.plist")"
[[ "$ACTUAL_APP_BUNDLE_ID" == "$APP_BUNDLE_ID" ]] || fail \
    "app bundle id is $ACTUAL_APP_BUNDLE_ID; expected $APP_BUNDLE_ID"
ACTUAL_HELPER_ID="$(codesign -d --verbose=4 "$HELPER_PATH" 2>&1 \
    | sed -n 's/^Identifier=//p' | head -1)"
[[ "$ACTUAL_HELPER_ID" == "$HELPER_NAME" ]] || fail \
    "helper signed identifier is $ACTUAL_HELPER_ID; expected $HELPER_NAME"

# ---------------------------------------------------------------------------
# 4. Install to a stable location and launch.
# ---------------------------------------------------------------------------
echo "==> Installing to $APP_DEST"
python3 "$REPO_ROOT/Scripts/helper_lifecycle_guard.py" install
STAGE="$(mktemp -d "$INSTALL_DIR/.procexp-approved-install.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP_SRC" "$STAGE/$APP_INSTALL_NAME"
codesign --verify --deep --strict "$STAGE/$APP_INSTALL_NAME"
python3 "$REPO_ROOT/Scripts/helper_lifecycle_guard.py" install
BACKUP=""
if [[ -d "$APP_DEST" ]]; then
    BACKUP="$APP_DEST.backup.$(uuidgen)"
    [[ ! -e "$BACKUP" && ! -L "$BACKUP" ]] || fail "backup destination already exists"
    move_exact "$APP_DEST" "$BACKUP"
    echo "==> Preserved previous app at $BACKUP"
fi
if ! move_exact "$STAGE/$APP_INSTALL_NAME" "$APP_DEST"; then
    if [[ -n "$BACKUP" ]]; then
        [[ ! -e "$APP_DEST" && ! -L "$APP_DEST" ]] || fail \
            "install destination changed; previous app preserved at $BACKUP"
        move_exact "$BACKUP" "$APP_DEST" || fail "could not restore previous app; preserved at $BACKUP"
        fail "install swap failed; previous app restored"
    fi
    fail "install swap failed; no previous app changed"
fi

# ---------------------------------------------------------------------------
# 5. Optionally restart the root daemon so it loads the freshly built helper
#    binary (needed only when the HELPER's own code changed).
# ---------------------------------------------------------------------------
if [[ "$RESTART_HELPER" == "1" ]]; then
    echo "==> Restarting the separately approved root helper daemon…"
    sudo -n launchctl kickstart -k "system/$HELPER_NAME"
fi

echo "==> Launching $APP_DEST"
open -n "$APP_DEST"

HELPER_STATE="$(python3 "$REPO_ROOT/Scripts/helper_lifecycle_guard.py" status)"

cat <<EOF

==> DONE.
    Installed: $APP_DEST
    Config:    $CONFIGURATION
    Identity:  $IDENTITY
    Bundle ID: $APP_BUNDLE_ID
    Helper:    $HELPER_STATE

First-time only: choose "Install Privileged Helper…" in the app, then approve it
in System Settings ▸ General ▸ Login Items & Extensions.

If you changed the HELPER's code, reload the daemon with:
  PROCEXP_HELPER_INSTALL_APPROVED=1 PROCEXP_HELPER_REPLACE_APPROVED=1 \\
  PROCEXP_HELPER_RESTART_APPROVED=1 RESTART_HELPER=1 bash Scripts/dev_install_helper.sh

Inspect daemon status:
  PROCEXP_LOCAL_FLAVOR=$HELPER_FLAVOR python3 Scripts/helper_lifecycle_guard.py status

Clean up:
    Use the app's "Uninstall Privileged Helper…" menu and quit it first, then:
    PROCEXP_HELPER_REMOVE_APPROVED=1 PROCEXP_HELPER_UNREGISTERED=1 \\
    PROCEXP_LOCAL_FLAVOR=$HELPER_FLAVOR bash Scripts/dev_uninstall_helper.sh
EOF
