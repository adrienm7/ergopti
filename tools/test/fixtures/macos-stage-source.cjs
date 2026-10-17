// tools/test/fixtures/macos-stage-source.cjs
'use strict';

/** Selects actual guarded role steps; job graph and source predicates remain unchanged. */
const assert = require('node:assert/strict');
const raw = require('../ci-pipeline.cjs');
const stage = Object.freeze({
	'test-hs': 'test-hs',
	'e2e-hs': 'e2e-hs',
	'tooltip-canvas': 'e2e-hs',
	'managed-ollama-native': 'e2e-hs',
	'managed-ollama-build': 'e2e-hs',
	'item36-native': 'e2e-hs',
	'lease-silence-native': 'e2e-hs',
	'package-macos': 'package-macos',
	launch: 'launch',
	'cold-bootstrap-native': 'launch',
	'macos-ok': 'macos-ok'
});
function expression(value) {
	return value
		.trim()
		.replace(/^\$\{\{\s*/, '')
		.replace(/\s*\}\}$/, '')
		.trim();
}
/** Transpose an independently authored old step's metadata to its admitted cell fields. */
function metadata(value, role) {
	assert.ok(Object.hasOwn(stage, role), 'Unknown Mac role');
	if (typeof value === 'string')
		return value.replace(/matrix\.(role|runner|architecture|scenario)/g, (_, field) =>
			role === 'test-hs'
				? 'fromJSON(steps.stage-selection.outputs.cell).' + field
				: 'env.MACOS_STAGE_' + field.toUpperCase()
		);
	if (Array.isArray(value)) return value.map((part) => metadata(part, role));
	if (value && typeof value === 'object')
		return Object.fromEntries(
			Object.entries(value).map(([key, part]) => [key, metadata(part, role)])
		);
	return value;
}
function condition(role, predicate = null) {
	assert.ok(Object.hasOwn(stage, role), 'Unknown Mac role');
	if (role === 'test-hs' || role === 'macos-ok') return predicate;
	const parts = ["steps.stage-admission.outcome == 'success'"];
	if (role !== 'package-macos') parts.push("env.MACOS_STAGE_ROLE == '" + role + "'");
	if (['item36-native', 'lease-silence-native'].includes(role))
		parts.push("(github.event_name == 'workflow_dispatch' && !inputs.release)");
	if (predicate) parts.push('(' + expression(metadata(predicate, role)) + ')');
	return '${{ ' + parts.join(' && ') + ' }}';
}
function selected(job, role) {
	assert.ok(Object.hasOwn(stage, role), 'Unknown Mac role');
	const marker = "env.MACOS_STAGE_ROLE == '" + role + "'";
	const found = raw.steps(job).filter((step) => raw.stepField(step.body, 'if')?.includes(marker));
	assert.ok(found.length > 0, 'Missing Mac role ' + role);
	for (const step of found) {
		const predicate = raw.stepField(step.body, 'if');
		const prefix = condition(role).slice(0, -3);
		assert.ok(
			predicate === condition(role) || predicate.startsWith(prefix + ' && ('),
			'Unadmitted Mac role predicate'
		);
	}
	return found;
}
function body(source, role) {
	assert.ok(Object.hasOwn(stage, role), 'Unknown Mac role');
	const jobs = raw
		.jobsOfText(source, '.github/workflows/ci-macos.yml')
		.filter((job) => job.id === stage[role]);
	assert.equal(jobs.length, 1, 'Missing or duplicate Mac stage');
	return (
		'    steps:\n' +
		selected(jobs[0].body, role)
			.map((step) => step.body)
			.join('\n')
	);
}
module.exports = { stage, metadata, condition, selected, body };
