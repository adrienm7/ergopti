// tools/test/test-layout-source-emulation.cjs

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source Emulation Contract
 * DESCRIPTION:
 * Pins the emulation of what no .keylayout holds: the table compileEmulation
 * writes for the emulation fixture equals its committed golden file (generated
 * by tools/codegen/codegen-layout-source-emulation.cjs), the web engine replays the shared
 * typing vectors the Lua drivers replay too, the engine refuses malformed
 * tables, every record the emulation cannot perform is reported, and
 * export-all publishes the emulation and web targets.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { loadLayoutSource } = require('../lib/layout-source.cjs');
const { targetReport } = require('../lib/layout-source-report.cjs');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');

const Source = loadLayoutSource();
const Engine = Source.emulation;
const corpus = shared('tests', 'corpus', 'layouts', 'source');
const read = (file) => fs.readFileSync(file, 'utf8');
const clone = (value) => JSON.parse(JSON.stringify(value));
const fixture = Source.read(read(path.join(corpus, 'emulation_source.toml')));
const golden = JSON.parse(read(path.join(corpus, 'emulation.json')));
const vectors = JSON.parse(read(path.join(corpus, 'emulation_vectors.json')));
let checks = 0;

// The golden table is the compiler's own output, per platform.
for (const platform of ['macos', 'linux', 'windows']) {
	assert.deepEqual(
		clone(Source.compileEmulation(fixture, { platform })),
		golden[platform],
		`${platform}: regenerate with node tools/codegen/codegen-layout-source-emulation.cjs`
	);
	checks++;
}

// The main fixture's tables, which the drivers' composer host tests store, too.
{
	const main = Source.read(read(path.join(corpus, 'source.toml')));
	assert.deepEqual(
		clone(
			Object.fromEntries(
				['macos', 'linux', 'windows'].map((platform) => [
					platform,
					Source.compileEmulation(main, { platform })
				])
			)
		),
		JSON.parse(read(path.join(corpus, 'source_emulation.json'))),
		'regenerate with node tools/codegen/codegen-layout-source-emulation.cjs'
	);
	checks++;
}

// What even the emulation cannot perform is listed with a stable reason.
assert.deepEqual(
	golden.linux.not_emulated.map((entry) => `${entry.path}:${entry.reason}`),
	[
		'modifiers.kana_lock.keys[1]:physical_key_not_emulated',
		'modifiers.nav.keys[0]:physical_key_not_emulated',
		'layers.kana.keys.KeyJ:action_not_emulated',
		'layers.right_kana:sided_modifier_not_emulated',
		'remap.Pause:physical_key_not_emulated',
		'remap.CapsLock:modifier_key_not_emulated'
	]
);
checks++;

/** Replay one vector case on a fresh session; returns the first mismatch. */
function replay(table, steps) {
	const session = Engine.newSession(Engine.compile(table));
	for (const [index, step] of steps.entries()) {
		let got;
		if (step.press !== undefined)
			got = Engine.press(session, step.press, step.held, step.at, step.before);
		else if (step.release !== undefined) got = Engine.release(session, step.release, step.at);
		else if (step.tick !== undefined) got = { actions: Engine.tick(session, step.tick) };
		else got = { actions: Engine.reset(session) };
		const expected = { actions: step.actions };
		if (step.consumed !== undefined) expected.consumed = step.consumed;
		const actual = { actions: clone(got.actions) };
		if (step.consumed !== undefined) actual.consumed = got.consumed;
		if (JSON.stringify(actual) !== JSON.stringify(expected))
			return `step ${index}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`;
	}
	return null;
}

for (const platform of vectors.platforms)
	for (const vector of vectors.cases) {
		assert.equal(replay(golden[platform], vector.steps), null, `${platform}: ${vector.name}`);
		checks++;
	}

// The replay can fail: a changed expected action is a mismatch.
{
	const [first] = vectors.cases.filter((vector) =>
		vector.steps.some((step) => step.actions.length)
	);
	const changed = clone(first.steps);
	changed.find((step) => step.actions.length).actions[0].type = 'changed';
	assert.notEqual(replay(golden.linux, changed), null, 'the replay sees a changed action');
	checks++;
}

// Malformed tables are refused when compiled, never on a key. The engine runs in
// the loader's vm realm, so its errors are matched by message, not by class.
for (const [label, mutate, message] of [
	['format', (table) => (table.format = 'other'), /is not an ergopti-layout-emulation version 1/],
	['version', (table) => (table.version = 2), /is not an ergopti-layout-emulation version 1/],
	[
		'layer modifier',
		(table) => table.layers[2].selectors[0].required.push('unknown'),
		/unknown modifier 'unknown'/
	],
	['hold layer', (table) => (table.tap_holds[0].hold_layer = 'missing'), /unknown layer 'missing'/],
	['two holds', (table) => (table.tap_holds[0].hold_modifier = 'shift'), /needs one hold/],
	['threshold', (table) => (table.tap_holds[0].threshold_ms = 0), /malformed tap-hold/],
	[
		'mapping',
		(table) => (table.layers[0].keys.KeyX = { dead_key: 'undeclared' }),
		/malformed mapping at layers.base.KeyX/
	],
	['shared key', (table) => table.modifiers[1].keys.push('IntlBackslash'), /share the key/],
	['two roles', (table) => (table.tap_holds[0].key = 'IntlBackslash'), /two roles/]
]) {
	const table = clone(golden.linux);
	mutate(table);
	assert.throws(() => Engine.compile(table), { message }, label);
	checks++;
}

// The driver reports keep only what neither the .keylayout nor the table carries.
{
	const reports = targetReport(fixture);
	for (const [target, platform] of [
		['driver_macos', 'macos'],
		['driver_linux', 'linux']
	]) {
		const report = reports.find((entry) => entry.target === target);
		assert.equal(report.status, 'partial', target);
		const paths = report.omitted.map((entry) => entry.path);
		for (const entry of golden[platform].not_emulated)
			assert(paths.includes(entry.path), entry.path);
		assert(!paths.includes('shortcuts.KeyA'), `${target}: shortcuts are emulated`);
		assert(!paths.includes('layers.roya'), `${target}: custom layers are emulated`);
		assert(!paths.includes('modifiers.roya'), `${target}: custom modifiers are emulated`);
	}
	checks++;
}

// A key's shortcut_key: every combination but the text levels (and Ctrl+Alt, which
// Windows reports for AltGr) acts as the chosen key, on the three platforms; an
// explicit shortcut of the same combination wins; the native targets report it.
{
	const source = clone(fixture);
	source.keys = Object.assign({}, source.keys, { KeyW: { shortcut_key: 'KeyC' } });
	source.shortcuts = (source.shortcuts || []).concat([
		{ key: 'KeyW', modifiers: ['control', 'shift'], send_key: 'KeyX', send_modifiers: ['control'] }
	]);
	// It survives a write and a read of the TOML source.
	assert.deepEqual(clone(Source.read(Source.write(source)).keys.KeyW), { shortcut_key: 'KeyC' });
	const combinations = clone(Source.shortcutKeyCombinations()).map((ids) =>
		ids.slice().sort().join('+')
	);
	assert.deepEqual(combinations, [
		'control',
		'control+shift',
		'meta',
		'meta+shift',
		'control+meta',
		'control+meta+shift',
		'alt+meta',
		'alt+meta+shift'
	]);
	for (const platform of ['macos', 'linux', 'windows']) {
		const table = Source.compileEmulation(source, { platform });
		const own = table.shortcuts.filter((entry) => entry.key === 'KeyW');
		assert.equal(own.length, combinations.length, `${platform}: one shortcut per combination`);
		const explicit = own.filter((entry) => entry.send_key === 'KeyX');
		assert.deepEqual(clone(explicit.map((entry) => entry.modifiers)), [['control', 'shift']]);
		const session = Engine.newSession(Engine.compile(table));
		const press = (held) => clone(Engine.press(session, 'KeyW', held, 0));
		assert.deepEqual(press(['control']).actions, [
			{ type: 'key', key: 'KeyC', modifiers: ['control'] }
		]);
		const altMeta = press(['meta', 'alt']).actions;
		assert.equal(altMeta.length, 1);
		assert.equal(altMeta[0].key, 'KeyC');
		assert.deepEqual(altMeta[0].modifiers.slice().sort(), ['alt', 'meta']);
		assert.deepEqual(press(['control', 'shift']).actions, [
			{ type: 'key', key: 'KeyX', modifiers: ['control'] }
		]);
		// The text levels and AltGr (Ctrl+Alt on Windows) stay text.
		for (const held of [[], ['shift'], ['alt'], ['shift', 'alt'], ['control', 'alt']])
			assert.ok(
				!press(held).actions.some((action) => action.type === 'key' && action.key === 'KeyC'),
				`${platform}: ${held.join('+') || 'base'} is not a shortcut`
			);
		checks++;
	}
	// A key the drivers cannot send is reported, never dropped silently.
	const unsendable = clone(source);
	unsendable.keys.KeyW.shortcut_key = 'MacCode66';
	assert.ok(
		Source.compileEmulation(unsendable, { platform: 'linux' }).not_emulated.some(
			(entry) =>
				entry.path === 'keys.KeyW.shortcut_key' && entry.reason === 'physical_key_not_emulated'
		)
	);
	// The native targets carry it on their shortcut level (the goldens:
	// test-layout-shortcut-keys.cjs; the Windows KLC report is checked in
	// test-layout-source.cjs, with its metadata): this fixture's KeyC types nothing,
	// so the native files say only that; the drivers emulate it as well.
	const reports = targetReport(source);
	for (const [target, format] of [
		['macos', 'keylayout'],
		['linux', 'xkb']
	]) {
		const report = reports.find((entry) => entry.target === target);
		assert.deepEqual(
			clone(report.omitted.filter((entry) => entry.path === 'keys.KeyW.shortcut_key')),
			[{ path: 'keys.KeyW.shortcut_key', reason: `shortcut_key_types_nothing_in_${format}` }],
			`${target}: shortcut_key is carried natively`
		);
	}
	for (const target of ['driver_macos', 'driver_linux']) {
		const report = reports.find((entry) => entry.target === target);
		assert.ok(
			!report.omitted.some((entry) => entry.path === 'keys.KeyW.shortcut_key'),
			`${target}: shortcut_key is emulated`
		);
	}
	checks++;
}

// export-all publishes the emulation tables and the web emulation.
{
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'layout-source-emulation-'));
	try {
		const cli = (...args) =>
			spawnSync(process.execPath, [path.join(REPO_ROOT, 'tools', 'layout-source.cjs'), ...args], {
				encoding: 'utf8'
			});
		const out = path.join(temporary, 'out');
		const run = cli('export-all', path.join(corpus, 'emulation_source.toml'), out);
		assert.equal(run.status, 0, run.stderr);
		const reports = JSON.parse(read(path.join(out, 'report.json')));
		assert.deepEqual(
			reports
				.filter((report) => ['emulation', 'web'].includes(report.target))
				.map((report) => [report.target, report.status]),
			[
				['emulation', 'partial'],
				['web', 'partial']
			]
		);
		for (const platform of ['macos', 'linux', 'windows'])
			assert.deepEqual(
				JSON.parse(read(path.join(out, 'emulation', `emulation.${platform}.json`))),
				golden[platform]
			);
		assert.deepEqual(JSON.parse(read(path.join(out, 'web', 'emulation.json'))), golden.macos);
		assert.equal(
			read(path.join(out, 'web', 'emulation_fixture.keylayout')),
			Source.compileKeylayout(fixture).text
		);
		const single = path.join(temporary, 'emulation.json');
		const exported = cli('export-emulation', path.join(corpus, 'emulation_source.toml'), single);
		assert.equal(exported.status, 0, exported.stderr);
		assert.deepEqual(JSON.parse(read(single)), golden);
		assert.notEqual(
			cli('export-emulation', path.join(corpus, 'emulation_source.toml'), single).status,
			0,
			'no overwrite'
		);
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
	}
	checks++;
}

// A preserved import has no structured records to emulate.
assert.throws(
	() =>
		Source.compileEmulation(
			Source.importKeylayout(
				read(path.join(REPO_ROOT, 'static', 'layouts', 'registry', 'ergopti', 'ergopti.keylayout')),
				'ergopti',
				'iso'
			)
		),
	/source_imported_preserved/
);
checks++;

// Neo 2's own levels (layout-levels-emulation): Mod3 and Mod4 held on Caps Lock
// and AltGr as on their other keys, ¡ and ¿, and the dead keys of those levels
// composing with the native base and Shift levels. The table is the compiler's
// own, and the vectors the Lua and AutoHotkey engines replay too.
const neoGolden = JSON.parse(read(path.join(corpus, 'neo2_emulation.json')));
const neoVectors = JSON.parse(read(path.join(corpus, 'neo2_vectors.json')));
let neoReplayed = 0;
{
	const neo = Source.read(read(path.join(corpus, neoVectors.source)));
	for (const platform of neoVectors.platforms) {
		assert.deepEqual(
			clone(Source.compileEmulation(neo, { platform })),
			neoGolden[platform],
			`${platform}: regenerate with node tools/codegen/codegen-layout-source-emulation.cjs`
		);
		const model = Engine.compile(neoGolden[platform]);
		assert.equal(Engine.holdsModifierKey(model, 'AltRight'), true, `${platform}: AltGr holds Mod4`);
		assert.equal(
			Engine.holdsModifierKey(model, 'CapsLock'),
			platform !== 'macos',
			`${platform}: Caps Lock holds Mod3 where the hook sees it held`
		);
		for (const vector of neoVectors.cases) {
			if (vector.platforms && !vector.platforms.includes(platform)) continue;
			assert.equal(replay(neoGolden[platform], vector.steps), null, `${platform}: ${vector.name}`);
			neoReplayed++;
		}
	}
	assert.deepEqual(
		neoGolden.macos.not_emulated.map((entry) => `${entry.path}:${entry.reason}`),
		['modifiers.mod3.keys[0]:modifier_key_not_holdable_on_macos'],
		'macOS names Caps Lock, the one key it cannot hold Mod3 on'
	);
	for (const platform of ['linux', 'windows'])
		assert.deepEqual(
			neoGolden[platform].not_emulated,
			[],
			`${platform}: every Neo level is emulated`
		);
	assert(neoReplayed >= 3 * 16, 'every Neo vector is replayed on the three platforms');
	checks++;
}

// A layout's own repeat and magic keys (layout-context-keys-emulation): every
// platform emulates them on its native layers from the text typed before, the
// tables carry the magic tables, every native layout file leaves them out, a
// tap-hold cannot tap one, and the engine refuses a press without that text.
let contextReplayed = 0;
{
	const contextGolden = JSON.parse(read(path.join(corpus, 'context_emulation.json')));
	const contextVectors = JSON.parse(read(path.join(corpus, 'context_vectors.json')));
	const doc = Source.read(read(path.join(corpus, contextVectors.source)));
	for (const platform of contextVectors.platforms) {
		const table = clone(Source.compileEmulation(doc, { platform }));
		assert.deepEqual(
			table,
			contextGolden[platform],
			`${platform}: regenerate with node tools/codegen/codegen-layout-source-emulation.cjs`
		);
		assert.deepEqual(table.not_emulated, [], `${platform}: every repeat and magic key is emulated`);
		assert.deepEqual(Object.keys(table.magic), ['sfb'], `${platform}: the magic table travels`);
		for (const vector of contextVectors.cases) {
			assert.equal(replay(table, vector.steps), null, `${platform}: ${vector.name}`);
			contextReplayed++;
		}
		const session = Engine.newSession(Engine.compile(table));
		assert.throws(
			() => Engine.press(session, 'Quote', [], 0),
			/needs the text typed before it/,
			`${platform}: a magic key without the text before is refused`
		);
	}
	const omitted = Source.compileKeylayout(doc).omitted.map(
		(entry) => `${entry.path}:${entry.reason}`
	);
	for (const path_ of [
		'layers.base.keys.IntlBackslash',
		'layers.base.keys.Quote',
		'layers.shift.keys.IntlBackslash'
	])
		assert(
			omitted.includes(`${path_}:context_key_not_in_keylayout`),
			`the .keylayout lists ${path_} as omitted (${omitted.join(', ')})`
		);
	const tapped = clone(doc);
	tapped.tap_holds = [
		{ key: 'Space', tap: { repeat: 1 }, hold_modifier: 'shift', threshold_ms: 200 }
	];
	const tappedTable = clone(
		Source.compileEmulation(Source.validate(tapped), { platform: 'linux' })
	);
	assert.deepEqual(
		tappedTable.not_emulated,
		[{ path: 'tap_holds[0].tap', reason: 'context_key_tap_not_emulated' }],
		'a tap-hold cannot tap a repeat key'
	);
	for (const [what, spoil] of [
		['an unknown magic table', (d) => (d.layers[0].keys.Quote = { magic: 'none' })],
		['an unused magic table', (d) => d.magic.push({ id: 'other', rules: [] })],
		['a context of three characters', (d) => (d.magic[0].rules[0].after = 'the')],
		['an output of two characters', (d) => (d.magic[0].rules[0].types = 'de')],
		['a context twice', (d) => d.magic[0].rules.push({ after: 'e', types: 'f' })],
		['a repeat three places back', (d) => (d.layers[0].keys.IntlBackslash = { repeat: 3 })]
	]) {
		const spoiled = clone(doc);
		spoil(spoiled);
		assert.throws(
			() => Source.validate(spoiled),
			/source_/,
			`the source validator accepts ${what}`
		);
	}
	checks++;
}

// Layouts that hold no custom modifier on Caps Lock or AltGr and type no dead
// key on an emulated layer (ergopti-emulation-unchanged): the tables of the
// Ergopti layouts are byte for byte those pinned before the emulation held
// either key, and the engine holds neither key and no dead key for them.
{
	const { renderErgopti } = require('../codegen/codegen-layout-source-emulation.cjs');
	const pinned = read(path.join(corpus, 'ergopti_emulation.json'));
	assert.equal(renderErgopti(Source), pinned, 'the Ergopti tables are unchanged');
	for (const [file, tables] of Object.entries(JSON.parse(pinned)))
		for (const [platform, table] of Object.entries(tables)) {
			const where = `${file} on ${platform}`;
			assert.equal(table.dead_keys, undefined, `${where}: no dead key is emulated`);
			const model = Engine.compile(table);
			for (const key of ['CapsLock', 'AltRight']) {
				assert.equal(Engine.holdsModifierKey(model, key), false, `${where}: ${key} keeps its role`);
				const session = Engine.newSession(model);
				assert.deepEqual(
					clone(Engine.press(session, key, [], 0)),
					{ consumed: false, actions: [] },
					`${where}: ${key} goes to the OS`
				);
			}
		}
	checks++;
}

console.log(
	`[OK] layout source emulation: ${checks} checks (golden tables, ${vectors.cases.length} shared typing vectors per platform, ${neoReplayed} Neo 2 level replays, ${contextReplayed} repeat and magic key replays, refusals, reports, CLI)`
);
