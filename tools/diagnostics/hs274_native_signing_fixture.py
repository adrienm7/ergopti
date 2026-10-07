# tools/diagnostics/hs274_native_signing_fixture.py
"""TEST-ONLY disposable Darwin credentials. No production credential fallback.

Native commands run in the invoking SDK Guardian's inherited process group.
Their output is memory-only; credential material never enters evidence captures.
"""

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import time


class FixtureRefusal(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def require(value, code):
    if not value:
        raise FixtureRefusal(code)


def supported(platform):
    return platform == "darwin"


def remaining(deadline):
    value = deadline - time.monotonic()
    require(value > 0, "deadline")
    return value


def _stamp(s):
    return (s.st_dev, s.st_ino, s.st_uid, stat.S_IMODE(s.st_mode))


def _full(s):
    return _stamp(s) + (s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_nlink)


def _ancestors(path):
    try:
        require(path.is_absolute() and path.resolve(strict=True) == path, "ancestry")
    except FixtureRefusal as error:
        error.ancestry_check = "canonical_path"
        raise
    result = []
    for parent in reversed((path,) + tuple(path.parents)):
        s = parent.lstat()
        try:
            require(stat.S_ISDIR(s.st_mode), "ancestry")
        except FixtureRefusal as error:
            error.ancestry_check = "ancestor_directory"
            raise
        result.append((parent, _stamp(s)))
    return tuple(result)


def _current_ancestors(ancestors):
    for path, stamp in ancestors:
        require(
            _stamp(path.lstat()) == stamp and stat.S_ISDIR(path.lstat().st_mode), "ancestry_changed"
        )


@dataclass(frozen=True)
class Held:
    path: Path
    identity: tuple
    data: bytes
    ancestors: tuple
    owned: bool


def ordinary(path, mode=None, limit=256 * 1024 * 1024, *, owned=True):
    path = Path(path)
    ancestors = _ancestors(path.parent)
    require(path.parent / path.name == path and path.name not in ("", ".", ".."), "path")
    before = path.lstat()
    require(
        stat.S_ISREG(before.st_mode)
        and before.st_nlink == 1
        and before.st_uid == (os.geteuid() if owned else 0),
        "file",
    )
    if mode is not None:
        require(stat.S_IMODE(before.st_mode) == mode, "mode")
    require(0 < before.st_size <= limit, "file_size")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        opened = os.fstat(fd)
        require(_full(opened) == _full(before), "file_changed")
        data = bytearray()
        while True:
            chunk = os.read(fd, min(65536, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
            require(len(data) <= limit, "file_size")
        require(
            _full(os.fstat(fd)) == _full(before) and _full(path.lstat()) == _full(before),
            "file_changed",
        )
        require(len(data) == before.st_size, "file_changed")
        _current_ancestors(ancestors)
        return Held(path, _full(before), bytes(data), ancestors, owned)
    finally:
        os.close(fd)


def current(held):
    fresh = ordinary(held.path, held.identity[3], owned=held.owned)
    require(
        fresh.identity == held.identity
        and fresh.data == held.data
        and fresh.ancestors == held.ancestors,
        "file_changed",
    )


def create_private(path):
    path = Path(path)
    _ancestors(path.parent)
    require(not os.path.lexists(path), "collision")
    path.mkdir(mode=0o700)
    info = path.lstat()
    require(info.st_uid == os.geteuid() and _stamp(info)[3] == 0o700, "root")
    return _ancestors(path)


def list_keychains(data):
    require(type(data) is bytes and len(data) <= 65536, "keychain_list")
    try:
        text = data.decode("utf-8", "strict")
    except UnicodeError as e:
        raise FixtureRefusal("keychain_list") from e
    result = []
    for line in text.splitlines():
        m = re.fullmatch(r'\s*"([^"\\\x00-\x1f]+)"\s*', line)
        require(m is not None, "keychain_list")
        value = m.group(1)
        p = Path(value)
        require(
            p.is_absolute() and str(p) == value and ".." not in p.parts and value not in result,
            "keychain_list",
        )
        result.append(value)
    return tuple(result)


def foreign_list(values, owned):
    return tuple(v for v in values if v != owned)


def search_unchanged(before, after, owned):
    return foreign_list(after, owned) == tuple(before)


def public_record(identity, sha):
    require(
        re.fullmatch("[A-F0-9]{40}", identity) is not None
        and re.fullmatch("[a-f0-9]{64}", sha) is not None,
        "record",
    )
    return {
        "schema": 1,
        "status": "ready",
        "identity": identity,
        "public_leaf_sha256": sha,
        "test_only": True,
        "shipping_qualified": False,
        "installation_qualified": False,
        "authentication_qualified": False,
    }


_NATIVE = ("/usr/bin/security", "/usr/bin/openssl")


def command(arguments, deadline, guard, env=None):
    require(arguments[0] in _NATIVE, "command")
    guard()
    remaining(deadline)
    try:
        result = subprocess.run(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=remaining(deadline),
            check=False,
            env=env,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        raise FixtureRefusal("native_command") from e
    guard()
    remaining(deadline)
    require(
        result.returncode == 0 and len(result.stdout) + len(result.stderr) <= 2 * 1024 * 1024,
        "native_command",
    )
    return result.stdout, result.stderr


def _write(path, data, mode):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as out:
            out.write(data)
    except BaseException:
        raise


def _state(root, record):
    path = root / ".state.json"
    temp = root / ".state.next"
    require(not os.path.lexists(temp), "state")
    _write(temp, (json.dumps(record, sort_keys=True) + "\n").encode(), 0o600)
    os.replace(temp, path)


def _search(deadline, guard):
    return list_keychains(
        command(["/usr/bin/security", "list-keychains", "-d", "user"], deadline, guard)[0]
    )


def _setup_stage(stage, operation):
    """Retain only a fixed setup caller for the original ancestry refusal."""
    try:
        return operation()
    except FixtureRefusal as error:
        if error.code == "ancestry":
            error.ancestry_stage = stage
        raise


def setup(root, public):
    require(supported(sys.platform), "platform")
    root, public = Path(root), Path(public)
    require(root.is_absolute() and public.is_absolute(), "path")
    public_ancestors = _setup_stage("public_ancestry", lambda: _ancestors(public))
    require(
        public not in root.parents
        and public.parent not in root.parents
        and root not in public.parents
        and root != public
        and root != public.parent,
        "private_in_evidence",
    )
    ancestors = _setup_stage("private_creation", lambda: create_private(root))
    source = _setup_stage(
        "fixture_source", lambda: ordinary(Path(__file__).resolve(), limit=1024 * 1024)
    )
    tools = _setup_stage(
        "native_tools", lambda: tuple(ordinary(Path(path), owned=False) for path in _NATIVE)
    )
    held_credentials = {}

    def guard():
        _current_ancestors(ancestors)
        _current_ancestors(public_ancestors)
        current(source)
        for tool in tools:
            current(tool)
        for credential in held_credentials.values():
            current(credential)

    deadline = time.monotonic() + 30
    before = _search(deadline, guard)
    record = {
        "schema": 1,
        "root": list(_stamp(root.lstat())),
        "before": list(before),
        "keychain": None,
        "files": {},
    }
    _state(root, record)
    password = secrets.token_urlsafe(32)
    env = os.environ.copy()
    env["ERGOPTI_TEST_ONLY_KEY_PASSWORD"] = password
    keychain = root / "fixture.keychain-db"
    config = (
        b"[req]\ndistinguished_name=subject\nprompt=no\nx509_extensions=code_signing\n"
        b"[subject]\nCN=ErgoptiPlus Disposable Runtime Signing TEST ONLY\n"
        b"[code_signing]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\n"
        b"extendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n"
    )
    _write(root / "openssl.cnf", config, 0o600)
    held_credentials["openssl.cnf"] = ordinary(root / "openssl.cnf", 0o600)
    require(held_credentials["openssl.cnf"].data == config, "credential_changed")
    record["files"]["openssl.cnf"] = list(held_credentials["openssl.cnf"].identity)
    _state(root, record)

    def normalize_output(name, mode):
        # Capture the producer result before ANY subsequent foreign port.
        # Normalize its mode through the same held inode, never a fresh path.
        guard()
        original = ordinary(root / name)
        require(original.identity[3] in (0o600, 0o644), "credential_mode")
        descriptor = os.open(original.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            require(_full(os.fstat(descriptor)) == original.identity, "credential_changed")
            os.fchmod(descriptor, mode)
            changed = os.fstat(descriptor)
            require(
                _stamp(changed)[:3] == original.identity[:3]
                and changed.st_nlink == 1
                and changed.st_size == original.identity[4]
                and changed.st_mtime_ns == original.identity[5],
                "credential_changed",
            )
            captured = ordinary(original.path, mode)
            require(
                captured.identity == _full(changed) and captured.data == original.data,
                "credential_changed",
            )
        finally:
            os.close(descriptor)
        return captured

    def capture_output(name, mode):
        captured = normalize_output(name, mode)
        held_credentials[name] = captured
        record["files"][name] = list(captured.identity)
        _state(root, record)
        guard()

    command(
        [
            "/usr/bin/openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:3072",
            "-sha256",
            "-days",
            "1",
            "-config",
            str(root / "openssl.cnf"),
            "-keyout",
            str(root / "private-key.pem"),
            "-passout",
            "env:ERGOPTI_TEST_ONLY_KEY_PASSWORD",
            "-out",
            str(root / "certificate.pem"),
        ],
        deadline,
        guard,
        env,
    )
    capture_output("private-key.pem", 0o600)
    capture_output("certificate.pem", 0o600)
    version = command(["/usr/bin/openssl", "version"], deadline, guard)[0]
    require(version.startswith((b"LibreSSL ", b"OpenSSL 3.")), "openssl_version")
    args = [
        "/usr/bin/openssl",
        "pkcs12",
        "-export",
        "-in",
        str(root / "certificate.pem"),
        "-inkey",
        str(root / "private-key.pem"),
        "-passin",
        "env:ERGOPTI_TEST_ONLY_KEY_PASSWORD",
        "-passout",
        "env:ERGOPTI_TEST_ONLY_KEY_PASSWORD",
        "-keypbe",
        "PBE-SHA1-3DES",
        "-certpbe",
        "PBE-SHA1-3DES",
        "-out",
        str(root / "identity.p12"),
    ]
    if version.startswith(b"OpenSSL 3."):
        args += ["-macalg", "sha1"]
    command(args, deadline, guard, env)
    capture_output("identity.p12", 0o600)
    command(
        [
            "/usr/bin/openssl",
            "x509",
            "-in",
            str(root / "certificate.pem"),
            "-outform",
            "DER",
            "-out",
            str(root / "public-leaf.der"),
        ],
        deadline,
        guard,
    )
    capture_output("public-leaf.der", 0o644)
    require(not os.path.lexists(keychain), "collision")
    command(
        ["/usr/bin/security", "create-keychain", "-p", password, str(keychain)], deadline, guard
    )
    captured_keychain = normalize_output("fixture.keychain-db", 0o600)
    # The database may legitimately change; retain its fixed inode/owner/mode only.
    record["keychain"] = list(captured_keychain.identity[:4])
    _state(root, record)

    def credentials_current():
        guard()
        require(_stamp(keychain.lstat()) == tuple(record["keychain"]), "keychain_changed")
        for name, identity in record["files"].items():
            require(
                ordinary(root / name, identity[3]).identity == tuple(identity), "credential_changed"
            )

    command(
        ["/usr/bin/security", "set-keychain-settings", "-lut21600", str(keychain)],
        deadline,
        credentials_current,
    )
    command(
        ["/usr/bin/security", "unlock-keychain", "-p", password, str(keychain)],
        deadline,
        credentials_current,
    )
    command(
        [
            "/usr/bin/security",
            "import",
            str(root / "identity.p12"),
            "-k",
            str(keychain),
            "-f",
            "pkcs12",
            "-P",
            password,
            "-T",
            "/usr/bin/codesign",
        ],
        deadline,
        credentials_current,
    )
    command(
        [
            "/usr/bin/security",
            "set-key-partition-list",
            "-S",
            "apple-tool:,apple:,codesign:",
            "-s",
            "-k",
            password,
            str(keychain),
        ],
        deadline,
        credentials_current,
    )
    leaf = ordinary(root / "public-leaf.der", 0o644)
    identity = hashlib.sha1(leaf.data).hexdigest().upper()
    out, _ = command(
        ["/usr/bin/security", "find-identity", "-p", "codesigning", str(keychain)],
        deadline,
        credentials_current,
    )
    identities = re.findall(rb"^\s*[0-9]+\) ([A-Fa-f0-9]{40}) ", out, re.M)
    require(len(identities) == 1 and identities[0].decode().upper() == identity, "identity")
    require(
        search_unchanged(before, _search(deadline, credentials_current), str(keychain)),
        "search_changed",
    )
    for name in ("openssl.cnf", "private-key.pem", "certificate.pem", "identity.p12"):
        current(held_credentials[name])
        (root / name).unlink()
        del record["files"][name]
        del held_credentials[name]
    env.pop("ERGOPTI_TEST_ONLY_KEY_PASSWORD", None)
    password = None
    _state(root, record)
    guard()
    current(leaf)
    _write(public / "public-leaf.der", leaf.data, 0o644)
    return public_record(identity, hashlib.sha256(leaf.data).hexdigest())


def cleanup(root):
    require(supported(sys.platform), "platform")
    root = Path(root)
    ancestors = _ancestors(root)
    state = ordinary(root / ".state.json", 0o600, 65536)

    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "state")
            result[key] = value
        return result

    record = json.loads(state.data, object_pairs_hook=unique)
    require(
        type(record) is dict
        and type(record.get("files")) is dict
        and type(record.get("before")) is list,
        "state",
    )
    permitted = {
        "openssl.cnf",
        "private-key.pem",
        "certificate.pem",
        "identity.p12",
        "public-leaf.der",
    }
    require(set(record["files"]) <= permitted, "state")
    require(
        all(
            type(v) is str and Path(v).is_absolute() and ".." not in Path(v).parts
            for v in record["before"]
        )
        and len(set(record["before"])) == len(record["before"]),
        "state",
    )
    for values in [record.get("root"), record.get("keychain")] + list(record["files"].values()):
        require(
            type(values) is list
            and len(values) in (4, 8)
            and all(type(v) is int and v >= 0 for v in values),
            "state",
        )
    require(
        set(record) == {"schema", "root", "before", "keychain", "files"}
        and type(record["schema"]) is int
        and record["schema"] == 1
        and tuple(record["root"]) == _stamp(root.lstat()),
        "state",
    )
    require(record["keychain"] is not None, "cleanup_unknown")
    keychain = root / "fixture.keychain-db"
    require(
        _stamp(keychain.lstat()) == tuple(record["keychain"])
        and stat.S_ISREG(keychain.lstat().st_mode),
        "keychain_changed",
    )
    known = {".state.json", "fixture.keychain-db"} | set(record["files"])
    observed = set()
    with os.scandir(root) as entries:
        for entry in entries:
            require(
                len(observed) < len(known) and entry.name in known and entry.name not in observed,
                "cleanup_inventory",
            )
            observed.add(entry.name)
    require(observed == known, "cleanup_inventory")
    held = [ordinary(root / name, identity[3]) for name, identity in record["files"].items()]
    require(
        all(item.identity == tuple(record["files"][item.path.name]) for item in held),
        "credential_changed",
    )
    source = ordinary(Path(__file__).resolve(), limit=1024 * 1024)
    tools = tuple(ordinary(Path(path), owned=False) for path in _NATIVE)

    def guard():
        _current_ancestors(ancestors)
        current(state)
        current(source)
        for tool in tools:
            current(tool)
        for item in held:
            current(item)

    deadline = time.monotonic() + 30
    before = list(record["before"])
    pre = _search(deadline, guard)
    clean = search_unchanged(before, pre, str(keychain))
    delete_cuts = 0

    def delete_guard():
        nonlocal delete_cuts
        guard()
        if delete_cuts == 0:
            require(
                _stamp(keychain.lstat()) == tuple(record["keychain"])
                and stat.S_ISREG(keychain.lstat().st_mode),
                "keychain_changed",
            )
        else:
            require(not os.path.lexists(keychain), "cleanup_refused")
        delete_cuts += 1

    command(["/usr/bin/security", "delete-keychain", str(keychain)], deadline, delete_guard)
    require(not os.path.lexists(keychain), "cleanup_refused")
    post = _search(deadline, guard)
    # Never reset search lists: foreign changes fail qualification, even after own deletion.
    require(
        foreign_list(pre, str(keychain)) == post and tuple(before) == post and clean,
        "search_changed",
    )
    for item in held:
        current(item)
        item.path.unlink()
    current(state)
    state.path.unlink()
    root.rmdir()
    require(not os.path.lexists(root), "cleanup_refused")
    return {"schema": 1, "status": "removed", "test_only": True}


# These literal policy codes are the complete reviewed fixture vocabulary.
# Unknown exception payloads never become public diagnostics.
_CLOSED_REFUSAL_CODES = frozenset(
    (
        "ancestry",
        "ancestry_changed",
        "arguments",
        "cleanup_inventory",
        "cleanup_refused",
        "cleanup_unknown",
        "collision",
        "command",
        "credential_changed",
        "credential_mode",
        "deadline",
        "file",
        "file_changed",
        "file_size",
        "identity",
        "keychain_changed",
        "keychain_list",
        "mode",
        "native_command",
        "openssl_version",
        "path",
        "platform",
        "private_in_evidence",
        "record",
        "root",
        "search_changed",
        "state",
    )
)


def _diagnostic_code(error):
    """Return only fixed public policy literals, never exception text or arguments."""
    if isinstance(error, FixtureRefusal):
        code = error.code
        return code if type(code) is str and code in _CLOSED_REFUSAL_CODES else "unknown_refusal"
    return "system_io" if isinstance(error, OSError) else "invalid_value"


def _ancestry_failure_observation(error):
    """Decode fixed failure metadata without paths, credential bytes or new native reads."""
    try:
        if type(error) is not FixtureRefusal or error.code != "ancestry":
            return None
        stage = getattr(error, "ancestry_stage", None)
        check = getattr(error, "ancestry_check", None)
        if type(stage) is not str or stage not in (
            "public_ancestry",
            "private_creation",
            "fixture_source",
            "native_tools",
        ):
            return None
        if type(check) is not str or check not in ("canonical_path", "ancestor_directory"):
            return None
        return {
            "schema": 1,
            "kind": "test_only_signer_ancestry_failure_observation",
            "authority": False,
            "native_verdict": "unchanged",
            "stage": stage,
            "check": check,
        }
    except Exception:
        return None


def main(args):
    try:
        require(len(args) in (2, 3), "arguments")
        if args[0] == "setup" and len(args) == 3:
            record = setup(Path(args[1]), Path(args[2]))
        elif args[0] == "cleanup" and len(args) == 2:
            record = cleanup(Path(args[1]))
        else:
            raise FixtureRefusal("arguments")
        print(json.dumps(record, sort_keys=True))
        return 0
    except (FixtureRefusal, OSError, ValueError) as error:
        # No raw error, command arguments, private paths or subprocess output.
        print(
            "Native signing TEST-ONLY fixture refused: " + _diagnostic_code(error), file=sys.stderr
        )
        observation = _ancestry_failure_observation(error)
        if observation is not None:
            print(
                "ERGOPTI_SIGNER_ANCESTRY_DIAGNOSTIC "
                + json.dumps(observation, sort_keys=True, separators=(",", ":")),
                file=sys.stderr,
            )
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
