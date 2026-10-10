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
		const text = model.formatShareable(vector.snapshot, schema, (key) => key);
		for (const canary of vector.canaries)
			assert.ok(!text.includes(canary), vector.name + ': ' + canary);

		const readable = text.split('```json')[0];
		for (const id of ['versions', 'hardware', 'system', 'input', 'ai', 'permissions', 'issues'])
			assert.ok(
				readable.includes('## healthcheck.section.' + id),
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
	assert.throws(() => model.shareSnapshot({ driver: 'foreign' }, schema));
	assert.throws(() => model.shareSnapshot(corpus.vectors[0].snapshot, {}));
	console.log(
		'[OK] diagnostic sharing: ' +
			corpus.vectors.length +
			' synthetic three-driver vectors; no native collection.'
	);
	return outputs;
};
