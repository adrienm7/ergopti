#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_updater_archive_pipeline.py
"""First genuine archive chain. Source-only until guardian/runner peer review."""

from __future__ import annotations
import argparse
import hashlib
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socketserver
import ssl
import stat
import tarfile
import threading

BEFORE = b"Independent prior installation bytes\n"
AFTER = b"Independent verified replacement bytes\0\n"
REDIRECT = b"Intermediate body MUST NOT enter final retained archive\n" * 3
MARKER = "linux/pipeline-independent-corpus.bin"
MODES = ("happy", "wrong_digest", "smoke_rollback")
SMOKE_RECEIPT = b"ERGOPTI_PIPELINE_SMOKE_EXECUTED_EXIT42\n"


def ordinary(path: Path) -> bytes:
    fact = path.lstat()
    if not stat.S_ISREG(fact.st_mode) or path.is_symlink():
        raise RuntimeError("Ordinary admitted source required")
    return path.read_bytes()


def inventory(root: Path) -> str:
    rows = []
    for path in sorted(root.rglob("*")):
        fact = path.lstat()
        if path.is_symlink() or not (stat.S_ISREG(fact.st_mode) or stat.S_ISDIR(fact.st_mode)):
            raise RuntimeError("Native payload contains unadmitted alias/special file")
        if stat.S_ISREG(fact.st_mode):
            rows.append(
                [
                    path.relative_to(root).as_posix(),
                    fact.st_mode & 0o777,
                    hashlib.sha256(path.read_bytes()).hexdigest(),
                ]
            )
    rows.sort(key=lambda row: row[0].encode("utf-8"))
    return hashlib.sha256(json.dumps(rows, separators=(",", ":")).encode()).hexdigest()


def tree_identity(root: Path) -> tuple:
    """Independent prior inode/path/mode/content snapshot, including directories."""
    rows = []
    for path in [root, *sorted(root.rglob("*"))]:
        fact = path.lstat()
        if path.is_symlink() or not (stat.S_ISREG(fact.st_mode) or stat.S_ISDIR(fact.st_mode)):
            raise RuntimeError("Rollback prior tree contains alias or special file")
        rows.append(
            (
                path.relative_to(root).as_posix(),
                fact.st_dev,
                fact.st_ino,
                stat.S_IFMT(fact.st_mode),
                stat.S_IMODE(fact.st_mode),
                fact.st_uid,
                fact.st_gid,
                hashlib.sha256(ordinary(path)).hexdigest() if stat.S_ISREG(fact.st_mode) else None,
            )
        )
    rows.sort(key=lambda row: row[0].encode("utf-8"))
    return tuple(rows)


def smoke_launcher(observation: Path) -> bytes:
    """Literal ordinary replacement executable, no production operation substitute."""
    if not observation.is_absolute():
        raise RuntimeError("Private smoke observation path must be absolute")
    return (
        "#!/bin/sh\nprintf '%s\\n' 'ERGOPTI_PIPELINE_SMOKE_EXECUTED_EXIT42' > "
        + shlex.quote(str(observation))
        + " || exit 43\nexit 42\n"
    ).encode("utf-8")


def marker_identity(path: Path) -> tuple:
    fact = path.lstat()
    if (
        not stat.S_ISREG(fact.st_mode)
        or path.is_symlink()
        or fact.st_uid != os.getuid()
        or stat.S_IMODE(fact.st_mode) != 0o600
        or fact.st_nlink != 1
    ):
        raise RuntimeError("Exact private ordinary smoke marker refused")
    return (fact.st_dev, fact.st_ino, stat.S_IMODE(fact.st_mode), fact.st_uid, fact.st_nlink)


def prefix_input(payload: Path, prefix: Path) -> Path:
    """Private test input, not install.sh/permission setup qualification."""
    installed = prefix / "lib/ergopti"
    installed.parent.mkdir(parents=True, mode=0o700)
    shutil.copytree(payload, installed)
    (installed / MARKER).write_bytes(BEFORE)
    # Project ONLY the genuine installer's launcher template path substitution.
    # Actual updater replacement/smoke remains the original DEFAULT_OPS.
    source = ordinary(payload / "install.sh").decode()
    start = 'cat > "${BIN_DIR}/ergopti-hotstrings" << WRAPPER\n'
    if source.count(start) != 1:
        raise RuntimeError("Canonical standalone wrapper constructor unavailable")
    template = source.split(start, 1)[1].split("\nWRAPPER\n", 1)[0] + "\n"
    substitution = "$(printf '%q' \"${LIB_DIR}\")"
    if (
        template.count(substitution) != 1
        or "\\${INSTALL_ROOT}/bin/ergopti-hotstrings" not in template
    ):
        raise RuntimeError("Standalone template input refused")
    wrapper = template.replace(substitution, shlex.quote(str(installed)))
    wrapper = wrapper.replace(r"\${INSTALL_ROOT}", "${INSTALL_ROOT}").replace(r"\$@", "$@")
    (prefix / "bin").mkdir(mode=0o700)
    launcher = prefix / "bin/ergopti-hotstrings"
    launcher.write_text(wrapper)
    launcher.chmod(0o755)
    return installed


def corpus(payload: Path, smoke_observation: Path | None = None) -> bytes:
    """Independent literal marker and archive bytes, before production hashing."""
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz", format=tarfile.PAX_FORMAT) as archive:
        for name in ("linux", "_shared", "bin", "install.sh"):
            source = payload / name
            paths = [source, *sorted(source.rglob("*"))] if source.is_dir() else [source]
            for path in paths:
                rel = path.relative_to(payload).as_posix()
                info = archive.gettarinfo(str(path), arcname=rel)
                if not (info.isdir() or info.isfile()):
                    raise RuntimeError(
                        "Independent native corpus only admits ordinary payload entries"
                    )
                # Deterministic caller-owned corpus metadata, no synthetic version.
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = 0
                if rel == MARKER:
                    continue
                if smoke_observation is not None and rel == "bin/ergopti-hotstrings":
                    launcher = smoke_launcher(smoke_observation)
                    info.size, info.mode = len(launcher), 0o755
                    archive.addfile(info, io.BytesIO(launcher))
                    continue
                if info.isfile():
                    with path.open("rb") as source_file:
                        archive.addfile(info, source_file)
                else:
                    archive.addfile(info)
        marker = tarfile.TarInfo(MARKER)
        marker.size, marker.mode, marker.mtime = len(AFTER), 0o600, 0
        archive.addfile(marker, io.BytesIO(AFTER))
    return output.getvalue()


RETAINED_TLS_OWNERS = []  # Exact acquired owners survive constructor/cleanup refusal.


class Origin(http.server.ThreadingHTTPServer):
    daemon_threads = False
    block_on_close = False  # Each exact request thread has its own bounded join.

    def __init__(self, address, handler):
        self.thread_owners, self.socket_owners, self.refusals = [], [], []
        self.owner_lock = threading.RLock()
        self.server_stop = threading.Event()
        self.server_entered = threading.Event()
        self.server_retired = threading.Event()
        self.server_thread, self.closed_owned = None, False
        self.listener_state = "constructing"
        RETAINED_TLS_OWNERS.append(self)  # Before socket/bind/listen acquisition.
        try:
            super().__init__(address, handler, bind_and_activate=False)
            self.listener_state = "open"
            self.timeout = 0.05
            self.server_bind()
            self.server_activate()
        except BaseException as primary:
            try:
                self.close_owned()
            except BaseException as cleanup:
                if hasattr(primary, "add_note"):
                    primary.add_note(str(cleanup))
            raise

    def server_bind(self):
        # HTTPServer's decorative getfqdn is not native listener admission.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = str(self.server_address[0]), self.server_address[1]

    def get_request(self):
        connection, address = super().get_request()
        record = {
            "socket": connection,
            "raw": connection,
            "closed": False,
            "closing": False,
            "uncertain": False,
            "wrap_attempted": False,
        }
        self.socket_owners.append(record)  # Before timeout/TLS native reads.
        try:
            connection.settimeout(5)
            record["wrap_attempted"] = True
            wrapped = self.context.wrap_socket(
                connection, server_side=True, do_handshake_on_connect=False
            )
            record["socket"] = wrapped  # Retain returned ownership before handshake.
            wrapped.settimeout(5)
            wrapped.do_handshake()
            return wrapped, address
        except BaseException as primary:
            self.refusals.append("ACCEPTED_TLS_SETUP_FAILED")
            if (
                record["socket"] is connection
                and record["wrap_attempted"]
                and connection.fileno() == -1
            ):
                record["uncertain"] = True
                self.refusals.append("TLS_CONSTRUCTOR_OWNER_UNCERTAIN")
            try:
                self.close_request(record["socket"])
            except BaseException as cleanup:
                if hasattr(primary, "add_note"):
                    primary.add_note(str(cleanup))
            raise

    def close_request(self, request):
        with self.owner_lock:
            record = next((item for item in self.socket_owners if item["socket"] is request), None)
            if record is None:
                self.refusals.append("SOCKET_OWNER_MISSING")
                return
            if record["closed"] or record["closing"] or record["uncertain"]:
                return
            record["closing"] = True  # One destructive close, never a guessed FD.
        try:
            request.close()
            if request.fileno() != -1:
                raise RuntimeError("Actual socket close acknowledgement refused")
            record["closed"] = True
        except BaseException:
            record["uncertain"] = True
            self.refusals.append("SOCKET_CLOSE_REFUSED")
        finally:
            record["closing"] = False

    def handle_error(self, request, client_address):
        self.refusals.append("HANDLER_FAILED")  # No peer/header/body diagnostic.

    def start_record(self, target, args, server_role=False):
        record = {
            "thread": None,
            "attempted": False,
            "acknowledged": False,
            "uncertain": False,
            "entered": threading.Event(),
            "retired": threading.Event(),
        }
        self.thread_owners.append(record)

        def owned_target():
            record["entered"].set()
            try:
                target(*args)
            finally:
                record["retired"].set()

        record["thread"] = threading.Thread(target=owned_target, daemon=False)
        if server_role:
            self.server_thread = record["thread"]
        record["attempted"] = True
        try:
            record["thread"].start()
            record["acknowledged"] = True
        except BaseException:
            record["uncertain"] = True
            self.refusals.append("THREAD_START_UNCERTAIN")
            raise
        return record["thread"]

    def process_request(self, request, client_address):
        self.start_record(self.process_request_thread, (request, client_address))

    def serve_owned(self):
        self.server_entered.set()
        try:
            while not self.server_stop.is_set():
                self.handle_request()  # Same actual handler API, bounded accept/TLS.
        except BaseException:
            self.refusals.append("SERVER_TARGET_FAILED")
        finally:
            self.server_retired.set()

    def start_owned(self):
        return self.start_record(self.serve_owned, (), server_role=True)

    def close_owned(self):
        if self.closed_owned:
            return
        errors = []
        self.server_stop.set()  # Safe even before a delayed target enters.

        # Join the exact server role first, then a bounded snapshot of handlers.
        def join(record):
            thread = record["thread"]
            try:
                if thread is None:
                    errors.append("THREAD_CONSTRUCTOR_UNCERTAIN")
                elif record["acknowledged"] or record["entered"].is_set():
                    thread.join(timeout=7)
                    if thread.is_alive() or not record["retired"].is_set():
                        errors.append("THREAD_RETIREMENT_PENDING")
                elif record["attempted"]:
                    errors.append("THREAD_START_UNCERTAIN")
            except BaseException:
                errors.append("THREAD_JOIN_REFUSED")

        for record in tuple(self.thread_owners):
            if record["thread"] is self.server_thread:
                join(record)
        if self.server_thread is not None and not self.server_retired.is_set():
            errors.append("SERVER_TARGET_RETIREMENT_PENDING")
        for record in tuple(self.thread_owners):
            if record["thread"] is not self.server_thread:
                join(record)
        # Listener retirement is independent of every join failure. Disabling
        # ThreadingMixIn's join prevents an unbounded hidden second wait.
        if self.listener_state == "open":
            self.listener_state = "closing"
            try:
                self.server_close()
                if self.socket.fileno() != -1:
                    raise RuntimeError("Actual listener close acknowledgement refused")
                self.listener_state = "closed"
            except BaseException:
                self.listener_state = "uncertain"
                errors.append("LISTENER_CLOSE_REFUSED")
        elif self.listener_state != "closed":
            errors.append("LISTENER_CONSTRUCTOR_UNCERTAIN")
        for record in tuple(self.socket_owners):
            if not record["closed"] and not record["uncertain"]:
                self.close_request(record["socket"])
        errors.extend(self.refusals)
        if errors or any(not item["closed"] for item in self.socket_owners):
            raise RuntimeError("Owned TLS resource retirement refused")
        self.closed_owned = True
        RETAINED_TLS_OWNERS.remove(self)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.observed.append(self.path)
        mode, phase = self.path.strip("/").split("/", 1)
        if mode not in MODES:
            raise RuntimeError("Unexpected actual native route")
        selected_archive = (
            self.server.rollback_archive if mode == "smoke_rollback" else self.server.archive
        )
        digest = (
            "0" * 64 if mode == "wrong_digest" else hashlib.sha256(selected_archive).hexdigest()
        )
        body = (
            (digest + "  ergopti-plus-linux.tar.gz\n").encode()
            if phase == "checksum"
            else REDIRECT
            if phase == "archive"
            else selected_archive
        )
        self.send_response(302 if phase == "archive" else 200)
        if phase == "archive":
            self.send_header("Location", "/" + mode + "/final")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--payload", type=Path, required=True)
    parser.add_argument("--expected-payload-inventory", required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--luajit", type=Path, required=True)
    parser.add_argument("--bash", type=Path, required=True)
    parser.add_argument("--expected-bash-sha256", required=True)
    parser.add_argument("--lua-fixture", type=Path, required=True)
    parser.add_argument("--expected-lua-sha256", required=True)
    parser.add_argument("--guardian", type=Path, required=True)
    parser.add_argument("--expected-guardian-sha256", required=True)
    parser.add_argument("--certificate", type=Path, required=True)
    parser.add_argument("--key", type=Path, required=True)
    args = parser.parse_args()
    for value in (
        args.expected_payload_inventory,
        args.expected_lua_sha256,
        args.expected_guardian_sha256,
        args.expected_bash_sha256,
    ):
        if re.fullmatch(r"[0-9a-f]{64}", value) is None:
            raise RuntimeError("Exact source admission required")
    for path in (
        args.payload,
        args.work,
        args.luajit,
        args.bash,
        args.lua_fixture,
        args.guardian,
        args.certificate,
        args.key,
    ):
        if not path.is_absolute():
            raise RuntimeError("Absolute owned native inputs required")
    bash = ordinary(args.bash)
    if bash[:4] != b"\x7fELF" or hashlib.sha256(bash).hexdigest() != args.expected_bash_sha256:
        raise RuntimeError("Actual canonical Bash source admission refused")
    if not os.access(args.bash, os.X_OK):
        raise RuntimeError("Actual canonical Bash is not executable")
    if inventory(args.payload) != args.expected_payload_inventory:
        raise RuntimeError("Canonical owner-built payload inventory refused")
    if hashlib.sha256(ordinary(args.lua_fixture)).hexdigest() != args.expected_lua_sha256:
        raise RuntimeError("Native Lua source identity refused")
    raw_guardian = ordinary(args.guardian)
    if hashlib.sha256(raw_guardian).hexdigest() != args.expected_guardian_sha256:
        raise RuntimeError("Original native guardian source identity refused")
    native = ordinary(args.payload / "linux/bin/libergopti_archive_publication.so")
    if native[:4] != b"\x7fELF":
        raise RuntimeError("Canonical backend was not built for actual target")
    if ordinary(args.payload / "bin/ergopti-hotstrings") != ordinary(
        args.payload / "linux/install/standalone_launcher.sh"
    ):
        raise RuntimeError("Actual versioned standalone launcher required")
    stamp = ordinary(args.payload / "_shared/build_stamp.txt").decode()
    versions = re.findall(
        r"^version=([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)$", stamp, flags=re.M
    )
    if len(versions) != 1:
        raise RuntimeError("Genuine generated release build stamp required")
    tag = "v" + versions[0]
    spec = importlib.util.spec_from_file_location(
        "pipeline_original_native_guardian", args.guardian
    )
    guardian = importlib.util.module_from_spec(spec)
    # This is the original sole guardian, source-admitted before its constructor.
    exec(compile(raw_guardian, str(args.guardian), "exec"), guardian.__dict__)
    args.work.mkdir(mode=0o700)  # Refuse reuse, retain failed evidence for owner.
    archive = corpus(args.payload)
    server, thread = None, None
    primary = None
    touched = [
        "TMPDIR",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_CACHE_HOME",
        "XDG_STATE_HOME",
        "XDG_RUNTIME_DIR",
        "CURL_CA_BUNDLE",
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
    ]
    saved_environment = {name: os.environ.get(name) for name in touched}
    completed = []
    try:
        server = Origin(("127.0.0.1", 0), Handler)
        server.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server.context.load_cert_chain(args.certificate, args.key)
        server.archive, server.digest, server.observed = (
            archive,
            hashlib.sha256(archive).hexdigest(),
            [],
        )
        thread = server.start_owned()
        for mode in MODES:
            work = args.work / mode
            work.mkdir(mode=0o700)
            smoke_observation, smoke_identity = None, None
            if mode == "smoke_rollback":
                smoke_observation = work / "smoke-executed.receipt"
                with smoke_observation.open("xb") as marker:
                    smoke_observation.chmod(0o600)
                    marker.flush()
                    os.fsync(marker.fileno())
                smoke_identity = marker_identity(smoke_observation)
                if ordinary(smoke_observation) != b"":
                    raise RuntimeError("Smoke observation must start empty")
                server.rollback_archive = corpus(args.payload, smoke_observation)
            prefix = work / "prefix"
            installed = prefix_input(args.payload, prefix)
            # The genuine previous ownership producer records the fixture input.
            if (
                guardian.main(
                    [
                        str(args.bash),
                        str(installed / "linux/install/ownership.sh"),
                        str(installed / "linux"),
                        str(installed / "_shared"),
                        str(installed),
                    ]
                )
                != 0
            ):
                raise RuntimeError("Actual initial ownership manifest producer failed")
            original = inventory(installed)
            original_tree = tree_identity(installed) if mode == "smoke_rollback" else None
            for name in touched:
                os.environ.pop(name, None)
            for name in (
                "TMPDIR",
                "XDG_CONFIG_HOME",
                "XDG_DATA_HOME",
                "XDG_CACHE_HOME",
                "XDG_STATE_HOME",
                "XDG_RUNTIME_DIR",
            ):
                directory = work / name.lower()
                directory.mkdir(mode=0o700)
                os.environ[name] = str(directory)
            os.environ["CURL_CA_BUNDLE"] = str(args.certificate)
            config = work / "fixture-config.toml"
            config.write_bytes(b"")
            config.chmod(0o600)
            start = len(server.observed)
            status = guardian.main(
                [
                    str(args.luajit),
                    str(args.lua_fixture),
                    str(prefix),
                    f"https://127.0.0.1:{server.server_port}",
                    mode,
                    tag,
                    str(config),
                ]
            )
            if status != 0:
                raise RuntimeError("Actual native chain failed; original fixture evidence retained")
            if server.observed[start:] != [
                f"/{mode}/checksum",
                f"/{mode}/archive",
                f"/{mode}/final",
            ]:
                raise RuntimeError(
                    "Actual checksum/streaming redirect route was incomplete or repeated"
                )
            if mode == "happy":
                if (
                    ordinary(installed / MARKER) != AFTER
                    or ordinary(Path(str(installed) + ".old") / MARKER) != BEFORE
                ):
                    raise RuntimeError(
                        "Actual replacement/retained rollback bytes failed independent corpus"
                    )
                if not (installed / ".ergopti-owned-files").is_file():
                    raise RuntimeError("Actual DEFAULT_OPS ownership receipt missing")
            elif mode == "smoke_rollback":
                if (
                    smoke_observation is None
                    or marker_identity(smoke_observation) != smoke_identity
                    or ordinary(smoke_observation) != SMOKE_RECEIPT
                ):
                    raise RuntimeError(
                        "Actual replacement smoke execution receipt absent or foreign"
                    )
                if (
                    ordinary(installed / MARKER) != BEFORE
                    or inventory(installed) != original
                    or tree_identity(installed) != original_tree
                ):
                    raise RuntimeError(
                        "Smoke failure did not restore whole prior inode/path/mode/content tree"
                    )
                if Path(str(installed) + ".old").exists():
                    raise RuntimeError("Smoke rollback left original root in backup namespace")
            elif inventory(installed) != original or Path(str(installed) + ".old").exists():
                raise RuntimeError("Wrong digest mutated prior installation or published backup")
            if list((work / "tmpdir").iterdir()) or any(
                p.name.startswith(".ergopti-update.") for p in installed.parent.iterdir()
            ):
                raise RuntimeError("Actual archive/install namespace cleanup remains pending")
            completed.append(mode)
    except BaseException as error:
        primary = error
    finally:
        cleanup = None
        if server is not None:
            try:
                server.close_owned()
            except BaseException as error:
                cleanup = error
        for name, value in saved_environment.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
        if primary is not None:
            if cleanup is not None and hasattr(primary, "add_note"):
                primary.add_note(str(cleanup))
            raise primary
        if cleanup is not None:
            raise cleanup
    if tuple(completed) != MODES or inventory(args.payload) != args.expected_payload_inventory:
        raise RuntimeError("Whole fixed source/native case floor refused")
    print("PIPELINE_NATIVE_RESULT cases=3 checks=15 failed=0 skipped=0 closure=complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
