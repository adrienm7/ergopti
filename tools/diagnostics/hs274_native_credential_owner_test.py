# tools/diagnostics/hs274_native_credential_owner_test.py
"""Physical IPC/FS owner controls; native Security and compiler are unqualified.

The fixed native endpoint is modeled solely inside this separate control
process. Production CLI has no alternate provider. Old signer47 stays whole.
"""

from array import array
from contextlib import contextmanager
import errno
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import hs274_native_credential_owner as owner


def load_legacy():
    specification = importlib.util.spec_from_file_location(
        "credential_controls_original", Path(__file__).with_name("hs274_native_signing_fixture.py")
    )
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


LEGACY = load_legacy()


def producer(root):
    """Separate physical process; real socket/frame/SCM_RIGHTS and private FDs."""
    kind = root.name
    channel = socket.socket(fileno=0)
    payload = bytearray()
    while len(payload) < 61:
        part = channel.recv(61 - len(payload))
        if not part:
            os._exit(2)
        payload.extend(part)
    if bytes(payload) != owner.native_frame("A" * 43, b"P", b"D"):
        os._exit(3)
    database = root / owner.DATABASE_NAME
    database.write_bytes(b"independent native database fixture\n")
    database.chmod(0o600)
    lock = root / owner.LOCK_NAME
    lock.write_bytes(b"")
    lock.chmod(0o600)
    route = database
    if kind == "same-bytes":
        route = root / "foreign"
        route.write_bytes(database.read_bytes())
        route.chmod(0o600)
    if kind == "mode":
        database.chmod(0o644)
    if kind == "links":
        os.link(database, root / "foreign")
    if kind == "directory":
        route = root
    descriptor = (
        os.dup(channel.fileno())
        if kind == "socket"
        else os.open(route, os.O_WRONLY if kind == "writable" else os.O_RDONLY)
    )
    nonce = os.urandom(32)
    challenge = b"F" + nonce
    descriptors = [] if kind == "no-fd" else [descriptor]
    if kind == "two-fd":
        descriptors.append(os.open(database, os.O_RDONLY))
    ancillary = (
        [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array("i", descriptors))] if descriptors else []
    )
    if kind == "fragmented":
        channel.sendall(challenge[:7])
        channel.sendmsg([challenge[7:]], ancillary)
    else:
        channel.sendmsg([challenge], ancillary)
    if kind == "no-fd":
        os._exit(0)
    acknowledged = bytearray()
    while len(acknowledged) < 33:
        part = channel.recv(33 - len(acknowledged))
        if not part:
            os._exit(4)
        acknowledged.extend(part)
    if bytes(acknowledged) != b"A" + nonce:
        os._exit(5)
    if kind == "alive":
        time.sleep(2)
    if kind == "nonzero":
        os._exit(6)
    if kind == "extra":
        channel.sendmsg([b"X"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array("i", [descriptor]))])
    os._exit(0)


def delete_model(root, kind):
    """Only the test process can select this modeled native deletion endpoint."""
    if kind == "failed":
        os._exit(7)
    if kind == "timeout":
        time.sleep(2)
    if kind == "changed-data":
        (root / owner.DATABASE_NAME).write_bytes(b"foreign changed data")
    for name in (owner.DATABASE_NAME, owner.LOCK_NAME):
        if kind != "left-lock" or name != owner.LOCK_NAME:
            (root / name).unlink()
    if kind == "replacement":
        (root / owner.DATABASE_NAME).write_bytes(b"foreign replacement")
    if kind == "extra":
        (root / "unexpected").write_bytes(b"foreign")
    os._exit(0)


def journal_model(root, kind):
    journal = owner.PrivateJournal(LEGACY, root, lambda: None)
    record = {
        "schema": 2,
        "phase": "created",
        "root": [],
        "directories": {},
        "before": [],
        "files": {},
        "native": None,
        "custody": {},
    }
    for phase in owner.PrivateJournal.PHASES[:-1]:
        record["phase"] = phase
        journal.publish(record)
    if kind == "intermediate":
        journal.close()
        if journal.close_debt:
            os._exit(8)
        os._exit(0)
    record["phase"] = "ready"
    real_close = os.close
    real_replace = os.replace
    real_write = os.write
    real_open = os.open
    calls = []
    writers = {journal.descriptor: owner.full(os.fstat(journal.descriptor))[:4]}

    def open_writer(path, flags, mode=0o777, **keywords):
        descriptor = real_open(path, flags, mode, **keywords)
        if Path(path) == root / ".state.next" and flags & os.O_ACCMODE == os.O_WRONLY:
            writers[descriptor] = owner.full(os.fstat(descriptor))[:4]
        return descriptor

    def close(descriptor):
        if fcntl.fcntl(descriptor, fcntl.F_GETFL) & os.O_ACCMODE == os.O_WRONLY:
            calls.append(descriptor)
        real_close(descriptor)
        if kind in ("ambiguous", "marker-failed") and calls == [descriptor]:
            raise OSError(errno.EIO, "modeled ambiguous close")
        if kind == "old-ambiguous" and len(calls) == 2 and calls[-1] == descriptor:
            raise OSError(errno.EIO, "modeled ambiguous prior-writer close")

    def replace(source, destination):
        if kind == "foreign":
            foreign = root / ".foreign"
            foreign.write_bytes(Path(source).read_bytes())
            foreign.chmod(0o600)
            real_replace(foreign, source)
        # The writer closes are observed against real FDs; the operation itself
        # always uses the actual kernel, never a fake inode/stat return.
        if len(writers) != 2:
            raise AssertionError("Both original and next writer must be observed")
        for descriptor, observed in writers.items():
            try:
                actual = owner.full(os.fstat(descriptor))[:4]
                flags = fcntl.fcntl(descriptor, fcntl.F_GETFL)
            except OSError:
                continue
            if actual == observed and flags & os.O_ACCMODE == os.O_WRONLY:
                raise AssertionError("writer still open at Ready rename")
        real_replace(source, destination)

    def write(descriptor, data):
        if kind == "stdout-failed" and descriptor == 1:
            raise OSError(errno.EPIPE, "modeled failed stdout")
        return real_write(descriptor, data)

    try:
        with (
            mock.patch.object(owner.os, "close", close),
            mock.patch.object(owner.os, "replace", replace),
            mock.patch.object(owner.os, "write", write),
            mock.patch.object(owner.os, "open", open_writer),
        ):
            try:
                journal.finish_ready(record, b"ready\n", lambda: None, time.monotonic() + 3)
            finally:
                # A real os._exit must terminate without this independent
                # callback/unwind marker. The test never mocks termination.
                (root / ".unwound").write_bytes(b"unexpected unwind")
    except Exception:
        # Supplementary marker failure must not be required for strict refusal.
        if kind == "marker-failed":
            with mock.patch.object(
                owner.os, "open", side_effect=OSError(errno.EMFILE, "modeled exhaustion")
            ):
                try:
                    owner.record_setup_debt(root, owner.ancestry(root))
                except OSError:
                    pass
        os._exit(1)
    os._exit(9)


class CredentialOwnerControls(unittest.TestCase):
    @contextmanager
    def native(self, kind="healthy"):
        with tempfile.TemporaryDirectory(prefix="credential-owner-control-") as temporary:
            parent = Path(temporary).resolve()
            root = parent / kind
            root.mkdir(mode=0o700)
            image_path = parent / "producer"
            image_path.write_text(
                "#!"
                + sys.executable
                + "\nimport os,sys\nos.execv(sys.executable,[sys.executable,'-B',"
                + repr(str(Path(__file__).resolve()))
                + ",'producer',sys.argv[1]])\n",
                encoding="utf-8",
            )
            image_path.chmod(0o700)
            image = LEGACY.ordinary(image_path, 0o700)
            process = owner.NativeProcess(
                LEGACY,
                image,
                root,
                owner.fixed_environment(parent, parent),
                lambda: None,
                time.monotonic() + (0.6 if kind == "alive" else 4),
            )
            try:
                yield root, process
            finally:
                process.close()

    def healthy(self, kind="healthy"):
        with self.native(kind) as (root, process):
            reply = process.run("A" * 43, b"P", b"D")
            self.assertTrue(process.retired)
            self.assertEqual(process.process.returncode, 0)
            self.assertFalse(process.debt)
            self.assertEqual(
                os.fstat(reply.descriptor).st_ino, (root / owner.DATABASE_NAME).stat().st_ino
            )
            self.assertEqual(
                os.pread(reply.descriptor, len(reply.data) + 1, 0),
                b"independent native database fixture\n",
            )
            return True

    def refused_producer(self, kind):
        with self.native(kind) as (root, process):
            with self.assertRaises(Exception):
                process.run("A" * 43, b"P", b"D")
            self.assertTrue(process.debt)
            self.assertTrue((root / owner.DATABASE_NAME).exists())
            if process.process is not None:
                # An exhausted wrapper deadline retains Guardian retirement
                # debt. Test custody physically reaps only its own modeled
                # child; this is not credited as wrapper retirement authority.
                process.process.communicate(timeout=1)
                self.assertIsNotNone(process.process.poll())

    def test_p01_healthy(self):
        self.assertTrue(self.healthy())

    def test_p02_fragmented(self):
        self.assertTrue(self.healthy("fragmented"))

    def test_p03_missing_fd(self):
        self.refused_producer("no-fd")

    def test_p04_two_fds(self):
        self.refused_producer("two-fd")

    def test_p05_foreign_same_bytes(self):
        self.refused_producer("same-bytes")

    def test_p06_bad_fd_kind_mode_links(self):
        for kind in ("writable", "socket", "directory", "mode", "links"):
            with self.subTest(kind=kind):
                self.refused_producer(kind)

    def test_p07_replacement_after_admission(self):
        with self.native() as (root, process):
            reply = process.run("A" * 43, b"P", b"D")
            foreign = root / "foreign"
            foreign.write_bytes(reply.data)
            foreign.chmod(0o600)
            original = (root / owner.DATABASE_NAME).stat().st_ino
            foreign.replace(root / owner.DATABASE_NAME)
            replacement = (root / owner.DATABASE_NAME).stat().st_ino
            self.assertNotEqual(original, replacement)
            with self.assertRaises(owner.OwnerRefusal):
                reply.current()
            self.assertEqual((root / owner.DATABASE_NAME).stat().st_ino, replacement)

    def test_p08_alive_after_ack(self):
        self.refused_producer("alive")

    def test_p09_nonzero_after_ack(self):
        self.refused_producer("nonzero")

    def test_p10_extra_response_fd(self):
        self.refused_producer("extra")

    def test_p11_ancestor_replacement(self):
        with self.native() as (root, process):
            reply = process.run("A" * 43, b"P", b"D")
            root.rename(root.with_name("original"))
            root.mkdir(mode=0o700)
            with self.assertRaises(owner.OwnerRefusal):
                reply.current()
            self.assertEqual(list(root.iterdir()), [])

    def test_p12_reused_fd_not_closed(self):
        with self.native() as (root, process):
            reply = process.run("A" * 43, b"P", b"D")
            descriptor = reply.descriptor
            os.close(descriptor)
            foreign_path = root / "foreign"
            foreign_path.write_bytes(b"foreign")
            foreign = os.open(foreign_path, os.O_RDONLY)
            if foreign != descriptor:
                os.dup2(foreign, descriptor)
                os.close(foreign)
            try:
                reply.close()
                self.assertTrue(reply.close_debt)
                self.assertEqual(os.pread(descriptor, 7, 0), b"foreign")
            finally:
                os.close(descriptor)

    def test_p13_ambiguous_close_not_retried(self):
        with self.native() as (_, process):
            reply = process.run("A" * 43, b"P", b"D")
            target = reply.descriptor
            real_close = os.close
            attempted = []

            def close(descriptor):
                attempted.append(descriptor)
                real_close(descriptor)
                if descriptor == target:
                    raise OSError(errno.EIO, "modeled ambiguous close")

            with mock.patch.object(owner.os, "close", close):
                reply.close()
            self.assertTrue(reply.close_debt)
            self.assertEqual(attempted.count(target), 1)

    def cleanup_case(self, trigger, accepted=False):
        with self.native() as (root, process):
            reply = process.run("A" * 43, b"P", b"D")
            inventory = owner.FirstNativeInventory(root, reply, lambda: None)
            delete_calls = []
            foreign_search = ("/private/independent-user.keychain-db",)
            before_output = b'    "/private/independent-user.keychain-db"\n'
            endpoint = "healthy"
            if trigger == "lock-replacement":
                leaf = root / "foreign"
                leaf.write_bytes(b"")
                leaf.chmod(0o600)
                leaf.replace(root / owner.LOCK_NAME)
            elif trigger == "db-replacement":
                leaf = root / "foreign"
                leaf.write_bytes(reply.data)
                leaf.chmod(0o600)
                leaf.replace(root / owner.DATABASE_NAME)
            elif trigger == "metadata":
                (root / owner.LOCK_NAME).chmod(0o644)
            elif trigger == "content":
                (root / owner.LOCK_NAME).write_bytes(b"changed content")
            elif trigger == "mtime":
                info = (root / owner.LOCK_NAME).stat()
                os.utime(root / owner.LOCK_NAME, ns=(info.st_atime_ns, info.st_mtime_ns + 1))
            elif trigger == "nlink":
                os.link(root / owner.LOCK_NAME, root / "foreign-link")
            elif trigger == "extra-before":
                (root / "unexpected").write_bytes(b"foreign")
            elif trigger in (
                "failed",
                "timeout",
                "left-lock",
                "replacement",
                "extra",
                "changed-data",
            ):
                endpoint = trigger

            def command(arguments, deadline, guard, environment):
                guard()
                if arguments[1] == "list-keychains":
                    data = before_output
                    if (trigger == "search-before" and not delete_calls) or (
                        trigger == "search-after" and delete_calls
                    ):
                        data = b'    "/private/foreign-changed.keychain-db"\n'
                    guard()
                    return data, b""
                self.assertEqual(
                    arguments,
                    ["/usr/bin/security", "delete-keychain", str(root / owner.DATABASE_NAME)],
                )
                delete_calls.append(tuple(arguments))
                receipt = subprocess.run(
                    [
                        sys.executable,
                        "-B",
                        str(Path(__file__).resolve()),
                        "delete",
                        str(root),
                        endpoint,
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=LEGACY.remaining(deadline),
                    check=False,
                )
                if receipt.returncode:
                    raise owner.OwnerRefusal("modeled_native_delete_failed")
                guard()
                return receipt.stdout, receipt.stderr

            try:
                deadline = time.monotonic() + (0.5 if trigger == "timeout" else 4)
                with mock.patch.object(LEGACY, "command", command):
                    if accepted:
                        owner.delete_native_inventory(
                            LEGACY,
                            inventory,
                            foreign_search,
                            deadline,
                            owner.fixed_environment(root.parent, root.parent),
                        )
                        self.assertEqual(list(root.iterdir()), [])
                        self.assertFalse(inventory.close_debt or reply.close_debt)
                    else:
                        with self.assertRaises(Exception):
                            owner.delete_native_inventory(
                                LEGACY,
                                inventory,
                                foreign_search,
                                deadline,
                                owner.fixed_environment(root.parent, root.parent),
                            )
                expected_calls = (
                    0
                    if trigger
                    in (
                        "lock-replacement",
                        "db-replacement",
                        "metadata",
                        "content",
                        "mtime",
                        "nlink",
                        "extra-before",
                        "search-before",
                    )
                    else 1
                )
                self.assertEqual(len(delete_calls), expected_calls)
                if trigger == "replacement":
                    self.assertEqual(
                        (root / owner.DATABASE_NAME).read_bytes(), b"foreign replacement"
                    )
            finally:
                inventory.close()

    def test_c01_exact_native_delete(self):
        self.cleanup_case("healthy", accepted=True)

    def test_c02_bad_first_lock(self):
        for trigger in ("absent", "nonempty", "mode", "linked"):
            with self.subTest(trigger=trigger), self.native() as (root, process):
                reply = process.run("A" * 43, b"P", b"D")
                lock = root / owner.LOCK_NAME
                if trigger == "absent":
                    lock.unlink()
                elif trigger == "nonempty":
                    lock.write_bytes(b"foreign")
                elif trigger == "mode":
                    lock.chmod(0o644)
                else:
                    os.link(lock, root / "foreign")
                with self.assertRaises(owner.OwnerRefusal):
                    owner.FirstNativeInventory(root, reply, lambda: None)

    def test_c03_exact_inventory(self):
        self.cleanup_case("extra-before")

    def test_c04_lock_replacement(self):
        self.cleanup_case("lock-replacement")

    def test_c05_database_replacement(self):
        self.cleanup_case("db-replacement")

    def test_c06_changed_metadata(self):
        for trigger in ("metadata", "content", "mtime", "nlink"):
            with self.subTest(trigger=trigger):
                self.cleanup_case(trigger)

    def test_c07_delete_failure_leaves_or_extra(self):
        for trigger in ("failed", "timeout", "left-lock", "extra"):
            with self.subTest(trigger=trigger):
                self.cleanup_case(trigger)

    def test_c08_delete_foreign_replacement(self):
        self.cleanup_case("replacement")

    def test_c09_search_list_before(self):
        self.cleanup_case("search-before")

    def test_c10_search_list_after(self):
        self.cleanup_case("search-after")

    def test_c11_native_delete_changes_data(self):
        self.cleanup_case("changed-data")

    def test_c12_unretired_never_returns_authority(self):
        self.refused_producer("alive")

    def journal_case(self, kind, expected):
        with tempfile.TemporaryDirectory(prefix="credential-journal-control-") as temporary:
            root = Path(temporary).resolve()
            root.chmod(0o700)
            result = subprocess.run(
                [sys.executable, "-B", str(Path(__file__).resolve()), "journal", str(root), kind],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
                check=False,
            )
            self.assertEqual(result.returncode, expected)
            self.assertEqual(result.stderr, b"")
            record = json.loads((root / ".state.json").read_bytes())
            if kind in ("ambiguous", "old-ambiguous", "marker-failed"):
                self.assertEqual(record["phase"], "native_retired")
                self.assertTrue((root / ".state.next").exists())
                self.assertFalse((root / ".debt").exists())
                with self.assertRaises(owner.OwnerRefusal):
                    owner.closed_ready_record(LEGACY, root)
            elif expected == 0:
                self.assertEqual(
                    record["phase"], "native_retired" if kind == "intermediate" else "ready"
                )
                self.assertEqual(result.stdout, b"" if kind == "intermediate" else b"ready\n")
                self.assertFalse((root / ".unwound").exists())
            elif kind == "stdout-failed":
                self.assertEqual(record["phase"], "ready")
                self.assertEqual(result.stdout, b"")
                self.assertFalse((root / ".unwound").exists())
            return record

    def test_r01_real_intermediate_rename(self):
        self.journal_case("intermediate", 0)

    def test_r02_foreign_ready_vnode(self):
        self.journal_case("foreign", 1)

    def test_r03_writers_closed_before_ready(self):
        self.journal_case("healthy", 0)

    def test_r04_ambiguous_close_before_ready(self):
        for kind in ("ambiguous", "old-ambiguous"):
            with self.subTest(kind=kind):
                self.journal_case(kind, 1)

    def test_r05_marker_failure_not_authority(self):
        self.journal_case("marker-failed", 1)

    def test_r06_terminal_ready_never_unwinds(self):
        self.journal_case("terminal", 0)

    def test_r07_stdout_failure_is_physical_failure(self):
        self.journal_case("stdout-failed", 1)

    def test_r08_original_helper_and_fixed_inputs(self):
        self.assertEqual(
            owner.native_frame("A" * 43, b"P", b"D"),
            b"ERP1\x00\x00\x00+\x00\x00\x00\x01\x00\x00\x00\x01" + b"A" * 43 + b"PD",
        )
        for password in ("A" * 42, "A" * 44, "/" * 43):
            with self.subTest(password_length=len(password)), self.assertRaises(owner.OwnerRefusal):
                owner.native_frame(password, b"P", b"D")

        with tempfile.TemporaryDirectory(prefix="credential-env-control-") as temporary:
            path = Path(temporary).resolve()
            with mock.patch.dict(
                os.environ,
                {
                    "GITHUB_TOKEN": "independent-never-propagate",
                    "ERGOPTI_TEST_ONLY_KEY_PASSWORD": "independent-never-propagate",
                },
            ):
                result = owner.fixed_environment(path, path)
            self.assertEqual(set(result), {"PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"})
            self.assertNotIn("independent-never-propagate", result.values())

        with owner.fixed_legacy() as (legacy, current):
            self.assertEqual(
                legacy.public_record("A" * 40, "b" * 64),
                {
                    "schema": 1,
                    "status": "ready",
                    "identity": "A" * 40,
                    "public_leaf_sha256": "b" * 64,
                    "test_only": True,
                    "shipping_qualified": False,
                    "installation_qualified": False,
                    "authentication_qualified": False,
                },
            )
            current()

    def custody_gap(self, trigger):
        """Real two-read filesystem boundary, not a modeled stat oracle.

        This exercises the production custody binding predicate only. Native
        tools/whole Darwin cleanup remain separately unqualified.
        """
        with tempfile.TemporaryDirectory(prefix="credential-custody-gap-") as temporary:
            root = Path(temporary).resolve()
            for name in ("native-db", "tmp", "home"):
                (root / name).mkdir(mode=0o700)
            roles = {
                "owner": ("hs274_native_credential_owner.py", 0o600),
                "cpp": ("hs274_native_credential_transaction.cpp", 0o600),
                "tool": ("modeled-security", 0o700),
                "provider": ("native-credential-provider", 0o700),
                "leaf": ("public-leaf.der", 0o644),
            }
            held = {}
            for role, (name, mode) in roles.items():
                path = root / name
                path.write_bytes(b"independent exact custody role: " + role.encode("ascii"))
                path.chmod(mode)
                held[role] = LEGACY.ordinary(path, mode)

            def entry(item):
                return {
                    "identity": list(item.identity),
                    "sha256": owner.hashlib.sha256(item.data).hexdigest(),
                }

            record = {
                "custody": {
                    "sources": {
                        held[role].path.name: entry(held[role]) for role in ("owner", "cpp")
                    },
                    "tools": {str(held["tool"].path): entry(held["tool"])},
                    "home_ancestors": [
                        [str(path), list(observed)]
                        for path, observed in owner.ancestry(root / "home")
                    ],
                },
                "files": {held[role].path.name: entry(held[role]) for role in ("provider", "leaf")},
                "directories": {
                    name: list(owner.full((root / name).lstat())[:4])
                    for name in ("native-db", "tmp")
                },
            }
            if trigger in roles:
                target = held[trigger].path
                foreign = root / ".replacement"
                foreign.write_bytes(held[trigger].data)
                foreign.chmod(held[trigger].identity[3])
                expected = foreign.stat().st_ino
                foreign.replace(target)
            else:
                target = root / trigger
                target.rename(root / ".original-directory")
                target.mkdir(mode=0o700)
                expected = target.stat().st_ino
            fresh = {
                role: LEGACY.ordinary(root / name, mode) for role, (name, mode) in roles.items()
            }
            with self.assertRaises(owner.OwnerRefusal):
                owner.bind_cleanup_captures(
                    record,
                    tuple(fresh[role] for role in ("owner", "cpp")),
                    (fresh["tool"],),
                    tuple(fresh[role] for role in ("provider", "leaf")),
                    tuple(owner.ancestry(root / name) for name in ("native-db", "tmp")),
                    owner.ancestry(root / "home"),
                )
            self.assertEqual(target.stat().st_ino, expected)
            if trigger in roles:
                self.assertEqual(target.read_bytes(), held[trigger].data)

    def test_g01_provider_replacement_between_reads(self):
        self.custody_gap("provider")

    def test_g02_leaf_replacement_between_reads(self):
        self.custody_gap("leaf")

    def test_g03_owner_source_replacement_between_reads(self):
        self.custody_gap("owner")

    def test_g04_cpp_source_replacement_between_reads(self):
        self.custody_gap("cpp")

    def test_g05_tool_replacement_between_reads(self):
        self.custody_gap("tool")

    def test_g06_private_directory_replacement_between_reads(self):
        for name in ("native-db", "tmp"):
            with self.subTest(name=name):
                self.custody_gap(name)

    def test_g07_home_replacement_between_reads(self):
        self.custody_gap("home")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "producer":
        producer(Path(sys.argv[2]))
    elif len(sys.argv) == 4 and sys.argv[1] == "delete":
        delete_model(Path(sys.argv[2]), sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == "journal":
        journal_model(Path(sys.argv[2]), sys.argv[3])
    elif len(sys.argv) == 1:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(CredentialOwnerControls)
        if suite.countTestCases() != 40:
            raise SystemExit("credential_owner_control_registration_refused")
        result = unittest.TextTestRunner().run(suite)
        raise SystemExit(
            0 if result.wasSuccessful() and result.testsRun == 40 and not result.skipped else 1
        )
    else:
        raise SystemExit("credential_owner_control_arguments_refused")
