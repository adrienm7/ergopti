// tools/test/fixtures/diagnostic-checks-controls.cjs

/** Executes the actual model, redactor and check owner with an inert timer port. */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');

exports.run = function run(root) {
	const shared = path.join(root, 'static/ergopti_plus/_shared');
	const schema = JSON.parse(
		fs.readFileSync(path.join(shared, 'modules/diagnostics/schema.json'), 'utf8')
	);
	const rules = JSON.parse(
		fs.readFileSync(path.join(shared, 'modules/diagnostics/redaction.json'), 'utf8')
	);
	const sandbox = {};
	sandbox.window = sandbox;
	vm.createContext(sandbox);
	for (const name of ['dom_utils.js', 'healthcheck/model.js', 'redact.js', 'healthcheck/checks.js'])
		vm.runInContext(fs.readFileSync(path.join(shared, 'ui', name), 'utf8'), sandbox, {
			filename: name
		});
	const checks = sandbox.ErgoptiDiagnosticChecks;
	const redact = sandbox.ErgoptiRedact.apply;
	let count = 0;
	function verify(name, body) {
		body();
		count += 1;
		console.log('[OK] diagnostic-checks: ' + name);
	}
	function snapshot(selected, detailed) {
		const sections = {};
		for (const section of schema.sections) {
			if (
				section.kind !== 'summary' &&
				(!section.platforms || section.platforms.includes('windows'))
			)
				sections[section.id] = {};
		}
		const probes = {};
		for (const [id, definition] of Object.entries(schema.probes)) {
			if (!definition.platforms || definition.platforms.includes('windows'))
				probes[id] = selected
					? { state: 'pending' }
					: { state: 'not_run', reason: 'opt_in_required' };
		}
		return {
			schema_version: 2,
			driver: 'windows',
			extensive: selected,
			detailed: detailed,
			sections,
			probes
		};
	}
	function drive(value, redactor) {
		const queued = new Map();
		const published = [];
		let serial = 0;
		const run = checks.start(
			value,
			schema,
			rules,
			redactor || redact,
			(id, result) => published.push({ id, state: result.state }),
			(fn) => {
				queued.set(++serial, fn);
				return serial;
			},
			(id) => queued.delete(id)
		);
		value.diagnostic_checks = run.results;
		return {
			run,
			queued,
			published,
			pump() {
				while (queued.size) {
					const [id, fn] = queued.entries().next().value;
					queued.delete(id);
					fn();
				}
			}
		};
	}
	verify('quick export never schedules tests even with privacy opt-in', () => {
		const value = snapshot(false, true);
		const owner = drive(value);
		assert.equal(owner.queued.size, 0);
		assert.equal(owner.published.length, 0);
		assert.equal(value.diagnostic_checks.schema_fields.state, 'not_run');
		assert.equal(value.diagnostic_checks.schema_fields.reason, 'opt_in_required');
	});
	verify('explicit opt-in runs three checks and retains two unavailable suites', () => {
		const value = snapshot(true, false);
		const owner = drive(value);
		owner.pump();
		assert.deepEqual(owner.published, [
			{ id: 'schema_fields', state: 'ok' },
			{ id: 'probe_inventory', state: 'ok' },
			{ id: 'redaction', state: 'ok' }
		]);
		assert.equal(value.diagnostic_checks.driver_suites.state, 'not_run');
		assert.equal(value.diagnostic_checks.driver_suites.reason, 'not_embedded');
		assert.equal(
			value.diagnostic_checks.install_reload_profile.reason,
			'isolated_environment_required'
		);
	});
	verify('missing canonical section fails the real schema control', () => {
		const value = snapshot(true, false);
		delete value.sections.paths;
		drive(value).pump();
		assert.equal(value.diagnostic_checks.schema_fields.state, 'error');
	});
	verify('undeclared host probe fails exact inventory', () => {
		const value = snapshot(true, false);
		value.probes.unknown_probe = { state: 'ok' };
		drive(value).pump();
		assert.equal(value.diagnostic_checks.probe_inventory.state, 'error');
	});
	verify('identity redactor cannot pass the independent synthetic oracle', () => {
		const value = snapshot(true, false);
		drive(value, (text) => text).pump();
		assert.equal(value.diagnostic_checks.redaction.state, 'error');
	});
	verify('cancel suppresses an already dequeued continuation and retains completed data', () => {
		const value = snapshot(true, false);
		const owner = drive(value);
		const [firstId, first] = owner.queued.entries().next().value;
		owner.queued.delete(firstId);
		first();
		const late = owner.queued.entries().next().value[1];
		assert.equal(owner.run.cancel(), true);
		assert.equal(owner.run.cancel(), false);
		late();
		assert.deepEqual(owner.published, [
			{ id: 'schema_fields', state: 'ok' },
			{ id: 'probe_inventory', state: 'cancelled' },
			{ id: 'redaction', state: 'cancelled' }
		]);
		assert.equal(value.diagnostic_checks.schema_fields.state, 'ok');
		assert.equal(owner.queued.size, 0);
	});
	verify('same report formatter carries precise scope, cancellation and cleanup debt', () => {
		const value = snapshot(true, false);
		const owner = drive(value);
		owner.run.cancel();
		value.probes.github_api = { state: 'cancelled', cleanup: 'pending', ms: 15 };
		const text = sandbox.ErgoptiDiagnostics.formatMarkdown(value, schema, (key) => key);
		assert.ok(text.includes('schema_fields, diagnostics-model): CANCELLED'));
		assert.ok(text.includes('driver_suites, isolated-suite): NOT_RUN'));
		assert.ok(text.includes('github_api (host-probe): CANCELLED, 15 ms'));
		assert.ok(text.includes('healthcheck.probe.cleanup_pending'));
		assert.ok(!text.includes('api_key=diagnostic_key_123456789'));
	});
	verify('invalid host result remains exportable and cannot produce PASS', () => {
		const value = snapshot(false, false);
		value.probes.github_api = null;
		assert.ok(
			checks.report(value, schema, (key) => key).includes('github_api (host-probe): ERROR')
		);
	});
	verify('Markdown preserves exact cleanup uncertainty for current and retired probes', () => {
		for (const cleanup of ['pending', 'settled', 'unknown', undefined, null, 'secret-token']) {
			const value = snapshot(true, false);
			const result = { state: 'cancelled', ms: 15 };
			if (cleanup !== undefined) result.cleanup = cleanup;
			value.probes.github_api = result;
			value.retired_probes = [{ probes: { github_api: { ...result } } }];
			const text = sandbox.ErgoptiDiagnostics.formatMarkdown(value, schema, (key) => key);
			const expected = ['pending', 'settled', 'unknown'].includes(cleanup) ? cleanup : 'unknown';
			for (const scope of ['host-probe', 'retired-host-probe'])
				assert.ok(
					text.includes('github_api (' + scope + '): CANCELLED, 15 ms, cleanup=' + expected)
				);
			assert.ok(!checks.report(value, schema, (key) => key).includes('secret-token'));
		}
	});
	return count;
};
