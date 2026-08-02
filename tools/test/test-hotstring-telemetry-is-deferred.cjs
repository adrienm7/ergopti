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
 * both call sites in modules/keymap/ defer today, and that is exactly the
 * problem this guards. The deferral was applied PER CALL SITE rather than at the
 * sink, and it has already been forgotten once: llm_bridge.lua carries a comment
 * saying "That one was moved off the HID thread and this one was not, because
 * the deferral was applied per call site instead of at the sink". A third call
 * site would be synchronous again and nothing would say so — the suite would
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

// Measured when this landed: two calls, both in llm_bridge.lua. Set below that so
// a third one does not trip it, far enough above zero that a broken scan fails.
const MIN_CALLS = 2;

const errors = [];
let found = 0;

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
	const lines = src.split('\n');
	lines.forEach((line, i) => {
		if (!/keylogger\.log_hotstring_(suggested|dismissed|accepted)/.test(line)) return;
		if (line.trim().startsWith('--')) return; // a comment about the call, not the call
		found += 1;

		// The call must sit inside a deferral opened in the preceding few lines.
		// Looking back rather than at the line itself, because the scheduler call
		// and the logging call are on separate lines by construction.
		const window = lines.slice(Math.max(0, i - 4), i).join('\n');
		if (!/TimerScheduler\.after\s*\(\s*0\s*,/.test(window)) {
			errors.push(
				`${path.relative(ROOT, file)}:${i + 1} calls hotstring telemetry without a ` +
					'TimerScheduler.after(0, …) around it. That is an open/write/flush inside the ' +
					'keyDown eventtap, on the thread the keystroke is waiting on. The other call ' +
					'sites in this file defer; this one would be the third time the deferral was ' +
					'applied per call site and missed one.'
			);
		}
	});
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
		`every one behind TimerScheduler.after(0, …).\x1b[0m`
);
