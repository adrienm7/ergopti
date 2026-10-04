# tools/diagnostics/macos_brew_archive_acceptance.py
"""Exercise real isolated Homebrew archive installation without touching host state.

The native fixture requires existing Brew/Ruby dependencies. It neither installs
those dependencies nor modifies a tap, Keychain, application or cache outside
its owned directory. A native sandbox admission precedes any Brew command.
Checksums are Brew's admission boundary; signing identity belongs to the archive
producer/upstream publication gate, not to Brew's generated cask.
"""

import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import plistlib
import shutil
import shlex
import signal
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from urllib.parse import urlsplit

from macos_owned_process import NativeProcessGroups, OwnedProcessInterrupted, acquire_owned


BUNDLE = "ErgoptiPlus.app"
RESOURCE = "Independent Unicode bytes: café 😀\n".encode()
VERSIONS = ("71.36.1", "71.36.2", "71.36.3", "71.36.4")


class AppleEventBoundaryError(RuntimeError):
    """Retain failed private native boundary inputs for diagnosis after child retirement."""


class AdmissionError(RuntimeError):
    """A required observation failed; no fallback or skipped success exists."""


def require(condition, message):
    """Reject absent or ambiguous acceptance evidence."""
    if not condition:
        raise AdmissionError(message)


def digest(path):
    """Hash artifact bytes without exposing signing or TLS key material."""
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def owned_path(root, path):
    """Reject a resolved escape, including symlinks to an existing host tree."""
    resolved = Path(path).resolve(strict=True)
    require(resolved == root or root in resolved.parents, "Observed path escapes owned fixture")
    return resolved


def tree_receipt(root):
    """Record independent bytes, executable modes and symlinks without following them."""
    root = Path(root)
    if not root.exists():
        return None
    receipt = {}
    for path in sorted(root.rglob("*")):
        entry = path.lstat()
        relative = str(path.relative_to(root))
        if stat.S_ISLNK(entry.st_mode):
            receipt[relative] = {"link": os.readlink(path)}
        elif stat.S_ISREG(entry.st_mode):
            receipt[relative] = {"sha256": digest(path), "mode": stat.S_IMODE(entry.st_mode)}
        elif stat.S_ISDIR(entry.st_mode):
            receipt[relative] = {"directory": True}
        else:
            raise AdmissionError("Unexpected special file in observed tree")
    return receipt


def private_environment(root):
    """Do not inherit credentials, proxy configuration, Ruby injection or Brew overrides."""
    environment = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
        "HOME": str(root / "home"),
        "USER": os.environ.get("USER", str(os.getuid())),
        "LOGNAME": os.environ.get("LOGNAME", str(os.getuid())),
        "TMPDIR": str(root / "temp"),
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "SWIFT_BACKTRACE": "enable=no",
        "HOMEBREW_CACHE": str(root / "cache"),
        "HOMEBREW_TEMP": str(root / "temp"),
        "HOMEBREW_LOGS": str(root / "logs"),
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_ANALYTICS": "1",
        "HOMEBREW_NO_INSTALL_FROM_API": "1",
        "HOMEBREW_NO_ENV_HINTS": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1",
        "HOMEBREW_NO_BOOTSNAP": "1",
        "HOMEBREW_CURLRC": str(root / "curlrc"),
        "HOMEBREW_CASK_OPTS": shlex.quote("--appdir=" + str(root / "apps")),
        "HOMEBREW_DOWNLOAD_CONCURRENCY": "2",
        "HOMEBREW_CURL_RETRIES": "0",
        "HOMEBREW_CURL_MAX_TIME": "60",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
    }
    return environment


def sandbox_profile(root):
    """Allow reads but contain every descendant write and network connection."""
    escaped = json.dumps(str(root))
    return "\n".join(
        [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            f'(allow file-write* (subpath {escaped}) (literal "/dev/null"))',
            "(deny network-outbound)",
            "(deny appleevent-send)",
            '(allow network-outbound (remote ip "127.0.0.1:*"))',
            "",
        ]
    )


class Children:
    """Own process groups and settle descendants before removing their inputs."""

    def __init__(self, root):
        self.root = root
        self.environment = private_environment(root)
        self.active = []
        self.debt = []
        self.sequence = 0
        self.external_owned = []
        self.servers = []
        self.native_groups = NativeProcessGroups()
        self.groups = {}
        self.captures = {}

    def record_debt(self, entry):
        """Repeated retirement attempts keep one diagnostic per exact owned resource."""
        if entry not in self.debt:
            self.debt.append(entry)

    def acknowledge_group_absence(self, process):
        """Clear only exact process-group debt after physical absence was observed."""
        self.debt = [
            entry
            for entry in self.debt
            if not (
                entry.get("kind") in ("process-group", "process-retirement-error")
                and entry.get("pid") == process.pid
            )
        ]

    def settle(self, process):
        """Retire only a reserved leader's inherited PGID; never signal after reap."""
        require(process in self.groups, "Unacquired process cannot authorize group retirement")
        if self.groups[process].settle():
            self.acknowledge_group_absence(process)
            return
        if not any(entry.get("pid") == process.pid for entry in self.debt):
            self.record_debt({"kind": "process-group", "pid": process.pid})

    def start(self, arguments, *, confined=False):
        """Acquire an asynchronous native child and every input/capture needed to retire it."""
        self.sequence += 1
        output = self.root / f"child-{self.sequence}.stdout"
        errors = self.root / f"child-{self.sequence}.stderr"
        if confined:
            arguments = ["/usr/bin/sandbox-exec", "-f", str(self.root / "sandbox.sb"), *arguments]
        with output.open("wb") as out, errors.open("wb") as err:

            def register(group):
                process = group.process
                self.active.append(process)
                self.groups[process] = group
                self.captures[process] = (output, errors)

            group = acquire_owned(
                arguments,
                self.native_groups,
                register,
                cwd=self.root,
                env=self.environment,
                stdout=out,
                stderr=err,
            )
        return group.process

    def run(self, arguments, *, check=True, confined=False, timeout=180):
        """Capture into owned files, cap diagnostics, preserve exact exit status."""
        process = self.start(arguments, confined=confined)
        output, errors = self.captures[process]
        failure = None
        try:
            self.groups[process].wait_for_exit(timeout)
        except subprocess.TimeoutExpired:
            failure = AdmissionError("Owned native command exceeded deadline")
        except BaseException as error:
            failure = error
        finally:
            try:
                self.settle(process)
            except Exception:
                self.record_debt({"kind": "process-retirement-error", "pid": process.pid})
            if not any(entry.get("pid") == process.pid for entry in self.debt):
                self.active.remove(process)
        if failure is not None:
            raise failure
        require(
            not any(entry.get("pid") == process.pid for entry in self.debt),
            "Owned native command left process-group retirement debt",
        )
        stdout = output.read_bytes()
        stderr = errors.read_bytes()
        require(
            len(stdout) <= 1024 * 1024 and len(stderr) <= 1024 * 1024,
            "Owned native output exceeded evidence bound",
        )
        result = subprocess.CompletedProcess(
            arguments, process.returncode, stdout.decode("utf-8"), stderr.decode("utf-8")
        )
        if check:
            require(
                result.returncode == 0,
                f"Owned {Path(arguments[-1]).name if confined else Path(arguments[0]).name} failed "
                f"with exit {result.returncode}: {result.stderr[:2048]!r}",
            )
        return result

    def retire(self):
        """Retry remaining exact children; unresolved debt preserves the fixture."""
        for server in list(self.servers):
            try:
                if server.close():
                    self.debt = [
                        entry
                        for entry in self.debt
                        if not (
                            entry.get("kind") in ("server-thread", "server-retirement-error")
                            and entry.get("server") == id(server)
                        )
                    ]
                    if server in self.servers:
                        self.servers.remove(server)
                else:
                    self.record_debt({"kind": "server-thread", "server": id(server)})
            except Exception:
                self.record_debt({"kind": "server-retirement-error", "server": id(server)})
        for process in list(self.active):
            try:
                self.settle(process)
            except Exception:
                self.record_debt({"kind": "process-retirement-error", "pid": process.pid})
            if not any(entry.get("pid") == process.pid for entry in self.debt):
                self.active.remove(process)
        if not self.active and not any(
            entry.get("kind") != "external-canary" for entry in self.debt
        ):
            for directory in list(self.external_owned):
                try:
                    directory.rmdir()
                except FileNotFoundError:
                    pass
                except OSError:
                    self.record_debt({"kind": "external-canary", "path": str(directory)})
                    continue
                self.external_owned.remove(directory)
                self.debt = [
                    entry
                    for entry in self.debt
                    if not (
                        entry.get("kind") == "external-canary"
                        and entry.get("path") == str(directory)
                    )
                ]
        return not self.active and not self.debt


class Assets:
    """Serve only explicit immutable origin paths from a private trusted TLS endpoint."""

    def __init__(self, root, children):
        self.paths = {}
        self.requests = []
        self.failures = []
        self.root = root
        config = root / "tls.cnf"
        config.write_text(
            "[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n"
            "[dn]\nCN=github.com\n[ext]\nsubjectAltName=DNS:github.com\n"
            "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,digitalSignature,keyEncipherment\n",
            encoding="utf-8",
            newline="\n",
        )
        children.run(
            [
                "/usr/bin/openssl",
                "req",
                "-new",
                "-x509",
                "-nodes",
                "-newkey",
                "rsa:2048",
                "-days",
                "1",
                "-config",
                str(config),
                "-keyout",
                str(root / "tls.key"),
                "-out",
                str(root / "tls.pem"),
            ]
        )
        (root / "tls.key").chmod(0o600)
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_HEAD(self):
                """Real Brew queries origin sizes before deciding whether a cache is fresh."""
                self.respond(head=True)

            def do_GET(self):
                """Only actual body acquisitions count toward native archive evidence."""
                self.respond(head=False)

            def respond(self, *, head):
                """Unknown hosts or paths cannot become public network requests."""
                name = urlsplit(self.path).path
                if self.headers.get("Host") != "github.com" or name not in owner.paths:
                    owner.failures.append("unknown-origin")
                    self.send_error(404)
                    return
                if not head:
                    owner.requests.append(name)
                payload = owner.paths[name].read_bytes()
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                if not head:
                    self.wfile.write(payload)

            def log_message(self, *_arguments):
                """Never expose HTTP headers, environment or TLS key payloads."""

        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(root / "tls.pem", root / "tls.key")

        class BoundedTLSServer(HTTPServer):
            def get_request(self):
                connection, address = self.socket.accept()
                connection.settimeout(5)
                try:
                    return context.wrap_socket(connection, server_side=True), address
                except Exception:
                    connection.close()
                    raise

        self.server = BoundedTLSServer(("127.0.0.1", 0), Handler)
        self.server.timeout = 0.1
        self.thread = None
        self.closed = False
        self.children = children
        children.servers.append(self)
        try:
            self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
            self.thread.start()
        except Exception:
            self.close()
            raise
        port = self.server.server_address[1]
        try:
            (root / "curlrc").write_text(
                f'connect-to = "github.com:443:127.0.0.1:{port}"\n'
                f'cacert = "{root / "tls.pem"}"\nproxy = ""\nnoproxy = "*"\n',
                encoding="utf-8",
                newline="\n",
            )
        except Exception:
            self.close()
            raise

    def add(self, version, archive):
        """Keep the generator's HTTPS URL and digest unchanged."""
        name = f"/adrienm7/ergopti/releases/download/v{version}/{archive.name}"
        require(name not in self.paths, "Origin path already acquired")
        self.paths[name] = archive
        return name

    def close(self):
        """A live server retains the fixture, even when the primary case failed."""
        if self.closed:
            return True
        if self.thread is not None and self.thread.is_alive():
            self.server.shutdown()
        self.server.server_close()
        if self.thread is not None and self.thread.ident is not None:
            self.thread.join(timeout=5)
        self.closed = self.thread is None or not self.thread.is_alive()
        if self.closed:
            self.children.debt = [
                entry
                for entry in self.children.debt
                if not (
                    entry.get("kind") in ("server-thread", "server-retirement-error")
                    and entry.get("server") == id(self)
                )
            ]
            if self in self.children.servers:
                self.children.servers.remove(self)
        return self.closed


def refuse_foreign_running_apps():
    """Generated cask hooks must not acquire or quit an unrelated running app."""
    running = subprocess.run(
        ["/usr/bin/pgrep", "-f", "/ErgoptiPlus.app/Contents/"], capture_output=True, timeout=10
    )
    require(
        running.returncode == 1 and not running.stdout and not running.stderr,
        "Foreign running Ergopti app prevents generated uninstall/quit hooks",
    )
    running_ids = subprocess.run(
        [
            "/usr/bin/osascript",
            "-l",
            "JavaScript",
            "-e",
            'ObjC.import("AppKit"); const apps = $.NSWorkspace.sharedWorkspace.runningApplications; '
            "let count = 0; for(let i=0; i<apps.count; i++) { "
            "const identifier = ObjC.unwrap(apps.objectAtIndex(i).bundleIdentifier); "
            'if(identifier === "com.ergoptiplus.app" || identifier === "com.ergoptiplus.app.hammerspoon") count++; } '
            "String(count);",
        ],
        capture_output=True,
        text=True,
        timeout=10,
    )
    require(
        running_ids.returncode == 0 and running_ids.stdout == "0\n" and not running_ids.stderr,
        "Foreign running bundle identity prevents generated quit hooks",
    )


def native_preconditions():
    """Refuse unsupported hosts and foreign running apps before creating a fixture."""
    require(sys.platform == "darwin", "Real Homebrew archive acceptance requires macOS")
    for tool in (
        "/usr/bin/sandbox-exec",
        "/usr/bin/codesign",
        "/usr/bin/openssl",
        "/usr/bin/curl",
        "/usr/bin/git",
        "/usr/bin/pgrep",
        "/usr/bin/osascript",
        "/usr/bin/xattr",
        "/usr/bin/tar",
        "/usr/bin/xcrun",
    ):
        require(
            Path(tool).is_file() and os.access(tool, os.X_OK),
            "Required existing native tool is missing",
        )
    require(shutil.which("node") is not None, "Existing Node runtime is required")
    brew = shutil.which("brew")
    require(
        brew is not None, "Existing Homebrew CLI is required; this fixture never installs tools"
    )
    refuse_foreign_running_apps()
    source = Path(brew).resolve(strict=True)
    require(
        source.name == "brew" and source.parent.name == "bin", "Unsupported actual Brew location"
    )
    host = source.parent.parent
    require((host / "Library/Homebrew/brew.sh").is_file(), "Actual Brew library is missing")
    require(
        not Path("/etc/homebrew/brew.env").exists(),
        "System Brew environment override prevents private environment admission",
    )
    vendor = host / "Library/Homebrew/vendor"
    require(
        (vendor / "portable-ruby-version").is_file(),
        "Existing Brew Ruby version declaration is absent",
    )
    ruby_current = vendor / "portable-ruby/current"
    require(
        ruby_current.is_symlink() and (ruby_current / "bin/ruby").is_file(),
        "Existing portable Ruby is required; dependency installation is forbidden",
    )
    require(
        os.readlink(ruby_current) == (vendor / "portable-ruby-version").read_text().strip(),
        "Existing portable Ruby requires upgrade; this fixture never upgrades tools",
    )
    return source, host, Path(brew).absolute().parent.parent.resolve(strict=True)


def admit_sandbox(children):
    """Prove native containment before exposing the read-only Brew library."""
    root = children.root
    (root / "sandbox.sb").write_text(sandbox_profile(root), encoding="utf-8", newline="\n")
    children.run(["/usr/bin/touch", str(root / "sandbox-owned")], confined=True)
    # A nonexistent unique sibling is sufficient to qualify write denial without
    # ever asking the tool to touch a host application or credential path.
    outside = root.parent / (root.name + "-forbidden")
    require(not outside.exists(), "Sandbox refusal probe path is already owned elsewhere")
    result = children.run(["/usr/bin/touch", str(outside)], confined=True, check=False)
    if outside.exists():
        children.debt.append({"kind": "sandbox-escape", "path": str(outside)})
    require(
        result.returncode != 0 and not outside.exists(),
        "Native file-write containment was not enforced",
    )
    canary = root.parent / (root.name + "-sandbox-canary")
    canary.mkdir(mode=0o700)
    children.external_owned.append(canary)
    (root / "sandbox-symlink").symlink_to(canary, target_is_directory=True)
    result = children.run(
        ["/usr/bin/touch", str(root / "sandbox-symlink/forbidden")], confined=True, check=False
    )
    if result.returncode == 0 or any(canary.iterdir()):
        children.debt.append({"kind": "sandbox-symlink-escape", "path": str(canary)})
        raise AdmissionError("Native sandbox allowed writes through a read-only external reference")
    canary.rmdir()
    children.external_owned.remove(canary)
    network_probe = children.root / "sandbox-network.py"
    network_probe.write_text(
        "import errno, socket, sys\n"
        "connection = socket.socket()\nconnection.settimeout(2)\n"
        "try:\n    connection.connect(('192.0.2.1', 443))\n"
        "except OSError as failure:\n    sys.exit(73 if failure.errno == errno.EPERM else 74)\n"
        "sys.exit(75)\n",
        encoding="utf-8",
        newline="\n",
    )
    result = children.run(
        [sys.executable, "-I", str(network_probe)], confined=True, check=False, timeout=10
    )
    require(result.returncode == 73, "Native outbound containment did not prove EPERM refusal")


def admit_appleevent_boundary(children, repository):
    """Retain a failed native admission fixture without extending process ownership."""
    try:
        return _admit_appleevent_boundary(children, repository)
    except Exception as error:
        raise AppleEventBoundaryError(
            "Native AppleEvent boundary unavailable: " + str(error)
        ) from error


def _admit_appleevent_boundary(children, repository):
    """Require two real owned deliveries before admitting the full policy's refusal."""
    root = children.root
    nonce = str(uuid.uuid4())
    executables = {}
    for role in ("receiver", "sender"):
        app = root / ("OwnedAppleEvent-" + role + ".app")
        executable = app / "Contents/MacOS" / role
        executable.parent.mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": "com.ergopti.private.appleevent." + role + "." + nonce,
                    "CFBundleName": "Owned AppleEvent sandbox admission",
                    "CFBundleExecutable": role,
                    "CFBundlePackageType": "APPL",
                    "LSUIElement": True,
                    "NSAppleEventsUsageDescription": "Private native sandbox delivery admission.",
                }
            )
        )
        command = [
            "/usr/bin/xcrun",
            "clang",
            "-std=c11",
            "-O2",
            "-framework",
            "ApplicationServices",
        ]
        if role == "receiver":
            command += ["-framework", "Carbon"]
        command += [
            str(repository / ("tools/diagnostics/native_appleevent_probe_" + role + ".c")),
            "-o",
            str(executable),
        ]
        children.run(command, confined=True)
        children.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], confined=True)
        children.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], confined=True
        )
        executables[role] = executable
    ready = root / "appleevent-ready"
    marker = root / "appleevent-delivered"
    receiver = children.start([str(executables["receiver"]), str(ready), str(marker), nonce])
    group = children.groups[receiver]

    def same_live_receiver():
        require(
            group.observe_exit() is None, "The exact owned AppleEvent receiver is no longer live"
        )

    deadline = time.monotonic() + 10
    expected_ready = f"{receiver.pid}\n{nonce}\n".encode()
    while True:
        same_live_receiver()
        if ready.exists() or ready.is_symlink():
            require(
                ready.is_file() and not ready.is_symlink(),
                "Owned AppleEvent readiness is not an ordinary private file",
            )
            actual_ready = ready.read_bytes()
            require(
                expected_ready.startswith(actual_ready),
                "Owned AppleEvent readiness identity or nonce differs",
            )
            if actual_ready == expected_ready:
                break
        require(
            time.monotonic() < deadline, "Owned AppleEvent receiver did not acknowledge readiness"
        )
        time.sleep(0.02)
    same_live_receiver()
    sender = [str(executables["sender"]), str(receiver.pid), nonce]
    positive = children.run([*sender, "success"])
    require(
        positive.stdout == "native_appleevent_status=0\n" and not positive.stderr,
        "Owned unconfined AppleEvent route was not independently admitted",
    )

    def marker_bytes(index):
        path = Path(str(marker) + "." + str(index))
        require(
            path.is_file() and not path.is_symlink() and owned_path(root, path) == path,
            "Owned AppleEvent marker is not an ordinary private file",
        )
        value = path.read_bytes()
        require(value == nonce.encode(), "Owned AppleEvent marker nonce differs")
        return value

    first = marker_bytes(1)
    require(
        not Path(str(marker) + ".2").exists(), "Unexpected delivery preceded deny-removal control"
    )
    same_live_receiver()
    policy = (root / "sandbox.sb").read_text(encoding="utf-8")
    deny = "(deny appleevent-send)\n"
    require(
        policy.count(deny) == 1, "Full native policy does not contain exactly one AppleEvent denial"
    )
    removed = root / "sandbox-appleevent-positive.sb"
    removed.write_text(policy.replace(deny, ""), encoding="utf-8", newline="\n")
    positive = children.run(["/usr/bin/sandbox-exec", "-f", str(removed), *sender, "success"])
    require(
        positive.stdout == "native_appleevent_status=0\n" and not positive.stderr,
        "Same-policy deny-removal AppleEvent route was not independently admitted",
    )
    second = marker_bytes(2)
    require(marker_bytes(1) == first, "Deny-removal delivery altered the first positive marker")
    same_live_receiver()
    refused = children.run([*sender, "denied"], confined=True)
    require(
        refused.stdout in ("native_appleevent_status=-1742\n", "native_appleevent_status=-1743\n")
        and not refused.stderr,
        "Full native policy did not report a documented AppleEvent refusal",
    )
    same_live_receiver()
    require(
        marker_bytes(1) == first
        and marker_bytes(2) == second
        and not Path(str(marker) + ".3").exists(),
        "Denied AppleEvent altered actual delivery state",
    )
    children.settle(receiver)
    require(group.reaped, "Owned AppleEvent receiver retirement remains incomplete")
    children.active.remove(receiver)
    return {
        "unconfined_status": 0,
        "deny_removal_status": 0,
        "denied_status": int(refused.stdout.split("=")[1]),
        "positive_markers_sha256": [
            digest(Path(str(marker) + ".1")),
            digest(Path(str(marker) + ".2")),
        ],
        "receiver_retired": True,
    }


def admit_brew(children, source, host):
    """Copy only the actual entrypoint and own all mutable Brew namespaces."""
    root = children.root
    prefix = root / "prefix"
    children.run(
        [
            "/usr/bin/git",
            "clone",
            "--shared",
            "--no-checkout",
            "--no-hardlinks",
            str(host),
            str(prefix),
        ],
        confined=True,
    )
    for relative in (
        "bin",
        "Library",
        "Library/Taps/ergopti/homebrew-acceptance",
        "Caskroom",
        "Cellar",
    ):
        (prefix / relative).mkdir(parents=True, exist_ok=True)
    copied = prefix / "bin/brew"
    shutil.copy2(source, copied)
    require(
        not copied.is_symlink() and digest(copied) == digest(source),
        "Actual Brew entrypoint changed",
    )
    (prefix / "Library/Homebrew").symlink_to(host / "Library/Homebrew", target_is_directory=True)
    children.environment["PATH"] = str(prefix / "bin") + os.pathsep + children.environment["PATH"]
    probe = root / "brew-paths.rb"
    probe.write_text(
        'require "json"\nrequire "tap"\nrequire "cask/config"\nrequire "cask/caskroom"\n'
        "puts JSON.generate({prefix: HOMEBREW_PREFIX.to_s, repository: HOMEBREW_REPOSITORY.to_s, "
        "library: HOMEBREW_LIBRARY.to_s, caskroom: Cask::Caskroom.path.to_s, appdir: Cask::Config.new.appdir.to_s, "
        "cache: HOMEBREW_CACHE.to_s, temp: HOMEBREW_TEMP.to_s, home: Dir.home, "
        'tap: Tap.fetch("ergopti/acceptance").path.to_s, ruby: RbConfig.ruby, download_concurrency: Homebrew::EnvConfig.download_concurrency})\n',
        encoding="utf-8",
        newline="\n",
    )
    paths = json.loads(children.run([str(copied), "ruby", str(probe)], confined=True).stdout)
    expected = {
        "prefix": prefix,
        "repository": prefix,
        "library": prefix / "Library",
        "caskroom": prefix / "Caskroom",
        "appdir": root / "apps",
        "cache": root / "cache",
        "temp": root / "temp",
        "home": root / "home",
        "tap": prefix / "Library/Taps/ergopti/homebrew-acceptance",
    }
    require(
        paths.get("download_concurrency") == 2,
        "Actual Brew checksum diagnostic concurrency is unsupported",
    )
    for key, value in expected.items():
        require(
            paths.get(key) == str(value) and owned_path(root, value) == value,
            f"Actual Brew {key} is not exclusively owned",
        )
    require(Path(paths.get("ruby", "")).is_file(), "Brew did not admit an existing Ruby runtime")
    require(
        children.run([str(copied), "--prefix"], confined=True).stdout == str(prefix) + "\n",
        "Actual copied Brew --prefix disagrees with its Ruby namespace",
    )
    version = children.run([str(copied), "--version"], confined=True).stdout.strip()
    require(
        version.startswith("Homebrew ") and len(version) > len("Homebrew "),
        "Actual Brew version is absent",
    )
    children.run(["/usr/bin/git", "-C", str(expected["tap"]), "init"], confined=True)
    children.run(
        ["/usr/bin/git", "-C", str(expected["tap"]), "config", "user.name", "Owned acceptance"],
        confined=True,
    )
    children.run(
        [
            "/usr/bin/git",
            "-C",
            str(expected["tap"]),
            "config",
            "user.email",
            "acceptance@example.invalid",
        ],
        confined=True,
    )
    return (
        copied,
        expected["tap"],
        {"version": version, "entrypoint_sha256": digest(source), "paths": paths},
    )


def invoke_brew(children, command, *, check=True):
    """Recheck native process absence immediately before every generated hook."""
    refuse_foreign_running_apps()
    return children.run(command, confined=True, check=check)


def signed_bundle(children, version):
    """Use actual codesign on independently authored private fixture expectations."""
    root = children.root
    app = root / ("source-" + version) / BUNDLE
    executable = app / "Contents/MacOS/OwnedFixture"
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True)
    executable.parent.mkdir(parents=True)
    shutil.copyfile("/usr/bin/true", executable)
    executable.chmod(0o751)
    (resources / "données.txt").write_bytes(RESOURCE)
    (resources / "owned-link").symlink_to("données.txt")
    (app / "Contents/Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleIdentifier": "com.ergopti.brew-private-fixture",
                "CFBundleName": "Owned Brew acceptance fixture",
                "CFBundleExecutable": "OwnedFixture",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": version,
                "CFBundleVersion": version,
                "LSMinimumSystemVersion": "11.0",
            }
        )
    )
    children.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], confined=True)
    children.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], confined=True)
    return app


def archives(children, repository, app):
    """Call the production dual archive producer, never a fixture extractor."""
    output = app.parent / "archives"
    output.mkdir()
    children.run(
        [
            shutil.which("node"),
            str(repository / "tools/build/macos-release-archives.cjs"),
            str(app),
            str(output),
        ],
        confined=True,
    )
    for name in (BUNDLE + ".zip", BUNDLE + ".tar.xz"):
        require((output / name).is_file(), "Production dual archive output is missing")
    return output


def render_cask(children, repository, tap, version, archive, checksum=None):
    """Render through the real generator and verify its literal origin contract."""
    fmt = "tar.xz" if archive.name.endswith(".tar.xz") else "zip"
    checksum = checksum or digest(archive)
    renderer = children.root / "render-cask.cjs"
    renderer.write_text(
        "const fs = require('fs');\nconst path = require('path');\n"
        "const owner = require(process.argv[2]);\n"
        "const cask = owner.renderCask(process.argv[3], process.argv[4], process.argv[5]);\n"
        "const file = path.join(process.argv[6], cask.file);\n"
        "fs.mkdirSync(path.dirname(file), {recursive:true});\n"
        "fs.writeFileSync(file, cask.text);\nprocess.stdout.write(file + '\\n');\n",
        encoding="utf-8",
        newline="\n",
    )
    result = children.run(
        [
            shutil.which("node"),
            str(renderer),
            str(repository / "tools/build/homebrew-cask.cjs"),
            "v" + version,
            checksum,
            archive.name,
            str(tap),
        ],
        confined=True,
    )
    file = owned_path(children.root, result.stdout.strip())
    text = file.read_text(encoding="utf-8")
    require(f'  sha256 "{checksum}"\n' in text, "Generator changed expected archive checksum")
    origin = f"https://github.com/adrienm7/ergopti/releases/download/v#{{version}}/{BUNDLE}.{fmt}"
    require(
        f'  url "{origin}"\n' in text and '  app "ErgoptiPlus.app"\n' in text,
        "Generator did not preserve declared origin/artifact/format",
    )
    children.run(
        ["/usr/bin/git", "-C", str(tap), "add", "--", str(file.relative_to(tap))], confined=True
    )
    children.run(
        ["/usr/bin/git", "-C", str(tap), "commit", "-m", "Owned native fixture " + version],
        confined=True,
    )
    return file


def verify_installed(children, version, source):
    """Read native installed state independently of producer/cask rendering."""
    app = children.root / "apps" / BUNDLE
    require(app.is_dir() and not app.is_symlink(), "Actual Brew did not install an owned bundle")
    plist = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(
        plist["CFBundleShortVersionString"] == version,
        "Installed version differs from independent expectation",
    )
    resource = app / "Contents/Resources/données.txt"
    require(resource.read_bytes() == RESOURCE, "Installed Unicode resource bytes changed")
    require(
        os.readlink(app / "Contents/Resources/owned-link") == "données.txt",
        "Installed symlink changed",
    )
    require(
        stat.S_IMODE((app / "Contents/MacOS/OwnedFixture").stat().st_mode) == 0o751,
        "Installed executable mode changed",
    )
    require(
        tree_receipt(app) == tree_receipt(source),
        "Native Brew changed signed source bytes or modes",
    )
    children.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], confined=True)
    caskroom = children.root / "prefix/Caskroom/ergoptiplus"
    require((caskroom / version).is_dir(), "Actual Brew Caskroom lacks expected version")
    require(
        any(path.is_file() for path in caskroom.rglob("*.rb")),
        "Actual Brew Caskroom receipt is absent",
    )
    return {"version": version, "bundle": tree_receipt(app), "caskroom": tree_receipt(caskroom)}


def host_receipt(source, host, prefix):
    """Observe host code and Brew state while the native sandbox forbids all writes."""
    return {
        "entrypoint": digest(source),
        "library": tree_receipt(host / "Library/Homebrew"),
        "taps": tree_receipt(host / "Library/Taps"),
        "caskrooms": {
            str(path): tree_receipt(path) for path in {host / "Caskroom", prefix / "Caskroom"}
        },
        "prefix_entries": sorted(path.name for path in prefix.iterdir()),
    }


def observe(repository, output, *, fixture_parent=None):
    """Require ZIP install, XZ upgrade, two refusals and recovery with real Brew."""
    source, host, host_prefix = native_preconditions()
    repository = Path(repository).resolve(strict=True)
    host_before = host_receipt(source, host, host_prefix)
    receipt = {
        "kind": "native-homebrew-archive-acceptance",
        "complete": False,
        "revision": os.environ.get("GITHUB_SHA"),
        "sources": {
            name: digest(repository / name)
            for name in (
                "tools/build/homebrew-cask.cjs",
                "tools/build/macos-release-archives.cjs",
                "tools/diagnostics/macos_brew_archive_acceptance.py",
                "tools/diagnostics/macos_owned_process.py",
                "tools/diagnostics/native_appleevent_probe_receiver.c",
                "tools/diagnostics/native_appleevent_probe_sender.c",
            )
        },
        "cases": {},
        "cleanup_errors": [],
        "ownership": {"schema": 1, "helper_pid": os.getpid(), "closed": False},
        "native_python": {"executable": sys.executable, "version": list(sys.version_info[:3])},
        "signature_identity_boundary": "upstream-publication",
    }
    parent = Path(fixture_parent or tempfile.gettempdir()).resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix="ErgoptiBrewAcceptance-", dir=parent))
    children = None
    server = None
    failure = None
    old_handlers = {}

    def interrupted(_signal, _frame):
        raise OwnedProcessInterrupted("Native acceptance interrupted; exact children must retire")

    try:
        root.chmod(0o700)
        for name in ("home", "temp", "cache", "logs", "apps"):
            (root / name).mkdir()
        children = Children(root)
        for sig in (signal.SIGTERM, signal.SIGINT):
            previous = signal.getsignal(sig)
            signal.signal(sig, interrupted)
            old_handlers[sig] = previous
        admit_sandbox(children)
        receipt["appleevent_boundary"] = admit_appleevent_boundary(children, repository)
        brew, tap, receipt["brew"] = admit_brew(children, source, host)
        server = Assets(root, children)
        apps = {version: signed_bundle(children, version) for version in VERSIONS}
        produced = {version: archives(children, repository, apps[version]) for version in VERSIONS}
        receipt["archives"] = {
            version: {
                name: digest(directory / name) for name in (BUNDLE + ".zip", BUNDLE + ".tar.xz")
            }
            for version, directory in produced.items()
        }
        a, b, c, d = VERSIONS
        zip_archive = produced[a] / (BUNDLE + ".zip")
        xz_archive = produced[b] / (BUNDLE + ".tar.xz")
        server.add(a, zip_archive)
        server.add(b, xz_archive)
        token = "ergopti/acceptance/ergoptiplus"
        command = [str(brew), "install", "--cask", "--appdir=" + str(root / "apps"), token]
        render_cask(children, repository, tap, a, zip_archive)
        invoke_brew(children, command)
        verify_installed(children, a, apps[a])
        receipt["cases"]["zip_install"] = True
        render_cask(children, repository, tap, b, xz_archive)
        upgrade = [str(brew), "upgrade", "--cask", "--appdir=" + str(root / "apps"), token]
        invoke_brew(children, upgrade)
        installed = verify_installed(children, b, apps[b])
        receipt["cases"]["xz_upgrade"] = True
        # Keep the legitimate expected checksum; corrupt only the served bytes.
        good_c = produced[c] / (BUNDLE + ".tar.xz")
        bad_c = root / "corrupt" / good_c.name
        bad_c.parent.mkdir()
        corrupted_app = bad_c.parent / BUNDLE
        shutil.copytree(apps[c], corrupted_app, symlinks=True)
        signature = corrupted_app / "Contents/_CodeSignature/CodeResources"
        signature.write_bytes(b"Independent invalid native signature bytes\n")
        invalid_signature = children.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(corrupted_app)],
            confined=True,
            check=False,
        )
        require(
            invalid_signature.returncode != 0, "Negative signature-byte corruption remained valid"
        )
        children.run(
            ["/usr/bin/tar", "-cJf", str(bad_c), "-C", str(bad_c.parent), BUNDLE], confined=True
        )
        require(
            digest(bad_c) != digest(good_c),
            "Negative checksum fixture did not change archive bytes",
        )
        path_c = server.add(c, bad_c)
        render_cask(children, repository, tap, c, good_c)
        refused = invoke_brew(children, upgrade, check=False)
        checksum_output = refused.stdout + refused.stderr
        diagnostic = any(
            marker in checksum_output
            for marker in ("SHA256 mismatch", "Cask reports different checksum:")
        )
        require(
            refused.returncode != 0
            and diagnostic
            and digest(good_c) in checksum_output
            and digest(bad_c) in checksum_output,
            "Actual Brew did not report independent expected/served checksum refusal",
        )
        require(
            verify_installed(children, b, apps[b]) == installed,
            "Checksum refusal changed installed state",
        )
        receipt["cases"]["checksum_refusal_preserved"] = True
        server.paths[path_c] = good_c
        invoke_brew(children, upgrade)
        installed = verify_installed(children, c, apps[c])
        receipt["cases"]["checksum_retry"] = True
        # A real signed producer archive renamed under the declared URL has a
        # valid digest, but contains a differently named artifact.
        wrong_root = root / "wrong-artifact"
        wrong_root.mkdir()
        wrong_app = wrong_root / "ForeignArtifact.app"
        shutil.copytree(apps[d], wrong_app, symlinks=True)
        wrong_archive = wrong_root / (BUNDLE + ".tar.xz")
        # The producer intentionally enforces its declared bundle name. To test
        # Brew's artifact boundary, package the already verified signed bytes
        # with native tar, without changing producer acceptance claims.
        children.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(wrong_app)], confined=True
        )
        children.run(
            ["/usr/bin/tar", "-cJf", str(wrong_archive), "-C", str(wrong_root), wrong_app.name],
            confined=True,
        )
        path_d = server.add(d, wrong_archive)
        render_cask(children, repository, tap, d, wrong_archive)
        refused = invoke_brew(children, upgrade, check=False)
        refusal_output = refused.stdout + refused.stderr
        require(
            refused.returncode != 0
            and "It seems the App source '" in refusal_output
            and "ErgoptiPlus.app" in refusal_output
            and "is not there." in refusal_output,
            "Actual Brew did not refuse missing declared artifact",
        )
        require(
            verify_installed(children, c, apps[c]) == installed,
            "Artifact refusal changed installed state",
        )
        receipt["cases"]["artifact_refusal_preserved"] = True
        good_d = produced[d] / (BUNDLE + ".tar.xz")
        server.paths[path_d] = good_d
        render_cask(children, repository, tap, d, good_d)
        invoke_brew(children, upgrade)
        verify_installed(children, d, apps[d])
        receipt["cases"]["artifact_retry"] = True
        require(not server.failures, "Owned TLS transport received undeclared origins")
        require(
            all(path in server.requests for path in server.paths),
            "Actual Brew did not acquire all declared archive origins",
        )
        receipt["requests"] = server.requests
        receipt["complete"] = True
    except Exception as error:
        failure = error
        receipt["failure"] = str(error)[:4096]
    finally:
        for sig in old_handlers:
            try:
                signal.signal(sig, signal.SIG_IGN)
            except Exception:
                receipt["cleanup_errors"].append("Owned signal masking failed")
        # Never discard the ledger while its acquired native groups retain debt.
        # Cleanup retries preserve the original operation failure/deadline; a
        # permanently unavailable native census keeps this owner and inputs alive.
        operation_complete = receipt["complete"]
        retired = children is None
        while not retired:
            try:
                retired = children.retire()
            except Exception:
                retired = False
            if not retired:
                receipt["complete"] = False
                receipt["fixture_retained"] = True
                receipt["fixture"] = str(root)
                receipt["cleanup_debt"] = children.debt
                try:
                    Path(output).write_text(
                        json.dumps(receipt, indent=2) + "\n", encoding="utf-8", newline="\n"
                    )
                except Exception:
                    pass  # Failed evidence publication cannot surrender native ownership.
                time.sleep(0.25)
        receipt["ownership"]["closed"] = True
        receipt["complete"] = operation_complete
        receipt.pop("cleanup_debt", None)
        try:
            host_after = host_receipt(source, host, host_prefix)
            receipt["host_unchanged"] = host_before == host_after
        except Exception:
            receipt["host_unchanged"] = False
            receipt["cleanup_errors"].append("Host state could not be re-observed")
        if not receipt["host_unchanged"]:
            receipt["cleanup_errors"].append("Read-only host Brew state changed")
        receipt["complete"] = receipt["complete"] and not receipt["cleanup_errors"]
        if children is not None and children.debt:
            receipt["cleanup_debt"] = children.debt
        receipt["fixture_retained"] = bool(receipt["cleanup_errors"]) or isinstance(
            failure, AppleEventBoundaryError
        )
        if receipt["fixture_retained"]:
            receipt["fixture"] = str(root)
        else:
            try:
                shutil.rmtree(root)
            except OSError:
                receipt["complete"] = False
                receipt["fixture_retained"] = True
                receipt["fixture"] = str(root)
                receipt["cleanup_errors"].append("Owned fixture could not retire")
        for sig, handler in old_handlers.items():
            try:
                signal.signal(sig, handler)
            except Exception:
                receipt["complete"] = False
                receipt["cleanup_errors"].append("Owned signal handler restoration failed")
        Path(output).write_text(
            json.dumps(receipt, indent=2) + "\n", encoding="utf-8", newline="\n"
        )
    if failure is not None:
        raise AdmissionError(str(failure)) from failure
    require(receipt["complete"], "Native acceptance retained cleanup debt")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository")
    parser.add_argument("receipt")
    parser.add_argument("--fixture-parent")
    arguments = parser.parse_args()
    try:
        observe(arguments.repository, arguments.receipt, fixture_parent=arguments.fixture_parent)
    except (AdmissionError, OSError, ValueError) as error:
        print("Native Brew acceptance failed: " + str(error), file=sys.stderr)
        raise SystemExit(1)
