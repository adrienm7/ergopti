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
		'layers.roya.keys.KeyE:dead_key_not_emulated',
		'layers.kana.keys.KeyJ:action_not_emulated',
		'layers.right_kana:sided_modifier_not_emulated',
		'tap_holds[3].tap:dead_key_not_emulated',
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
		if (step.press !== undefined) got = Engine.press(session, step.press, step.held, step.at);
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
		(table) => (table.layers[0].keys.KeyX = { dead_key: 'acute' }),
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

console.log(
	`[OK] layout source emulation: ${checks} checks (golden tables, ${vectors.cases.length} shared typing vectors per platform, refusals, reports, CLI)`
);
