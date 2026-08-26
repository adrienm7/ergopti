// tools/test/test-input-source-python-supervisor.cjs

/**
 * ==============================================================================
 * MODULE: macOS Input-Source Python Supervisor - Behavioral Guard
 * DESCRIPTION:
 * Executes the exact Python program passed by the Hammerspoon input-source
 * adapter under deterministic process, clock, and signal doubles.  This proves
 * that every nested child consumes one global deadline and that timeout or
 * parent termination kills and reaps the exact process group.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const INPUT_SOURCES = path.join(ROOT, 'static', 'ergopti_plus', 'macos',
	'modules', 'keymap', 'input_sources.lua');
const PY_CANDIDATES = ['python3', 'python'];

let passed = 0;
let failed = 0;
const results = [];

function test(name, ok, detail = '') {
	passed += ok ? 1 : 0;
	failed += ok ? 0 : 1;
	results.push({ name, ok, detail });
}

function resolvePython() {
	for (const candidate of PY_CANDIDATES) {
		const probe = spawnSync(candidate, ['--version'], { encoding: 'utf8' });
		if (!probe.error && probe.status === 0) return candidate;
	}
	return null;
}

function extractSupervisor(source) {
	const match = source.match(/local py_script = \[\[([\s\S]*?)\n\]\]\n\n\tlocal nested_timeout/);
	if (!match) throw new Error('input-source Python supervisor block not found');
	return match[1];
}

function buildHarness(supervisor) {
	return `
import builtins, json, os, plistlib, signal, subprocess, sys, time

MODE = sys.argv[1]
BUNDLE_PATH = sys.argv[2]
SUPERVISOR = ${JSON.stringify(supervisor)}
EVENTS = []
HANDLERS = {}
BLOCKED = False
PENDING_TERM = False
REAL_PRINT = builtins.print

clock_values = {
    "budget": [100.0, 101.0, 104.0, 108.0],
    "timeout": [100.0, 101.0],
    "race": [100.0, 101.0],
}[MODE]
clock_iter = iter(clock_values)
time.monotonic = lambda: next(clock_iter)
plistlib.loads = lambda _raw: {"AppleEnabledInputSources": []}
plistlib.dumps = lambda _value, fmt=None: b"plist"
os.getuid = lambda: 501

if not hasattr(signal, "SIG_BLOCK"):
    signal.SIG_BLOCK = 0
if not hasattr(signal, "SIG_SETMASK"):
    signal.SIG_SETMASK = 2
if not hasattr(signal, "SIGKILL"):
    signal.SIGKILL = 9

def fake_signal(sig, handler):
    HANDLERS[sig] = handler

def deliver_or_queue_term():
    global PENDING_TERM
    if BLOCKED:
        PENDING_TERM = True
    else:
        HANDLERS[signal.SIGTERM](signal.SIGTERM, None)

def fake_pthread_sigmask(how, mask):
    global BLOCKED, PENDING_TERM
    previous = {signal.SIGTERM} if BLOCKED else set()
    if how == signal.SIG_BLOCK:
        BLOCKED = signal.SIGTERM in mask
    elif how == signal.SIG_SETMASK:
        BLOCKED = signal.SIGTERM in mask
        if not BLOCKED and PENDING_TERM:
            PENDING_TERM = False
            HANDLERS[signal.SIGTERM](signal.SIGTERM, None)
    return previous

signal.signal = fake_signal
signal.pthread_sigmask = fake_pthread_sigmask

def fake_killpg(pid, sig):
    EVENTS.append(["killpg", pid, sig])

os.killpg = fake_killpg

class FakePopen:
    created = 0

    def __init__(self, args, stdout=None, stderr=None, start_new_session=False):
        FakePopen.created += 1
        self.index = FakePopen.created
        self.pid = 1000 + self.index
        self.returncode = None
        EVENTS.append(["spawn", self.index, bool(start_new_session)])
        if MODE == "race" and self.index == 1:
            deliver_or_queue_term()

    def poll(self):
        return self.returncode

    def communicate(self, timeout=None):
        EVENTS.append(["communicate", self.index, timeout])
        if MODE == "timeout" and self.index == 1:
            raise subprocess.TimeoutExpired(["defaults"], timeout)
        self.returncode = 0
        return (b"plist" if self.index == 1 else b"", b"")

    def wait(self, timeout=None):
        EVENTS.append(["wait", self.pid, timeout])
        self.returncode = -9
        return self.returncode

subprocess.Popen = FakePopen
builtins.print = lambda *args, **_kwargs: EVENTS.append(
    ["print", " ".join(str(item) for item in args)])
sys.argv = ["input-source-supervisor", BUNDLE_PATH, "Ergopti", "9"]

exit_code = 0
try:
    exec(compile(SUPERVISOR, "input-source-supervisor", "exec"), {})
except SystemExit as exc:
    exit_code = exc.code if isinstance(exc.code, int) else 1
except BaseException as exc:
    exit_code = 250
    EVENTS.append(["exception", type(exc).__name__, str(exc)])
finally:
    REAL_PRINT(json.dumps({"exit": exit_code, "events": EVENTS}))
`;
}

function runMode(python, supervisor, fixtureDir, mode) {
	const harnessPath = path.join(fixtureDir, `harness-${mode}.py`);
	fs.writeFileSync(harnessPath, buildHarness(supervisor), 'utf8');
	const run = spawnSync(python, [harnessPath, mode, fixtureDir], {
		cwd: ROOT,
		encoding: 'utf8',
	});
	if (run.error || run.status !== 0) {
		throw new Error(`harness ${mode} failed: status=${run.status}\n${run.stdout}${run.stderr}`);
	}
	return JSON.parse(run.stdout.trim());
}

function eventsOf(payload, kind) {
	return payload.events.filter((event) => event[0] === kind);
}

function replaceExactly(source, before, after) {
	const first = source.indexOf(before);
	if (first === -1 || source.indexOf(before, first + before.length) !== -1) {
		throw new Error(`mutation anchor must occur exactly once: ${before}`);
	}
	return source.slice(0, first) + after + source.slice(first + before.length);
}

function budgetContract(payload) {
	const timeouts = eventsOf(payload, 'communicate').map((event) => event[2]);
	return payload.exit === 0
		&& JSON.stringify(timeouts) === JSON.stringify([8, 5, 1]);
}

function timeoutKillContract(payload) {
	return payload.exit === 1
		&& eventsOf(payload, 'killpg').some((event) => event[1] === 1001);
}

function timeoutWaitContract(payload) {
	return eventsOf(payload, 'wait')
		.some((event) => event[1] === 1001 && event[2] === 1);
}

function signalRaceContract(payload) {
	return payload.exit === 124
		&& eventsOf(payload, 'killpg').some((event) => event[1] === 1001)
		&& eventsOf(payload, 'wait').some((event) => event[1] === 1001);
}

function report() {
	console.log('TAP version 14');
	console.log(`1..${results.length}`);
	results.forEach((result, index) => {
		console.log(`${result.ok ? 'ok' : 'not ok'} ${index + 1} - ${result.name}`);
		if (!result.ok && result.detail) console.log(`  # ${result.detail}`);
	});
	console.log(`# passed: ${passed}/${results.length}`);
	if (failed > 0) process.exit(1);
}

const python = resolvePython();
if (!python) {
	console.error('No usable Python interpreter found (tried python3, python).');
	process.exit(1);
}

const source = fs.readFileSync(INPUT_SOURCES, 'utf8');
const supervisor = extractSupervisor(source);
const fixtureDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-input-source-'));
const resourcesDir = path.join(fixtureDir, 'Contents', 'Resources');

try {
	fs.mkdirSync(resourcesDir, { recursive: true });
	fs.writeFileSync(path.join(resourcesDir, 'Ergopti.keylayout'),
		'<keyboard id="42" name="Ergopti"></keyboard>\n', 'utf8');

	const budget = runMode(python, supervisor, fixtureDir, 'budget');
	test('all nested children consume the one decreasing monotonic budget',
		budgetContract(budget),
		JSON.stringify(budget));
	test('every nested child starts in its own process group',
		eventsOf(budget, 'spawn').length === 3
			&& eventsOf(budget, 'spawn').every((event) => event[2] === true),
		JSON.stringify(budget));

	const timeout = runMode(python, supervisor, fixtureDir, 'timeout');
	test('a nested timeout kills the exact process group',
		timeoutKillContract(timeout),
		JSON.stringify(timeout));
	test('a nested timeout waits for the exact killed child',
		timeoutWaitContract(timeout),
		JSON.stringify(timeout));

	const race = runMode(python, supervisor, fixtureDir, 'race');
	test('SIGTERM during spawn cannot escape before child ownership publishes',
		signalRaceContract(race),
		JSON.stringify(race));

	const resetBudget = replaceExactly(supervisor,
		'    remaining = DEADLINE - time.monotonic()',
		'    remaining = CHILD_TIMEOUT  # mutation: resets the global budget');
	test('mutation guard rejects a per-child budget reset',
		!budgetContract(runMode(python, resetBudget, fixtureDir, 'budget')));

	const communicateBudget = replaceExactly(supervisor,
		'        stdout, _stderr = child.communicate(timeout=remaining)',
		'        stdout, _stderr = child.communicate(timeout=CHILD_TIMEOUT)');
	test('mutation guard rejects a non-decreasing communicate timeout',
		!budgetContract(runMode(python, communicateBudget, fixtureDir, 'budget')));

	const noKill = replaceExactly(supervisor,
		'        os.killpg(child.pid, signal.SIGKILL)',
		'        pass  # mutation: child process group survives');
	test('mutation guard rejects missing process-group kill',
		!timeoutKillContract(runMode(python, noKill, fixtureDir, 'timeout')));

	const noWait = replaceExactly(supervisor,
		'        child.wait(timeout=1)',
		'        pass  # mutation: exact child is never reaped');
	test('mutation guard rejects missing exact-child wait',
		!timeoutWaitContract(runMode(python, noWait, fixtureDir, 'timeout')));

	const maskedSpawn = `    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
    try:
        child = subprocess.Popen(
            args, stdout=stdout_target, stderr=subprocess.DEVNULL,
            start_new_session=True)
        ACTIVE_CHILD = child
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)`;
	const unmaskedSpawn = `    child = subprocess.Popen(
        args, stdout=stdout_target, stderr=subprocess.DEVNULL,
        start_new_session=True)
    ACTIVE_CHILD = child`;
	const raceWindow = replaceExactly(supervisor, maskedSpawn, unmaskedSpawn);
	test('mutation guard rejects the SIGTERM ownership publication window',
		!signalRaceContract(runMode(python, raceWindow, fixtureDir, 'race')));
} finally {
	fs.rmSync(fixtureDir, { recursive: true, force: true });
}

report();
