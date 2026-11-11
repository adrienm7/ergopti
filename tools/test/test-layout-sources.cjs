// tools/test/test-layout-sources.cjs

/**
 * ==============================================================================
 * MODULE: Layout Sources Fidelity Test
 * DESCRIPTION:
 * Proves that the layout sources kept in static/layouts/sources/ reproduce the
 * layouts they were made from, every key, level and dead-key state:
 *   - ergopti.toml against KbdEdit's macOS export of Ergopti v2.2.2, whose
 *     Command level is the Windows Kana level: the source names it `kana`,
 *     which the macOS target compiles to the Option level.
 *   - bepo.toml against the official bepo.klc, table for table, and the four
 *     Windows DLLs built from each source read back as those tables.
 * The equivalence oracle walks every reachable pair of dead-key states and
 * compares the output of every key of every keyMap; a mutation control shows
 * it can fail.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadLayoutSource } = require('../lib/layout-source.cjs');
const { REPO_ROOT } = require('../lib/paths.cjs');

const Source = loadLayoutSource();
const Composer = Source.composer;
const SOURCES = path.join(REPO_ROOT, 'static', 'layouts', 'sources');
const KBDEDIT_EXPORT = path.join(
	REPO_ROOT,
	'static',
	'ergopti',
	'macos',
	'raw_kbdedit_keylayouts',
	'Ergopti_v2.2.2_v0.keylayout'
);
const read = (file) => fs.readFileSync(file, 'utf8');

/**
 * Behavioural differences of two .keylayout models: selectors in order, then
 * from every reachable pair of dead-key states every key of every keyMap.
 * @returns {string[]}
 */
function differences(a, b) {
	const tokens = (keys) => keys.map((k) => k.split(/\s+/).filter(Boolean).sort().join(' '));
	const found = [];
	if (a.selects.length !== b.selects.length) return ['keyMapSelect count'];
	a.selects.forEach((select, i) => {
		if (JSON.stringify(tokens(select.keys)) !== JSON.stringify(tokens(b.selects[i].keys)))
			found.push(`keyMapSelect ${i}: ${select.keys} != ${b.selects[i].keys}`);
	});
	const seen = new Set();
	const queue = [['none', 'none']];
	let states = 0;
	while (queue.length) {
		const [sa, sb] = queue.shift();
		if (seen.has(`${sa}\0${sb}`)) continue;
		seen.add(`${sa}\0${sb}`);
		states++;
		a.selects.forEach((select, i) => {
			for (let code = 0; code < 128; code++) {
				const x = Composer.step(a, sa, select.index, code);
				const y = Composer.step(b, sb, b.selects[i].index, code);
				if (x.output !== y.output)
					found.push(`${sa}/${sb} map ${i} code ${code}: ${x.output} != ${y.output}`);
				if (x.next !== 'none' || y.next !== 'none') queue.push([x.next, y.next]);
			}
		});
	}
	differences.states = states;
	return found;
}

// KbdEdit writes Kana on Command and numbers the two keys Apple numbers apart the
// ANSI way (50 left of 1, 10 the ISO key); the compiled source is ISO-numbered.
const kbdedit = read(KBDEDIT_EXPORT);
const isoNumbered = kbdedit.replace(
	/(<key code=")(10|50)(")/g,
	(_, a, code, b) => `${a}${code === '10' ? '50' : '10'}${b}`
);
const expected = isoNumbered.replace(/<modifier keys="command( anyShift)?"\/>/g, (_, shift) =>
	shift ? '<modifier keys="anyOption anyShift"/>' : '<modifier keys="anyOption"/>'
);
assert.notEqual(expected, kbdedit, 'the export selects its Kana level with Command');

const source = Source.read(read(path.join(SOURCES, 'ergopti.toml')));
const kanaLayers = source.layers.filter((layer) => layer.required.includes('kana'));
assert.deepEqual(
	kanaLayers.map((layer) => layer.id),
	['kana', 'shift_kana'],
	'the Kana level and its Shift'
);
assert.ok(
	!source.layers.some((layer) => layer.required.includes('meta')),
	'no Command level is left'
);
const compiled = Source.compileKeylayout(source);
const model = Composer.parseModel(compiled.text);
const reference = Composer.parseModel(expected);
assert.deepEqual(differences(reference, model), [], 'ergopti.toml types as the KbdEdit export');
assert.ok(differences.states >= 8, 'the walk visits every dead-key state');
assert.deepEqual(JSON.parse(JSON.stringify(compiled.omitted)), [], 'nothing is left out on macOS');

// No collision with Ergopti's own Option: its macOS layout already types this level
// with Option, key for key (and ê sits on the ISO key, $ left of 1, as there).
const registry = Composer.parseModel(
	read(path.join(REPO_ROOT, 'static', 'layouts', 'registry', 'ergopti', 'ergopti.keylayout'))
);
for (const level of [0, 2, 5, 6])
	for (let code = 0; code < 51; code++)
		assert.equal(
			Composer.step(model, 'none', model.selects[level].index, code).output,
			Composer.step(registry, 'none', registry.selects[level].index, code).output,
			`level ${level} code ${code} matches the registry Ergopti macOS layout`
		);
assert.equal(source.layers[0].keys.IntlBackslash.text, 'ê');
assert.equal(source.layers[0].keys.Backquote.text, '$');

// The oracle can fail: one changed Kana-level output is a difference.
const mutated = expected.replace(/(<keyMap index="5">[\s\S]*?output=")([^"&]+)"/, '$1Ж"');
assert.notEqual(mutated, expected, 'mutation target present');
assert.ok(
	differences(Composer.parseModel(mutated), model).length > 0,
	'a changed Kana cell is seen'
);

// A source that already has an Alt level keeps Kana out of the native layout, saying why.
const withAlt = JSON.parse(JSON.stringify(source));
withAlt.layers.push({
	id: 'alt',
	required: ['alt_right'],
	optional: [],
	keys: { KeyA: { text: 'æ' } }
});
const shared = Source.compileKeylayout(Source.read(Source.write(withAlt)));
assert.ok(
	shared.omitted.some(
		(entry) => entry.path === 'layers.kana' && entry.reason === 'kana_level_taken_by_alt'
	),
	'the Kana level gives way to an Alt level of its own'
);

// =================================================
// ======= Windows tables: KLC, source and DLL =====
// =================================================

const { fromKlc } = require('../lib/kbd-dll/klc.cjs');
const KbdSource = require('../lib/kbd-dll/source.cjs');
const { buildDlls, toolchainAvailable } = require('../lib/kbd-dll/build.cjs');
const { readDll } = require('../lib/kbd-dll/reader.cjs');
const { compareLayout } = require('../lib/kbd-dll/compare.cjs');

/** A model in a canonical form: sorted object keys, keys by virtual key. */
function canonical(model) {
	const plain = JSON.parse(JSON.stringify(model));
	plain.keys.sort((a, b) => a.vk - b.vk);
	plain.dead_keys.sort((a, b) => a.dead - b.dead);
	for (const dead of plain.dead_keys) dead.rules.sort((a, b) => a.base - b.base);
	return JSON.stringify(plain, (key, value) =>
		value && typeof value === 'object' && !Array.isArray(value)
			? Object.fromEntries(
					Object.keys(value)
						.sort()
						.map((k) => [k, value[k]])
				)
			: value
	);
}

/** Builds the four DLL images of a model; each must read back as it. */
function provenDlls(model, label) {
	assert.ok(
		toolchainAvailable(),
		'clang, llvm-rc and lld-link are required (tools/ci/ubuntu_apt.py clang lld llvm)'
	);
	const { dlls } = buildDlls(model);
	assert.deepEqual(
		Object.keys(dlls).sort(),
		['arm64', 'wow64', 'x64', 'x86'],
		`${label}: four images`
	);
	for (const [arch, bytes] of Object.entries(dlls))
		assert.deepEqual(
			compareLayout(model, readDll(bytes).layout),
			[],
			`${label} ${arch} reads back as its tables`
		);
	return dlls;
}

// Bépo: the source gives back the official KLC's tables, and its DLLs carry them.
const klcModel = fromKlc(
	fs.readFileSync(path.join(REPO_ROOT, 'tools', 'test', 'fixtures', 'kbd-dll', 'bepo.klc'))
);
const bepo = Source.read(read(path.join(SOURCES, 'bepo.toml')));
const fromBepo = KbdSource.fromSource(bepo);
assert.deepEqual(
	JSON.parse(JSON.stringify(fromBepo.omitted)),
	[],
	'bépo: nothing left out on Windows'
);
assert.equal(
	canonical(fromBepo.model),
	canonical(klcModel),
	'bepo.toml gives back bepo.klc, table for table'
);
assert.equal(klcModel.dead_keys.length, 20, 'bépo: its 20 dead keys');
provenDlls(fromBepo.model, 'bépo');
// The oracle can fail: one changed AltGr cell is a difference.
const changed = JSON.parse(JSON.stringify(bepo));
changed.layers.find((layer) => layer.id === 'altgr').keys.KeyA = { text: 'Ж' };
assert.notEqual(
	canonical(KbdSource.fromSource(changed).model),
	canonical(klcModel),
	'a changed cell is seen'
);
// The macOS target compiles it too, every dead key with it.
const bepoMac = Source.compileKeylayout(bepo);
assert.equal(
	(bepoMac.text.match(/<when state="none" next="/g) || []).length >= 20,
	true,
	'bépo: every dead key enters its state on macOS'
);

// Ergopti: Kana is the real KBDKANA column, held by Right Alt (VK_OEM_8), and
// each Kana cell is the KbdEdit export's Command cell.
const ergoptiWindows = KbdSource.fromSource(source);
const ergoptiTables = ergoptiWindows.model;
assert.deepEqual(
	JSON.parse(JSON.stringify(ergoptiWindows.omitted)).map(
		(entry) => `${entry.path}:${entry.reason}`
	),
	['keys.NumpadEqual:no_windows_scan_code', 'keys.NumpadEnter:shares_a_virtual_key'],
	'Ergopti on Windows leaves out only what Windows has no key for'
);
assert.deepEqual(
	[...ergoptiTables.columns],
	[0, 1, 2, 8, 9],
	'base, Shift, Ctrl, Kana, Shift+Kana'
);
assert.deepEqual(JSON.parse(JSON.stringify(ergoptiTables.modifier_vks)), { kana: 0xdf });
assert.deepEqual(JSON.parse(JSON.stringify(ergoptiTables.scancodes_e0)), [{ sc: 0x38, vk: 0xdf }]);
const exported = Composer.parseModel(isoNumbered);
const commandIndex = exported.selects.find((select) => select.keys.join(' ') === 'command').index;
const physical = JSON.parse(
	read(
		path.join(
			REPO_ROOT,
			'static',
			'ergopti_plus',
			'_shared',
			'data',
			'keycodes',
			'physical_keys.json'
		)
	)
).keys;
let kanaCells = 0;
for (const [code, mapping] of Object.entries(
	source.layers.find((layer) => layer.id === 'kana').keys
)) {
	// Control outputs (Enter, Tab…) are the system keys' own, not the layout's.
	if (typeof mapping.text !== 'string' || /[\u0000-\u001f]/.test(mapping.text)) continue;
	if (!physical[code]) continue; // no Windows key: listed in fromSource's omitted
	const mac = physical[code].macos_iso ? physical[code].macos_iso.hs : physical[code].hs;
	assert.equal(
		Composer.step(exported, 'none', commandIndex, mac).output,
		mapping.text,
		`kana ${code}`
	);
	kanaCells++;
}
assert.ok(kanaCells > 40, 'the Kana level is checked key by key');
provenDlls(ergoptiTables, 'Ergopti');

console.log(
	`[OK] layout sources: ergopti.toml reproduces the KbdEdit v2.2.2 export over ${differences(reference, model).length === 0 ? differences.states : 0} dead-key states (Kana on Option; KBDKANA in its 4 DLLs), bepo.toml gives back bepo.klc and its 4 DLLs read back exactly`
);
