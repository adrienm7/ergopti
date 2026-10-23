# tools/test/managed_ollama_go_evidence_test.py
"""Receive frozen genuine Go output; no macOS SDK or Darwin execution credit."""

import ast
import importlib.util
import json
import os
import re
import stat
import signal
import subprocess
import sys
import time
from pathlib import Path
import tempfile
import unittest
import unittest.mock
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "managed_go_producer", ROOT / "tools/build/build-macos-managed-ollama.py"
)
PRODUCER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCER)
CONTRACT = json.loads((ROOT / PRODUCER.RUNTIME_CONTRACT).read_text(encoding="utf-8"))
POLICY = CONTRACT["native_http_go_test_policy"]
# These literal identities belong to the frozen pre-event Linux receipt, not current policy.
REQUIRED = [
    "TestPrivateHMACFrozenIndependentVectorBindsAuthorityPathAndBody",
    "TestPrivateAdmissionRequiresExactSecretAndLoopback",
    "TestPrivateAdmissionDoesNotDiscloseUnqualifiedDaemon",
    "TestPrivateSessionRejectsDuplicateNullAndMalformedIdentity",
    "TestOwnedPullRetirementWaitsForPhysicalNativeAndBackgroundOwners",
    "TestOrdinaryPullAndPrivateForeignSessionStaySeparate",
    "TestBootstrapIndependentHMACVectorAndImmutableSnapshot",
    "TestBootstrapSignedProtocolRefusals",
    "TestBootstrapPreservesCustomStoreWithoutMigration",
    "TestBootstrapRealPrivateFDAndNamespaceRefusals",
    "TestBootstrapNativeWorkerGetsOnlyPrivateCertificates",
    "TestBootstrapCertificateTrustIsScopedAndPreservesOriginal",
    "TestBootstrapCertificateDirectoryAndMalformedRefusals",
    "TestBootstrapExplicitProxyUsesActualScopedTLSAnchor",
    "TestFullURLPrivateHeadersAndPhysicalCompletion",
    "TestWireFailuresCannotPublishFinalBytes/truncated",
    "TestWireFailuresCannotPublishFinalBytes/false-terminal",
    "TestWireFailuresCannotPublishFinalBytes/wrong-exit",
    "TestWireFailuresCannotPublishFinalBytes/late-bytes",
    "TestWireFailuresCannotPublishFinalBytes/null-terminal",
    "TestWireFailuresCannotPublishFinalBytes/duplicate",
    "TestWireFailuresCannotPublishFinalBytes/invalid-header",
    "TestWireFailuresCannotPublishFinalBytes",
    "TestHeadVerifiesTerminalBeforeHeaders/complete",
    "TestHeadVerifiesTerminalBeforeHeaders/wrong-exit",
    "TestHeadVerifiesTerminalBeforeHeaders",
    "TestGoRedirectPolicyRetainsFullURLAndStripsForeignAuth",
    "TestCancellationAndConcurrentClosePhysicallyRetirePeer/stall-header",
    "TestCancellationAndConcurrentClosePhysicallyRetirePeer/cancel-body",
    "TestCancellationAndConcurrentClosePhysicallyRetirePeer/stall-body",
    "TestCancellationAndConcurrentClosePhysicallyRetirePeer",
    "TestBypassIndependentVectors",
    "TestIdleDeadlinePhysicallyRetiresPeer",
    "TestUnknownLengthRequiresTerminalAndExactEOF",
    "TestClientErrorPrivacyRetainsContextCause",
    "TestManagedRedirectStrictAuthorityAndDowngrade/https://origin.example/blob?q=two",
    "TestManagedRedirectStrictAuthorityAndDowngrade/https://origin.example:443/blob?q=two",
    "TestManagedRedirectStrictAuthorityAndDowngrade/https://origin.example:444/blob?q=two",
    "TestManagedRedirectStrictAuthorityAndDowngrade/https://asset.origin.example/blob?q=two",
    "TestManagedRedirectStrictAuthorityAndDowngrade/https://foreign.example/blob?q=two",
    "TestManagedRedirectStrictAuthorityAndDowngrade/http://origin.example/blob?q=two",
    "TestManagedRedirectStrictAuthorityAndDowngrade",
    "TestManagedRedirectKeepsOriginalVeto",
    "TestManagedRedirectReturnToOriginDoesNotRestoreHeaderOrJarSecrets",
]
# Literal identities of the destination policy that replaces Ollama 0.40.4's
# checked dialer on native routes; neither frozen receipt can qualify them.
ADDRESS_POLICY_IDENTITIES = [
    "TestDestinationPolicyIndependentUpstreamVectors",
    "TestDestinationPolicyRefusesNonPublicBeforeNativeWorker",
    "TestDestinationPolicyExplicitProxyHopBypassesCheckedDialer",
    "TestValidateRedirectTargetLeavesUnresolvedHostToTheCarrier",
    "TestRedirectPolicyStopsAfterTenHops",
    "TestWrapCheckedKeepsOriginalCheckedDialerWithoutCapability",
]
# Literal identities of the shared serve environment (OLLAMA_NO_CLOUD) the
# managed server applies before it reads its configuration.
SERVE_ENVIRONMENT_IDENTITIES = [
    "TestServeEnvironmentDisablesOllamaCloud",
    "TestServeEnvironmentRefusesInvalidDeclarations",
]
ADDED_IDENTITIES = ADDRESS_POLICY_IDENTITIES + SERVE_ENVIRONMENT_IDENTITIES
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

        # These literal subjects are frozen from the original e941 source,
        # independently of the candidate policy. Events below are only a model.
        identities = json.loads(
            (FROZEN.parent / "failure-stage-identities.json").read_text(encoding="utf-8")
        )
        self.assertEqual(identities["scope"], "model_only_closed_test_identity_fixture")
        self.assertEqual(
            identities["original_source_commit"], "e94153e87b698b24de86133239319bde4be12a90"
        )
        original = identities["identities"]
        added = identities["required_failure_stage_subtests"]
        self.assertEqual(len(original), 74)
        self.assertEqual(len(set(original)), 74)
        subjects = original + ADDED_IDENTITIES
        self.assertEqual(len(added), 17)
        self.assertEqual(len(set(added)), 17)
        events = [{"Action": "start", "Package": PACKAGE}]
        for name in subjects:
            events.extend(
                {"Action": action, "Package": PACKAGE, "Test": name} for action in ("run", "pass")
            )
        events.append({"Action": "pass", "Package": PACKAGE})
        try:
            fact = self.receive(events, required=POLICY["required_passes"])
        except ValueError:
            self.fail("The frozen original failure-stage subtests must be explicitly enrolled")
        self.assertEqual(POLICY["required_passes"], subjects)
        self.assertEqual(
            (fact["passed"], fact["top_level_passed"], fact["subtests_passed"]), (82, 47, 35)
        )
        self.assertEqual((fact["failed"], fact["skipped"], fact["package_completed"]), (0, 0, True))
        for name in added + ADDED_IDENTITIES:
            for mutation in (
                "missing",
                "fail",
                "skip",
                "duplicate_run",
                "duplicate_pass",
                "foreign",
            ):
                with self.subTest(identity=name, mutation=mutation):
                    changed = []
                    for event in events:
                        if event.get("Test") != name:
                            changed.append(event)
                        elif mutation == "missing":
                            continue
                        elif mutation in ("fail", "skip") and event["Action"] == "pass":
                            changed.append(dict(event, Action=mutation))
                        elif mutation == "duplicate_run" and event["Action"] == "run":
                            changed.extend((event, dict(event)))
                        elif mutation == "duplicate_pass" and event["Action"] == "pass":
                            changed.extend((event, dict(event)))
                        elif mutation == "foreign":
                            changed.append(dict(event, Test=name + "/unenrolled"))
                        else:
                            changed.append(event)
                    with self.assertRaises(ValueError):
                        self.receive(changed, required=POLICY["required_passes"])

    def testFrozenLinux44CannotQualifySixAddedListenerEventIdentities(self):
        required = [
            "TestListenerEventRealUnixFrameHalfCloseAndGuardianEOF",
            "TestListenerEventForeignPortCannotAcquireUnixConnection",
            "TestListenerEventMissingSessionCannotAcquireUnixConnection",
            "TestListenerEventForeignGuardianCannotReceiveAnyFrame",
            "TestListenerEventUnexpectedGuardianByteCannotPermitServe",
            "TestListenerEventRepeatedPublicationCannotCreateSuccessor",
        ]
        self.assertEqual(
            [name for name in POLICY["required_passes"] if name.startswith("TestListenerEvent")],
            required,
        )
        observed = {
            event["Test"]
            for event in self.events
            if event.get("Action") == "pass" and "Test" in event
        }
        self.assertTrue(observed.isdisjoint(required))
        for name in required:
            with self.subTest(identity=name):
                with self.assertRaises(ValueError):
                    self.receive(required=REQUIRED + [name])

    def testFrozenLinux44CannotQualifyAddedDestinationAndServeEnvironmentIdentities(self):
        self.assertEqual(
            [name for name in POLICY["required_passes"] if name in ADDED_IDENTITIES],
            ADDED_IDENTITIES,
        )
        observed = {
            event["Test"]
            for event in self.events
            if event.get("Action") == "pass" and "Test" in event
        }
        self.assertTrue(observed.isdisjoint(ADDED_IDENTITIES))
        for name in ADDED_IDENTITIES:
            with self.subTest(identity=name):
                with self.assertRaises(ValueError):
                    self.receive(required=REQUIRED + [name])

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
            and node.name
            == ("compile_native_cli" if operation == "build" else "_run_native_go_tests")
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
                "compiled_cli": self.root / "compiled-ollama",
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
        self.assertEqual(argv[argv.index("-o") + 1], str(self.root / "compiled-ollama"))
        self.assertNotEqual(argv[argv.index("-o") + 1], str(self.root / "owned-ollama"))

    def testNormalBuildDirectoryIsRetired(self):
        with PRODUCER.native_build_directory(self.root) as owned:
            (owned / "source").write_text("owned\n", encoding="utf-8")
        self.assertFalse(owned.exists())


class NativeGoFailureSummaryTests(unittest.TestCase):
    def test_names_failed_tests_with_their_output_and_the_stderr_tail(self):
        transcript = b"\n".join(
            [
                b'{"Action":"run","Test":"TestPasses"}',
                b'{"Action":"output","Test":"TestPasses","Output":"ok\\n"}',
                b'{"Action":"pass","Test":"TestPasses"}',
                b'{"Action":"output","Test":"TestDeadline","Output":"transport_test.go:91: deadline\\n"}',
                b'{"Action":"fail","Test":"TestDeadline"}',
                b"not json",
                b'{"Action":"fail"}',
            ]
        )
        summary = PRODUCER.native_go_failure_summary(transcript, b"exit status 1\n")
        self.assertEqual(
            summary.splitlines(),
            ["FAIL TestDeadline", "    transport_test.go:91: deadline", "exit status 1"],
        )


class NativeCliPublicationTests(unittest.TestCase):
    """Real owned file replacement with recording Go/lipo, never native compilation."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="managed-fresh-cli-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.candidate = self.root / "source"
        self.candidate.mkdir()
        self.cli = self.root / "ollama"
        self.original = b"Independent authenticated upstream CLI bytes\n"
        self.compiled = b"Independent recorded fresh native CLI bytes\n"
        self.cli.write_bytes(self.original)
        self.options = SimpleNamespace(go="owned-go")
        self.env = {"CGO_ENABLED": "1", "CC": "owned-clang -isysroot owned-sdk"}
        self.calls = []
        self.mode = "healthy"
        self.refusal = subprocess.CalledProcessError(78, ["owned-go", "build"])

    def command(self, argv, *, cwd=None, env=None):
        self.calls.append(argv)
        self.assertEqual(self.cli.read_bytes(), self.original)
        if argv[:2] == ["owned-go", "build"]:
            output = Path(argv[argv.index("-o") + 1])
            self.assertEqual(output, self.root / "compiled-ollama")
            self.assertFalse(output.exists())
            self.assertIs(env, self.env)
            self.assertEqual(cwd, self.candidate)
            if self.mode != "missing":
                output.write_bytes(b"" if self.mode == "empty" else self.compiled)
                output.chmod(0o755)
                self.compiled_mode = output.stat().st_mode
            if self.mode == "failed":
                raise self.refusal
            return ""
        if argv[:2] == ["lipo", "-archs"]:
            self.assertEqual(Path(argv[2]), self.root / "compiled-ollama")
            self.assertEqual(Path(argv[2]).read_bytes(), self.compiled)
            return "x86_64" if self.mode == "wrong-architecture" else "arm64"
        raise AssertionError("Unknown native compiler boundary command")

    def publish(self):
        with unittest.mock.patch.object(PRODUCER, "run", self.command):
            PRODUCER.compile_native_cli(
                self.options, self.candidate, self.root, self.cli, self.env, CONTRACT, "arm64"
            )

    def testFreshCompileVerifiesBeforeReplacingAuthenticatedCli(self):
        self.publish()
        self.assertEqual(self.cli.read_bytes(), self.compiled)
        self.assertEqual(self.cli.stat().st_mode, self.compiled_mode)
        self.assertEqual(
            [row[:2] for row in self.calls], [["owned-go", "build"], ["lipo", "-archs"]]
        )
        self.assertFalse((self.root / "compiled-ollama").exists())

    def testFailedCompilationPreservesOriginalCliAndExactError(self):
        self.mode = "failed"
        with self.assertRaises(subprocess.CalledProcessError) as raised:
            self.publish()
        self.assertIs(raised.exception, self.refusal)
        self.assertEqual(self.cli.read_bytes(), self.original)
        self.assertEqual(len(self.calls), 1)

    def testMissingOrAlreadyOwnedOutputCannotReplaceCli(self):
        for mode in ("missing", "empty"):
            with self.subTest(mode=mode):
                self.mode = mode
                self.calls.clear()
                with self.assertRaisesRegex(ValueError, "not a regular file"):
                    self.publish()
                self.assertEqual(self.cli.read_bytes(), self.original)
                self.assertEqual(len(self.calls), 1)
                if (self.root / "compiled-ollama").exists():
                    (self.root / "compiled-ollama").unlink()
        self.calls.clear()
        (self.root / "compiled-ollama").write_bytes(b"Already owned candidate\n")
        with self.assertRaisesRegex(ValueError, "already owned"):
            self.publish()
        self.assertEqual(self.cli.read_bytes(), self.original)
        self.assertEqual(self.calls, [])

    def testWrongArchitectureCannotReplaceAuthenticatedCli(self):
        self.mode = "wrong-architecture"
        with self.assertRaisesRegex(ValueError, "architecture changed"):
            self.publish()
        self.assertEqual(self.cli.read_bytes(), self.original)
        self.assertEqual(len(self.calls), 2)


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
 # Readiness must expose only the closed, complete numeric PID.
 pid=Path(os.environ['CONTROL_PID'])
 pending=pid.with_name(pid.name+'.pending')
 with pending.open('x',encoding='ascii') as output:
  output.write(str(process.pid))
 os.replace(pending,pid)
 if os.environ['CONTROL_MODE']=='acquisition': os.kill(os.getpid(),signal.SIGTERM)
def rescue():
 for process in children:
  if process.returncode is None:
   os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=3)
"""


def publish_signal_control_result(root, data):
    """Expose the controlled receipt only after its complete file is closed."""
    pending = root / "result.json.pending"
    # Exclusive creation keeps an existing sibling outside this publication.
    with pending.open("x", encoding="utf-8") as output:
        output.write(data)
    os.replace(pending, root / "result.json")


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
        publish_signal_control_result(
            root,
            json.dumps(
                {
                    "outcome": outcome,
                    "handlers_restored": restored,
                    "settled": (root / "settled").exists(),
                    "child_alive": alive,
                    "proof_published": (root / "fixed.tgz.go-tests.receipt.json").exists(),
                }
            ),
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


SIGNAL_FAILURE_EXCEPTIONS = frozenset(
    (
        "AssertionError",
        "BrokenPipeError",
        "FileNotFoundError",
        "KeyboardInterrupt",
        "NativeGoCancelled",
        "NativeGoRetirementDebt",
        "OSError",
        "PermissionError",
        "ProcessLookupError",
        "RuntimeError",
        "SystemExit",
        "TimeoutExpired",
        "TypeError",
        "ValueError",
    )
)


def owned_signal_failure_diagnostic(root, original_stderr):
    """Project bounded existing bytes from the exact owned capture, never text."""
    prefix = "OWNED_SIGNAL_CALLER"
    try:
        expected = os.fstat(original_stderr.fileno())
        nonblocking = getattr(os, "O_NONBLOCK", None)
        nofollow = getattr(os, "O_NOFOLLOW", None)
        if (
            not isinstance(nonblocking, int)
            or nonblocking == 0
            or not isinstance(nofollow, int)
            or nofollow == 0
        ):
            return prefix + " stderr=capability_refused"
        descriptor = os.open(root / "caller.stderr", os.O_RDONLY | nonblocking | nofollow)
    except (OSError, ValueError):
        return prefix + " stderr=read_refused"
    outcome = "identity_refused"
    close_refused = False
    try:
        observed = os.fstat(descriptor)
        if stat.S_ISREG(observed.st_mode) and (observed.st_dev, observed.st_ino) == (
            expected.st_dev,
            expected.st_ino,
        ):
            data = os.read(descriptor, 8193)
            outcome = None
    except (OSError, ValueError):
        outcome = "read_refused"
    finally:
        try:
            os.close(descriptor)
        except OSError:
            close_refused = True
    if close_refused:
        return prefix + " stderr=close_refused"
    if outcome is not None:
        return prefix + " stderr=" + outcome
    if len(data) > 8192:
        return prefix + " stderr=oversized"
    try:
        text = data.decode("utf-8", "strict")
    except UnicodeError:
        return prefix + " stderr=encoding_refused"
    lines = text.splitlines()
    category = "unknown"
    for line in reversed(lines):
        if not line.strip():
            continue
        candidate = line.partition(":")[0]
        if candidate in SIGNAL_FAILURE_EXCEPTIONS:
            category = candidate
        break
    frame, number = "unknown", 0
    allowed = {
        "managed_ollama_go_evidence_test.py": "control",
        "build-macos-managed-ollama.py": "producer",
        "macos_owned_process.py": "owned_port",
        "subprocess.py": "subprocess",
    }
    for line in lines:
        matched = re.fullmatch(
            r'  File "([^"\n]+)", line ([1-9][0-9]{0,5})(?:, in [A-Za-z_][A-Za-z0-9_]*)?', line
        )
        if matched:
            token = allowed.get(Path(matched.group(1)).name)
            if token is not None:
                frame, number = token, int(matched.group(2))
    return f"{prefix} stderr=received bytes={len(data)} exception={category} frame={frame} line={number}"


def annotate_owned_signal_failure(error, root, original_stderr, secondary=None):
    """Optional closed diagnostics cannot replace the exact original error."""
    try:
        note = owned_signal_failure_diagnostic(root, original_stderr)
        if secondary is not None:
            kind = type(secondary).__name__
            note += " cleanup=" + (kind if kind in SIGNAL_FAILURE_EXCEPTIONS else "unknown")
        if callable(getattr(error, "add_note", None)):
            error.add_note(note)
        else:
            sys.stderr.write(note + "\n")
    except BaseException:
        # Original assertion and original cleanup remain authoritative.
        pass


def receive_owned_signal_failure_diagnostic_controls(test):
    """Keep the actual failure formatter exercised even when the child passes."""
    with tempfile.TemporaryDirectory(prefix="signal-diagnostic-controls-") as temporary:
        root = Path(temporary)
        path = root / "caller.stderr"
        with path.open("wb") as original_stderr:
            payload = b'  File "/private/SECRET/macOS/macos_owned_process.py", line 37, in settle\nRuntimeError: PRIVATE_VALUE\n'
            original_stderr.write(payload)
            original_stderr.flush()
            fact = owned_signal_failure_diagnostic(root, original_stderr)
            test.assertEqual(
                fact,
                f"OWNED_SIGNAL_CALLER stderr=received bytes={len(payload)} exception=RuntimeError frame=owned_port line=37",
            )
            test.assertNotIn("PRIVATE_VALUE", fact)
            test.assertNotIn("SECRET", fact)
            primary = AssertionError("primary")
            secondary = AssertionError("secondary")
            annotate_owned_signal_failure(primary, root, original_stderr, secondary)
            if hasattr(primary, "__notes__"):
                test.assertEqual(primary.__notes__, [fact + " cleanup=AssertionError"])
            test.assertEqual(primary.args, ("primary",))
        for data, expected in (
            (b"ForeignException: PRIVATE_VALUE\n", "exception=unknown frame=unknown line=0"),
            (b"\xff", "stderr=encoding_refused"),
            (b"x" * 8193, "stderr=oversized"),
        ):
            with path.open("wb") as original_stderr:
                original_stderr.write(data)
                original_stderr.flush()
                fact = owned_signal_failure_diagnostic(root, original_stderr)
                test.assertIn(expected, fact)
                test.assertNotIn("PRIVATE_VALUE", fact)
        with path.open("wb") as original_stderr:
            path.rename(root / "original.stderr")
            path.write_bytes(b"RuntimeError: FOREIGN_PRIVATE_VALUE\n")
            test.assertEqual(
                owned_signal_failure_diagnostic(root, original_stderr),
                "OWNED_SIGNAL_CALLER stderr=identity_refused",
            )
            path.unlink()
            path.symlink_to(root / "original.stderr")
            test.assertEqual(
                owned_signal_failure_diagnostic(root, original_stderr),
                "OWNED_SIGNAL_CALLER stderr=read_refused",
            )
            path.unlink()
            os.mkfifo(path)
            test.assertEqual(
                owned_signal_failure_diagnostic(root, original_stderr),
                "OWNED_SIGNAL_CALLER stderr=identity_refused",
            )
        test.assertEqual(
            owned_signal_failure_diagnostic(root, original_stderr),
            "OWNED_SIGNAL_CALLER stderr=read_refused",
        )

        path.unlink()
        with path.open("wb") as original_stderr:
            actual_close = os.close
            closes = []

            def refused_close(descriptor):
                closes.append(descriptor)
                actual_close(descriptor)
                raise OSError("controlled close refusal after physical close")

            with unittest.mock.patch.object(os, "close", side_effect=refused_close):
                test.assertEqual(
                    owned_signal_failure_diagnostic(root, original_stderr),
                    "OWNED_SIGNAL_CALLER stderr=close_refused",
                )
            test.assertEqual(len(closes), 1)

        class RefusedNote(AssertionError):
            def add_note(self, note):
                raise RuntimeError("controlled diagnostic sink refusal")

        primary = RefusedNote("primary")
        annotate_owned_signal_failure(primary, root, original_stderr)
        test.assertEqual(primary.args, ("primary",))


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
                primary = None
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
                except BaseException as error:
                    primary = error
                    raise
                finally:
                    try:
                        (root / "rescue").touch()
                        process.wait(timeout=5)
                        self.assertEqual(process.returncode, 0)
                    except BaseException as cleanup_error:
                        if primary is not None:
                            annotate_owned_signal_failure(primary, root, errors, cleanup_error)
                            raise primary from cleanup_error
                        annotate_owned_signal_failure(cleanup_error, root, errors)
                        raise
                    else:
                        if primary is not None:
                            annotate_owned_signal_failure(primary, root, errors)

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
        receive_owned_signal_failure_diagnostic_controls(self)

    def testRefusedRetirementPreservesDebtWithoutProof(self):
        self.run_control(signal.SIGTERM, "refuse")

    def testFailedRetirementObservationPreservesDebtWithoutProof(self):
        self.run_control(signal.SIGTERM, "raise")


# Seven additive receiving controls preserve the original 37-case cohort above.
ATOMIC_PUBLICATION_SCHEDULE = 'import json\nimport os\nimport sys\nimport time\nfrom pathlib import Path\n\n_original_open = Path.open\nif "--signal-caller" in sys.argv:\n    class ScheduledWriter:\n        def __init__(self, stream, path):\n            self.stream = stream\n            self.path = path\n\n        def __enter__(self):\n            self.stream.__enter__()\n            return self\n\n        def __exit__(self, *args):\n            return self.stream.__exit__(*args)\n\n        def write(self, data):\n            mode = os.environ["SIGNAL_PUBLICATION_SCHEDULE"]\n            if mode == "partial":\n                self.stream.write("{")\n                self.stream.flush()\n            destination = self.path.parent / "result.json"\n            assert not destination.exists()\n            # The original parent runs during this finite controlled write pause.\n            time.sleep(0.05)\n            assert not destination.exists()\n            with _original_open(Path(os.environ["SIGNAL_PUBLICATION_FACT"]), "x") as fact:\n                json.dump({"mode": mode, "destination_absent_before_and_after_pause": True}, fact)\n            if mode == "partial":\n                self.stream.seek(0)\n                self.stream.truncate()\n            return self.stream.write(data)\n\n    def open_path(self, *args, **kwargs):\n        stream = _original_open(self, *args, **kwargs)\n        if self.name == "result.json.pending":\n            return ScheduledWriter(stream, self)\n        return stream\n\n    Path.open = open_path\n'


class AtomicPublicationReceivingTests(unittest.TestCase):
    def scheduled_original_control(self, mode):
        with tempfile.TemporaryDirectory(prefix="signal-publication-receiving-") as temporary:
            root = Path(temporary)
            hooks = root / "hooks"
            hooks.mkdir()
            (hooks / "sitecustomize.py").write_text(ATOMIC_PUBLICATION_SCHEDULE, encoding="utf-8")
            fact = root / "publication.json"
            env = dict(
                os.environ,
                PYTHONPATH=str(hooks),
                SIGNAL_PUBLICATION_SCHEDULE=mode,
                SIGNAL_PUBLICATION_FACT=str(fact),
            )
            result = subprocess.run(
                [
                    sys.executable,
                    "-B",
                    str(Path(__file__).resolve()),
                    "NativeGoSignalOwnershipTests.testActualSigtermSettlesAndRestoresHandlers",
                    "-v",
                ],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(b"Ran 1 test", result.stderr)
            self.assertIn(b"\nOK\n", result.stderr)
            self.assertEqual(
                json.loads(fact.read_text()),
                {"mode": mode, "destination_absent_before_and_after_pause": True},
            )

    def testEmptyPendingFileCannotReachOriginalReader(self):
        self.scheduled_original_control("empty")

    def testPartialPendingFileCannotReachOriginalReader(self):
        self.scheduled_original_control("partial")

    def testCompleteClosedFileIsRenamedWithinSameOwnedDirectory(self):
        with tempfile.TemporaryDirectory(prefix="signal-publication-closed-") as temporary:
            root = Path(temporary)
            actual_replace = os.replace
            received = []
            streams = []
            actual_open = Path.open

            def tracked_open(path, *args, **kwargs):
                stream = actual_open(path, *args, **kwargs)
                if args and args[0] == "x":
                    streams.append(stream)
                return stream

            def replace(source, destination):
                self.assertEqual(len(streams), 1)
                self.assertTrue(streams[0].closed)
                self.assertEqual(source, root / "result.json.pending")
                self.assertEqual(destination, root / "result.json")
                self.assertEqual(source.read_bytes(), b'{"answer":42}')
                self.assertFalse(destination.exists())
                actual_replace(source, destination)
                received.append(True)

            with (
                unittest.mock.patch.object(Path, "open", tracked_open),
                unittest.mock.patch.object(os, "replace", replace),
            ):
                publish_signal_control_result(root, '{"answer":42}')
            self.assertEqual(received, [True])
            self.assertEqual((root / "result.json").read_bytes(), b'{"answer":42}')
            self.assertFalse((root / "result.json.pending").exists())

    def testWriteErrorClosesActualFileAndNeverPublishes(self):
        with tempfile.TemporaryDirectory(prefix="signal-publication-write-error-") as temporary:
            root = Path(temporary)
            actual_open = Path.open
            primary = OSError("controlled-write-refusal")
            streams = []

            class RefusedWriter:
                def __init__(self, stream):
                    self.stream = stream

                def __enter__(self):
                    self.stream.__enter__()
                    return self

                def __exit__(self, *args):
                    return self.stream.__exit__(*args)

                def write(self, data):
                    self.stream.write("{")
                    self.stream.flush()
                    raise primary

            def open_path(path, *args, **kwargs):
                stream = actual_open(path, *args, **kwargs)
                streams.append(stream)
                return RefusedWriter(stream)

            with (
                unittest.mock.patch.object(Path, "open", open_path),
                unittest.mock.patch.object(os, "replace") as replacement,
            ):
                with self.assertRaises(OSError) as raised:
                    publish_signal_control_result(root, '{"answer":42}')
                self.assertIs(raised.exception, primary)
                replacement.assert_not_called()
            self.assertTrue(all(stream.closed for stream in streams))
            self.assertFalse((root / "result.json").exists())
            self.assertEqual((root / "result.json.pending").read_bytes(), b"{")

    def testCloseErrorCannotPublishAndPreservesPrimary(self):
        with tempfile.TemporaryDirectory(prefix="signal-publication-close-error-") as temporary:
            root = Path(temporary)
            actual_open = Path.open
            primary = OSError("controlled-close-refusal")
            streams = []

            class RefusedClose:
                def __init__(self, stream):
                    self.stream = stream

                def __enter__(self):
                    self.stream.__enter__()
                    return self

                def __exit__(self, *args):
                    self.stream.__exit__(*args)
                    raise primary

                def write(self, data):
                    return self.stream.write(data)

            def open_path(path, *args, **kwargs):
                stream = actual_open(path, *args, **kwargs)
                streams.append(stream)
                return RefusedClose(stream)

            with (
                unittest.mock.patch.object(Path, "open", open_path),
                unittest.mock.patch.object(os, "replace") as replacement,
            ):
                with self.assertRaises(OSError) as raised:
                    publish_signal_control_result(root, '{"answer":42}')
                self.assertIs(raised.exception, primary)
                replacement.assert_not_called()
            self.assertTrue(all(stream.closed for stream in streams))
            self.assertFalse((root / "result.json").exists())

    def testReplaceRefusalKeepsPreviousCompleteReceiptAndPrimary(self):
        with tempfile.TemporaryDirectory(prefix="signal-publication-replace-error-") as temporary:
            root = Path(temporary)
            (root / "result.json").write_bytes(b'{"answer":7}')
            primary = OSError("controlled-replace-refusal")
            with unittest.mock.patch.object(os, "replace", side_effect=primary):
                with self.assertRaises(OSError) as raised:
                    publish_signal_control_result(root, '{"answer":42}')
            self.assertIs(raised.exception, primary)
            self.assertEqual((root / "result.json").read_bytes(), b'{"answer":7}')
            self.assertEqual((root / "result.json.pending").read_bytes(), b'{"answer":42}')

    def testExistingSiblingIsRefusedWithoutTruncatingItsBytes(self):
        with tempfile.TemporaryDirectory(prefix="signal-publication-foreign-") as temporary:
            root = Path(temporary)
            (root / "result.json.pending").write_bytes(b"foreign-sentinel")
            with self.assertRaises(FileExistsError):
                publish_signal_control_result(root, '{"answer":42}')
            self.assertEqual((root / "result.json.pending").read_bytes(), b"foreign-sentinel")
            self.assertFalse((root / "result.json").exists())


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
