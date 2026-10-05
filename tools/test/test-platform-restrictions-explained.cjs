// tools/test/test-platform-restrictions-explained.cjs

/**
 * ==============================================================================
 * MODULE: Platform-Coverage Report and Ratchet (I2)
 * DESCRIPTION:
 * Every declaration that restricts a feature or a menu row to one platform is
 * counted, classified, and — once it carries no `reason_key` — frozen. Run with
 * `--report` to print the full inventory.
 *
 * THE INVARIANT:
 * "A feature missing on a platform carries a translated `reason_key`."
 * Canonical menu presentations explicitly classified HIDE are not applicable
 * on the omitted platforms and owe no reason. This exception never applies
 * to feature or section capabilities, or to unclassified legacy restrictions.
 *
 * WHY THE BASELINE ROSE FROM 76 TO 142 ON 2026-08-02 — READ THIS BEFORE
 * TREATING IT AS A REGRESSION:
 * Not one feature changed availability. What changed is that the driver silos
 * were dissolved, and with them the excuse that was hiding two thirds of the
 * population.
 *
 * The rule has always been that a table restating the restriction its own
 * enclosing section already declares says nothing new. Before Lot 4 that
 * enclosing section was `sections.ahk.*`, so every AHK-only feature in the AHK
 * silo was an artifact by construction — 127 of them, excused on the shape of
 * the file rather than on anything true about the product. The user still met
 * every one of those missing rows; the gate simply was not counting them.
 *
 * After Lot 4 a feature lives under `sections.shortcuts` (ahk + hs) and states
 * `platforms = ["ahk"]` itself. Same feature, same availability, same missing
 * row — now visible to the count. The artifact rule survives in the form that
 * was always the honest one: a restriction the enclosing section already makes
 * is still excluded, because the user meets ONE missing submenu rather than
 * fourteen missing rows inside a submenu they never see.
 *
 * So 76 was an undercount and 142 is the measurement. Lowering it means writing
 * reasons, not restoring a namespace.
 *
 * WHY A RATCHET AND NOT A REQUIREMENT:
 * Requiring all 142 now means 142 new locale keys across 21 locales — nearly
 * 3 000 translated strings, in 19 languages nobody here can check. Machine-
 * filling them would put unverifiable text in front of users in every language,
 * which is worse than the silence it replaces. The count is frozen instead: a
 * NEW platform restriction must explain itself, and the existing ones can be
 * described as they are revisited. Lower this baseline as reasons are written.
 * Never raise it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const MANIFEST = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'modules',
	'features',
	'manifest.toml'
);

// Frozen on 2026-08-02 at 142: 87 features + 45 menu rows + 10 sections
// restricted to one platform with no reason_key. 127 restrictions that a parent
// section already makes are excluded by construction — see the header for why
// this is 142 rather than the 76 measured under the driver silos.
//
// 2026-08-03: 142 → 139. Three came off together, and it is the first time this
// number has moved at all, because until that day it could not: `reason_key` had
// no reader anywhere in the repo, and the generator did not even emit it — each
// driver's generated manifest carries only the features it HAS, so a driver
// could not enumerate its own absences, let alone explain one. Writing reasons
// into that would have been writing configuration nothing could ever read.
// The chain now exists (generator → manifest_reader.coverage_gaps() →
// healthcheck), and `script.alt_gr_is_kana_remap` is the first one written
// through it end to end.
//
// 2026-08-04: 139 → 138. `llm.models.mlx`, on the same criterion as the first:
// MLX is Apple's on-device inference framework, built on Metal and Apple
// Silicon's unified memory, and no Windows or Linux build of it exists. The
// restriction therefore stays true however much of this repository gets written,
// which is the test — a reason is only writable when it survives the assumption
// that everything else is finished.
//
// A candidate that looked far larger was rejected the same day, and it is worth
// recording so nobody re-derives it: the 34 hs-only `features.gestures` entries
// would drop this number to 105 for one shared key. But `platforms = ["hs"]`
// excludes Linux as well as Windows, and the Linux driver ships the gestures
// module, its menu and its defaults — what it has no reader for is touch input,
// which manager.lua's own header calls a TODO. So the Linux half of that reason
// would read "not coded yet", the one thing the model reason forbids, and 21
// translated strings would have frozen it in place.
const BASELINE = 104;

// 2026-10-05: the original1794 source (SHA256 below) contained136 debt rows,
// despite its138 allowance.31 were already canonical MENU-HIDE declarations;
// the existing user_models capability now has its truthful translated reason.
// Keep the104 other original semantic identities, including every anonymous
// separator's original ordinal. A new debt cannot replace a retired old debt.
const PARENT_MANIFEST_SHA256 = '06b311ca65d356b405a889fb3479538b24505649a47e1d628299bf6611a5eb59';
const PARENT_GATE_SHA256 = '872a8889a8767accdf5fdd3cd687da8726073741d9945df27d43ecd9990de290';
const KNOWN_UNEXPLAINED = new Set([
	'["features.gestures","hs","action","swipe_2_diag",null,null,null,null]',
	'["features.gestures","hs","action","swipe_3_diag",null,null,null,null]',
	'["features.gestures","hs","action","swipe_4_diag",null,null,null,null]',
	'["features.gestures","hs","action","swipe_5_diag",null,null,null,null]',
	'["features.hotstrings","hs","boolean","enabled",null,null,null,null]',
	'["features.hotstrings","hs","number","expansion_delay",null,null,null,null]',
	'["features.layout","ahk","boolean","ctrl_magic_save",null,null,null,null]',
	'["features.layout","ahk","boolean","ergopti_alt_gr",null,null,null,null]',
	'["features.layout","ahk","boolean","ergopti_base",null,null,null,null]',
	'["features.layout","ahk","boolean","ergopti_plus",null,null,null,null]',
	'["features.layout","ahk","string","emulated_layout",null,null,null,null]',
	'["features.layout","hs","boolean","on_pause",null,null,null,null]',
	'["features.layout","hs","boolean","on_resume",null,null,null,null]',
	'["features.layout","hs","boolean","pause_switch_enabled",null,null,null,null]',
	'["features.llm","ahk","boolean","onboarding_seen",null,null,null,null]',
	'["features.llm","ahk","string","app_profile_overrides",null,null,null,null]',
	'["features.llm.navigation","hs","boolean","arrow_nav_enabled",null,null,null,null]',
	'["features.llm.profiles","hs","array","user_profiles",null,null,null,null]',
	'["features.llm.trigger","ahk","boolean","inline_autotype",null,null,null,null]',
	'["features.llm.trigger","hs","array","disabled_apps",null,null,null,null]',
	'["features.metrics","ahk","array","metrics_disabled_apps",null,null,null,null]',
	'["features.metrics","ahk","boolean","metrics_enabled",null,null,null,null]',
	'["features.metrics","ahk","boolean","metrics_wpm_menubar_colors",null,null,null,null]',
	'["features.metrics","ahk","number","wpm_widget_x",null,null,null,null]',
	'["features.metrics","ahk","number","wpm_widget_y",null,null,null,null]',
	'["features.metrics","hs","array","disabled_apps",null,null,null,null]',
	'["features.metrics","hs","boolean","float_colors",null,null,null,null]',
	'["features.metrics","hs","boolean","float_graph",null,null,null,null]',
	'["features.metrics","hs","boolean","float_wpm",null,null,null,null]',
	'["features.metrics","hs","boolean","menubar_colors",null,null,null,null]',
	'["features.metrics","hs","boolean","menubar_wpm",null,null,null,null]',
	'["features.metrics","linux","boolean","wpm_menubar_colors",null,null,null,null]',
	'["features.metrics","linux","boolean","wpm_menubar_visible",null,null,null,null]',
	'["features.shortcuts","ahk","boolean","get_hex_value",null,null,null,null]',
	'["features.shortcuts","ahk","boolean","microsoft_bold",null,null,null,null]',
	'["features.shortcuts","ahk","boolean","move",null,null,null,null]',
	'["features.shortcuts","ahk","boolean","open_downloads",null,null,null,null]',
	'["features.shortcuts","ahk","boolean","paste_without_formatting",null,null,null,null]',
	'["features.shortcuts","ahk","boolean","screen",null,null,null,null]',
	'["features.shortcuts","ahk","boolean","select_line",null,null,null,null]',
	'["features.shortcuts","ahk","boolean","spotlight_mouse",null,null,null,null]',
	'["features.shortcuts","ahk","boolean","surround_with_parentheses",null,null,null,null]',
	'["features.shortcuts","ahk","boolean","teleport_mouse",null,null,null,null]',
	'["features.shortcuts","ahk","boolean","title_case",null,null,null,null]',
	'["features.shortcuts","ahk","boolean","uppercase",null,null,null,null]',
	'["features.shortcuts","ahk","boolean","win_caps_lock",null,null,null,null]',
	'["features.shortcuts","ahk","feature","gpt",null,null,null,null]',
	'["features.shortcuts","ahk","feature","search",null,null,null,null]',
	'["features.shortcuts","ahk","feature","take_note",null,null,null,null]',
	'["features.shortcuts.a_grave","ahk","boolean","enabled",null,null,null,null]',
	'["features.shortcuts.a_grave","ahk","string","letter",null,null,null,null]',
	'["features.shortcuts.e_acute","ahk","boolean","enabled",null,null,null,null]',
	'["features.shortcuts.e_acute","ahk","string","letter",null,null,null,null]',
	'["features.shortcuts.e_circ","ahk","boolean","enabled",null,null,null,null]',
	'["features.shortcuts.e_circ","ahk","string","letter",null,null,null,null]',
	'["features.shortcuts.e_grave","ahk","boolean","enabled",null,null,null,null]',
	'["features.shortcuts.e_grave","ahk","string","letter",null,null,null,null]',
	'["features.shortcuts.keyboard","hs","action","hs_ctrl_space",null,null,null,null]',
	'["features.shortcuts.keyboard","linux","action","ctrl_g",null,null,null,null]',
	'["features.shortcuts.keyboard","linux","action","super_space",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","cmd_shift_v",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","cmd_star",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_a",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_capslock",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_d",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_e",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_g",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_h",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_i",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_l",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_m",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_o",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_p",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_period",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_quote",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_s",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_t",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_u",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_w",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","ctrl_x",null,null,null,null]',
	'["features.shortcuts.keys","hs","boolean","wrap_text_if_selected",null,null,null,null]',
	'["menu.accented_letters_group","ahk","letter_picker","a_grave",null,null,null,null]',
	'["menu.accented_letters_group","ahk","letter_picker","e_acute",null,null,null,null]',
	'["menu.accented_letters_group","ahk","letter_picker","e_circ",null,null,null,null]',
	'["menu.accented_letters_group","ahk","letter_picker","e_grave",null,null,null,null]',
	'["menu.apps_menu","hs","list","apps_installed",null,null,null,null]',
	'["menu.gestures_menu","hs","---",null,null,null,null,10]',
	'["menu.gestures_menu","hs","---",null,null,null,null,12]',
	'["menu.gestures_menu","hs","---",null,null,null,null,14]',
	'["menu.gestures_menu","linux","---",null,null,null,null,18]',
	'["menu.hotstrings_menu","linux","---",null,null,null,null,19]',
	'["menu.layout_menu","hs","---",null,null,null,null,11]',
	'["menu.llm_menu","linux","---",null,null,null,null,6]',
	'["menu.metrics_menu","linux","---",null,null,null,null,20]',
	'["menu.tap_holds_menu","hs","---",null,null,null,null,5]',
	'["sections.category_enabled","ahk",null,null,null,null,null,null]',
	'["sections.gestures.modes","hs",null,null,null,null,null,null]',
	'["sections.gestures.sensitivities","hs",null,null,null,null,null,null]',
	'["sections.hotstrings.order_overrides","hs",null,null,null,null,null,null]',
	'["sections.shortcuts.key_combination_taps","ahk",null,null,null,null,null,null]',
	'["sections.shortcuts.keyboard","ahk",null,null,null,null,null,null]',
	'["sections.shortcuts.personal","ahk",null,null,null,null,null,null]',
	'["sections.shortcuts.wrap_symbols","hs",null,null,null,null,null,null]',
	'["sections.ui","hs",null,null,null,null,null,null]'
]);

if (KNOWN_UNEXPLAINED.size !== BASELINE)
	throw new Error('the original unexplained identity ledger must contain exactly104 distinct rows');

// Floor: retain the original complete-inventory safeguard.
const MIN_TABLES = 300;
const TABLE_HEADER = /^(\[+)([A-Za-z0-9_.]+)(\]+)\s*$/;
const { parse: parseToml } = require('smol-toml');
const {
	classifyMenuRow,
	validateMenuAvailability,
	validateChildTemplates
} = require('../lib/menu-row-availability.cjs');

/** Stable role and identity; anonymous rows retain their original multiplicity. */
function restrictionIdentity(owner) {
	const row = owner.row;
	return JSON.stringify([
		owner.name,
		row.platforms[0],
		row.type ?? null,
		row.id ?? null,
		row.path ?? null,
		row.i18n ?? null,
		row.category ?? null,
		row.id === undefined &&
		row.path === undefined &&
		row.i18n === undefined &&
		owner.index !== undefined
			? owner.index
			: null
	]);
}

/** Enumerates parsed TOML owners, including children of array-of-table entries. */
function readCoverage(src) {
	const parsed = parseToml(src);
	if (!parsed.menu || typeof parsed.menu !== 'object' || Array.isArray(parsed.menu))
		throw new Error('manifest.toml is missing the [menu] tables');
	validateMenuAvailability(parsed.menu);
	validateChildTemplates(parsed.menu);
	const menuRows = new Set(Object.values(parsed.menu).filter(Array.isArray).flat());
	const tables = [];
	function walk(node, name) {
		if (Array.isArray(node)) {
			for (const [index, row] of node.entries()) {
				if (!row || typeof row !== 'object' || Array.isArray(row)) continue;
				tables.push({ name, row, index });
				for (const [key, value] of Object.entries(row))
					if (value && typeof value === 'object') walk(value, name + '.' + key);
			}
			return;
		}
		if (!node || typeof node !== 'object') return;
		if (name) tables.push({ name, row: node });
		for (const [key, value] of Object.entries(node))
			if (value && typeof value === 'object') walk(value, name ? name + '.' + key : key);
	}
	walk(parsed, '');
	const sectionRestriction = new Map();
	for (const owner of tables) {
		const plats = owner.row.platforms;
		if (
			owner.name.startsWith('sections.') &&
			Array.isArray(plats) &&
			plats.length === 1 &&
			plats[0] !== 'both'
		)
			sectionRestriction.set(owner.name.slice('sections.'.length), plats[0]);
	}
	function sectionPlatform(tableName) {
		const parts = tableName.split('.');
		parts.shift();
		if (tableName.startsWith('sections.')) parts.pop();
		while (parts.length > 0) {
			const hit = sectionRestriction.get(parts.join('.'));
			if (hit) return hit;
			parts.pop();
		}
		return null;
	}
	const real = [],
		artifacts = [],
		notApplicable = [];
	for (const owner of tables) {
		const row = owner.row;
		const plats = row.platforms;
		// Preserve I2's single-platform scope. This does not reclassify legacy
		// two-platform declarations or their debt in this bounded correction.
		if (!Array.isArray(plats) || plats.length !== 1 || plats[0] === 'both') continue;
		if (!['ahk', 'hs', 'linux'].includes(plats[0]))
			throw new Error(`${owner.name}: unknown restricted platform "${plats[0]}"`);
		const entry = {
			name: owner.name,
			platform: plats[0],
			identity: restrictionIdentity(owner),
			explained: typeof row.reason_key === 'string' && row.reason_key !== ''
		};
		// Only direct parsed [menu.*] array rows have a menu declaration owner.
		// A feature/section/legacy row with an unavailable token is never exempt.
		if (
			owner.name.startsWith('menu.') &&
			menuRows.has(row) &&
			classifyMenuRow(row, owner.name) === 'not-applicable'
		) {
			notApplicable.push(entry);
			continue;
		}
		(sectionPlatform(owner.name) === plats[0] ? artifacts : real).push(entry);
	}
	return {
		tables,
		tableHeaderCount: src.split(/\r?\n/).filter((line) => TABLE_HEADER.test(line)).length,
		real,
		artifacts,
		notApplicable,
		unexplained: real.filter((entry) => !entry.explained)
	};
}

/** Holds both the original count bound and the independently frozen identities. */
function coverageErrors(coverage) {
	const errors = [];
	const measuredTables = Math.min(coverage.tables.length, coverage.tableHeaderCount);
	if (measuredTables < MIN_TABLES)
		errors.push(
			`parsed only ${measuredTables} table(s) (floor ${MIN_TABLES}) — ` +
				'the scan is broken, and this ratchet would then find no restrictions at all and pass'
		);
	if (coverage.unexplained.length > BASELINE)
		errors.push(
			`platform restrictions with no reason_key rose to ${coverage.unexplained.length} ` +
				`(baseline ${BASELINE}). Add reason_key (and its locale entry in all 21 catalogues). ` +
				'Do NOT raise the baseline.'
		);
	const seen = new Set();
	for (const entry of coverage.unexplained) {
		if (seen.has(entry.identity)) errors.push(`duplicate unexplained identity: ${entry.identity}`);
		seen.add(entry.identity);
		if (!KNOWN_UNEXPLAINED.has(entry.identity))
			errors.push(
				`new unexplained platform restriction: ${entry.identity}. ` +
					"Explain the capability; do not spend a retired restriction's budget."
			);
	}
	return errors;
}

function run() {
	if (!fs.existsSync(MANIFEST)) {
		console.error('\x1b[31m[ERROR] manifest.toml is missing.\x1b[0m');
		return 1;
	}
	let coverage;
	try {
		coverage = readCoverage(fs.readFileSync(MANIFEST, 'utf8'));
	} catch (error) {
		console.error('\x1b[31m[ERROR] platform coverage:\x1b[0m');
		console.error('    - ' + error.message);
		return 1;
	}
	const errors = coverageErrors(coverage);
	if (process.argv.includes('--report')) {
		console.log(
			`Platform-coverage report — ${coverage.real.length} real restriction(s), ` +
				`${coverage.real.length - coverage.unexplained.length} explained, ` +
				`${coverage.unexplained.length} not; ${coverage.notApplicable.length} not applicable.\n`
		);
		for (const entry of [...coverage.real, ...coverage.notApplicable])
			console.log(
				`  ${coverage.notApplicable.includes(entry) ? 'hide' : entry.explained ? '✓' : ' '} ` +
					`${entry.platform.padEnd(6)} ${entry.identity}`
			);
		console.log(`  ${coverage.artifacts.length} section restatement(s) excluded.`);
		console.log(`  Original debt source: ${PARENT_MANIFEST_SHA256}; gate: ${PARENT_GATE_SHA256}.`);
	}
	if (errors.length) {
		console.error('\x1b[31m[ERROR] platform coverage:\x1b[0m');
		for (const error of errors) console.error('    - ' + error);
		return 1;
	}
	console.log(
		`\x1b[32m[OK] platform restrictions without a reason: ` +
			`${coverage.unexplained.length}/${BASELINE} (${coverage.real.length} real, ` +
			`${coverage.artifacts.length} section restatement(s) excluded, ` +
			`${coverage.notApplicable.length} not applicable).\x1b[0m`
	);
	return 0;
}

module.exports = { readCoverage, coverageErrors, restrictionIdentity };
if (require.main === module) process.exitCode = run();
