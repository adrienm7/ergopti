// tools/test/test-platform-reason-wording.cjs

/**
 * ==============================================================================
 * MODULE: Platform Reasons State A Fact, Not A Schedule
 * DESCRIPTION:
 * A platform_reason text explains why a platform differs, and it has to stay true
 * if everything else were finished (see test-platform-restrictions-explained.cjs).
 * A text that says "for now", "yet" or "not implemented" is a promise to do the
 * work, written into 21 languages, and it goes stale the day the work is done.
 * This gate refuses such wording in the English catalogue. The two texts that
 * still carry it are frozen below until their rewrite; the ledger only shrinks.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const CATALOGUE = path.join(ROOT, 'static/ergopti_plus/_shared/data/locales/en.json');

// Wording that schedules work instead of describing the platform.
const SCHEDULED =
	/\b(for now|yet|not (coded|implemented|built|supported)|todo|planned|later|temporar\w*|soon|currently|at the moment)\b/i;

// Texts still to rewrite (cross-OS parity audit, stale reason texts).
const KNOWN_SCHEDULED = new Set([
	'platform_reason.shortcuts_restore_is_composed_on_macos',
	'platform_reason.token_streaming_unvalidated_on_windows'
]);

const english = JSON.parse(fs.readFileSync(CATALOGUE, 'utf8'));
const errors = [];
for (const [key, text] of Object.entries(english)) {
	if (!key.startsWith('platform_reason.')) continue;
	if (SCHEDULED.test(text) && !KNOWN_SCHEDULED.has(key))
		errors.push(
			`${key} schedules work ("${text.match(SCHEDULED)[0]}"); state what the platform does instead`
		);
}
for (const key of KNOWN_SCHEDULED) {
	if (!(key in english)) errors.push(`${key} no longer exists: remove it from the ledger`);
	else if (!SCHEDULED.test(english[key]))
		errors.push(`${key} was rewritten: remove it from the ledger`);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] platform reason wording:\x1b[0m');
	for (const error of errors) console.error('  - ' + error);
	process.exit(1);
}
console.log(
	'\x1b[32m[OK] platform reasons describe the platform; 2 texts remain to rewrite.\x1b[0m'
);
