# modules/llm/managed_bootstrap_http.py
"""Stage pinned bootstrap inputs through the signed native request transport.

uv consumes verified local files with network access disabled. Its original
interpreter extraction, dependency hashes and final import probe remain owners
of installation; a working CONNECT tunnel cannot substitute for URL routing.
"""

import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urljoin, urlsplit


DRIVER_ROOT = Path(__file__).resolve().parents[2]
SHARED_ROOT = DRIVER_ROOT.parent / "_shared"
REDIRECT_POLICY = SHARED_ROOT / "data/http/redirect_policy.json"
PROXY_POLICY = SHARED_ROOT / "python/network_proxy_policy.py"
PYTHON_RELEASE = SHARED_ROOT / "modules/llm/managed_python_release.json"
NATIVE_ENGINE = DRIVER_ROOT / "platform/network/native_http.py"


class BootstrapFailure(Exception):
    """An installation failure whose public message contains no private URL."""

    def __init__(self, reason):
        self.reason = reason
        super().__init__(reason)


def _remaining(deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise BootstrapFailure("deadline")
    return remaining


def _native_request(*args, **kwargs):
    if "_ergopti_native_http" not in sys.modules:
        specification = importlib.util.spec_from_file_location(
            "_ergopti_native_http", NATIVE_ENGINE
        )
        if specification is None or specification.loader is None:
            raise BootstrapFailure("unavailable")
        module = importlib.util.module_from_spec(specification)
        sys.modules[specification.name] = module
        specification.loader.exec_module(module)
    return sys.modules["_ergopti_native_http"].open_request(*args, **kwargs)


def _url(value, maximum):
    if (
        not isinstance(value, str)
        or len(value.encode("utf-8")) > maximum
        or any(ord(c) < 33 or ord(c) == 127 for c in value)
    ):
        raise BootstrapFailure("protocol")
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError:
        raise BootstrapFailure("protocol") from None
    if (
        parsed.scheme not in ("https", "http")
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
    ):
        raise BootstrapFailure("protocol")
    if port is not None and not 1 <= port <= 65535:
        raise BootstrapFailure("protocol")
    return parsed


def _direct_route(url):
    specification = importlib.util.spec_from_file_location(
        "_ergopti_bootstrap_proxy_policy", PROXY_POLICY
    )
    if specification is None or specification.loader is None:
        raise BootstrapFailure("unavailable")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    policy = module.ProxyPolicy()
    # The shell captured the original HTTPS/all route before exporting static
    # system settings and keeps that explicit selection on curl. Those later
    # exports cannot masquerade as an original environment route here.
    environment = dict(os.environ)
    for name in policy.system_lookup_environment_exclusions:
        environment.pop(name, None)
    mode, _ = policy.route(url, environment)
    return mode == "direct"


def download(url, output, digest, size, deadline, idle_timeout, request=_native_request):
    """Publish one exact checksum-admitted file after native terminal and reap.

    Every redirect is a separate full-URL request under the original absolute
    deadline. Redirect bodies are physically cancelled before the next request.
    A failed transfer removes only the descriptor this invocation created.
    """
    policy = json.loads(REDIRECT_POLICY.read_text(encoding="utf-8"))["buffered_get"]
    if not isinstance(digest, str) or re.fullmatch(r"[a-f0-9]{64}", digest) is None:
        raise BootstrapFailure("integrity")
    if size is not None and (type(size) is not int or size <= 0):
        raise BootstrapFailure("integrity")
    output = Path(output)
    if not output.is_absolute():
        raise BootstrapFailure("file_create")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    descriptor = os.open(output, flags, 0o600)
    complete = False
    try:
        with os.fdopen(descriptor, "wb") as stream:
            current = url
            visited = set()
            for _ in range(policy["max_hops"] + 1):
                parsed = _url(current, policy["max_url_bytes"])
                if current in visited:
                    raise BootstrapFailure("redirect")
                visited.add(current)
                with request(
                    current,
                    headers=(("Accept-Encoding", "identity"),),
                    timeout=_remaining(deadline),
                    idle_timeout=idle_timeout,
                    direct=_direct_route(current),
                ) as response:
                    if policy["status_min"] <= response.status <= policy["status_max"]:
                        locations = [
                            value for name, value in response.headers if name.lower() == "location"
                        ]
                        if len(locations) != 1 or not locations[0]:
                            raise BootstrapFailure("redirect")
                        target = urljoin(current, locations[0])
                        next_url = _url(target, policy["max_url_bytes"])
                        if parsed.scheme == "https" and next_url.scheme != "https":
                            raise BootstrapFailure("redirect")
                        current = target
                        continue
                    if response.status != 200:
                        raise BootstrapFailure("http")
                    count = 0
                    actual = hashlib.sha256()
                    while True:
                        _remaining(deadline)
                        chunk = response.read()
                        if not chunk:
                            break
                        count += len(chunk)
                        if size is not None and count > size:
                            raise BootstrapFailure("integrity")
                        stream.write(chunk)
                        actual.update(chunk)
                    if (size is not None and count != size) or actual.hexdigest() != digest:
                        raise BootstrapFailure("integrity")
                    stream.flush()
                    os.fsync(stream.fileno())
                    _remaining(deadline)
                    break
            else:
                raise BootstrapFailure("redirect")
        _remaining(deadline)
        complete = True
        return output
    finally:
        if not complete:
            output.unlink()


def _run_uv(arguments, deadline, environment=None):
    """Retire the exact uv child before an exception or a successor escapes."""
    child = None
    try:
        child = subprocess.Popen(arguments, stdout=subprocess.PIPE, env=environment)
        stdout, _ = child.communicate(timeout=_remaining(deadline))
        if child.returncode != 0 or len(stdout) > 16 * 1024 * 1024:
            raise BootstrapFailure("dependency")
        return stdout
    except subprocess.TimeoutExpired:
        raise BootstrapFailure("deadline") from None
    finally:
        if child is not None:
            if child.poll() is None:
                child.kill()
            child.wait()
            if child.stdout is not None:
                child.stdout.close()


def install_python(uv, python_request, deadline, idle_timeout):
    """Give genuine uv a pinned native-downloaded archive in its offline cache."""
    family = {
        "cpython-3.11-macos-aarch64-none": "aarch64",
        "cpython-3.11-macos-x86_64-none": "x86_64",
    }.get(python_request)
    if family is None:
        raise BootstrapFailure("dependency")
    release = json.loads(PYTHON_RELEASE.read_text(encoding="utf-8"))
    if not isinstance(release, dict):
        raise BootstrapFailure("integrity")
    downloads = release.get("downloads")
    if (
        type(release.get("schema_version")) is not int
        or release["schema_version"] != 1
        or not isinstance(downloads, dict)
        or len(downloads) != 2
    ):
        raise BootstrapFailure("integrity")
    selections = {}
    for key, candidate in downloads.items():
        if (
            not isinstance(candidate, dict)
            or set(candidate)
            != {
                "name",
                "arch",
                "os",
                "libc",
                "major",
                "minor",
                "patch",
                "prerelease",
                "url",
                "sha256",
                "variant",
                "build",
            }
            or not isinstance(candidate.get("arch"), dict)
            or set(candidate["arch"]) != {"family", "variant"}
        ):
            raise BootstrapFailure("integrity")
        architecture = candidate["arch"].get("family")
        if architecture not in ("aarch64", "x86_64") or architecture in selections:
            raise BootstrapFailure("integrity")
        if (
            candidate.get("name") != "cpython"
            or candidate.get("os") != "darwin"
            or candidate.get("libc") != "none"
            or candidate["arch"].get("variant") is not None
            or candidate.get("variant") is not None
            or candidate.get("prerelease") != ""
            or type(candidate.get("major")) is not int
            or candidate["major"] != 3
            or type(candidate.get("minor")) is not int
            or candidate["minor"] != 11
            or type(candidate.get("patch")) is not int
            or candidate["patch"] < 0
            or not isinstance(candidate.get("build"), str)
            or re.fullmatch(r"[0-9]{8}", candidate["build"]) is None
            or not isinstance(candidate.get("sha256"), str)
            or re.fullmatch(r"[a-f0-9]{64}", candidate["sha256"]) is None
        ):
            raise BootstrapFailure("integrity")
        version = "3.11." + str(candidate["patch"])
        if (
            key != "cpython-" + version + "-darwin-" + architecture + "-none"
            or candidate.get("url")
            != "https://github.com/astral-sh/python-build-standalone/releases/download/"
            + candidate["build"]
            + "/cpython-"
            + version
            + "%2B"
            + candidate["build"]
            + "-"
            + architecture
            + "-apple-darwin-install_only_stripped.tar.gz"
        ):
            raise BootstrapFailure("integrity")
        selections[architecture] = (key, candidate)
    if set(selections) != {"aarch64", "x86_64"}:
        raise BootstrapFailure("integrity")
    key, entry = selections[family]
    with tempfile.TemporaryDirectory(prefix="ergopti-python-input-") as folder:
        root = Path(folder)
        metadata = root / "downloads.json"
        metadata.write_text(json.dumps({key: entry}), encoding="utf-8")
        # uv deliberately uses '-' for the escaped '+' in its private Python
        # archive cache. Its built-in extraction verifies the complete hash.
        filename = entry["url"].rsplit("/", 1)[-1].replace("%2B", "-")
        if re.fullmatch(r"[a-zA-Z0-9_.-]+", filename) is None:
            raise BootstrapFailure("integrity")
        archive = root / (entry["sha256"][:9] + "-" + filename)
        download(entry["url"], archive, entry["sha256"], None, deadline, idle_timeout)
        environment = dict(os.environ)
        environment["UV_PYTHON_CACHE_DIR"] = str(root)
        environment["UV_PYTHON_DOWNLOADS"] = "manual"
        target = (
            "cpython-"
            + str(entry["major"])
            + "."
            + str(entry["minor"])
            + "."
            + str(entry["patch"])
            + "-macos-"
            + family
            + "-none"
        )
        _run_uv(
            [
                uv,
                "python",
                "install",
                target,
                "--offline",
                "--no-config",
                "--python-downloads-json-url",
                str(metadata),
            ],
            deadline,
            environment,
        )


def _read_lock(project):
    import tomllib

    return tomllib.loads((Path(project) / "uv.lock").read_text(encoding="utf-8"))


def _wheel_name(wheel):
    filename = unquote(urlsplit(wheel["url"]).path.rsplit("/", 1)[-1])
    if not filename.endswith(".whl") or re.fullmatch(r"[a-zA-Z0-9_.+-]+", filename) is None:
        raise BootstrapFailure("integrity")
    return filename


def _fetch_wheel(wheel, folder, deadline, idle_timeout):
    if not wheel["hash"].startswith("sha256:"):
        raise BootstrapFailure("integrity")
    return download(
        wheel["url"],
        folder / _wheel_name(wheel),
        wheel["hash"][7:],
        wheel["size"],
        deadline,
        idle_timeout,
    )


def sync_dependencies(uv, project, python, deadline, idle_timeout):
    """Select locked native wheels and run uv's hash-enforced offline sync."""
    lock = _read_lock(project)
    with tempfile.TemporaryDirectory(prefix="ergopti-mlx-input-") as folder:
        root = Path(folder)
        packages = {(package["name"], package["version"]): package for package in lock["package"]}
        packaging = [package for package in lock["package"] if package["name"] == "packaging"]
        if len(packaging) != 1:
            raise BootstrapFailure("dependency")
        pure_wheels = [
            wheel
            for wheel in packaging[0].get("wheels", [])
            if _wheel_name(wheel).endswith("-py3-none-any.whl")
        ]
        if len(pure_wheels) != 1 or "packaging" in sys.modules:
            raise BootstrapFailure("dependency")
        packaging_wheel = _fetch_wheel(pure_wheels[0], root, deadline, idle_timeout)
        # The already-locked dependency supplies the real PEP 425/508 rules.
        # Never guess wheel ABI/platform compatibility or execute an sdist.
        sys.path.insert(0, str(packaging_wheel))
        from packaging.requirements import Requirement
        from packaging.tags import sys_tags
        from packaging.utils import canonicalize_name, parse_wheel_filename

        rank = {tag: index for index, tag in enumerate(sys_tags())}
        requirements = _run_uv(
            [
                uv,
                "export",
                "--project",
                str(project),
                "--frozen",
                "--offline",
                "--no-dev",
                "--no-emit-project",
                "--no-header",
                "--no-annotate",
                "--format",
                "requirements-txt",
            ],
            deadline,
        )
        text = requirements.decode("utf-8").replace("\\\n", " ")
        selected = set()
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            requirement = Requirement(line.split(" --hash=", 1)[0].strip())
            if requirement.marker is not None and not requirement.marker.evaluate():
                continue
            versions = list(requirement.specifier)
            if requirement.url is not None or len(versions) != 1 or versions[0].operator != "==":
                raise BootstrapFailure("dependency")
            identity = (canonicalize_name(requirement.name), versions[0].version)
            if identity in selected:
                continue
            selected.add(identity)
            package = packages.get(identity)
            if package is None or set(package.get("source", {})) != {"registry"}:
                raise BootstrapFailure("dependency")
            candidates = []
            for wheel in package.get("wheels", []):
                wheel_name, wheel_version, _, tags = parse_wheel_filename(_wheel_name(wheel))
                if (
                    canonicalize_name(wheel_name) != identity[0]
                    or str(wheel_version) != identity[1]
                ):
                    raise BootstrapFailure("integrity")
                matches = [rank[tag] for tag in tags if tag in rank]
                if matches:
                    candidates.append((min(matches), wheel))
            if not candidates:
                raise BootstrapFailure("dependency")
            wheel = min(candidates, key=lambda candidate: candidate[0])[1]
            if root / _wheel_name(wheel) != packaging_wheel:
                _fetch_wheel(wheel, root, deadline, idle_timeout)
        if not selected:
            raise BootstrapFailure("dependency")
        exported = root / "requirements.txt"
        exported.write_bytes(requirements)
        _run_uv(
            [
                uv,
                "pip",
                "sync",
                "--offline",
                "--no-index",
                "--require-hashes",
                "--find-links",
                str(root),
                "--python",
                python,
                str(exported),
            ],
            deadline,
        )


def _cancel(_signal, _frame):
    raise BootstrapFailure("cancelled")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--idle-timeout", type=float, required=True)
    actions = parser.add_subparsers(dest="action", required=True)
    asset = actions.add_parser("download")
    asset.add_argument("--url", required=True)
    asset.add_argument("--output", required=True)
    asset.add_argument("--sha256", required=True)
    asset.add_argument("--size", type=int)
    interpreter = actions.add_parser("python-install")
    interpreter.add_argument("--uv", required=True)
    interpreter.add_argument("--request", required=True)
    dependencies = actions.add_parser("sync")
    dependencies.add_argument("--uv", required=True)
    dependencies.add_argument("--project", required=True)
    dependencies.add_argument("--python", required=True)
    arguments = parser.parse_args(argv)
    if not all(
        math.isfinite(value) and value > 0 for value in (arguments.timeout, arguments.idle_timeout)
    ):
        raise BootstrapFailure("protocol")
    deadline = time.monotonic() + arguments.timeout
    sys.dont_write_bytecode = True
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, _cancel)
    if arguments.action == "download":
        download(
            arguments.url,
            arguments.output,
            arguments.sha256,
            arguments.size,
            deadline,
            arguments.idle_timeout,
        )
    elif arguments.action == "python-install":
        install_python(arguments.uv, arguments.request, deadline, arguments.idle_timeout)
    else:
        sync_dependencies(
            arguments.uv, arguments.project, arguments.python, deadline, arguments.idle_timeout
        )


if __name__ == "__main__":
    try:
        main()
    except Exception as failure:
        reason = failure.reason if hasattr(failure, "reason") else "unavailable"
        if reason not in {
            "integrity",
            "dependency",
            "deadline",
            "cancelled",
            "unavailable",
            "protocol",
            "redirect",
            "http",
            "file_create",
            "offline",
            "certificate",
            "proxy",
            "connect",
            "content_encoding",
        }:
            reason = "unavailable"
        print("Managed bootstrap request failed: " + reason + ".", file=sys.stderr)
        sys.exit(74)
