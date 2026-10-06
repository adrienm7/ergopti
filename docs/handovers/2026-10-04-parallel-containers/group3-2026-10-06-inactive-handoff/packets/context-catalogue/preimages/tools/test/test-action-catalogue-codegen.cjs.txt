// tools/test/test-action-catalogue-codegen.cjs

/**
 * ==============================================================================
 * MODULE: Action Catalogue Codegen Guard
 * DESCRIPTION:
 * Pins the contract of tools/codegen/codegen-action-catalogue.cjs, which turns
 * _shared/modules/actions/actions.toml into one catalogue per driver.
 *
 * ROOT CAUSES ENCODED:
 * 1. Three runtime readers of one TOML file disagreed. The macOS line reader
 *    stored anything but `key = "string"` as a raw string without an error, and
 *    Linux ignored the file for its picker altogether. The generator is now the
 *    only reader, so it must refuse what it does not understand: an unknown
 *    field, platform, parameter kind or requirement token, an ordered id with no
 *    table, a declared id that is never ordered.
 * 2. The picker headings came out French in every locale. The catalogue carried
 *    the literal "#Raccourcis" and the drivers glued "##Raccourcis " to each
 *    modifier group. Every heading must now be a locale key present, with a
 *    real value, in all 21 locales, and the group key must carry its {1}.
 * 3. Headings with nothing under them on a platform ("Navigation" holds two
 *    Windows-only rows) read as a list that failed to load; they are dropped.
 * 4. The declaration-vs-driver gate was a literal scan: an id counted as
 *    handled whenever it appeared as a quoted string anywhere in the driver
 *    tree, so Linux "select_line" and "tab" passed while doing nothing. The
 *    real comparison — generated catalogue against the set each driver can
 *    run, both ways — lives in each driver's own suite, where the registry
 *    exists; this file checks those three tests are still there.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const {
	generate,
	parseRegistry,
	OUTPUTS,
	CHORD_GROUP_KEY,
	HEADER_KEY_PREFIX
} = require('../codegen/codegen-action-catalogue.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SOURCE = fs.readFileSync(
	path.join(SP, '_shared', 'modules', 'actions', 'actions.toml'),
	'utf8'
);
const LOCALES = path.join(SP, '_shared', 'data', 'locales');

const errors = [];
let checks = 0;

/**
 * Records one assertion.
 * @param {boolean} cond Holds when the check passes.
 * @param {string} message Failure message.
 */
function check(cond, message) {
	checks++;
	if (!cond) errors.push(message);
}

/**
 * Asserts that parsing a mutated registry throws a message matching `pattern`.
 * @param {string} label Case name.
 * @param {string} source Mutated TOML.
 * @param {RegExp} pattern Expected error text.
 */
function rejects(label, source, pattern) {
	let message = null;
	try {
		parseRegistry(source);
	} catch (err) {
		message = err.message;
	}
	check(
		message !== null,
		`${label}: the generator accepted it — a field nothing reads would be dropped silently`
	);
	if (message !== null) check(pattern.test(message), `${label}: wrong refusal "${message}"`);
}

/**
 * Replaces one exact fragment, failing loudly when the fixture drifted.
 * @param {string} from Fragment present once in the registry.
 * @param {string} to Replacement.
 * @returns {string}
 */
function mutate(from, to) {
	if (SOURCE.split(from).length !== 2) throw new Error(`fixture fragment not unique: ${from}`);
	return SOURCE.replace(from, to);
}

// 1. Strictness.
rejects(
	'unknown field',
	mutate(
		'[sg_actions.lookup]\nplatform = "hs"',
		'[sg_actions.lookup]\nplatform = "hs"\nrequire_hs = ["x"]'
	),
	/unknown field "require_hs"/
);
rejects(
	'unknown platform',
	mutate('[sg_actions.lookup]\nplatform = "hs"', '[sg_actions.lookup]\nplatform = "mac"'),
	/unknown platform "mac"/
);
rejects(
	'unknown parameter kind',
	mutate('parameter = "url"', 'parameter = "uri"'),
	/unknown parameter kind/
);
rejects(
	'requirement token no driver probes',
	mutate(
		'[sg_actions.lookup]\nplatform = "hs"',
		'[sg_actions.lookup]\nplatform = "hs"\nrequires_hs = ["tool:osascript"]'
	),
	/no hs probe/
);
rejects(
	'requirement for an unclaimed platform',
	mutate(
		'[sg_actions.lookup]\nplatform = "hs"',
		'[sg_actions.lookup]\nplatform = "hs"\nrequires_linux = ["session:x11"]'
	),
	/does not claim linux/
);
rejects(
	'ordered id without a table',
	mutate('    "lookup",\n', '    "lookup",\n    "ghost_action",\n'),
	/"ghost_action" has no table/
);
rejects(
	'declared id never ordered',
	mutate('    "lookup",\n', ''),
	/"lookup" is declared but never ordered/
);
rejects(
	'confirm must be boolean',
	mutate(
		'[sg_actions.lookup]\nplatform = "hs"',
		'[sg_actions.lookup]\nplatform = "hs"\nconfirm = "yes"'
	),
	/confirm must be a boolean/
);

// 2. The committed files are exactly what the generator produces.
const generated = generate(SOURCE);
for (const [platform, out] of Object.entries(generated)) {
	const onDisk = fs.readFileSync(path.join(ROOT, OUTPUTS[platform]), 'utf8');
	check(
		onDisk === out.text,
		`${OUTPUTS[platform]} is stale — run npm run codegen:action-catalogue`
	);
}

// 3. Filtering, empty-heading pruning and metadata.
const models = Object.fromEntries(Object.entries(generated).map(([k, v]) => [k, v.model]));
const ids = (m) => m.sgItems.filter((i) => i.kind === 'action').map((i) => i.id);
check(
	ids(models.ahk).length >= 90,
	`ahk lists only ${ids(models.ahk).length} action(s) — the walk collapsed`
);
check(
	ids(models.hs).length >= 90,
	`hs lists only ${ids(models.hs).length} action(s) — the walk collapsed`
);
check(
	ids(models.linux).length >= 60,
	`linux lists only ${ids(models.linux).length} action(s) — the walk collapsed`
);
check(ids(models.ahk).includes('copy') && !ids(models.hs).includes('copy'), 'copy is Windows-only');
check(
	ids(models.hs).includes('lookup') && !ids(models.linux).includes('lookup'),
	'lookup is macOS-only'
);
const navKey = HEADER_KEY_PREFIX + 'navigation';
const hasHeading = (m, key) => m.sgItems.some((i) => i.kind === 'heading' && i.key === key);
check(hasHeading(models.ahk, navKey), 'Windows keeps the Navigation heading over its two rows');
check(!hasHeading(models.hs, navKey), 'macOS must not show an empty Navigation heading');
check(!hasHeading(models.linux, navKey), 'Linux must not show an empty Navigation heading');
for (const [platform, m] of Object.entries(models)) {
	for (let i = 0; i < m.sgItems.length; i++) {
		const item = m.sgItems[i];
		if (item.kind !== 'heading') continue;
		const next = m.sgItems[i + 1];
		check(
			next !== undefined && !(next.kind === 'heading' && next.level <= item.level),
			`${platform}: heading ${item.key} has nothing under it`
		);
	}
	const chords = m.sgItems.filter((i) => i.kind === 'modifier_chords');
	check(
		chords.length === 1 && chords[0].groupKey === CHORD_GROUP_KEY && chords[0].level === 2,
		`${platform}: exactly one level-2 modifier-chord block keyed on ${CHORD_GROUP_KEY}`
	);
	check(
		m.actions.open_url && m.actions.open_url.parameter === 'url',
		`${platform}: open_url keeps its url parameter`
	);
	check(
		m.actions.search_web && m.actions.search_web.parameter === 'search_url',
		`${platform}: search_web keeps its search_url parameter`
	);
	for (const id of ids(m))
		check(Boolean(m.actions[id]), `${platform}: listed "${id}" has no metadata`);
}
check(
	models.hs.axItems.length >= 10 &&
		models.ahk.axItems.length === 0 &&
		models.linux.axItems.length === 0,
	'only macOS dispatches an axis, so only its catalogue may list one'
);
check(
	JSON.stringify(models.linux.actions.left_click_toggle.requires) ===
		JSON.stringify(['session:x11', 'tool:xdotool']),
	'Linux left_click_toggle carries its requirements'
);
check(!models.ahk.actions.left_click_toggle.requires, 'requirements stay per-OS');
check(
	models.hs.karabinerAliases && models.hs.karabinerAliases.return === 'enter',
	'macOS keeps the Karabiner aliases'
);
check(
	models.linux.slots && models.linux.slots.single.includes('tap_3'),
	'Linux carries the gesture slot-space'
);

// 4. Every heading and label key resolves in every locale, and none is French
//    outside fr.json.
const localeFiles = fs.readdirSync(LOCALES).filter((f) => f.endsWith('.json'));
check(localeFiles.length === 21, `expected 21 locales, found ${localeFiles.length}`);
const keys = new Set([CHORD_GROUP_KEY]);
for (const m of Object.values(models)) {
	for (const item of m.sgItems) if (item.kind === 'heading') keys.add(item.key);
	for (const a of Object.values(m.actions)) keys.add(a.labelKey);
}
check(keys.size >= 150, `only ${keys.size} key(s) collected — the catalogue walk collapsed`);
for (const f of localeFiles) {
	const code = f.replace(/\.json$/, '');
	const strings = JSON.parse(fs.readFileSync(path.join(LOCALES, f), 'utf8'));
	for (const key of keys) {
		const value = strings[key];
		check(
			typeof value === 'string' && value.replace(/^#+/, '').trim() !== '',
			`${code}: "${key}" has no value`
		);
		if (typeof value === 'string' && code !== 'fr' && key.startsWith(HEADER_KEY_PREFIX)) {
			check(!/Raccourcis/.test(value), `${code}: heading "${key}" is French ("${value}")`);
		}
	}
	check(
		typeof strings[CHORD_GROUP_KEY] === 'string' && strings[CHORD_GROUP_KEY].includes('{1}'),
		`${code}: ${CHORD_GROUP_KEY} must place the modifier label with {1}`
	);
}
check(!/"#+Raccourcis/.test(SOURCE), 'actions.toml must not carry a literal French heading');

// 5. The per-driver runtime parity tests exist and are wired. Windows lists
//    its tests one #Include at a time; the Lua runners discover test_*.lua.
const PARITY_SLUG = '(action-catalogue-parity)';
const PARITY_TESTS = [
	'windows/tests/unit/test_gestures.ahk',
	'macos/tests/unit/modules/gestures/test_action_catalogue_parity.lua',
	'linux/tests/unit/modules/test_action_catalogue_parity.lua'
];
for (const rel of PARITY_TESTS) {
	const abs = path.join(SP, rel);
	check(
		fs.existsSync(abs) && fs.readFileSync(abs, 'utf8').includes(PARITY_SLUG),
		`${rel} must carry the runtime catalogue parity test ${PARITY_SLUG}`
	);
}
const runAll = fs.readFileSync(path.join(SP, 'windows', 'tests', 'run_all.ahk'), 'utf8');
check(
	/^#Include unit\/test_gestures\.ahk$/m.test(runAll),
	'run_all.ahk must include unit/test_gestures.ahk'
);

// 6. The website reads the same canonical registry.
const SITE_LOADER = fs.readFileSync(
	path.join(ROOT, 'src', 'routes', 'ergopti-plus', '+page.server.js'),
	'utf8'
);
check(
	/ACTIONS_ROOT[\s\S]*?modules[/\\]actions/.test(SITE_LOADER) &&
		/resolve\(ACTIONS_ROOT,\s*'actions\.toml'\)/.test(SITE_LOADER),
	'the Ergopti+ site must read the canonical modules/actions/actions.toml registry'
);
check(
	!/modules[/\\]gestures/.test(SITE_LOADER),
	'the Ergopti+ site still reads the retired shared modules/gestures path'
);

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] action catalogue codegen:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}
console.log(`\x1b[32m[OK] action catalogue codegen: ${checks} check(s) passed.\x1b[0m`);
