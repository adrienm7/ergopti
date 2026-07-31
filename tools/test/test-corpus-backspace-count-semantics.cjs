// tools/test/test-corpus-backspace-count-semantics.cjs

/**
 * ==============================================================================
 * MODULE: Hotstring Corpus — backspace_count Semantics Guard
 * DESCRIPTION:
 * `backspace_count` in the shared hotstring corpus is a LOGICAL count: how many
 * codepoints of already-typed text the expansion replaces. It is NOT the number
 * of backspace keystrokes a driver physically emits.
 *
 * WHY THIS DISTINCTION NEEDS A GATE AND NOT JUST A COMMENT:
 * The two readings give different numbers on macOS, whose expander keeps the
 * longest common prefix between trigger and replacement instead of erasing the
 * whole trigger. For `btw → by the way` they share "b", so macOS emits 2
 * backspaces and types "y the way", where Windows and Linux emit 3 and type the
 * full replacement. Measured across the corpus: 6 of the 13 matched vectors
 * have a physical macOS count BELOW the logical one.
 *
 * Nothing said so anywhere. The corpus called the field "backspace_count", the
 * macOS e2e harness quietly reconstructs the logical count from the screen
 * (its `backspaces()` searches for the replacement to recover where the trigger
 * began, precisely so the prefix optimisation does not change the answer), and
 * the three per-driver corpus tests only check the corpus against its own
 * formula. So a reader comparing the field name against the macOS expander
 * concludes the corpus is broken — the project's own backlog carried exactly
 * that conclusion, along with a "correct" macOS number (1) that is neither the
 * logical count (3) nor the physical one (2).
 *
 * The failure this prevents is the plausible one: someone "simplifies" the e2e
 * harness to count emitted backspaces, macOS goes red against a corpus that is
 * right, and the corpus gets "fixed" to match one driver's optimisation —
 * quietly making it unable to accept the other two.
 *
 * WHAT IS ASSERTED:
 * 1. The logical formula holds for every matched vector, in one place rather
 *    than three near-identical per-driver copies.
 * 2. The physical macOS count really does differ, for the vectors where it
 *    should — so the distinction is executable, not prose that can rot.
 * 3. The corpus documents the field, so the next reader does not have to
 *    rediscover this.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const CORPUS = path.join(
	ROOT,
	'static/ergopti_plus/_shared/tests/corpus/hotstrings/vectors.json'
);

const errors = [];
const corpus = JSON.parse(fs.readFileSync(CORPUS, 'utf8'));

/** Codepoints, not bytes and not UTF-16 units. */
const cp = (s) => Array.from(s);

/** Length of the longest shared leading codepoint run. */
function common_prefix(a, b) {
	const A = cp(a);
	const B = cp(b);
	let n = 0;
	while (n < A.length && n < B.length && A[n] === B[n]) n++;
	return n;
}

const matched = (corpus.vectors || []).filter(
	(v) => v.expected && v.expected.matched === true && v.expected.backspace_count !== undefined
);

if (matched.length < 10) {
	errors.push(
		`only ${matched.length} matched vector(s) carry a backspace_count — the corpus shape changed ` +
			'and this guard is no longer measuring anything'
	);
}

// ── 1. The logical formula, for every vector ────────────────────────────────

let physical_differs = 0;
for (const v of matched) {
	const tlen = cp(v.trigger).length;
	const bonus = v.terminator_consumed === true ? 1 : 0;
	const logical = tlen + bonus;

	if (v.expected.backspace_count !== logical) {
		errors.push(
			`${v.id}: backspace_count is ${v.expected.backspace_count}, but the logical count is ` +
				`${logical} (${tlen} trigger codepoint(s)${bonus ? ' + 1 consumed terminator' : ''}). ` +
				'This field counts the codepoints REPLACED, never the keystrokes a driver emits.'
		);
	}

	// The macOS physical count for the terminator path: trigger length minus the
	// prefix it keeps on screen.
	const physical_macos = tlen - common_prefix(v.trigger, v.expected.replacement || '') + bonus;
	if (physical_macos !== logical) physical_differs++;
}

// ── 2. The distinction must be real, not theoretical ────────────────────────

if (physical_differs === 0) {
	errors.push(
		'no vector distinguishes the logical count from the macOS physical count — every trigger and ' +
			'replacement in the corpus now shares no common prefix, so this guard proves nothing and ' +
			'a driver could satisfy the corpus by emitting either number. Add a vector whose trigger ' +
			'and replacement share a leading character (e.g. btw → by the way).'
	);
}

// ── 3. The corpus must say what the field means ─────────────────────────────
//
// The measurement above is what makes the claim true; this is what stops the
// next person having to redo it.
const doc = JSON.stringify(corpus.field_semantics || {});
if (!/logical/i.test(doc) || !/backspace_count/.test(JSON.stringify(Object.keys(corpus.field_semantics || {})))) {
	errors.push(
		'the corpus has no field_semantics.backspace_count entry explaining that the count is logical ' +
			'(codepoints replaced) rather than physical (keystrokes emitted). The field name alone reads ' +
			'as physical, which is how it came to be misread as a macOS conformance bug.'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] hotstring corpus backspace_count semantics:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] backspace_count is the logical replaced-codepoint count for all ${matched.length} ` +
		`matched vector(s); ${physical_differs} of them would give a different answer if it were ` +
		'read as emitted keystrokes.\x1b[0m'
);
