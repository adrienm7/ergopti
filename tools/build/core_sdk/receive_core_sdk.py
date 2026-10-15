"""Private genuine Xcode/Core receiving; never execute the Core application.

This is source-owned software receiving, not installation, input readiness,
maintenance authorization or a claim about the customer's lease incident.
The caller retains a failed Attempt until its original group debts settle.
"""

import hashlib
import importlib.util
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import sys
import time

SOURCE_SHA = "c8da59d08b4b43d968989f1eecf0e11199b6b1027477884a77cb9a8de3faa7c8"
_source_path = Path(__file__).resolve().with_name("operational_core_source.py")
_source_info = _source_path.lstat()
_source_bytes = _source_path.read_bytes()


def _input_identity(info):
    return (
        info.st_dev,
        info.st_ino,
        info.st_uid,
        info.st_mode,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


if hashlib.sha256(_source_bytes).hexdigest() != SOURCE_SHA or _input_identity(
    _source_path.lstat()
) != _input_identity(_source_info):
    raise RuntimeError("Fixed operational source owner changed")
_source_name = "fixed_operational_core_source_owner"
_source_spec = importlib.util.spec_from_loader(_source_name, loader=None)
source = importlib.util.module_from_spec(_source_spec)
source.__file__ = str(_source_path)
sys.modules[_source_name] = source
exec(compile(_source_bytes, str(_source_path), "exec"), source.__dict__)

OWNER_SHA = "9b985af7e8bf549cb843b289885a2bea38a67ea3ce44defaf389dab1001fef98"
CONTROLS = (
    "real_owned_child_exit",
    "live_child_socket_EOF",
    "actual_owned_child_exec",
    "real_monitor_EBADF",
    "real_socket_EBADF",
    "already_reaped_owned_child",
)
_REFUSED = []


def _load_owner(repository):
    path = repository / "tools/diagnostics/macos_owned_process.py"
    require = source.require
    require(path.resolve(strict=True) == path and path.is_file(), "Process guardian redirects")
    before = path.lstat()
    data = path.read_bytes()
    require(
        source.digest(data) == OWNER_SHA
        and source.input_identity(path.lstat()) == source.input_identity(before),
        "Original process guardian changed",
    )
    name = "core_sdk_original_native_process_guardian"
    spec = importlib.util.spec_from_loader(name, loader=None)
    module = importlib.util.module_from_spec(spec)
    module.__file__ = str(path)
    sys.modules[name] = module
    exec(compile(data, str(path), "exec"), module.__dict__)
    require(
        source.input_identity(path.lstat()) == source.input_identity(before)
        and path.read_bytes() == data,
        "Guardian changed during loading",
    )
    return module, (path, before, data)


class Attempt:
    """Retain every registered owner, including acquire-before-return refusal."""

    def __init__(self, module, owner, owner_input):
        self.module, self.owner, self.owner_input = module, owner, owner_input
        self.backend = None
        self.phases, self.handlers, self.statuses = [], {}, []
        self.products, self.failure, self.receipt = [], None, None

    def install_handlers(self):
        def interrupted(_signal, _frame):
            raise self.module.OwnedProcessInterrupted("Core SDK receiving interrupted")

        for sig in (signal.SIGINT, signal.SIGTERM):
            self.handlers[sig] = signal.signal(sig, interrupted)

    def current_owner(self):
        path, before, data = self.owner_input
        source.require(
            source.input_identity(path.lstat()) == source.input_identity(before)
            and path.read_bytes() == data,
            "Original guardian input changed",
        )

    def phase(self, name, command, cwd, deadline):
        self.current_owner()
        source.require(time.monotonic() < deadline, "Original absolute SDK deadline exhausted")
        source.require(self.backend is not None, "Actual original phase owner missing")
        name = name.replace("-", "_")
        stdout = self.owner / (name + ".stdout")
        stderr = self.owner / (name + ".stderr")
        # Authentic original begin_phase registers before FDs/Popen, and Popen
        # inherits the original outer-owned group. No inner sessions are made.
        operation = self.backend.begin_phase(
            name, command, cwd, self.owner, deadline, self.phases.append
        )
        source.require(
            operation.process is not None and os.getpgid(operation.process.pid) == os.getpgrp(),
            "Native child escaped original owned group",
        )
        while not self.backend.phase_ready(operation):
            source.require(time.monotonic() < deadline, "Original absolute SDK deadline exhausted")
            time.sleep(min(0.02, max(0, deadline - time.monotonic())))
        try:
            self.backend.finish_phase(operation)
        except self.backend.NativeBuildError as error:
            record = operation.record
            # Original finish_phase intentionally rejects nonzero commands.
            # Retain its exact normal direct status for the later negative
            # judge only after every original child/FD completion cut passed.
            source.require(
                error.code == "phase_failed"
                and operation.finished
                and operation.waited
                and not operation.debt
                and not operation.secondary_failures
                and record is not None
                and record.get("status") == "failed",
                "Original phase closure or evidence refused",
            )
        source.require(
            operation.finished
            and operation.waited
            and not operation.debt
            and not operation.secondary_failures
            and operation.record is not None,
            "Original phase debt remains",
        )
        status = operation.process.returncode
        source.require(type(status) is int and 0 <= status <= 255, "Compiler did not exit normally")
        source.require(
            time.monotonic() <= deadline, "Compiler finished after absolute SDK deadline"
        )
        source.require(
            stdout.stat().st_size <= 16 * 1024 * 1024 and stderr.stat().st_size <= 16 * 1024 * 1024,
            "Compiler stream bound exceeded",
        )
        self.statuses.append((name, status))
        (self.owner / (name + ".status")).write_text(str(status) + "\n")
        self.current_owner()
        return status, stdout.read_text(), stderr.read_text()

    def settle(self):
        """Attempt every owned closure; retain any refused original custody."""
        failures = []
        try:
            for sig in self.handlers:
                signal.signal(sig, signal.SIG_IGN)
            for operation in self.phases:
                try:
                    if not operation.finished:
                        if operation.finish_started or not self.backend.phase_ready(operation):
                            failures.append("original_phase_retirement_refused")
                            continue
                        try:
                            self.backend.finish_phase(operation)
                        except BaseException:
                            pass  # Inspect the actual retained closure fields below.
                    if (
                        not operation.finished
                        or operation.debt
                        or operation.launch_debt
                        or (operation.process is not None and not operation.waited)
                        or operation.secondary_failures
                    ):
                        failures.append("original_phase_retirement_refused")
                except BaseException as error:
                    failures.append(type(error).__name__)
        finally:
            # On refusal retain the nonterminating cleanup disposition. The
            # original outer custodian still owns this SAME native group.
            if not failures:
                for sig, handler in self.handlers.items():
                    try:
                        signal.signal(sig, handler)
                    except BaseException as error:
                        failures.append(type(error).__name__)
        if failures:
            if self not in _REFUSED:
                _REFUSED.append(self)
            self.receipt = None
            self.failure = "original_custody_refused"
            return False
        return True


def receive(repository, owner):
    """Return retained Attempt; success only after real full native receiving."""
    require = source.require
    require(
        platform.system() == "Darwin" and platform.machine() in ("arm64", "x86_64"),
        "Actual Darwin ARM/Intel required",
    )
    require(
        os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
        and os.environ.get("ERGOPTI_RELEASE_MODE") == "false",
        "Manual nonrelease receiving only",
    )
    sha = os.environ.get("GITHUB_SHA", "")
    require(re.fullmatch(r"[0-9a-f]{40}", sha), "Exact hosted source SHA missing")
    require(
        os.environ.get("ERGOPTI_CORE_SDK_ARCH") == platform.machine(),
        "Wrong actual matrix architecture",
    )
    run_id, run_attempt = (
        os.environ.get("GITHUB_RUN_ID", ""),
        os.environ.get("GITHUB_RUN_ATTEMPT", ""),
    )
    require(
        re.fullmatch(r"[1-9][0-9]{0,19}", run_id) and re.fullmatch(r"[1-9][0-9]{0,5}", run_attempt),
        "Hosted run/attempt identity missing",
    )
    repository, owner = map(Path, (repository, owner))
    module, owner_input = _load_owner(repository)
    # All phases share this one original300s calibration budget; preparation and
    # native tool acquisition do not create fresh compiler phase deadlines.
    deadline = time.monotonic() + 300
    attempt = Attempt(module, owner, owner_input)
    image = None
    held_products = []
    try:
        attempt.install_handlers()
        build, _, _, _, _ = source._load_build(repository, deadline)
        attempt.backend = build.BASE
        build._OWNER(owner)
        require(not any(owner.iterdir()), "SDK requires a fresh empty private owner")
        git = shutil.which("git")
        require(git is not None, "Actual source Git unavailable")
        git = str(Path(git).resolve(strict=True))
        status, actual_head, _ = attempt.phase(
            "source-head", [git, "-C", str(repository), "rev-parse", "HEAD"], owner, deadline
        )
        require(
            status == 0 and actual_head == sha + "\n",
            "Actual repository HEAD differs from hosted source",
        )
        # A real Git tree plus local Git blob identity binds every executed new
        # module/source leaf, rather than accepting a caller inventory receipt.
        status, tree, _ = attempt.phase(
            "source-tree",
            [
                git,
                "-C",
                str(repository),
                "ls-tree",
                "-rz",
                "--full-tree",
                sha,
                "--",
                "tools/build/core_sdk",
            ],
            owner,
            deadline,
        )
        require(status == 0, "Committed SDK source tree unavailable")
        committed = {}
        for item in tree.split("\0"):
            if not item:
                continue
            prefix, relative = item.split("\t", 1)
            mode, kind, oid = prefix.split(" ")
            require(
                mode == "100644" and kind == "blob" and relative not in committed,
                "Nonordinary or duplicate committed SDK source",
            )
            committed[relative] = oid
        required = {
            "tools/build/core_sdk/" + name
            for name in (
                "operational_core_source.py",
                "sdk_source.py",
                "receive_core_sdk.py",
                "run_core_sdk.py",
                "installed_cli_frontend.py",
                "generate_installed_cli_source.py",
                "installed_cli_source.json",
                "inputs/hs274-installed-cli.source.hpp",
            )
        }
        required |= {
            "tools/build/core_sdk/source/" + row[0] for row in source.rows(repository, deadline)
        }
        require(set(committed) == required, "Committed fixed SDK source roster differs")
        for relative, oid in committed.items():
            path = repository / relative
            require(
                path.resolve(strict=True) == path and path.is_file(),
                "Committed SDK source redirects",
            )
            body = path.read_bytes()
            actual_oid = hashlib.sha1(
                b"blob " + str(len(body)).encode("ascii") + b"\0" + body
            ).hexdigest()
            require(actual_oid == oid, "Executed SDK source differs from genuine committed blob")
        pristine = owner / "pristine"
        require(
            not pristine.exists() and not pristine.is_symlink(), "Pristine acquisition collision"
        )
        for label, command in (
            (
                "acquisition",
                [
                    git,
                    "-c",
                    "http.sslVerify=true",
                    "-c",
                    "transfer.fsckObjects=true",
                    "clone",
                    "--no-checkout",
                    "https://github.com/pqrs-org/Karabiner-Elements.git",
                    str(pristine),
                ],
            ),
            ("checkout", [git, "-C", str(pristine), "checkout", "--detach", build.BASE.UPSTREAM]),
            (
                "submodules",
                [git, "-C", str(pristine), "submodule", "update", "--init", "--recursive"],
            ),
        ):
            status, _, _ = attempt.phase(label, command, owner, deadline)
            require(status == 0, "Genuine pinned pristine acquisition refused")
        observed = {}
        for name, relative in (
            ("upstream", ""),
            ("cpm", "vendor/cpm-cmake-package-lock"),
            ("vhd", "vendor/Karabiner-DriverKit-VirtualHIDDevice"),
        ):
            status, out, _ = attempt.phase(
                "identity-" + name,
                [git, "-C", str(pristine / relative), "rev-parse", "HEAD"],
                owner,
                deadline,
            )
            require(status == 0, "Actual original submodule identity unavailable")
            observed[name] = out.strip()
        build.BASE.verify_pins(observed)
        status, _, _ = attempt.phase(
            "source-clean", [git, "-C", str(pristine), "diff", "--exit-code"], owner, deadline
        )
        require(status == 0, "Pristine original source changed")
        image = source.prepare(repository, pristine, owner, deadline)
        build = source.build_owner(image, deadline)
        tools = {name: shutil.which(name) for name in ("xcodebuild", "xcrun")}
        require(all(tools.values()), "Actual Xcode toolchain unavailable")
        tool_inputs = []
        for name, value in tools.items():
            path = Path(value).resolve(strict=True)
            tools[name] = str(path)
            tool_inputs.append((path, path.stat()))
        tool_inputs.append((Path(git), Path(git).stat()))
        xcodegen, acquisition = build.BASE.acquire_xcodegen(owner, deadline)
        tools["xcodegen"] = str(xcodegen.resolve(strict=True))
        tool_inputs.append((xcodegen.resolve(strict=True), xcodegen.stat()))

        def current():
            require(
                source.input_identity(_source_path.lstat()) == source.input_identity(_source_info)
                and _source_path.read_bytes() == _source_bytes,
                "Fixed operational source code changed",
            )
            source.current(image, deadline)
            attempt.current_owner()
            for path, previous in tool_inputs:
                require(
                    source.input_identity(path.stat()) == source.input_identity(previous),
                    "Actual native tool image changed",
                )
            for product in held_products:
                build.current_product(product, image.root)

        def phase(name, command, cwd, expected_zero=True):
            current()
            status, out, err = attempt.phase(name, command, cwd, deadline)
            current()
            if expected_zero:
                require(status == 0, "Actual native compiler/tool phase failed")
            return status, out, err

        phase("xcode-version", [tools["xcodebuild"], "-version"], owner)
        phase("xcodegen-version", [tools["xcodegen"], "--version"], owner)
        phase("sdk-path", [tools["xcrun"], "--sdk", "macosx", "--show-sdk-path"], owner)
        root = image.root
        phase("version", [sys.executable, str(root / "scripts/update_version.py")], root)
        duktape = root / "vendor/duktape-src"
        phase("duktape-generate", [tools["xcodegen"], "generate"], duktape)
        phase("duktape-build", build.build_command(tools["xcodebuild"], duktape), duktape)
        held_products.append(build.product_snapshot(duktape / "build/Release/libduktape.a", root))
        cli = root / "src/bin/cli"
        phase("installed-cli-generate", [tools["xcodegen"], "generate"], cli)
        held_products.append(
            build.product_snapshot(cli / "ergoptiplus_remap_cli.xcodeproj/project.pbxproj", root)
        )
        phase("installed-cli-build", build.build_command(tools["xcodebuild"], cli), cli)
        cli_product_path = cli / "build/Release/ergoptiplus_remap_cli"
        cli_product = build.product_snapshot(cli_product_path, root)
        held_products.append(cli_product)
        _, cli_architectures, _ = phase(
            "installed-cli-architectures",
            [tools["xcrun"], "lipo", "-archs", str(cli_product_path)],
            cli,
        )
        require(
            set(cli_architectures.split()) == {"arm64", "x86_64"}
            and len(cli_architectures.split()) == 2,
            "Actual installed CLI universal architecture slices absent or duplicated",
        )
        attempt.products.append(
            ("installed-cli", str(cli_product.path), source.digest(cli_product.data))
        )
        console_rows = [row for row in build.TARGETS if row[0] == "console"]
        require(len(console_rows) == 1, "Actual console supplier role is missing or duplicated")
        _, console_recipe, console_relative = console_rows[0]
        console = root / console_recipe
        console_product_path = console / console_relative
        phase("console-generate", [tools["xcodegen"], "generate"], console)
        held_products.append(
            build.product_snapshot(
                console / (console_product_path.name + ".xcodeproj/project.pbxproj"), root
            )
        )
        phase("console-build", build.build_command(tools["xcodebuild"], console), console)
        console_product = build.product_snapshot(console_product_path, root)
        held_products.append(console_product)
        console_plist = build.product_snapshot(console_product_path.parents[1] / "Info.plist", root)
        held_products.append(console_plist)
        build.validate_plist(
            console_plist.data, "console", repository=repository, deadline=deadline
        )
        _, console_architectures, _ = phase(
            "console-architectures",
            [tools["xcrun"], "lipo", "-archs", str(console_product_path)],
            console,
        )
        require(
            set(console_architectures.split()) == {"arm64", "x86_64"}
            and len(console_architectures.split()) == 2,
            "Actual console universal architecture slices absent or duplicated",
        )
        attempt.products.append(
            ("console", str(console_product.path), source.digest(console_product.data))
        )
        project = root / "src/apps/CoreService"
        phase(
            "core-observer-generate",
            [tools["xcodegen"], "generate", "--spec", "observer-project.yml"],
            project,
        )
        held_products.append(
            build.product_snapshot(
                project / "ErgoptiPlus-Remap-Core-Observer.xcodeproj/project.pbxproj", root
            )
        )
        common = [
            tools["xcodebuild"],
            "-project",
            "ErgoptiPlus-Remap-Core-Observer.xcodeproj",
            "-configuration",
            "Release",
            "SYMROOT=" + str(project / "build"),
            "ARCHS=arm64 x86_64",
            "ONLY_ACTIVE_ARCH=NO",
            "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO",
            "GCC_GENERATE_DEBUGGING_SYMBOLS=NO",
            "SWIFT_ENABLE_EXPLICIT_MODULES=NO",
            "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS=NO",
        ]
        for name, target, relative in (
            (
                "core-positive",
                "ErgoptiPlus-Remap-Core",
                "build/Release/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core",
            ),
            (
                "observer-positive",
                "Core-NativeObserver-Positive",
                "build/Release/Core-NativeObserver-Positive",
            ),
        ):
            phase(name, common + ["-target", target], project)
            product = build.product_snapshot(project / relative, root)
            held_products.append(product)
            _, out, _ = phase(
                name + "-architectures",
                [tools["xcrun"], "lipo", "-archs", str(project / relative)],
                project,
            )
            require(
                set(out.split()) == {"arm64", "x86_64"} and len(out.split()) == 2,
                "Actual universal architecture slices absent or duplicated",
            )
            attempt.products.append((name, str(product.path), source.digest(product.data)))
        status, out, err = phase(
            "production-negative",
            common + ["-target", "Core-NativeObserver-Production-Negative"],
            project,
            False,
        )
        diagnostics = out + err
        require(
            status != 0
            and "fatal error:" not in diagnostics
            and "file not found" not in diagnostics
            and "Undefined symbols" not in diagnostics,
            "Dependency or link failure is not a macro-negative proof",
        )
        require(
            re.search(r"error: .*('issuer_exit'|'arm_issuer_monitor').*private", diagnostics),
            "Exact private observer access refusal absent",
        )
        compiler_errors = [line for line in diagnostics.splitlines() if "error:" in line]
        require(
            compiler_errors
            and all(
                (
                    re.search(r"('issuer_exit'|'arm_issuer_monitor').*private", line)
                    or re.search(r"no matching constructor.*'issuer_exit'", line)
                )
                for line in compiler_errors
            ),
            "Unrelated compiler failure cannot qualify production-negative",
        )
        current()
        executable = project / "build/Release/Core-NativeObserver-Positive"
        status, out, err = attempt.phase(
            "native-controls", [str(executable)], project, min(deadline, time.monotonic() + 70)
        )
        require(
            status == 0
            and not err
            and out.splitlines() == ["CONTROL " + name + " PASS" for name in CONTROLS],
            "Native six controls failed, skipped, duplicated or reordered",
        )
        current()
        attempt.products = tuple(attempt.products)
        attempt.module.exclusive_receipt(
            owner / "SOURCE.json",
            {
                "version": 1,
                "source_sha": sha,
                "run_id": run_id,
                "run_attempt": run_attempt,
                "actual_staged_inventory": source.inventory(image, deadline),
                "operational_source_module_sha256": SOURCE_SHA,
                "build_source_sha256": source.BUILD_SHA,
                "source_factory_sha256": source.FACTORY_SHA,
                "shipping_qualified": False,
            },
        )
        attempt.receipt = {
            "version": 1,
            "source_sha": sha,
            "run_id": run_id,
            "run_attempt": run_attempt,
            "scope": "complete_cli_and_console_and_core_sdk_and_observer_mechanics_only",
            "arch": platform.machine(),
            "direct_statuses": tuple(attempt.statuses),
            "controls": CONTROLS,
            "products": attempt.products,
            "image_terminal": False,
            "customer_exit73_resolved": False,
        }
    except BaseException as error:
        attempt.failure = type(error).__name__
        attempt.receipt = None
    finally:
        if not attempt.settle():
            attempt.receipt = None
    return attempt
