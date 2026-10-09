// tools/test/fixtures/ci-scoped-full-branches.cjs
'use strict';

/** Inspect retained full command bodies after admitting one exact reviewed scope wrapper. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const raw = require('../ci-pipeline.cjs');
const qualification = require('../../ci/dev-release-qualification.cjs');
const contract = require('./ci-scoped-full-branches.json');

function validateBoundary() {
	const policy = qualification.validatePolicy(
		qualification.parseClosedJson(fs.readFileSync(qualification.STABLE_POLICY_PATH, 'utf8'))
	);
	assert.deepEqual(
		Object.keys(policy.scopes),
		contract.scope_ids,
		'unknown qualification scope inventory'
	);
	return policy;
}
function unwrap(code, protocol) {
	assert.ok(code.startsWith(protocol.prefix), 'unknown or weakened scoped command admission');
	assert.ok(code.endsWith(protocol.suffix), 'unknown or weakened scoped command refusal');
	let full = code.slice(protocol.prefix.length, -protocol.suffix.length);
	assert.ok(full.trim(), 'the retained full command body must be nonempty');
	full = full
		.split('\n')
		.map((line) => {
			if (!line.trim()) return '';
			assert.ok(
				line.startsWith(' '.repeat(protocol.strip)),
				'invalid retained command indentation'
			);
			return line.slice(protocol.strip);
		})
		.join('\n');
	// The wrapper adds the same strict shell setup as the retained original body.
	// Two identical consecutive setups convey one full-default command boundary.
	full = full.replace(/^set -euo pipefail\nset -euo pipefail\n/, 'set -euo pipefail\n');
	return [protocol.retained_prefix, full, protocol.retained_suffix]
		.filter((part) => part !== undefined)
		.join('\n');
}
function projectScopedSteps(text, rel) {
	const policy = validateBoundary();
	let result = text;
	const seen = new Set();
	for (const job of raw.jobsOfText(text, rel))
		for (const step of raw.steps(job.body)) {
			const matches = contract.slots.filter(
				(slot) => slot.file === rel && slot.job === job.id && slot.step === step.name
			);
			const lines = raw.runOf(step.body);
			if (!lines) {
				assert.equal(matches.length, 0, 'the reviewed scoped command must retain its run body');
				continue;
			}
			const code = lines.join('\n');
			if (!matches.length && !code.includes('--validate-scope-receipt')) continue;
			assert.equal(
				matches.length,
				1,
				'unknown or duplicated scoped command owner: ' + rel + '/' + job.id + '/' + step.name
			);
			const slot = matches[0],
				protocol = contract.protocols[slot.protocol];
			assert.equal(policy.scopes[protocol.scope].path, rel, 'scope and workflow owner must agree');
			if (slot.owner_job !== undefined) {
				assert.equal(
					protocol.scope,
					'macos-native-http',
					'only the reviewed native-wire duplicate has a sibling owner'
				);
				assert.equal(job.id, 'package-macos', 'native-wire duplicate job must remain');
				assert.equal(
					step.name,
					'Receive actual managed HTTP native clients',
					'native-wire duplicate step must remain'
				);
				assert.equal(
					slot.owner_job,
					'managed-ollama-native',
					'native-wire original owner must remain'
				);
				assert.equal(
					slot.owner_step,
					'Receive actual independent managed HTTP native clients',
					'native-wire original step must remain'
				);
				assert.equal(
					policy.scopes[protocol.scope].args[1],
					slot.owner_step,
					'scope and original step owner must agree'
				);
			}
			assert.equal(
				policy.scopes[protocol.scope].args[0],
				slot.owner_job ?? job.id,
				'scope and job owner must agree'
			);
			const identity = job.id + '/' + step.name;
			assert.ok(!seen.has(identity), 'duplicate scoped command owner');
			seen.add(identity);
			const full = unwrap(code, protocol);
			const run = /^        run: \|\n(?: {10}[^\n]*(?:\n|$)|\n)*/m.exec(step.body);
			assert.ok(run, 'the reviewed wrapper must have one literal run block');
			const replacement = full.includes('\n')
				? '        run: |\n' +
					full
						.split('\n')
						.map((line) => '          ' + line)
						.join('\n') +
					'\n'
				: '        run: ' + full + '\n';
			const projected = step.body.replace(run[0], () => replacement);
			assert.equal(
				result.split(step.body).length,
				2,
				'the source step must be unique and nonempty'
			);
			result = result.replace(step.body, () => projected);
		}
	const expected = contract.slots
		.filter((slot) => slot.file === rel)
		.map((slot) => slot.job + '/' + slot.step);
	assert.equal(
		new Set(expected).size,
		expected.length,
		'reviewed command identities must be unique'
	);
	assert.deepEqual(
		[...seen].sort(),
		expected.sort(),
		'every reviewed scoped command owner must remain'
	);
	return result;
}
function projectLinuxHarness(source) {
	const { prefix, suffix } = contract.linux_harness;
	assert.equal(source.split(prefix).length, 2, 'exact native harness scope admission must remain');
	assert.equal(source.split(suffix).length, 2, 'exact native harness refusal must remain');
	const start = source.indexOf(prefix),
		end = source.indexOf(suffix, start + prefix.length);
	const body = source.slice(start + prefix.length, end);
	assert.ok(body.trim(), 'native full command must remain nonempty');
	assert.ok(
		body.split('\n').every((line) => line.startsWith('\t\t')),
		'native full command indentation'
	);
	return (
		source.slice(0, start) +
		body
			.split('\n')
			.map((line) => line.slice(1))
			.join('\n') +
		source.slice(end + suffix.length)
	);
}
module.exports = { projectScopedSteps, projectLinuxHarness, unwrap, contract };
