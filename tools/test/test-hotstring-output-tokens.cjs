// tools/test/test-hotstring-output-tokens.cjs

/**
 * ==============================================================================
 * MODULE: Shared Hotstring Output Token Corpus Gate
 * DESCRIPTION:
 * Checks _shared/tests/corpus/hotstrings/output_token_vectors.json against a
 * reference implementation of its documented rule over the vocabulary
 * _shared/modules/actions/send_keys.json, checks that the tokens the editors
 * advertise are all in it, and checks that each driver suite replays the corpus.
 *
 * WHY:
 * The editor promised {Left} and the shipped magic-key pack holds {U+XXXX}, while
 * Windows and Linux typed both as text and macOS typed the second. The grammar is
 * implemented twice (_shared/lua/send_input, windows/infra/send_input_parameter.ahk);
 * the corpus is what keeps them equal, and it pins nothing if no suite replays it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const CORPUS_RELATIVE = ['tests', 'corpus', 'hotstrings', 'output_token_vectors.json'];
const CORPUS = path.join(SP, '_shared', ...CORPUS_RELATIVE);
const VOCABULARY = path.join(SP, '_shared', 'modules', 'actions', 'send_keys.json');

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

const vocabulary = JSON.parse(fs.readFileSync(VOCABULARY, 'utf8'));
const findKey = (name) =>
	vocabulary.keys.find((entry) => entry.id === name || entry.aliases.includes(name)) || null;

/** Reads the inside of one {group}: a code point, a key, or null. */
function readGroup(inner) {
	const hex = /^[Uu]\+([0-9A-Fa-f]+)$/.exec(inner);
	if (hex) {
		if (hex[1].length > 6) return null;
		const code = parseInt(hex[1], 16);
		const control = code <= 0x1f || (code >= 0x7f && code <= 0x9f);
		if (code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff) || control) return null;
		return { text: String.fromCodePoint(code) };
	}
	const named = /^([0-9A-Za-z][0-9A-Za-z_]*)(?: ([1-9][0-9]*))?$/.exec(inner);
	if (!named) return null;
	const count = named[2] === undefined ? 1 : Number(named[2]);
	if (count > vocabulary.output_key_max_repeat) return null;
	const entry = findKey(named[1].replace(/[A-Z]/g, (c) => c.toLowerCase()));
	return entry ? { key: entry.id, count } : null;
}

/** The documented rule, as a reference. */
function parseOutput(value) {
	const tokens = [];
	const pushText = (text) => {
		const last = tokens[tokens.length - 1];
		if (last && last.text !== undefined) last.text += text;
		else tokens.push({ text });
	};
	let index = 0;
	while (index < value.length) {
		const char = value[index];
		if (char === '\t') {
			tokens.push({ key: 'tab', count: 1 });
			index += 1;
		} else if (char === '\r' || char === '\n') {
			index += char === '\r' && value[index + 1] === '\n' ? 2 : 1;
			tokens.push({ key: 'enter', count: 1 });
		} else if (value.startsWith('{{}', index)) {
			pushText('{');
			index += 3;
		} else if (value.startsWith('{}}', index)) {
			pushText('}');
			index += 3;
		} else if (char === '{') {
			const close = value.indexOf('}', index + 1);
			const group = close === -1 ? null : readGroup(value.slice(index + 1, close));
			if (group === null) {
				pushText('{');
				index += 1;
			} else {
				if (group.text !== undefined) pushText(group.text);
				else tokens.push(group);
				index = close + 1;
			}
		} else {
			pushText(char);
			index += 1;
		}
	}
	return tokens;
}

check(
	Number.isInteger(vocabulary.output_key_max_repeat) && vocabulary.output_key_max_repeat > 1,
	'send_keys.json must declare an integer output_key_max_repeat above 1'
);

const corpus = JSON.parse(fs.readFileSync(CORPUS, 'utf8'));
check(typeof corpus.rule === 'string' && corpus.rule.length > 200, 'the corpus documents its rule');
check(corpus.vectors.length >= 40, 'the corpus must hold its vectors');
const ids = new Set();
const covered = new Set();
for (const vector of corpus.vectors) {
	check(
		typeof vector.id === 'string' && !ids.has(vector.id),
		`duplicate or missing id ${vector.id}`
	);
	ids.add(vector.id);
	const actual = parseOutput(vector.output);
	check(
		JSON.stringify(actual) === JSON.stringify(vector.tokens),
		`${vector.id}: the rule reads ${JSON.stringify(actual)}, the vector says ${JSON.stringify(vector.tokens)}`
	);
	const typed = actual.map((token) => token.text || '').join('');
	check(typed === vector.text, `${vector.id}: the typed text is ${JSON.stringify(typed)}`);
	const hasKeys = actual.some((token) => token.key !== undefined);
	check(hasKeys === vector.has_keys, `${vector.id}: has_keys should be ${hasKeys}`);
	for (const token of actual) if (token.key) covered.add(token.key);
}

// What the Windows editor's help line lists is promised to the user, so each one
// resolves and has a vector.
const editor = fs.readFileSync(path.join(SP, 'windows', 'ui', 'personal_toml_editor.ahk'), 'utf8');
const help = /"(\{Enter\}[^"\n]*\{End\})"/.exec(editor);
check(help !== null, 'the Windows editor must still list its tokens on one line');
for (const name of help ? help[1].match(/[A-Za-z]+/g) : []) {
	const entry = findKey(name.toLowerCase());
	check(entry !== null, `the editor promises {${name}}, which send_keys.json does not name`);
	check(entry !== null && covered.has(entry.id), `no vector presses the promised {${name}}`);
}

// Every {U+XXXX} the shipped packs hold is a token of the grammar, not text.
const magic = fs.readFileSync(
	path.join(SP, '_shared', 'modules', 'hotstrings', 'magickey.toml'),
	'utf8'
);
for (const match of magic.matchAll(/output = "(\{U\+[0-9A-Fa-f]+\})"/g)) {
	const parsed = parseOutput(match[1]);
	check(
		parsed.length === 1 && parsed[0].text !== undefined && parsed[0].text.length <= 2,
		`magickey.toml: ${match[1]} must decode to one code point`
	);
}

// Each suite replays the corpus, and each replay is wired into its runner.
const CONSUMERS = [
	'macos/tests/unit/modules/keymap/expansion/test_output_token_vectors.lua',
	'linux/tests/unit/modules/hotstrings/engine/test_output_token_vectors.lua',
	'windows/tests/unit/modules/hotstrings/engine/test_hotstring_output_tokens.ahk'
];
for (const file of CONSUMERS) {
	const abs = path.join(SP, file);
	const source = fs.existsSync(abs) ? fs.readFileSync(abs, 'utf8') : '';
	check(source.includes('output_token_vectors.json'), `${file} must read the shared corpus`);
}
const linuxManifest = fs.readFileSync(path.join(SP, 'linux', 'tests', 'test_manifest.lua'), 'utf8');
check(
	linuxManifest.includes('"tests.unit.modules.hotstrings.engine.test_output_token_vectors"'),
	'the Linux test manifest must list test_output_token_vectors'
);
const ahkRunner = fs.readFileSync(path.join(SP, 'windows', 'tests', 'run_all.ahk'), 'utf8');
check(
	/^#Include unit\/modules\/hotstrings\/engine\/test_hotstring_output_tokens\.ahk$/m.test(
		ahkRunner
	),
	'windows/tests/run_all.ahk must #Include test_hotstring_output_tokens.ahk'
);

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] hotstring output tokens: ${checks} check(s) passed (${corpus.vectors.length} vectors).\x1b[0m`
);
