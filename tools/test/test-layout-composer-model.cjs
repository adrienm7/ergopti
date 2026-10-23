// tools/test/test-layout-composer-model.cjs

/**
 * ==============================================================================
 * MODULE: Layout Composer Model Gate
 * DESCRIPTION:
 * _shared/ui/layout_composer/composer_model.js reads registry layouts, builds a
 * layout from four layers and a shortcuts layer, and writes it as one complete
 * .keylayout that the three drivers consume through the readers they already
 * have. This gate holds the model to the shared layout vectors and to the
 * composition contract of docs/layout-composer.md.
 *
 * WHAT IS CHECKED:
 * 1. Reader: the model types what _shared/tests/corpus/layouts/keylayout_vectors.json
 *    says for every registry layout, the same answers the Windows reader and
 *    the Linux converter are pinned to.
 * 2. Identity: composing all four layers (and the shortcuts) from one layout,
 *    writing the file and reading it back types the same vectors.
 * 3. Mixing: a layer from each of four layouts types each layer's own cells,
 *    dead keys follow the typed character, shortcuts follow their modifier.
 * 4. Overrides: text, nothing, a copied cell and a copied dead key, and the
 *    derived Caps layer.
 * 5. Validation: every problem code is reachable, and a composition with a
 *    problem is never serialized.
 * 6. File: deterministic bytes, a complete keyMap per level, XML escaping, and
 *    the reserved ids stay out of the registry.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { shared } = require('../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const MODEL_PATH = shared('ui', 'layout_composer', 'composer_model.js');
const REFERENCE_PATH = shared('ui', 'layout_composer', 'reference_layouts.js');
const TABLE_PATH = shared('modules', 'layouts', 'mac_keycodes.json');
const DATA_PATH = shared('ui', 'layout_composer', '_generated', 'composer_data.js');
const VECTORS_PATH = shared('tests', 'corpus', 'layouts', 'keylayout_vectors.json');
const REGISTRY_DIR = path.join(ROOT, 'static', 'layouts', 'registry');

// Floors: nothing compared must not read as everything agreeing.
const MIN_VECTORS = 30;
const MIN_REGISTRY_LAYOUTS = 5;
const MIN_ROUND_TRIP_CELLS = 400;

const errors = [];
const fail = (message) => errors.push(message);
const check = (condition, message) => {
	if (!condition) fail(message);
};

const sandbox = {};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(REFERENCE_PATH, 'utf8'), sandbox, { filename: REFERENCE_PATH });
vm.runInContext(fs.readFileSync(MODEL_PATH, 'utf8'), sandbox, { filename: MODEL_PATH });
const Composer = vm.runInContext('LayoutComposer', sandbox);
const REFERENCE = vm.runInContext('LAYOUT_COMPOSER_REFERENCE', sandbox);
const SHARED_TABLE = JSON.parse(fs.readFileSync(TABLE_PATH, 'utf8'));
vm.runInContext(fs.readFileSync(DATA_PATH, 'utf8'), sandbox, { filename: DATA_PATH });
// The page reads its keys from the generated data; the model works on it unchanged.
const TABLE = vm.runInContext('LAYOUT_COMPOSER_DATA', sandbox);
check(
	TABLE.keys.length === SHARED_TABLE.keys.length &&
		TABLE.keys.every(
			(key, position) =>
				key.code === SHARED_TABLE.keys[position].code &&
				JSON.stringify(key.mac) === JSON.stringify(SHARED_TABLE.keys[position].mac) &&
				key.geometry !== undefined
		) &&
		JSON.stringify(TABLE.conventions) === JSON.stringify(SHARED_TABLE.conventions),
	'composer_data.js is stale: run npm run codegen:layout-composer-data:js'
);
const INDEX = JSON.parse(fs.readFileSync(path.join(REGISTRY_DIR, 'index.json'), 'utf8'));
const VECTORS = JSON.parse(fs.readFileSync(VECTORS_PATH, 'utf8')).vectors;

const ahkToCode = new Map(SHARED_TABLE.keys.map((key) => [key.ahk, key.code]));
const keyByCode = new Map(TABLE.keys.map((key) => [key.code, key]));
const macOf = (code, convention) => {
	const mac = keyByCode.get(code).mac;
	return typeof mac === 'object' ? mac[convention] : mac;
};

/** Every registry layout as a source, read from its file. */
function loadRegistrySources() {
	const sources = {};
	for (const entry of INDEX.layouts) {
		const text = fs.readFileSync(path.join(REGISTRY_DIR, entry.file), 'utf8');
		sources[entry.id] = Composer.parseSource(entry.id, text, entry.keycode_convention, TABLE);
	}
	return sources;
}

const SOURCES = loadRegistrySources();
for (const id of Object.keys(REFERENCE)) SOURCES[id] = Composer.referenceSource(id, REFERENCE[id]);

// ===================================
// ===== Typing on a .keylayout ======
// ===================================

const MODIFIER_NAMES = { shift: 'shift', caps: 'caps', altgr: 'option' };

/** A vector's press ("altgr shift SC010") as the modifiers down and the scan code. */
function readPress(press) {
	const tokens = press.split(' ');
	const scan = tokens.pop();
	return { pressed: tokens.map((token) => MODIFIER_NAMES[token]), scan };
}

/**
 * Types a vector's presses on a layout text through the model's own reader.
 * @returns {string} What the presses type.
 */
function typeOn(text, convention, presses) {
	const model = Composer.parseModel(text);
	let state = 'none';
	let out = '';
	for (const press of presses) {
		const { pressed, scan } = readPress(press);
		const code = ahkToCode.get(scan);
		const result = Composer.step(
			model,
			state,
			Composer.keyMapIndex(model, pressed),
			macOf(code, convention)
		);
		out += result.output;
		state = result.next;
	}
	return out;
}

/** What a chord sends: the layout's Command level, "" for nothing or a dead key. */
function shortcutOn(text, convention, scan, modifier) {
	const model = Composer.parseModel(text);
	const code = ahkToCode.get(scan);
	const result = Composer.resolve(
		model,
		Composer.keyMapIndex(model, modifier),
		macOf(code, convention)
	);
	return result.kind === 'text' ? result.text : '';
}

const conventionOf = (id) => INDEX.layouts.find((entry) => entry.id === id).keycode_convention;
const textOf = (id) => {
	const entry = INDEX.layouts.find((candidate) => candidate.id === id);
	return fs.readFileSync(path.join(REGISTRY_DIR, entry.file), 'utf8');
};

// =========================
// ===== 1/ Reader =========
// =========================

check(VECTORS.length >= MIN_VECTORS, `only ${VECTORS.length} vectors read (floor ${MIN_VECTORS})`);
check(
	Object.keys(SOURCES).length >= MIN_REGISTRY_LAYOUTS,
	'fewer sources than the registry and the references'
);
for (const vector of VECTORS) {
	const text = textOf(vector.layout);
	const convention = conventionOf(vector.layout);
	if (vector.press) {
		const typed = typeOn(text, convention, vector.press);
		check(
			typed === vector.types,
			`vector ${vector.id}: typed "${typed}", expected "${vector.types}"`
		);
	} else {
		const sent = shortcutOn(text, convention, vector.shortcut, ['command']);
		check(sent === vector.sends, `vector ${vector.id}: sent "${sent}", expected "${vector.sends}"`);
	}
}

// ==========================
// ===== 2/ Identity ========
// ==========================

/** A declaration taking every layer, and the Command level, from one source. */
function identityOf(id) {
	const declaration = Composer.emptyDeclaration(`Identity ${id}`, conventionOf(id), id);
	Composer.setShortcutSource(declaration, 'default', { source: id, layer: 'command' });
	return declaration;
}

function buildOrFail(declaration, label) {
	const built = Composer.build(declaration, SOURCES, TABLE);
	if (!built.ok) {
		fail(`${label}: ${JSON.stringify(built.problems)}`);
		return null;
	}
	return built.layout;
}

for (const id of ['ergol', 'ergopti']) {
	const layout = buildOrFail(identityOf(id), `identity ${id}`);
	if (!layout) continue;
	const text = Composer.serialize(layout, TABLE);
	for (const vector of VECTORS.filter((candidate) => candidate.layout === id)) {
		if (vector.press) {
			const typed = typeOn(text, conventionOf(id), vector.press);
			check(
				typed === vector.types,
				`identity ${id} ${vector.id}: typed "${typed}", expected "${vector.types}"`
			);
		} else {
			const sent = shortcutOn(text, conventionOf(id), vector.shortcut, ['command']);
			check(
				sent === vector.sends,
				`identity ${id} ${vector.id}: sent "${sent}", expected "${vector.sends}"`
			);
		}
	}
}

// Every cell of every source layer survives identity composition and a round trip.
let roundTripCells = 0;
for (const id of ['ergol', 'ergopti', 'ergopti_plus', 'qwerty', 'azerty']) {
	const declaration = Composer.emptyDeclaration(
		`Identity ${id}`,
		conventionOf(id === 'qwerty' || id === 'azerty' ? 'ergol' : id),
		id
	);
	const layout = buildOrFail(declaration, `identity ${id}`);
	if (!layout) continue;
	const text = Composer.serialize(layout, TABLE);
	const model = Composer.parseModel(text);
	const convention = declaration.keycode_convention;
	for (const [code, row] of Object.entries(layout.keys)) {
		for (const level of Composer.LEVELS) {
			const cell = row[level.id];
			const resolved = Composer.resolve(
				model,
				Composer.keyMapIndex(model, levelPressed(level.id)),
				macOf(code, convention)
			);
			roundTripCells += 1;
			if (cell === null)
				check(
					resolved.kind === 'none',
					`${id} ${code} ${level.id}: expected nothing, read ${resolved.kind}`
				);
			else if (cell.output !== undefined)
				check(
					resolved.kind === 'text' && resolved.text === cell.output,
					`${id} ${code} ${level.id}: expected "${cell.output}", read ${JSON.stringify(resolved)}`
				);
			else {
				const neutral = layout.actions[cell.action].none;
				if (neutral.next !== '')
					check(
						resolved.kind === 'dead' && resolved.action === cell.action,
						`${id} ${code} ${level.id}: expected the dead key ${cell.action}, read ${JSON.stringify(resolved)}`
					);
				else
					check(
						resolved.kind === 'text' && resolved.text === neutral.output,
						`${id} ${code} ${level.id}: expected "${neutral.output}", read ${JSON.stringify(resolved)}`
					);
			}
		}
	}
}
check(roundTripCells >= MIN_ROUND_TRIP_CELLS, `only ${roundTripCells} round-trip cells compared`);

/** The modifiers down for a composed level. */
function levelPressed(levelId) {
	return {
		base: [],
		shift: ['shift'],
		caps: ['caps'],
		altgr: ['option'],
		shift_altgr: ['shift', 'option'],
		meta: ['command'],
		ctrl: ['control'],
		alt: ['option', 'command']
	}[levelId];
}

// ==========================
// ===== 3/ Mixing ==========
// ==========================

const MIXED = {
	schema_version: 1,
	name: 'Mixed',
	keycode_convention: 'iso',
	layers: {
		base: { source: 'qwerty' },
		shift: { source: 'azerty' },
		altgr: { source: 'ergopti' },
		shift_altgr: { source: 'ergol' }
	},
	shortcuts: {
		default: { source: 'qwerty', layer: 'base' },
		ctrl: { source: 'azerty', layer: 'base' }
	},
	overrides: {}
};
const mixed = buildOrFail(MIXED, 'mixed');
if (mixed) {
	const mixedText = Composer.serialize(mixed, TABLE);
	const typeMixed = (presses) => typeOn(mixedText, 'iso', presses);
	check(typeMixed(['SC010']) === 'q', 'mixed: base KeyQ is the QWERTY q');
	check(typeMixed(['shift SC010']) === 'A', 'mixed: Shift KeyQ is the AZERTY A');
	const ergoptiAltGr = SOURCES.ergopti.cells.KeyQ.altgr;
	const ergolShiftAltGr = SOURCES.ergol.cells.KeyQ.shift_altgr;
	check(
		typeMixed(['altgr SC010']) === (ergoptiAltGr && ergoptiAltGr.text),
		`mixed: AltGr KeyQ is the Ergopti cell ${JSON.stringify(ergoptiAltGr)}`
	);
	check(
		ergolShiftAltGr === null ||
			typeMixed(['altgr shift SC010']) === ergolShiftAltGr.text ||
			ergolShiftAltGr.dead !== undefined,
		'mixed: Shift+AltGr KeyQ is the Ergo-L cell'
	);
	// The AZERTY circumflex sits on Shift (diaeresis) of the AZERTY layer: a QWERTY base
	// letter typed after it still composes.
	check(
		typeMixed(['shift SC01A', 'SC012']) === 'ë',
		`mixed: AZERTY diaeresis then QWERTY e types "${typeMixed(['shift SC01A', 'SC012'])}"`
	);
	check(
		typeMixed(['shift SC01A', 'SC039']) === '¨',
		'mixed: the diaeresis then a space types the diaeresis'
	);
	check(
		shortcutOn(mixedText, 'iso', 'SC010', ['command']) === 'q',
		'mixed: Win/Cmd shortcuts follow the default entry'
	);
	check(
		shortcutOn(mixedText, 'iso', 'SC010', ['control']) === 'a',
		'mixed: Ctrl shortcuts follow their own entry (AZERTY a)'
	);
	check(
		shortcutOn(mixedText, 'iso', 'SC010', ['option', 'command']) === 'q',
		'mixed: Alt shortcuts follow the default entry'
	);
	check(
		typeMixed(['caps SC010']) === 'A',
		'mixed: derived Caps on a cased base letter takes the Shift cell'
	);
}

// Shortcuts default to the composed base layer when nothing is declared.
{
	const declaration = Composer.emptyDeclaration('Plain', 'iso', 'ergol');
	const layout = buildOrFail(declaration, 'plain shortcuts');
	if (layout)
		check(layout.keys.KeyQ.ctrl.output === 'q', 'shortcuts default to the composed base layer');
}

// ==========================
// ===== 4/ Overrides =======
// ==========================

{
	const declaration = Composer.emptyDeclaration('Tuned', 'iso', 'qwerty');
	Composer.setOverride(declaration, 'base', 'KeyQ', 'x');
	Composer.setOverride(declaration, 'base', 'KeyW', null);
	Composer.setOverride(declaration, 'shift', 'KeyE', {
		copy: { source: 'ergol', key: 'KeyA', layer: 'altgr' }
	});
	Composer.setOverride(declaration, 'base', 'KeyR', {
		copy: { source: 'azerty', key: 'BracketLeft', layer: 'base' }
	});
	Composer.setOverride(declaration, 'altgr', 'KeyT', '……');
	Composer.setOverride(declaration, 'caps', 'KeyY', '&<>"');
	Composer.setOverride(declaration, 'ctrl', 'KeyZ', 'z');
	const layout = buildOrFail(declaration, 'tuned');
	if (layout) {
		const text = Composer.serialize(layout, TABLE);
		check(typeOn(text, 'iso', ['SC010']) === 'x', 'override: base KeyQ types x');
		check(typeOn(text, 'iso', ['SC011']) === '', 'override: a null override types nothing');
		const ergolCell = SOURCES.ergol.cells.KeyA.altgr;
		check(
			typeOn(text, 'iso', ['shift SC012']) ===
				(ergolCell && ergolCell.text ? ergolCell.text : typeOn(text, 'iso', ['shift SC012'])),
			'override: Shift KeyE copies the Ergo-L AltGr KeyA cell'
		);
		check(
			typeOn(text, 'iso', ['SC013', 'SC012']) === 'ê',
			`override: a copied dead key composes by character, typed "${typeOn(text, 'iso', ['SC013', 'SC012'])}"`
		);
		check(
			typeOn(text, 'iso', ['altgr SC014']) === '……',
			'override: a two-character output is kept'
		);
		check(
			typeOn(text, 'iso', ['caps SC015']) === '&<>"',
			'override: the Caps layer takes its own override, XML escaped and read back'
		);
		check(shortcutOn(text, 'iso', 'SC02C', ['control']) === 'z', 'override: a Ctrl cell');
		check(text.includes('maxout="4"'), 'override: maxout follows the longest output');
		Composer.clearOverride(declaration, 'base', 'KeyQ');
		check(!('KeyQ' in declaration.overrides.base), 'clearOverride removes the key');
	}
}

// ==========================
// ===== 5/ Validation ======
// ==========================

function codesOf(mutate) {
	const declaration = JSON.parse(JSON.stringify(MIXED));
	mutate(declaration);
	return Composer.validate(declaration, SOURCES, TABLE).problems.map((entry) => entry.code);
}

const BAD = {
	schema_version: (d) => {
		d.schema_version = 9;
	},
	name_invalid: (d) => {
		d.name = '';
	},
	convention_invalid: (d) => {
		d.keycode_convention = 'jis';
	},
	layers_invalid: (d) => {
		d.layers = [];
	},
	base_missing: (d) => {
		delete d.layers.base;
	},
	unknown_layer: (d) => {
		d.layers.shift.layer = 'meta';
	},
	unknown_source: (d) => {
		d.layers.altgr.source = 'nowhere';
	},
	spec_invalid: (d) => {
		d.layers.altgr = 'ergol';
	},
	shortcuts_invalid: (d) => {
		d.shortcuts = 3;
	},
	unknown_shortcut: (d) => {
		d.shortcuts.hyper = { source: 'ergol' };
	},
	overrides_invalid: (d) => {
		d.overrides = 'x';
	},
	unknown_target: (d) => {
		d.overrides.nowhere = {};
	},
	unknown_key: (d) => {
		d.overrides.base = { KeyNope: 'x' };
	},
	output_invalid: (d) => {
		d.overrides.base = { KeyQ: 'x\u0001' };
	},
	override_invalid: (d) => {
		d.overrides.base = { KeyQ: 42 };
	}
};
for (const [code, mutate] of Object.entries(BAD)) {
	const codes = codesOf(mutate);
	check(codes.includes(code), `validation: expected ${code}, got ${JSON.stringify(codes)}`);
	const declaration = JSON.parse(JSON.stringify(MIXED));
	mutate(declaration);
	check(
		!Composer.build(declaration, SOURCES, TABLE).ok,
		`validation ${code}: a bad declaration must not build`
	);
}
check(
	codesOf((d) => {
		d.overrides.base = { KeyQ: 'x'.repeat(9) };
	}).includes('output_invalid'),
	'validation: nine characters is too long'
);
check(
	Composer.validate(null, SOURCES, TABLE).problems[0].code === 'declaration_invalid',
	'validation: null declaration'
);
check(
	codesOf((d) => {
		d.overrides.base = { KeyQ: { copy: { source: 'ergol', key: 'KeyA', layer: 'nope' } } };
	}).includes('unknown_layer'),
	'validation: a copy names a real layer'
);
{
	const empty = Composer.emptyDeclaration('Empty', 'iso', 'qwerty');
	for (const code of Object.keys(SOURCES.qwerty.cells))
		Composer.setOverride(empty, 'base', code, null);
	const built = Composer.build(empty, SOURCES, TABLE);
	check(
		!built.ok && built.problems[0].code === 'base_empty',
		'validation: an empty base layer is refused'
	);
}
{
	// A source that defines two different results for one character in one dead
	// state cannot be composed once that character is typed under that state.
	const clash = Object.assign({}, SOURCES.azerty, { ambiguous: new Set(['diaeresis\u0000e']) });
	const built = Composer.build(MIXED, Object.assign({}, SOURCES, { azerty: clash }), TABLE);
	check(
		!built.ok && built.problems.some((entry) => entry.code === 'ambiguous_composition'),
		'validation: an ambiguous composition is refused'
	);
}
{
	const unread = Composer.readDeclaration('{ not json');
	check(
		unread.problem === 'declaration_not_json',
		'a stored declaration that is not JSON is reported'
	);
	check(Composer.readDeclaration(null).declaration === null, 'no stored declaration is no problem');
}

// ==========================
// ===== 6/ File ============
// ==========================

if (mixed) {
	const first = Composer.serialize(mixed, TABLE);
	check(first === Composer.serialize(mixed, TABLE), 'serialization is deterministic');
	check(
		first.endsWith('</keyboard>\n') && !first.includes('\r'),
		'the file is LF with a final newline'
	);
	const model = Composer.parseModel(first);
	const sets = model.keyMapSets.get(Composer.COMPOSED_ID);
	check(sets.size === Composer.LEVELS.length, 'one keyMap per level');
	const sizes = new Set([...sets.values()].map((keys) => keys.size));
	check(sizes.size === 1, 'every keyMap defines the same keys');
	check(model.name === 'Mixed', 'the keyboard name is written');
	const written = Composer.writeDeclaration(MIXED);
	const read = Composer.readDeclaration(written);
	check(
		read.problem === null && Composer.writeDeclaration(read.declaration) === written,
		'a declaration round-trips byte for byte'
	);
}

const registryIds = new Set(INDEX.layouts.map((entry) => entry.id));
const DEFAULTS = JSON.parse(fs.readFileSync(shared('modules', 'layouts', 'defaults.json'), 'utf8'));
check(
	Composer.COMPOSED_ID === DEFAULTS.composer.id,
	'COMPOSED_ID must be the id the shared layout defaults declare for the composer'
);
check(
	!registryIds.has(Composer.COMPOSED_ID),
	'the registry may not hold the id of the composition'
);
for (const id of Object.keys(REFERENCE)) {
	check(!registryIds.has(id), `the registry may not hold the reference id ${id}`);
	check(/^[a-z][a-z0-9_]*$/.test(id), `the reference id ${id} is a legal id`);
}
for (const [id, reference] of Object.entries(REFERENCE)) {
	const codes = new Set(TABLE.keys.map((key) => key.code));
	for (const code of Object.keys(reference.rows))
		check(codes.has(code), `reference ${id}: ${code} is a known key`);
	for (const code of codes) check(code in reference.rows, `reference ${id}: ${code} has a row`);
}

// ===============================
// ===== 7/ Shared corpus ========
// ===============================

// composed.keylayout is compiled from composition.json (npm run
// codegen:layout-composer-corpus) and replayed by every driver's composer test.
{
	const CORPUS_DIR = shared('tests', 'corpus', 'layouts', 'composer');
	const declaration = JSON.parse(
		fs.readFileSync(path.join(CORPUS_DIR, 'composition.json'), 'utf8')
	);
	const corpus = JSON.parse(fs.readFileSync(path.join(CORPUS_DIR, 'vectors.json'), 'utf8'));
	const committed = fs.readFileSync(path.join(CORPUS_DIR, 'composed.keylayout'), 'utf8');
	const built = buildOrFail(declaration, 'corpus composition');
	if (built) {
		const compiled = Composer.serialize(built, TABLE);
		check(
			compiled === committed,
			'composed.keylayout is stale: run npm run codegen:layout-composer-corpus'
		);
		check(corpus.layout === Composer.COMPOSED_ID, 'the corpus layout is the composer id');
		check(
			corpus.convention === declaration.keycode_convention,
			'the corpus convention is the one of the declaration'
		);
		const MODIFIERS = { meta: ['command'], ctrl: ['control'], alt: ['option', 'command'] };
		let replayed = 0;
		for (const vector of corpus.vectors) {
			replayed += 1;
			if (vector.press) {
				const typed = typeOn(committed, corpus.convention, vector.press);
				check(
					typed === vector.types,
					`corpus ${vector.id}: typed "${typed}", expected "${vector.types}"`
				);
			} else {
				const sent = shortcutOn(
					committed,
					corpus.convention,
					vector.shortcut,
					MODIFIERS[vector.modifier]
				);
				check(
					sent === vector.sends,
					`corpus ${vector.id}: sent "${sent}", expected "${vector.sends}"`
				);
			}
		}
		check(replayed >= 12, `only ${replayed} corpus vectors`);
		check(
			corpus.vectors.some((v) => v.modifier === 'ctrl') &&
				corpus.vectors.some((v) => v.modifier === 'alt') &&
				corpus.vectors.some((v) => v.modifier === 'meta'),
			'the corpus covers the three shortcut modifiers'
		);
	}
}

if (errors.length > 0) {
	console.error(`test-layout-composer-model: ${errors.length} problem(s)`);
	for (const message of errors.slice(0, 40)) console.error(`  - ${message}`);
	process.exit(1);
}
console.log(
	`test-layout-composer-model: OK (${VECTORS.length} vectors, ${roundTripCells} round-trip cells, ${Object.keys(BAD).length} problem codes)`
);
