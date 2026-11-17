// tools/codegen/codegen-site-keyboard.cjs

/**
 * ==============================================================================
 * MODULE: Site Keyboard Data Codegen
 * DESCRIPTION:
 * Writes static/layouts/visualisation/ergopti_v2.2.json, the data the site's
 * keyboard drawings (src/lib/keyboard/Keyboard.js) and its emulation read,
 * from the Ergopti layout source (static/layouts/sources/ergopti.toml, read
 * by the Studio's own model) and a display patch
 * (src/lib/keyboard/data/ergopti_display_patch.json). The site therefore
 * always shows the layout's current levels and dead keys; nobody edits the
 * generated file.
 *
 * FEATURES & RATIONALE:
 * 1. From the source: the four text levels (patch `levels` names the source
 *    layer of each) and, for each dead key (patch `dead_levels` names it by
 *    its terminator), what it gives after the key's base and Shift
 *    characters, a dead key on a dead key included. A dead key's cell shows
 *    its terminator, an accent spelled on a dotted circle as the site's
 *    legend formatter expects (src/lib/keyboard/keyLegend.js), and carries
 *    the `deadkey` style the drawing marks and names.
 * 2. From the patch: what the layout source cannot say. The physical
 *    drawings (ISO and ErgoDox geometry, hands, fingers), the keys the
 *    source does not own (modifiers, editing keys, ErgoDox-only keys), the
 *    Ctrl shortcut level beyond the letters and digits, the Ergopti+ levels
 *    (`…+`, Layer, À, comma) and the few display stand-ins (`display`). A
 *    key the source does not own shows `all` on every level and `all_plus`
 *    on every Ergopti+ level, except what its `extra` sets (null: no cell).
 * 3. Fail fast: a patch value that hides a source value, a display stand-in
 *    for a cell the source leaves empty, a dead key of the source the patch
 *    does not name (or the reverse) and an unknown source key all stop the
 *    generation, so the patch can never drift from the layout silently.
 * 4. Deterministic: no timestamp; `--check` compares instead of writing.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { loadLayoutSource } = require('../lib/layout-source.cjs');

const ROOT = path.resolve(__dirname, '../..');
const SOURCE_PATH = path.join(ROOT, 'static', 'layouts', 'sources', 'ergopti.toml');
const PATCH_PATH = path.join(ROOT, 'src', 'lib', 'keyboard', 'data', 'ergopti_display_patch.json');
const OUT_PATH = path.join(ROOT, 'static', 'layouts', 'visualisation', 'ergopti_v2.2.json');

// A no-break space renders as the site's visible marker element (Keyboard.css).
const NO_BREAK = /[  ]/g;
const NO_BREAK_MARKUP = '<nbsp></nbsp>';
// Spacing accents a dead key shows as a combining mark on a dotted circle,
// the spelling keyLegend.js's deadKeyText turns back into the bare accent.
const COMBINING = Object.freeze({
	'^': '̂',
	'¨': '̈',
	'`': '̀',
	'´': '́',
	'~': '̃',
	'¸': '̧',
	'˘': '̆',
	ˇ: '̌',
	'˚': '̊',
	'¯': '̄',
	'˙': '̇',
	'˝': '̋',
	'˛': '̨'
});
const CTRL_FROM_BASE = /^[a-z0-9]$/;

/** The text a cell shows for a typed string. */
function cellText(text) {
	return text.replace(NO_BREAK, NO_BREAK_MARKUP);
}

/** The legend of a dead key, from its terminator. */
function deadGlyph(terminator) {
	return COMBINING[terminator] ? '◌' + COMBINING[terminator] : terminator;
}

/**
 * Indexes the source document: its layers by id and its dead keys by id.
 * @throws {Error} When a layer the patch names is missing.
 */
function indexSource(document, patch) {
	const layers = new Map(document.layers.map((layer) => [layer.id, layer.keys]));
	for (const [level, id] of Object.entries(patch.levels))
		if (!layers.has(id)) throw new Error(`Level ${level}: the source has no layer ${id}`);
	const deadKeys = new Map(document.dead_keys.map((dead) => [dead.id, dead]));
	const byTerminator = new Map(document.dead_keys.map((dead) => [dead.terminator, dead]));
	const named = new Set(Object.values(patch.dead_levels));
	for (const dead of document.dead_keys)
		if (!named.has(dead.terminator))
			throw new Error(
				`Dead key ${dead.id} (« ${dead.terminator} ») has no level in the display patch`
			);
	for (const [level, terminator] of Object.entries(patch.dead_levels))
		if (!byTerminator.has(terminator))
			throw new Error(`Dead level ${level}: the source has no dead key « ${terminator} »`);
	return { layers, deadKeys, byTerminator };
}

/** What a dead key gives after one source entry (a character or a dead key). */
function afterDead(dead, entry) {
	if (!entry) return '';
	const rule = dead.rules.find((candidate) =>
		entry.dead_key !== undefined
			? candidate.input_dead_key === entry.dead_key
			: candidate.input === entry.text
	);
	return rule ? cellText(rule.text) : '';
}

/**
 * The source levels of one physical key.
 * @returns {{values: Object<string,string>, styles: Object<string,string>}}
 */
function sourceLevels(index, patch, code) {
	const values = {};
	const styles = {};
	for (const [level, layerId] of Object.entries(patch.levels)) {
		const entry = index.layers.get(layerId)[code];
		if (!entry) values[level] = '';
		else if (entry.dead_key !== undefined) {
			values[level] = deadGlyph(index.deadKeys.get(entry.dead_key).terminator);
			styles[level] = 'deadkey';
		} else values[level] = cellText(entry.text);
	}
	const base = index.layers.get(patch.levels.Primary)[code];
	const shift = index.layers.get(patch.levels.Shift)[code];
	for (const [level, terminator] of Object.entries(patch.dead_levels)) {
		const dead = index.byTerminator.get(terminator);
		values[level] = afterDead(dead, base);
		values[level + 'Shift'] = afterDead(dead, shift);
	}
	return { values, styles };
}

/**
 * One key of the generated data.
 * @throws {Error} When the patch contradicts or hides the source.
 */
function buildKey(index, patch, key, allCodes) {
	const out = { key: key.key };
	const order = patch.level_order;
	if (key.source === undefined) {
		for (const level of order) {
			out[level] = key.all ?? '';
			if (key.all_plus !== undefined) out[level + '+'] = key.all_plus;
		}
		for (const [field, text] of Object.entries(key.extra ?? {}))
			if (text === null) delete out[field];
			else out[field] = text;
		out.type = key.type;
		return out;
	}
	if (key.all !== undefined || key.all_plus !== undefined)
		throw new Error(`Key ${key.key}: a source key takes its levels from the source`);
	if (!allCodes.has(key.source))
		throw new Error(`Key ${key.key}: the source has no key ${key.source}`);
	const { values, styles } = sourceLevels(index, patch, key.source);
	const owned = new Set(Object.keys(values));
	for (const [level, text] of Object.entries(key.display ?? {})) {
		if (!owned.has(level)) throw new Error(`Key ${key.key}: ${level} is not a source level`);
		if (values[level] === '')
			throw new Error(`Key ${key.key}: display stand-in for an empty ${level} cell`);
		if (values[level] === text)
			throw new Error(`Key ${key.key}: display stand-in equals the source on ${level}`);
		values[level] = text;
	}
	if (CTRL_FROM_BASE.test(values.Primary)) values.Ctrl = values.Primary;
	for (const field of Object.keys(key.extra ?? {})) {
		const level = field.replace(/-style$/, '');
		if (owned.has(level)) throw new Error(`Key ${key.key}: ${field} would hide the layout source`);
		if (field === 'Ctrl' && values.Ctrl !== undefined)
			throw new Error(`Key ${key.key}: its Ctrl level comes from its base letter or digit`);
	}
	for (const level of order) {
		out[level] = values[level] ?? key.extra?.[level] ?? '';
		if (styles[level]) out[level + '-style'] = styles[level];
		for (const field of [level + '-style', level + '+', level + '+-style'])
			if (key.extra?.[field] !== undefined) out[field] = key.extra[field];
	}
	for (const [field, text] of Object.entries(key.extra ?? {}))
		if (!(field in out)) out[field] = text;
	out.type = key.type;
	return out;
}

/**
 * The generated data for a source document text and a patch.
 * @param {string} sourceText the layout source TOML.
 * @param {object} patch the display patch.
 * @returns {object} the site's layout data.
 */
function build(sourceText, patch) {
	const source = loadLayoutSource();
	const document = source.read(sourceText);
	const index = indexSource(document, patch);
	const allCodes = new Set(document.layers.flatMap((layer) => Object.keys(layer.keys)));
	const geometryCodes = new Map(patch.iso.map((entry) => [entry.key, entry.code]));
	for (const key of patch.keys)
		if (key.source !== undefined && geometryCodes.get(key.key) !== undefined)
			if (geometryCodes.get(key.key) !== key.source)
				throw new Error(
					`Key ${key.key}: the ISO drawing places ${geometryCodes.get(key.key)}, the patch reads ${key.source}`
				);
	return {
		_generated: `By tools/codegen/codegen-site-keyboard.cjs from ${path.relative(ROOT, SOURCE_PATH).replaceAll('\\', '/')} and ${path.relative(ROOT, PATCH_PATH).replaceAll('\\', '/')}: never edit by hand.`,
		name: patch.name,
		site: patch.site,
		iso: patch.iso,
		ergodox: patch.ergodox,
		keys: patch.keys.map((key) => buildKey(index, patch, key, allCodes))
	};
}

/** The committed text of the generated file. */
function render() {
	const patch = JSON.parse(fs.readFileSync(PATCH_PATH, 'utf8'));
	const data = build(fs.readFileSync(SOURCE_PATH, 'utf8'), patch);
	return `${JSON.stringify(data, null, '\t')}\n`;
}

if (require.main === module) {
	const text = render();
	if (process.argv.includes('--check')) {
		if (fs.readFileSync(OUT_PATH, 'utf8') !== text)
			throw new Error(
				`${path.relative(ROOT, OUT_PATH)} is stale: run node tools/codegen/codegen-site-keyboard.cjs.`
			);
	} else fs.writeFileSync(OUT_PATH, text);
	console.log('[OK] Site keyboard data matches the Ergopti layout source.');
}

module.exports = { build, render, deadGlyph, cellText, SOURCE_PATH, PATCH_PATH, OUT_PATH };
