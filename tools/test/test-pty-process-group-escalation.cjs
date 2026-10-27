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
const PTY_PROCESS_GROUP = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'macos',
	'modules',
	'llm',
	'pty_process_group.lua'
);
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
	const match = source.match(/local WRAPPER_SOURCE = \[\[([\s\S]*?)\n\]\]\n\n--- Removes/);
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
REAPED = False
KILL_AT = None
POST_KILL_MODES = {"post-kill-transient", "post-kill-persistent"}
ZOMBIE_MODES = {"zombie-only", "zombie-descendant", "exited-permission", "live-permission", "exiting-permission"} | POST_KILL_MODES
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
        self.returncode = 78 if MODE in ZOMBIE_MODES and MODE not in {"live-permission", "exiting-permission"} else None
        FakeProcess.active = self
        EVENTS.append(["spawn", list(args), bool(start_new_session)])

    def poll(self):
        global REAPED
        # The leader of an exiting group is not reapable for a moment (Darwin).
        if MODE == "exiting-permission" and self.returncode is None and CLOCK >= 0.2:
            self.returncode = 0
        if MODE in ZOMBIE_MODES:
            EVENTS.append(["poll", self.pid, self.returncode])
            if self.returncode is not None:
                REAPED = True
        return self.returncode

    def wait(self, timeout=None):
        EVENTS.append(["wait", timeout])
        return self.returncode

subprocess.Popen = FakeProcess

def fake_killpg(pid, sig):
    global ALIVE, KILL_AT
    if sig == 0:
        if MODE in ZOMBIE_MODES:
            EVENTS.append(["probe", pid, bool(REAPED)])
            if pid != 4242:
                raise RuntimeError("signal probe targeted an unrelated group")
            if MODE in POST_KILL_MODES and KILL_AT is not None:
                if MODE == "post-kill-persistent" or CLOCK < KILL_AT + 0.15:
                    EVENTS.append(["unconfirmed", CLOCK])
                    raise PermissionError(1, "Operation not permitted")
                ALIVE = False
            if MODE in {"live-permission", "exited-permission"} or not REAPED:
                raise PermissionError(1, "Operation not permitted")
            if MODE == "exiting-permission":
                ALIVE = False
            if MODE == "zombie-only":
                ALIVE = False
        if ALIVE:
            return None
        raise ProcessLookupError()
    EVENTS.append(["killpg", pid, sig])
    if sig == signal.SIGTERM:
        if MODE not in ZOMBIE_MODES:
            FakeProcess.active.returncode = -signal.SIGTERM
        return None
    if sig == signal.SIGKILL:
        if MODE in POST_KILL_MODES:
            KILL_AT = CLOCK
            return None
        if MODE != "stubborn-after-kill":
            ALIVE = False
            if MODE not in ZOMBIE_MODES:
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
		encoding: 'utf8'
	});
	if (run.error || run.status !== 0) {
		throw new Error(`wrapper harness failed: status=${run.status}\n${run.stdout}${run.stderr}`);
	}
	return {
		payload: JSON.parse(run.stdout.trim()),
		stderr: run.stderr
	};
}

function eventsOf(run, kind) {
	return run.payload.events.filter((event) => event[0] === kind);
}

function escalationContract(run) {
	const signals = eventsOf(run, 'killpg').map((event) => event[2]);
	return (
		run.payload.exit !== 250 &&
		run.payload.alive === false &&
		run.payload.select_calls <= 40 &&
		JSON.stringify(signals) === JSON.stringify([15, 9]) &&
		eventsOf(run, 'wait').length === 1 &&
		eventsOf(run, 'close').some((event) => event[1] === 10) &&
		run.stderr.includes('SIGKILL')
	);
}

function boundedDrainContract(run) {
	const signals = eventsOf(run, 'killpg').map((event) => event[2]);
	return (
		run.payload.exit === 124 &&
		run.payload.alive === true &&
		run.payload.select_calls <= 40 &&
		JSON.stringify(signals) === JSON.stringify([15, 9]) &&
		eventsOf(run, 'wait').length === 0 &&
		eventsOf(run, 'close').some((event) => event[1] === 10) &&
		run.stderr.includes('drain deadline')
	);
}

function replaceExactly(source, before, after) {
	const first = source.indexOf(before);
	if (first === -1 || source.indexOf(before, first + before.length) !== -1) {
		throw new Error(`mutation anchor must occur exactly once: ${before}`);
	}
	return source.slice(0, first) + after + source.slice(first + before.length);
}

// A signalled leader exits 128 + N, the shell's and the native PTY guardian's
// convention. Popen's -9 used to leave the wrapper as 247, which no checker
// could name (field run 2026-10-27 22:32 saw a signalled installer).
function signalledLeaderStatus(python, wrapperSource) {
	const directory = fs.mkdtempSync(path.join(require('os').tmpdir(), 'ergopti-pty-signal-'));
	const wrapperPath = path.join(directory, 'wrapper.py');
	try {
		fs.writeFileSync(wrapperPath, wrapperSource);
		const run = spawnSync(python, ['-u', wrapperPath, '/bin/sh', '-c', 'kill -KILL $$'], {
			encoding: 'utf8',
			timeout: 20000
		});
		return run.status;
	} finally {
		fs.rmSync(directory, { recursive: true, force: true });
	}
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

test(
	'a TERM-resistant descendant receives KILL and the wrapper settles',
	escalationContract(run),
	JSON.stringify(run)
);

const stubborn = runWrapper(python, wrapper, 'stubborn-after-kill');
test(
	'the post-KILL drain has an absolute terminal deadline',
	boundedDrainContract(stubborn),
	JSON.stringify(stubborn)
);

const noKill = replaceExactly(
	wrapper,
	'        try: os.killpg(proc.pid, signal.SIGKILL)',
	'        pass  # mutation: TERM-resistant descendants survive'
);
test(
	'mutation guard rejects a missing process-group KILL',
	!escalationContract(runWrapper(python, noKill))
);

const noHardDeadline = replaceExactly(
	wrapper,
	'    if kill_sent and kill_deadline is not None and now >= kill_deadline:',
	'    if False:  # mutation: post-KILL drain is unbounded'
);
test(
	'mutation guard rejects a missing post-KILL deadline',
	!boundedDrainContract(runWrapper(python, noHardDeadline, 'stubborn-after-kill'))
);

const noWait = replaceExactly(
	wrapper,
	'    proc.wait()',
	'    pass  # mutation: the exact group leader is never reaped'
);
test(
	'mutation guard rejects a missing exact-leader wait',
	!escalationContract(runWrapper(python, noWait))
);

function zombieGoneContract(run) {
	const events = run.payload.events;
	const probes = eventsOf(run, 'probe');
	return (
		run.payload.exit === 78 &&
		run.payload.alive === false &&
		probes.length === 2 &&
		probes[0][2] === false &&
		probes[1][2] === true &&
		events.findIndex((event) => event[0] === 'probe') <
			events.findIndex((event) => event[0] === 'poll') &&
		eventsOf(run, 'poll')[0][2] === 78 &&
		eventsOf(run, 'killpg').length === 0 &&
		eventsOf(run, 'wait').length === 1 &&
		eventsOf(run, 'close').some((event) => event[1] === 10)
	);
}

const zombie = runWrapper(python, wrapper, 'zombie-only');
test(
	'zombie-only EPERM reaps the exact leader and preserves the child refusal exit78',
	zombieGoneContract(zombie),
	JSON.stringify(zombie)
);

const descendant = runWrapper(python, wrapper, 'zombie-descendant');
test(
	'reaped leader with a live descendant still requires TERM KILL and complete drain',
	escalationContract(descendant) &&
		descendant.payload.exit === 78 &&
		eventsOf(descendant, 'probe').length >= 3 &&
		eventsOf(descendant, 'probe')[1][2] === true,
	JSON.stringify(descendant)
);

// A refusal that outlasts the bounded grace is still an error; the grace only
// covers the moment an exiting leader is not yet reapable.
function lastingPermissionContract(run) {
	const exception = eventsOf(run, 'exception');
	return (
		run.payload.exit === 250 &&
		exception.length === 1 &&
		exception[0][1] === 'PermissionError' &&
		eventsOf(run, 'probe').length > 2 &&
		eventsOf(run, 'wait').length === 0 &&
		!eventsOf(run, 'close').some((event) => event[1] === 10)
	);
}

const livePermission = runWrapper(python, wrapper, 'live-permission');
test(
	'lasting EPERM with a live exact leader remains a permission refusal after the grace',
	lastingPermissionContract(livePermission),
	JSON.stringify(livePermission)
);

const exitedPermission = runWrapper(python, wrapper, 'exited-permission');
test(
	'persistent EPERM after exact leader reaping never proves group disappearance',
	exitedPermission.payload.exit !== 78 &&
		exitedPermission.payload.exit !== 0 &&
		eventsOf(exitedPermission, 'wait').length === 0,
	JSON.stringify(exitedPermission)
);

// Field run 2026-10-27 21:08: the MLX installer had finished and its leader was
// exiting; killpg answered EPERM before the leader could be reaped, and the
// wrapper raised instead of asking again on the next tick.
function exitingLeaderContract(run) {
	return (
		run.payload.exit === 0 &&
		eventsOf(run, 'exception').length === 0 &&
		eventsOf(run, 'wait').length === 1 &&
		!eventsOf(run, 'killpg').some((event) => event[2] === 9) &&
		eventsOf(run, 'close').some((event) => event[1] === 10)
	);
}
const exitingPermission = runWrapper(python, wrapper, 'exiting-permission');
test(
	'EPERM while the exiting leader is not yet reapable settles with its exit status',
	exitingLeaderContract(exitingPermission),
	JSON.stringify(exitingPermission)
);
const noGrace = replaceExactly(
	wrapper,
	'        elif now - eperm_since >= EPERM_GRACE_SECONDS: raise',
	'        raise  # mutation: no grace for an exiting leader'
);
test(
	'mutation guard rejects an immediate raise for an exiting leader',
	!exitingLeaderContract(runWrapper(python, noGrace, 'exiting-permission'))
);

const noReap = replaceExactly(
	wrapper,
	'        if proc.poll() is not None:',
	'        if False:  # mutation: zombie leader never reaped'
);
test(
	'mutation guard detects missing exact leader reaping',
	!zombieGoneContract(runWrapper(python, noReap, 'zombie-only'))
);

const reprobeBlock =
	'            try: os.killpg(proc.pid, 0)\n' +
	'            except ProcessLookupError:\n' +
	'                eperm_since = None\n' +
	'                return False\n' +
	'            except PermissionError:\n' +
	'                if kill_sent: return True';
const noReprobe = replaceExactly(
	wrapper,
	reprobeBlock,
	'            return False  # mutation: group disappearance inferred from leader exit'
);
test(
	'mutation guard detects disappearance inferred without a second native group probe',
	!escalationContract(runWrapper(python, noReprobe, 'zombie-descendant'))
);

const swallowPermission = replaceExactly(
	wrapper,
	reprobeBlock,
	'            try: os.killpg(proc.pid, 0)\n            except (ProcessLookupError, PermissionError): return False'
);
test(
	'mutation guard detects persistent permission refusal hidden as gone',
	runWrapper(python, swallowPermission, 'exited-permission').payload.exit === 78
);

const retiring = runWrapper(python, wrapper, 'post-kill-transient');
test(
	'post-KILL uncertainty waits for observed disappearance within the existing drain budget',
	escalationContract(retiring) &&
		retiring.payload.exit === 78 &&
		eventsOf(retiring, 'unconfirmed').length >= 2,
	JSON.stringify(retiring)
);
const unconfirmed = runWrapper(python, wrapper, 'post-kill-persistent');
test(
	'persistent post-KILL uncertainty times out without reporting retirement',
	boundedDrainContract(unconfirmed) && eventsOf(unconfirmed, 'unconfirmed').length >= 2,
	JSON.stringify(unconfirmed)
);
test(
	'mutation guard rejects inferring post-KILL retirement from permission refusal',
	!escalationContract(runWrapper(python, swallowPermission, 'post-kill-transient'))
);
test(
	'mutation guard keeps the existing deadline for unconfirmed post-KILL retirement',
	!boundedDrainContract(runWrapper(python, noHardDeadline, 'post-kill-persistent'))
);

const signalled = signalledLeaderStatus(python, wrapper);
test(
	'a leader killed by SIGKILL makes the wrapper exit 137',
	signalled === 137,
	`status=${signalled}`
);
const negativeStatus = replaceExactly(
	wrapper,
	'    if returncode < 0:\n        returncode = 128 - returncode\n',
	''
);
test(
	'mutation guard rejects the raw negative Popen status',
	signalledLeaderStatus(python, negativeStatus) !== 137
);

report();
