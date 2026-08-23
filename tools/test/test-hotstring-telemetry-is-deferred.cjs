// tools/test/test-hotstring-telemetry-is-deferred.cjs

/**
 * ==============================================================================
 * MODULE: Hotstring Telemetry Must Not Run On The Keystroke Tap
 * DESCRIPTION:
 * `keylogger.log_hotstring_suggested` / `_dismissed` / `_accepted` perform a
 * file open, write and flush. Called straight from the keymap hot path they run
 * inside the keyDown eventtap — on every tooltip shown and every dismissal —
 * which is the thread that has to return before the user's keystroke reaches the
 * application.
 *
 * WHY A GATE AND NOT JUST THE FIX:
 * both call sites in modules/keymap/ now enter schedule_prediction_deferred,
 * whose callback is dispatched by TimerScheduler.after(0, ...). The helper owns
 * the exact timer until settlement, but a new call site could still bypass that
 * boundary and run synchronously. Nothing else would say so: the suite would
 * stay green, the telemetry would still be written, and the only symptom would
 * be a slower keystroke.
 *
 * WHY NOT MOVE IT TO THE SINK:
 * deferring inside the keylogger would change the contract for every caller,
 * including the ones that legitimately expect the write to have happened when
 * they return. That is a bigger change than the risk warrants; requiring the
 * deferral at the boundary keeps the sink honest for its other callers.
 *
 * THE FLOOR IS LOAD-BEARING: a scan that finds zero calls would pass forever. If
 * the calls move out of modules/keymap/, this gate is measuring nothing and says
 * so rather than going quietly green.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const HOT_PATH = path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'modules', 'keymap');
const DEFER_HELPER = 'schedule_prediction_deferred';

const CENTRAL_DEFERRAL = new RegExp(
	`local\\s+function\\s+${DEFER_HELPER}\\s*\\([^)]*\\)` +
		'[\\s\\S]{0,600}?TimerScheduler\\.after\\s*\\(\\s*0\\s*,\\s*function\\s*\\(\\s*\\)' +
		'[\\s\\S]{0,250}?\\bcallback\\s*\\(\\s*\\)'
);

// Measured when this landed: two calls, both in llm_bridge.lua. Set below that so
// a third one does not trip it, far enough above zero that a broken scan fails.
const MIN_CALLS = 2;

const errors = [];
let found = 0;
let helperDefinitions = 0;
let centralDeferrals = 0;

/** Every production Lua file on the keymap hot path. */
function hotPathFiles(dir) {
	const out = [];
	if (!fs.existsSync(dir)) return out;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) out.push(...hotPathFiles(p));
		else if (e.name.endsWith('.lua')) out.push(p);
	}
	return out;
}

const files = hotPathFiles(HOT_PATH);
if (files.length === 0) {
	errors.push(`no Lua file under ${path.relative(ROOT, HOT_PATH)} — the scan is broken`);
}

for (const file of files) {
	const src = fs.readFileSync(file, 'utf8');
	const lines = src.split('\n').map((line) => {
		if (line.trimStart().startsWith('--')) return '';
		return line.replace(/--.*$/, '');
	});
	const code = lines.join('\n');
	helperDefinitions += (code.match(new RegExp(`local\\s+function\\s+${DEFER_HELPER}\\s*\\(`, 'g')) || [])
		.length;
	if (CENTRAL_DEFERRAL.test(code)) centralDeferrals += 1;

	lines.forEach((line, i) => {
		if (!/keylogger\.log_hotstring_(suggested|dismissed|accepted)/.test(line)) return;
		found += 1;

		// The telemetry call must be the direct payload of the central deferral.
		// Checking both sides prevents a nearby, already-closed helper call from
		// satisfying the oracle merely because it appears in the look-behind.
		const before = lines.slice(Math.max(0, i - 6), i).join('\n');
		const helperOffset = before.lastIndexOf(DEFER_HELPER);
		const helperOpen = helperOffset >= 0 ? before.slice(helperOffset) : '';
		const after = lines.slice(i + 1, i + 3).join('\n');
		const opensDeferredCallback = new RegExp(
			`^${DEFER_HELPER}\\s*\\(\\s*[^,\\n]+,\\s*function\\s*\\(\\s*\\)`
		).test(helperOpen);
		const closesDeferredCallback = /^\s*end\s*\)/m.test(after);
		if (!opensDeferredCallback || /\bend\s*\)/.test(helperOpen) || !closesDeferredCallback) {
			errors.push(
				`${path.relative(ROOT, file)}:${i + 1} calls hotstring telemetry without a ` +
					`${DEFER_HELPER} callback around it. That is an open/write/flush inside the ` +
					'keyDown eventtap, on the thread the keystroke is waiting on.'
			);
		}
	});
}

if (helperDefinitions !== 1) {
	errors.push(
		`found ${helperDefinitions} ${DEFER_HELPER} definition(s) on the keymap hot path; ` +
			'the telemetry boundary must have one unambiguous owner.'
	);
}

if (centralDeferrals !== 1) {
	errors.push(
		`${DEFER_HELPER} must deliver callbacks through TimerScheduler.after(0, ...); ` +
			'otherwise call-site delegation does not move the file write off the keyDown eventtap.'
	);
}

if (found < MIN_CALLS) {
	errors.push(
		`found only ${found} hotstring-telemetry call(s) on the keymap hot path, below the ` +
			`recorded ${MIN_CALLS}. Either they moved — in which case re-point this gate — or the ` +
			'scan broke, and a scan that matches nothing passes forever.'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] hotstring telemetry on the keystroke tap:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] hotstring telemetry is deferred — ${found} call(s) on the keymap hot path, ` +
		`every one owned by ${DEFER_HELPER} and TimerScheduler.after(0, ...).\x1b[0m`
);
