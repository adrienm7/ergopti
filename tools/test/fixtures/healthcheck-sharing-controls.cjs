// tools/test/fixtures/healthcheck-sharing-controls.cjs

/** Exercises the real sharing projection with synthetic canaries on all drivers. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

exports.run = function run(root) {
	const shared = path.join(root, 'static/ergopti_plus/_shared');
	const schema = JSON.parse(
		fs.readFileSync(path.join(shared, 'modules/diagnostics/schema.json'), 'utf8')
	);
	schema.export_strings = JSON.parse(
		fs.readFileSync(path.join(shared, 'data/locales/en.json'), 'utf8')
	);
	const corpus = JSON.parse(
		fs.readFileSync(path.join(shared, 'tests/corpus/healthcheck/share_vectors.json'), 'utf8')
	);
	const sandbox = { Number, JSON };
	sandbox.window = sandbox;
	vm.createContext(sandbox);
	for (const name of ['dom_utils.js', 'healthcheck/model.js'])
		vm.runInContext(fs.readFileSync(path.join(shared, 'ui', name), 'utf8'), sandbox, {
			filename: name
		});
	const model = sandbox.ErgoptiDiagnostics;
	const outputs = [];
	for (const vector of corpus.vectors) {
		const safe = model.shareSnapshot(vector.snapshot, schema);
		const text = model.formatShareable(
			vector.snapshot,
			schema,
			(key) => 'LOCALIZED-EXPORT-CANARY:' + key
		);
		for (const canary of vector.canaries)
			assert.ok(!text.includes(canary), vector.name + ': ' + canary);

		assert.ok(
			!text.includes('LOCALIZED-EXPORT-CANARY:'),
			'Sharing must use canonical English without consulting UI locale'
		);
		const readable = text.split('```json')[0];
		for (const id of ['versions', 'hardware', 'system', 'input', 'ai', 'permissions', 'issues'])
			assert.ok(
				readable.includes('## ' + schema.export_strings['healthcheck.section.' + id]),
				'readable section omitted: ' + id
			);
		assert.ok(readable.includes('| probes.appleevent_transport.native_status | -1744 |'));
		assert.ok(readable.includes('| probes.appleevent_transport.cleanup | pending |'));
		assert.ok(
			readable.includes('| retired_probes.1.probes.appleevent_transport.cleanup | unknown |')
		);
		assert.deepEqual(
			JSON.parse(text.split('```json\n')[1].split('\n```')[0]),
			JSON.parse(JSON.stringify(safe))
		);

		assert.equal(safe.driver, vector.snapshot.driver);
		assert.equal(safe.sections.versions.commit, 'a'.repeat(40));
		assert.equal(safe.sections.versions.ergopti_version, '0.0.0-dev.156');
		assert.equal(safe.probes.appleevent_transport.state, 'timeout');
		assert.equal(safe.probes.appleevent_transport.cleanup, 'pending');
		assert.equal(safe.probes.appleevent_transport.native_status, -1744);
		assert.equal(safe.retired_probes[0].probes.appleevent_transport.cleanup, 'unknown');
		assert.ok(!Object.hasOwn(safe, 'diagnostic_checks'));
		assert.ok(text.includes('page-model-checks: not_collected'));
		assert.ok(!Object.hasOwn(safe.sections, 'paths'));
		assert.ok(!Object.hasOwn(safe.sections.issues, 'last_error'));
		if (vector.name.endsWith('collector-labels')) {
			assert.equal(
				safe.sections.versions.runtime,
				{ windows: '2.0.19', macos: '1.1.1', linux: '2.1.0-beta3' }[safe.driver]
			);
			assert.equal(
				safe.sections.system.os,
				{ windows: '10.0.26100.1', macos: '15.5', linux: '24.04' }[safe.driver]
			);
		} else assert.ok(!Object.hasOwn(safe.sections.system, 'os'));
		const input = JSON.stringify(vector.snapshot);
		model.shareSnapshot(vector.snapshot, schema);
		assert.equal(
			JSON.stringify(vector.snapshot),
			input,
			'projection must not mutate the collector'
		);
		outputs.push({ name: vector.name, snapshot: JSON.parse(JSON.stringify(safe)) });
	}

	const facts = JSON.parse(
		fs.readFileSync(
			path.join(shared, 'tests/corpus/healthcheck/recent_error_fact_vectors.json'),
			'utf8'
		)
	);
	for (const vector of facts.vectors) {
		const original = JSON.stringify(vector.snapshot);
		const document = model.formatShareable(vector.snapshot, schema, () => 'PRIVATE_LOCALE');
		const safe = model.shareSnapshot(vector.snapshot, schema);
		assert.deepEqual(
			JSON.parse(JSON.stringify(safe.sections.issues.recent_error_facts)),
			vector.expected
		);
		for (const canary of facts.canaries) assert.ok(!document.includes(canary), canary);
		assert.ok(
			document.includes('lease_watchdog_exit') && document.includes('log_observation_only')
		);
		assert.ok(document.includes('excluded_entries'));
		assert.equal(JSON.stringify(vector.snapshot), original);
	}
	// The configuration section: a path, a sentence or a token cannot be shared
	// whatever type a row claims (negative controls shared with the Lua and AHK
	// replays of the same file).
	const configuration = JSON.parse(
		fs.readFileSync(
			path.join(shared, 'tests/corpus/healthcheck/configuration_share_vectors.json'),
			'utf8'
		)
	);
	// The collectors and the projection share one list of files and states.
	const spec = schema.configuration;
	const projected =
		schema.share_policy.projection.fields.sections.fields.configuration_files.fields.items.item
			.fields;
	assert.deepEqual(projected.id.values, ['defaults', ...Object.keys(spec.file_names)]);
	assert.deepEqual(projected.state.values, spec.states);
	for (const [driver, ids] of Object.entries(spec.files))
		for (const id of ids)
			assert.ok(id === 'defaults' || spec.file_names[id], driver + ' lists an unknown file ' + id);
	assert.match(
		fs.readFileSync(path.join(shared, 'keymap/layer_actions.toml'), 'utf8'),
		new RegExp('^user_file = "' + spec.file_names.layers.replace('.', '\\.') + '"', 'm'),
		'the layers file name is the layer vocabulary user_file'
	);
	for (const rel of [
		'../windows/platform/remap/tap_hold_loader.ahk',
		'../linux/platform/remap/tap_hold_loader.lua'
	])
		assert.ok(
			fs.readFileSync(path.join(shared, rel), 'utf8').includes(spec.file_names.tap_hold),
			rel + ' reads the configured tap-hold file name'
		);
	for (const driver of ['windows', 'macos', 'linux'])
		for (const vector of configuration.vectors) {
			const snapshot = {
				schema_version: 2,
				driver,
				generated_at: '2026-10-20T10:00:00Z',
				detailed: false,
				extensive: false,
				sections: {
					configuration: { items: vector.items },
					configuration_files: { items: configuration.files }
				}
			};
			const label = driver + ': ' + vector.id;
			const safe = model.shareSnapshot(snapshot, schema);
			assert.deepEqual(
				JSON.parse(JSON.stringify(safe.sections.configuration.items)),
				vector.expected,
				label
			);
			assert.deepEqual(
				JSON.parse(JSON.stringify(safe.sections.configuration_files.items)),
				configuration.expected_files,
				label + ' files'
			);
			const document = model.formatShareable(snapshot, schema, (key) => key);
			for (const canary of configuration.canaries)
				assert.ok(!document.includes(canary), label + ' leaked ' + canary);
			for (const row of vector.expected)
				assert.ok(
					document.includes('| ' + row.setting + ' | ' + row.type + ': ' + row.value + ' |'),
					label
				);
		}
	// The configuration comes from a probe: until it answers, and whenever it
	// does not, the report says so explicitly instead of showing empty sections.
	const probeStates = [
		['pending', {}, 'healthcheck.probe.pending'],
		['not_run', { reason: 'opt_in_required' }, 'healthcheck.probe.not_run'],
		[
			'timeout',
			{ detail: 'deadline_expired', cleanup: 'settled', ms: 2100 },
			'healthcheck.probe.timeout'
		],
		[
			'error',
			{ cleanup: 'settled', detail: 'C:\\Users\\PRIVATE_USER_ZEBRA\\notes' },
			'healthcheck.probe.error'
		],
		['ok', { cleanup: 'settled', ms: 12 }, 'healthcheck.value.none']
	];
	for (const driver of ['windows', 'macos', 'linux'])
		for (const [state, extra, note] of probeStates) {
			const snapshot = {
				schema_version: 2,
				driver,
				generated_at: '2026-10-20T10:00:00Z',
				detailed: false,
				extensive: false,
				sections: { configuration: { items: [] }, configuration_files: { items: [] } },
				probes: { configuration: Object.assign({ state }, extra) }
			};
			const label = driver + ': configuration probe ' + state;
			const safe = model.shareSnapshot(snapshot, schema);
			assert.equal(safe.probes.configuration.state, state, label);
			const text = model.formatShareable(snapshot, schema, (key) => key);
			assert.ok(text.includes('| probes.configuration.state | ' + state + ' |'), label);
			assert.ok(!text.includes('PRIVATE_USER_ZEBRA'), label + ' leaked a path');
			const page = model.formatMarkdown(snapshot, schema, (key) => key);
			assert.ok(page.includes(note), label + ' shows ' + note);
		}
	assert.equal(schema.probes.configuration.local, true, 'the configuration probe is local');
	assert.ok(
		schema.probes.configuration.timeout_ms <= 5000,
		'the configuration deadline is bounded'
	);
	const crowded = Array.from({ length: 801 }, (_, index) => ({
		setting: 'script.k' + index,
		type: 'boolean',
		value: 'true'
	}));
	assert.equal(
		model.shareSnapshot(
			{
				schema_version: 2,
				driver: 'windows',
				generated_at: '2026-10-20T10:00:00Z',
				sections: { configuration: { items: crowded } }
			},
			schema
		).sections.configuration.items.length,
		800,
		'the configuration rows are bounded'
	);
	assert.throws(() => model.shareSnapshot({ driver: 'foreign' }, schema));
	assert.throws(() => model.shareSnapshot(corpus.vectors[0].snapshot, {}));
	console.log(
		'[OK] diagnostic sharing: ' +
			corpus.vectors.length +
			' synthetic three-driver vectors; no native collection.'
	);
	return outputs;
};
