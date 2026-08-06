/**
 * ==============================================================================
 * MODULE: Preview-Masking Cross-Driver Ratchet
 * DESCRIPTION:
 * Measures how many drivers actually render the preview bubble from the shared
 * masking corpus, and refuses to let that number fall.
 *
 * WHY A RATCHET AND NOT A PASS/FAIL:
 * The decision — IBAN, BIC, card number and SSN partially hidden in the bubble,
 * phone number in clear, identical on all three drivers — is implemented on
 * Linux and on neither of the other two. Failing outright would leave CI red for
 * work that is not a bug being fixed but a feature being carried across two more
 * drivers, one of which (Windows) is AutoHotkey and cannot require the shared
 * Lua at all.
 *
 * So the gap is recorded as a number instead of being described in prose. A
 * driver that starts consuming the corpus lowers it and the baseline must be
 * lowered with it; a driver that stops raises it and this fails. What it forbids
 * is the thing prose cannot: quietly staying where it is while everyone believes
 * otherwise, or regressing after the work is done.
 *
 * ROOT CAUSE ENCODED:
 * The bubble exists so a user can confirm WHICH of their values is about to be
 * typed. A reveal on one platform and a blank on another are not the same check,
 * and "identical on all three" is a claim about output that only a shared corpus
 * can measure — three implementations in two languages will not converge on
 * intent alone.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const CORPUS_REL = 'modules/personal_info/preview_vectors.toml';
const CORPUS = path.join(SHARED, CORPUS_REL.split('/').join(path.sep));

// The corpus filename as a test would name it. A driver "consumes the corpus"
// when one of its test files reads this by name — not when it merely masks
// something, because masking to its own expectations is exactly the divergence
// the corpus exists to catch.
const CORPUS_MARKER = 'preview_vectors.toml';

const DRIVERS = [
	{ label: 'linux', testsRel: 'static/ergopti_plus/linux/tests', exts: ['.lua'] },
	{ label: 'macos', testsRel: 'static/ergopti_plus/macos/tests', exts: ['.lua'] },
	{ label: 'windows', testsRel: 'static/ergopti_plus/windows/tests', exts: ['.ahk'] }
];

// Drivers that do NOT yet render the bubble from the corpus. Lower this — and
// the list — as each one lands. It must never grow.
//
// macOS and Windows both need the same thing first, and it is not a call to a
// mask function: their preview candidates carry no personal_info field name, so
// there is nothing to ask the declaration about. Linux threads that provenance
// through, which is why it could be wired up at all.
const NOT_YET_WIRED = ['macos', 'windows'];

const errors = [];
const notes = [];

/** Recursively collects files with the given extensions. */
function walk(dir, exts, out = []) {
	if (!fs.existsSync(dir)) return out;
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) walk(full, exts, out);
		else if (exts.some((e) => entry.name.endsWith(e))) out.push(full);
	}
	return out;
}

// ─── 1. The corpus itself must be present and non-trivial ────────────────────
//
// Every check below is relative to this file. If it were missing or empty the
// whole gate would report a tidy green over nothing at all.
if (!fs.existsSync(CORPUS)) {
	errors.push(`the shared corpus is missing: _shared/${CORPUS_REL}`);
} else {
	const body = fs.readFileSync(CORPUS, 'utf8');
	const vectorCount = (body.match(/^\[\[vectors\]\]/gm) || []).length;
	if (vectorCount < 15) {
		errors.push(
			`_shared/${CORPUS_REL} declares ${vectorCount} vector(s) — it carried 16 when this ` +
			'guard was written, and a shrinking corpus is coverage being removed rather than a driver being fixed.'
		);
	}
	// Both arms have to be represented or the corpus proves half the decision.
	// A wrong port is most likely to over-mask, which only the public fields catch.
	const bulletRows = (body.match(/preview = "[^"]*•/g) || []).length;
	if (bulletRows < 6) {
		errors.push(`_shared/${CORPUS_REL} has ${bulletRows} masked vector(s) — expected at least 6.`);
	}
	notes.push(`corpus: ${vectorCount} vector(s), ${bulletRows} of them masked`);
}

// ─── 2. Which drivers actually read it ───────────────────────────────────────
const wired = [];
const unwired = [];

for (const driver of DRIVERS) {
	const dir = path.join(ROOT, driver.testsRel.split('/').join(path.sep));
	const files = walk(dir, driver.exts);
	if (files.length === 0) {
		errors.push(`${driver.label}: found no test files under ${driver.testsRel} — this scan is broken, not the tree.`);
		continue;
	}
	const consumer = files.find((f) => fs.readFileSync(f, 'utf8').includes(CORPUS_MARKER));
	if (consumer) {
		wired.push(driver.label);
		notes.push(`${driver.label}: ${path.relative(ROOT, consumer).split(path.sep).join('/')}`);
	} else {
		unwired.push(driver.label);
	}
}

// ─── 3. The ratchet ──────────────────────────────────────────────────────────
for (const label of unwired) {
	if (!NOT_YET_WIRED.includes(label)) {
		errors.push(
			`${label} no longer renders the preview bubble from _shared/${CORPUS_REL}. ` +
			'It did when this guard was written, so this is a regression: the three ' +
			'drivers can now show a user different things for the same value.'
		);
	}
}
for (const label of NOT_YET_WIRED) {
	if (wired.includes(label)) {
		errors.push(
			`${label} now consumes _shared/${CORPUS_REL} — remove it from NOT_YET_WIRED. ` +
			'A baseline that outlives the gap it recorded starts excusing the next one.'
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] preview-masking cross-driver:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${wired.length}/${DRIVERS.length} driver(s) render the preview bubble from the shared corpus ` +
	`(${wired.join(', ')}); ${unwired.length} still to carry it across (${unwired.join(', ') || 'none'}).\x1b[0m`
);
for (const n of notes) console.log('     ' + n);
