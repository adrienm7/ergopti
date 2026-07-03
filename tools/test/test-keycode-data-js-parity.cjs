// tools/test/test-keycode-data-js-parity.cjs

/**
 * ==============================================================================
 * MODULE: Keycode Data Single-Source Guard (DC-1)
 * DESCRIPTION:
 * The keycode -> finger/hand/home map used by the typing-heatmap dashboard used
 * to be a hand-copied literal `KEYCODE_DATA` array in state.js, with no
 * mechanism catching drift against the canonical
 * `_shared/data/keycodes/azerty.json`.
 *
 * This test pins the fix:
 *   1. The generated `_generated/keycode_data.js` carries the exact
 *      kc/finger/home triples from azerty.json, in the same order.
 *   2. state.js no longer re-declares its own KEYCODE_DATA literal — it must
 *      rely on the generated global.
 *   3. index.html loads the generated script before state.js, so the global
 *      exists by the time state.js's top-level code runs.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');

const AZERTY_JSON = path.join(ROOT, 'static/ergopti_plus/_shared/data/keycodes/azerty.json');
const GENERATED_JS = path.join(
	ROOT,
	'static/ergopti_plus/_shared/ui/metrics_typing/_generated/keycode_data.js'
);
const STATE_JS = path.join(ROOT, 'static/ergopti_plus/_shared/ui/metrics_typing/state.js');
const INDEX_HTML = path.join(ROOT, 'static/ergopti_plus/_shared/ui/metrics_typing/index.html');

let _pass = 0;
let _fail = 0;
const _results = [];

/**
 * @param {string} name
 * @param {boolean} ok
 * @param {string} [detail]
 */
function test(name, ok, detail) {
	_pass += ok ? 1 : 0;
	_fail += ok ? 0 : 1;
	_results.push({ name, ok, detail });
}

function report() {
	const total = _pass + _fail;
	console.log('TAP version 14');
	console.log(`1..${total}`);
	let i = 1;
	for (const r of _results) {
		console.log(`${r.ok ? 'ok' : 'not ok'} ${i++} - ${r.name}`);
		if (!r.ok && r.detail) console.log(`  # ${r.detail}`);
	}
	console.log(`# passed: ${_pass}/${total}`);
	if (_fail > 0) {
		console.log(`# FAILED: ${_fail} test(s)`);
		process.exit(1);
	}
}

const azerty = JSON.parse(fs.readFileSync(AZERTY_JSON, 'utf8'));
const generatedJs = fs.readFileSync(GENERATED_JS, 'utf8');
const stateJs = fs.readFileSync(STATE_JS, 'utf8');
const indexHtml = fs.readFileSync(INDEX_HTML, 'utf8');

test('azerty.json has a non-empty "keys" array', Array.isArray(azerty.keys) && azerty.keys.length > 0);

// --- generated keycode_data.js carries every azerty.json entry, in order ---
{
	const lines = generatedJs
		.split(/\r?\n/)
		.filter((l) => l.trim().startsWith('{ kc:'))
		.map((l) => l.trim());
	test(
		'keycode_data.js has exactly one entry per azerty.json key',
		lines.length === azerty.keys.length,
		`azerty.json has ${azerty.keys.length} key(s), keycode_data.js has ${lines.length} entry line(s)`
	);

	azerty.keys.forEach((entry, i) => {
		const homePart = entry.home ? ', home: true' : '';
		const expected = `{ kc: ${entry.kc}, finger: '${entry.finger}'${homePart} },`;
		test(
			`keycode_data.js entry ${i} (kc ${entry.kc}) matches azerty.json`,
			lines[i] === expected,
			`expected ${JSON.stringify(expected)}, got ${JSON.stringify(lines[i])}`
		);
	});
}

// --- Regression guard: state.js must not re-declare its own literal ---
test(
	'state.js no longer declares its own KEYCODE_DATA literal array',
	!/const\s+KEYCODE_DATA\s*=\s*\[/.test(stateJs),
	'found "const KEYCODE_DATA = [" in state.js — the map must come from _generated/keycode_data.js'
);
test('state.js still references KEYCODE_DATA (consumes the generated global)', /KEYCODE_DATA/.test(stateJs));

// --- index.html loads the generated script before state.js ---
{
	const genIdx = indexHtml.indexOf('_generated/keycode_data.js');
	const stateIdx = indexHtml.indexOf('src="state.js"');
	test('index.html includes a <script> tag for _generated/keycode_data.js', genIdx !== -1);
	test(
		'index.html loads _generated/keycode_data.js before state.js',
		genIdx !== -1 && stateIdx !== -1 && genIdx < stateIdx,
		`generated script index=${genIdx}, state.js index=${stateIdx}`
	);
}

report();
