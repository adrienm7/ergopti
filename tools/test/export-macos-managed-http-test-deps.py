"""Export the existing locked native-client test closure with committed hashes.

The output is an ephemeral pip requirements input, not a second dependency
authority. Unrelated MLX runtimes are excluded; every selected dependency edge,
including platform marker alternatives, remains represented and hash gated.
"""

import re
import sys
import tomllib
from pathlib import Path


ROOTS = ("huggingface-hub", "httpx", "truststore")
NAME = re.compile(r"[a-z0-9]+(?:[-_.][a-z0-9]+)*\Z")
VERSION = re.compile(r"[A-Za-z0-9][-A-Za-z0-9_.+!]*\Z")
HASH = re.compile(r"sha256:([a-f0-9]{64})\Z")


def requirements(source):
    """Return a closed, fully hashed requirements input or refuse ambiguity."""
    lock = tomllib.loads(source)
    if type(lock.get("version")) is not int or lock["version"] != 1:
        raise ValueError("Unsupported locked client dependency schema")
    packages = {}
    for package in lock.get("package", []):
        if not isinstance(package, dict) or not isinstance(package.get("name"), str):
            raise ValueError("Invalid locked client package")
        packages.setdefault(package["name"], []).append(package)
    pending, selected = list(ROOTS), {}
    while pending:
        name = pending.pop()
        if name in selected:
            continue
        matches = packages.get(name, [])
        if len(matches) != 1:
            raise ValueError("Ambiguous or missing locked client dependency")
        package = matches[0]
        version = package.get("version")
        if (
            not NAME.fullmatch(name)
            or not isinstance(version, str)
            or not VERSION.fullmatch(version)
        ):
            raise ValueError("Invalid locked client identity")
        if package.get("source", {}).get("registry") != "https://pypi.org/simple":
            raise ValueError("Unqualified locked client source")
        selected[name] = package
        for dependency in package.get("dependencies", []):
            child = dependency.get("name") if isinstance(dependency, dict) else None
            if not isinstance(child, str) or not NAME.fullmatch(child):
                raise ValueError("Invalid locked client dependency edge")
            if "version" in dependency:
                candidates = packages.get(child, [])
                if len(candidates) != 1 or candidates[0].get("version") != dependency["version"]:
                    raise ValueError("Ambiguous locked client dependency version")
            pending.append(child)
    lines = [
        "# Exported from the existing uv.lock; install with --require-hashes --only-binary=:all:."
    ]
    for name in sorted(selected):
        package = selected[name]
        distributions = list(package.get("wheels", []))
        if "sdist" in package:
            distributions.append(package["sdist"])
        hashes = set()
        for distribution in distributions:
            digest = distribution.get("hash") if isinstance(distribution, dict) else None
            if not isinstance(digest, str) or HASH.fullmatch(digest) is None:
                raise ValueError("Invalid locked client distribution hash")
            hashes.add(digest)
        if not hashes:
            raise ValueError("Missing locked client distribution hashes")
        lines.append(name + "==" + package["version"] + " \\")
        ordered = sorted(hashes)
        lines.extend(
            "    --hash=" + digest + (" \\" if index < len(ordered) - 1 else "")
            for index, digest in enumerate(ordered)
        )
    return "\n".join(lines) + "\n"


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: export-macos-managed-http-test-deps.py <existing-uv.lock>")
    try:
        result = requirements(Path(sys.argv[1]).read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError, KeyError):
        raise SystemExit("Locked native-client test dependency export refused") from None
    sys.stdout.write(result)


if __name__ == "__main__":
    main()
