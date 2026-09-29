// tools/test/test-layer-editor-model.cjs

/**
 * ==============================================================================
 * MODULE: Layer Editor Model Gate
 * DESCRIPTION:
 * _shared/ui/layer_editor/layer_model.js reads the user's layers.toml, applies
 * the editor's edits and writes the file back. The drivers read what it writes
 * with their own loaders, so this gate holds the model to the reference loader
 * (tools/lib/keymap-layers.cjs) and to the editing contract.
 *
 * WHAT IS CHECKED:
 * 1. Reader: over the shared keymap_layers corpus, the page refuses exactly the
 *    files every loader refuses as toml_invalid, and reads the others' layers
 *    as a TOML parser does.
 * 2. Writer: the recommended layer read and written back resolves, on every OS,
 *    to what the shipped file resolves to, and the output is inside the format.
 * 3. One OS at a time: binding any input to any value available on one OS, or
 *    giving it back its normal behaviour, changes that input on that OS and
 *    nothing on any other OS.
 * 4. Availability: the model offers an action, a shortcut modifier or a repeat
 *    count on an OS exactly when the reference loader resolves it there.
 * 5. End to end: a scripted editing session writes, byte for byte,
 *    _shared/tests/corpus/layer_editor/edited_layers.toml, the file the three
 *    drivers' bridge tests save and turn into their generated layer, and that
 *    file resolves to expected.json on every OS.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const TOML = require('smol-toml');
const { shared } = require('../lib/paths.cjs');
const { loadContext, loadLayers, formatResolution } = require('../lib/keymap-layers.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const MODEL_PATH = shared('ui', 'layer_editor', 'layer_model.js');
const DATA_PATH = shared('ui', 'layer_editor', '_generated', 'layer_data.js');
const CORPUS_PATH = shared('tests', 'corpus', 'keymap_layers', 'vectors.json');
const FIXTURE_DIR = shared('tests', 'corpus', 'layer_editor');
const FIXTURE_TOML = path.join(FIXTURE_DIR, 'edited_layers.toml');
const FIXTURE_EXPECTED = path.join(FIXTURE_DIR, 'expected.json');
const RECOMMENDED_TEXT = fs.readFileSync(shared('keymap', 'layers.recommended.toml'), 'utf8');

// Floors: nothing compared must not read as everything agreeing.
const MIN_CORPUS_VECTORS = 40;
const MIN_TOML_INVALID_VECTORS = 15;
const MIN_ISOLATION_EDITS = 600;
const MIN_AVAILABILITY_PROBES = 150;

const errors = [];
const fail = (msg) => errors.push(msg);

// Both files are classic browser scripts: run them as the page does, in one
// global scope, and read the two globals they define.
const sandbox = {};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(DATA_PATH, 'utf8'), sandbox, { filename: DATA_PATH });
vm.runInContext(fs.readFileSync(MODEL_PATH, 'utf8'), sandbox, { filename: MODEL_PATH });
const DATA = vm.runInContext('LAYER_EDITOR_DATA', sandbox);
const Model = vm.runInContext('LayerModel', sandbox);
const ctx = loadContext();
const OSES = DATA.platforms;
const LAYER = DATA.layer;

/** Every resolution of a layer file on one OS, as comparable text. */
function resolved(text, os) {
	const result = loadLayers(text, os, ctx);
	const out = {};
	for (const [layerId, bindings] of Object.entries(result.layers)) {
		for (const [code, r] of Object.entries(bindings))
			out[`${layerId}.${code}`] = formatResolution(r);
	}
	return { ok: result.ok, errors: result.errors, bindings: out };
}

/** JSON with every object's keys sorted: two maps are equal whatever their key order. */
function canonical(value) {
	if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
	if (value !== null && typeof value === 'object')
		return `{${Object.keys(value)
			.sort()
			.map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`)
			.join(',')}}`;
	return JSON.stringify(value);
}
const same = (a, b) => canonical(a) === canonical(b);
const copy = (v) => JSON.parse(JSON.stringify(v));

// =========================
// =========================
// ======= 1/ Reader =======
// =========================
// =========================

const corpus = JSON.parse(fs.readFileSync(CORPUS_PATH, 'utf8')).vectors;
if (corpus.length < MIN_CORPUS_VECTORS)
	fail(`only ${corpus.length} corpus vectors read (floor ${MIN_CORPUS_VECTORS})`);
let tomlInvalid = 0;
for (const vector of corpus) {
	// `file` names a shipped layer file under _shared/keymap/ in place of `toml`.
	const text =
		vector.file !== undefined
			? fs.readFileSync(shared('keymap', vector.file), 'utf8')
			: vector.toml;
	if (text === null) continue;
	const refused = vector.expected.errors.some((sig) => sig.startsWith('toml_invalid|'));
	const parsed = Model.parseToml(text);
	if (refused) {
		tomlInvalid += 1;
		if (parsed.problem === null)
			fail(
				`corpus "${vector.id}": every loader refuses the file as toml_invalid, the page reads it`
			);
		continue;
	}
	if (parsed.problem !== null) {
		fail(
			`corpus "${vector.id}": the loaders read the file, the page refuses it (${parsed.problem})`
		);
		continue;
	}
	const reference = TOML.parse(text.replace(/^﻿/, ''));
	if (!same(parsed.root, reference))
		fail(
			`corpus "${vector.id}": the page reads ${JSON.stringify(parsed.root)}, a TOML parser ${JSON.stringify(reference)}`
		);
}
if (tomlInvalid < MIN_TOML_INVALID_VECTORS)
	fail(`only ${tomlInvalid} toml_invalid vectors compared (floor ${MIN_TOML_INVALID_VECTORS})`);

const wrongVersion = Model.readLayerFile('[_meta]\nschema_version = 2\n', DATA);
if (wrongVersion.problem === null || Object.keys(wrongVersion.doc.layers).length !== 0)
	fail('a file of another schema version must be refused with an empty document');
if (Model.readLayerFile(null, DATA).problem !== null)
	fail('an absent file is an empty layer set, not a problem');

// =========================
// =========================
// ======= 2/ Writer =======
// =========================
// =========================

const recommendedRead = Model.readLayerFile(RECOMMENDED_TEXT, DATA);
if (recommendedRead.problem !== null)
	fail(`the page cannot read layers.recommended.toml: ${recommendedRead.problem}`);
const rewritten = Model.serialize(recommendedRead.doc, DATA);
for (const os of OSES) {
	const original = resolved(RECOMMENDED_TEXT, os);
	const written = resolved(rewritten, os);
	if (!written.ok)
		fail(
			`the rewritten recommended layer does not load on ${os}: ${JSON.stringify(written.errors)}`
		);
	if (!same(original.bindings, written.bindings))
		fail(`the rewritten recommended layer resolves differently on ${os}`);
}
if (Model.parseToml(rewritten).problem !== null) fail('the writer leaves the layer-file format');
if (!same(Model.readLayerFile(rewritten, DATA).doc, recommendedRead.doc))
	fail('writing then reading the recommended layer does not give it back');

const restored = { layers: {} };
Model.restoreRecommended(restored, LAYER, DATA.recommended);
if (Model.serialize(restored, DATA) !== rewritten)
	fail('Restore recommended does not write the recommended layer');
const cleared = copy(restored);
Model.clearLayer(cleared, LAYER);
for (const os of OSES) {
	const r = resolved(Model.serialize(cleared, DATA), os);
	if (!r.ok || Object.keys(r.bindings).length !== 0)
		fail(`Clear all leaves bindings on ${os}: ${JSON.stringify(r.bindings)}`);
}

// ======================================
// ======================================
// ======= 3/ One OS at a time ==========
// ======================================
// ======================================

const inputs = DATA.keys.filter((k) => k.geometry || k.kind !== 'key').map((k) => k.code);
let edits = 0;
for (const os of OSES) {
	const values = [null, 'keystroke:primary+shift+KeyZ'].concat(
		Object.keys(DATA.actions).filter((id) => DATA.actions[id].platforms.includes(os))
	);
	if (DATA.repeat_count.platforms.includes(os)) values.push('repeat_count:3');
	for (const code of inputs) {
		if (!Model.inputAvailability(code, os, DATA).ok) continue;
		// Two values per input keep the loop short and still cover every action.
		const picks = [values[0], values[1 + (edits % (values.length - 1))]];
		for (const value of picks) {
			const doc = copy(recommendedRead.doc);
			const before = Object.fromEntries(OSES.map((o) => [o, Model.effective(doc, LAYER, o)]));
			if (value === null) Model.makeNative(doc, LAYER, os, code, OSES);
			else Model.setBinding(doc, LAYER, os, code, value);
			edits += 1;
			for (const other of OSES) {
				const after = Model.effective(doc, LAYER, other);
				if (other === os) {
					const got = after[code] ? after[code].value : null;
					if (got !== value) fail(`${os}: binding ${code} to ${value} leaves it ${got}`);
					const rest = (m) =>
						Object.fromEntries(
							Object.entries(m)
								.filter(([c]) => c !== code)
								.map(([c, e]) => [c, e.value])
						);
					if (!same(rest(before[os]), rest(after)))
						fail(`${os}: binding ${code} changed another key on ${os}`);
				} else {
					const plain = (m) => Object.fromEntries(Object.entries(m).map(([c, e]) => [c, e.value]));
					if (!same(plain(before[other]), plain(after)))
						fail(`binding ${code} to ${value} on ${os} changed ${other}`);
				}
			}
			for (const target of OSES) {
				const r = resolved(Model.serialize(doc, DATA), target);
				if (!r.ok)
					fail(
						`binding ${code} to ${value} on ${os} writes a file ${target} refuses: ${JSON.stringify(r.errors)}`
					);
			}
		}
	}
}
if (edits < MIN_ISOLATION_EDITS)
	fail(`only ${edits} isolated edits checked (floor ${MIN_ISOLATION_EDITS})`);

const redundant = copy(recommendedRead.doc);
Model.setBinding(redundant, LAYER, 'windows', 'KeyT', 'keystroke:F3');
Model.setBinding(redundant, LAYER, 'windows', 'KeyT', redundant.layers[LAYER].all.KeyT);
if (redundant.layers[LAYER].windows && 'KeyT' in redundant.layers[LAYER].windows)
	fail('an OS entry equal to the `all` entry must be dropped, not kept as a copy');

// ===============================
// ===============================
// ======= 4/ Availability =======
// ===============================
// ===============================

let probes = 0;
const probeFile = (value) =>
	`[_meta]\nschema_version = ${DATA.schema_version}\n[layers.${LAYER}.all]\n"KeyA" = "${value}"\n`;
const probeValues = Object.keys(DATA.actions)
	.concat(DATA.modifier_order.map((m) => `keystroke:${m}+KeyB`))
	.concat([
		'keystroke:primary+KeyB',
		`repeat_count:${DATA.repeat_count.min}`,
		'unknown_action_id',
		'keystroke:KeyA+NotAKey'
	]);
for (const value of probeValues) {
	for (const os of OSES) {
		probes += 1;
		const loader = loadLayers(probeFile(value), os, ctx);
		const model = Model.bindingAvailability(value, os, DATA);
		if (model.ok !== loader.ok)
			fail(
				`"${value}" on ${os}: the page says ${model.ok ? 'available' : 'unavailable'}, the loader ${loader.ok ? 'resolves it' : JSON.stringify(loader.errors)}`
			);
		const reason = loader.errors.length === 1 ? loader.errors[0].reason_key || null : null;
		if (!model.ok && model.reason_key !== reason)
			fail(`"${value}" on ${os}: the page gives reason ${model.reason_key}, the loader ${reason}`);
	}
}
if (probes < MIN_AVAILABILITY_PROBES)
	fail(`only ${probes} availability probes (floor ${MIN_AVAILABILITY_PROBES})`);
for (const os of OSES) {
	for (const code of inputs) {
		const loader = loadLayers(
			`[_meta]\nschema_version = ${DATA.schema_version}\n[layers.${LAYER}.all]\n"${code}" = "none"\n`,
			os,
			ctx
		);
		if (Model.inputAvailability(code, os, DATA).ok !== loader.ok)
			fail(`${code} on ${os}: the page and the loader disagree whether it can be a layer key`);
	}
}

// =============================
// =============================
// ======= 5/ End to end =======
// =============================
// =============================

/**
 * The scripted editing session whose output the drivers' bridge tests save:
 * start from the recommended layer, then one edit per OS on KeyT, and KeyG
 * made native on Windows, which moves its shared binding into macOS and Linux.
 */
function editingSession() {
	const doc = { layers: {} };
	Model.restoreRecommended(doc, LAYER, DATA.recommended);
	Model.setBinding(doc, LAYER, 'windows', 'KeyT', 'arrow_up');
	Model.setBinding(doc, LAYER, 'macos', 'KeyT', 'keystroke:primary+shift+KeyZ');
	Model.setBinding(doc, LAYER, 'linux', 'KeyT', 'mute');
	Model.makeNative(doc, LAYER, 'windows', 'KeyG', OSES);
	return Model.serialize(doc, DATA);
}

const sessionText = editingSession();
if (!fs.existsSync(FIXTURE_TOML) || !fs.existsSync(FIXTURE_EXPECTED)) {
	fail(
		`${path.relative(ROOT, FIXTURE_DIR)} lacks edited_layers.toml or expected.json — the drivers' bridge tests have nothing to save`
	);
} else {
	if (fs.readFileSync(FIXTURE_TOML, 'utf8') !== sessionText)
		fail('edited_layers.toml is not what the scripted editing session writes');
	const expected = JSON.parse(fs.readFileSync(FIXTURE_EXPECTED, 'utf8'));
	for (const os of OSES) {
		const r = resolved(sessionText, os);
		if (!r.ok) fail(`edited_layers.toml does not load on ${os}: ${JSON.stringify(r.errors)}`);
		for (const [code, text] of Object.entries(expected[os] || {})) {
			const got = r.bindings[`${LAYER}.${code}`];
			if ((got === undefined ? null : got) !== text)
				fail(`edited_layers.toml on ${os}: ${code} resolves to ${got}, expected.json says ${text}`);
		}
		if (Object.keys(expected[os] || {}).length < 2)
			fail(`expected.json pins fewer than two keys on ${os}`);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the layer editor model breaks its contract:\x1b[0m');
	for (const e of errors.slice(0, 40)) console.error('    - ' + e);
	if (errors.length > 40) console.error(`    … ${errors.length - 40} more`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] layer editor model: ${corpus.length} corpus files read as the loaders read them, ${edits} single-OS edits isolated, ` +
		`${probes} availability probes agree with the loader, and the scripted session writes the drivers' fixture.\x1b[0m`
);
