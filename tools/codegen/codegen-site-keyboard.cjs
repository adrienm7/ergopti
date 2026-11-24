// tools/codegen/codegen-site-keyboard.cjs

/**
 * ==============================================================================
 * MODULE: Site Keyboard Data Codegen
 * DESCRIPTION:
 * Writes the data the site's keyboard drawings (src/lib/keyboard/Keyboard.js)
 * and its emulation read, one file of static/layouts/visualisation per entry
 * of LAYOUTS, from a layout source of static/layouts/sources (read by the
 * Studio's own model) and a display patch: Ergopti's own
 * (src/lib/keyboard/data/ergopti_display_patch.json), or for a layout without
 * Ergopti+ levels the default patch made from Ergopti's drawings. The site
 * therefore always shows each layout's current levels and dead keys; nobody
 * edits a generated file.
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
 * 5. Any layout: the default patch keeps Ergopti's ISO and ErgoDox drawings
 *    and its modifier and editing keys, reads every character key from the
 *    source, gives each source dead key a level named after its id, and
 *    leaves out the Ergopti+ levels and Ergopti's own extra keys. Each file
 *    names its dead levels (`dead_levels`, level to the glyph its dead key
 *    shows) and its selectable levels (`level_labels`), so the emulation
 *    opens any layout's dead keys without knowing the layout.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { loadLayoutSource } = require('../lib/layout-source.cjs');

const ROOT = path.resolve(__dirname, '../..');
const SOURCES_DIR = path.join(ROOT, 'static', 'layouts', 'sources');
const OUT_DIR = path.join(ROOT, 'static', 'layouts', 'visualisation');
const SOURCE_PATH = path.join(SOURCES_DIR, 'ergopti.toml');
const PATCH_PATH = path.join(ROOT, 'src', 'lib', 'keyboard', 'data', 'ergopti_display_patch.json');
const OUT_PATH = path.join(OUT_DIR, 'ergopti_v2.2.json');
// Every drawn layout: its source, its output and either its own display
// patch or, for the default patch, the source layer of each text level.
// bepo_1_1rc2.toml is not drawn: two of its dead keys share the terminator
// « ˰ », which the drawing could not tell apart.
const LAYOUTS = Object.freeze([
	Object.freeze({ source: SOURCE_PATH, output: OUT_PATH, patch: PATCH_PATH }),
	Object.freeze({
		source: path.join(SOURCES_DIR, 'bepo.toml'),
		output: path.join(OUT_DIR, 'bepo.json'),
		levels: Object.freeze({
			Primary: 'base',
			Shift: 'shift',
			AltGr: 'altgr',
			ShiftAltGr: 'shift_altgr'
		})
	})
]);
// The selectable text levels of every layout, in the drawing's level select.
const TEXT_LEVEL_LABELS = Object.freeze([
	['➀ Primaire', 'Primary'],
	['➁ Shift', 'Shift'],
	['➂ AltGr', 'AltGr'],
	['➃ Shift + AltGr', 'ShiftAltGr'],
	['Ctrl', 'Ctrl']
]);
// The key types the default patch keeps from Ergopti's keys the source does
// not own: modifiers, editing keys and blanks. Ergopti's own extra
// characters (★, its ErgoDox ç) are blank on another layout.
const DEFAULT_KEPT_TYPES = new Set(['special', 'enter', 'vide', 'none']);
const DIGIT = /^\p{Nd}$/u;
const ASCII_LETTER = /^[A-Za-z]$/;
const LETTER = /^\p{L}$/u;
const PUNCTUATION = /^[.,;:!?'’"«»\-]$/u;

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
const COMBINING_MARK = /^\p{M}$/u;

/** The text a cell shows for a typed string. */
function cellText(text) {
	return text.replace(NO_BREAK, NO_BREAK_MARKUP);
}

/** The legend of a dead key, from its terminator. */
function deadGlyph(terminator) {
	if (COMBINING[terminator]) return '◌' + COMBINING[terminator];
	// A bare combining terminator (bépo's dot below) needs its circle too.
	return COMBINING_MARK.test(terminator) ? '◌' + terminator : terminator;
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
function build(sourceText, patch, sourcePath = SOURCE_PATH, patchName = relative(PATCH_PATH)) {
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
	const deadLevels = {};
	const glyphs = new Set();
	for (const [level, terminator] of Object.entries(patch.dead_levels)) {
		const glyph = deadGlyph(terminator);
		if (glyphs.has(glyph))
			throw new Error(`Dead level ${level}: another dead key shows « ${glyph} »`);
		glyphs.add(glyph);
		deadLevels[level] = glyph;
	}
	const levelLabels = TEXT_LEVEL_LABELS.map(([label, level]) => ({ label, level }));
	for (const level of Object.keys(patch.dead_levels)) {
		const label = patch.level_labels?.[level] ?? deadLevels[level];
		levelLabels.push({ label, level }, { label: label + ' ⇧', level: level + 'Shift' });
	}
	return {
		_generated: `By tools/codegen/codegen-site-keyboard.cjs from ${relative(sourcePath)} and ${patchName}: never edit by hand.`,
		name: patch.name,
		site: patch.site,
		dead_levels: deadLevels,
		level_labels: levelLabels,
		iso: patch.iso,
		ergodox: patch.ergodox,
		keys: patch.keys.map((key) => buildKey(index, patch, key, allCodes))
	};
}

/** A repository path with forward slashes. */
function relative(file) {
	return path.relative(ROOT, file).replaceAll('\\', '/');
}

/** The drawing type of a source key, from its base character. */
function keyType(entry) {
	if (!entry) return 'vide';
	if (entry.dead_key !== undefined) return 'dead';
	if (entry.text === ' ') return 'space';
	if (DIGIT.test(entry.text)) return 'chiffre';
	if (ASCII_LETTER.test(entry.text)) return 'letter';
	if (LETTER.test(entry.text)) return 'french';
	if (PUNCTUATION.test(entry.text)) return 'ponctuation';
	return 'symbole';
}

/**
 * The display patch of a layout without one: Ergopti's drawings and
 * modifiers, every character key read from the source, a level per dead key.
 * @param {object} document the read layout source.
 * @param {object} ergopti Ergopti's display patch.
 * @param {Object<string,string>} levels the source layer of each text level.
 * @returns {object} the patch.
 * @throws {Error} When a level names no layer of the source.
 */
function defaultPatch(document, ergopti, levels) {
	const layers = new Map(document.layers.map((layer) => [layer.id, layer.keys]));
	for (const [level, id] of Object.entries(levels))
		if (!layers.has(id)) throw new Error(`Level ${level}: the source has no layer ${id}`);
	const deadLevels = Object.fromEntries(
		document.dead_keys.map((dead) => [dead.id, dead.terminator])
	);
	const levelOrder = [
		'Primary',
		'Shift',
		'Ctrl',
		'AltGr',
		'ShiftAltGr',
		...Object.keys(deadLevels).flatMap((level) => [level, level + 'Shift'])
	];
	const kept = new Set(levelOrder);
	const base = layers.get(levels.Primary);
	const keys = ergopti.keys.map((key) => {
		if (key.source !== undefined) {
			const out = { key: key.key, type: keyType(base[key.source]), source: key.source };
			if (key.key === 'Space') out.display = { Primary: '␣' };
			return out;
		}
		if (!DEFAULT_KEPT_TYPES.has(key.type)) return { key: key.key, type: 'vide', all: '' };
		const out = { key: key.key, type: key.type, all: key.all };
		const extra = Object.fromEntries(
			Object.entries(key.extra ?? {}).filter(([field]) => kept.has(field))
		);
		if (Object.keys(extra).length) out.extra = extra;
		return out;
	});
	return {
		name: document.layout.name,
		site: ergopti.site,
		levels,
		dead_levels: deadLevels,
		level_order: levelOrder,
		iso: ergopti.iso,
		ergodox: ergopti.ergodox,
		keys
	};
}

/**
 * The generated data of a layout of LAYOUTS (or one shaped like it).
 * @param {{source: string, patch?: string, levels?: Object<string,string>}} layout
 * @returns {object} the site's layout data.
 */
function buildLayout(layout) {
	const sourceText = fs.readFileSync(layout.source, 'utf8');
	const ergopti = JSON.parse(fs.readFileSync(PATCH_PATH, 'utf8'));
	if (layout.patch !== undefined)
		return build(
			sourceText,
			JSON.parse(fs.readFileSync(layout.patch, 'utf8')),
			layout.source,
			relative(layout.patch)
		);
	const document = loadLayoutSource().read(sourceText);
	const patch = defaultPatch(document, ergopti, layout.levels);
	return build(
		sourceText,
		patch,
		layout.source,
		`the default display patch (${relative(PATCH_PATH)})`
	);
}

/** The committed text of a generated file (Ergopti's by default). */
function render(layout = LAYOUTS[0]) {
	return `${JSON.stringify(buildLayout(layout), null, '\t')}\n`;
}

if (require.main === module) {
	for (const layout of LAYOUTS) {
		const text = render(layout);
		if (process.argv.includes('--check')) {
			if (fs.readFileSync(layout.output, 'utf8') !== text)
				throw new Error(
					`${relative(layout.output)} is stale: run node tools/codegen/codegen-site-keyboard.cjs.`
				);
		} else fs.writeFileSync(layout.output, text);
	}
	console.log('[OK] Site keyboard data matches the layout sources.');
}

module.exports = {
	build,
	buildLayout,
	defaultPatch,
	keyType,
	render,
	deadGlyph,
	cellText,
	LAYOUTS,
	SOURCE_PATH,
	PATCH_PATH,
	OUT_PATH
};
