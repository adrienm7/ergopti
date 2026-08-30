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
	'modules/keymap/layout.ahk:_UIA_SelectionPollTimer':
		'Polls the UIA selection so a layout remap knows whether text is selected. 500 ms, and ' +
		'armed only in the apps that need it — the AX call is the expensive part, which is why ' +
		'this is a poll rather than an event subscription.',
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

const errors = [];

if (scanned < 100) {
	errors.push(`walked only ${scanned} .ahk file(s) — the scan is broken, and an empty inventory proves nothing`);
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
		`${scanned} file(s) scanned.\x1b[0m`
);
