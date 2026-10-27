#!/usr/bin/env python3
"""Exercise real macOS signing with a disposable identity and changed binaries.

Run on a normal macOS host with Command Line Tools and access to its Keychain
services. This test never changes certificate trust or the default keychain,
launches neither fixture, and makes no claim about privacy permission retention.
"""

import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SECURITY = "/usr/bin/security"
OPENSSL = "/usr/bin/openssl"
CODESIGN = "/usr/bin/codesign"
CLANG = "/usr/bin/clang"
COMPONENTS = (
    ("application", "", "io.github.ytwsy.oneshot"),
    ("capture", "Contents/Helpers/OneShot Capture.app", "io.github.ytwsy.oneshot.capture-probe"),
    ("mcp", "Contents/Helpers/oneshot-mcp", "io.github.ytwsy.oneshot.mcp"),
)


class IntegrationFailure(Exception):
    """A fixed, non-secret failure message suitable for test logs."""


def require(condition, message):
    if not condition:
        raise IntegrationFailure(message)


def command(arguments, environment, label, timeout=45):
    # In particular, never print import/cleanup diagnostics, command arguments,
    # environment variables, or a CalledProcessError containing key passwords.
    try:
        process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=environment, text=True, start_new_session=True)
    except OSError:
        raise IntegrationFailure(label + " could not run") from None
    try:
        output, _ = process.communicate(timeout=timeout)
    except BaseException as error:
        # The zsh helpers launch Python, which launches security. Stop that whole
        # group before cleanup so a timed-out import cannot resume behind it.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        raise IntegrationFailure(label + " could not complete") from None
    if process.returncode:
        raise IntegrationFailure(label + " failed (captured tool output omitted)")
    return output


def keychain_state(environment):
    listed = command([SECURITY, "list-keychains", "-d", "user"],
                     environment, "keychain search-list inspection")
    try:
        paths = shlex.split(listed)
    except ValueError:
        raise IntegrationFailure("keychain search-list inspection could not be parsed") from None
    default = command([SECURITY, "default-keychain", "-d", "user"],
                      environment, "default-keychain inspection").strip()
    return paths, default


def create_identity(work, environment):
    configuration = work / "certificate.cnf"
    configuration.write_text(
        "[req]\nprompt=no\ndistinguished_name=name\nx509_extensions=extensions\n"
        "[name]\nCN=OneShot Disposable Signing Integration Identity\n"
        "[extensions]\nbasicConstraints=critical,CA:true\n"
        "keyUsage=critical,digitalSignature,keyCertSign\n"
        "extendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n",
        encoding="utf-8")
    private_key = work / "private-key.pem"
    certificate = work / "certificate.pem"
    der = work / "certificate.der"
    p12 = work / "identity.p12"
    command([OPENSSL, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
             "-keyout", str(private_key), "-out", str(certificate), "-config", str(configuration)],
            environment, "temporary certificate generation")
    command([OPENSSL, "x509", "-in", str(certificate), "-outform", "DER", "-out", str(der)],
            environment, "public certificate conversion")
    fingerprint = hashlib.sha1(der.read_bytes()).hexdigest().upper()
    password = secrets.token_urlsafe(48)
    export_environment = dict(environment, ONESHOT_INTEGRATION_P12_PASSWORD=password)
    command([OPENSSL, "pkcs12", "-export", "-inkey", str(private_key), "-in", str(certificate),
             "-out", str(p12), "-passout", "env:ONESHOT_INTEGRATION_P12_PASSWORD"],
            export_environment, "temporary P12 export")
    return fingerprint, password, p12


def create_app(work, generation, environment):
    # Keep the binary outside the similarly named app directory: default macOS
    # volumes are case-insensitive.
    app = work / ("generation-" + str(generation)) / "OneShot.app"
    capture = app / COMPONENTS[1][1]
    for bundle, identifier, executable in (
        (app, COMPONENTS[0][2], "oneshot-editor"),
        (capture, COMPONENTS[1][2], "oneshot"),
    ):
        (bundle / "Contents/MacOS").mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
            "CFBundlePackageType": "APPL", "CFBundleName": "OneShot Signing Fixture",
            "CFBundleVersion": str(generation), "CFBundleShortVersionString": "0.0." + str(generation),
            "LSMinimumSystemVersion": "14.0",
        }))
    source = work / ("fixture-" + str(generation) + ".c")
    binary = work / ("fixture-binary-" + str(generation))
    source.write_text("int main(void) { return " + str(generation) + "; }\n", encoding="utf-8")
    command([CLANG, "-arch", "arm64", "-mmacosx-version-min=14.0", str(source), "-o", str(binary)],
            environment, "arm64 fixture compilation")
    for target in (app / "Contents/MacOS/oneshot-editor", capture / "Contents/MacOS/oneshot",
                   app / COMPONENTS[2][1]):
        shutil.copy2(binary, target)
    return app


def sign_app(app, fingerprint, keychain, environment):
    # Seal nested code before the containing application.
    for _, relative, identifier in reversed(COMPONENTS):
        target = app / relative if relative else app
        requirement = '=designated => identifier "' + identifier + '" and certificate leaf = H"' + fingerprint + '"'
        command([CODESIGN, "--force", "--sign", fingerprint, "--keychain", str(keychain),
                 "--options", "runtime", "--timestamp=none", "--requirements", requirement,
                 "--identifier", identifier, str(target)], environment, "fixture code signing")


def verify_generations(apps):
    sys.dont_write_bytecode = True
    specification = importlib.util.spec_from_file_location("oneshot_signing_integration", ROOT / "packaging/signing.py")
    signing = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(signing)
    try:
        reports = [signing.verify_app(app, "self-signed") for app in apps]
        compared = signing.compare_apps(apps[0], apps[1])
    except (ValueError, OSError, subprocess.SubprocessError):
        raise IntegrationFailure("real signature verification failed (captured tool output omitted)") from None
    require(compared["identityCompatible"], "changed fixtures have incompatible designated requirements")
    old = {component["role"]: component for component in reports[0]["components"]}
    new = {component["role"]: component for component in reports[1]["components"]}
    require(set(old) == set(new) == {role for role, _, _ in COMPONENTS}, "verification omitted a release component")
    require(len(compared["components"]) == len(old) and
            {component["role"] for component in compared["components"]} == set(old),
            "requirement comparison omitted a release component")
    for role in old:
        require(old[role]["cdhash"] != new[role]["cdhash"], "a fixture code hash did not change")
        require(old[role]["designatedRequirement"] == new[role]["designatedRequirement"],
                "a certificate-pinned designated requirement changed")
    require(all(component["candidateSatisfiesPrevious"] and component["previousSatisfiesCandidate"]
                for component in compared["components"]), "a component failed mutual requirement checks")


def main():
    if sys.platform != "darwin":
        print("Signing integration requires a normal macOS host with Keychain services.", file=sys.stderr)
        return 1
    environment = {name: value for name, value in os.environ.items()
                   if not name.startswith("ONESHOT_SIGNING_") and name not in ("GITHUB_ENV", "GITHUB_OUTPUT")}
    environment.update(LC_ALL="C", LANG="C")
    work = None
    signing_directory = None
    original_paths = original_default = None
    failure = None
    old_umask = os.umask(0o077)
    try:
        original_paths, original_default = keychain_state(environment)
        parent = Path(environment.get("RUNNER_TEMP", "/private/tmp")).resolve(strict=True)
        work = Path(tempfile.mkdtemp(prefix="oneshot-signing-integration-", dir=str(parent)))
        signing_directory = work / "oneshot-signing-keychain"
        fingerprint, password, p12 = create_identity(work, environment)
        import_environment = dict(environment, ONESHOT_SIGNING_MODE="self-signed",
                                  ONESHOT_SIGNING_IDENTITY=fingerprint,
                                  ONESHOT_SIGNING_CERTIFICATE_PASSWORD=password,
                                  ONESHOT_SIGNING_CERTIFICATE_BASE64=base64.b64encode(p12.read_bytes()).decode("ascii"))
        command(["/bin/zsh", str(ROOT / "scripts/import-signing-identity.sh"),
                 "--directory", str(signing_directory)], import_environment, "temporary identity import")
        selected = json.loads((signing_directory / "signing-environment.json").read_text(encoding="utf-8"))
        keychain = signing_directory / "identity.keychain-db"
        require(selected == {"ONESHOT_SIGNING_IDENTITY": fingerprint, "ONESHOT_SIGNING_KEYCHAIN": str(keychain)},
                "identity import selected an unexpected keychain or certificate")
        p12.unlink()
        (work / "private-key.pem").unlink()
        current_paths, current_default = keychain_state(environment)
        require(str(keychain) in current_paths, "imported keychain is absent from the search list")
        require(current_default == original_default, "identity import changed the default keychain")
        require([path for path in current_paths if path in original_paths] == original_paths,
                "identity import lost or reordered original keychains")
        apps = [create_app(work, generation, environment) for generation in (1, 2)]
        for app in apps:
            sign_app(app, fingerprint, keychain, environment)
        verify_generations(apps)
    except IntegrationFailure as error:
        failure = str(error)
    except (OSError, ValueError, KeyError, TypeError):
        failure = "local fixture setup or metadata inspection failed (details omitted)"
    finally:
        before_cleanup_paths = None
        try:
            if original_paths is not None:
                before_cleanup_paths, _ = keychain_state(environment)
        except IntegrationFailure as error:
            failure = str(error)
        try:
            if signing_directory is not None:
                command(["/bin/zsh", str(ROOT / "scripts/cleanup-signing-identity.sh"),
                         "--directory", str(signing_directory)], environment, "temporary identity cleanup")
            if original_paths is not None:
                remaining, default = keychain_state(environment)
                require(default == original_default, "default keychain changed during integration")
                # Permit other processes to append keychains while this runs.
                # Cleanup must remove only our entry, never replay an old list.
                require([path for path in remaining if path in original_paths] == original_paths,
                        "original keychains were lost or reordered during integration")
                if signing_directory is not None:
                    own_keychain = str(signing_directory / "identity.keychain-db")
                    require(own_keychain not in remaining,
                            "temporary keychain remains in the search list")
                    if before_cleanup_paths is not None:
                        retained = [path for path in before_cleanup_paths if path != own_keychain]
                        require([path for path in remaining if path in retained] == retained,
                                "cleanup lost another process's keychain search-list entry")
        except IntegrationFailure as error:
            failure = str(error)
        finally:
            if work is not None:
                # Remove plaintext key material even when Keychain services fail.
                for name in ("private-key.pem", "identity.p12"):
                    try:
                        (work / name).unlink(missing_ok=True)
                    except OSError:
                        failure = "plaintext temporary key cleanup failed"
                if signing_directory is None or not signing_directory.exists():
                    try:
                        shutil.rmtree(work)
                    except OSError:
                        failure = "temporary fixture directory cleanup failed"
                else:
                    failure = "temporary keychain cleanup needs retry; retained private ownership marker at " + str(signing_directory)
            os.umask(old_umask)
    if failure:
        print("Signing integration failed: " + failure, file=sys.stderr)
        return 1
    print("Signing integration passed: two arm64 generations, three changed code hashes, stable certificate-pinned requirements, mutual identity compatibility; temporary identity removed.")
    print("Certificate trust and the default keychain were unchanged. Privacy permission retention was not tested.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
