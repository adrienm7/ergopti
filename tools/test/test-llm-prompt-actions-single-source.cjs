// tools/test/test-llm-prompt-actions-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Prompt Actions Single-Source Gate
 * DESCRIPTION:
 * The built-in prompt profiles live in _shared/modules/llm/profiles.json. The
 * action catalogue (_shared/modules/actions/actions.toml) offers one
 * ready-made action per built-in profile, `llm_predict_<profile id>`, next to
 * the configurable `llm_prompt_prediction`. This gate keeps the two lists equal
 * and checks every place that must follow a new profile: the picker order, the
 * three generated catalogues and every locale.
 *
 * ROOT CAUSE ENCODED:
 * Running a prediction with a given prompt meant switching the whole AI menu to
 * it first. The per-profile actions fix that, but a profile added to the JSON
 * without its action (or an action left behind by a removed profile) would
 * silently offer a different set of prompts in the picker than in the menu.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const PROFILES = path.join(SP, '_shared', 'modules', 'llm', 'profiles.json');
const ACTIONS = path.join(SP, '_shared', 'modules', 'actions', 'actions.toml');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');
const CATALOGUES = [
	path.join(SP, 'macos', '_generated', 'action_catalogue.lua'),
	path.join(SP, 'linux', '_generated', 'action_catalogue.lua'),
	path.join(SP, 'windows', '_generated', 'action_catalogue.ahk')
];

// The configurable action every preset is a shortcut of, and the preset prefix
const CONFIGURABLE_ACTION = 'llm_prompt_prediction';
const PRESET_PREFIX = 'llm_predict_';

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

const profileIds = JSON.parse(fs.readFileSync(PROFILES, 'utf8')).map((profile) => profile.id);
const registry = toml.parse(fs.readFileSync(ACTIONS, 'utf8'));
const actions = registry.sg_actions || {};
const expected = profileIds.map((id) => PRESET_PREFIX + id);
const declared = Object.keys(actions).filter((id) => id.startsWith(PRESET_PREFIX));

check(profileIds.length >= 5 && profileIds.includes('rewrite'), 'profiles.json must hold the built-ins, rewrite included');

// 1. One preset per built-in profile, in both directions.
for (const id of expected) check(declared.includes(id), `actions.toml lacks ${id} for a built-in profile`);
for (const id of declared) check(expected.includes(id), `actions.toml declares ${id}, which names no built-in profile`);

// 2. The presets need no parameter and run everywhere the configurable action runs.
const configurable = actions[CONFIGURABLE_ACTION];
check(configurable && configurable.parameter === 'llm_prompt', `${CONFIGURABLE_ACTION} must take the llm_prompt parameter`);
for (const id of expected) {
	const row = actions[id] || {};
	check(row.parameter === undefined, `${id} must not take a parameter`);
	check(configurable && row.platform === configurable.platform, `${id} must run on ${configurable && configurable.platform}`);
}

// 3. The picker lists the presets right after the configurable action, in menu order.
const order = registry.sg_order.items;
const start = order.indexOf(CONFIGURABLE_ACTION);
check(start !== -1, `${CONFIGURABLE_ACTION} must be in [sg_order]`);
check(JSON.stringify(order.slice(start + 1, start + 1 + expected.length)) === JSON.stringify(expected),
	`[sg_order] must list ${expected.join(', ')} right after ${CONFIGURABLE_ACTION}`);

// 4. Every generated catalogue carries them: a stale one means the generator was not run.
for (const file of CATALOGUES) {
	const source = fs.readFileSync(file, 'utf8');
	for (const id of expected.concat([CONFIGURABLE_ACTION])) {
		check(source.includes(`"${id}"`), `${path.relative(ROOT, file)} lacks ${id}: run npm run codegen:action-catalogue`);
	}
}

// 5. Every locale labels them.
for (const file of fs.readdirSync(LOCALES).filter((name) => name.endsWith('.json'))) {
	const strings = JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8'));
	for (const id of expected.concat([CONFIGURABLE_ACTION])) {
		const label = strings[`sg_actions.${id}`];
		check(typeof label === 'string' && label.trim() !== '', `${file} lacks the label of ${id}`);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] prompt actions single source:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}
console.log(`\x1b[32m[OK] one prompt action per built-in profile, ordered, generated and labelled (${checks} checks).\x1b[0m`);
