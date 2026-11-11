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

// KbdEdit writes Kana on Command; macOS gets it on Option from the source.
const kbdedit = read(KBDEDIT_EXPORT);
const expected = kbdedit.replace(/<modifier keys="command( anyShift)?"\/>/g, (_, shift) =>
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

console.log(
	`[OK] layout sources: ergopti.toml reproduces the KbdEdit v2.2.2 export over ${differences(reference, model).length === 0 ? differences.states : 0} dead-key states, Kana on Option`
);
