// tools/test/test-corpus-fields-are-read.cjs

/**
 * ==============================================================================
 * MODULE: Corpus Field Reader Guard
 * DESCRIPTION:
 * Every field a cross-driver corpus vector carries must be read by at least one
 * driver replay, or be documented in that corpus's `field_semantics` as
 * descriptive.
 *
 * ROOT CAUSE ENCODED:
 * A corpus field that nothing reads is the same defect this repo already gates
 * for the menu manifest — a declaration that looks load-bearing while nothing
 * consumes it — and it is worse here, because a corpus is the CROSS-DRIVER
 * contract: a field in it implies all three drivers agree about that value.
 * Someone editing a vector to steer a scenario watches nothing happen.
 * Measured across 16 corpora and 74 fields, exactly one was inert: `notes` in
 * `toml/coercion_vectors.json`, a human label carried by every vector while the
 * behaviour lives in `input`/`lua`/`ahk`.
 *
 * WHAT THIS GUARD'S OWN DEVELOPMENT PROVES, AND WHY THE SCAN IS WIDE:
 * A first version scoped the consumer scan to files named `*corpus*` and
 * reported **eleven** inert fields. Every one was a false positive:
 * `test_process_prediction_vectors.lua` and `test_tooltip_dequeue_contract.lua`
 * are consumers whose names say nothing about a corpus. Widening to all driver
 * tests left three; adding `tools/` cleared `expected_ids`, which
 * `test-metrics-category-ids.cjs` asserts on. The last survivor looked like a
 * genuine find — `terminator`, carried by all 24 hotstring vectors — and it is
 * NOT inert either: all three **e2e** runners inject it as a real keystroke.
 * A narrow reader scan does not under-report, it over-reports, and each false
 * positive invites deleting a field that something depends on. Hence: every
 * `.lua`, `.ahk`, `.cjs` and `.js` under the three suites and `tools/`.
 *
 * WHY "DOCUMENTED" IS A VALID ANSWER:
 * `field_semantics` already existed for this — `backspace_count` is documented
 * there because its name reads as physical when the value is logical. The rule
 * is not "every field must be executed", it is "no field may be silently inert".
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const CORPUS_DIR = path.join(SP, '_shared', 'tests', 'corpus');

// Structural keys that describe the corpus rather than a vector.
const CORPUS_META = new Set(['$schema', 'description', 'version', 'field_semantics']);

// Fields every corpus carries for humans and tooling alike.
const UNIVERSAL = new Set(['id', 'description']);

// Floors — a scan that finds nothing must not pass for free.
const MIN_CORPORA = 3;
const MIN_READERS = 3;

const errors = [];

/** Recursively collects every *.json corpus file. */
function corpora(dir, acc = []) {
	if (!fs.existsSync(dir)) return acc;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) corpora(p, acc);
		else if (e.name.endsWith('.json')) acc.push(p);
	}
	return acc;
}

// Every consumer a corpus can have. Driver suites replay most vectors, but some
// are read by a JS gate instead — test-metrics-category-ids.cjs reads
// `expected_ids` — so scoping this to the three drivers reported a field as
// inert while a gate was asserting on it.
const readerFiles = [];
const readerRoots = [
	path.join(SP, 'windows', 'tests'),
	path.join(SP, 'macos', 'tests'),
	path.join(SP, 'linux', 'tests'),
	path.join(ROOT, 'tools')
];
for (const base of readerRoots) {
	if (!fs.existsSync(base)) continue;
	(function walk(dir) {
		for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
			const p = path.join(dir, e.name);
			if (e.isDirectory()) walk(p);
			// EVERY test file, not only those named "*corpus*". A first version
			// scoped to the filename and reported 11 fields as unread — but
			// test_process_prediction_vectors.lua and test_tooltip_dequeue_contract.lua
			// are consumers whose names say nothing about a corpus.
			else if (/\.(lua|ahk|cjs|js)$/.test(e.name)) {
				if (path.resolve(p) === path.resolve(__filename)) continue;
				readerFiles.push({ rel: path.relative(SP, p).split(path.sep).join('/'), src: fs.readFileSync(p, 'utf8') });
			}
		}
	})(base);
}

if (readerFiles.length < MIN_READERS) {
	errors.push(
		`found only ${readerFiles.length} corpus-consuming test file(s) (floor ${MIN_READERS}) — the ` +
			'reader scan is broken, and every field would then look unread'
	);
}

/** True when any replay reads the named field outside a comment. */
function isRead(field) {
	const f = field.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const patterns = [
		new RegExp(`\\.${f}\\b`), // v.terminator
		new RegExp(`\\["${f}"\\]`), // Vec["terminator"]
		new RegExp(`\\['${f}'\\]`),
		new RegExp(`Has\\("${f}"\\)`)
	];
	return readerFiles.some(({ src }) =>
		src.split(/\r?\n/).some((line) => {
			const t = line.trimStart();
			if (t.startsWith('--') || t.startsWith(';') || t.startsWith('//')) return false;
			return patterns.some((p) => p.test(line));
		})
	);
}

let scanned = 0;
let checkedFields = 0;

for (const abs of corpora(CORPUS_DIR)) {
	let data;
	try {
		data = JSON.parse(fs.readFileSync(abs, 'utf8'));
	} catch (e) {
		errors.push(`${path.relative(ROOT, abs)}: invalid JSON — ${e.message}`);
		continue;
	}
	if (!data || typeof data !== 'object') continue;

	// A corpus is any object holding at least one array of vector objects.
	const arrays = Object.entries(data).filter(
		([k, v]) => !CORPUS_META.has(k) && Array.isArray(v) && v.some((x) => x && typeof x === 'object')
	);
	if (arrays.length === 0) continue;
	scanned++;

	const documented = new Set(Object.keys(data.field_semantics || {}));
	const rel = path.relative(SP, abs).split(path.sep).join('/');

	const fields = new Set();
	for (const [, rows] of arrays) {
		for (const row of rows) {
			if (row && typeof row === 'object' && !Array.isArray(row)) {
				for (const k of Object.keys(row)) fields.add(k);
			}
		}
	}

	for (const field of [...fields].sort()) {
		if (UNIVERSAL.has(field)) continue;
		checkedFields++;
		if (documented.has(field)) continue;
		if (isRead(field)) continue;
		errors.push(
			`${rel}: every vector carries "${field}" and no driver replay reads it. It reads as an ` +
				'input, so the next person to edit a vector will change it and see nothing happen. Feed it ' +
				'in a replay, or document it under "field_semantics" as descriptive — a corpus field is the ' +
				'cross-driver contract, so an inert one implies an agreement nobody checks.'
		);
	}
}

if (scanned < MIN_CORPORA) {
	errors.push(`scanned only ${scanned} corpus file(s) (floor ${MIN_CORPORA}) — the walk is broken`);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] corpus fields with no reader:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${checkedFields} field(s) across ${scanned} corpus file(s) are read by a replay ` +
		`or documented (${readerFiles.length} consumer(s) scanned).\x1b[0m`
);
