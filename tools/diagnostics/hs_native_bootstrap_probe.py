# tools/diagnostics/hs_native_bootstrap_probe.py
"""Measure installed native features at startup without admitting AppleEvents.

This supplementary owner launches the unchanged signed embedded application with
an owned Lua startup file. It never loads the full driver, supplies logger
authority, edits grants, or replaces the launch gate's required measurements.
"""

import json
import os
from pathlib import Path
import plistlib
import secrets
import signal
import stat
import subprocess
import time

from hs_delayed_timer_probe import (
    AppleScriptPreference,
    CONTRACT as TIMER_CONTRACT,
    NativeDelayedTimerProbe,
    SCRIPTING_TIMEOUT_SECONDS,
    SCRIPT_CLEANUP_TIMEOUT_SECONDS,
    unique_object,
    validate_receipt as validate_timer,
)
from hs_karabiner_config_probe import INITIAL_CONFIG, validate_receipt as validate_karabiner
from hs_script_scope_probe import validate_receipt as validate_script, validate_claim, recover_claim

CONTRACT = "hs.startup.supplementary-feature"
CONFIG_KEY = "MJConfigFile"
FEATURE_TIMEOUT_SECONDS = 15
RECEIPT_BYTE_LIMIT = 8 * 1024 * 1024
QUALIFICATION = "installed native feature only; no managed boot or AppleEvent admission"


def bounded_refusal(error):
    """Reuse the native diagnostic privacy policy without publishing command argv."""
    detail = (
        "TimeoutExpired: the owned native bootstrap command exceeded its unchanged deadline"
        if isinstance(error, subprocess.TimeoutExpired)
        else f"{type(error).__name__}: {error}"
    )
    return NativeDelayedTimerProbe.bounded_diagnostic_text(detail)


def read_receipt(path, limit=RECEIPT_BYTE_LIMIT):
    """Read a complete bounded owned regular file, rejecting aliases and duplicates."""
    with path.open("rb") as handle:
        opened = os.fstat(handle.fileno())
        named = path.lstat()
        if not stat.S_ISREG(named.st_mode) or (opened.st_dev, opened.st_ino) != (
            named.st_dev,
            named.st_ino,
        ):
            raise ValueError("A native bootstrap receipt is not its owned regular file")
        raw = handle.read(limit + 1)
    if len(raw) > limit:
        raise ValueError("A native bootstrap receipt exceeds its bounded inventory")
    return json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)


def publish(path, value):
    """Publish one fresh gate-owned input without replacing an existing answer."""
    with path.open("x", encoding="utf-8") as handle:
        handle.write(json.dumps(value, ensure_ascii=False) + "\n")


class StartupPreference:
    """Own only MJConfigFile while preserving unrelated current native preferences."""

    def __init__(self, domain, runner):
        self.domain = domain
        self.runner = runner
        self.reader = AppleScriptPreference(domain, runner)
        self.snapshot = None
        self.mutated = False
        self.attempted_value = None

    def configure(self, startup):
        """Retain the exact physical value before attempting native publication."""
        if self.snapshot is not None:
            raise RuntimeError("The bootstrap startup preference already has an owner")
        self.snapshot = self.reader.read_domain()
        self.mutated = True
        self.attempted_value = str(startup)
        result = self.runner(
            ["/usr/bin/defaults", "write", self.domain, CONFIG_KEY, "-string", str(startup)],
            capture_output=True,
            timeout=SCRIPTING_TIMEOUT_SECONDS,
        )
        if result.returncode or self.reader.read_domain().get(CONFIG_KEY) != str(startup):
            raise RuntimeError("The native startup preference did not acknowledge publication")

    def restore(self):
        """Restore the owned physical key only after its native writer has stopped."""
        if not self.mutated:
            return
        current = self.reader.read_domain()
        physical = {CONFIG_KEY: current[CONFIG_KEY]} if CONFIG_KEY in current else {}
        original = {CONFIG_KEY: self.snapshot[CONFIG_KEY]} if CONFIG_KEY in self.snapshot else {}
        if plistlib.dumps(physical) != plistlib.dumps(
            {CONFIG_KEY: self.attempted_value}
        ) and plistlib.dumps(physical) != plistlib.dumps(original):
            raise RuntimeError("A foreign startup preference owner refuses restoration")
        if CONFIG_KEY in self.snapshot:
            current[CONFIG_KEY] = self.snapshot[CONFIG_KEY]
        else:
            current.pop(CONFIG_KEY, None)
        result = self.runner(
            ["/usr/bin/defaults", "import", self.domain, "-"],
            input=plistlib.dumps(current),
            capture_output=True,
            timeout=SCRIPTING_TIMEOUT_SECONDS,
        )
        restored = self.reader.read_domain()
        removed = None
        if CONFIG_KEY not in self.snapshot and CONFIG_KEY in restored:
            removed = self.runner(
                ["/usr/bin/defaults", "delete", self.domain, CONFIG_KEY],
                capture_output=True,
                timeout=SCRIPTING_TIMEOUT_SECONDS,
            )
            restored = self.reader.read_domain()
        if (
            result.returncode
            or removed is not None
            and removed.returncode
            or plistlib.dumps(restored) != plistlib.dumps(current)
        ):
            raise RuntimeError("The native startup preference did not acknowledge restoration")


class SupplementaryNativeBootstrap:
    """Bind an authentic installed runtime before admitting its one native feature."""

    def __init__(self, app, output, domain, processes, runner=subprocess.run):
        self.app = app
        self.output = output
        self.domain = domain
        self.processes = processes
        self.runner = runner
        self.executable = NativeDelayedTimerProbe.executable_path(app)
        self.launcher = app / "Contents/MacOS/ErgoptiPlus"
        self.embedded = app / "Contents/Frameworks/Hammerspoon.app"
        self.nonce = secrets.token_hex(16)
        self.preference = StartupPreference(domain, runner)
        self.pid = None
        self.launch_attempted = False
        self.identity = {
            "nonce": self.nonce,
            "executable": str(self.executable),
            "bundle_id": domain,
            "version": TIMER_CONTRACT["runtime_version"],
        }

    def validate_owner(self, receipt, phase):
        """Reject foreign, extra, malformed or changed native startup identities."""
        expected = dict(self.identity, schema_version=1, contract=CONTRACT, phase=phase)
        extras = (
            {"pid"} if phase == "ready" else {"pid", "complete", "cleanup_acknowledged", "errors"}
        )
        if not isinstance(receipt, dict) or set(receipt) != set(expected) | extras:
            raise ValueError("The supplementary native identity has incomplete fields")
        for key, value in expected.items():
            if type(receipt[key]) is not type(value) or receipt[key] != value:
                raise ValueError(f"The supplementary native identity differs: {key}")
        pid = receipt["pid"]
        if type(pid) is not int or pid <= 0 or self.processes(self.executable) != [pid]:
            raise ValueError("The supplementary native runtime is not the exact live owner")
        if self.processes(self.launcher):
            raise ValueError("A managed launcher appeared during standalone feature admission")
        if self.pid is not None and self.pid != pid:
            raise ValueError("The supplementary native runtime changed after admission")
        if phase == "settled" and (
            receipt["complete"] is not True
            or receipt["cleanup_acknowledged"] is not True
            or receipt["errors"] != []
        ):
            raise ValueError("The supplementary native feature did not settle its exact owners")
        return pid

    def wait_receipt(self, path, timeout):
        """Wait only while the unique native owner remains live and within budget."""
        deadline = time.monotonic() + timeout
        while True:
            owners = self.processes(self.executable)
            if (
                len(owners) > 1
                or self.pid is not None
                and owners != [self.pid]
                or time.monotonic() >= deadline
            ):
                raise RuntimeError(
                    "The supplementary native receipt timed out or its owner changed"
                )
            if path.exists():
                result = read_receipt(path)
                if time.monotonic() >= deadline:
                    raise RuntimeError(
                        "The supplementary native receipt timed out before admission"
                    )
                return result
            time.sleep(0.05)

    def retire(self):
        """Retire only a uniquely identified executable before restoring its preference."""
        owners = self.processes(self.executable)
        if not owners:
            return
        if (
            not self.launch_attempted
            or len(owners) != 1
            or self.pid is not None
            and owners != [self.pid]
        ):
            raise RuntimeError("Foreign native process debt refuses preference restoration")
        pid = owners[0]
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            if self.processes(self.executable):
                raise RuntimeError("Native process ownership changed before retirement")
            return
        deadline = time.monotonic() + SCRIPT_CLEANUP_TIMEOUT_SECONDS
        while self.processes(self.executable):
            if self.processes(self.executable) != [pid]:
                raise RuntimeError("Native process ownership changed during retirement")
            if time.monotonic() >= deadline:
                os.kill(pid, signal.SIGKILL)
                break
            time.sleep(0.05)
        deadline = time.monotonic() + SCRIPT_CLEANUP_TIMEOUT_SECONDS
        while self.processes(self.executable):
            if time.monotonic() >= deadline or self.processes(self.executable) != [pid]:
                raise RuntimeError("Native process retirement did not acknowledge exact exit")
            time.sleep(0.05)

    def observe_script_scope(self):
        """Use a fresh exact native identity after the original feature retired."""
        return SupplementaryNativeBootstrap(
            self.app, self.output, self.domain, self.processes, self.runner
        ).observe("script_scope")

    def observe(self, feature):
        """Measure the unchanged probe, then physically retire and restore the owner."""
        if feature not in ("delayed_timer", "karabiner_config", "script_scope"):
            raise ValueError("Unknown supplementary native feature")
        if self.processes(self.launcher) or self.processes(self.executable):
            raise RuntimeError("The supplementary bootstrap requires all original runtimes settled")
        root = self.output / (
            "supplementary-native-bootstrap-script_scope"
            if feature == "script_scope"
            else "supplementary-native-bootstrap"
        )
        root.mkdir(mode=0o700)
        macos = self.app / "Contents/Resources/static/ergopti_plus/macos"
        shared = macos.parent / "_shared/lua"
        if not (macos / "init.lua").is_file() or not shared.is_dir():
            raise RuntimeError("The supplementary bootstrap lacks actual installed module owners")
        with (self.embedded / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        if (
            info.get("CFBundleIdentifier") != self.domain
            or info.get("CFBundleShortVersionString") != TIMER_CONTRACT["runtime_version"]
        ):
            raise RuntimeError(
                "The installed supplementary runtime has a foreign preference domain"
            )
        verified = self.runner(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.embedded)],
            capture_output=True,
            timeout=SCRIPTING_TIMEOUT_SECONDS,
        )
        if verified.returncode:
            raise RuntimeError("The installed supplementary runtime signature was not verified")
        paths = {
            name: root / (name + ".json")
            for name in ("ready", "admit", "settled", "feature", "context")
        }
        destination = root / (
            "script-private.toml" if feature == "script_scope" else "karabiner-private.json"
        )
        original = (json.dumps(INITIAL_CONFIG, indent=2) + "\n").encode()
        if feature == "karabiner_config":
            with destination.open("xb") as handle:
                handle.write(original)
        fixture = Path(__file__).with_name(
            "hs_delayed_timer_native.lua"
            if feature == "delayed_timer"
            else "hs_script_scope_native.lua"
            if feature == "script_scope"
            else "hs_karabiner_config_native.lua"
        )
        # Timers already observe asynchronous receipts for 15 seconds; the
        # synchronous Karabiner request keeps its original 10-second budget.
        feature_timeout = (
            FEATURE_TIMEOUT_SECONDS if feature == "delayed_timer" else SCRIPTING_TIMEOUT_SECONDS
        )
        context = dict(
            self.identity,
            schema_version=1,
            contract=CONTRACT,
            feature=feature,
            module_roots=[str(macos), str(shared)],
            probe_source=str(fixture),
            destination=str(destination),
            paths={key: str(value) for key, value in paths.items()},
            admission_timeout=SCRIPTING_TIMEOUT_SECONDS,
            feature_timeout=feature_timeout,
        )
        publish(paths["context"], context)
        startup = root / "init.lua"
        startup.write_text(
            "-- Owned supplementary native feature bootstrap; no full driver startup.\n"
            + "dofile({}).run({})\n".format(
                json.dumps(
                    str(Path(__file__).with_name("hs_native_bootstrap.lua")), ensure_ascii=False
                ),
                json.dumps(str(paths["context"]), ensure_ascii=False),
            ),
            encoding="utf-8",
        )
        summary = None
        primary = None
        try:
            self.preference.configure(startup)
            self.launch_attempted = True
            opened = self.runner(
                ["/usr/bin/open", "-n", str(self.embedded)],
                capture_output=True,
                timeout=SCRIPTING_TIMEOUT_SECONDS,
            )
            if opened.returncode:
                raise RuntimeError("The supplementary native LaunchServices invocation refused")
            ready = self.wait_receipt(paths["ready"], SCRIPTING_TIMEOUT_SECONDS)
            self.pid = self.validate_owner(ready, "ready")
            # No invocation is admitted before the actual kernel-PID is bound.
            publish(paths["admit"], dict(ready, phase="admit"))
            settled = self.wait_receipt(paths["settled"], feature_timeout)
            self.validate_owner(settled, "settled")
            result = read_receipt(paths["feature"])
            validator = (
                validate_timer
                if feature == "delayed_timer"
                else validate_script
                if feature == "script_scope"
                else validate_karabiner
            )
            measured = validator(result, self.nonce, self.pid, self.executable, self.domain)
            if feature == "karabiner_config" and destination.read_bytes() != original:
                raise RuntimeError(
                    "The supplementary native private source was not exactly restored"
                )
            self.validate_owner(settled, "settled")
            summary = {
                "schema_version": 1,
                "contract": CONTRACT,
                "feature": feature,
                "qualification": QUALIFICATION,
                "admission": "owned startup file",
                "identity": ready,
                "measurement": measured,
                "cleanup_acknowledged": True,
                "process_retired": False,
                "preference_restored": False,
            }
        except Exception as error:
            primary = error
        finally:
            try:
                claim, claim_error = None, None
                claim_path = Path(str(destination) + ".settings-claim.json")
                if feature == "script_scope" and claim_path.exists():
                    try:
                        claim = validate_claim(
                            read_receipt(claim_path),
                            self.nonce,
                            self.pid,
                            self.executable,
                            self.domain,
                        )
                    except Exception as error:
                        claim_error = error
                self.retire()
                try:
                    if claim_error is not None:
                        raise claim_error
                    if claim is not None:
                        if self.processes(self.executable) or self.processes(self.launcher):
                            raise RuntimeError(
                                "A native successor refuses private settings cleanup"
                            )
                        recover_claim(
                            claim,
                            self.domain,
                            self.preference.reader,
                            self.runner,
                            SCRIPTING_TIMEOUT_SECONDS,
                        )
                finally:
                    self.preference.restore()
                if summary is not None:
                    summary["process_retired"] = True
                    summary["preference_restored"] = True
            except Exception as cleanup:
                raise RuntimeError(
                    f"Supplementary native bootstrap failed: {primary}; cleanup refused: {cleanup}"
                ) from cleanup
        if primary is not None:
            raise primary
        return summary
