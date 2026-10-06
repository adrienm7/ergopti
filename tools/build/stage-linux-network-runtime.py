#!/usr/bin/env python3
# tools/build/stage-linux-network-runtime.py

"""Stage the build host's actual AppImage network runtime, then admit its ABI.

This preserves the existing AppImage same-vintage glibc requirement. It does
not bundle a CA store, alter desktop settings, or claim PAC/session delivery.
Only trusted build-host package files are inspected with ldd.
"""

import argparse
import ctypes
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shutil
import selectors
import signal
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools.lib.git_bash import bash_executable  # noqa: E402


class RuntimeRefused(RuntimeError):
    """A fixed, private-output-free packaging refusal."""


# Linux kernel child ownership and a WNOWAIT-reserved session leader fence
# every signal; capability refusal never substitutes a closure receipt.

_STAGE_DEADLINE = None
_DESTINATION_ROOT = None


def parse_process_fact(pid, raw):
    head, separator, tail = raw.rpartition(b") ")
    fields = tail.split()
    if (
        not separator
        or len(fields) < 20
        or not head.startswith(str(pid).encode("ascii") + b" (")
        or not re.fullmatch(rb"[A-Za-z]", fields[0])
        or not re.fullmatch(rb"(?:0|[1-9][0-9]*)", fields[1])
    ):
        raise RuntimeRefused("Native process observation refused.")
    try:
        return {
            "state": fields[0].decode("ascii"),
            "parent": int(fields[1]),
            "group": int(fields[2]),
            "session": int(fields[3]),
            "birth": int(fields[19]),
        }
    except (ValueError, UnicodeError) as error:
        raise RuntimeRefused("Native process observation refused.") from error


def process_fact(pid):
    return parse_process_fact(pid, Path(f"/proc/{pid}/stat").read_bytes())


def current_proc_owner():
    # NSpid is emitted from the mounted proc namespace through the task's
    # active namespace. Exactly one PID prevents an ancestor-view alias even
    # when its numeric owner happens to equal this process's getpid().
    owner = os.getpid()
    with Path("/proc/self/status").open("rb") as source:
        status = source.read(65537)
    lines = [line for line in status.splitlines() if line.startswith(b"NSpid:")]
    if (
        len(status) > 65536
        or len(lines) != 1
        or lines[0].split() != [b"NSpid:", str(owner).encode("ascii")]
    ):
        raise RuntimeRefused("Native process census PID view unavailable.")
    return parse_process_fact(owner, Path("/proc/self/stat").read_bytes())


def process_census():
    # One complete kernel-stat census serves both group and parent ownership.
    # This single-threaded helper is the sole reaper; children remain visible
    # until its waitpid. PPID identifies candidates, never destructive authority:
    # the existing waitid/WNOWAIT reservations still fence every signal/reap.
    result = {}
    try:
        before = current_proc_owner()
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            if not re.fullmatch(r"[1-9][0-9]*", entry.name):
                raise RuntimeRefused("Native process census schema refused.")
            pid = int(entry.name)
            if pid in result:
                raise RuntimeRefused("Native process census schema refused.")
            try:
                fact = process_fact(pid)
            except FileNotFoundError:
                # A vanished entry is the same narrow exception admitted by
                # the original group census. Denials/unknown reads still fail.
                continue
            result[pid] = fact
        after = current_proc_owner()
    except OSError as error:
        raise RuntimeRefused("Native process census unavailable.") from error
    owner = result.get(os.getpid())
    if owner is None or owner["birth"] != before["birth"] or owner["birth"] != after["birth"]:
        raise RuntimeRefused("Native process census owner unavailable.")
    return result


def direct_children():
    owner = os.getpid()
    return sorted(pid for pid, fact in process_census().items() if fact["parent"] == owner)


def observe_child(pid):
    result = os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    if result is not None and (
        result.si_pid != pid or result.si_code not in {os.CLD_EXITED, os.CLD_KILLED, os.CLD_DUMPED}
    ):
        raise RuntimeRefused("Native child terminal observation refused.")
    return result


def group_live_members(group):
    # Only kernel stat fields are observed, never foreign argv/environment/paths.
    return [
        pid
        for pid, fact in process_census().items()
        if fact["group"] == group
        and fact["session"] == group
        and fact["state"] not in {"Z", "X", "x"}
    ]


def subreaper(enabled=None):
    libc = ctypes.CDLL(None, use_errno=True)
    native = libc.prctl
    native.restype = ctypes.c_int
    native.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
    value = ctypes.c_int()
    address = ctypes.cast(ctypes.byref(value), ctypes.c_void_p).value
    if native(37, address, 0, 0, 0) != 0:
        raise RuntimeRefused("Native child ownership unavailable.")
    old = value.value
    if enabled is not None and native(36, int(enabled), 0, 0, 0) != 0:
        raise RuntimeRefused("Native child ownership unavailable.")
    return old


def run(arguments, *, env=None, budget_seconds=20, pass_fds=()):
    if sys.platform != "linux" or not hasattr(os, "WNOWAIT") or direct_children():
        raise RuntimeRefused("Exclusive native command ownership unavailable.")
    group_live_members(os.getpid())  # Refuse unavailable census before acquisition.
    old_subreaper = None
    cancelled = False
    old_handlers = {}
    process = None
    leader_birth = None
    captures = [bytearray(), bytearray()]
    selector = None
    primary = None
    status = None

    def cleanup(action):
        nonlocal primary
        try:
            action()
        except BaseException:
            # Resource cleanup must not replace an earlier deadline/refusal.
            # This private command owner publishes no admission with debt.
            if primary is None:
                primary = RuntimeRefused("Native command resource cleanup refused.")
            sys.stderr.write("Native command resource cleanup refused; owned inputs retained.\n")

    def collect_signal(signum, frame):
        nonlocal cancelled
        cancelled = True

    def reserved_leader():
        nonlocal leader_birth
        observed = observe_child(process.pid)
        fact = process_fact(process.pid)
        if leader_birth is None:
            leader_birth = fact["birth"]
        if (
            fact["birth"] != leader_birth
            or fact["group"] != process.pid
            or fact["session"] != process.pid
        ):
            raise RuntimeRefused("Native command reservation lost.")
        return observed

    def drain(timeout):
        for key, _ in selector.select(timeout):
            block = os.read(key.fd, 65536)
            if not block:
                selector.unregister(key.fileobj)
            else:
                captures[key.data].extend(block)
                if len(captures[key.data]) > 1048576:
                    raise RuntimeRefused("Native command output bound exceeded.")

    try:
        for signum in [signal.SIGINT, signal.SIGTERM]:
            old_handlers[signum] = signal.signal(signum, collect_signal)
        old_subreaper = subreaper(True)
        selector = selectors.DefaultSelector()
        deadline = time.monotonic() + budget_seconds
        if _STAGE_DEADLINE is not None:
            deadline = min(deadline, _STAGE_DEADLINE)
        if cancelled or time.monotonic() >= deadline:
            raise RuntimeRefused("Native packaging deadline refused.")
        inherited = list(pass_fds)
        if _DESTINATION_ROOT is not None:
            root_current()
            inherited.append(_DESTINATION_ROOT["fd"])
        inherited = tuple(dict.fromkeys(inherited))
        if any(not stat.S_ISDIR(os.fstat(descriptor).st_mode) for descriptor in inherited):
            raise RuntimeRefused("Native directory capability refused.")
        process = subprocess.Popen(
            arguments,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
            pass_fds=inherited,
        )
        leader = process_fact(process.pid)
        leader_birth = leader["birth"]
        reserved_leader()
        for index, stream in enumerate([process.stdout, process.stderr]):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, index)
        while True:
            if cancelled or time.monotonic() >= deadline:
                raise RuntimeRefused("Native packaging command deadline or cancellation refused.")
            observed = reserved_leader()
            drain(min(0.05, max(0, deadline - time.monotonic())))
            if observed is not None and not selector.get_map():
                status = (
                    observed.si_status if observed.si_code == os.CLD_EXITED else -observed.si_status
                )
                break
    except BaseException as error:
        primary = error
    finally:
        if process is not None:
            # Keep the leader unreaped until its entire group and every kernel-
            # adopted escaped descendant are terminal. Persistent debt keeps
            # this owner alive; it never emits an admission/closure receipt.
            warned = False
            while True:
                try:
                    reserved_leader()
                    if group_live_members(process.pid):
                        reserved_leader()
                        os.killpg(process.pid, signal.SIGKILL)
                    children = direct_children()
                    if process.pid not in children:
                        raise RuntimeRefused("Native command reservation lost.")
                    for pid in children:
                        if pid == process.pid:
                            continue
                        # WNOWAIT proves this is our kernel-adopted child. Its
                        # PID stays reserved through the signal and one reap.
                        observed = observe_child(pid)
                        if observed is None:
                            os.kill(pid, signal.SIGKILL)
                        else:
                            reaped, _ = os.waitpid(pid, 0)
                            if reaped != pid:
                                raise RuntimeRefused("Native adopted child retirement refused.")
                    # Group absence is checked before the fresh direct-child
                    # census; zombie exit has already performed reparenting.
                    if not group_live_members(process.pid) and direct_children() == [process.pid]:
                        observed = reserved_leader()
                        if observed is not None:
                            reaped, wait_status = os.waitpid(process.pid, 0)
                            if reaped != process.pid:
                                raise RuntimeRefused("Native leader retirement refused.")
                            process.returncode = os.waitstatus_to_exitcode(wait_status)
                            break
                except (RuntimeRefused, OSError) as error:
                    if primary is None:
                        primary = error
                    if not warned:
                        sys.stderr.write(
                            "Native command retirement pending; owned inputs retained.\n"
                        )
                        warned = True
                time.sleep(0.02)
            # Every inherited capture endpoint is now physically retired.
            # The streams are drained under the original command deadline;
            # cleanup never grants a fresh execution budget.
            if primary is None:
                try:
                    while selector.get_map():
                        if cancelled or time.monotonic() >= deadline:
                            raise RuntimeRefused(
                                "Native packaging command deadline or cancellation refused."
                            )
                        drain(min(0.05, max(0, deadline - time.monotonic())))
                except BaseException as error:
                    primary = error
            if process.stdout is not None:
                cleanup(process.stdout.close)
            if process.stderr is not None:
                cleanup(process.stderr.close)
        elif old_subreaper is not None:
            # A failed Popen acquisition normally reaps its own exec-failure
            # child. Independently acknowledge kernel child absence before
            # restoring the subreaper; never assume that constructor cleanup.
            warned = False
            while True:
                try:
                    children = direct_children()
                    if not children:
                        break
                    for pid in children:
                        observed = observe_child(pid)
                        if observed is None:
                            os.kill(pid, signal.SIGKILL)
                        else:
                            reaped, _ = os.waitpid(pid, 0)
                            if reaped != pid:
                                raise RuntimeRefused("Native acquisition child retirement refused.")
                except (RuntimeRefused, OSError) as error:
                    if primary is None:
                        primary = error
                    if not warned:
                        sys.stderr.write(
                            "Native acquisition retirement pending; owned inputs retained.\n"
                        )
                        warned = True
                time.sleep(0.02)
        if selector is not None:
            cleanup(selector.close)
        for signum, old_handler in old_handlers.items():
            cleanup(
                lambda signum=signum, old_handler=old_handler: signal.signal(signum, old_handler)
            )
        if old_subreaper is not None:
            cleanup(lambda: subreaper(old_subreaper))
    if primary is not None:
        raise primary
    if (
        cancelled
        or status != 0
        or (_STAGE_DEADLINE is not None and time.monotonic() >= _STAGE_DEADLINE)
    ):
        raise RuntimeRefused("Native packaging command refused.")
    return captures[0].decode("utf-8", errors="strict")


def regular_source(source):
    resolved = Path(source).resolve(strict=True)
    if not stat.S_ISREG(resolved.stat().st_mode):
        raise RuntimeRefused("Native packaging source refused.")
    return resolved


def directory_fd(path, *, create, use_root=True):
    """Pin each directory component; NOFOLLOW applies at actual acquisition."""
    path = Path(path)
    if not path.is_absolute():
        raise RuntimeRefused("Native packaging destination refused.")
    if use_root and _DESTINATION_ROOT is not None:
        root_current()
        root_path = _DESTINATION_ROOT["path"]
        if not path.is_relative_to(root_path):
            raise RuntimeRefused("Native packaging destination outside owned root.")
        descriptor = os.dup(_DESTINATION_ROOT["fd"])
        parts = path.relative_to(root_path).parts
    else:
        descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        parts = path.parts[1:]
    result = None
    primary = None
    try:
        for part in parts:
            if part in {"", ".", ".."}:
                raise RuntimeRefused("Native packaging destination refused.")
            if create:
                try:
                    os.mkdir(part, mode=0o755, dir_fd=descriptor)
                except FileExistsError:
                    # The subsequent NOFOLLOW directory open is admission.
                    pass
            acquired = os.open(
                part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor
            )
            old = descriptor
            descriptor = acquired
            os.close(old)
        result = descriptor
        descriptor = None
    except BaseException as error:
        primary = error
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except BaseException:
                if primary is None:
                    primary = RuntimeRefused("Native directory descriptor retirement refused.")
                sys.stderr.write(
                    "Native directory descriptor retirement refused; owned inputs retained.\n"
                )
    if primary is not None:
        if isinstance(primary, OSError):
            raise RuntimeRefused("Native packaging directory acquisition refused.") from primary
        raise primary
    return result


def root_current():
    """Fence the original spelling; never resolve and adopt its replacement."""
    if _DESTINATION_ROOT is None:
        raise RuntimeRefused("Owned native package root unavailable.")
    descriptor = directory_fd(_DESTINATION_ROOT["path"], create=False, use_root=False)
    primary = None
    try:
        current = os.fstat(descriptor)
        retained = os.fstat(_DESTINATION_ROOT["fd"])
        identity = _DESTINATION_ROOT["identity"]
        if (current.st_dev, current.st_ino) != identity or (
            retained.st_dev,
            retained.st_ino,
        ) != identity:
            raise RuntimeRefused("Owned native package root changed.")
    except BaseException as error:
        primary = error
    finally:
        try:
            os.close(descriptor)
        except BaseException:
            if primary is None:
                primary = RuntimeRefused("Native root observation retirement refused.")
            sys.stderr.write("Native root observation retirement refused; owned inputs retained.\n")
    if primary is not None:
        raise primary


@contextmanager
def owned_root(path):
    """Keep the original AppDir capability throughout native writes/children."""
    global _DESTINATION_ROOT
    if _DESTINATION_ROOT is not None:
        raise RuntimeRefused("Duplicate native package root ownership.")
    lexical = Path(path)
    descriptor = directory_fd(lexical, create=False)
    primary = None
    try:
        original = os.fstat(descriptor)
        _DESTINATION_ROOT = {
            "path": lexical,
            "fd": descriptor,
            "identity": (original.st_dev, original.st_ino),
        }
        root_current()
        yield lexical
        root_current()
    except BaseException as error:
        primary = error
    finally:
        _DESTINATION_ROOT = None
        try:
            os.close(descriptor)
        except BaseException:
            if primary is None:
                primary = RuntimeRefused("Native package root retirement refused.")
            sys.stderr.write("Native package root retirement refused; owned inputs retained.\n")
    if primary is not None:
        raise primary


@contextmanager
def held_directory(path):
    descriptor = directory_fd(path, create=False)
    primary = None
    try:
        yield descriptor
        current_fd = directory_fd(path, create=False)
        observation_error = None
        try:
            current = os.fstat(current_fd)
            retained = os.fstat(descriptor)
            if (current.st_dev, current.st_ino) != (retained.st_dev, retained.st_ino):
                raise RuntimeRefused("Owned native writer directory changed.")
        except BaseException as error:
            observation_error = error
        finally:
            try:
                os.close(current_fd)
            except BaseException:
                if observation_error is None:
                    observation_error = RuntimeRefused(
                        "Native writer observation retirement refused."
                    )
                sys.stderr.write(
                    "Native writer observation retirement refused; owned inputs retained.\n"
                )
        if observation_error is not None:
            raise observation_error
    except BaseException as error:
        primary = error
    finally:
        try:
            os.close(descriptor)
        except BaseException:
            if primary is None:
                primary = RuntimeRefused("Native writer directory retirement refused.")
            sys.stderr.write("Native writer directory retirement refused; owned inputs retained.\n")
    if primary is not None:
        raise primary


def gio_querymodules_executable():
    candidate = Path(run(["pkg-config", "--variable=gio_querymodules", "gio-2.0"]).strip())
    if not candidate.is_absolute():
        raise RuntimeRefused("Native GIO cache writer location refused.")
    executable = regular_source(candidate)
    if not os.access(executable, os.X_OK):
        raise RuntimeRefused("Native GIO cache writer executable refused.")
    return str(executable)


def query_modules(path, *, executable="gio-querymodules"):
    # The actual cache writer inherits the retained module directory, rather
    # than following a lexical path after a root/ancestor precheck.
    with held_directory(path) as descriptor:
        run([executable, f"/proc/self/fd/{descriptor}"], pass_fds=(descriptor,))


def inspection_prefix():
    root_current()
    return Path(f"/proc/self/fd/{_DESTINATION_ROOT['fd']}") / "usr"


def destination_directory(path):
    descriptor = directory_fd(path, create=True)
    os.close(descriptor)
    return Path(path)


def copy_unique(source, destination, owners):
    source = regular_source(source)
    destination = Path(destination)
    old = owners.get(destination)
    if old is not None:
        observed = os.stat(destination, follow_symlinks=False)
        if (
            not old["complete"]
            or not stat.S_ISREG(observed.st_mode)
            or (observed.st_dev, observed.st_ino) != old["identity"]
            or not os.path.samefile(old["source"], source)
        ):
            raise RuntimeRefused("Conflicting native packaging identity.")
        return
    directory = directory_fd(destination.parent, create=True)
    source_fd = None
    output_fd = None
    primary = None
    try:
        source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
        before = os.fstat(source_fd)
        if not stat.S_ISREG(before.st_mode) or before.st_mode & (stat.S_ISUID | stat.S_ISGID):
            raise RuntimeRefused("Native packaging source admission refused.")
        output_fd = os.open(
            destination.name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            stat.S_IMODE(before.st_mode),
            dir_fd=directory,
        )
        # The acquired output inode is owned even if a later write refuses;
        # failure retains it and never substitutes a publication receipt.
        output_identity = os.fstat(output_fd)
        owners[destination] = {
            "source": source,
            "complete": False,
            "identity": (output_identity.st_dev, output_identity.st_ino),
        }
        copied = 0
        while True:
            block = os.read(source_fd, 1048576)
            if not block:
                break
            offset = 0
            while offset < len(block):
                count = os.write(output_fd, block[offset:])
                if count <= 0:
                    raise RuntimeRefused("Native packaging write refused.")
                offset += count
            copied += len(block)
        after = os.fstat(source_fd)
        if copied != before.st_size or (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
        ) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise RuntimeRefused("Native packaging source changed during acquisition.")
        os.fchmod(output_fd, stat.S_IMODE(before.st_mode))
        os.fsync(output_fd)
        parent = os.stat(destination.parent, follow_symlinks=False)
        pinned_parent = os.fstat(directory)
        leaf = os.stat(destination.name, dir_fd=directory, follow_symlinks=False)
        if (
            not stat.S_ISDIR(parent.st_mode)
            or (parent.st_dev, parent.st_ino) != (pinned_parent.st_dev, pinned_parent.st_ino)
            or not stat.S_ISREG(leaf.st_mode)
            or (leaf.st_dev, leaf.st_ino) != owners[destination]["identity"]
        ):
            raise RuntimeRefused("Native packaging destination changed during acquisition.")
        owners[destination]["complete"] = True
    except BaseException as error:
        primary = error
    finally:
        for descriptor in [output_fd, source_fd, directory]:
            if descriptor is None:
                continue
            try:
                os.close(descriptor)
            except BaseException:
                # A failed close invalidates publication but does not erase
                # the source/write/destination refusal that caused cleanup.
                owners.get(destination, {}).update(complete=False)
                if primary is None:
                    primary = RuntimeRefused("Native packaging descriptor retirement refused.")
                sys.stderr.write(
                    "Native packaging descriptor retirement refused; owned inputs retained.\n"
                )
    if primary is not None:
        if isinstance(primary, OSError):
            raise RuntimeRefused("Exclusive native packaging copy refused.") from primary
        raise primary


def dependency_paths(output):
    """Parse actual trusted-host ldd output; never accept a missing dependency."""
    dependencies = []
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        if "=> not found" in line:
            raise RuntimeRefused("Unresolved native packaging dependency.")
        mapped = re.fullmatch(r"([^\s/]+) => (/[^\n]+) \(0x[0-9a-fA-F]+\)", line)
        if mapped:
            dependencies.append((mapped[1], mapped[2]))
            continue
        if re.fullmatch(r"(?:linux-vdso[^\s]*|/[^\n]+) \(0x[0-9a-fA-F]+\)", line):
            continue
        raise RuntimeRefused("Unknown native packaging dependency observation.")
    return dependencies


def external_glibc(name):
    # These are one glibc installation, supplied together by the recipient.
    return name in {
        "libc.so.6",
        "libm.so.6",
        "libdl.so.2",
        "libpthread.so.0",
        "librt.so.1",
        "libresolv.so.2",
        "libutil.so.1",
    } or name.startswith("ld-linux-")


def copy_elf_closure(seeds, library_directory, owners):
    pending = list(seeds)
    visited = set()
    while pending:
        source = regular_source(pending.pop())
        if source in visited:
            continue
        visited.add(source)
        if len(visited) > 256:
            raise RuntimeRefused("Native packaging dependency bound exceeded.")
        for name, dependency in dependency_paths(run(["ldd", str(source)])):
            if external_glibc(name):
                continue
            copy_unique(dependency, library_directory / name, owners)
            pending.append(dependency)


def explicit_digest_sources(catalogue):
    """Resolve direct dlopen roots from actual OpenSSL build metadata/ELF."""
    descriptor = catalogue.get("archive_digest_runtime")
    if (
        not isinstance(descriptor, dict)
        or descriptor.get("soname") != "libcrypto.so.3"
        or descriptor.get("portable_dlopen_roots") != ["libcrypto.so.3"]
    ):
        raise RuntimeRefused("Explicit OpenSSL3 staging descriptor unavailable.")
    # libcrypto.pc is OpenSSL's actual component metadata. No architecture-
    # specific /usr/lib directory or curl's optional dependency is inferred.
    directory = Path(run(["pkg-config", "--variable=libdir", "libcrypto"]).strip())
    if not directory.is_absolute():
        raise RuntimeRefused("Actual OpenSSL build library directory unavailable.")
    sources = []
    for soname in descriptor["portable_dlopen_roots"]:
        source = regular_source(directory / soname)
        observed = run(
            ["readelf", "--dynamic", "--", str(source)], env={**os.environ, "LC_ALL": "C"}
        )
        identities = re.findall(r"\(SONAME\)[^\n]*Library soname: \[([^\]\n]+)\]", observed)
        if identities != [soname]:
            raise RuntimeRefused("Actual OpenSSL ELF SONAME refused.")
        sources.append(source)
    return sources


def stage(appdir, catalogue, template):
    global _STAGE_DEADLINE
    _STAGE_DEADLINE = time.monotonic() + 180
    if sys.platform != "linux" or os.uname().machine != "x86_64":
        raise RuntimeRefused("AppImage native build architecture refused.")
    with owned_root(appdir) as appdir:
        prefix = destination_directory(appdir / "usr")
        driver = prefix / "lib/ergopti"
        if not (driver / "platform/network/runtime_probe.lua").is_file():
            raise RuntimeRefused("Installed runtime probe absent.")
        catalogue_data = json.loads(Path(catalogue).read_text())
        policy = catalogue_data["network_runtime"]["portable"]
        owners = {}
        binaries = []
        for name in ["luajit", "curl"]:
            source = shutil.which(name)
            if source is None:
                raise RuntimeRefused("Required native packaging executable absent.")
            copy_unique(source, prefix / "bin" / name, owners)
            binaries.append(source)
        luv_path = run(
            [
                binaries[0],
                "-e",
                'local p=assert(package.searchpath("luv",package.cpath)); '
                'local uv=require("luv"); assert(type(uv.spawn)=="function"); io.write(p)',
            ]
        )
        luv_source = regular_source(luv_path)
        copy_unique(luv_source, prefix / "lib/lua/5.1/luv.so", owners)
        # pkg-config reports the actual build host's GIO module location; no
        # distribution-specific /usr/lib spelling is inferred.
        module_directory = Path(run(["pkg-config", "--variable=giomoduledir", "gio-2.0"]).strip())
        if not module_directory.is_absolute():
            raise RuntimeRefused("Native GIO module location refused.")
        modules = []
        for name in policy["gio_modules"]:
            source = regular_source(module_directory / name)
            copy_unique(source, prefix / "lib/gio/modules" / name, owners)
            modules.append(source)
        schema_directory = Path(run(["pkg-config", "--variable=schemasdir", "gio-2.0"]).strip())
        if not schema_directory.is_absolute():
            raise RuntimeRefused("Native schema location refused.")
        copy_unique(
            schema_directory / "gschemas.compiled",
            prefix / "share/glib-2.0/schemas/gschemas.compiled",
            owners,
        )
        digest_sources = explicit_digest_sources(catalogue_data)
        for source in digest_sources:
            copy_unique(
                source, prefix / "lib" / catalogue_data["archive_digest_runtime"]["soname"], owners
            )
        copy_elf_closure([*binaries, luv_source, *modules, *digest_sources], prefix / "lib", owners)
        # 0.5's backend is linked and therefore relocatable through package lib.
        # 0.4's separate runtime plugin search needs another qualification owner.
        if not any(destination.name == "libpxbackend-1.0.so" for destination in owners):
            raise RuntimeRefused("Unqualified native libproxy plugin layout.")
        copy_unique(template, driver / "network-runtime-env.sh", owners)
        # The shared environment template has a generated catalogue region.
        # It is copied unchanged, rather than generating policy in this stager.
        query_modules(prefix / "lib/gio/modules", executable=gio_querymodules_executable())
        admitted_prefix = inspection_prefix()
        inspect_installed(admitted_prefix, admitted_prefix / "lib/ergopti")
        root_current()
    print(
        "PASS AppImage staged native network runtime: ABI/backend/schema admitted; PAC/session unqualified."
    )


def inspect_installed(prefix, driver):
    result = run(
        [
            bash_executable(),
            "-c",
            'set -euo pipefail; source "$1" "$2" "$3"; export XDG_DATA_DIRS="$2/share" XDG_DATA_HOME="$2/share"; exec "$2/bin/luajit" "$3/platform/network/runtime_probe.lua" "$3/_shared"',
            "ergopti-owned-runtime",
            str(driver / "network-runtime-env.sh"),
            str(prefix),
            str(driver),
        ]
    )
    receipt = json.loads(result)
    if receipt != {
        "ok": True,
        "acknowledgement": "native-runtime",
        "schema_available": True,
        "schema_required": True,
        "selection_scope": "native-selection",
    }:
        raise RuntimeRefused("Installed native packaging admission refused.")
    curl_version = run(
        [
            bash_executable(),
            "-c",
            'set -euo pipefail; source "$1" "$2" "$3"; exec "$2/bin/curl" --disable --version',
            "ergopti-owned-curl",
            str(driver / "network-runtime-env.sh"),
            str(prefix),
            str(driver),
        ]
    )
    lines = curl_version.splitlines()
    protocols = [
        line[len("Protocols: ") :].split() for line in lines if line.startswith("Protocols: ")
    ]
    features = [
        line[len("Features: ") :].split() for line in lines if line.startswith("Features: ")
    ]
    if (
        not lines
        or not lines[0].startswith("curl ")
        or len(protocols) != 1
        or len(features) != 1
        or not {"http", "https"}.issubset(protocols[0])
        or "SSL" not in features[0]
    ):
        raise RuntimeRefused("Installed curl TLS capability refused.")


def main():
    global _STAGE_DEADLINE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appdir", required=True)
    parser.add_argument("--catalogue", required=True)
    parser.add_argument("--template", required=True)
    parser.add_argument("--owned-execution", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument(
        "--probe-only",
        action="store_true",
        help="Read-only installed-package admission under the same native command owner.",
    )
    arguments = parser.parse_args()
    try:
        if not arguments.owned_execution:
            # The CLI itself owns the worker session, so termination/deadline
            # of a blocked inner admission retires its adopted descendants too.
            # No independent spawnSync timeout kills only this supervisor.
            budget = 60 if arguments.probe_only else 180
            _STAGE_DEADLINE = time.monotonic() + budget
            result = run(
                [sys.executable, str(Path(__file__).resolve()), *sys.argv[1:], "--owned-execution"],
                budget_seconds=budget,
            )
            expected = (
                "PASS installed package native network runtime admitted.\n"
                if arguments.probe_only
                else "PASS AppImage staged native network runtime: ABI/backend/schema admitted; PAC/session unqualified.\n"
            )
            if result != expected:
                raise RuntimeRefused("Native packaging worker acknowledgement refused.")
            print(expected, end="")
        elif arguments.probe_only:
            _STAGE_DEADLINE = time.monotonic() + 60
            with owned_root(arguments.appdir):
                prefix = inspection_prefix()
                inspect_installed(prefix, prefix / "lib/ergopti")
                root_current()
            print("PASS installed package native network runtime admitted.")
        else:
            stage(arguments.appdir, arguments.catalogue, arguments.template)
    except (RuntimeRefused, OSError, ValueError, KeyError) as error:
        # No filenames, certificate bytes, settings or native output escape.
        raise SystemExit("Native network packaging refused.") from error


if __name__ == "__main__":
    main()
