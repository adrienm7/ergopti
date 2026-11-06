// tools/test/test-metrics-key-names.cjs

/**
 * ==============================================================================
 * MODULE: Metrics Heatmap Key Names
 * DESCRIPTION:
 * Executes the real key name table projection, its page helper and
 * heatmap_win.js, and asserts that the keyboard heatmap names its special keys
 * from _shared/data/keycodes/key_names.json in the user's language and for the
 * recording OS.
 *
 * ROOT CAUSE ENCODED:
 * The Windows and Linux heatmap printed « Espace », « Entrée », « Maj » in French
 * in every locale (a hardcoded label map), and the macOS one printed the
 * hs.keycodes.map ids (`return`, `cmd`, `rightalt`).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const UI = path.resolve(__dirname, '..', '..', 'static', 'ergopti_plus', '_shared', 'ui');
const LOCALES = path.join(UI, '..', 'data', 'locales');
const read = (...parts) => fs.readFileSync(path.join(UI, ...parts), 'utf8');

/**
 * Loads the page scripts with one locale catalogue.
 * @param {string} locale Locale code.
 * @returns {{ strings: object, build: Function, name: Function }}
 */
function page(locale) {
	const strings = JSON.parse(fs.readFileSync(path.join(LOCALES, locale + '.json'), 'utf8'));
	const window = { _i18n_strings: strings };
	const source = [
		read('_generated', 'key_names.js'),
		read('key_names.js'),
		read('metrics_typing', 'heatmap_win.js')
	];
	const api = new Function(
		'window',
		`${source.join('\n')}\nreturn { build: build_keycode_layout_for_driver, name: name_keycode_layout };`
	)(window);
	return { strings, ...api };
}

let checks = 0;
for (const locale of ['fr', 'en', 'de', 'ar']) {
	const { strings, build, name } = page(locale);
	const win = name(build({ os: 'win' }, { 30: 'a' }), { os: 'win' });
	assert.equal(win['49'], strings['key_name.space'], `${locale}: Windows Space`);
	assert.equal(win['56'], strings['key_name.shift'], `${locale}: Windows Shift`);
	assert.equal(win['54'], strings['key_name.alt_gr'], `${locale}: Windows AltGr`);
	assert.equal(win['123'], '←', `${locale}: the arrows keep their glyph`);
	assert.equal(win['0'], 'a', `${locale}: the active layout still names letters`);
	const mac = name({ 36: 'return', 55: 'cmd', 61: 'rightalt', 0: 'a' }, { os: 'mac' });
	assert.equal(mac['36'], strings['key_name.enter'], `${locale}: macOS Return`);
	assert.equal(mac['0'], 'a', `${locale}: macOS letters unchanged`);
	assert.equal(
		name({ 55: 'cmd' }, undefined)['55'],
		mac['55'],
		`${locale}: no driver_meta is macOS`
	);
	for (const label of [...Object.values(win), ...Object.values(mac)])
		assert.ok(!/^key_name\./.test(label), `${locale}: unresolved ${label}`);
	checks += 1;
}
const fr = page('fr');
const en = page('en');
assert.notEqual(
	fr.name({}, { os: 'win' })['53'],
	en.name({}, { os: 'win' })['53'],
	'Escape reads in each language, not in French everywhere'
);
assert.throws(() => fr.name({}, { os: 'beos' }), /unknown driver OS/);

const html = read('metrics_typing', 'index.html');
const order = ['../_generated/key_names.js', '../key_names.js', 'heatmap_win.js'].map((src) =>
	html.indexOf(`<script src="${src}"></script>`)
);
assert.ok(
	order.every((at) => at >= 0),
	'the page loads the key name table and its helper'
);
assert.ok(
	order[0] < order[1] && order[1] < order[2],
	'the table loads before its helper and the heatmap'
);
assert.ok(
	!/'Entrée'|'Espace'|'Verr\. Maj'/.test(read('metrics_typing', 'heatmap_win.js')),
	'no French key label left'
);

console.log(
	`\x1b[32m[OK] Metrics heatmap key names: ${checks} locales, Windows and macOS layouts.\x1b[0m`
);
