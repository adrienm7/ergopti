// tools/test/test-magic-key-rules.cjs

/**
 * The magic key's display rule in the hotstring editor follows the shared one
 * (_shared/hotstrings/data/magic_key.json): the editor's format is the shared
 * format and it replays the display vectors of
 * _shared/tests/corpus/hotstrings/magic_key_vectors.json that name no locale
 * key. Every literal marker key the data lists is a locale key whose English
 * text writes the real ★, so the list cannot keep a key that left or changed.
 * The Lua and AutoHotkey twins replay the same vectors in their driver suites.
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '../..');
const SHARED = path.join(ROOT, 'static/ergopti_plus/_shared');
const SCRIPT = path.join(SHARED, 'ui/hotstring_editor/script.js');
const EVENT_WIRING_MARKER = '// ======= 15/ Event Wiring';

const data = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'hotstrings/data/magic_key.json'), 'utf8')
);
const corpus = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'tests/corpus/hotstrings/magic_key_vectors.json'), 'utf8')
);
const en = JSON.parse(fs.readFileSync(path.join(SHARED, 'core/i18n/data/locales/en.json'), 'utf8'));

const source = fs.readFileSync(SCRIPT, 'utf8');
const markerAt = source.indexOf(EVENT_WIRING_MARKER);
assert(markerAt > 0, 'the editor script must retain a separable event-wiring section');
const context = vm.createContext({
	console,
	document: { getElementById: () => null },
	makeHostBridge: () => function () {},
	setTimeout: () => 0,
	clearTimeout() {}
});
context.window = context;
vm.runInContext(
	source.slice(0, markerAt) +
		'\nglobalThis.__api = { setTrigger(c) { TRIGGER_CHAR = c; }, magicKeyDisplay, toShown,' +
		' format: MAGIC_KEY_DISPLAY_FORMAT, star: STAR };',
	context,
	{ filename: SCRIPT }
);
const api = context.__api;

let failures = 0;
function check(name, fn) {
	try {
		fn();
		console.log(`  ok  ${name}`);
	} catch (error) {
		failures += 1;
		console.error(`  FAIL ${name}: ${error.message}`);
	}
}

check('the editor shows the magic key with the shared format', () => {
	assert.strictEqual(api.format, data.display_format);
	assert.strictEqual(api.star, data.marker);
});

for (const vector of corpus.display) {
	if (vector.key !== undefined) continue;
	check(`(magic-key-display) ${vector.id}`, () => {
		api.setTrigger(vector.char);
		assert.strictEqual(api.toShown(vector.text), vector.expected);
	});
}

check('a configured character is never shown alone', () => {
	assert.strictEqual(api.magicKeyDisplay('ù'), '★ (ù)');
	assert.strictEqual(api.magicKeyDisplay('★'), '★');
});

check('every literal marker key is a locale key that writes the real ★', () => {
	for (const key of data.literal_marker_keys) {
		assert.ok(Object.hasOwn(en, key), `${key} is not an English locale key`);
		assert.ok(en[key].includes(data.marker), `${key} no longer writes ${data.marker}`);
	}
});

if (failures > 0) {
	console.error(`test-magic-key-rules: ${failures} failure(s)`);
	process.exit(1);
}
console.log('test-magic-key-rules: ok');
