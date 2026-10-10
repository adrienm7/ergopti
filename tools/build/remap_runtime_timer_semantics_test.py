# tools/build/remap_runtime_timer_semantics_test.py
"""Actual pinned dispatcher/software-clock controls; no native manipulator engine.

The existing authentic offline source owner supplies the complete eight-header
closure. No dispatcher, clock, cancellation or threading implementation is
substituted. Darwin keyboard semantics and original Lua expectations stay separate.
"""

import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

BUILD = Path(__file__).resolve().parent
OPTIONS = None
DEADLINE = None
sys.dont_write_bytecode = True
INVENTORY_SHA256 = "4480b5fe7013e6f8d0b1064c6694d88f77faaac1150844f20b47f6c573bfecfe"
CONTROL_SHA256 = "8205ca8cceb1cd72f964b5d2427aed7c444c5fdb17b5cba8aa26f1e6bea54538"
UPSTREAM = "9312593e1a3bf72b94c63c524ebabe2637442e8a"
PINS = {
    "vendor/vendor/include/pqrs/dispatcher/dispatcher.hpp": (
        11266,
        "ba13c1a71b4ab7502fb0e1a71ddbe0a940b02ae98d4e4df50f0c03b8f966e8eb",
        "8b8e84bd29527b1c60c2274b780f1a72126f1dc5",
    ),
    "vendor/vendor/include/pqrs/dispatcher/extra/debounced_task.hpp": (
        2237,
        "e479df306301d5e250c1d7481474524ed0dd873602c7374f91b8bd622aaf0653",
        "53cf29c22cf50c2bd705e722788e2311be7a40a1",
    ),
    "vendor/vendor/include/pqrs/dispatcher/extra/dispatcher_client.hpp": (
        2356,
        "1543f816e926943666b50b5f96784c2cf9ec6ad368b23f66774624ca5fc3688c",
        "43ff88d6167771d400491353299e65383fb91a53",
    ),
    "vendor/vendor/include/pqrs/dispatcher/extra/shared_dispatcher.hpp": (
        2170,
        "0b3d76405451276f980fd2aa314f44199e4e714e4424e40b9e6db5e33e7f82f1",
        "c2279923b0380057af11df91f33ffa49df8a02a4",
    ),
    "vendor/vendor/include/pqrs/dispatcher/object_id.hpp": (
        2510,
        "d42b633c081e48e274617e30624672a82c308f18d23a560d8d81997840796e84",
        "b01e238cf31b6bc8d214c94d785a9d204c2c56da",
    ),
    "vendor/vendor/include/pqrs/dispatcher/time_source.hpp": (
        1139,
        "2a83335fc4b13c54ee604c421d35ba31d08dcc725e8d43a85d4ad0ee7fa0db28",
        "b7437c7f44700759ed68f0f9907bbc84cd822391",
    ),
    "vendor/vendor/include/pqrs/dispatcher/types.hpp": (
        370,
        "58e3bade860fd579cb11c7d8eace5a4bdf161902d2eeea9872b871c8d66eba77",
        "856edc53e3c44473aadcf218ca0f00a1dbb3c29c",
    ),
    "vendor/vendor/include/pqrs/thread_wait.hpp": (
        2312,
        "237ce8b32ce019ac80a182d00480a9792134a6383b60c3b3e2ab5b7620899955",
        "6462e6704d05825bad67b09492d4e63b2648ae1e",
    ),
}
SCENARIOS = (
    "threshold_199_200",
    "cancel_before_eligible",
    "same_owner_rearm",
    "same_deadline_rearm",
    "independent_owners",
    "detach_before_due",
    "retained_rearm_after_detach_refuses",
)
REPORT = (
    "PASS portable pinned dispatcher cases=7 failures=0 errors=0 skipped=0 "
    "native_engine=unexecuted\n"
)


def owned_command(command, limit):
    """Own one finite POSIX process group, including compiler descendants."""
    remaining = min(limit, DEADLINE - time.monotonic())
    if remaining <= 0:
        raise RuntimeError("timer_fixture_deadline")
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=remaining)
    except subprocess.TimeoutExpired:
        # Do not reap the owning child before terminating its exact session;
        # the unreaped PID cannot be recycled into a foreign process group.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise RuntimeError("timer_fixture_child_deadline") from None
    return process.returncode, stdout, stderr


def inventory_owner(repository):
    """Execute only the retained exact existing offline-source bootstrap bytes."""
    path = repository / "tools/build/remap_runtime_inventory_fixture.py"
    if path.resolve(strict=True) != path:
        raise RuntimeError("timer_inventory_alias")
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != INVENTORY_SHA256:
        raise RuntimeError("timer_inventory_source")
    name = "timer_actual_inventory_owner"
    specification = importlib.util.spec_from_loader(name, loader=None)
    module = importlib.util.module_from_spec(specification)
    module.__file__ = str(path)
    sys.modules[name] = module
    exec(compile(data, str(path), "exec"), module.__dict__)
    return module


class PinnedDispatcherSemantics(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        inventory = inventory_owner(OPTIONS.repository)
        fixture = inventory.bootstrap_fixture()
        owner = fixture.owner(OPTIONS.owner)
        cls.temporary = tempfile.TemporaryDirectory(prefix="pinned-timer-", dir=owner)
        cls.addClassCleanup(cls.temporary.cleanup)
        work = fixture.owner(Path(cls.temporary.name))
        entries = dict(fixture.sources(census=fixture.manifest()))
        selected = []
        for path, (size, digest, blob) in PINS.items():
            data = entries[path]
            if (
                len(data) != size
                or hashlib.sha256(data).hexdigest() != digest
                or hashlib.sha1(b"blob " + str(size).encode("ascii") + b"\0" + data).hexdigest()
                != blob
            ):
                raise RuntimeError("timer_dependency_source")
            selected.append((path, data))
        source = work / "source"
        source.mkdir(mode=0o700)
        fixture.publish_sources(source, selected)
        control = fixture.read_owned(
            BUILD / "remap_runtime_timer_semantics_control.cpp", 20000, "timer_control"
        )
        if hashlib.sha256(control).hexdigest() != CONTROL_SHA256:
            raise RuntimeError("timer_control_source")
        translation_unit = work / "control.cpp"
        with translation_unit.open("xb") as stream:
            stream.write(control)
        cls.inputs = [(source / name, data) for name, data in selected]
        cls.inputs.append((translation_unit, control))
        cls.fixture = fixture
        cls.verify_inputs()
        cls.binary = work / "timer-controls"
        command = [
            OPTIONS.compiler,
            "-std=c++23",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-pthread",
            "-I",
            str(source / "vendor/vendor/include"),
            str(translation_unit),
            "-o",
            str(cls.binary),
        ]
        status, stdout, stderr = owned_command(command, 15)
        if status != 0 or stdout or stderr:
            raise RuntimeError("timer_actual_compilation_refused")
        cls.verify_inputs()

    @classmethod
    def verify_inputs(cls):
        for path, expected in cls.inputs:
            if cls.fixture.read_owned(path, len(expected), "timer_input_current") != expected:
                raise RuntimeError("timer_input_changed")

    def check(self, scenario):
        self.verify_inputs()
        status, stdout, stderr = owned_command([str(self.binary), scenario], 3)
        self.verify_inputs()
        self.assertEqual(status, 0)
        self.assertEqual(stderr, b"")
        self.assertEqual(
            stdout,
            ("PASS actual pinned dispatcher " + scenario + " native_engine=unexecuted\n").encode(),
        )

    def test_threshold_199_200(self):
        self.check("threshold_199_200")

    def test_cancel_before_eligible(self):
        self.check("cancel_before_eligible")

    def test_same_owner_rearm(self):
        self.check("same_owner_rearm")

    def test_same_deadline_rearm(self):
        self.check("same_deadline_rearm")

    def test_independent_owners(self):
        self.check("independent_owners")

    def test_detach_before_due(self):
        self.check("detach_before_due")

    def test_retained_rearm_after_detach_refuses(self):
        self.check("retained_rearm_after_detach_refuses")


def main():
    global OPTIONS, DEADLINE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owner", type=Path, required=True)
    parser.add_argument("--repository", type=Path, default=BUILD.parent.parent)
    parser.add_argument("--compiler", default="clang++")
    OPTIONS = parser.parse_args()
    if sys.platform not in ("linux", "darwin"):
        print("Refused timer fixture: POSIX host unavailable", file=sys.stderr)
        return 1
    DEADLINE = time.monotonic() + 20
    suite = unittest.TestLoader().loadTestsFromTestCase(PinnedDispatcherSemantics)
    if suite.countTestCases() != len(SCENARIOS) or len(set(SCENARIOS)) != 7:
        print("Refused timer fixture: control inventory", file=sys.stderr)
        return 1
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    if result.testsRun != 7 or result.skipped or not result.wasSuccessful():
        return 1
    sys.stdout.write(REPORT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
