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
		fs.readFileSync(path.join(shared, 'diagnostics/data/schema.json'), 'utf8')
	);
	schema.export_strings = JSON.parse(
		fs.readFileSync(path.join(shared, 'core/i18n/data/locales/en.json'), 'utf8')
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
		// One readable line per probe; the earlier runs are counted, and their
		// facts stay in the JSON block
		assert.ok(
			readable.includes(
				'\nappleevent_transport: timeout (cleanup=pending, native_status=-1744, ms=99)\n'
			)
		);
		assert.ok(readable.includes('\nretired_runs: ' + safe.retired_probes.length + '\n'));
		assert.ok(!/\| --- \|/.test(readable), 'the readable report has no Markdown table');
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
		assert.ok(!text.includes('page.'), 'no page check is reported before the page sent one');
		assert.ok(!Object.hasOwn(safe.sections, 'paths'));
		assert.ok(!Object.hasOwn(safe.sections.issues, 'last_error'));
		if (vector.name.endsWith('collector-labels')) {
			assert.equal(
				safe.sections.versions.runtime,
				{ windows: '2.0.19', macos: '1.1.1', linux: '2.1.0-beta3' }[safe.driver]
			);
			assert.equal(
				safe.sections.system.os,
				{ windows: 'Windows 10.0.26100.1', macos: 'macOS 15.5', linux: 'Ubuntu 24.04' }[safe.driver]
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
		fs.readFileSync(path.join(shared, 'layouts/data/layer_actions.toml'), 'utf8'),
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
			// One fenced "key = value" line per changed setting; a text or a list
			// says it is only a length or a count
			for (const row of vector.expected) {
				const unit =
					row.type === 'text'
						? ' ' + schema.export_strings['healthcheck.export.characters']
						: row.type === 'list'
							? ' ' + schema.export_strings['healthcheck.export.items']
							: '';
				assert.ok(document.includes('\n' + row.setting + ' = ' + row.value + unit + '\n'), label);
			}
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
			assert.ok(text.includes('\nconfiguration: ' + state), label);
			// A configuration that was not read claims no setting either way
			const changed = text.split(
				schema.export_strings['healthcheck.export.changed_settings'] + '\n'
			)[1];
			assert.ok(
				changed.startsWith(
					schema.export_strings[
						state === 'ok' ? 'healthcheck.value.none' : 'healthcheck.value.unknown'
					] + '\n'
				),
				label + ' changed settings'
			);
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

	// The readable report, byte for byte as share.lua and report.ahk write it:
	// the host refuses a page preview that differs from its own text
	const reports = JSON.parse(
		fs.readFileSync(path.join(shared, 'tests/corpus/healthcheck/report_vectors.json'), 'utf8')
	);
	for (const vector of reports.vectors) {
		const text = model.formatShareable(vector.snapshot, schema, (key) => key);
		assert.equal(text.split('\n```json\n')[0], vector.diagnostics, 'report vector ' + vector.id);
		assert.ok(!text.includes('PRIVATE_USER_ZEBRA'), vector.id + ' leaked a path');
	}
	// A config.toml with many changed settings: the bug link is cut in the
	// settings, the last group, and keeps every error, check and permission
	// whole (the settings used to come first and cut the errors off the link)
	vm.runInContext(fs.readFileSync(path.join(shared, 'ui/issue_link.js'), 'utf8'), sandbox);
	const templates = JSON.parse(
		fs.readFileSync(path.join(shared, 'diagnostics/data/issue_templates.json'), 'utf8')
	);
	const repository = JSON.parse(
		fs.readFileSync(path.join(shared, 'updater/data/defaults.json'), 'utf8')
	).github;
	const base = reports.vectors.find((vector) => vector.id === reports.large.vector);
	const large = JSON.parse(JSON.stringify(base.snapshot));
	for (let index = 0; index < reports.large.rows; index++)
		large.sections.configuration.items.push({
			setting: reports.large.setting_prefix + index,
			type: 'text',
			value: '9'
		});
	const head = model.formatShareable(large, schema, (key) => key).split('\n```json\n')[0];
	const note = schema.export_strings[schema.share_policy.truncated_note_key];
	const url = sandbox.ErgoptiIssueLink.buildIssueUrl(
		templates,
		repository,
		'bug',
		{ version: '1.0.10-dev.178', driver: 'macOS', os: 'macOS 15.1', diagnostics: head },
		{ diagnostics: note }
	);
	assert.ok(url.length <= templates.max_url_bytes, 'the bug link fits its budget');
	assert.ok(url.length > templates.max_url_bytes - 64, 'the bug link fills its budget');
	const prefilled = decodeURIComponent(/[?&]diagnostics=([^&]*)/.exec(url)[1]);
	const settingsTitle = '## ' + schema.export_strings['healthcheck.export.changed_settings'];
	assert.ok(
		prefilled.startsWith(base.diagnostics.split(settingsTitle)[0] + settingsTitle),
		'every group before the changed settings reaches the link whole'
	);
	assert.ok(prefilled.includes('\ngestures.enabled = false\n'), 'the first changed settings fit');
	assert.ok(prefilled.endsWith(templates.truncation_marker + '\n\n' + note));
	console.log(
		'[OK] diagnostic sharing: ' +
			corpus.vectors.length +
			' synthetic three-driver vectors; no native collection.'
	);
	return outputs;
};
