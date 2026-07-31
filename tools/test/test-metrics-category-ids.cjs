// tools/test/test-metrics-category-ids.cjs

/**
 * ==============================================================================
 * MODULE: Metrics Category Identity Guard
 * DESCRIPTION:
 * The app-time dashboard colours each category from a fixed table. That table
 * used to be keyed by the FRENCH LABEL, which made the colour a property of the
 * translation rather than of the category.
 *
 * ROOT CAUSE ENCODED:
 * Two consequences, one already live before this guard existed. 'Graphics
 * design' displays as "Design graphique", but the colour table held "Design", so
 * that category silently lost its lavender and fell through to the hash palette
 * — a mismatch nobody can see, because both spellings look correct. And
 * translating the dashboard would have dropped EVERY fixed colour at once, since
 * not one key would match any more.
 *
 * The category is also PERSISTED: a user override is written to
 * app_categories.json, and the default written there is itself localised. So the
 * file on disk already depends on which language was active when it was written.
 * A user who switches language must not find their overrides orphaned and their
 * charts recoloured, which is what a bare rename would have caused.
 *
 * This asserts the identity model rather than the spelling: colours are keyed by
 * the stable English id, every French label and every historical spelling still
 * resolves to its id, and an unknown category passes through so a user-invented
 * one keeps working.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SCRIPT = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'ui', 'metrics_apps', 'script.js');

const src = fs.readFileSync(SCRIPT, 'utf8');

// Evaluate only the declarations this guard needs, up to the first line that
// touches the DOM or the host bridge.
const cut = src.indexOf('const postBridge');
if (cut < 0) throw new Error('script.js no longer defines postBridge — update the slice point');
const prelude = src.slice(0, cut);

// The prelude reads `window` for host-injected data. A minimal stand-in is
// enough — this guard is about the category tables, and giving it a real DOM
// would couple it to whatever the dashboard renders next.
const ALIASES_FILE = path.join(
	ROOT, 'static', 'ergopti_plus', '_shared', 'data', 'metrics_general_category_aliases.json'
);
const CORPUS_FILE = path.join(
	ROOT, 'static', 'ergopti_plus', '_shared', 'tests', 'corpus', 'metrics', 'app_categories_vectors.json'
);

const aliasDoc = JSON.parse(fs.readFileSync(ALIASES_FILE, 'utf8'));
const corpus = JSON.parse(fs.readFileSync(CORPUS_FILE, 'utf8'));

const sandbox = new Function(
	'window',
	'document',
	`${prelude}\nreturn { MAC_CATEGORIES_FR, FIXED_CAT_COLORS, LABEL_TO_CATEGORY_ID, categoryId, getCategoryColor, CHART_PALETTE };`
);
const { MAC_CATEGORIES_FR, FIXED_CAT_COLORS, categoryId, getCategoryColor } = sandbox(
	{ ManifestData: {}, GeneralCategoryAliases: aliasDoc.aliases, addEventListener() {} },
	{ addEventListener() {}, getElementById: () => null, querySelectorAll: () => [] }
);

const errors = [];

function check(cond, msg) {
	if (!cond) errors.push(msg);
}

// 1. The colour table is keyed by IDs, never by a translated label.
for (const key of Object.keys(FIXED_CAT_COLORS)) {
	check(
		Object.prototype.hasOwnProperty.call(MAC_CATEGORIES_FR, key),
		`FIXED_CAT_COLORS key "${key}" is not a category id — it must be one of the keys of ` +
			'MAC_CATEGORIES_FR, or the colour belongs to a spelling rather than to a category'
	);
}

// 2. Every id and every French label resolves to the id.
for (const [id, fr] of Object.entries(MAC_CATEGORIES_FR)) {
	check(categoryId(id) === id, `categoryId("${id}") must be the identity for an id`);
	check(
		categoryId(fr) === id,
		`categoryId("${fr}") must resolve to "${id}" — a stored French override must survive a ` +
			'language switch, and the file on disk is already localised'
	);
}

// 3. The historical spelling that caused the live bug still resolves.
check(
	categoryId('Design') === 'Graphics design',
	'"Design" was the old colour key for Graphics design and may be on disk — it must still resolve'
);

// 4. Graphics design gets its fixed colour, under BOTH spellings. This is the
//    bug: the label and the colour key disagreed, so it never did.
const lavender = FIXED_CAT_COLORS['Graphics design'];
check(!!lavender, 'Graphics design must have a fixed colour');
for (const spelling of ['Graphics design', 'Design graphique', 'Design']) {
	check(
		getCategoryColor(spelling, 0) === lavender,
		`getCategoryColor("${spelling}") must be the fixed Graphics-design colour ${lavender}, ` +
			'not a hashed palette entry'
	);
}

// 5. A category keeps ONE colour across spellings — the whole point of the id.
for (const [id, fr] of Object.entries(MAC_CATEGORIES_FR)) {
	check(
		getCategoryColor(id, 0) === getCategoryColor(fr, 0),
		`"${id}" and "${fr}" are the same category and must render the same colour`
	);
}

// 6. An unknown category still works, and is stable across calls.
const invented = 'Ma catégorie perso';
check(categoryId(invented) === invented, 'an unknown category must pass through unchanged');
check(
	getCategoryColor(invented, 0) === getCategoryColor(invented, 0),
	'an unknown category must hash to a stable colour'
);

// 7. Scores still win over any colour lookup.
check(getCategoryColor('Productivity', 1) === '#30D158', 'a positive score must render green');
check(getCategoryColor('Productivity', -1) === '#FF453A', 'a negative score must render red');

// 8. The generated alias file must still match the locales. Regenerating is one
//    command; a stale list silently orphans the overrides of whichever language
//    was added or corrected since.
const { collect } = require('../build/gen-metrics-category-aliases.cjs');
const live = collect();
for (const [code, label] of Object.entries(live)) {
	check(
		aliasDoc.by_locale[code] === label,
		`metrics_general_category_aliases.json is stale for "${code}": file says ` +
			`${JSON.stringify(aliasDoc.by_locale[code])}, locale says ${JSON.stringify(label)}. ` +
			'Run `node tools/build/gen-metrics-category-aliases.cjs`.'
	);
}
check(
	Object.keys(aliasDoc.by_locale).length === Object.keys(live).length,
	`the alias file covers ${Object.keys(aliasDoc.by_locale).length} locale(s), the tree ships ` +
		`${Object.keys(live).length} — regenerate it`
);

// 9. The corpus: every stored spelling, in every shipped language, resolves to
//    the id its vector expects. This is the file a real user has on disk.
check(
	corpus.vectors.length >= 20,
	`the corpus holds only ${corpus.vectors.length} vector(s) — it must cover every locale`
);
for (const v of corpus.vectors) {
	for (const [app, storedEntry] of Object.entries(v.stored)) {
		const want = v.expected_ids[app];
		const got = categoryId(storedEntry.type);
		check(
			got === want,
			`corpus "${v.id}": ${app} is stored as ${JSON.stringify(storedEntry.type)} and must ` +
				`resolve to ${JSON.stringify(want)}, got ${JSON.stringify(got)} — a user who switched ` +
				'language would find this override orphaned'
		);
	}
}

// Every alias must land on the SAME id, so the picker shows one general category
// rather than one per language the user has ever used.
const generalIds = new Set(aliasDoc.aliases.map((a) => categoryId(a)));
check(
	generalIds.size === 1,
	`the ${aliasDoc.aliases.length} spellings of the default category resolve to ` +
		`${generalIds.size} different ids (${[...generalIds].join(', ')}) — they must collapse to one, ` +
		'or the picker grows a new "General" every time the user switches language'
);

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Metrics category identity is broken:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${Object.keys(MAC_CATEGORIES_FR).length} categories are id-keyed; ` +
		`${Object.keys(FIXED_CAT_COLORS).length} fixed colours resolve under every stored spelling.\x1b[0m`
);
