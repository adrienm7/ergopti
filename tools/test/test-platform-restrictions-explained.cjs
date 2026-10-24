// tools/test/test-platform-restrictions-explained.cjs

/**
 * ==============================================================================
 * MODULE: Platform-Coverage Report and Ratchet (I2)
 * DESCRIPTION:
 * Every declaration whose `platforms` leaves out one or two of the three
 * drivers — a feature, a section, a menu row, an onboarding control — is
 * counted, classified, and — once it carries no `reason_key` — frozen. Run with
 * `--report` to print the full inventory.
 *
 * THE INVARIANT:
 * "A feature missing on a platform carries a translated `reason_key`."
 * Canonical menu presentations explicitly classified HIDE are not applicable
 * on the omitted platforms and owe no reason. This exception never applies
 * to feature or section capabilities, or to unclassified legacy restrictions.
 * A preset of an onboarding choice owes no reason of its own when the choice
 * declares a `validation` policy for every platform the preset leaves out:
 * that policy refuses the value there, and its refusal text is the reason.
 *
 * TWO-PLATFORM RESTRICTIONS (2026-10-24): the ratchet first counted only the
 * declarations restricted to one platform. A feature on two drivers is just as
 * absent on the third, so the same rule now covers both shapes; a restriction
 * equal to its enclosing section's, of either shape, is still a restatement.
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
// 2026-10-20: 104 → 103. The Layout menu's macOS-only separator before the
// active input sources is a presentation, now classified unavailable = "hide".
// 2026-10-24: 88 → 1. The ledger below is no longer a list of silences. Every other
// single-platform feature, section and menu row now carries a reason that says what the
// platform does differently (checked against the code when it was written), and the four
// swipe_N_diag slots that no driver ever read were deleted instead of explained. The one
// left, the macOS-only array of user profiles, goes with the unification of the stored
// shape. Never raise it.
// 2026-10-24: 1 → 0. macOS stores its user profiles in llm.user_profiles like Windows
// and Linux; its own [llm.profiles] user_profiles array is gone.
// 2026-10-24: 0 → 1 after the two-platform count, and the rise is a measurement, not a new restriction. The count now
// includes the restrictions to two platforms; thirteen had no reason. Seven now carry the
// reason of what the third driver does instead (the two master switches Windows keeps in
// category_enabled, the key combinations macOS keeps with Karabiner, the macOS shortcut
// key that wraps a selection, the menubar readout Windows draws as a widget). The Layout
// section was wrong, since Linux has its number-row settings, and now lists every driver.
// Two separators Linux left out are drawn there as well, and the two magic-key presets
// Linux leaves out are refused there by the declared validation policy. The one entered
// in the ledger, the AI-profile section, is a wrong declaration rather than a missing
// reason: macOS stores the active profile and the prediction count under the same
// llm.profiles keys (infra/preferences.lua), so no true reason exists. Opening it to
// macOS adds both keys to the macOS AI scope, a behaviour change that goes with the
// manifest-matches-readers work once the macOS AI scope suite is green again.
// 2026-10-24: 1 → 3 on integration. The macOS user profiles moved to llm.user_profiles
// while the two-platform count landed, so these two AI rows now restrict macOS without a
// reason; like the AI-profile section they are wrong declarations to open to macOS.
const BASELINE = 3;

// 2026-10-05: the original1794 source (SHA256 below) contained136 debt rows,
// despite its138 allowance.31 were already canonical MENU-HIDE declarations;
// the existing user_models capability now has its truthful translated reason.
// Keep the104 other original semantic identities, including every anonymous
// separator's original ordinal. A new debt cannot replace a retired old debt.
const PARENT_MANIFEST_SHA256 = '06b311ca65d356b405a889fb3479538b24505649a47e1d628299bf6611a5eb59';
const PARENT_GATE_SHA256 = '872a8889a8767accdf5fdd3cd687da8726073741d9945df27d43ecd9990de290';
const KNOWN_UNEXPLAINED = new Set([
	'["features.llm","ahk,linux","string","user_profiles",null,null,null,null]',
	'["features.llm.profiles","ahk,linux","boolean","auto_profile_for_model",null,null,null,null]',
	'["sections.llm.profiles","ahk,linux",null,null,null,null,null,null]'
]);

if (KNOWN_UNEXPLAINED.size !== BASELINE)
	throw new Error(
		'the original unexplained identity ledger must contain exactly BASELINE distinct rows'
	);

// Floor: retain the original complete-inventory safeguard.
const MIN_TABLES = 300;
const TABLE_HEADER = /^(\[+)([A-Za-z0-9_.]+)(\]+)\s*$/;
const { parse: parseToml } = require('smol-toml');
const {
	classifyMenuRow,
	validateMenuAvailability,
	validateChildTemplates
} = require('../lib/menu-row-availability.cjs');

const PLATFORMS = ['ahk', 'hs', 'linux'];

/** The sorted platform set a restriction keeps, or null when it keeps all three. */
function restrictedTo(platforms, where) {
	if (!Array.isArray(platforms) || platforms.length === 0) return null;
	for (const platform of platforms)
		if (!PLATFORMS.includes(platform))
			throw new Error(`${where}: unknown restricted platform "${platform}"`);
	if (new Set(platforms).size !== platforms.length)
		throw new Error(`${where}: platforms repeats a driver`);
	return platforms.length < PLATFORMS.length ? [...platforms].sort().join(',') : null;
}

/**
 * True for a preset in a choice's `options` whose every left-out platform has a
 * `validation` policy on that choice: the policy refuses the value there, so the
 * preset is a value that platform does not accept, not a missing capability.
 */
function refusedByValidation(owner) {
	const choice = owner.parent;
	if (!choice || !Array.isArray(choice.options) || !choice.options.includes(owner.row))
		return false;
	const policies = choice.validation;
	if (!policies || typeof policies !== 'object' || Array.isArray(policies)) return false;
	return PLATFORMS.filter((platform) => !owner.row.platforms.includes(platform)).every(
		(platform) => typeof policies[platform] === 'string' && policies[platform] !== ''
	);
}

/** Stable role and identity; anonymous rows retain their original multiplicity. */
function restrictionIdentity(owner) {
	const row = owner.row;
	return JSON.stringify([
		owner.name,
		[...row.platforms].sort().join(','),
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
	const english = JSON.parse(
		fs.readFileSync(path.join(ROOT, 'static/ergopti_plus/_shared/data/locales/en.json'), 'utf8')
	);
	validateChildTemplates(parsed.menu, (key) =>
		Object.hasOwn(english, key) ? english[key] : undefined
	);
	const menuRows = new Set(Object.values(parsed.menu).filter(Array.isArray).flat());
	const tables = [];
	// `parent` is the table holding the array a row belongs to, so a preset can
	// be read against the choice that declares its validation policy.
	function walk(node, name, parent) {
		if (Array.isArray(node)) {
			for (const [index, row] of node.entries()) {
				if (!row || typeof row !== 'object' || Array.isArray(row)) continue;
				tables.push({ name, row, index, parent });
				for (const [key, value] of Object.entries(row))
					if (value && typeof value === 'object') walk(value, name + '.' + key, row);
			}
			return;
		}
		if (!node || typeof node !== 'object') return;
		if (name) tables.push({ name, row: node, parent });
		for (const [key, value] of Object.entries(node))
			if (value && typeof value === 'object') walk(value, name ? name + '.' + key : key, node);
	}
	walk(parsed, '');
	const sectionRestriction = new Map();
	for (const owner of tables) {
		const kept = restrictedTo(owner.row.platforms, owner.name);
		if (owner.name.startsWith('sections.') && kept)
			sectionRestriction.set(owner.name.slice('sections.'.length), kept);
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
		const kept = restrictedTo(row.platforms, owner.name);
		if (!kept) continue;
		const entry = {
			name: owner.name,
			platform: kept,
			identity: restrictionIdentity(owner),
			explained:
				(typeof row.reason_key === 'string' && row.reason_key !== '') || refusedByValidation(owner)
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
		(sectionPlatform(owner.name) === kept ? artifacts : real).push(entry);
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
