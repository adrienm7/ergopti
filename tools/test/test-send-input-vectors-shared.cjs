// tools/test/test-send-input-vectors-shared.cjs

/**
 * ==============================================================================
 * MODULE: Shared Send-Input Corpus Gate
 * DESCRIPTION:
 * Checks the corpus of the send_text, send_key and send_shortcut parameters,
 * _shared/tests/corpus/action_parameters/send_input_vectors.json, against the
 * vocabulary _shared/modules/actions/send_keys.json with a reference
 * implementation of its documented rules, checks the vocabulary itself (unique
 * ids and aliases, a name for every driver), and checks that each driver suite
 * replays the corpus.
 *
 * WHY:
 * The grammar is implemented twice (_shared/lua/send_input for macOS and Linux,
 * windows/infra/send_input_parameter.ahk) and read a third time by the shared
 * action picker. The corpus is what keeps them equal; a corpus whose
 * expectations disagree with its own rule, or that no suite replays, pins
 * nothing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const CORPUS = path.join(SP, '_shared', 'tests', 'corpus', 'action_parameters', 'send_input_vectors.json');
const VOCABULARY = path.join(SP, '_shared', 'modules', 'actions', 'send_keys.json');
const CATALOGUE = path.join(SP, '_shared', 'modules', 'actions', 'actions.toml');

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

const trim = (text) => text.replace(/^[ \t\r\n\v\f]+|[ \t\r\n\v\f]+$/g, '');
const asciiLower = (text) => text.replace(/[A-Z]/g, (c) => c.toLowerCase());
const isControl = (code) => code <= 0x1f || (code >= 0x7f && code <= 0x9f);

/** The documented rules, as a reference. */
function makeParser(vocabulary) {
	const find = (entries, wanted) =>
		entries.find((entry) => entry.id === wanted || entry.aliases.includes(wanted)) || null;
	const parseText = (value) => {
		const points = Array.from(value);
		if (points.length === 0 || points.length > vocabulary.text_max_code_points) return null;
		if (points.some((point) => isControl(point.codePointAt(0)))) return null;
		return { text: value, canonical: value };
	};
	const parseKey = (value, lowerLetter) => {
		const wanted = trim(value);
		if (wanted === '') return null;
		const entry = find(vocabulary.keys, asciiLower(wanted));
		if (entry) return { named: entry.id, canonical: entry.id };
		const points = Array.from(wanted);
		if (points.length !== 1 || isControl(points[0].codePointAt(0))) return null;
		const char = lowerLetter ? asciiLower(wanted) : wanted;
		return { char, canonical: char };
	};
	const parseShortcut = (value) => {
		const wanted = trim(value);
		if (wanted === '') return null;
		let keyToken;
		let modTokens;
		if (wanted.length >= 2 && wanted.endsWith('++')) {
			keyToken = '+';
			modTokens = wanted.slice(0, -2).split('+');
		} else {
			modTokens = wanted.split('+');
			keyToken = modTokens.pop();
		}
		if (modTokens.length === 0) return null;
		const held = new Set();
		for (const token of modTokens) {
			const entry = find(vocabulary.modifiers, asciiLower(trim(token)));
			if (!entry || held.has(entry.id)) return null;
			held.add(entry.id);
		}
		const key = parseKey(keyToken, true);
		if (!key) return null;
		const mods = vocabulary.modifiers.filter((entry) => held.has(entry.id)).map((entry) => entry.id);
		return { ...key, mods, canonical: mods.map((id) => id + '+').join('') + key.canonical };
	};
	return { text: parseText, key: (value) => parseKey(value, false), shortcut: parseShortcut };
}

const vocabulary = JSON.parse(fs.readFileSync(VOCABULARY, 'utf8'));

// The vocabulary: every entry names itself for every driver, and no token
// names two entries.
check(Number.isInteger(vocabulary.text_max_code_points) && vocabulary.text_max_code_points > 0,
	'send_keys.json must declare a positive integer text_max_code_points');
for (const family of ['modifiers', 'keys']) {
	const entries = vocabulary[family];
	check(Array.isArray(entries) && entries.length >= (family === 'keys' ? 20 : 5),
		`send_keys.json ${family} is missing or too short`);
	const tokens = new Set();
	for (const entry of entries || []) {
		for (const token of [entry.id, ...(entry.aliases || [])]) {
			check(typeof token === 'string' && token === asciiLower(token) && token.length > 1,
				`${family}.${entry.id}: token "${token}" must be a lowercase name`);
			check(!tokens.has(token), `${family}: "${token}" names two entries`);
			tokens.add(token);
		}
		check(typeof entry.ahk === 'string' && entry.ahk !== '', `${family}.${entry.id}: no AutoHotkey name`);
		check(typeof entry.hs === 'string' && entry.hs !== '', `${family}.${entry.id}: no Hammerspoon name`);
		check(Number.isInteger(entry.linux) && entry.linux > 0, `${family}.${entry.id}: no evdev keycode`);
	}
}
const primary = (vocabulary.modifiers || []).find((entry) => entry.id === 'primary');
check(primary && primary.hs === 'cmd' && primary.ahk === 'Ctrl',
	'the primary modifier is Command on macOS and Control on Windows');

const parse = makeParser(vocabulary);
const corpus = JSON.parse(fs.readFileSync(CORPUS, 'utf8'));
for (const kind of ['text', 'key', 'shortcut']) {
	check(corpus.rule && typeof corpus.rule[kind] === 'string' && corpus.rule[kind].length > 80,
		`the corpus must document the ${kind} rule`);
}
const ids = new Set();
const counts = { text: [0, 0], key: [0, 0], shortcut: [0, 0] };
for (const vector of corpus.vectors || []) {
	check(typeof vector.id === 'string' && !ids.has(vector.id), `duplicate or missing id ${vector.id}`);
	ids.add(vector.id);
	check(parse[vector.kind] !== undefined, `${vector.id}: unknown kind ${vector.kind}`);
	if (!parse[vector.kind]) continue;
	const value = vector.value.repeat(vector.repeat || 1);
	const actual = parse[vector.kind](value);
	if (vector.valid === false) {
		counts[vector.kind][1] += 1;
		check(actual === null, `${vector.id}: the rule accepts it as ${JSON.stringify(actual)}`);
		continue;
	}
	counts[vector.kind][0] += 1;
	const canonical = vector.canonical.repeat(vector.canonical_repeat || 1);
	check(actual !== null && actual.canonical === canonical,
		`${vector.id}: the rule reads ${JSON.stringify(actual)}`);
	if (!actual) continue;
	if (vector.kind !== 'text') {
		check((vector.named || null) === (actual.named || null) && (vector.char || null) === (actual.char || null),
			`${vector.id}: named/char disagree with the rule (${JSON.stringify(actual)})`);
	}
	if (vector.kind === 'shortcut') {
		check(JSON.stringify(vector.mods) === JSON.stringify(actual.mods),
			`${vector.id}: modifiers ${JSON.stringify(actual.mods)}`);
	}
}
for (const [kind, [valid, invalid]] of Object.entries(counts)) {
	check(valid >= 4 && invalid >= 3, `the corpus needs both kinds of ${kind} vector (${valid} valid, ${invalid} invalid)`);
}

// The catalogue declares the three actions with these kinds.
const catalogue = fs.readFileSync(CATALOGUE, 'utf8');
for (const [action, kind] of [['send_text', 'text'], ['send_key', 'key'], ['send_shortcut', 'shortcut']]) {
	const block = catalogue.match(new RegExp(`\\[sg_actions\\.${action}\\]([\\s\\S]*?)(?=\\n\\[)`));
	check(block && new RegExp(`^parameter = "${kind}"$`, 'm').test(block[1]),
		`actions.toml must declare ${action} with parameter = "${kind}"`);
}

// Each suite replays the corpus, and each replay is wired into its runner.
const CONSUMERS = [
	{ file: 'macos/tests/unit/modules/gestures/test_send_input_parameter_vectors.lua', path: 'tests/corpus/action_parameters/send_input_vectors.json' },
	{ file: 'linux/tests/unit/modules/shortcuts/test_send_input_parameter_vectors.lua', path: '_shared/tests/corpus/action_parameters/send_input_vectors.json' },
	{ file: 'windows/tests/unit/test_send_input_actions.ahk', path: '\\tests\\corpus\\action_parameters\\send_input_vectors.json' }
];
for (const consumer of CONSUMERS) {
	const abs = path.join(SP, consumer.file);
	const source = fs.existsSync(abs) ? fs.readFileSync(abs, 'utf8') : '';
	check(source.includes(consumer.path), `${consumer.file} must read the shared send-input corpus`);
}
const linuxManifest = fs.readFileSync(path.join(SP, 'linux', 'tests', 'test_manifest.lua'), 'utf8');
check(linuxManifest.includes('"tests.unit.modules.shortcuts.test_send_input_parameter_vectors"'),
	'the Linux test manifest must list test_send_input_parameter_vectors');
const ahkRunner = fs.readFileSync(path.join(SP, 'windows', 'tests', 'run_all.ahk'), 'utf8');
check(/^#Include unit\/test_send_input_actions\.ahk$/m.test(ahkRunner),
	'windows/tests/run_all.ahk must #Include unit/test_send_input_actions.ahk');

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}
console.log(`\x1b[32m[OK] shared send-input corpus: ${checks} check(s) passed (${corpus.vectors.length} vectors).\x1b[0m`);
