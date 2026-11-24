// tools/test/test-site-keyboard-data.cjs

/**
 * ==============================================================================
 * MODULE: Site Keyboard Data Drift Gate
 * DESCRIPTION:
 * The site's keyboard drawings read static/layouts/visualisation, whose
 * ergopti_v2.2.json and bepo.json tools/codegen/codegen-site-keyboard.cjs writes
 * from their layout source and display patch (Ergopti's, or the default patch). The rendering itself is checked in a browser
 * by tools/test/browser/site-structure.playwright.cjs (generated-keyboard).
 *
 * WHAT IS CHECKED:
 * 1. Each committed file is the generator's output for the current source
 *    and patch (no hand edit, no stale copy).
 * 2. Read independently from the raw TOML, every cell of a source key shows
 *    the source: the four text levels, the dead keys (styled, on their
 *    terminator) and what each dead key gives after the base and Shift
 *    characters; only the patch's display stand-ins differ. Each file names
 *    its dead levels by their glyph and its selectable levels, and the
 *    default patch draws no Ergopti+ level or Ergopti-only character.
 * 3. A layout change reaches the site: a changed character, a new dead-key
 *    rule. And the patch cannot drift: a value hiding the source, a stand-in
 *    for an empty cell, an unnamed dead key and an unknown source key stop
 *    the generator.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const Codegen = require('../codegen/codegen-site-keyboard.cjs');
const { shared } = require('../lib/paths.cjs');
const { loadLayoutSource } = require('../lib/layout-source.cjs');

const sourceText = fs.readFileSync(Codegen.SOURCE_PATH, 'utf8');
const patch = JSON.parse(fs.readFileSync(Codegen.PATCH_PATH, 'utf8'));

// 1/ Every committed file is current.
assert.ok(
	Codegen.LAYOUTS.some((layout) => layout.patch === undefined),
	'a layout without its own patch is drawn'
);
for (const layout of Codegen.LAYOUTS)
	assert.equal(
		fs.readFileSync(layout.output, 'utf8'),
		Codegen.render(layout),
		`${path.basename(layout.output)} is stale: npm run codegen:site-keyboard`
	);
const data = JSON.parse(fs.readFileSync(Codegen.OUT_PATH, 'utf8'));

// 2/ Every source cell, read from the raw TOML with the page's own codec.
const codec = {};
const codecPath = shared('ui', 'vendor', 'smol-toml.js');
vm.compileFunction(fs.readFileSync(codecPath, 'utf8'), ['exports'], { filename: codecPath })(codec);
const shown = (text) => text.replace(/[  ]/g, '<nbsp></nbsp>');
// The dotted-circle spelling of a few terminators, written out here.
const accent = { '^': '◌̂', '¨': '◌̈', '̣': '◌̣', '`': '◌̀' };

/**
 * Checks every source cell of a generated file against its raw TOML.
 * @returns {number} How many dead-key cells were drawn.
 */
function checkSourceCells(sourceText, patch, data) {
	const raw = codec.parse(sourceText);
	const layer = (id) => raw.layers.find((candidate) => candidate.id === id).keys;
	const deadById = new Map(raw.dead_keys.map((dead) => [dead.id, dead]));
	const glyph = (terminator) => accent[terminator] ?? Codegen.deadGlyph(terminator);
	let deadCells = 0;
	for (const key of patch.keys.filter((candidate) => candidate.source !== undefined)) {
		const cells = data.keys.find((candidate) => candidate.key === key.key);
		const display = key.display ?? {};
		for (const [level, layerId] of Object.entries(patch.levels)) {
			if (level in display) continue;
			const entry = layer(layerId)[key.source];
			if (entry?.dead_key) {
				const { terminator } = deadById.get(entry.dead_key);
				assert.equal(cells[level], glyph(terminator), `${key.key} ${level}`);
				assert.equal(cells[level + '-style'], 'deadkey', `${key.key} ${level} is a dead key`);
				deadCells++;
			} else {
				assert.equal(cells[level], entry ? shown(entry.text) : '', `${key.key} ${level}`);
				assert.notEqual(cells[level + '-style'], 'deadkey', `${key.key} ${level} is no dead key`);
			}
		}
		for (const [level, terminator] of Object.entries(patch.dead_levels)) {
			const dead = raw.dead_keys.find((candidate) => candidate.terminator === terminator);
			for (const [suffix, layerId] of [
				['', patch.levels.Primary],
				['Shift', patch.levels.Shift]
			]) {
				const entry = layer(layerId)[key.source];
				const rule = (dead.rules ?? []).find((candidate) =>
					entry?.dead_key
						? candidate.input_dead_key === entry.dead_key
						: candidate.input === entry?.text
				);
				if (level + suffix in display) continue;
				assert.equal(
					cells[level + suffix],
					entry && rule ? shown(rule.text) : '',
					`${key.key} ${level + suffix}`
				);
			}
		}
	}
	// Every dead key of the source is drawn somewhere on its own level, which
	// the data names by the glyph the emulation opens it from.
	assert.ok(deadCells >= raw.dead_keys.length, 'every dead key of the source is drawn');
	for (const dead of raw.dead_keys) {
		const level = Object.keys(patch.dead_levels).find(
			(candidate) => patch.dead_levels[candidate] === dead.terminator
		);
		assert.ok(level, `dead key ${dead.terminator} has a level`);
		assert.equal(data.dead_levels[level], glyph(dead.terminator), `${level} is named by its glyph`);
		for (const name of [level, level + 'Shift'])
			assert.ok(
				data.level_labels.some((entry) => entry.level === name),
				`${name} is in the level select`
			);
	}
	return deadCells;
}
checkSourceCells(sourceText, patch, data);

// The default patch: bépo, read from its own source, without Ergopti+.
const bepo = Codegen.LAYOUTS.find((layout) => path.basename(layout.output) === 'bepo.json');
const bepoText = fs.readFileSync(bepo.source, 'utf8');
const bepoData = JSON.parse(fs.readFileSync(bepo.output, 'utf8'));
const bepoPatch = Codegen.defaultPatch(loadLayoutSource().read(bepoText), patch, bepo.levels);
assert.ok(checkSourceCells(bepoText, bepoPatch, bepoData) >= 20, 'bépo draws its dead keys');
const bepoCell = (key) => bepoData.keys.find((candidate) => candidate.key === key);
assert.equal(bepoData.name, 'Bépo');
assert.equal(bepoCell('a').Primary, 'a', 'bépo has a on KeyA');
assert.equal(bepoCell('i').Primary, 'u', 'bépo has u on KeyS');
assert.equal(bepoCell('a').dead_005e, 'â', 'the bépo circumflex on a');
for (const key of bepoData.keys)
	for (const field of Object.keys(key))
		assert.ok(
			!field.endsWith('+') && !['Layer', 'À', ','].includes(field),
			`bépo ${key.key} draws no Ergopti+ level (${field})`
		);
assert.equal(bepoCell('ç').Primary, '', 'Ergopti’s own ErgoDox ç is blank on bépo');
assert.throws(
	() =>
		Codegen.defaultPatch(loadLayoutSource().read(bepoText), patch, {
			...bepo.levels,
			AltGr: 'kana'
		}),
	/the source has no layer kana/
);
// Concrete cells a reader can check on the page.
const cell = (key) => data.keys.find((candidate) => candidate.key === key);
assert.equal(cell('a').Primary, 'a');
assert.equal(cell('a').Circonflexe, 'â', 'the circumflex on a');
assert.equal(cell('Circonflexe').Primary, '◌̂', 'the circumflex dead key on the base level');
assert.equal(cell('Space').Primary, '␣', 'the space bar keeps its stand-in');

// 3/ A layout change reaches the site.
const changed = Codegen.build(
	sourceText.replace(/(\[layers\.keys\.KeyA\]\ntext = )"a"/, '$1"q"'),
	patch
);
assert.equal(
	changed.keys.find((candidate) => candidate.key === 'a').Primary,
	'q',
	'a changed base character is drawn'
);
const withRule = Codegen.build(
	sourceText.replace(/(\[\[dead_keys\.rules\]\]\ninput = "a"\ntext = )"â"/, '$1"ä̂"'),
	patch
);
assert.equal(
	withRule.keys.find((candidate) => candidate.key === 'a').Circonflexe,
	'ä̂',
	'a changed dead-key rule is drawn'
);
// The patch cannot hide or invent source cells.
const withKey = (entry, change) => ({
	...patch,
	keys: patch.keys.map((candidate) => (candidate.key === entry ? change(candidate) : candidate))
});
assert.throws(
	() =>
		Codegen.build(
			sourceText,
			withKey('a', (key) => ({ ...key, extra: { Primary: 'z' } }))
		),
	/would hide the layout source/
);
assert.throws(
	() =>
		Codegen.build(
			sourceText,
			withKey('a', (key) => ({ ...key, display: { R: 'x' } }))
		),
	/empty R cell/
);
assert.throws(
	() =>
		Codegen.build(
			sourceText,
			withKey('a', (key) => ({ ...key, source: 'KeyNone' }))
		),
	/the ISO drawing places KeyA, the patch reads KeyNone/
);
const unknown = withKey('a', (key) => ({ ...key, source: 'KeyNone' }));
unknown.iso = patch.iso.map((entry) => (entry.key === 'a' ? { ...entry, code: 'KeyNone' } : entry));
assert.throws(() => Codegen.build(sourceText, unknown), /the source has no key KeyNone/);
const { Greek: _unnamed, ...fewerDeadLevels } = patch.dead_levels;
assert.throws(
	() => Codegen.build(sourceText, { ...patch, dead_levels: fewerDeadLevels }),
	/has no level in the display patch/
);

console.log(
	'[OK] site keyboard data: generated from the layout source, every source cell checked, drift refused'
);
