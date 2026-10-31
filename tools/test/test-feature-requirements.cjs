// tools/test/test-feature-requirements.cjs

/**
 * ==============================================================================
 * MODULE: Feature Requirements Gate
 * DESCRIPTION:
 * Every feature of _shared/modules/features/manifest.toml declares, per OS it
 * is available on, what it needs outside its driver. This gate derives the same
 * lists from the drivers (tools/lib/feature-requirements.cjs) and fails, per
 * OS, in both directions: a feature that reaches a requirement without
 * declaring it, and a declared requirement nothing reaches. It also fails when
 * docs/design/feature-requirements.md is not the generated table.
 *
 * FEATURES & RATIONALE:
 * 1. Real inputs: the macOS Karabiner use comes from the generator's own state
 *    field mapping and remap facade inventory, every other use from the source
 *    signatures of requirements.toml; nothing is read from prose.
 * 2. The gate proves it can fail: each mutation below removes or adds one input
 *    and must produce the matching counterexample, so a derivation that went
 *    blind (a signature matching nothing, a table no longer parsed) is caught.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('fs');
const Requirements = require('../lib/feature-requirements.cjs');

let failures = 0;

/**
 * Runs one named check and records its failure.
 * @param {string} name Check name.
 * @param {Function} fn Check body.
 */
function check(name, fn) {
	try {
		fn();
		console.log(`  ok  ${name}`);
	} catch (err) {
		failures += 1;
		console.error(`  FAIL ${name}\n${err.message}`);
	}
}

/**
 * A deep copy of the sources, so one mutation never leaks into the next.
 * @param {object} sources From loadSources().
 * @returns {object}
 */
function cloneSources(sources) {
	return {
		features: sources.features.map((f) => ({
			...f,
			requires: f.requires && JSON.parse(JSON.stringify(f.requires))
		})),
		vocabulary: JSON.parse(JSON.stringify(sources.vocabulary)),
		generator: sources.generator,
		files: JSON.parse(JSON.stringify(sources.files))
	};
}

/**
 * Asserts a mutated derivation reports an error matching `pattern`.
 * @param {object} mutated Mutated sources.
 * @param {RegExp} pattern Expected counterexample.
 */
function expectError(mutated, pattern) {
	const { errors } = Requirements.derive(mutated);
	assert(
		errors.some((e) => pattern.test(e)),
		`expected an error matching ${pattern}, got:\n${errors.slice(0, 5).join('\n') || '(none)'}`
	);
}

/**
 * The first feature available on `os` whose declaration names `id`.
 * @returns {object}
 */
function featureDeclaring(sources, os, id) {
	const feature = sources.features.find((f) => f.requires && (f.requires[os] || []).includes(id));
	assert(feature, `no feature declares ${id} on ${os}: the mutation has nothing to remove`);
	return feature;
}

const sources = Requirements.loadSources();
console.log('Feature requirements gate');

check('every feature declares exactly what the drivers derive, per OS', () => {
	const { errors } = Requirements.derive(sources);
	assert.equal(errors.length, 0, errors.join('\n'));
});

check('docs/design/feature-requirements.md is the generated table', () => {
	const current = fs.existsSync(Requirements.TABLE_PATH)
		? fs.readFileSync(Requirements.TABLE_PATH, 'utf8')
		: '';
	assert.equal(
		current,
		Requirements.renderTable(sources),
		'stale table: run node tools/codegen/codegen-feature-requirements.cjs'
	);
});

check('every requirement of every OS is derived for at least one feature', () => {
	const { derived, byOs } = Requirements.derive(sources);
	for (const os of Requirements.OS_ORDER) {
		for (const id of byOs.get(os)) {
			const reached = [...(derived.get(os) || new Map()).values()].some((uses) => uses.has(id));
			assert(reached, `${os}/${id}: the detection rule reaches no feature`);
		}
	}
});

check('a feature that reaches a requirement without declaring it fails', () => {
	for (const [os, id] of [
		['macos', 'karabiner'],
		['linux', 'evdev'],
		['windows', 'webview2']
	]) {
		const mutated = cloneSources(sources);
		const feature = featureDeclaring(mutated, os, id);
		feature.requires[os] = feature.requires[os].filter((x) => x !== id);
		expectError(
			mutated,
			new RegExp(
				`^${feature.path.replace(/\./g, '\\.')}: reaches ${id} on ${os} without declaring it`
			)
		);
	}
});

check('a declared requirement nothing reaches fails', () => {
	for (const os of Requirements.OS_ORDER) {
		const mutated = cloneSources(sources);
		const feature = mutated.features.find(
			(f) => f.requires && Array.isArray(f.requires[os]) && f.requires[os].length === 0
		);
		assert(feature, `no feature declares nothing on ${os}`);
		const id = { macos: 'karabiner', linux: 'wmctrl', windows: 'ollama' }[os];
		feature.requires[os] = [id];
		expectError(mutated, new RegExp(`declares ${id} on ${os} but nothing derived reaches it`));
	}
});

check('an id outside the OS vocabulary and a requirement on an unavailable OS fail', () => {
	const mutated = cloneSources(sources);
	const windowsOnly = mutated.features.find((f) => f.oses.length === 1 && f.oses[0] === 'windows');
	windowsOnly.requires.windows = ['evdev'];
	windowsOnly.requires.linux = [];
	expectError(mutated, /requires\.windows names "evdev", outside the windows vocabulary/);
	expectError(mutated, /requires\.linux is declared but the feature is not available on linux/);
});

check('a generator state field without a mapping fails', () => {
	const mutated = cloneSources(sources);
	mutated.generator = mutated.generator.replace(
		/^(function M\.build_karabiner_json\()/m,
		'local function _probe(state) return state.probe_unmapped_field end\n$1'
	);
	expectError(
		mutated,
		/reads state\.probe_unmapped_field but M\.REQUIREMENT_STATE_FEATURES does not map it/
	);
});

check('a remap facade caller missing from the generator inventory fails', () => {
	const mutated = cloneSources(sources);
	mutated.files.macos['modules/probe_caller.lua'] =
		'local KeVariables = require("platform.remap.ke_variables")\nreturn KeVariables\n';
	expectError(mutated, /modules\/probe_caller\.lua calls the remap facade/);
});

check('an unlisted file using a requirement fails, and a dead owner fails', () => {
	const added = cloneSources(sources);
	added.files.linux['modules/probe_spawner.lua'] = 'os.execute("wmctrl -s 1")\n';
	expectError(
		added,
		/linux\/wmctrl: modules\/probe_spawner\.lua reaches the requirement but is neither an owner nor plumbing/
	);
	const removed = cloneSources(sources);
	delete removed.files.linux['modules/gestures/workspace_switcher.lua'];
	expectError(
		removed,
		/linux\/wmctrl: owner "modules\/gestures\/workspace_switcher\.lua" matches no file/
	);
});

check('a signature that only appears in a comment is no use', () => {
	const mutated = cloneSources(sources);
	mutated.files.linux['modules/probe_comment.lua'] =
		'-- this module once ran "wmctrl -s 1"\nreturn {}\n';
	const { errors } = Requirements.derive(mutated);
	assert(!errors.some((e) => /probe_comment/.test(e)), errors.join('\n'));
});

if (failures > 0) {
	console.error(`${failures} feature requirements check(s) failed.`);
	process.exit(1);
}
console.log('All feature requirements checks passed.');
