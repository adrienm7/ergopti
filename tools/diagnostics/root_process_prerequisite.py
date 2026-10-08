# tools/diagnostics/root_process_prerequisite.py
"""TEST ONLY: admit a fixed root helper and observe its actual root-child retirement.

Bootstrap uses a fixed admitted Apple interpreter and immutable in-memory
bootstrap text, never a runner-owned interpreter/module under sudo. Unknown bootstrap/root retirement retains concrete process
objects and inputs; a JSON record never grants privileged ownership or signing.
"""

import argparse
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

ABI_OBSERVATION_SHA256 = "c255709e64508eba039c55f21ebc591f06707e36908aeb08b3165b192ee6d249"
ROOT_SECONDS = 25
ROOT_PREFIX = "/private/var/tmp/ergopti-root-process-"
SOURCE_SHA256 = "6adb17bcbadee205468ae5694693ecbc1ba3d9799e4ccd3d9b3f5f31955047ad"
BRIDGE_SHA256 = "d5e04a2eef0145c7988b7f6c2c1de5fa9cc231714fc8781e5cb7cf62b2a595a5"
BOOTSTRAP_SHA256 = "6abbdbdad82fbdaead6f4e2fe94437e9c87ce44629576d091996e789a4f1ee4f"


class Refusal(RuntimeError):
    """Retains actual acquired process owners instead of reconstructing from PID JSON."""

    def __init__(self, code, owners=()):
        self.code, self.owners = code, tuple(owners)
        super().__init__(code)


def require(condition, code, owners=()):
    if not condition:
        raise Refusal(code, owners)


def root_locator(value):
    require(
        type(value) is str and re.fullmatch(re.escape(ROOT_PREFIX) + "[a-f0-9]{32}", value),
        "root_locator",
    )
    return Path(value)


def digest(value):
    require(type(value) is str and re.fullmatch("[a-f0-9]{64}", value), "digest")
    return value


def closed_line(value):
    require(type(value) is bytes and len(value) <= 64 and value.endswith(b"\n"), "protocol")
    try:
        text = value.decode("ascii")
    except UnicodeError as error:
        raise Refusal("protocol") from error
    require(
        re.fullmatch(
            r"V1 (?:HELD [1-9][0-9]{0,9}|CHILD [1-9][0-9]{0,9}|CHILD_RETIRED|RETIRED|DEBT)\n", text
        ),
        "protocol",
    )
    return text.rstrip("\n")


def stamp(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_uid,
        value.st_gid,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


class Held:
    """Physical ordinary input custody; compilation/signing authority is separate."""

    def __init__(self, path, *, root=False, maximum=4_194_304):
        self.fd = None
        self.close_debt = None
        self.path = Path(path)
        require(
            self.path.is_absolute() and self.path.resolve(strict=True) == self.path, "source_path"
        )
        named = self.path.lstat()
        require(
            stat.S_ISREG(named.st_mode)
            and named.st_nlink == 1
            and named.st_uid == (0 if root else os.geteuid()),
            "source",
        )
        require(0 < named.st_size <= maximum and (not root or not named.st_mode & 0o022), "source")
        self.fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
        try:
            self.identity = stamp(named)
            require(stamp(os.fstat(self.fd)) == self.identity, "source_changed")
            self.data = os.pread(self.fd, named.st_size + 1, 0)
            require(len(self.data) == named.st_size, "source_changed")
            self.current()
        except BaseException as original:
            try:
                self.close()
            except OSError:
                if isinstance(original, Refusal):
                    original.owners += (self,)
                else:
                    original.held_close_debt = self
            raise

    def current(self):
        require(
            stamp(os.fstat(self.fd)) == self.identity and stamp(self.path.lstat()) == self.identity,
            "source_changed",
        )
        require(os.pread(self.fd, len(self.data) + 1, 0) == self.data, "source_changed")

    def close(self):
        descriptor, self.fd = self.fd, None
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError as error:
                self.close_debt = error
                raise


def protected_compile_decision(stage, observation):
    """Decision model only: no authority, acquisition, command, or native receipt."""
    if type(stage) is not str or stage not in ("copy_source", "compile", "execute"):
        return "refuse"
    if type(observation) is not dict:
        return "refuse"
    expected = {
        "namespace_created_by_owned_root_tool": True,
        "namespace_uid": 0,
        "namespace_mode": 0o700,
        "namespace_acl_empty": True,
        "namespace_physical_current": True,
        "anchor_physical_admitted": True,
        "anchor_acl_admitted_before_creation": True,
        "operations_expired": False,
        "inventory": (),
    }
    if stage in ("compile", "execute"):
        expected.update(
            {
                "inventory": ("source.c",),
                "source_owner_uid": 0,
                "source_mode": 0o400,
                "source_acl_empty": True,
                "source_regular_single_link": True,
                "source_physical_current": True,
                "source_digest_matches_fixed_pin": True,
                "compiler_physical_admitted": True,
                "sdk_physical_admitted": True,
                "compiler_role": "fixed_admitted_apple_native_compiler",
                "sdk_role": "fixed_selected_apple_sdk",
                "environment": (("PATH", "/usr/bin:/bin"), ("LC_ALL", "C")),
                "command_role": "compile_fixed_protected_c_only",
            }
        )
    if stage == "execute":
        expected.update(
            {
                "inventory": ("probe", "source.c"),
                "product_owner_uid": 0,
                "product_mode": 0o500,
                "product_acl_empty": True,
                "product_regular_single_link": True,
                "product_physical_current": True,
                "product_created_inside_protected_namespace": True,
                "product_provenance": "owned_protected_native_compiler",
                "producer_reservation_physically_closed": True,
                "compiler_still_current": True,
                "sdk_still_current": True,
                "execution_role": "fixed_protected_builtin_supervisor",
            }
        )
    if set(observation) != set(expected):
        return "refuse"
    for key, value in expected.items():
        actual = observation[key]
        if type(actual) is not type(value) or actual != value:
            return "refuse"
    return {
        "copy_source": "copy_fixed_source",
        "compile": "compile_fixed_source",
        "execute": "execute_fixed_supervisor",
    }[stage]


def _load_abi_observation_module():
    import hashlib
    import types

    held = Held(Path(__file__).resolve(strict=True).with_name("native_abi_observation.py"))
    try:
        require(
            hashlib.sha256(held.data).hexdigest() == ABI_OBSERVATION_SHA256,
            "abi_observation_source_pin",
            [held],
        )
        held.current()
        module = types.ModuleType("fixed_sdk_abi_observation")
        exec(compile(held.data, str(held.path), "exec"), module.__dict__)
        held.current()
        return module
    finally:
        held.close()


def parse_sdk_abi_pair(waitid_data, filesec_data):
    return _load_abi_observation_module().parse_sdk_abi_pair(waitid_data, filesec_data)


PUBLISHED_OWNER_SHA256 = "d3bc862c737e444f22d84fc32368bb8669360bc33ba6008c208f7bf62001314b"
SDK_ORACLE_SOURCE_PINS = {
    "darwin_waitid_sdk_oracle.c": "9383033720a19fb6fc8f240ec74feb69120c620edc0a84cde90cbce97fb08f5b",
    "darwin_filesec_sdk_oracle.c": "e9af205d5d5d30b2945d2c552115e338d5c7f2385d2ad60588dd87d3381acd3c",
}


def _load_published_ownership(repository):
    """Load the actual pinned ordinary owner bytes without a pathname reread."""
    import hashlib
    import types

    held = Held(Path(repository).resolve(strict=True) / "tools/diagnostics/macos_owned_process.py")
    try:
        require(
            hashlib.sha256(held.data).hexdigest() == PUBLISHED_OWNER_SHA256,
            "published_ordinary_owner_pin",
            [held],
        )
        held.current()
        module = types.ModuleType("fixed_published_ordinary_owner")
        module.__file__ = str(held.path)
        exec(compile(held.data, str(held.path), "exec"), module.__dict__)
        held.current()
        return module
    finally:
        held.close()


class PreflightTool:
    """Ordinary source-role/currentness observation; no elevated ACL authority."""

    def __init__(self, path, role):
        self.path = Path(path)
        require(
            self.path.is_absolute() and self.path.resolve(strict=True) == self.path,
            "preflight_tool_path",
        )
        text = str(self.path)
        if role == "compiler":
            require(
                re.fullmatch(
                    r"/(?:Applications/[^\n]+\.app/Contents/Developer/Toolchains/XcodeDefault\.xctoolchain|Library/Developer/CommandLineTools)/usr/bin/clang",
                    text,
                ),
                "preflight_compiler_role",
            )
        elif role == "sdk":
            require(
                text.startswith(("/Applications/", "/Library/Developer/CommandLineTools/"))
                and re.fullmatch(r"MacOSX[0-9]*(?:\.[0-9]+)*\.sdk", self.path.name),
                "preflight_sdk_role",
            )
        else:
            raise Refusal("preflight_tool_role")
        named = self.path.lstat()
        # Name only the refused role and predicate; keep the original admission guard.
        require(
            named.st_uid == 0,
            "preflight_compiler_owner" if role == "compiler" else "preflight_sdk_owner",
        )
        require(
            not named.st_mode & 0o022,
            "preflight_compiler_writable" if role == "compiler" else "preflight_sdk_writable",
        )
        require(
            stat.S_ISREG(named.st_mode) if role == "compiler" else stat.S_ISDIR(named.st_mode),
            "preflight_compiler_kind" if role == "compiler" else "preflight_sdk_kind",
        )
        require(
            named.st_uid == 0
            and not named.st_mode & 0o022
            and (
                stat.S_ISREG(named.st_mode) if role == "compiler" else stat.S_ISDIR(named.st_mode)
            ),
            "preflight_apple_tool",
        )
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
        if role == "sdk":
            flags |= os.O_DIRECTORY
        self.fd = os.open(self.path, flags)
        self.identity = stamp(named)
        try:
            self.current()
        except BaseException:
            consumed, self.fd = self.fd, None
            os.close(consumed)
            raise

    def current(self):
        require(
            stamp(os.fstat(self.fd)) == self.identity and stamp(self.path.lstat()) == self.identity,
            "preflight_tool_changed",
            [self],
        )

    def close(self):
        consumed, self.fd = self.fd, None
        if consumed is not None:
            os.close(consumed)


def _admit_preflight_tool(path, role):
    """Admit only a closed ordinary Apple source role before the ABI probes."""
    return PreflightTool(path, role)


def _preflight_now():
    """An unavailable or invalid clock stops new native operations."""
    try:
        value = time.monotonic()
    except BaseException as error:
        raise Refusal("preflight_clock_unavailable") from error
    require(type(value) is float and math.isfinite(value) and value >= 0, "preflight_clock_refused")
    return value


def _run_preflight_owned(owner_module, arguments, native, deadline, owners):
    """Run a registered ordinary child under one supplied absolute deadline.

    New ctypes bridge/filesec objects and sudo are forbidden here. Closure uses
    the published native owner, not process.poll or a JSON observation. Only
    ordinary inherited PGIDs are covered. Unknown closure retains the actual
    parent/group objects with operations stopped, never a false terminal ACK.
    """
    import fcntl
    import signal

    require(
        type(deadline) is float and math.isfinite(deadline) and deadline > 0,
        "preflight_absolute_deadline",
    )
    group = None
    output, errors = bytearray(), bytearray()

    def register(acquired):
        nonlocal group
        group = acquired
        owners.append(acquired)

    def reap_closed():
        require(
            not group.reaped and group.process.returncode is None,
            "preflight_child_already_reaped",
            owners,
        )
        if not group.closed_before_reap():
            return None
        remaining = deadline - _preflight_now()
        require(remaining > 0, "preflight_reap_deadline", owners)
        group.reap_started = True
        group.process.wait(timeout=remaining)
        group.reaped = True
        return group.process.returncode

    def drain_outputs():
        reached_eof = True
        for stream, data in ((group.process.stdout, output), (group.process.stderr, errors)):
            while True:
                require(
                    fcntl.fcntl(stream.fileno(), fcntl.F_GETFL) & os.O_NONBLOCK,
                    "preflight_output_became_blocking",
                    owners,
                )
                try:
                    value = os.read(stream.fileno(), 65536)
                except BlockingIOError:
                    reached_eof = False
                    break
                if not value:
                    break
                data.extend(value)
                require(len(data) <= 65536, "preflight_output_limit", owners)
        return reached_eof

    try:
        require(_preflight_now() < deadline - 3, "preflight_acquisition_deadline", owners)
        owner_module.acquire_owned(
            arguments,
            native,
            register,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
        )
        require(group is not None, "preflight_child_unregistered", owners)
        for stream in (group.process.stdout, group.process.stderr):
            fcntl.fcntl(
                stream.fileno(),
                fcntl.F_SETFL,
                fcntl.fcntl(stream.fileno(), fcntl.F_GETFL) | os.O_NONBLOCK,
            )
        while True:
            require(_preflight_now() < deadline - 3, "preflight_operation_deadline", owners)
            drain_outputs()
            status = reap_closed()
            if status is not None:
                # A terminal child may have written between the prior read and
                # its final observation. Drain again after physical closure.
                require(drain_outputs(), "preflight_output_writer_not_retired", owners)
                return status, bytes(output), bytes(errors)
            time.sleep(0.001)
    except BaseException:
        if group is not None and not group.reaped:
            try:
                for number in (signal.SIGTERM, signal.SIGKILL):
                    require(_preflight_now() < deadline, "preflight_cleanup_deadline", owners)
                    if reap_closed() is not None:
                        break
                    group.observe_exit()  # A lost direct-child reservation denies the signal.
                    try:
                        os.killpg(group.process.pid, number)
                    except ProcessLookupError:
                        pass
                    until = min(deadline, _preflight_now() + 0.05)
                    while _preflight_now() < until:
                        if reap_closed() is not None:
                            break
                        time.sleep(0.001)
                    if group.reaped:
                        break
                require(group.reaped, "preflight_native_retirement_debt", owners)
            except BaseException:
                # Existing SDK observation budgets do not manufacture physical retirement.
                while True:
                    time.sleep(1)
        raise
    finally:
        if group is not None and group.reaped:
            for stream in (group.process.stdout, group.process.stderr):
                stream.close()


def native_abi_preflight(repository, output, deadline, native):
    """Observe both actual SDK ABIs before constructing new typed native wrappers.

    The immutable result contains ABI data only. Actual root UID, protected
    source/namespace, native compiler custody and privileged retirement remain
    independent prerequisites; ordinary probe output grants none of them.
    """
    import hashlib
    import tempfile

    require(sys.platform == "darwin" and os.geteuid() != 0, "native_ordinary_caller")
    require(
        type(deadline) is float and math.isfinite(deadline) and deadline > 0,
        "preflight_absolute_deadline",
    )
    sources, copies, tools, images, owners = [], [], [], [], []
    scope = None
    try:
        directory = Path(__file__).resolve(strict=True).parent
        for name, expected in SDK_ORACLE_SOURCE_PINS.items():
            held = Held(directory / name)
            sources.append(held)
            require(
                hashlib.sha256(held.data).hexdigest() == expected,
                "preflight_oracle_source_pin",
                sources,
            )
            held.current()
        owner_module = _load_published_ownership(repository)

        def child(arguments):
            status, stdout, stderr = _run_preflight_owned(
                owner_module, arguments, native, deadline, owners
            )
            require(status == 0 and not stderr, "preflight_owned_child_refused", owners)
            return stdout

        compiler_bytes = child(["/usr/bin/xcrun", "--find", "clang"])
        sdk_bytes = child(["/usr/bin/xcrun", "--show-sdk-path"])
        require(
            compiler_bytes.endswith(b"\n")
            and compiler_bytes.count(b"\n") == 1
            and sdk_bytes.endswith(b"\n")
            and sdk_bytes.count(b"\n") == 1,
            "preflight_tool_transcript",
        )
        compiler = compiler_bytes[:-1].decode("utf-8")
        sdk = sdk_bytes[:-1].decode("utf-8")
        require(
            re.fullmatch(
                r"/(?:Applications/[^\n]+\.app/Contents/Developer/Toolchains/XcodeDefault\.xctoolchain|Library/Developer/CommandLineTools)/usr/bin/clang",
                compiler,
            ),
            "preflight_compiler_role",
        )
        require(
            sdk.startswith(("/Applications/", "/Library/Developer/CommandLineTools/"))
            and re.fullmatch(r"MacOSX[0-9]*(?:\.[0-9]+)*\.sdk", Path(sdk).name),
            "preflight_sdk_role",
        )
        tools.append(_admit_preflight_tool(compiler, "compiler"))
        tools.append(_admit_preflight_tool(sdk, "sdk"))
        parent = Path(output).resolve(strict=True)
        require(
            parent.is_dir() and stat.S_IMODE(parent.stat().st_mode) == 0o700,
            "preflight_private_parent",
        )
        scope = Path(tempfile.mkdtemp(prefix="sdk-abi-", dir=parent)).resolve(strict=True)
        observations = []
        for source in sources:
            for tool in tools:
                tool.current()
            source.current()
            copied = scope / source.path.name
            with copied.open("xb") as stream:
                stream.write(source.data)
            held_copy = Held(copied)
            copies.append(held_copy)
            require(held_copy.data == source.data, "preflight_compiler_input_pin", copies)
            held_copy.current()
            image = scope / source.path.stem
            require(
                not child(
                    [
                        compiler,
                        "-std=c17",
                        "-Wno-deprecated-declarations",
                        "-isysroot",
                        sdk,
                        str(copied),
                        "-o",
                        str(image),
                    ]
                ),
                "preflight_compiler_output",
                owners,
            )
            held_copy.current()
            source.current()
            for tool in tools:
                tool.current()
            held_image = Held(image)
            images.append(held_image)
            held_image.current()
            observations.append(child([str(image)]))
            held_image.current()
        return parse_sdk_abi_pair(observations[0], observations[1])
    finally:
        for subject in reversed(images + copies + sources + tools):
            subject.close()
        # Completed ordinary evidence is retained for native review. Its bytes
        # confer no root executable/namespace authority and are never run elevated.


class OrdinaryNative:
    """Direct sudo ownership never impersonates ownership of its root descendants."""

    def __init__(self, repository, bridge):
        import importlib.util

        module_path = Path(repository) / "tools/diagnostics/macos_owned_process.py"
        specification = importlib.util.spec_from_file_location(
            "root_bootstrap_ordinary_native", module_path
        )
        module = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(module)
        self.groups = module.NativeProcessGroups.__new__(module.NativeProcessGroups)
        import ctypes

        self.groups.library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.groups.library.proc_listpids.argtypes = [
            ctypes.c_uint32,
            ctypes.c_uint32,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        self.groups.library.proc_listpids.restype = ctypes.c_int
        self.groups.library.proc_pidinfo.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint64,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        self.groups.library.proc_pidinfo.restype = ctypes.c_int
        self.bridge = bridge
        self.owners = []

    def acquire(self, command, deadline, *, stdin=subprocess.DEVNULL):
        # start_new_session obtains an ordinary direct-child PGID; sudo descendants may leave it.
        process = subprocess.Popen(
            command,
            stdin=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
            start_new_session=True,
        )
        self.owners.append(process)
        import fcntl

        try:
            for stream in (process.stdout, process.stderr):
                fcntl.fcntl(
                    stream.fileno(),
                    fcntl.F_SETFL,
                    fcntl.fcntl(stream.fileno(), fcntl.F_GETFL) | os.O_NONBLOCK,
                )
        except BaseException:
            try:
                self.finish(process, deadline)
            except BaseException:
                # A setup error after sudo acquisition cannot discard the real direct owner.
                # No ordinary PGID signal is used as root-descendant authority.
                import time

                while True:
                    time.sleep(1)
            raise
        return process

    def finish(self, process, deadline):
        import time

        stdout, stderr = bytearray(), bytearray()
        while True:
            require(time.monotonic() < deadline, "ordinary_child_deadline", self.owners)
            for stream, data in ((process.stdout, stdout), (process.stderr, stderr)):
                import fcntl

                require(
                    fcntl.fcntl(stream.fileno(), fcntl.F_GETFL) & os.O_NONBLOCK,
                    "ordinary_output_reader_became_blocking",
                    self.owners,
                )
                try:
                    chunk = os.read(stream.fileno(), 65536)
                except BlockingIOError:
                    chunk = b""
                data.extend(chunk)
                require(len(data) <= 262144, "ordinary_child_output_bound", self.owners)
            receipt = self.bridge.observe_pid(process.pid)
            if receipt is not None and not self.groups.live_members(process.pid, process.pid):
                pid, status = os.waitpid(process.pid, 0)
                require(pid == process.pid, "ordinary_child_reap", self.owners)
                process.returncode = os.waitstatus_to_exitcode(status)
                process.stdout.close()
                process.stderr.close()
                self.owners.remove(process)
                return process.returncode, bytes(stdout), bytes(stderr)
            time.sleep(0.001)

    def fixed_tool(self, command, deadline):
        process = self.acquire(command, deadline)
        status, stdout, stderr = self.finish(process, deadline)
        require(status == 0 and not stderr, "fixed_apple_tool", self.owners)
        return stdout.decode("utf-8").rstrip("\n")


def run(repository, output):
    """Execute the fixed root bootstrap; no signing or runtime readiness is granted."""
    import base64
    import errno
    import fcntl
    import hashlib
    import importlib.util
    import time

    require(sys.platform == "darwin" and os.geteuid() != 0, "native_ordinary_caller")
    deadline = _preflight_now() + ROOT_SECONDS
    published = _load_published_ownership(repository)
    published_native = published.NativeProcessGroups()
    abi_observation = native_abi_preflight(repository, output, deadline, published_native)
    directory = Path(__file__).resolve(strict=True).parent
    inputs = [
        Held(directory / name)
        for name in (
            "root_process_prerequisite.c",
            "darwin_waitid_bridge.py",
            "root_process_bootstrap.py",
            "native_abi_observation.py",
        )
    ]
    require(hashlib.sha256(inputs[0].data).hexdigest() == SOURCE_SHA256, "fixed_source_pin", inputs)
    require(hashlib.sha256(inputs[1].data).hexdigest() == BRIDGE_SHA256, "fixed_bridge_pin", inputs)
    require(
        hashlib.sha256(inputs[2].data).hexdigest() == BOOTSTRAP_SHA256,
        "fixed_bootstrap_pin",
        inputs,
    )
    require(
        hashlib.sha256(inputs[3].data).hexdigest() == ABI_OBSERVATION_SHA256,
        "fixed_abi_observation_pin",
        inputs,
    )
    abi_module = _load_abi_observation_module()
    encoded_abi = abi_module.encode_sdk_abi_observation(
        abi_module.NativeAbiObservation(abi_observation.waitid, abi_observation.filesec)
    )
    spec = importlib.util.spec_from_file_location("fixed_root_wait_bridge", inputs[1].path)
    bridge_module = importlib.util.module_from_spec(spec)
    exec(compile(inputs[1].data, str(inputs[1].path), "exec"), bridge_module.__dict__)
    for item in inputs:
        item.current()
    ordinary = OrdinaryNative(repository, bridge_module.DarwinWaitId())
    python = Path(ordinary.fixed_tool(["/usr/bin/xcrun", "--find", "python3"], deadline)).resolve(
        strict=True
    )
    compiler = Path(ordinary.fixed_tool(["/usr/bin/xcrun", "--find", "clang"], deadline)).resolve(
        strict=True
    )
    sdk = Path(ordinary.fixed_tool(["/usr/bin/xcrun", "--show-sdk-path"], deadline)).resolve(
        strict=True
    )
    require(
        str(python).startswith(("/Applications/", "/Library/Developer/")),
        "apple_python_role",
        inputs,
    )
    # Ordinary admission occurs before the privileged interpreter can load this closure.
    # The root bootstrap independently re-admits the same physical runtime afterward.
    runtime_probe = "import json,sys,os;print(json.dumps([sys.executable,sys.prefix,os.__file__]))"
    runtime = ordinary.fixed_tool([str(python), "-I", "-S", "-B", "-c", runtime_probe], deadline)
    import json

    interpreter, prefix, os_file = json.loads(runtime)
    require(Path(interpreter).resolve(strict=True) == python, "apple_python_identity", inputs)
    bootstrap_namespace = {"__name__": "fixed_ordinary_runtime_admission"}
    exec(compile(inputs[2].data, str(inputs[2].path), "exec"), bootstrap_namespace)
    acl = bootstrap_namespace["RootACL"]()
    root_path_type = bootstrap_namespace["RootPath"]
    admitted_runtime = []
    try:
        admitted_runtime.append(root_path_type(python, acl))
        for root in {Path(prefix).resolve(strict=True), Path(os_file).resolve(strict=True).parent}:
            admitted_runtime.append(root_path_type(root, acl, directory=True))
            for path in root.rglob("*"):
                require(time.monotonic() < deadline, "runtime_admission_deadline", inputs)
                target = path.resolve(strict=True)
                require(target.is_relative_to(root), "runtime_external_library_link", inputs)
                held = root_path_type(target, acl, directory=target.is_dir())
                held.close()
        for held in admitted_runtime:
            held.current()
    finally:
        for held in admitted_runtime:
            held.close()
    root_code = (
        inputs[3].data.decode("utf-8")
        + "\n"
        + inputs[1].data.decode("utf-8")
        + "\n"
        + inputs[2].data.decode("utf-8")
        + "\nroot_bootstrap(sys.argv[1:], DarwinWaitId, decode_sdk_abi_observation)\n"
    )
    reader, writer = os.pipe()
    fcntl.fcntl(reader, fcntl.F_SETFL, fcntl.fcntl(reader, fcntl.F_GETFL) | os.O_NONBLOCK)
    owner = None
    retired = False
    denied = False
    lines = []
    try:
        owner = ordinary.acquire(
            [
                "/usr/bin/sudo",
                "-n",
                "--",
                str(python),
                "-I",
                "-S",
                "-B",
                "-c",
                root_code,
                str(compiler),
                str(sdk),
                base64.b64encode(inputs[0].data).decode("ascii"),
                str(int(deadline * 1_000_000_000)),
                encoded_abi,
            ],
            deadline,
            stdin=reader,
        )
        consumed, reader = reader, None
        os.close(consumed)
        buffered = bytearray()
        while True:
            require(
                time.monotonic() < deadline, "root_bootstrap_deadline", [ordinary, owner, *inputs]
            )
            require(
                fcntl.fcntl(owner.stdout.fileno(), fcntl.F_GETFL) & os.O_NONBLOCK,
                "root_protocol_reader_became_blocking",
                [ordinary, owner, *inputs],
            )
            try:
                chunk = os.read(owner.stdout.fileno(), 4096)
            except BlockingIOError:
                chunk = b""
            buffered.extend(chunk)
            require(len(buffered) <= 1024, "root_protocol_bound", [ordinary, owner, *inputs])
            while b"\n" in buffered:
                line, _, rest = buffered.partition(b"\n")
                buffered = bytearray(rest)
                token = closed_line(bytes(line) + b"\n")
                lines.append(token)
                if token.startswith("V1 HELD "):
                    require(len(lines) == 1, "root_protocol_order", [ordinary, owner])
                    os.write(writer, b"GO\n")
                elif token.startswith("V1 CHILD "):
                    require(len(lines) == 2, "root_protocol_order", [ordinary, owner])
                    child_pid = int(token.split()[-1])
                    # Observational denial cannot itself authorize any PID operation.
                    try:
                        os.kill(child_pid, 0)
                    except PermissionError as error:
                        require(
                            error.errno == errno.EPERM, "ordinary_signal_denial", [ordinary, owner]
                        )
                        denied = True
                    require(denied, "root_child_not_protected", [ordinary, owner])
                    consumed, writer = writer, None
                    os.close(consumed)
                elif token == "V1 CHILD_RETIRED":
                    require(len(lines) == 3, "root_protocol_order", [ordinary, owner])
                elif token == "V1 RETIRED":
                    require(len(lines) == 4, "root_protocol_order", [ordinary, owner])
                    retired = True
            receipt = ordinary.bridge.observe_pid(owner.pid)
            if receipt is not None:
                break
            time.sleep(0.001)
        status, stdout, stderr = ordinary.finish(owner, deadline)
        require(
            status == 0 and not stdout and not stderr and retired and denied and not buffered,
            "root_bootstrap_not_qualified",
            [ordinary, owner, *inputs],
        )
        return {
            "schema": 1,
            "root_process_prerequisite": True,
            "root_child_signal_denied": True,
            "physical_root_worker_exit_observed": True,
            "native_reservations_reaped": 9,
            "abi_preflight_reservations_reaped": 6,
            "native_abi_preflight_validated": True,
            "signing_authority": False,
            "installation_qualified": False,
            "runtime_qualified": False,
        }
    except BaseException:
        if writer is not None:
            consumed, writer = writer, None
            os.close(consumed)
        # Do not signal sudo's PGID as if it were a root-descendant reservation.
        # An unresolved privileged owner remains live, with its absolute operations budget expired.
        if owner is not None and owner.returncode is None:
            try:
                receipt = ordinary.bridge.observe_pid(owner.pid)
                if receipt is not None and not ordinary.groups.live_members(owner.pid, owner.pid):
                    ordinary.finish(owner, deadline)
            except BaseException:
                pass
            if owner.returncode is None:
                while True:
                    time.sleep(1)
        raise
    finally:
        if reader is not None:
            consumed, reader = reader, None
            os.close(consumed)
        if writer is not None:
            consumed, writer = writer, None
            os.close(consumed)
        for item in inputs:
            item.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository")
    parser.add_argument("output")
    arguments = parser.parse_args()
    try:
        result = run(arguments.repository, arguments.output)
    except (Refusal, OSError, subprocess.SubprocessError) as error:
        print("UNAVAILABLE: root process prerequisite", file=sys.stderr)
        # Failure observations name only this boundary; they grant no native authority.
        reason = "unclassified"
        if type(error) is Refusal:
            named = error.code
            if type(named) is str and named in (
                "abi_observation_source_pin",
                "apple_python_identity",
                "apple_python_role",
                "digest",
                "fixed_abi_observation_pin",
                "fixed_apple_tool",
                "fixed_bootstrap_pin",
                "fixed_bridge_pin",
                "fixed_source_pin",
                "native_ordinary_caller",
                "ordinary_child_deadline",
                "ordinary_child_output_bound",
                "ordinary_child_reap",
                "ordinary_output_reader_became_blocking",
                "ordinary_signal_denial",
                "preflight_absolute_deadline",
                "preflight_acquisition_deadline",
                "preflight_apple_tool",
                "preflight_compiler_owner",
                "preflight_compiler_writable",
                "preflight_compiler_kind",
                "preflight_sdk_owner",
                "preflight_sdk_writable",
                "preflight_sdk_kind",
                "preflight_child_already_reaped",
                "preflight_child_unregistered",
                "preflight_cleanup_deadline",
                "preflight_clock_refused",
                "preflight_clock_unavailable",
                "preflight_compiler_input_pin",
                "preflight_compiler_output",
                "preflight_compiler_role",
                "preflight_native_retirement_debt",
                "preflight_operation_deadline",
                "preflight_oracle_source_pin",
                "preflight_output_became_blocking",
                "preflight_output_limit",
                "preflight_output_writer_not_retired",
                "preflight_owned_child_refused",
                "preflight_private_parent",
                "preflight_reap_deadline",
                "preflight_sdk_role",
                "preflight_tool_changed",
                "preflight_tool_path",
                "preflight_tool_role",
                "preflight_tool_transcript",
                "protocol",
                "published_ordinary_owner_pin",
                "root_bootstrap_deadline",
                "root_bootstrap_not_qualified",
                "root_child_not_protected",
                "root_locator",
                "root_protocol_bound",
                "root_protocol_order",
                "root_protocol_reader_became_blocking",
                "runtime_admission_deadline",
                "runtime_external_library_link",
                "source",
                "source_changed",
                "source_path",
            ):
                reason = named
        elif isinstance(error, OSError):
            reason = "os_error"
        elif isinstance(error, subprocess.SubprocessError):
            reason = "subprocess_error"
        import json

        observation = {
            "schema": 1,
            "kind": "root_process_prerequisite_refusal_observation",
            "stage": "prerequisite",
            "reason": reason,
            "authority": False,
            "native_verdict": "unchanged",
        }
        try:
            print(
                "ERGOPTI_ROOT_PREREQUISITE_DIAGNOSTIC "
                + json.dumps(observation, sort_keys=True, separators=(",", ":")),
                file=sys.stderr,
            )
        except OSError:
            # The original UNAVAILABLE prefix and69 already refuse qualification.
            pass
        return 69
    import json

    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
