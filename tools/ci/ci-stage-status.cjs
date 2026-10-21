/*
 * tools/ci/ci-stage-status.cjs
 * ============================================================================
 * Validates genuine adjacent scheduler results forwarded by OS job outputs.
 * Status custody never substitutes for source-bound native evidence.
 * ============================================================================
 */
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { loadPlan } = require('./linux-install-matrix.cjs');

// Each OS lane's chain, in order: unit -> integration -> E2E -> build -> install.
const JOBS = Object.freeze({
	windows: ['test-ahk', 'integration-ahk', 'e2e-ahk', 'package-windows', 'launch-windows'],
	linux: ['test-linux', 'integration-linux', 'e2e-linux', 'package-linux', 'install-linux']
});
// The E2E link of each chain: Build admits the chain up to and including it.
const E2E = Object.freeze({ windows: 'e2e-ahk', linux: 'e2e-linux' });
// What a chain job forwards beyond the custody outputs. Linux E2E reports the
// result of the integration stage it follows, which gates the manual
// diagnostic build; Linux Build hands the install cells their authored plan.
const EXTRA_OUTPUTS = Object.freeze({
	'e2e-linux': ['ci_integration_result'],
	'package-linux': ['install_matrix', 'install_metadata']
});
// A job that runs beside the last chain job and is needed by the same verdict:
// the Linux Flatpak is built from the package job's bundle while the install
// cells run, so it is a sibling of the install job, not a link of the chain.
const SIBLINGS = Object.freeze({ linux: 'package-flatpak' });
const OUTPUTS = ['ci_attempt', 'ci_predecessors', 'ci_run_id', 'ci_source_sha'];
const RESULTS = ['success', 'failure', 'cancelled', 'skipped'];

/** Read one finite JSON record, rejecting absent or malformed custody. */
function record(raw) {
	assert.equal(typeof raw, 'string', 'Scheduler custody must be a JSON string');
	assert.ok(raw.length > 0 && raw.length <= 65536, 'Scheduler custody is missing or oversized');
	const value = JSON.parse(raw);
	// JSON.parse validates syntax but accepts duplicate keys. Tokenize only its
	// already-valid strings and containers to refuse last-wins status aliases.
	const stack = [],
		string = /"(?:\\.|[^"\\])*"/y;
	for (let cursor = 0; cursor < raw.length; ) {
		const char = raw[cursor],
			parent = stack.at(-1);
		if (char === '"') {
			string.lastIndex = cursor;
			const token = string.exec(raw);
			assert.ok(token, 'Incomplete scheduler string');
			if (parent?.object && parent.key) {
				const key = JSON.parse(token[0]);
				assert.ok(!parent.keys.has(key), 'Duplicate scheduler field');
				parent.keys.add(key);
			}
			cursor = string.lastIndex;
			continue;
		}
		if (char === '{' || char === '[') {
			assert.ok(stack.length < 16, 'Scheduler custody depth refused');
			stack.push({ object: char === '{', key: true, keys: new Set() });
		} else if (char === '}' || char === ']') stack.pop();
		else if (char === ':' && parent) parent.key = false;
		else if (char === ',' && parent) parent.key = true;
		cursor++;
	}
	assert.ok(
		value && !Array.isArray(value) && typeof value === 'object',
		'Expected a scheduler object'
	);
	return value;
}

/** Require the exact keys of a scheduler or output record. */
function keys(value, expected) {
	assert.ok(value && !Array.isArray(value) && typeof value === 'object');
	assert.deepEqual(
		Object.keys(value).sort(),
		[...expected].sort(),
		'Scheduler custody keys differ'
	);
}

/** Bind every reused producer to this run and source, permitting prior attempts. */
function context(value) {
	assert.match(value.sourceSha, /^[a-f0-9]{40}$/, 'Invalid scheduler source');
	assert.match(value.runId, /^[1-9][0-9]*$/, 'Invalid scheduler run');
	assert.match(value.attempt, /^[1-9][0-9]*$/, 'Invalid scheduler attempt');
	assert.ok(Number.isSafeInteger(Number(value.attempt)), 'Scheduler attempt is not finite');
	assert.ok(['push', 'pull_request', 'workflow_dispatch'].includes(value.event));
	return value;
}

/** Admit a preceding job output and return only its genuine direct needs. */
function predecessor(job, name, current) {
	keys(job, ['result', 'outputs']);
	assert.ok(RESULTS.includes(job.result), 'Unknown scheduler result');
	keys(job.outputs, [...OUTPUTS, ...(EXTRA_OUTPUTS[name] ?? [])]);
	if (name === 'package-linux') {
		const plan = loadPlan(path.resolve(__dirname, '../..'));
		assert.equal(
			job.outputs.install_matrix,
			JSON.stringify(plan.matrix),
			'Linux package matrix differs from the complete authored plan'
		);
		assert.equal(
			job.outputs.install_metadata,
			JSON.stringify(plan.metadata),
			'Linux package metadata differs from the complete authored map'
		);
	}
	assert.equal(job.outputs.ci_source_sha, current.sourceSha, 'Foreign scheduler source');
	assert.equal(job.outputs.ci_run_id, current.runId, 'Foreign scheduler run');
	assert.match(job.outputs.ci_attempt, /^[1-9][0-9]*$/, 'Invalid producer attempt');
	assert.ok(
		Number.isSafeInteger(Number(job.outputs.ci_attempt)) &&
			Number(job.outputs.ci_attempt) <= Number(current.attempt),
		'Future or invalid producer attempt'
	);
	return record(job.outputs.ci_predecessors);
}

/** Restore the original exact job map from a closed adjacent chain. */
function collect(platform, raw, current, highest) {
	assert.ok(Object.hasOwn(JOBS, platform), 'Unknown OS status lane');
	context(current);
	const names = JOBS[platform];
	let direct = record(raw);
	const result = {};
	let downstreamAttempt = Number(current.attempt);
	for (let index = highest; index >= 0; index--) {
		keys(direct, [names[index]]);
		const job = direct[names[index]];
		keys(job, ['result', 'outputs']);
		assert.ok(RESULTS.includes(job.result), 'Unknown scheduler result');
		result[names[index]] = { result: job.result };
		if (index === 0) {
			keys(job.outputs, []);
			continue;
		}
		direct = predecessor(job, names[index], current);
		const attempt = Number(job.outputs.ci_attempt);
		assert.ok(attempt <= downstreamAttempt, 'Producer lineage runs backward');
		downstreamAttempt = attempt;
		if (names[index] === 'e2e-linux') {
			keys(direct, [names[index - 1]]);
			assert.equal(
				job.outputs.ci_integration_result,
				direct[names[index - 1]].result,
				'Integration predicate differs from genuine Integration result'
			);
		}
	}
	return Object.fromEntries(names.slice(0, highest + 1).map((name) => [name, result[name]]));
}

/** Preserve the existing Linux manual diagnostic build after failed E2E. */
function admitBuild(platform, raw, current) {
	assert.ok(Object.hasOwn(JOBS, platform), 'Unknown OS status lane');
	const names = JOBS[platform];
	const e2e = E2E[platform];
	const result = collect(platform, raw, current, names.indexOf(e2e));
	for (const name of names.slice(0, names.indexOf(e2e)))
		assert.equal(result[name].result, 'success', `${name} did not succeed`);
	assert.ok(
		result[e2e].result === 'success' ||
			(platform === 'linux' &&
				current.event === 'workflow_dispatch' &&
				result[e2e].result === 'failure'),
		'E2E does not admit this build'
	);
	return result;
}

/** Require every mandatory actual result before passing native evidence onward. */
function complete(platform, raw, current) {
	const names = JOBS[platform];
	assert.ok(names, 'Unknown OS status lane');
	const last = names.length - 1;
	const direct = record(raw);
	const sibling = SIBLINGS[platform];
	keys(direct, sibling ? [names[last], sibling] : [names[last]]);
	assert.equal(direct[names[last]].result, 'success', 'Aggregate Testbuild did not succeed');
	const chain = JSON.stringify({ [names[last]]: direct[names[last]] });
	const result = collect(platform, chain, current, last);
	for (const name of names) assert.equal(result[name].result, 'success', `${name} did not succeed`);
	if (sibling) {
		const job = direct[sibling];
		keys(job, ['result', 'outputs']);
		assert.equal(job.result, 'success', `${sibling} did not succeed`);
		keys(job.outputs, OUTPUTS);
		assert.equal(job.outputs.ci_source_sha, context(current).sourceSha, 'Foreign sibling source');
		assert.equal(job.outputs.ci_run_id, current.runId, 'Foreign sibling run');
		assert.match(job.outputs.ci_attempt, /^[1-9][0-9]*$/, 'Invalid sibling attempt');
		assert.ok(
			Number.isSafeInteger(Number(job.outputs.ci_attempt)) &&
				Number(job.outputs.ci_attempt) <= Number(current.attempt),
			'Future or invalid sibling attempt'
		);
		// The sibling must have consumed the very package job the install job did.
		assert.deepEqual(
			record(job.outputs.ci_predecessors),
			record(direct[names[last]].outputs.ci_predecessors),
			'Sibling was built from a different predecessor than the install job'
		);
		result[sibling] = { result: job.result };
	}
	return result;
}

if (require.main === module) {
	const [command, platform] = process.argv.slice(2);
	assert.equal(process.argv.length, 4, 'Use complete or admit-build and one OS');
	const current = {
		sourceSha: process.env.GITHUB_SHA,
		runId: process.env.GITHUB_RUN_ID,
		attempt: process.env.GITHUB_RUN_ATTEMPT,
		event: process.env.GITHUB_EVENT_NAME
	};
	assert.ok(command === 'complete' || command === 'admit-build');
	const result = (command === 'complete' ? complete : admitBuild)(
		platform,
		process.env.NEEDS,
		current
	);
	process.stdout.write(JSON.stringify(result) + '\n');
}

module.exports = { JOBS, complete, admitBuild };
