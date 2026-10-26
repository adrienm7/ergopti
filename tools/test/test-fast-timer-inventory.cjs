// tools/test/test-fast-timer-inventory.cjs

/**
 * ==============================================================================
 * MODULE: Fast Repeating-Timer Inventory
 * DESCRIPTION:
 * Every REPEATING SetTimer under one second in the Windows driver must be listed
 * here, with what it polls and why it has to be that fast.
 *
 * ROOT CAUSE ENCODED:
 * A repeating timer is the one construct that costs CPU forever whether or not
 * anything is happening. `SetTimer(Fn, 150)` is ten wakeups a second for the
 * lifetime of the process, and the cost is invisible in every profile that
 * measures a keystroke — it shows up as a warm laptop and a flat battery, which
 * nobody attributes to a line of code. The driver has been through one campaign
 * to remove exactly this (`Metrics.FocusRefresh` blocking 20x/s on a Not
 * Responding window), and nothing stops the next one appearing.
 *
 * A one-shot (`SetTimer(Fn, -50)`) is NOT inventoried: it fires once and stops,
 * and the driver uses it heavily as a "run this off the current thread" idiom —
 * 101 such call sites, none of which is a poller. Only a positive period repeats.
 *
 * FEATURES & RATIONALE:
 * 1. The inventory is the test. Adding a poller means adding an entry that says
 *    what it watches and why the interval is what it is — the review that a bare
 *    `SetTimer(F, 100)` in a diff never gets.
 * 2. vendor/ is excluded: UIA.ahk and Promise.ahk are third-party and their
 *    timers are not ours to justify.
 * 3. An entry whose call site is gone fails too, so the list shrinks when a
 *    poller is removed instead of accumulating dead justifications.
 * 4. No numeric literal in a timer or sleep call. `SetTimer(Fn, -100)`,
 *    `Sleep 50`, `hs.timer.doAfter(0.05, ...)`, `Timers.after(1.5, ...)` and
 *    `setTimeout(fn, 80)` are delays typed where they are used, so the same
 *    delay is typed again (the gesture poll `-100` six times, the safety flush
 *    `-2000` three times) and drifts. A delay is a key of the shared timing
 *    registry (_shared/modules/timings/constants.toml) read through Timings.
 *    Zero is the "yield to the event loop" idiom and stays allowed. The sites
 *    that exist today are frozen per file in timer-literal-baseline.json, which
 *    can only shrink: node tools/test/test-fast-timer-inventory.cjs
 *    --update-timer-baseline rewrites it, and refuses while anything has grown.
 *    The Windows (AHK) sites are baseline entries until the Windows side moves
 *    them to registry keys; Swift sleeps are not scanned.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVER = path.join(ROOT, 'static', 'ergopti_plus', 'windows');

// Anything at or above this is a background chore, not a poller.
const FAST_MS = 1000;

/**
 * The inventory. Key is "<relative path>:<function>", value is the justification.
 * The interval is read from the source, not repeated here — one source of truth.
 */
const INVENTORY = {
	'ui/healthcheck/collection.ahk:this':
		'Armed only during a bounded local collection or retained worker retirement. ' +
		'100 ms observes atomic progress and explicit guided Ctrl/Shift transitions; ' +
		'no ambient input is retained, and acknowledged task completion disarms the timer.',
	'modules/llm/ollama_managed_bootstrap.ahk:this':
		'Armed only while a managed Ollama session owns installation, startup, model work or ' +
		'READY service custody. 150 ms bounds cancellation, stale configuration and pause ' +
		'observation; READY retains the ownership watch after the progress window closes. ' +
		'Cancel stops the exact callback, and no unowned or external server arms this timer.',
	'modules/dynamic_hotstrings/user_code.ahk:_UserHotstringsPoll':
		'Armed only while a programmable worker or exact Job/stage retirement debt is owned. ' +
		'25 ms bounds cooperative cancellation and stale source/focus/input publication; ' +
		'the final acknowledged cleanup disarms it. ShellRunner owns process completion, ' +
		'but exposes no progress subscription for these source and lifecycle receipts.',
	'adapters/llm_nav_event_owner.ahk:_LLM_NavEventOwnerServiceFn':
		'Drains receipts from the native navigation owner when its wake message is delayed or ' +
		'lost, and observes fail-open native delivery faults. 100 ms bounds how long a ' +
		'physically suppressed key or suspended native owner can wait for exact recovery; the ' +
		'timer is disarmed whenever the native owner stops.',
	'infra/lifecycle.ahk:_SuspendPendingPoll':
		'Runs ONLY while a suspend is deferred waiting for held prefix keys to be released, ' +
		'and stops as soon as they are. 25 ms because the user is mid-chord and any visible ' +
		'lag between releasing the keys and the driver suspending reads as a stuck modifier.',
	'ui/tooltip/core.ahk:_TooltipDequeuePollFn':
		'Drains the tooltip render queue. 100 ms is the upper bound on how long a queued ' +
		'prediction can sit unrendered, and the tooltip is the only place a prediction is ' +
		'shown before it is typed — a slower drain shows the user stale text.',
	'ui/spotlight/ownership.ahk:_SpotlightTick':
		'Armed only while a Spotlight session owns visible overlay windows. 100 ms bounds ' +
		'the delay before mouse movement or expiry dismisses those windows, and the timer is ' +
		'stopped atomically whenever the session is replaced, cancelled, or dismissed.',
	'modules/shortcuts/win.ahk:AwakeCheckMouseMoved':
		'Armed only while keep-awake is active, to cancel it the instant the user moves the ' +
		'mouse. 150 ms because a cancel the user has to wait for reads as the feature ignoring ' +
		'them. Disarmed with the feature.',
	'ui/menu/menu_llm/menu_api_entries.ahk:_LLM_Menu_ApiTestProgressTick':
		'Armed only while an API test probe shows its progress window, and stopped by ' +
		'_LLM_Menu_ApiTestProgressHide when the probe answers, times out or is cancelled. ' +
		'150 ms keeps the elapsed-time label and bar moving smoothly; a slower pulse makes ' +
		'the probe look frozen while it waits on the provider.',
	'modules/keymap/layout.ahk:_UIA_SelectionPollTimer':
		'Polls the UIA selection so a layout remap knows whether text is selected. 500 ms, and ' +
		'armed only in the apps that need it — the AX call is the expensive part, which is why ' +
		'this is a poll rather than an event subscription.'
};

/** Every production .ahk file, vendor and generated code excluded. */
function walk(dir, acc = []) {
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (e.name !== 'tests' && e.name !== '_generated' && e.name !== 'vendor') walk(p, acc);
		} else if (e.name.endsWith('.ahk')) {
			acc.push(p);
		}
	}
	return acc;
}

/**
 * Splits a SetTimer argument list on top-level commas, so a `.Bind(a, b)` in the
 * callback does not look like a period argument.
 * @param {string} args Raw text between the outer parentheses.
 * @returns {string[]} Arguments, in order.
 */
function splitArgs(args) {
	const out = [];
	let depth = 0;
	let cur = '';
	for (const ch of args) {
		if (ch === '(') depth++;
		else if (ch === ')') depth--;
		if (ch === ',' && depth === 0) {
			out.push(cur);
			cur = '';
		} else cur += ch;
	}
	out.push(cur);
	return out;
}

const CALL = /SetTimer\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)/g;

const found = new Map(); // "rel:callback" → { rel, line, ms }
let scanned = 0;

for (const abs of walk(DRIVER)) {
	const rel = path.relative(DRIVER, abs).split(path.sep).join('/');
	scanned++;
	fs.readFileSync(abs, 'utf8')
		.split(/\r?\n/)
		.forEach((line, i) => {
			const t = line.trim();
			if (t.startsWith(';')) return;
			for (const m of t.matchAll(CALL)) {
				const parts = splitArgs(m[1]);
				if (parts.length < 2) continue;
				// A positive literal repeats; a negative one fires once and stops.
				const num = parts[1].trim().match(/^(\d+)$/);
				if (!num) continue;
				const ms = Number(num[1]);
				if (ms <= 0 || ms >= FAST_MS) continue;
				// The callback name, for a stable key that survives a line move.
				const cb = (parts[0].trim().match(/^[A-Za-z_]\w*/) || ['<expr>'])[0];
				found.set(`${rel}:${cb}`, { rel, line: i + 1, ms });
			}
		});
}

// ------------------------------------------------------------------
// No numeric literal in a timer or sleep call, with a shrinking baseline.
// ------------------------------------------------------------------

const SP = path.join(ROOT, 'static', 'ergopti_plus');
const TIMER_LITERAL_BASELINE = path.join(__dirname, 'timer-literal-baseline.json');
const TIMER_LITERAL_COMMENT =
	'Timer and sleep calls per file that carry a non-zero numeric delay (tools/test/test-fast-timer-inventory.cjs). Shrink it with --update-timer-baseline as delays move to the timing registry; never add to it.';
const MIN_LITERAL_SCAN_FILES = 1000;
const LITERAL_SKIPPED_DIRECTORIES = new Set([
	'node_modules',
	'.git',
	'.build',
	'tests',
	'Tests',
	'vendor',
	'_generated'
]);
const LITERAL_EXTENSIONS = /\.(?:ahk|lua|js|cjs|mjs)$/;
const NONZERO = /^-?(?:\d+\.?\d*|\.\d+)$/;

// Lua: the delay is the first argument of a timer constructor.
const LUA_TIMER = /\b(?:doAfter|doEvery|after|every|sleep)\(\s*(-?[0-9][0-9.]*)\s*[,)]/g;
// JavaScript: the delay is the last argument of a one-line call.
const JS_TIMER = /\b(?:setTimeout|setInterval)\((?:[^()]|\([^()]*\))*,\s*(\d+(?:\.\d+)?)\s*\)/g;
const AHK_SLEEP = /\bSleep\(?\s*(\d+)\s*\)?/g;

/**
 * Counts the timer and sleep calls of one file that carry a non-zero numeric
 * literal as their delay.
 * @param {string} ext File extension with its dot.
 * @param {string} text File content.
 * @returns {number} Literal-delay call count.
 */
function literalDelayCount(ext, text) {
	let count = 0;
	for (const raw of text.split(/\r?\n/)) {
		const line = raw.trim();
		if (ext === '.ahk') {
			if (line.startsWith(';')) continue;
			for (const m of line.matchAll(CALL)) {
				const parts = splitArgs(m[1]);
				if (parts.length >= 2 && NONZERO.test(parts[1].trim()) && Number(parts[1]) !== 0) count++;
			}
			for (const m of line.matchAll(AHK_SLEEP)) if (Number(m[1]) > 0) count++;
		} else if (ext === '.lua') {
			if (line.startsWith('--')) continue;
			for (const m of line.matchAll(LUA_TIMER)) if (Number(m[1]) !== 0) count++;
		} else {
			if (line.startsWith('//') || line.startsWith('*')) continue;
			for (const m of line.matchAll(JS_TIMER)) if (Number(m[1]) > 0) count++;
		}
	}
	return count;
}

/** Literal-delay call count per production file under static/ergopti_plus. */
function literalDelayCounts() {
	const counts = {};
	let walked = 0;
	const visit = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const abs = path.join(dir, entry.name);
			if (entry.isDirectory()) {
				if (!LITERAL_SKIPPED_DIRECTORIES.has(entry.name)) visit(abs);
			} else if (LITERAL_EXTENSIONS.test(entry.name)) {
				walked++;
				const n = literalDelayCount(path.extname(entry.name), fs.readFileSync(abs, 'utf8'));
				if (n > 0) counts[path.relative(SP, abs).split(path.sep).join('/')] = n;
			}
		}
	};
	visit(SP);
	return { counts, walked };
}

/**
 * Compares the counts with the baseline.
 * @param {Object<string, number>} counts Current literal-delay counts per file.
 * @param {Object<string, number>} baseline Frozen counts.
 * @returns {{grown: string[], shrunk: string[]}} Files above and below their baseline.
 */
function compareLiteralBaseline(counts, baseline) {
	const grown = [];
	const shrunk = [];
	for (const rel of new Set([...Object.keys(counts), ...Object.keys(baseline)])) {
		const have = counts[rel] || 0;
		const frozen = baseline[rel] || 0;
		if (have > frozen) grown.push(`${rel}: ${have} literal delay(s), baseline ${frozen}`);
		else if (have < frozen) shrunk.push(`${rel}: ${have} literal delay(s), baseline ${frozen}`);
	}
	return { grown, shrunk };
}

/** Proves the detector counts what it must and ignores what it must. */
function literalSelfTest() {
	const failures = [];
	const expect = (name, ext, text, want) => {
		const got = literalDelayCount(ext, text);
		if (got !== want) failures.push(`${name}: expected ${want}, got ${got}`);
	};
	expect('AHK one-shot literal', '.ahk', 'SetTimer(Fn.Bind(1, 2), -100)', 1);
	expect('AHK zero delay', '.ahk', 'SetTimer(Fn, 0)', 0);
	expect('AHK registry delay', '.ahk', 'SetTimer(Fn, -TimingsGet("ui", "x_ms"))', 0);
	expect('AHK Sleep literal', '.ahk', '    Sleep 50', 1);
	expect('AHK Sleep call form', '.ahk', 'Sleep(20)', 1);
	expect('AHK comment', '.ahk', '; SetTimer(Fn, -100)', 0);
	expect('Lua doAfter literal', '.lua', 'hs.timer.doAfter(0.05, function() end)', 1);
	expect('Lua deferred literal', '.lua', 'DeferredWork.after(1.5, fn, "x")', 1);
	expect('Lua yield', '.lua', 'TimerScheduler.after(0, function() end)', 0);
	expect('Lua constant', '.lua', 'hs.timer.doAfter(DELAY_SEC, fn)', 0);
	expect('Lua comment', '.lua', '-- hs.timer.doAfter(2, fn)', 0);
	expect('JS setTimeout literal', '.js', 'setTimeout(() => el.focus(), 80);', 1);
	expect('JS yield', '.js', 'setTimeout(() => el.focus(), 0);', 0);
	expect('JS constant', '.js', 'setTimeout(fn, DELAY_MS);', 0);
	const verdict = compareLiteralBaseline({ 'a.lua': 2 }, { 'a.lua': 1 });
	if (verdict.grown.length !== 1) failures.push('a grown count was not reported');
	if (compareLiteralBaseline({}, { 'a.lua': 1 }).shrunk.length !== 1)
		failures.push('a stale baseline entry was not reported');
	return failures;
}

const literal = literalDelayCounts();
if (process.argv.includes('--update-timer-baseline')) {
	const baseline = JSON.parse(fs.readFileSync(TIMER_LITERAL_BASELINE, 'utf8'));
	delete baseline._comment;
	if (compareLiteralBaseline(literal.counts, baseline).grown.length > 0) {
		console.error('refusing to update: a file gained a literal delay. Use a timing registry key.');
		process.exit(1);
	}
	fs.writeFileSync(
		TIMER_LITERAL_BASELINE,
		JSON.stringify({ _comment: TIMER_LITERAL_COMMENT, ...literal.counts }, null, '\t') + '\n'
	);
	console.log('timer-literal baseline rewritten');
	process.exit(0);
}

const errors = [];

if (scanned < 100) {
	errors.push(
		`walked only ${scanned} .ahk file(s) — the scan is broken, and an empty inventory proves nothing`
	);
}

if (literal.walked < MIN_LITERAL_SCAN_FILES) {
	errors.push(
		`the literal-delay scan walked only ${literal.walked} file(s) — it is broken, and an empty count proves nothing`
	);
}
{
	const frozen = JSON.parse(fs.readFileSync(TIMER_LITERAL_BASELINE, 'utf8'));
	delete frozen._comment;
	const verdict = compareLiteralBaseline(literal.counts, frozen);
	for (const g of verdict.grown)
		errors.push(
			`${g}. A timer or sleep delay is a key of _shared/modules/timings/constants.toml, ` +
				'read through Timings; a number typed at the call is typed again elsewhere and drifts.'
		);
	for (const sh of verdict.shrunk)
		errors.push(
			`${sh}. Run node tools/test/test-fast-timer-inventory.cjs --update-timer-baseline to ` +
				'record the improvement.'
		);
	for (const f of literalSelfTest()) errors.push(`literal-delay self-test: ${f}`);
}

for (const [key, site] of found) {
	if (!INVENTORY[key]) {
		errors.push(
			`${site.rel}:${site.line}: a REPEATING ${site.ms} ms timer that is not in the inventory.\n` +
				`      Add "${key}" to INVENTORY with what it polls and why it must be that fast. ` +
				'A repeating timer costs CPU forever whether or not anything happens, and that cost ' +
				'is invisible in every profile that measures a keystroke.'
		);
	}
}

for (const key of Object.keys(INVENTORY)) {
	if (!found.has(key)) {
		errors.push(
			`INVENTORY lists "${key}", but no repeating sub-second SetTimer for it exists any more. ` +
				'Delete the entry — a justification for a poller that is gone will silently bless the next one.'
		);
	}
}

// A configured brightness worker is a required suspend owner. Its fast poll is
// bounded by the canonical shared policy, including while retirement is pending.
const brightnessFiles = {
	adapter: 'adapters/screen_brightness.ahk',
	registry: 'infra/lifecycle_transition.ahk',
	lifecycle: 'infra/lifecycle.ahk',
	meta: 'tests/meta/suite/test_fast_timer_inventory.ahk'
};
const brightnessSources = Object.fromEntries(
	Object.entries(brightnessFiles).map(([key, rel]) => [
		key,
		fs.readFileSync(path.join(DRIVER, rel), 'utf8')
	])
);
const brightnessPolicy = JSON.parse(
	fs.readFileSync(
		path.join(DRIVER, '..', '_shared', 'modules', 'actions', 'brightness.json'),
		'utf8'
	)
);
function brightnessInventoryErrors(sources, policy) {
	const faults = [];
	const suspend = sources.registry.match(/"suspend",\s*\[([\s\S]*?)\]/)?.[1] || '';
	if ((suspend.match(/"screen-brightness"/g) || []).length !== 1)
		faults.push('screen-brightness must be registered exactly once as a required suspend owner');
	if (
		!/_LifecycleRunRequiredStep\(Transition,\s*"screen-brightness",\s*\(\) => ScreenBrightnessCancel\("suspended"\),\s*true\)/.test(
			sources.lifecycle
		)
	)
		faults.push('screen-brightness suspend must require actual native retirement acknowledgement');
	const timerArgs = [
		...sources.adapter.matchAll(/SetTimer\(ScreenBrightnessPoll,\s*([^\r\n]+)\)/g)
	].map((match) => match[1]);
	const arms = timerArgs.filter((expression) => expression !== '0');
	if (
		arms.length !== 2 ||
		arms.some((expression) => expression !== 'ScreenBrightnessData()["worker_poll_ms"]')
	)
		faults.push(
			'both brightness worker and retirement-debt poll arms must read the canonical shared period'
		);
	if (
		!sources.adapter.includes(
			'Data := JsonParse(FileRead(_SharedDir . "\\modules\\actions\\brightness.json", "UTF-8"))'
		)
	)
		faults.push('brightness period getter must load the actual canonical policy');
	if (!Number.isInteger(policy.worker_poll_ms) || policy.worker_poll_ms !== 50)
		faults.push('reviewed brightness fast-poll period changed from 50 ms');
	if (!/"ScreenBrightnessPoll",\s*"50"/.test(sources.meta))
		faults.push('native fast-timer inventory must explicitly review the 50 ms brightness poll');
	if (
		!sources.meta.includes(`if Expr == 'ScreenBrightnessData()["worker_poll_ms"]'`) ||
		!sources.meta.includes('Period := Policy.Get("worker_poll_ms", 0)') ||
		!sources.meta.includes('!(Period is Integer) || Period <= 0')
	)
		faults.push(
			'native fast-timer resolver must read and validate the canonical brightness period'
		);
	return faults;
}
errors.push(...brightnessInventoryErrors(brightnessSources, brightnessPolicy));
const brightnessMutations = [
	[
		'missing owner',
		{
			...brightnessSources,
			registry: brightnessSources.registry.replace('"screen-brightness", ', '')
		},
		brightnessPolicy
	],
	[
		'missing acknowledgement',
		{
			...brightnessSources,
			lifecycle: brightnessSources.lifecycle.replace(
				'ScreenBrightnessCancel("suspended"), true)',
				'ScreenBrightnessCancel("suspended"))'
			)
		},
		brightnessPolicy
	],
	[
		'unknown runtime period',
		{
			...brightnessSources,
			adapter: brightnessSources.adapter.replaceAll(
				'ScreenBrightnessData()["worker_poll_ms"]',
				'Data["worker_poll_ms"]'
			)
		},
		brightnessPolicy
	],
	[
		'missing native inventory',
		{
			...brightnessSources,
			meta: brightnessSources.meta.replace(
				'"ScreenBrightnessPoll",          "50",',
				'"ForeignBrightnessPoll",         "50",'
			)
		},
		brightnessPolicy
	],
	['shortened period', brightnessSources, { ...brightnessPolicy, worker_poll_ms: 25 }],
	['unreadable policy', brightnessSources, { ...brightnessPolicy, worker_poll_ms: '50' }],
	[
		'unknown policy origin',
		{
			...brightnessSources,
			adapter: brightnessSources.adapter.replace(
				'\\modules\\actions\\brightness.json',
				'\\modules\\actions\\foreign.json'
			)
		},
		brightnessPolicy
	]
];
for (const [name, sources, policy] of brightnessMutations) {
	if (brightnessInventoryErrors(sources, policy).length === 0)
		errors.push(`brightness timer/lifecycle negative mutation was not rejected: ${name}`);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Fast repeating-timer inventory is out of date:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

const list = [...found.entries()]
	.sort((a, b) => a[1].ms - b[1].ms)
	.map(([k, v]) => `${v.ms}ms ${k.split(':')[1]}`)
	.join(', ');
console.log(
	`\x1b[32m[OK] ${found.size} repeating sub-second timer(s), all inventoried (${list}) — ` +
		`${scanned} file(s) scanned; ${Object.values(literal.counts).reduce((a, b) => a + b, 0)} literal delay(s) frozen in ${Object.keys(literal.counts).length} file(s).\x1b[0m`
);
