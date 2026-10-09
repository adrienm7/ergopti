// tools/test/fixtures/diagnostic-summary-controls.cjs

/** Checks the real HTML and Markdown summaries against independent outcomes. */
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
	const sandbox = {};
	sandbox.window = sandbox;
	vm.createContext(sandbox);
	for (const name of ['dom_utils.js', 'healthcheck/model.js', 'healthcheck/checks.js'])
		vm.runInContext(fs.readFileSync(path.join(shared, 'ui', name), 'utf8'), sandbox, {
			filename: name
		});
	const model = sandbox.ErgoptiDiagnostics;
	const t = (key, value) => key + (value === undefined ? '' : ':' + value);
	function snapshot(driver, selected) {
		const sections = {};
		for (const section of schema.sections) {
			if (section.kind !== 'summary' && (!section.platforms || section.platforms.includes(driver)))
				sections[section.id] = section.kind === 'items' ? { items: [] } : {};
		}
		sections.input.keymap_resolved = true;
		const probes = {};
		for (const [id, definition] of Object.entries(schema.probes)) {
			if (!definition.platforms || definition.platforms.includes(driver))
				probes[id] = selected
					? { state: 'ok', cleanup: 'settled' }
					: { state: 'not_run', reason: 'opt_in_required' };
		}
		const checks = {
			schema_fields: { state: 'ok' },
			probe_inventory: { state: 'ok' },
			redaction: { state: 'ok' },
			driver_suites: { state: 'not_run', reason: 'not_embedded' },
			install_reload_profile: { state: 'not_run', reason: 'isolated_environment_required' }
		};
		return {
			schema_version: 2,
			driver,
			extensive: selected,
			detailed: false,
			sections,
			probes,
			diagnostic_checks: checks
		};
	}
	let count = 0;
	const failures = [];
	function verify(name, value, expected, failed) {
		try {
			const html = model.renderHtml(value, schema, t);
			const htmlSummary = /id="section-summary"[\s\S]*?<\/section>/.exec(html);
			assert.ok(htmlSummary, 'actual summary section missing');
			const markdown = model.formatMarkdown(value, schema, t);
			const markdownSummary = /## healthcheck.section.summary\n[\s\S]*?(?=\n## |$)/.exec(markdown);
			assert.ok(markdownSummary, 'actual Markdown summary missing');
			assert.ok(htmlSummary[0].includes(expected), name + ': HTML must contain scoped outcome');
			assert.ok(
				markdownSummary[0].includes(expected),
				name + ': Markdown must contain scoped outcome'
			);
			assert.ok(
				!htmlSummary[0].includes('healthcheck.problem.none'),
				name + ': old overall green is forbidden'
			);
			assert.ok(
				!markdownSummary[0].includes('healthcheck.problem.none'),
				name + ': old overall Markdown green is forbidden'
			);
			assert.ok(markdownSummary[0].includes('healthcheck.summary.scope'));
			const failures = model
				.problems(value, schema)
				.filter((problem) => problem.key === 'healthcheck.problem.diagnostic_check');
			assert.equal(failures.length, failed, name + ': failure classification');
			if (expected !== 'healthcheck.summary.observed')
				assert.ok(!htmlSummary[0].includes('class="ok"'));
			console.log('[OK] diagnostics-summary: ' + name);
			count += 1;
		} catch (error) {
			failures.push({ name, message: error.message, stack: error.stack });
			console.error('[FAIL] diagnostics-summary: ' + name + ': ' + error.message);
		}
	}
	for (const driver of ['windows', 'macos', 'linux'])
		verify(
			'intentional quick NOT_RUN is neutral on ' + driver,
			snapshot(driver, false),
			'healthcheck.summary.quick',
			0
		);
	for (const id of ['schema_fields', 'redaction']) {
		const value = snapshot('windows', true);
		value.diagnostic_checks[id] = { state: 'error' };
		verify(
			id + ' failure cannot be overall green',
			value,
			'healthcheck.problem.diagnostic_check',
			1
		);
	}
	for (const state of ['error', 'timeout', 'cancelled', 'not_run', 'pending']) {
		const value = snapshot('macos', true);
		value.probes.appleevent_transport = {
			state,
			cleanup: state === 'cancelled' ? 'pending' : 'settled'
		};
		verify(
			'AppleEvent ' + state,
			value,
			state === 'error' || state === 'timeout'
				? 'healthcheck.problem.diagnostic_check'
				: 'healthcheck.summary.incomplete',
			state === 'error' || state === 'timeout' ? 1 : 0
		);
	}
	const archived = snapshot('macos', true);
	archived.retired_probes = [
		{ probes: { appleevent_transport: { state: 'cancelled', cleanup: 'pending' } } }
	];
	verify('archived cleanup debt remains incomplete', archived, 'healthcheck.summary.incomplete', 0);
	const unknown = snapshot('macos', true);
	unknown.probes.appleevent_transport.cleanup = 'unknown';
	verify(
		'unconfirmed cleanup cannot turn a completed result green',
		unknown,
		'healthcheck.summary.incomplete',
		0
	);
	const complete = snapshot('macos', true);
	verify(
		'healthy recorded controls retain a limited positive scope',
		complete,
		'healthcheck.summary.observed',
		0
	);
	assert.ok(model.formatMarkdown(complete, schema, t).includes('NOT_RUN'));
	console.log(
		'diagnostics-summary-controls=' +
			(count + failures.length) +
			'; passed=' +
			count +
			'; failed=' +
			failures.length
	);
	if (failures.length)
		throw new Error(
			failures.length +
				' actual diagnostic summary control(s) failed.\n' +
				failures.map((failure) => failure.stack).join('\n')
		);
	return count;
};
