// tools/test/validate-ahk-e2e-manifest.cjs

/**
 * Requires complete pure and native Edit coverage of the shipped hotstring corpus.
 * A self-consistent transcript that omits a whole tier must fail admission.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { validateAhkSuiteManifest } = require('./validate-ahk-suite-manifest.cjs');
const corpus = require('../../static/ergopti_plus/_shared/tests/corpus/hotstrings/vectors.json');

/** Validates observed terminal results against both mandatory corpus tiers. */
function validateAhkE2eManifest(source, vectors = corpus.vectors) {
	const manifest = validateAhkSuiteManifest(source);
	const errors = [...manifest.errors];
	if (!Array.isArray(vectors) || vectors.length === 0) {
		errors.push('The canonical hotstring corpus must contain vectors.');
	} else {
		const ids = new Set();
		for (const vector of vectors) {
			const id = vector?.id;
			if (typeof id !== 'string' || id.trim() === '' || ids.has(id)) {
				errors.push('The canonical hotstring corpus must contain unique nonempty IDs.');
				continue;
			}
			ids.add(id);
			for (const tier of ['pure', 'native-edit']) {
				const name = `e2e[${tier}] ${id}`;
				const observed = manifest.executed.filter((entry) => entry.name === name);
				if (observed.length !== 1 || observed[0].status !== 'ok')
					errors.push(`Expected exactly one successful ${name}.`);
			}
		}
	}
	if (manifest.executed_count === 0) errors.push('The E2E runner executed no tests.');
	if (manifest.failed !== 0) errors.push('The E2E runner contains failed terminal results.');
	return { ...manifest, complete: errors.length === 0, errors };
}

/** Admits only a fresh native dry-run plan, including the mandatory regressions. */
function validateAhkE2eDiscovery(planSource, source, vectors = corpus.vectors) {
	const { parsePlan } = require('../ci/windows-test-replay.cjs');
	const errors = [];
	let names = [];
	try {
		names = parsePlan(planSource).map((entry) => entry.name);
	} catch (error) {
		errors.push(error.message);
	}
	if (new Set(names.map((name) => name.toLowerCase())).size !== names.length)
		errors.push('The native plan contains duplicate test names.');
	const required = ['pure', 'native-edit'].flatMap((tier) => [
		...vectors.map((vector) => `e2e[${tier}] ${vector.id}`),
		`e2e[${tier}] supplementary trigger and completion preserve native edits (unicode-erase)`
	]);
	for (const name of required)
		if (!names.includes(name)) errors.push(`Native discovery omitted ${name}.`);
	const lines = String(source)
		.replace(/^\uFEFF/, '')
		.split(/\r?\n/);
	const plans = lines.filter((line) => /^1\.\.\d+$/.test(line));
	if (plans.length !== 1 || plans[0] !== `1..${names.length}`)
		errors.push('Native discovery TAP and exported plan disagree.');
	if (lines.filter((line) => line === '# dry-run - skipping execution.').length !== 1)
		errors.push('Native discovery did not confirm dry-run admission.');
	if (/^(?:RUNNING |(?:not )?ok |# duration_ms |# \d+ passed,)/m.test(source))
		errors.push('Native discovery contains execution results.');
	if (/\b(?:SKIP|DEFERRED)\b|^# excluded/im.test(source))
		errors.push('Native discovery excluded tests.');
	return { complete: errors.length === 0, expected_count: names.length, names, errors };
}

/** Requires execution to match every freshly discovered name and timing in order. */
function validateAhkE2ePlanExecution(source, discovery, vectors = corpus.vectors) {
	const { validateExecution } = require('../ci/windows-test-replay.cjs');
	const manifest = validateAhkE2eManifest(source, vectors);
	const errors = [...discovery.errors, ...manifest.errors];
	try {
		validateExecution(source, discovery.names);
	} catch (error) {
		errors.push(error.message);
	}
	if (/\b(?:SKIP|DEFERRED)\b|^# excluded|# dry-run - skipping execution\./im.test(source))
		errors.push('Native E2E execution skipped tests.');
	return {
		...manifest,
		expected_count: discovery.expected_count,
		complete: errors.length === 0,
		errors
	};
}

/** Reads explicit source-bound discovery and execution receipts. */
function main(argv) {
	const args = {};
	for (let index = 0; index < argv.length; index += 2) {
		const flag = argv[index];
		if (
			!['--input', '--plan', '--discovery', '--json'].includes(flag) ||
			Object.hasOwn(args, flag) ||
			!argv[index + 1] ||
			argv[index + 1].startsWith('--')
		)
			throw new Error('Expected unique --input/--plan/--discovery/--json file arguments.');
		args[flag] = argv[index + 1];
	}
	if (
		Boolean(args['--plan']) !== Boolean(args['--discovery']) ||
		(!args['--input'] && !args['--plan'])
	)
		throw new Error('A native plan and discovery receipt must be supplied together.');
	const read = (flag) => fs.readFileSync(path.resolve(args[flag]), 'utf8');
	const discovery = args['--plan']
		? validateAhkE2eDiscovery(read('--plan'), read('--discovery'))
		: null;
	const manifest = args['--input']
		? discovery
			? validateAhkE2ePlanExecution(read('--input'), discovery)
			: validateAhkE2eManifest(read('--input'))
		: discovery;
	if (args['--json'])
		fs.writeFileSync(args['--json'], `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
	if (!manifest.complete) {
		for (const error of manifest.errors) console.error(error);
		return 1;
	}
	console.log(
		args['--input']
			? `AHK E2E corpus and native Edit coverage complete: ${manifest.executed_count} results.`
			: `AHK E2E native discovery complete: ${manifest.expected_count} names.`
	);
	return 0;
}

if (require.main === module) {
	try {
		process.exitCode = main(process.argv.slice(2));
	} catch (error) {
		console.error(error.message);
		process.exitCode = 1;
	}
}

module.exports = { validateAhkE2eManifest, validateAhkE2eDiscovery, validateAhkE2ePlanExecution };
