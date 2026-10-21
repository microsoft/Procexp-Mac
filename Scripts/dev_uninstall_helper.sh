#!/usr/bin/env bash
# Remove only the explicitly approved app after its helper is unregistered.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$REPO_ROOT/Scripts/helper_lifecycle_guard.py" remove

INSTALL_DIR="${INSTALL_DIR:-/Applications}"
LOCAL_FLAVOR="${PROCEXP_LOCAL_FLAVOR:-development}"
case "$LOCAL_FLAVOR" in
    development) APP_DEST="$INSTALL_DIR/ProcExp (Dev).app" ;;
    official) APP_DEST="$INSTALL_DIR/ProcExp.app" ;;
    *) echo "ERROR: invalid helper flavor" >&2; exit 1 ;;
esac

echo "==> Removing the approved, unregistered app: $APP_DEST"
rm -rf "$APP_DEST"
echo "==> Removed $APP_DEST; no other app, keychain or system helper files were changed."
