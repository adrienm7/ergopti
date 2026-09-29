// tools/test/test-diagnostics-redaction-vectors.cjs

/**
 * ==============================================================================
 * MODULE: Diagnostics Redaction Vectors (JS)
 * DESCRIPTION:
 * Replays _shared/tests/corpus/diagnostics/redaction_vectors.json through the
 * page-side redactor _shared/ui/redact.js, with the rules of
 * _shared/modules/diagnostics/redaction.json. The diagnostics page builds the
 * text that leaves the machine (clipboard, saved report, GitHub issue) and the
 * preview of it, so the page must remove exactly what the Lua and AHK ports
 * remove: the three replay the same file, byte for byte.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');

// The redactor is a page script (it defines window.ErgoptiRedact), so it runs in
// a sandbox exactly as the page loads it
const Redact = (() => {
	const file = path.join(SHARED, 'ui', 'redact.js');
	const sandbox = { window: {} };
	vm.runInNewContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
	if (!sandbox.window.ErgoptiRedact)
		throw new Error('redact.js did not define window.ErgoptiRedact');
	return sandbox.window.ErgoptiRedact;
})();
const rules = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'modules', 'diagnostics', 'redaction.json'), 'utf8')
);
const corpus = JSON.parse(
	fs.readFileSync(
		path.join(SHARED, 'tests', 'corpus', 'diagnostics', 'redaction_vectors.json'),
		'utf8'
	)
);

const failures = [];

// Floor: a corpus that parsed to nothing would pass the loop below
if (!Array.isArray(corpus.vectors) || corpus.vectors.length < 10) {
	failures.push('the corpus holds fewer than 10 redaction vectors');
}

for (const vector of corpus.vectors || []) {
	let got;
	try {
		got = Redact.apply(vector.input, rules, vector.context);
	} catch (caught) {
		failures.push(`${vector.id}: threw ${caught.message}`);
		continue;
	}
	if (got !== vector.expected) {
		failures.push(
			`${vector.id}:\n      got      ${JSON.stringify(got)}\n      expected ${JSON.stringify(vector.expected)}`
		);
	}
}

// JavaScript-only hazards the JSON corpus cannot pin for the other ports.
// toLowerCase() folds beyond ASCII and changes the length of some strings
// ("İ" becomes two code units): a fold of the whole text would shift every
// index after it and cut the wrong characters out.
const shifted = Redact.apply('İ /Users/jdoe/x', rules, {
	home: '/Users/jdoe',
	user: 'jdoe',
	case_insensitive: true
});
if (shifted !== 'İ ~/x')
	failures.push(
		`a non-ASCII capital before the home shifted the match: ${JSON.stringify(shifted)}`
	);
// \s in a JavaScript class also matches a no-break space; Lua's %s does not,
// so a key=value secret must run through it as the Lua port does.
const nbsp = Redact.apply('token=abc defghi', rules, {});
if (nbsp !== 'token=<secret>')
	failures.push(`a no-break space ended a secret early: ${JSON.stringify(nbsp)}`);
// A missing rules document is a programming error, never a silent pass-through
let threw = false;
try {
	Redact.apply('text', null, {});
} catch (caught) {
	threw = true;
}
if (!threw)
	failures.push('apply() without rules must throw instead of returning the text unredacted');

if (failures.length > 0) {
	console.error(`[FAIL] diagnostics redaction vectors (JS): ${failures.length} failure(s)`);
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}
console.log(
	`[OK] diagnostics redaction vectors (JS): ${corpus.vectors.length} vector(s) match the Lua and AHK ports.`
);
