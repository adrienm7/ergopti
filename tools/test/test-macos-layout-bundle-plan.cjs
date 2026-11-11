// tools/test/test-macos-layout-bundle-plan.cjs

/**
 * ==============================================================================
 * MODULE: macOS Layout Bundle Plan Test
 * DESCRIPTION:
 * Checks, on any OS, the typing vectors the native macOS bundle check feeds to
 * UCKeyTranslate: they come from the TOML source and the ANSI rule, and every
 * one-key vector agrees with the cell of the compiled .keylayout, so a native
 * failure on the Mac means macOS read the files differently, not a wrong plan.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const { build, iconPng } = require('./macos-layout-bundle-native.cjs');

const { compiled, plan } = build();
const text = (suffix) => compiled.files.find((file) => file.path.endsWith(suffix)).text;
const xml = {
	iso: text('/source_fixture.keylayout'),
	ansi: text('/source_fixture_ansi.keylayout')
};
const unescape = (value) =>
	value
		.replace(/&#x([0-9A-F]+);/gi, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
		.replace(/&lt;/g, '<')
		.replace(/&gt;/g, '>')
		.replace(/&quot;/g, '"')
		.replace(/&amp;/g, '&');

/** The map index the compiled modifierMap selects for a Carbon modifier state. */
function mapIndex(modifiers) {
	const byState = { 0: 0, 2: 1, 4: 1, 64: 2 };
	assert.ok(Object.hasOwn(byState, modifiers), `unplanned modifier state ${modifiers}`);
	return byState[modifiers];
}

/** The output, or the no-state output of the action, of one compiled cell. */
function cell(variant, code, modifiers) {
	const source = xml[variant];
	const map = source.split(`<keyMap index="${mapIndex(modifiers)}">`)[1].split('</keyMap>')[0];
	const key = new RegExp(`<key code="${code}" (output|action)="([^"]*)"`).exec(map);
	assert.ok(key, `${variant}: no cell for code ${code}`);
	if (key[1] === 'output') return unescape(key[2]);
	const action = source.split(`<action id="${key[2]}">`)[1].split('</action>')[0];
	return unescape(/<when state="none" output="([^"]*)"/.exec(action)[1]);
}

assert.deepEqual(
	[...plan.sources],
	['com.apple.keyboardlayout.source_fixture', 'com.apple.keyboardlayout.source_fixture.ansi']
);
const single = plan.vectors.filter((vector) => vector.keys.length === 1);
const sequences = plan.vectors.filter((vector) => vector.keys.length > 1);
assert.ok(single.length >= 20, 'the plan types every one-scalar mapping');
assert.equal(sequences.length, 6, 'three dead-key sequences per variant');
for (const vector of single)
	assert.equal(
		cell(vector.variant, vector.keys[0].code, vector.keys[0].modifiers),
		vector.expected,
		`${vector.variant} ${vector.name}`
	);
// Every dead-key sequence types its expectation through the compiled states (the
// order of a chain is checked here, not first on the Mac).
const { loadLayoutSource } = require('../lib/layout-source.cjs');
const Composer = loadLayoutSource().composer;
for (const vector of sequences) {
	const parsed = Composer.parseModel(xml[vector.variant]);
	let state = 'none';
	let typed = '';
	for (const press of vector.keys) {
		const step = Composer.step(parsed, state, mapIndex(press.modifiers), press.code);
		typed += step.output;
		state = step.next;
	}
	assert.equal(
		typed,
		vector.expected,
		`${vector.variant} ${vector.name} through the compiled states`
	);
}
// The ANSI rule moved the ISO key: the two variants differ where the rule says.
const at = (variant, name) => plan.vectors.find((v) => v.variant === variant && v.name === name);
assert.notEqual(
	at('iso', 'base:none:IntlBackslash').keys[0].code,
	at('ansi', 'base:none:IntlBackslash').keys[0].code
);
assert.equal(at('ansi', 'remap:KeyW').expected, 'z', 'the native remap types its target');
// Each variant carries the icon the native check requires macOS to list.
for (const name of ['source_fixture.icns', 'source_fixture_ansi.icns'])
	assert.ok(
		compiled.files.some((file) => file.path.endsWith(`/Resources/${name}`)),
		name
	);
assert.equal(Buffer.from(iconPng()).subarray(1, 4).toString('latin1'), 'PNG');
console.log(
	`[OK] macOS bundle native plan: ${single.length} one-key vectors match the compiled cells, ${sequences.length} dead-key sequences`
);
