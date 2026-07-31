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
const sandbox = new Function(
	'window',
	'document',
	`${prelude}\nreturn { MAC_CATEGORIES_FR, FIXED_CAT_COLORS, LABEL_TO_CATEGORY_ID, categoryId, getCategoryColor, CHART_PALETTE };`
);
const { MAC_CATEGORIES_FR, FIXED_CAT_COLORS, categoryId, getCategoryColor } = sandbox(
	{ ManifestData: {}, addEventListener() {} },
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

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Metrics category identity is broken:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${Object.keys(MAC_CATEGORIES_FR).length} categories are id-keyed; ` +
		`${Object.keys(FIXED_CAT_COLORS).length} fixed colours resolve under every stored spelling.\x1b[0m`
);
