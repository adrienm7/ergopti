// tools/test/test-wrap-pair-vectors-shared.cjs

/**
 * ==============================================================================
 * MODULE: Shared Wrap-Pair Corpus Gate
 * DESCRIPTION:
 * Checks the corpus of the wrap_selection parameter,
 * _shared/tests/corpus/action_parameters/wrap_pair_vectors.json, against the
 * built-in catalogue _shared/modules/wrap_symbols/wrap_symbols.json with a
 * reference implementation of its documented rule, and checks that each driver
 * suite replays it.
 *
 * WHY:
 * The wrap_pair rule is implemented three times (_shared/lua/wrap_pair for
 * macOS and Linux, windows/infra/wrap_pair.ahk). The corpus is what keeps them
 * equal; a corpus whose expectations disagree with the catalogue, or that no
 * suite replays, pins nothing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const CORPUS = path.join(SP, '_shared', 'tests', 'corpus', 'action_parameters', 'wrap_pair_vectors.json');
const CATALOGUE = path.join(SP, '_shared', 'modules', 'wrap_symbols', 'wrap_symbols.json');

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

// Lua's %s and the AHK driver's trim set: space, tab, CR, LF, VT, FF.
const trim = (text) => text.replace(/^[ \t\r\n\v\f]+|[ \t\r\n\v\f]+$/g, '');

/**
 * The documented rule, as a reference.
 * @param {string} value
 * @param {{left: string, right: string}[]} pairs Catalogue order.
 * @returns {{left: string, right: string}|null}
 */
function referenceParse(value, pairs) {
	const wanted = trim(value);
	if (wanted === '' || /[\r\n]/.test(wanted)) return null;
	for (const field of ['left', 'right']) {
		const hit = pairs.find((pair) => trim(pair[field]) === wanted);
		if (hit) return { left: hit.left, right: hit.right };
	}
	const parts = wanted.split('|');
	if (parts.length !== 2 || trim(parts[0]) === '' || trim(parts[1]) === '') return null;
	return { left: parts[0], right: parts[1] };
}

const catalogue = JSON.parse(fs.readFileSync(CATALOGUE, 'utf8'));
const pairs = catalogue.groups.flatMap((group) => group.pairs);
check(pairs.length >= 30, `the catalogue holds only ${pairs.length} pair(s)`);

const corpus = JSON.parse(fs.readFileSync(CORPUS, 'utf8'));
check(typeof corpus.rule === 'string' && corpus.rule.length > 80, 'the corpus must document its rule');
check(Array.isArray(corpus.vectors) && corpus.vectors.length >= 15, 'the corpus must hold at least 15 vectors');
const ids = new Set();
let valid = 0;
let invalid = 0;
for (const vector of corpus.vectors || []) {
	check(typeof vector.id === 'string' && !ids.has(vector.id), `duplicate or missing id ${vector.id}`);
	ids.add(vector.id);
	check(typeof vector.value === 'string', `${vector.id}: value must be a string`);
	const expected = referenceParse(vector.value, pairs);
	if (vector.valid === false) {
		invalid += 1;
		check(expected === null, `${vector.id}: the rule resolves it to ${JSON.stringify(expected)}`);
		check(vector.left === undefined && vector.right === undefined, `${vector.id}: an invalid vector has no pair`);
	} else {
		valid += 1;
		check(expected !== null && expected.left === vector.left && expected.right === vector.right,
			`${vector.id}: the rule resolves it to ${JSON.stringify(expected)}`);
	}
}
check(valid >= 8 && invalid >= 5, `the corpus needs both kinds of vector (${valid} valid, ${invalid} invalid)`);

// Each suite replays the corpus, and each replay is wired into its runner.
const CONSUMERS = [
	{ file: 'macos/tests/unit/modules/gestures/test_wrap_pair_parameter_vectors.lua', path: 'tests/corpus/action_parameters/wrap_pair_vectors.json' },
	{ file: 'linux/tests/unit/modules/shortcuts/test_wrap_pair_parameter_vectors.lua', path: '_shared/tests/corpus/action_parameters/wrap_pair_vectors.json' },
	{ file: 'windows/tests/unit/test_wrap_selection_action.ahk', path: '\\tests\\corpus\\action_parameters\\wrap_pair_vectors.json' }
];
for (const consumer of CONSUMERS) {
	const abs = path.join(SP, consumer.file);
	const source = fs.existsSync(abs) ? fs.readFileSync(abs, 'utf8') : '';
	check(source.includes(consumer.path), `${consumer.file} must read the shared wrap-pair corpus`);
}
const linuxManifest = fs.readFileSync(path.join(SP, 'linux', 'tests', 'test_manifest.lua'), 'utf8');
check(linuxManifest.includes('"tests.unit.modules.shortcuts.test_wrap_pair_parameter_vectors"'),
	'the Linux test manifest must list test_wrap_pair_parameter_vectors');
const ahkRunner = fs.readFileSync(path.join(SP, 'windows', 'tests', 'run_all.ahk'), 'utf8');
check(/^#Include unit\/test_wrap_selection_action\.ahk$/m.test(ahkRunner),
	'windows/tests/run_all.ahk must #Include unit/test_wrap_selection_action.ahk');

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}
console.log(`\x1b[32m[OK] shared wrap-pair corpus: ${checks} check(s) passed (${corpus.vectors.length} vectors).\x1b[0m`);
