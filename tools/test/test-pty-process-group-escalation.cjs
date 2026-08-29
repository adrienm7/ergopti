// tools/test/test-pty-process-group-escalation.cjs

/**
 * ==============================================================================
 * MODULE: macOS PTY Process-Group Escalation - Behavioral Guard
 * DESCRIPTION:
 * Executes the exact Python wrapper published by the Hammerspoon dependency
 * checkers under deterministic process, clock, signal, and PTY doubles.  A
 * descendant that ignores TERM must receive KILL and the wrapper must settle
 * within a bounded number of drain iterations.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const PTY_PROCESS_GROUP = path.join(ROOT, 'static', 'ergopti_plus', 'macos',
	'modules', 'llm', 'pty_process_group.lua');
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

function extractWrapper(source) {
	const match = source.match(
		/local WRAPPER_SOURCE = \[\[([\s\S]*?)\n\]\]\n\n--- Removes/);
	if (!match) throw new Error('PTY process-group Python wrapper block not found');
	return match[1];
}

function buildHarness(wrapper, mode) {
	return `
import builtins, json, os, select, signal, subprocess, sys, time

WRAPPER = ${JSON.stringify(wrapper)}
MODE = ${JSON.stringify(mode)}
EVENTS = []
HANDLERS = {}
ALIVE = True
CLOCK = 0.0
SELECT_CALLS = 0
REAL_PRINT = builtins.print

if not hasattr(signal, "SIGHUP"):
    signal.SIGHUP = 1
if not hasattr(signal, "SIGKILL"):
    signal.SIGKILL = 9

def fake_signal(sig, handler):
    HANDLERS[sig] = handler

signal.signal = fake_signal

def fake_monotonic():
    return CLOCK

def fake_sleep(delay):
    global CLOCK
    CLOCK += delay
    EVENTS.append(["sleep", delay])
    if CLOCK > 10.0:
        raise RuntimeError("process group outlived the escalation deadline")

time.monotonic = fake_monotonic
time.sleep = fake_sleep

class FakeProcess:
    active = None

    def __init__(self, args, stdin=None, stdout=None, stderr=None,
                 close_fds=False, start_new_session=False):
        self.pid = 4242
        self.returncode = None
        FakeProcess.active = self
        EVENTS.append(["spawn", list(args), bool(start_new_session)])

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        EVENTS.append(["wait", timeout])
        return self.returncode

subprocess.Popen = FakeProcess

def fake_killpg(pid, sig):
    global ALIVE
    if sig == 0:
        if ALIVE:
            return None
        raise ProcessLookupError()
    EVENTS.append(["killpg", pid, sig])
    if sig == signal.SIGTERM:
        FakeProcess.active.returncode = -signal.SIGTERM
        return None
    if sig == signal.SIGKILL:
        if MODE != "stubborn-after-kill":
            ALIVE = False
            FakeProcess.active.returncode = -signal.SIGKILL
        return None

os.killpg = fake_killpg
os.openpty = lambda: (10, 11)
os.close = lambda fd: EVENTS.append(["close", fd])
os.read = lambda _fd, _size: b""

def fake_select(_read, _write, _error, timeout):
    global CLOCK, SELECT_CALLS
    SELECT_CALLS += 1
    if SELECT_CALLS == 1:
        HANDLERS[signal.SIGTERM](signal.SIGTERM, None)
    CLOCK += timeout
    if SELECT_CALLS > 40:
        raise RuntimeError("wrapper did not escalate within forty drain iterations")
    return ([], [], [])

select.select = fake_select
sys.argv = ["pty-wrapper", "/bin/fake-child"]

exit_code = 0
try:
    exec(compile(WRAPPER, "pty-process-group-wrapper", "exec"), {})
except SystemExit as exc:
    exit_code = exc.code if isinstance(exc.code, int) else 1
except BaseException as exc:
    exit_code = 250
    EVENTS.append(["exception", type(exc).__name__, str(exc)])
finally:
    REAL_PRINT(json.dumps({
        "exit": exit_code,
        "events": EVENTS,
        "alive": ALIVE,
        "select_calls": SELECT_CALLS,
    }))
`;
}

function runWrapper(python, wrapper, mode = 'term-resistant') {
	const run = spawnSync(python, ['-c', buildHarness(wrapper, mode)], {
		cwd: ROOT,
		encoding: 'utf8',
	});
	if (run.error || run.status !== 0) {
		throw new Error(`wrapper harness failed: status=${run.status}\n${run.stdout}${run.stderr}`);
	}
	return {
		payload: JSON.parse(run.stdout.trim()),
		stderr: run.stderr,
	};
}

function eventsOf(run, kind) {
	return run.payload.events.filter((event) => event[0] === kind);
}

function escalationContract(run) {
	const signals = eventsOf(run, 'killpg').map((event) => event[2]);
	return run.payload.exit !== 250
		&& run.payload.alive === false
		&& run.payload.select_calls <= 40
		&& JSON.stringify(signals) === JSON.stringify([15, 9])
		&& eventsOf(run, 'wait').length === 1
		&& eventsOf(run, 'close').some((event) => event[1] === 10)
		&& run.stderr.includes('SIGKILL');
}

function boundedDrainContract(run) {
	const signals = eventsOf(run, 'killpg').map((event) => event[2]);
	return run.payload.exit === 124
		&& run.payload.alive === true
		&& run.payload.select_calls <= 40
		&& JSON.stringify(signals) === JSON.stringify([15, 9])
		&& eventsOf(run, 'wait').length === 0
		&& eventsOf(run, 'close').some((event) => event[1] === 10)
		&& run.stderr.includes('drain deadline');
}

function replaceExactly(source, before, after) {
	const first = source.indexOf(before);
	if (first === -1 || source.indexOf(before, first + before.length) !== -1) {
		throw new Error(`mutation anchor must occur exactly once: ${before}`);
	}
	return source.slice(0, first) + after + source.slice(first + before.length);
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

const source = fs.readFileSync(PTY_PROCESS_GROUP, 'utf8');
const wrapper = extractWrapper(source);
const run = runWrapper(python, wrapper);

test('a TERM-resistant descendant receives KILL and the wrapper settles',
	escalationContract(run), JSON.stringify(run));

const stubborn = runWrapper(python, wrapper, 'stubborn-after-kill');
test('the post-KILL drain has an absolute terminal deadline',
	boundedDrainContract(stubborn), JSON.stringify(stubborn));

const noKill = replaceExactly(wrapper,
	'        try: os.killpg(proc.pid, signal.SIGKILL)',
	'        pass  # mutation: TERM-resistant descendants survive');
test('mutation guard rejects a missing process-group KILL',
	!escalationContract(runWrapper(python, noKill)));

const noHardDeadline = replaceExactly(wrapper,
	'    if kill_sent and kill_deadline is not None and now >= kill_deadline:',
	'    if False:  # mutation: post-KILL drain is unbounded');
test('mutation guard rejects a missing post-KILL deadline',
	!boundedDrainContract(runWrapper(python, noHardDeadline, 'stubborn-after-kill')));

const noWait = replaceExactly(wrapper,
	'    proc.wait()',
	'    pass  # mutation: the exact group leader is never reaped');
test('mutation guard rejects a missing exact-leader wait',
	!escalationContract(runWrapper(python, noWait)));

report();
