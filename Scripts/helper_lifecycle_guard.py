#!/usr/bin/env python3
"""Explicit helper prerequisites and workspace-owned signing readiness probes."""
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from xml.parsers.expat import ExpatError

FLAVORS = {
    "development": ("ProcExp (Dev).app", "com.sysinternals.procexpmac.dev"),
    "official": ("ProcExp.app", "com.sysinternals.procexpmac"),
}


class GuardError(RuntimeError):
    pass


def require(environment, flag):
    if environment.get(flag) != "1":
        raise GuardError("Explicit scoped approval required: " + flag + "=1")


def authorize(action, environment):
    flags = {"install": "PROCEXP_HELPER_INSTALL_APPROVED",
             "remove": "PROCEXP_HELPER_REMOVE_APPROVED",
             "identity": "PROCEXP_SIGNING_KEYCHAIN_CREATE_APPROVED"}
    require(environment, flags[action])
    flavor = environment.get("PROCEXP_LOCAL_FLAVOR", "development")
    if flavor not in FLAVORS:
        raise GuardError("PROCEXP_LOCAL_FLAVOR must be development or official")
    if action != "identity" and flavor == "official":
        require(environment, "PROCEXP_HELPER_OFFICIAL_APPROVED")
    if action == "install" and environment.get("RESTART_HELPER", "0") == "1":
        require(environment, "PROCEXP_HELPER_RESTART_APPROVED")
    if action == "install" and environment.get("RESTART_HELPER", "0") not in ("0", "1"):
        raise GuardError("RESTART_HELPER must be 0 or 1")
    if action == "identity":
        if not environment.get("DEV_SIGN_KEYCHAIN_PASSWORD"):
            raise GuardError("Supply the new dedicated keychain password locally; no default password")
        keychain = Path(environment.get("DEV_SIGN_KEYCHAIN",
                                       str(Path.home() / "Library/Keychains/procexp-dev.keychain-db")))
        if not keychain.is_absolute():
            raise GuardError("The new dedicated keychain path must be absolute")
        if keychain.exists() or keychain.is_symlink():
            raise GuardError("Refusing to replace an existing keychain: " + str(keychain))
        if keychain.parent.resolve() != (Path.home() / "Library/Keychains").resolve():
            raise GuardError("The new dedicated keychain must be in ~/Library/Keychains")
        if not keychain.name.endswith(".keychain-db"):
            raise GuardError("Expected a dedicated .keychain-db filename")
    return flavor


def service_output(label):
    result = subprocess.run(["launchctl", "print", "system/" + label],
                            capture_output=True, text=True, timeout=15)
    if result.returncode == 0:
        return result.stdout
    if 'Could not find service "' + label + '"' in result.stderr:
        return None
    raise GuardError("Cannot establish helper registration state: " + result.stderr.strip())


def service_registered(label):
    return service_output(label) is not None


def ensure_quit(app):
    executable = app / "Contents/MacOS/ProcexpMac"
    result = subprocess.run(["pgrep", "-f", "^" + re.escape(str(executable)) + "( |$)"],
                            capture_output=True, text=True, timeout=15)
    if result.returncode == 0:
        raise GuardError("Quit the exact installed app before changing it; matching PIDs: " + result.stdout.strip())
    if result.returncode != 1:
        raise GuardError("Cannot establish installed-app process state: " + result.stderr.strip())


def destination(action, environment):
    flavor = authorize(action, environment)
    name, bundle_id = FLAVORS[flavor]
    directory = Path(environment.get("INSTALL_DIR", "/Applications"))
    if not directory.is_absolute():
        raise GuardError("INSTALL_DIR must be absolute")
    directory = directory.resolve()
    if not directory.is_dir():
        raise GuardError("Install directory does not exist")
    app = directory / name
    if app.is_symlink() or (app.exists() and not app.is_dir()):
        raise GuardError("Installed app path is redirected or is not a bundle")
    if app.exists():
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if info["CFBundleIdentifier"] != bundle_id:
            raise GuardError("Existing app does not match the selected helper tuple")
        if info["CFBundleExecutable"] != "ProcexpMac":
            raise GuardError("Existing app does not have the expected executable")
        if action == "install":
            require(environment, "PROCEXP_HELPER_REPLACE_APPROVED")
        ensure_quit(app)
    elif action == "remove":
        raise GuardError("Selected installed app is absent; no removal performed")
    label = bundle_id + ".helper"
    registered = service_registered(label)
    if action == "remove":
        require(environment, "PROCEXP_HELPER_UNREGISTERED")
        if registered:
            raise GuardError("Uninstall Privileged Helper in the app before removing its bundle")
        for legacy in (Path("/Library/LaunchDaemons") / (label + ".plist"),
                       Path("/Library/PrivilegedHelperTools") / label):
            if legacy.exists() or legacy.is_symlink():
                raise GuardError("Legacy system helper installation needs separately scoped cleanup: " + str(legacy))
    elif registered and environment.get("RESTART_HELPER") != "1":
        raise GuardError("Unregister the helper first, or explicitly approve RESTART_HELPER=1")
    elif not registered and environment.get("RESTART_HELPER") == "1":
        raise GuardError("Requested helper restart, but the selected service is absent")
    return {"app": str(app), "bundleID": bundle_id, "helper": label}


def signing_preflight(environment):
    authorize("install", environment)
    identity = environment.get("DEV_SIGN_IDENTITY", "ProcexpMac Dev")
    keychain = environment.get("DEV_SIGN_KEYCHAIN")
    command = ["security", "find-identity", "-v", "-p", "codesigning"]
    if keychain:
        if not Path(keychain).is_file():
            raise GuardError("Selected signing keychain does not exist")
        command.append(keychain)

    def checked(arguments):
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            raise GuardError("Signing readiness command failed: " + arguments[0] + ": "
                             + (result.stderr.strip() or result.stdout.strip()
                                or "exit " + str(result.returncode)))
        return result.stdout

    available = checked(command)
    matches = {fingerprint.upper() for fingerprint, name in re.findall(
        r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"]+)"\s*$', available, re.MULTILINE)
        if name == identity or fingerprint.casefold() == identity.casefold()}
    if len(matches) != 1:
        raise GuardError("Expected one trusted, valid code-signing identity for " + repr(identity)
                         + "; found " + str(len(matches)))
    fingerprint = next(iter(matches))
    root = Path(__file__).resolve().parents[1]
    build = root / "build"
    if build.is_symlink():
        raise GuardError("Refusing a redirected signing probe directory")
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="helper-signing-probe-", dir=build) as directory:
        probe = Path(directory) / "owned-signing-probe"
        shutil.copyfile("/usr/bin/true", probe)
        command = ["codesign", "--force", "--options", "runtime", "--timestamp=none",
                   "--sign", fingerprint, "--identifier", "com.sysinternals.procexpmac.signing-probe"]
        if keychain:
            command += ["--keychain", keychain]
        checked(command + [str(probe)])
        checked(["codesign", "--verify", "--strict", "--all-architectures", str(probe)])
        certificates = str(Path(directory) / "certificate-")
        checked(["codesign", "--display", "--extract-certificates=" + certificates, str(probe)])
        leaf = Path(certificates + "0")
        if not leaf.is_file() or hashlib.sha1(leaf.read_bytes()).hexdigest().upper() != fingerprint:
            raise GuardError("Actual signing probe leaf does not match the selected identity")
    return {"signingReady": True, "certificateSHA1": fingerprint}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "remove", "identity", "status", "signing"))
    args = parser.parse_args()
    try:
        if args.action == "status":
            flavor = os.environ.get("PROCEXP_LOCAL_FLAVOR", "development")
            if flavor not in FLAVORS:
                raise GuardError("Invalid helper flavor")
            label = FLAVORS[flavor][1] + ".helper"
            print(json.dumps({"helper": label, "registered": service_registered(label)}))
        elif args.action == "signing":
            print(json.dumps(signing_preflight(os.environ)))
        elif args.action == "identity":
            authorize(args.action, os.environ)
            print(json.dumps({"status": "approved-prerequisites", "action": args.action}))
        else:
            print(json.dumps(dict(destination(args.action, os.environ), status="approved-prerequisites")))
        return 0
    except (GuardError, OSError, ValueError, KeyError, TypeError, ExpatError,
            subprocess.SubprocessError) as error:
        print("Helper lifecycle blocked: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
