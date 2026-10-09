# tools/test/managed_ollama_go_evidence_test.py
"""Receive frozen genuine Go output; no macOS SDK or Darwin execution credit."""

import ast
import importlib.util
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "managed_go_producer", ROOT / "tools/build/build-macos-managed-ollama.py"
)
PRODUCER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCER)
CONTRACT = json.loads((ROOT / PRODUCER.RUNTIME_CONTRACT).read_text(encoding="utf-8"))
POLICY = CONTRACT["native_http_go_test_policy"]
# The four Darwin-only identities are already in the independently frozen policy.
REQUIRED = [
    name for name in POLICY["required_passes"] if not name.startswith("TestBootstrapDarwin")
]
FROZEN = ROOT / "tools/test/fixtures/managed-ollama-go/linux-44.jsonl"
PACKAGE = "ergopti/nativehttp"


class NativeGoEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="managed-go-evidence-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.events = [json.loads(line) for line in FROZEN.read_text(encoding="utf-8").splitlines()]

    def receive(self, events=None, *, raw=None, required=REQUIRED, limit=None):
        path = self.root / "events.jsonl"
        if raw is None:
            raw = "".join(
                json.dumps(event) + "\n"
                for event in (events if events is not None else self.events)
            )
        path.write_text(raw, encoding="utf-8")
        return PRODUCER.admit_go_test_log(
            path, PACKAGE, required, limit or POLICY["maximum_log_bytes"]
        )

    def testActualCompletedLinux44Has26TopLevelAnd18Subtests(self):
        fact = self.receive(raw=FROZEN.read_text(encoding="utf-8"))
        self.assertEqual(
            (fact["passed"], fact["top_level_passed"], fact["subtests_passed"]), (44, 26, 18)
        )
        self.assertEqual((fact["failed"], fact["skipped"], fact["package_completed"]), (0, 0, True))
        self.assertEqual(fact["transcript_sha256"], PRODUCER.sha256(FROZEN))

    def testLinuxReceiptCannotQualifyRequiredDarwin48(self):
        with self.assertRaises(ValueError):
            self.receive(required=POLICY["required_passes"])

    def testMissingSubjectPassRefused(self):
        events = [
            event
            for event in self.events
            if not (event.get("Action") == "pass" and event.get("Test") == REQUIRED[0])
        ]
        with self.assertRaises(ValueError):
            self.receive(events)

    def testMissingSubtestRefused(self):
        subject = next(name for name in REQUIRED if "/" in name)
        events = [event for event in self.events if event.get("Test") != subject]
        with self.assertRaises(ValueError):
            self.receive(events)

    def testSkippedSubjectRefused(self):
        events = [
            dict(event, Action="skip")
            if event.get("Action") == "pass" and event.get("Test") == REQUIRED[0]
            else event
            for event in self.events
        ]
        with self.assertRaises(ValueError):
            self.receive(events)

    def testFailedSubjectRefused(self):
        events = [
            dict(event, Action="fail")
            if event.get("Action") == "pass" and event.get("Test") == REQUIRED[0]
            else event
            for event in self.events
        ]
        with self.assertRaises(ValueError):
            self.receive(events)

    def testMissingPackageCompletionRefused(self):
        with self.assertRaises(ValueError):
            self.receive(self.events[:-1])

    def testPartialFinalFrameRefused(self):
        with self.assertRaises(ValueError):
            self.receive(raw=FROZEN.read_text(encoding="utf-8").rstrip("\n"))

    def testDuplicateSubjectPassRefused(self):
        index = next(
            i
            for i, event in enumerate(self.events)
            if event.get("Action") == "pass" and "Test" in event
        )
        with self.assertRaises(ValueError):
            self.receive(self.events[:index] + [self.events[index]] + self.events[index:])

    def testDuplicateRunRefused(self):
        index = next(i for i, event in enumerate(self.events) if event.get("Action") == "run")
        with self.assertRaises(ValueError):
            self.receive(self.events[:index] + [self.events[index]] + self.events[index:])

    def testForeignPackageRefused(self):
        events = [dict(event, Package="foreign/package") for event in self.events]
        with self.assertRaises(ValueError):
            self.receive(events)

    def testDuplicateEventKeyRefused(self):
        raw = FROZEN.read_text(encoding="utf-8").replace(
            '"Action":"start"', '"Action":"start","Action":"start"', 1
        )
        with self.assertRaises(ValueError):
            self.receive(raw=raw)

    def testOversizeTranscriptRefused(self):
        with self.assertRaises(ValueError):
            self.receive(limit=1)

    def testTerminalFollowingEventsRefused(self):
        with self.assertRaises(ValueError):
            self.receive(self.events + [self.events[-1]])

    def testRetirementDebtPreservesActualBuildDirectory(self):
        owned = None
        with self.assertRaises(PRODUCER.NativeGoRetirementDebt):
            with PRODUCER.native_build_directory(self.root) as owned:
                (owned / "source").write_text("retained\n", encoding="utf-8")
                raise PRODUCER.NativeGoRetirementDebt("independent closure refusal")
        self.assertEqual((owned / "source").read_text(encoding="utf-8"), "retained\n")

    def native_go_argv(self, operation):
        tree = ast.parse(Path(PRODUCER.__file__).read_text(encoding="utf-8"))
        function = next(
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef)
            and node.name == ("build" if operation == "build" else "_run_native_go_tests")
        )
        commands = [
            node
            for node in ast.walk(function)
            if isinstance(node, ast.List)
            and len(node.elts) >= 2
            and isinstance(node.elts[1], ast.Constant)
            and node.elts[1].value == operation
        ]
        self.assertEqual(len(commands), 1, "the actual native command must be unique")
        expression = ast.Expression(body=commands[0])
        return eval(
            compile(expression, "actual-native-go-argv", "eval"),
            {
                "options": SimpleNamespace(go="owned-go"),
                "contract": CONTRACT,
                "timeout": POLICY["timeout_seconds"],
                "cli": self.root / "owned-ollama",
            },
        )

    def testActualGoTestCreatesWritableOwnedModuleCache(self):
        argv = self.native_go_argv("test")
        self.assertEqual(argv.count("-modcacherw"), 1)
        self.assertEqual(argv.count("-mod=readonly"), 1)
        self.assertEqual(argv[0:2], ["owned-go", "test"])
        self.assertIn("-json", argv)
        self.assertIn("-count=1", argv)
        self.assertIn("-timeout=" + str(POLICY["timeout_seconds"]) + "s", argv)
        self.assertEqual(argv[-1], "./internal/ergoptinativehttp")

    def testActualGoBuildCreatesWritableOwnedModuleCache(self):
        argv = self.native_go_argv("build")
        self.assertEqual(argv.count("-modcacherw"), 1)
        self.assertEqual(argv.count("-mod=readonly"), 1)
        self.assertEqual(argv[0:2], ["owned-go", "build"])
        self.assertIn("-trimpath", argv)
        self.assertIn("-buildvcs=false", argv)
        self.assertEqual(argv[-1], ".")
        self.assertEqual(argv[argv.index("-o") + 1], str(self.root / "owned-ollama"))

    def testNormalBuildDirectoryIsRetired(self):
        with PRODUCER.native_build_directory(self.root) as owned:
            (owned / "source").write_text("owned\n", encoding="utf-8")
        self.assertFalse(owned.exists())


class NativeGoPublisherPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location(
            "managed_go_publisher", ROOT / "tools/build/stage-macos-managed-ollama-catalogue.py"
        )
        cls.publisher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.publisher)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="managed-go-publisher-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for relative in (PRODUCER.RUNTIME_CONTRACT, self.publisher.OFFICIAL_RELEASE):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((ROOT / relative).read_bytes())
        self.contract = json.loads(json.dumps(CONTRACT))

    def receive(self):
        (self.root / PRODUCER.RUNTIME_CONTRACT).write_text(
            json.dumps(self.contract), encoding="utf-8"
        )
        return self.publisher.read_contract(self.root, self.publisher.Inputs())

    def testExactAddedPolicyAdmitted(self):
        self.assertEqual(self.receive()[0]["native_http_go_test_policy"], POLICY)

    def testOldContractWithoutMandatoryPolicyRefused(self):
        del self.contract["native_http_go_test_policy"]
        with self.assertRaises(ValueError):
            self.receive()

    def testUnknownContractFieldRemainsRefused(self):
        self.contract["unexpected"] = True
        with self.assertRaises(ValueError):
            self.receive()

    def testUnknownPolicyFieldRefused(self):
        self.contract["native_http_go_test_policy"]["skip_allowed"] = True
        with self.assertRaises(ValueError):
            self.receive()

    def testBooleanTimeoutRefused(self):
        self.contract["native_http_go_test_policy"]["timeout_seconds"] = True
        with self.assertRaises(ValueError):
            self.receive()

    def testNonpositiveByteLimitRefused(self):
        self.contract["native_http_go_test_policy"]["maximum_log_bytes"] = 0
        with self.assertRaises(ValueError):
            self.receive()

    def testDuplicateFrozenIdentityRefused(self):
        self.contract["native_http_go_test_policy"]["required_passes"].append(
            POLICY["required_passes"][0]
        )
        with self.assertRaises(ValueError):
            self.receive()

    def testNonstringIdentityRefused(self):
        self.contract["native_http_go_test_policy"]["required_passes"][0] = 1
        with self.assertRaises(ValueError):
            self.receive()


# The native census is an explicit observation double. Child creation, signals,
# process-group killing, wait/reap and handler restoration are actual POSIX calls.
SIGNAL_OWNER_PORT = """import os,signal,subprocess,sys,time
from pathlib import Path
children=[]
class NativeProcessGroups:
 def __init__(self):
  if os.environ['CONTROL_MODE']=='before': os.kill(os.getpid(),signal.SIGTERM)
class Group:
 def __init__(self,process): self.process=process
 def observe_exit(self): return None
 def settle(self):
  Path(os.environ['CONTROL_SETTLING']).write_text('settling')
  time.sleep(.15)
  mode=os.environ['CONTROL_MODE']
  if mode=='refuse': return False
  if mode=='raise': raise RuntimeError('controlled census refusal')
  os.killpg(self.process.pid,signal.SIGKILL)
  self.process.wait(timeout=3)
  Path(os.environ['CONTROL_SETTLED']).write_text('settled')
  return True
 def receipt(self): return {'closed':self.process.returncode is not None}
def acquire_owned(arguments,native,register,**options):
 process=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'],
  start_new_session=True,stdout=options['stdout'],stderr=options['stderr'])
 children.append(process)
 register(Group(process))
 Path(os.environ['CONTROL_PID']).write_text(str(process.pid))
 if os.environ['CONTROL_MODE']=='acquisition': os.kill(os.getpid(),signal.SIGTERM)
def rescue():
 for process in children:
  if process.returncode is None:
   os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=3)
"""


def signal_control_caller(root, mode):
    """Keep a refused controlled child owned until the observer permits rescue."""
    from types import SimpleNamespace

    owner = root / "tools/diagnostics/macos_owned_process.py"
    options = SimpleNamespace(repository=root, output=root, go=sys.executable)
    contract = {
        "native_http_go_test_policy": {
            "timeout_seconds": 10,
            "maximum_log_bytes": 10000,
            "required_passes": ["TestFixed"],
        },
        "assets": {"macos-arm64": {"filename": "fixed.tgz"}},
    }
    previous = {signum: signal.getsignal(signum) for signum in (signal.SIGTERM, signal.SIGINT)}
    sentinels = {signum: (lambda _signum, _frame: None) for signum in previous}
    for signum, handler in sentinels.items():
        signal.signal(signum, handler)
    outcome = "unexpected_success"
    try:
        try:
            PRODUCER.run_native_go_tests(
                options,
                root,
                dict(os.environ),
                contract,
                {"tools/diagnostics/macos_owned_process.py": PRODUCER.sha256(owner)},
                "arm64",
            )
        except BaseException as error:
            outcome = type(error).__name__
        restored = all(signal.getsignal(signum) is handler for signum, handler in sentinels.items())
        alive = False
        pidfile = root / "pid"
        if pidfile.exists():
            try:
                os.kill(int(pidfile.read_text()), 0)
                alive = True
            except ProcessLookupError:
                pass
        (root / "result.json").write_text(
            json.dumps(
                {
                    "outcome": outcome,
                    "handlers_restored": restored,
                    "settled": (root / "settled").exists(),
                    "child_alive": alive,
                    "proof_published": (root / "fixed.tgz.go-tests.receipt.json").exists(),
                }
            ),
            encoding="utf-8",
        )
        deadline = time.monotonic() + 5
        while not (root / "rescue").exists():
            if time.monotonic() >= deadline:
                raise RuntimeError("Controlled observer did not acknowledge rescue")
            time.sleep(0.01)
    finally:
        # Retain only the exact controlled owner loaded by the production caller.
        if SIGNAL_CONTROL_OWNER:
            SIGNAL_CONTROL_OWNER[0].rescue()
        for signum, handler in previous.items():
            signal.signal(signum, handler)


SIGNAL_CONTROL_OWNER = []


class NativeGoSignalOwnershipTests(unittest.TestCase):
    def run_control(self, signum, mode="normal", repeated=False):
        with tempfile.TemporaryDirectory(prefix="managed-go-signal-") as temporary:
            root = Path(temporary)
            owner = root / "tools/diagnostics/macos_owned_process.py"
            owner.parent.mkdir(parents=True)
            owner.write_text(SIGNAL_OWNER_PORT, encoding="utf-8")
            env = dict(
                os.environ,
                CONTROL_MODE=mode,
                CONTROL_PID=str(root / "pid"),
                CONTROL_SETTLING=str(root / "settling"),
                CONTROL_SETTLED=str(root / "settled"),
                PYTHONDONTWRITEBYTECODE="1",
            )
            with (root / "caller.stderr").open("wb") as errors:
                process = subprocess.Popen(
                    [
                        sys.executable,
                        str(Path(__file__).resolve()),
                        "--signal-caller",
                        str(root),
                        mode,
                    ],
                    env=env,
                    stdout=subprocess.DEVNULL,
                    stderr=errors,
                )
                try:
                    deadline = time.monotonic() + 5
                    marker = root / ("result.json" if mode in ("before", "acquisition") else "pid")
                    while not marker.exists():
                        self.assertIsNone(process.poll())
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(0.01)
                    if mode not in ("before", "acquisition"):
                        os.kill(process.pid, signum)
                    if repeated:
                        while not (root / "settling").exists():
                            self.assertIsNone(process.poll())
                            self.assertLess(time.monotonic(), deadline)
                            time.sleep(0.01)
                        os.kill(process.pid, signal.SIGINT)
                        os.kill(process.pid, signal.SIGTERM)
                    while not (root / "result.json").exists():
                        self.assertIsNone(process.poll())
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(0.01)
                    fact = json.loads((root / "result.json").read_text())
                    self.assertTrue(fact["handlers_restored"])
                    self.assertFalse(fact["proof_published"])
                    if mode in ("refuse", "raise"):
                        self.assertEqual(fact["outcome"], "NativeGoRetirementDebt")
                        self.assertTrue(fact["child_alive"])
                        self.assertFalse(fact["settled"])
                    else:
                        self.assertEqual(fact["outcome"], "NativeGoCancelled")
                        self.assertFalse(fact["child_alive"])
                        self.assertEqual(fact["settled"], mode != "before")
                finally:
                    (root / "rescue").touch()
                    process.wait(timeout=5)
                    self.assertEqual(process.returncode, 0)

    def testActualSigintSettlesAndRestoresHandlers(self):
        self.run_control(signal.SIGINT)

    def testActualSigtermSettlesAndRestoresHandlers(self):
        self.run_control(signal.SIGTERM)

    def testCancellationBeforeAcquisitionCannotSpawn(self):
        self.run_control(signal.SIGTERM, "before")

    def testAcquisitionCancellationRetiresRegisteredChild(self):
        self.run_control(signal.SIGTERM, "acquisition")

    def testRepeatedSignalsCannotInterruptPhysicalRetirement(self):
        self.run_control(signal.SIGTERM, repeated=True)

    def testRefusedRetirementPreservesDebtWithoutProof(self):
        self.run_control(signal.SIGTERM, "refuse")

    def testFailedRetirementObservationPreservesDebtWithoutProof(self):
        self.run_control(signal.SIGTERM, "raise")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--signal-caller":
        original_module = importlib.util.module_from_spec

        def retained_module(spec):
            module = original_module(spec)
            if spec.name == "ergopti_go_test_owner":
                SIGNAL_CONTROL_OWNER.append(module)
            return module

        importlib.util.module_from_spec = retained_module
        signal_control_caller(Path(sys.argv[2]), sys.argv[3])
    else:
        unittest.main()
