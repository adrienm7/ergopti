// tools/test/test-keyboard-slot-recommended-bindings.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard-Slot Defaults and Recommendations Gate
 * DESCRIPTION:
 * Fresh keyboard slots remain neutral. Explicit restoration uses independent
 * recommendations, including one prediction chord per driver. Production owners
 * project manifest defaults rather than maintaining private assignment tables.
 * In-memory mutations prove the gate rejects broken values and projections.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');
const { stripComments } = require('../lib/script-source.cjs');
const SP = path.resolve(__dirname, '../../static/ergopti_plus');
const PREDICTION_SLOTS = { ahk: 'win_space', hs: 'hs_ctrl_space', linux: 'super_space' };
const read = (file) => fs.readFileSync(path.join(SP, file), 'utf8').replace(/^\uFEFF/, '');

/**
 * Checks canonical values and the owners that initialize assignments.
 * @param {object} input Parsed entries and driver source snapshots.
 * @returns {{errors: string[], checks: number}} Violations and check count.
 */
function validate(input) {
	const errors = [];
	let checks = 0;
	const check = (ok, message) => {
		checks += 1;
		if (!ok) errors.push(message);
	};
	const slots = input.slots;
	check(slots.length >= 15, `inventory: only ${slots.length} keyboard entries parsed`);
	check(slots.filter((entry) => entry.platforms.includes('ahk')).length >= 15,
		'inventory: Windows must retain its full slot catalogue');
	const identities = new Set();
	for (const entry of slots) {
		check(entry.default === 'none', `neutral: ${entry.id} must initialize to none`);
		check(typeof entry.recommended === 'string' && entry.recommended.length > 0,
			`recommendation: ${entry.id} needs an independent recommended action`);
		check(entry.type === 'action' && entry.input_altering === true,
			`metadata: ${entry.id} must declare an input-altering action`);
		for (const platform of entry.platforms) {
			const identity = `${platform}:${entry.id}`;
			check(!identities.has(identity), `duplicate: ${identity}`);
			identities.add(identity);
			const value = (entry.default_per_platform || {})[platform];
			check(value === undefined || value === 'none', `neutral: ${identity} override must stay none`);
		}
	}
	for (const [platform, slot] of Object.entries(PREDICTION_SLOTS)) {
		const recommended = slots.filter((entry) => entry.platforms.includes(platform)
			&& ((entry.recommended_per_platform || {})[platform] ?? entry.recommended) === 'llm_generate_prediction');
		check(recommended.length === 1 && recommended[0].id === slot,
			`prediction: ${platform} must recommend exactly ${slot}`);
		const entry = slots.find((candidate) => candidate.id === slot);
		check(entry && JSON.stringify(entry.platforms) === JSON.stringify([platform]),
			`platform: ${slot} must belong only to ${platform}`);
	}
	const ahk = stripComments(input.ahk, '.ahk');
	const assignments = [...ahk.matchAll(/^global KEYBOARD_SHORTCUT_DEFAULTS\s*:=\s*(.+)$/gm)];
	check(assignments.length === 1
		&& assignments[0][1].trim() === '_FeatureStateDefaultsForSection("shortcuts.keyboard")',
		'windows-owner: defaults must use the canonical section projection exactly once');
	const body = (ahk.match(/^_FeatureStateDefaultsForSection\(Section\)\s*\{([\s\S]*?)^\}/m) || [])[1] || '';
	check(body !== '' && /for Entry in ManifestFeaturesForSection\(Section\)/.test(body)
		&& /Values\[Entry\["id"\]\]\s*:=\s*ManifestDefaultFor\(Entry\["path"\]\)/.test(body)
		&& /return Values/.test(body) && !/ManifestRecommendedFor/.test(body),
		'windows-projection: section entries must resolve defaults, never recommendations');
	for (const [platform, raw] of Object.entries(input.lua)) {
		const source = stripComments(raw, '.lua');
		const body = (source.match(/^local function manifest_defaults\(\)([\s\S]*?)^end/m) || [])[1] || '';
		const loader = (source.match(/^local function load_assignments\([^)]*\)([\s\S]*?)^end/m) || [])[1] || '';
		// Both owners publish one candidate map. macOS seeds it directly; Linux
		// projects assignable non-neutral rows into it. A dead defaults helper or
		// an unrelated loop elsewhere cannot satisfy the publication boundary.
		const direct = loader.match(/local\s+(\w+)\s*=\s*manifest_defaults\(\)/);
		const projected = loader.match(/for\s+(\w+)\s*,\s*(\w+)\s+in\s+pairs\(manifest_defaults\(\)\)\s+do/);
		const sink = projected && loader.match(new RegExp(`(\\w+)\\[${projected[1]}\\]\\s*=\\s*${projected[2]}\\b`));
		const candidate = direct?.[1] || sink?.[1];
		const published = candidate && (new RegExp(`_actions\\s*,\\s*_loaded\\s*=\\s*${candidate}\\s*,\\s*true\\b`).test(loader)
			|| new RegExp(`_assignments\\s*=\\s*${candidate}\\b`).test(loader));
		const overwritten = candidate && new RegExp(`^\\s*${candidate}\\s*=`, 'm').test(loader);
		check(/local KEYBOARD_SECTION = "shortcuts\.keyboard"/.test(source)
			&& body !== '' && /ipairs\(Manifest\.features\(\)\)/.test(body)
			&& /entry\.section == KEYBOARD_SECTION/.test(body)
			&& /defaults\[entry\.id\] = entry\.default/.test(body)
			&& /return defaults/.test(body) && !/entry\.recommended/.test(body)
			&& loader !== '' && Boolean(published) && !overwritten,
			`${platform}-owner: initialization must consume manifest defaults`);
	}
	return { errors, checks };
}

const manifest = toml.parse(read('_shared/modules/features/manifest.toml').replace(
	/^\[\[features\.([^\]]+)\]\]\r?$/gm,
	(_match, prefix) => `[[entries]]\npath_prefix = "${prefix}"`
));
const input = {
	slots: (manifest.entries || []).filter((entry) => entry.path_prefix === 'shortcuts.keyboard'),
	ahk: read('windows/infra/feature_state.ahk'),
	lua: {
		hs: read('macos/modules/shortcuts/keyboard_shortcuts.lua'),
		linux: read('linux/modules/shortcuts/keyboard_shortcuts.lua'),
	},
};
const result = validate(input);
const mutations = [
	['neutral', (copy) => { copy.slots[0].default = 'paste_plain'; }],
	['neutral', (copy) => { copy.slots[0].default_per_platform = { ahk: 'paste_plain' }; }],
	['prediction', (copy) => { copy.slots.find((entry) => entry.id === 'win_space').recommended = 'none'; }],
	['prediction', (copy) => { copy.slots[0].recommended_per_platform = { ahk: 'llm_generate_prediction' }; }],
	['inventory', (copy) => { copy.slots = copy.slots.slice(0, 2); }],
	['windows-owner', (copy) => { copy.ahk = copy.ahk.replace('global KEYBOARD_SHORTCUT_DEFAULTS := _FeatureStateDefaultsForSection("shortcuts.keyboard")', 'global KEYBOARD_SHORTCUT_DEFAULTS := Map()'); }],
	['windows-projection', (copy) => { copy.ahk = copy.ahk.replace('ManifestDefaultFor(Entry["path"])', 'ManifestRecommendedFor(Entry["path"])'); }],
	...Object.keys(input.lua).map((platform) => [`${platform}-owner`, (copy) => {
		copy.lua[platform] = copy.lua[platform].replace('defaults[entry.id] = entry.default', 'defaults[entry.id] = entry.recommended');
	}]),
	['hs-owner', (copy) => { copy.lua.hs = copy.lua.hs.replace('local loaded = manifest_defaults()', 'local loaded = {}'); }],
	['hs-owner', (copy) => { copy.lua.hs = copy.lua.hs.replace('_actions, _loaded = loaded, true', '_actions, _loaded = {}, true'); }],
	['hs-owner', (copy) => { copy.lua.hs = copy.lua.hs.replace('local loaded = manifest_defaults()', 'local loaded = {}') + '\nlocal unused = manifest_defaults()'; }],
	['hs-owner', (copy) => { copy.lua.hs = copy.lua.hs.replace('_actions, _loaded = loaded, true', 'loaded = {}\n_actions, _loaded = loaded, true'); }],
	['linux-owner', (copy) => { copy.lua.linux = copy.lua.linux.replace('pairs(manifest_defaults())', 'pairs({})'); }],
	['linux-owner', (copy) => { copy.lua.linux = copy.lua.linux.replace('_assignments = loaded', '_assignments = {}'); }],
];
for (const [label, mutate] of mutations) {
	const copy = structuredClone(input);
	mutate(copy);
	if (!validate(copy).errors.some((message) => message.startsWith(`${label}:`))) {
		result.errors.push(`mutation: ${label} corruption escaped its contract check`);
	}
}
if (result.errors.length > 0) {
	for (const error of result.errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}
console.log(`[OK] keyboard slots: ${input.slots.length} entries, ${result.checks} checks and ${mutations.length} rejected mutations.`);
