// tools/test/test-hardening-d-native-timeout-contract.cjs

/**
 * ==============================================================================
 * MODULE: Caller ↔ Native Timeout Contract (hardening-d-native-timeout-contract)
 * DESCRIPTION:
 * Every deadline a native worker caller arms must leave at least MARGIN_SEC
 * over the budget that worker gives itself for the same answer. The two sides
 * can live in different languages, so this test reads their actual owners
 * together. Supplementary no-prompt AppleEvent admission also needs this
 * margin for subprocess startup, JXA construction and numeric status delivery.
 *
 * ROOT CAUSE ENCODED (incident of 2026-09-30):
 * The Karabiner lease worker answers every PING, PAUSE and RESUME within its
 * private command budget (kPrivateCommandAckTimeoutSeconds, 1.75 s, in
 * RemapLeaseWorker.swift) or fences itself. Hammerspoon waited 2.0 s for that
 * answer: 0.25 s for the pipe and a main thread busy with its start-up builds.
 * dev.152 failed with "timeout waiting for PONG 1". The fix (f4c5c1d48) raised
 * the Lua deadline by hand; this test makes the rule a contract, for that pair
 * and for every other pair the two sides share.
 *
 * FEATURES & RATIONALE:
 * 1. Values are parsed from source, never copied: the Swift constants, the
 *    Lua constants, and which Lua constant arm_ack_timer uses for which ACK.
 * 2. The Swift side of a pair is derived from the code that spends it. The
 *    guardian registration budget counts the launchctl steps and health waits
 *    in ensureLegacyRemapGuardianRegistered, so an added step raises the
 *    required Lua deadline without anyone updating a comment.
 * 3. A pair whose parse finds nothing fails: a renamed constant must not turn
 *    this contract into a silent pass.
 * 4. `--root <dir>` runs the contract against another checkout's copy (used to
 *    prove the test red on the pre-fix revision of an incident).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const rootArg = process.argv.indexOf('--root');
const ROOT =
	rootArg > 0 ? path.resolve(process.argv[rootArg + 1]) : path.resolve(__dirname, '..', '..');
const MACOS = path.join(ROOT, 'static', 'ergopti_plus', 'macos');
const SWIFT_DIR = path.join(MACOS, 'launcher', 'Sources', 'ErgoptiPlus');

// The pipe, a main thread busy with its first builds and a timer that fires a
// little late all come out of this margin. 0.25 s was not enough (dev.152).
const MARGIN_SEC = 2.0;

const errors = [];
const passes = [];

function read(file) {
	return fs.readFileSync(file, 'utf8');
}

/** Removes Swift line and block comments so prose cannot satisfy a count. */
function stripSwiftComments(src) {
	return src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
}

/** Removes Lua comments (block first, then line). */
function stripLuaComments(src) {
	return src.replace(/--\[(=*)\[[\s\S]*?\]\1\]/g, '').replace(/--[^\n]*/g, '');
}

/**
 * Returns the body of one Swift function, parameter list skipped by paren
 * depth so default closures in the signature cannot end it early.
 */
function swiftFuncBody(src, name) {
	const start = src.search(new RegExp(`\\bfunc\\s+${name}\\s*\\(`));
	if (start < 0) return null;
	let i = src.indexOf('(', start);
	let depth = 0;
	for (; i < src.length; i++) {
		if (src[i] === '(') depth++;
		else if (src[i] === ')') {
			depth--;
			if (depth === 0) break;
		}
	}
	const open = src.indexOf('{', i);
	depth = 0;
	for (let j = open; j < src.length; j++) {
		if (src[j] === '{') depth++;
		else if (src[j] === '}') {
			depth--;
			if (depth === 0) return src.slice(open + 1, j);
		}
	}
	return null;
}

/** Reads one `let kName: TimeInterval = <number>` from a Swift source. */
function swiftSeconds(src, name, file) {
	const m = src.match(new RegExp(`\\blet\\s+${name}\\s*:\\s*TimeInterval\\s*=\\s*([\\d_.]+)`));
	if (!m) {
		errors.push(`${file}: ${name} is not declared as a TimeInterval literal any more`);
		return NaN;
	}
	return Number(m[1].replace(/_/g, ''));
}

/** Reads one `local NAME = <number>` from a Lua source. */
function luaSeconds(src, name, file) {
	const m = src.match(new RegExp(`^local\\s+${name}\\s*=\\s*([\\d.]+)`, 'm'));
	if (!m) {
		errors.push(`${file}: ${name} is not declared as a numeric local any more`);
		return NaN;
	}
	return Number(m[1]);
}

/** Counts non-overlapping literal occurrences. */
function count(haystack, needle) {
	return haystack.split(needle).length - 1;
}

function requirePair(label, luaName, luaValue, swiftLabel, swiftBudget, caller = 'Lua') {
	if (!Number.isFinite(luaValue) || !Number.isFinite(swiftBudget)) {
		errors.push(`${label}: one side of the pair could not be read (see above)`);
		return;
	}
	const margin = luaValue - swiftBudget;
	const line =
		`${label}: ${caller} ${luaName} = ${luaValue} s, native ${swiftLabel} = ` +
		`${swiftBudget.toFixed(2)} s, margin ${margin.toFixed(2)} s`;
	if (margin + 1e-9 < MARGIN_SEC) {
		errors.push(
			`${line} — needs at least ${MARGIN_SEC} s: a deadline this close to the ` +
				'worker budget fails a healthy worker whenever the pipe or the main thread is slow'
		);
	} else {
		passes.push(line);
	}
}

const WORKER_FILE = 'RemapLeaseWorker.swift';
const GUARDIAN_FILE = 'RemapLeaseGuardian.swift';
const LEASE_LUA = 'platform/remap/lease_controller.lua';
const REMAP_LUA = 'platform/remap/init.lua';

const worker = stripSwiftComments(read(path.join(SWIFT_DIR, WORKER_FILE)));
const guardian = stripSwiftComments(read(path.join(SWIFT_DIR, GUARDIAN_FILE)));
const leaseLua = stripLuaComments(read(path.join(MACOS, LEASE_LUA)));
const remapLua = stripLuaComments(read(path.join(MACOS, REMAP_LUA)));

// ── 1. The lease worker's private command and fence budgets ────────────────

const commandBudget = swiftSeconds(worker, 'kPrivateCommandAckTimeoutSeconds', WORKER_FILE);
const fenceBudget = swiftSeconds(worker, 'kPrivateFenceAckTimeoutSeconds', WORKER_FILE);
const cliBudget = swiftSeconds(worker, 'kCLITimeoutSeconds', WORKER_FILE);

// The budget each private command gets is chosen in one place: STOP spends the
// fence budget, every other command the command budget. A third branch would
// be a budget this test does not know.
{
	const arm = swiftFuncBody(worker, 'arm');
	if (!arm || !/command\s*==\s*\.stop/.test(arm)) {
		errors.push(`${WORKER_FILE}: LeasePrivateCommandDeadline.arm no longer singles out .stop`);
	} else if (
		count(arm, 'kPrivateFenceAckTimeoutSeconds') !== 1 ||
		count(arm, 'kPrivateCommandAckTimeoutSeconds') !== 1
	) {
		errors.push(
			`${WORKER_FILE}: LeasePrivateCommandDeadline.arm must choose between exactly the ` +
				'fence and the command budget'
		);
	}
}
// The worker's own CLI child must fit inside the command budget it answers in.
if (Number.isFinite(cliBudget) && Number.isFinite(commandBudget) && !(cliBudget < commandBudget)) {
	errors.push(
		`${WORKER_FILE}: kCLITimeoutSeconds (${cliBudget}) must stay below ` +
			`kPrivateCommandAckTimeoutSeconds (${commandBudget}): the CLI write is spent inside it`
	);
}

// ── 2. Which Lua deadline waits for which acknowledgement ──────────────────

const readyLua = luaSeconds(leaseLua, 'READY_ACK_TIMEOUT_SEC', LEASE_LUA);
const commandLua = luaSeconds(leaseLua, 'COMMAND_ACK_TIMEOUT_SEC', LEASE_LUA);
const stopLua = luaSeconds(leaseLua, 'STOP_ACK_TIMEOUT_SEC', LEASE_LUA);
{
	const armStart = leaseLua.search(/local function arm_ack_timer\s*\(/);
	const armBody = armStart < 0 ? '' : leaseLua.slice(armStart, armStart + 1200);
	const wants = [
		['local timeout = COMMAND_ACK_TIMEOUT_SEC', 'PONG, PAUSED and RESUMED wait COMMAND_ACK'],
		['if expected == "READY" then timeout = READY_ACK_TIMEOUT_SEC end', 'READY waits READY_ACK'],
		['if expected == "STOPPED" then timeout = STOP_ACK_TIMEOUT_SEC end', 'STOPPED waits STOP_ACK']
	];
	if (armBody === '') errors.push(`${LEASE_LUA}: arm_ack_timer was not found`);
	for (const [needle, why] of wants) {
		if (armBody !== '' && !armBody.includes(needle)) {
			errors.push(`${LEASE_LUA}: arm_ack_timer no longer reads "${needle}" (${why})`);
		}
	}
}

requirePair(
	'lease ACTIVATE → READY',
	'READY_ACK_TIMEOUT_SEC',
	readyLua,
	'kPrivateCommandAckTimeoutSeconds',
	commandBudget
);
requirePair(
	'lease PING/PAUSE/RESUME → PONG/PAUSED/RESUMED',
	'COMMAND_ACK_TIMEOUT_SEC',
	commandLua,
	'kPrivateCommandAckTimeoutSeconds',
	commandBudget
);
requirePair(
	'lease STOP → STOPPED',
	'STOP_ACK_TIMEOUT_SEC',
	stopLua,
	'kPrivateFenceAckTimeoutSeconds',
	fenceBudget
);

// ── 3. The guardian registration role ──────────────────────────────────────
// Its worst case is every launchctl step running into its timeout plus the
// SIGTERM grace, and every health wait running out. The counts come from the
// function that spends them.

const launchctlTimeout = swiftSeconds(guardian, 'kLegacyLaunchctlTimeoutSeconds', GUARDIAN_FILE);
{
	const legacy = swiftFuncBody(guardian, 'ensureLegacyRemapGuardianRegistered');
	const runnerClass = guardian.indexOf('final class PosixGuardianLaunchctlRunner');
	const runnerSource = runnerClass < 0 ? null : guardian.slice(runnerClass);
	const runBody = runnerSource && swiftFuncBody(runnerSource, 'run');
	// The Boolean registration port now delegates to the exact exit-status
	// owner shared with unregistration. Only that complete delegation may
	// redirect the budget scan; extra work in the wrapper must be accounted for.
	const delegatesExitStatus =
		runBody && /^\s*return\s+exitStatus\(arguments:\s*arguments\)\s*==\s*0\s*$/.test(runBody);
	const runner = delegatesExitStatus ? swiftFuncBody(runnerSource, 'exitStatus') : runBody;
	const healthWait = swiftFuncBody(guardian, 'waitForLegacyGuardianHealth');
	const graceMatch = runner && runner.match(/terminationDeadline\s*=[^\n]*\+\s*([\d.]+)/);
	if (!legacy || !runner || !healthWait || !graceMatch) {
		errors.push(
			`${GUARDIAN_FILE}: the legacy registration path (ensureLegacyRemapGuardianRegistered, ` +
				'the launchctl runner and waitForLegacyGuardianHealth) could not be read'
		);
	} else if (!healthWait.includes('kLegacyLaunchctlTimeoutSeconds')) {
		errors.push(
			`${GUARDIAN_FILE}: waitForLegacyGuardianHealth no longer waits kLegacyLaunchctlTimeoutSeconds`
		);
	} else {
		const steps = count(legacy, 'runner.run(arguments:');
		const healthWaits = count(legacy, 'guardianHealth(paths)');
		const grace = Number(graceMatch[1]);
		if (steps < 3 || healthWaits < 1) {
			errors.push(
				`${GUARDIAN_FILE}: found ${steps} launchctl step(s) and ${healthWaits} health wait(s) in ` +
					'ensureLegacyRemapGuardianRegistered — the count no longer reads the registration'
			);
		}
		const budget = steps * (launchctlTimeout + grace) + healthWaits * launchctlTimeout;
		requirePair(
			`guardian registration (${steps} launchctl steps + ${healthWaits} health waits)`,
			'LEASE_GUARDIAN_REGISTRATION_TIMEOUT_SEC',
			luaSeconds(remapLua, 'LEASE_GUARDIAN_REGISTRATION_TIMEOUT_SEC', REMAP_LUA),
			'worst-case registration',
			budget
		);
	}
}

// The status role only observes: it may not wait for health, or the 2 s probe
// would fail every healthy but slow answer.
{
	const observe = swiftFuncBody(guardian, 'observeRemapGuardianRegistrationStatus');
	const modern = swiftFuncBody(guardian, 'observeModernRemapGuardianRegistration');
	if (!observe || !modern) {
		errors.push(`${GUARDIAN_FILE}: the guardian status observation path could not be read`);
	} else {
		const waits = count(observe + modern, 'waitForLegacyGuardianHealth');
		requirePair(
			'guardian status probe',
			'LEASE_GUARDIAN_PROBE_TIMEOUT_SEC',
			luaSeconds(remapLua, 'LEASE_GUARDIAN_PROBE_TIMEOUT_SEC', REMAP_LUA),
			`${waits} health wait(s)`,
			waits * launchctlTimeout
		);
	}
}

// ── 4. The heartbeat the worker is told to expect ──────────────────────────
// The inner fences itself after heartbeatSeconds + kPrivateCommandAckTimeoutSeconds
// of silence, and heartbeatSeconds is whatever Lua passes. Lua must pass its
// own cadence, or the worker would wait for a heartbeat that comes later.
{
	const heartbeat = luaSeconds(leaseLua, 'HEARTBEAT_INTERVAL_SEC', LEASE_LUA);
	if (!/TimerScheduler\.every,\s*HEARTBEAT_INTERVAL_SEC/.test(leaseLua)) {
		errors.push(`${LEASE_LUA}: the heartbeat timer no longer ticks every HEARTBEAT_INTERVAL_SEC`);
	}
	if (!/tostring\(HEARTBEAT_INTERVAL_SEC\),?\s*\}/.test(leaseLua)) {
		errors.push(
			`${LEASE_LUA}: the worker spawn no longer passes HEARTBEAT_INTERVAL_SEC as its heartbeat`
		);
	}
	if (
		!/timeout:\s*identity\.heartbeatSeconds\s*\+\s*kPrivateCommandAckTimeoutSeconds/.test(worker)
	) {
		errors.push(
			`${WORKER_FILE}: the inner's silence deadline is no longer heartbeat + command budget`
		);
	} else if (Number.isFinite(heartbeat)) {
		passes.push(
			`lease heartbeat: Lua ticks every ${heartbeat} s, the inner fences after ` +
				`${(heartbeat + commandBudget).toFixed(2)} s of silence`
		);
	}
}

// ── 5. Supplementary no-prompt AppleEvent status delivery ─────────────────
// The outer deadline includes interpreter startup, descriptor construction,
// native sending and receipt delivery. Equal inner/outer budgets lose the
// native timeout status before the same owned osascript child can report it.
{
	const file = 'tools/diagnostics/hs_delayed_timer_probe.py';
	const source = read(path.join(ROOT, file));
	// Python formatting may wrap this binding; its exact owner and uniqueness remain mandatory.
	const usesNativeTimeoutOwner = (script) =>
		[
			...script.matchAll(
				/"__NO_PROMPT_NATIVE_TIMEOUT_SECONDS__",\s*str\(NO_PROMPT_NATIVE_TIMEOUT_SECONDS\)/g
			)
		].length === 1;
	const compactBinding =
		'"__NO_PROMPT_NATIVE_TIMEOUT_SECONDS__", str(NO_PROMPT_NATIVE_TIMEOUT_SECONDS)';
	for (const [binding, expected] of [
		[compactBinding, true],
		[
			'"__NO_PROMPT_NATIVE_TIMEOUT_SECONDS__",\n                str(NO_PROMPT_NATIVE_TIMEOUT_SECONDS)',
			true
		],
		['"__NO_PROMPT_NATIVE_TIMEOUT_SECONDS__", str(SCRIPTING_TIMEOUT_SECONDS)', false],
		['"__NO_PROMPT_NATIVE_TIMEOUT_SECONDS__", 8', false],
		['"__NO_PROMPT_NATIVE_TIMEOUT_SECONDS__", str(NO_PROMPT_NATIVE_TIMEOUT_SECONDS_FUTURE)', false],
		['"__FOREIGN_TIMEOUT__", str(NO_PROMPT_NATIVE_TIMEOUT_SECONDS)', false],
		[`${compactBinding}\n${compactBinding}`, false],
		['', false]
	]) {
		if (usesNativeTimeoutOwner(binding) !== expected)
			errors.push(
				`${file}: native timeout-owner recognition failed its independent binding fixture`
			);
	}
	const seconds = (name) => {
		const match = source.match(new RegExp(`^${name} = ([\\d.]+)$`, 'm'));
		if (!match) {
			errors.push(`${file}: ${name} is not declared as a numeric owner any more`);
			return NaN;
		}
		return Number(match[1]);
	};
	const execute = source.match(/    def execute\([\s\S]*?(?=\n    (?:@staticmethod|def ))/);
	const script = source.match(
		/^    def no_prompt_script\((?:scope=None)?\):[\s\S]*?(?=\n    (?:@staticmethod|def ))/m
	);
	if (!execute || !script) {
		errors.push(`${file}: the actual executor and no-prompt script owners could not be read`);
	} else {
		const executor = execute[0].replace(/#[^\n]*/g, '');
		const nativeScript = script[0]
			.replace(/\/\*[\s\S]*?\*\//g, '')
			.replace(/\/\/[^\n]*/g, '')
			.replace(/^\s*#.*$/gm, '');
		if (
			count(executor, 'command.communicate(timeout=SCRIPTING_TIMEOUT_SECONDS)') !== 1 ||
			count(
				nativeScript,
				'event.sendEventWithOptionsTimeoutError(__NO_PROMPT_OPTIONS__, __NO_PROMPT_NATIVE_TIMEOUT_SECONDS__, error)'
			) !== 1 ||
			!usesNativeTimeoutOwner(nativeScript)
		) {
			errors.push(
				`${file}: the outer executor and inner native send no longer spend their declared owners`
			);
		}
	}
	requirePair(
		'no-prompt AppleEvent status delivery',
		'SCRIPTING_TIMEOUT_SECONDS',
		seconds('SCRIPTING_TIMEOUT_SECONDS'),
		'NO_PROMPT_NATIVE_TIMEOUT_SECONDS',
		seconds('NO_PROMPT_NATIVE_TIMEOUT_SECONDS'),
		'Python'
	);
}

for (const line of passes) console.log(`  PASS  ${line}`);
if (errors.length > 0) {
	for (const e of errors) console.error(`  FAIL  ${e}`);
	console.error(
		`\n[hardening-d-native-timeout-contract] ${errors.length} caller ↔ native timeout pair(s) ` +
			'break the contract.'
	);
	process.exit(1);
}
if (passes.length < 6) {
	console.error('[hardening-d-native-timeout-contract] fewer than 6 pairs were checked.');
	process.exit(1);
}
console.log(`[hardening-d-native-timeout-contract] ${passes.length} pair(s) keep ${MARGIN_SEC} s.`);
