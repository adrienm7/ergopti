// tools/test/test-hotstring-editor-confirm-wiring.cjs

/**
 * ==============================================================================
 * MODULE: Hotstring Editor — Confirm Dialog Wiring Regression Guard
 * DESCRIPTION:
 * Encodes the root cause of a delete-does-nothing bug in the shared hotstring
 * editor frontend. `showConfirm()` stores the pending action in `_confirmCb`,
 * but the confirm dialog's OK/Cancel buttons carry no inline `onclick` (unlike
 * the add/edit modals, whose Save buttons are wired in the HTML). For a while
 * `_confirmCb` was therefore set but NEVER invoked: clicking a delete button
 * opened the confirmation modal, and clicking OK silently did nothing — every
 * delete-entry, delete-section, and bulk-delete path was dead.
 *
 * FEATURES & RATIONALE:
 * 1. Asserts the confirm-ok button gets a click listener in JS (the buttons are
 *    not wired via inline onclick like the other modals, so the listener is the
 *    only thing keeping the OK path alive).
 * 2. Asserts the stored callback is actually FIRED — a captured local is invoked
 *    — not merely assigned and cleared. This is the exact regression: before the
 *    fix, `_confirmCb` was only ever set (showConfirm) and nulled (Escape).
 * 3. Asserts the confirm-cancel button is wired to dismiss without firing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const PASS_SYMBOL = '✓';
const FAIL_SYMBOL = '✗';

const REPO_ROOT = path.resolve(__dirname, '../..');
const SCRIPT = 'static/ergopti_plus/_shared/ui/hotstring_editor/script.js';

let total_pass = 0;
let total_fail = 0;

function check(label, pattern) {
	const filePath = path.join(REPO_ROOT, SCRIPT);
	try {
		const content = fs.readFileSync(filePath, 'utf8');
		if (pattern.test(content)) {
			total_pass++;
			console.log(`  ${PASS_SYMBOL}  ${label}`);
		} else {
			total_fail++;
			console.log(`  ${FAIL_SYMBOL}  ${label}`);
			console.log(`       Violation: pattern not found in ${SCRIPT}`);
		}
	} catch (err) {
		total_fail++;
		console.log(`  ${FAIL_SYMBOL}  ${label}`);
		console.log(`       Error: ${err.message}`);
	}
}

console.log('\n=== Hotstring Editor Confirm Dialog Wiring ===');

// The OK button must receive a click listener in JS — it has no inline onclick.
check(
	'confirm-ok button has a click listener',
	/getElementById\(\s*['"]confirm-ok['"]\s*\)\.addEventListener\(\s*['"]click['"]/
);

// The pending callback must be captured into a local and INVOKED, not just set
// and nulled. This is the heart of the regression — a delete that never runs.
check(
	'pending confirm callback is captured and fired',
	/const\s+cb\s*=\s*_confirmCb[\s\S]{0,240}?\bcb\(\)/
);

// Cancel must dismiss the dialog without firing the pending action.
check(
	'confirm-cancel button has a click listener',
	/getElementById\(\s*['"]confirm-cancel['"]\s*\)\.addEventListener\(\s*['"]click['"]/
);

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed.`);

if (total_fail > 0) {
	process.exit(1);
}
