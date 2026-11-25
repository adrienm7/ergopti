// tools/test/test-layout-editor-levels.cjs

/**
 * ==============================================================================
 * MODULE: Layout Levels Round Trip Tests
 * DESCRIPTION:
 * A layout's own levels (the Neo family's Mod3 and Mod4) through the Studio:
 * the layout editor's scripts run in a vm context in the order its page loads
 * them, and Neo 2 from the library goes through the editor's start, its TOML
 * save and reading back, and the editor's own reading of the document (the
 * analysis panel's layoutFromEditorDoc, which every export and the Comparer
 * handoff take).
 *
 * WHAT IS CHECKED:
 * 1. The source holds Mod3 and Mod4 as held custom modifiers on Neo's keys
 *    (Caps Lock and the ISO key left of Enter, the key right of left Shift
 *    and AltGr) and one layer per level; a dead key typed in another's state
 *    is an input_dead_key rule, never the text « dead:… ».
 * 2. Save and reload give the seven levels, their modifiers and every key
 *    back: each character is typed with the same keys as the library's Neo 2.
 * 3. A layout of four levels still reads through its compiled .keylayout.
 * 4. Exports: the DOF writes the Mod4 layer (¡) under its name and says the
 *    holding keys are left out; KLA, Kalamine, genkey and cmini name every
 *    level they leave out and the levels written as AltGr; a share link
 *    carries the levels and a link with levels but no modifiers is refused.
 * 5. Emulation: on Windows and Linux the drivers' table holds Mod3 on Caps
 *    Lock and the ISO key left of Enter, and Mod4 on the key right of left
 *    Shift and AltGr; macOS holds them on the same keys but Caps Lock, which
 *    it lists by path and reason. The emulated levels type their dead keys,
 *    and the committed Neo 2 fixture the drivers replay is the editor's.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { shared } = require('../lib/paths.cjs');

const UI = shared('ui');
// Page scripts that need a rendered page (the visitor's preferences, the
// translations, the editor's own page): no reading here uses them.
const PAGE_ONLY = [
	'a11y_prefs.js',
	'theme_choice.js',
	'i18n.js',
	'layout_editor/editor_page.js',
	'layout_editor/standalone.js'
];
const NEO = 'neo2_new';
const NEO_LEVELS = ['base', 'shift', 'mod3', 'shift_mod3', 'mod4', 'shift_mod4', 'mod3_mod4'];

/** The editor page's scripts, in its order, in one vm context. */
function loadEditor() {
	const html = fs.readFileSync(path.join(UI, 'layout_editor', 'index.html'), 'utf8');
	const scripts = [...html.matchAll(/<script src="([^"]+)"/g)]
		.map((m) =>
			path
				.relative(UI, path.resolve(path.join(UI, 'layout_editor'), m[1]))
				.split(path.sep)
				.join('/')
		)
		.filter((file) => !PAGE_ONLY.includes(file));
	for (const needed of ['layout_analysis/analysis_panel.js', 'layout_analysis/layout_formats.js'])
		assert(scripts.includes(needed), `the editor page loads ${needed}`);
	const context = vm.createContext({
		TextEncoder,
		TextDecoder,
		Blob,
		Response,
		CompressionStream,
		DecompressionStream,
		atob,
		btoa,
		// Still loading: the scripts that draw wait for it, and the analysis
		// panel listens for the app's typing tables from its load.
		document: { readyState: 'loading', addEventListener() {} }
	});
	context.window = context;
	for (const file of scripts) {
		const text = fs
			.readFileSync(path.join(UI, file), 'utf8')
			.replace(
				/^const (LAYOUT_COMPOSER_DATA|LAYER_EDITOR_DATA|LAYOUT_SOURCE_TABLES) =/m,
				'var $1 ='
			);
		vm.runInContext(text, context, { filename: file });
	}
	return vm.runInContext(
		'({ IO: LayoutSourceIO, E: LAYOUT_ANALYSIS, F: LAYOUT_FORMATS, DATA: LAYOUT_ANALYSIS_DATA, PANEL: LAYOUT_ANALYSIS_PANEL })',
		context
	);
}

const { IO, E, F, DATA, PANEL } = loadEditor();
const plain = (value) => JSON.parse(JSON.stringify(value));
const board = E.keyboard('iso');

/** Character → the keys that type it, substitutes excluded. */
function sequences(layout) {
	const out = {};
	for (const [char, seq] of E.compileLayout(layout, board, null))
		if (!seq.substituted) out[char] = seq.keys.join(',');
	return out;
}

const neo = E.libraryLayouts().find((layout) => layout.id === NEO);
assert(neo && neo.levels, 'the library has Neo 2 with its levels');

// =================================================
// ======= 1/ The source of a layout's levels ======
// =================================================

const started = IO.startFromDocument(F.toSource(neo), 'neo2_copy', 'Neo 2 copy');
const text = IO.serialize(started.doc);
const source = plain(started.doc);
assert.deepEqual(
	source.modifiers,
	[
		{ id: 'mod3', mode: 'held', keys: ['CapsLock', 'Backslash'] },
		{ id: 'mod4', mode: 'held', keys: ['IntlBackslash', 'AltRight'] }
	],
	'Mod3 and Mod4 are held custom modifiers on their keys'
);
assert.deepEqual(
	source.layers.map((layer) => [layer.id, layer.required]),
	[
		['base', []],
		['shift', ['shift']],
		['mod3', ['mod3']],
		['shift_mod3', ['mod3', 'shift']],
		['mod4', ['mod4']],
		['shift_mod4', ['mod4', 'shift']],
		['mod3_mod4', ['mod3', 'mod4']]
	],
	'one layer per level, held by its modifiers'
);
const rules = source.dead_keys.flatMap((entry) => entry.rules);
assert(
	rules.some((rule) => typeof rule.input_dead_key === 'string'),
	'a dead key typed in a dead state is an input_dead_key rule'
);
assert(
	!rules.some((rule) => typeof rule.input === 'string' && rule.input.startsWith('dead:')),
	'no rule answers to the text « dead:… »'
);
const mod4 = source.layers.find((layer) => layer.id === 'mod4');
assert(
	Object.values(mod4.keys).some((mapping) => mapping.text === '¡'),
	'the Mod4 layer types ¡'
);

// ======================================
// ======= 2/ Save, reload and read =====
// ======================================

const reloaded = IO.parse(text);
assert(reloaded.ok, `the saved TOML reads back: ${JSON.stringify(reloaded.error)}`);
assert.equal(IO.serialize(reloaded.doc), text, 'a second save writes the same TOML');
const read = PANEL.layoutFromEditorDoc(reloaded.doc);
assert.deepEqual(
	plain(read.levels).map((level) => level.id),
	NEO_LEVELS,
	'the editor reads the seven levels'
);
assert.deepEqual(plain(read.levels), plain(neo.levels), 'the levels come back as declared');
assert.deepEqual(plain(read.modifiers), plain(neo.modifiers), 'the modifiers come back');
assert.deepEqual(
	Object.keys(read.rows).sort(),
	Object.keys(neo.rows).sort(),
	'every typing key comes back'
);
const expected = sequences(neo);
const got = sequences(read);
const differing = Object.keys(Object.assign({}, expected, got)).filter(
	(char) => expected[char] !== got[char]
);
assert.deepEqual(differing, [], 'every character is typed with the same keys after a reload');
for (const char of ['¡', '¿', 'Λ'])
	assert(got[char], `${char} is typed after the reload (Mod4 and Mod3+Mod4)`);

// ==========================================
// ======= 3/ A layout of four levels =======
// ==========================================

const qwerty = E.libraryLayouts().find((layout) => layout.id === 'qwerty');
const four = IO.startFromDocument(F.toSource(qwerty), 'qwerty_copy', 'QWERTY copy').doc;
assert.equal(F.sourceHoldSets(four), null, 'QWERTY has no level of its own');
const fourRead = PANEL.layoutFromEditorDoc(IO.parse(IO.serialize(four)).doc);
assert.equal(fourRead.levels, undefined, 'a layout of four levels reads as four');
assert.equal(fourRead.rows.KeyQ[0], 'q', 'through its .keylayout');

// ============================================
// ======= 3b/ Tap-holds analysed as holds ====
// ============================================

// The source fixture's Space taps a space and holds the « command » layer;
// F is made to hold the « kana » layer (あ on A), which nothing else reaches.
{
	const parsed = IO.parse(
		fs.readFileSync(shared('tests', 'corpus', 'layouts', 'source', 'source.toml'), 'utf8')
	);
	assert(parsed.ok, 'the source fixture reads');
	const doc = plain(parsed.doc);
	const plainRead = PANEL.layoutFromEditorDoc(plain(parsed.doc));
	assert.deepEqual(
		plain(plainRead.levels.map((level) => level.id)),
		['base', 'shift', 'altgr', 'shift_altgr', 'hold_command'],
		'the layer a tap-hold holds is a level of its own, after the four'
	);
	assert.deepEqual(
		plain(plainRead.modifiers.hold_command),
		{ label: 'command', for_left_hand: ['Space'], for_right_hand: ['Space'], tap_keys: ['Space'] },
		'held by its tap-hold key, which also types'
	);
	assert.equal(plainRead.rows.Space[0], ' ', 'Space types its tap');
	assert.equal(plainRead.rows.KeyA[4], 'a', 'the held layer types its keys');
	doc.tap_holds.push({ key: 'KeyF', tap: { text: 'f' }, hold_layer: 'kana', threshold_ms: 200 });
	const read = PANEL.layoutFromEditorDoc(doc);
	assert.equal(read.rows.KeyF[0], 'f', 'a tap text is what the key types');
	assert.equal(
		E.analyse(plainRead, E.ngramsFromText('あ'), { keyboard: 'iso' }).metrics.unsupported,
		100,
		'without the tap-hold, nothing types あ'
	);
	assert.equal(
		E.analyse(read, E.ngramsFromText('あ'), { keyboard: 'iso' }).metrics.unsupported,
		0,
		'holding F types あ on A'
	);
	const report = E.tapHoldReport(read, E.ngramsFromText('fa あ'), { keyboard: 'iso' });
	const f = report.keys.find((key) => key.code === 'KeyF');
	assert(f && f.taps === 1 && f.held === 1, 'F is tapped once and held once');
	assert.equal(f.sameHandHold, 100, 'F holds for A, a key of its own hand');
	assert.equal(f.rollAfterTap, 100, '« fa » rolls from F to A on one hand');
	assert.equal(
		F.withTapHolds(fourRead, four, DATA.model.fingerings.standard),
		fourRead,
		'a source without tap-holds is read as it is'
	);
}

// ============================
// ======= 4/ The exports =====
// ============================

const losses = (unmapped, what) =>
	unmapped.filter((entry) => entry.what === what).map((entry) => entry.detail);
const dof = F.toDof(read);
const dofJson = JSON.parse(dof.text);
assert.deepEqual(
	Object.keys(dofJson.layers),
	['main', 'shift'].concat(NEO_LEVELS.slice(2)),
	'the DOF writes every level under its name'
);
assert(
	dofJson.layers.mod4.some((row) => row.split(' ').includes('¡')),
	'the DOF Mod4 layer types ¡'
);
assert.equal(losses(dof.unmapped, 'level_keys').length, 2, 'the DOF names the keys it cannot hold');
const levelLosses = [];
F.levelLosses(read, levelLosses);
assert.deepEqual(
	losses(levelLosses, 'level_as_altgr'),
	['Mod3', 'Shift+Mod3'],
	'a four-level format says Mod3 is written as AltGr'
);
assert.deepEqual(
	losses(levelLosses, 'layer'),
	['Mod4', 'Shift+Mod4', 'Mod3+Mod4'],
	'a four-level format names every level it leaves out'
);
const kalamine = F.toKalamineToml(read);
for (const level of ['Mod4', 'Shift+Mod4', 'Mod3+Mod4'])
	assert(losses(kalamine.unmapped, 'layer').includes(level), `Kalamine names ${level} left out`);
for (const write of [F.toGenkey, F.toCmini])
	assert(losses(write(read).unmapped, 'layer').includes('Mod4'), 'a letter block names Mod4');
for (const entry of levelLosses.concat(dof.unmapped))
	assert(
		F.lossMessage(entry).key.startsWith('layout_analysis.formats.loss.'),
		'each loss is worded'
	);
// The Windows package (2026-11-24): Neo's chained dead keys have an empty
// terminator and only results of several characters, which a DEADKEY entry
// cannot hold, so Space alone stays; it typed `undefined` (kbd_unit_invalid)
// and refused the package. It now types the dead key's private character.
{
	const windowsDoc = plain(reloaded.doc);
	windowsDoc.exports = Object.assign({}, windowsDoc.exports, {
		windows: { locale: 'de-DE', layout_id: '00000407', dll_name: 'neo2' }
	});
	const built = IO.windowsDlls(windowsDoc);
	const graveTilde = windowsDoc.dead_keys.findIndex((dead) => dead.id === 'grave_tilde');
	assert.equal(windowsDoc.dead_keys[graveTilde].terminator, '', 'grave_tilde ends on nothing');
	const tables = built.model.dead_keys[graveTilde];
	assert.deepEqual(
		plain(tables.rules),
		[{ base: 0x20, result: tables.dead }],
		"Space after grave_tilde types the dead key's own character"
	);
	const said = new Set(built.omitted.map((entry) => `${entry.path}:${entry.reason}`));
	for (const reason of [
		'dead_keys.grave_tilde.terminator:dead_key_private_character',
		'dead_keys.grave_tilde.rules[a]:dead_result_not_one_unit',
		'dead_keys.grave_tilde:dead_key_without_windows_rule'
	])
		assert(said.has(reason), `the Windows package says ${reason}`);
	assert(IO.windowsPackage(windowsDoc).bytes.length > 0, 'Neo 2 builds a Windows package');
}

(async () => {
	const part = await F.toLink([read]);
	const [linked] = await F.fromLink(`#${part}`, E);
	assert.deepEqual(plain(linked.levels), plain(neo.levels), 'a share link carries the levels');
	assert.deepEqual(sequences(linked), expected, 'a linked Neo 2 types as the library one');
	const json = new TextEncoder().encode(
		JSON.stringify([{ n: 'Half', r: { KeyA: ['a', 'A', null, null, null] }, v: neo.levels }])
	);
	const packed = new Uint8Array(
		await new Response(
			new Blob([json]).stream().pipeThrough(new CompressionStream('deflate-raw'))
		).arrayBuffer()
	);
	const half = `l=1.${Buffer.from(packed).toString('base64url')}`;
	await assert.rejects(F.fromLink(`#${half}`, E), (error) => error.code === 'link_invalid');

	// ===============================
	// ======= 5/ The emulation ======
	// ===============================

	for (const platform of ['windows', 'macos', 'linux']) {
		const table = plain(IO.emulationTable(reloaded.doc, platform));
		// macOS never reports Caps Lock held to an event tap (platform_parity.toml).
		const mod3Keys = platform === 'macos' ? ['Backslash'] : ['CapsLock', 'Backslash'];
		assert.deepEqual(
			table.modifiers,
			[
				{ id: 'mod3', mode: 'held', keys: mod3Keys },
				{ id: 'mod4', mode: 'held', keys: ['IntlBackslash', 'AltRight'] }
			],
			`${platform}: the drivers hold Mod3 and Mod4 on Neo's keys, Caps Lock and AltGr included`
		);
		const layer = table.layers.find((entry) => entry.id === 'mod4');
		assert(
			Object.values(layer.keys).some((mapping) => mapping.text === '¡'),
			`${platform}: the emulated Mod4 layer types ¡`
		);
		assert.deepEqual(
			layer.keys.Equal,
			{ dead_key: 'diaeresis' },
			`${platform}: the emulated Mod4 layer types its dead ¨`
		);
		assert(table.dead_keys.diaeresis, `${platform}: the table holds the dead ¨ and its rules`);
		assert.deepEqual(
			table.not_emulated.map((entry) => [entry.path, entry.reason]),
			platform === 'macos'
				? [['modifiers.mod3.keys[0]', 'modifier_key_not_holdable_on_macos']]
				: [],
			`${platform}: only what the platform cannot hold is listed`
		);
	}
	// The committed Neo 2 fixture the drivers replay is what the editor writes.
	const fixture = IO.parse(
		fs.readFileSync(shared('tests', 'corpus', 'layouts', 'source', 'neo2_source.toml'), 'utf8')
	);
	assert(fixture.ok, 'the Neo 2 fixture reads');
	assert.deepEqual(
		plain(fixture.doc),
		plain(IO.startFromDocument(F.toSource(neo), 'neo2', 'Neo 2').doc),
		"neo2_source.toml is the editor's Neo 2: rewrite it from F.toSource and IO.serialize"
	);
	console.log(
		`test-layout-editor-levels: OK (${NEO_LEVELS.length} levels, ${Object.keys(got).length} characters, 3 platforms)`
	);
})().catch((error) => {
	console.error(error);
	process.exit(1);
});
