"""Generate the fixed genuine CLI source tranche; no native/image admission."""

import argparse, hashlib, json, os, signal, stat, sys
from pathlib import Path

SOURCE_SHA = "a63fc1a38688a3c74fddaa2b7281adf930947031870c25bc0d1aa950023bb721"
SOURCE_BYTES = 26425
INPUT_PATH = "tools/build/core_sdk/inputs/hs274-installed-cli.source.hpp"
HEADER_PATH = "tools/build/core_sdk/source/src/share/hs274-installed-intent.hpp"
CLI_PATH = "tools/build/core_sdk/source/src/share/hs274-installed-cli.hpp"
DESCRIPTOR_PATH = "tools/build/core_sdk/installed_cli_source.json"
OWNERS = []


class Refused(RuntimeError):
    pass


def require(value, reason):
    if not value:
        raise Refused(reason)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def identity(info):
    return (
        info.st_dev,
        info.st_ino,
        info.st_uid,
        info.st_gid,
        info.st_mode,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


class Deferral:
    def __init__(self):
        self.original = None
        self.restored = False

    def __enter__(self):
        self.original = signal.pthread_sigmask(
            signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGALRM}
        )
        return self

    def __exit__(self, kind, value, trace):
        try:
            signal.pthread_sigmask(signal.SIG_SETMASK, self.original)
            self.restored = True
        except BaseException as cleanup:
            if value is not None:
                raise Refused("original error plus mask restoration refusal") from value
            raise cleanup
        return False


def fd_owner(path, flags, mode=None):
    owner = {
        "path": str(path),
        "fd": None,
        "opened": False,
        "close_attempted": False,
        "closed": False,
        "debt": False,
    }
    OWNERS.append(owner)
    try:
        owner["fd"] = os.open(path, flags) if mode is None else os.open(path, flags, mode)
        owner["opened"] = True
    except OSError:
        raise
    except BaseException:
        owner["debt"] = True
        raise
    return owner


def close_once(owner):
    if not owner["opened"] or owner["close_attempted"]:
        return
    owner["close_attempted"] = True
    try:
        os.close(owner["fd"])
        owner["closed"] = True
    except BaseException:
        owner["debt"] = True
        raise
    finally:
        owner["fd"] = None


def read_source(path):
    require(
        path.is_absolute() and path.resolve(strict=True) == path and not path.is_symlink(),
        "fixed source redirects",
    )
    with Deferral():
        before = path.lstat()
        require(
            stat.S_ISREG(before.st_mode)
            and before.st_nlink == 1
            and before.st_uid == os.getuid()
            and stat.S_IMODE(before.st_mode) == 0o644
            and before.st_size == SOURCE_BYTES,
            "fixed source shape",
        )
        owner = fd_owner(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        primary = None
        try:
            require(identity(os.fstat(owner["fd"])) == identity(before), "opened source changed")
            data = os.read(owner["fd"], SOURCE_BYTES + 1)
            require(len(data) == SOURCE_BYTES and digest(data) == SOURCE_SHA, "fixed source bytes")
            require(
                identity(os.fstat(owner["fd"])) == identity(before)
                and identity(path.lstat()) == identity(before),
                "fixed source changed",
            )
            return data, identity(before)
        except BaseException as error:
            primary = error
            raise
        finally:
            try:
                close_once(owner)
            except BaseException:
                if primary is not None:
                    raise Refused("original source error plus checked close refusal") from primary
                raise


def outputs(data):
    require(len(data) == SOURCE_BYTES and digest(data) == SOURCE_SHA, "source commitment")
    source = data.decode("utf-8", "strict")
    marker = "class intent_channel final {"
    require(source.count(marker) == 1, "original actor marker")
    start = source.index(marker)
    end = source.index("\n};", start) + 3
    actor = source[start:end]
    header = (
        "// Generated from the fixed original installed CLI implementation.\n#pragma once\n\n"
        + actor
        + "\n"
    ).encode()
    consumer = (source[:start] + '#include "hs274-installed-intent.hpp"' + source[end:]).encode()
    require(
        consumer.decode().replace('#include "hs274-installed-intent.hpp"', actor, 1) == source,
        "whole original consumer inverse",
    )
    files = {HEADER_PATH: header, CLI_PATH: consumer}
    descriptor = {
        "schema": 1,
        "kind": "g5_sdk_source_inventory",
        "generator": "tools/build/core_sdk/generate_installed_cli_source.py",
        "input": {"path": INPUT_PATH, "sha256": SOURCE_SHA, "bytes": len(data)},
        "files": {
            name: {
                "sha256": digest(body),
                "bytes": len(body),
                "lines": len(body.splitlines()),
                "mode": "100644",
            }
            for name, body in sorted(files.items())
        },
        "native_qualification": "NONE; source preparation only; real Core/driver/readiness producer and SDK integration required",
    }
    files[DESCRIPTOR_PATH] = (json.dumps(descriptor, indent="\t", sort_keys=True) + "\n").encode()
    return files


def generate(output):
    require(not any(row["debt"] for row in OWNERS), "retained original descriptor debt")
    output = Path(output)
    source = (
        Path(__file__).resolve(strict=True).parent / "inputs" / "hs274-installed-cli.source.hpp"
    )
    data, source_identity = read_source(source)
    files = outputs(data)
    require(
        output.is_absolute() and output.resolve(strict=True) == output and not output.is_symlink(),
        "owned output redirects",
    )
    before = output.lstat()
    require(
        stat.S_ISDIR(before.st_mode)
        and before.st_uid == os.getuid()
        and stat.S_IMODE(before.st_mode) == 0o700
        and not any(output.iterdir()),
        "empty owned output required",
    )
    with Deferral():
        directory = fd_owner(output, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        primary = None
        try:
            require(
                identity(os.fstat(directory["fd"])) == identity(before),
                "original output directory changed",
            )
            for name, body in files.items():
                target = output / name
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                require(
                    target.parent.resolve(strict=True) == target.parent
                    and target.parent.is_relative_to(output),
                    "output parent redirects",
                )
                leaf = fd_owner(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                leaf_error = None
                try:
                    held = os.fstat(leaf["fd"])
                    require(
                        stat.S_ISREG(held.st_mode)
                        and held.st_nlink == 1
                        and held.st_uid == os.getuid(),
                        "output descriptor shape",
                    )
                    offset = 0
                    while offset < len(body):
                        count = os.write(leaf["fd"], body[offset:])
                        require(count > 0, "incomplete output write")
                        offset += count
                    os.fchmod(leaf["fd"], 0o644)
                    os.fsync(leaf["fd"])
                    held = os.fstat(leaf["fd"])
                    require(
                        held.st_size == len(body) and identity(target.lstat()) == identity(held),
                        "exact original output leaf changed",
                    )
                except BaseException as error:
                    leaf_error = error
                    raise
                finally:
                    try:
                        close_once(leaf)
                    except BaseException:
                        if leaf_error is not None:
                            raise Refused(
                                "original output error plus close refusal"
                            ) from leaf_error
                        raise
            require(
                output.lstat().st_dev == before.st_dev and output.lstat().st_ino == before.st_ino,
                "output directory replaced",
            )
            require(
                source.lstat() and identity(source.lstat()) == source_identity,
                "fixed source replaced after generation",
            )
            require(
                {p.relative_to(output).as_posix() for p in output.rglob("*") if p.is_file()}
                == set(files),
                "output roster changed",
            )
        except BaseException as error:
            primary = error
            raise
        finally:
            try:
                close_once(directory)
            except BaseException:
                if primary is not None:
                    raise Refused(
                        "original generation error plus directory close refusal"
                    ) from primary
                raise
    require(
        not any(row["debt"] or row["opened"] and not row["closed"] for row in OWNERS),
        "original descriptor close incomplete",
    )
    return files


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    options = parser.parse_args()
    try:
        generate(options.output)
    except BaseException as error:
        print("SDK CLI source generation refused: " + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
