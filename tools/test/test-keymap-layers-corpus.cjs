// tools/test/test-keymap-layers-corpus.cjs

/**
 * ==============================================================================
 * MODULE: Layer-File Schema Corpus (JS Replay)
 * DESCRIPTION:
 * Replays _shared/tests/corpus/keymap_layers/vectors.json through the JS
 * reference loader (tools/lib/keymap-layers.cjs). The same vectors run through
 * the shared Lua loader in the macOS and Linux suites and through the AHK
 * loader in the Windows suite, so the four implementations of the layer-file
 * schema agree on every accepted file, every rejected one and every answer.
 *
 * WHAT IS CHECKED:
 * 1. Each vector's errors (as code|layer|section|key|reason_key signatures) and
 *    resolved layers equal the hand-written expectation, and `ok` is exactly
 *    "no error".
 * 2. Coverage: every error code the schema defines is exercised, every OS is
 *    resolved, and every binding form is resolved at least once — so a new
 *    rule cannot ship with no vector that would notice it breaking.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { shared } = require('../lib/paths.cjs');
const {
	loadContext,
	loadLayers,
	formatResolution,
	errorSignature
} = require('../lib/keymap-layers.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const CORPUS_PATH = shared('tests', 'corpus', 'keymap_layers', 'vectors.json');
const KEYMAP_DIR = shared('keymap');

// Floor: a corpus that stopped being read would otherwise pass with nothing replayed.
const MIN_VECTORS = 25;
// Every code the layer-file schema can report. A code added to a loader without
// a vector here stays untested on three of the four implementations.
const ERROR_CODES = [
	'toml_invalid',
	'schema_version_missing',
	'schema_version_unsupported',
	'unknown_field',
	'invalid_value_type',
	'invalid_layer_id',
	'unknown_layer_section',
	'unknown_key',
	'unknown_action',
	'invalid_parameter',
	'invalid_keystroke',
	'unavailable_on_os'
];
const RESOLUTION_FORMS = [
	/^keystroke:.*@repeat$/,
	/^keystroke:[^@]*$/,
	/^call:/,
	/^repeat_count:\d+$/,
	/^none$/
];

const errors = [];
const fail = (msg) => errors.push(msg);

if (!fs.existsSync(CORPUS_PATH)) {
	console.error(
		`\x1b[31m[FAIL] ${path.relative(ROOT, CORPUS_PATH)} is missing — the layer-file schema has no cross-driver contract.\x1b[0m`
	);
	process.exit(1);
}

const corpus = JSON.parse(fs.readFileSync(CORPUS_PATH, 'utf8'));
const ctx = loadContext();
const vectors = Array.isArray(corpus.vectors) ? corpus.vectors : [];
if (vectors.length < MIN_VECTORS) fail(`only ${vectors.length} vectors (floor ${MIN_VECTORS})`);

const seenCodes = new Set();
const seenOses = new Set();
const seenForms = new Set();
const ids = new Set();

for (const v of vectors) {
	const where = `vector "${v.id}"`;
	if (typeof v.id !== 'string' || ids.has(v.id)) fail(`${where}: missing or duplicate id`);
	ids.add(v.id);
	if (!ctx.platforms.includes(v.os)) {
		fail(`${where}: os "${v.os}" is not one of ${ctx.platforms.join(', ')}`);
		continue;
	}
	const hasFile = typeof v.file === 'string';
	if (hasFile === Object.prototype.hasOwnProperty.call(v, 'toml')) {
		fail(`${where}: needs exactly one of "toml" and "file"`);
		continue;
	}
	const text = hasFile ? fs.readFileSync(path.join(KEYMAP_DIR, v.file), 'utf8') : v.toml;
	if (text !== null && typeof text !== 'string') {
		fail(`${where}: "toml" must be a string or null`);
		continue;
	}
	seenOses.add(v.os);
	const result = loadLayers(text, v.os, ctx);
	const actualErrors = result.errors.map(errorSignature).sort();
	const expectedErrors = [...v.expected.errors].sort();
	for (const sig of expectedErrors) seenCodes.add(sig.split('|')[0]);
	if (JSON.stringify(actualErrors) !== JSON.stringify(expectedErrors))
		fail(
			`${where}: errors ${JSON.stringify(actualErrors)}, expected ${JSON.stringify(expectedErrors)}`
		);
	if (result.ok !== (actualErrors.length === 0))
		fail(`${where}: ok is ${result.ok} with ${actualErrors.length} error(s)`);
	const actualLayers = {};
	for (const [layerId, bindings] of Object.entries(result.layers)) {
		actualLayers[layerId] = {};
		for (const [code, r] of Object.entries(bindings))
			actualLayers[layerId][code] = formatResolution(r);
	}
	const expectedLayers = v.expected.layers;
	for (const layerId of new Set([...Object.keys(actualLayers), ...Object.keys(expectedLayers)])) {
		const a = actualLayers[layerId];
		const e = expectedLayers[layerId];
		if (!a || !e) {
			fail(
				`${where}: layer "${layerId}" is ${a ? 'loaded but not expected' : 'expected but not loaded'}`
			);
			continue;
		}
		for (const code of new Set([...Object.keys(a), ...Object.keys(e)])) {
			if (a[code] !== e[code])
				fail(
					`${where}: ${layerId}.${code} resolves to ${a[code] || '(nothing)'}, expected ${e[code] || '(nothing)'}`
				);
			for (let i = 0; i < RESOLUTION_FORMS.length; i++)
				if (e[code] && RESOLUTION_FORMS[i].test(e[code])) seenForms.add(i);
		}
	}
}

for (const code of ERROR_CODES)
	if (!seenCodes.has(code)) fail(`no vector expects the error code "${code}"`);
for (const os of ctx.platforms) if (!seenOses.has(os)) fail(`no vector resolves for ${os}`);
RESOLUTION_FORMS.forEach((form, i) => {
	if (!seenForms.has(i)) fail(`no vector expects a resolution matching ${form}`);
});

if (errors.length > 0) {
	console.error(
		'\x1b[31m[FAIL] the JS layer loader disagrees with the cross-driver layer-file corpus:\x1b[0m'
	);
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] ${vectors.length} layer-file vectors replayed through the JS loader; ${ERROR_CODES.length} error codes, ` +
		`${ctx.platforms.length} OSes and every binding form covered.\x1b[0m`
);
