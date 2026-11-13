// tools/test/test-user-action-vectors-shared.cjs

/**
 * ==============================================================================
 * MODULE: Shared User-Action Parameter Corpus Gate
 * DESCRIPTION:
 * Checks the corpus of the run_command, open_path and run_apple_shortcut
 * parameters, _shared/tests/corpus/action_parameters/user_action_vectors.json,
 * against a reference implementation of its documented rule, checks that the
 * macOS and Linux suites replay it, and that no driver claims one of the three
 * actions in actions.toml without a suite that replays it.
 *
 * WHY:
 * The rule is implemented once for both Lua drivers
 * (_shared/shortcuts/engine/user_action_parameter.lua); Windows is pending
 * (docs/tooling/windows-pc-agent-handoff.md). A corpus that disagrees with its
 * own rule, or that a suite stops replaying, pins nothing, and a platform
 * claimed before its replay exists is a binding the picker offers untested.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const CORPUS = path.join(
	SP,
	'_shared',
	'tests',
	'corpus',
	'action_parameters',
	'user_action_vectors.json'
);
const ACTIONS = path.join(SP, '_shared', 'shortcuts', 'data', 'actions', 'actions.toml');

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

const MAX_BYTES = 4096;
const bytes = (text) => Buffer.byteLength(text, 'utf8');
// Control characters: C0 and DEL; a command also admits tab and line feed.
const hasControl = (text, allowLines) =>
	[...text].some((ch) => {
		const code = ch.codePointAt(0);
		if (code > 31 && code !== 127) return false;
		return !(allowLines && (code === 9 || code === 10));
	});
const clean = (value) =>
	typeof value === 'string' &&
	value !== '' &&
	bytes(value) <= MAX_BYTES &&
	!value.includes('\u0000');
const UUID = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;

/**
 * Decodes a versioned object holding exactly `keys` besides its version.
 * @param {string} value
 * @param {string[]} keys
 * @returns {object|null}
 */
function decode(value, keys) {
	let data;
	try {
		data = JSON.parse(value);
	} catch {
		return null;
	}
	if (data === null || typeof data !== 'object' || Array.isArray(data)) return null;
	const present = Object.keys(data).sort();
	const wanted = ['version', ...keys].sort();
	if (present.length !== wanted.length || present.some((key, index) => key !== wanted[index]))
		return null;
	return data.version === 1 ? data : null;
}

/**
 * The documented rule, as a reference.
 * @param {string} kind
 * @param {string} value
 * @returns {object|null} The decoded fields.
 */
function referenceParse(kind, value) {
	if (kind === 'command') {
		const data = decode(value, ['command', 'mode', 'output']);
		if (!data || !clean(data.command) || hasControl(data.command, true) || !/\S/.test(data.command))
			return null;
		if (
			!['hidden', 'terminal'].includes(data.mode) ||
			!['none', 'type', 'copy'].includes(data.output)
		)
			return null;
		if (data.mode === 'terminal' && data.output !== 'none') return null;
		return { command: data.command, mode: data.mode, output: data.output };
	}
	if (kind === 'path') {
		if (!clean(value) || !value.startsWith('/') || hasControl(value, false)) return null;
		if (value.split('/').some((part) => part === '.' || part === '..')) return null;
		return { path: value };
	}
	if (kind === 'apple_shortcut') {
		const data = decode(value, ['id', 'name', 'input', 'output']);
		if (!data || typeof data.id !== 'string' || !UUID.test(data.id)) return null;
		if (!clean(data.name) || hasControl(data.name, false)) return null;
		if (
			!['none', 'selection'].includes(data.input) ||
			!['none', 'type', 'copy'].includes(data.output)
		)
			return null;
		return { id: data.id, name: data.name, input: data.input, output: data.output };
	}
	throw new Error(`unknown kind ${kind}`);
}

const corpus = JSON.parse(fs.readFileSync(CORPUS, 'utf8'));
check(
	typeof corpus.rule === 'string' && corpus.rule.length > 200,
	'the corpus must document its rule'
);
const ids = new Set();
const counts = {};
for (const vector of corpus.vectors || []) {
	const key = `${vector.kind}:${vector.id}`;
	check(!ids.has(key), `duplicate vector ${key}`);
	ids.add(key);
	const expected = referenceParse(vector.kind, vector.value);
	const valid = vector.valid !== false;
	counts[`${vector.kind}:${valid}`] = (counts[`${vector.kind}:${valid}`] || 0) + 1;
	if (valid) {
		check(
			JSON.stringify(expected) === JSON.stringify(vector.parsed),
			`${key}: the rule decodes it to ${JSON.stringify(expected)}`
		);
	} else {
		check(expected === null, `${key}: the rule accepts it as ${JSON.stringify(expected)}`);
		check(vector.parsed === undefined, `${key}: an invalid vector has no parsed fields`);
	}
}
for (const kind of ['command', 'path', 'apple_shortcut'])
	check(
		(counts[`${kind}:true`] || 0) >= 4 && (counts[`${kind}:false`] || 0) >= 6,
		`the corpus needs valid and invalid ${kind} vectors`
	);

// Each Lua suite replays the corpus, and each replay is wired into its runner.
const CONSUMERS = {
	hs: 'macos/tests/unit/modules/gestures/actions/test_user_actions.lua',
	linux: 'linux/tests/unit/modules/gestures/actions/test_user_actions.lua',
	ahk: 'windows/tests/unit/modules/gestures/test_user_actions.ahk'
};
for (const [platform, file] of Object.entries(CONSUMERS)) {
	const abs = path.join(SP, file);
	const source = fs.existsSync(abs) ? fs.readFileSync(abs, 'utf8') : '';
	const corpusPath =
		platform === 'ahk'
			? 'tests\\corpus\\action_parameters\\user_action_vectors.json'
			: 'tests/corpus/action_parameters/user_action_vectors.json';
	check(source.includes(corpusPath), `${file} must read the shared user-action corpus`);
	check(
		source.includes(
			platform === 'ahk' ? 'GestureValidateActionParameter' : 'validate_action_parameter'
		),
		`${file} must replay it through the gesture validator`
	);
}
const ahkRunner = fs.readFileSync(path.join(SP, 'windows', 'tests', 'run_all.ahk'), 'utf8');
check(
	ahkRunner.includes('unit/modules/gestures/test_user_actions.ahk'),
	'the AHK runner must include test_user_actions.ahk'
);
const linuxManifest = fs.readFileSync(path.join(SP, 'linux', 'tests', 'test_manifest.lua'), 'utf8');
check(
	linuxManifest.includes('"tests.unit.modules.gestures.actions.test_user_actions"'),
	'the Linux test manifest must list test_user_actions'
);

// A driver claims an action only once its suite replays the corpus.
const catalogue = TOML.parse(fs.readFileSync(ACTIONS, 'utf8'));
const EXPECTED_KIND = {
	run_command: 'command',
	open_path: 'path',
	run_apple_shortcut: 'apple_shortcut'
};
for (const [action, kind] of Object.entries(EXPECTED_KIND)) {
	const row = catalogue.sg_actions[action];
	check(row !== undefined, `actions.toml declares no ${action}`);
	if (!row) continue;
	check(row.parameter === kind, `${action} must carry the ${kind} parameter`);
	const platforms = row.platform === 'all' ? ['hs', 'ahk', 'linux'] : row.platform.split(',');
	for (const platform of platforms)
		check(
			CONSUMERS[platform] !== undefined,
			`${action} claims ${platform}, whose suite does not replay the user-action corpus`
		);
}
check(
	catalogue.sg_actions.run_apple_shortcut?.platform === 'hs',
	'run_apple_shortcut is macOS only'
);

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] shared user-action corpus: ${checks} check(s) passed (${corpus.vectors.length} vectors).\x1b[0m`
);
