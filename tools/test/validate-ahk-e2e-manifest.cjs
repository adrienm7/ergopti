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

/** Reads one explicit receipt and publishes only its actual admission verdict. */
function main(argv) {
	if (argv.length !== 2 || argv[0] !== '--input')
		throw new Error('Usage: node validate-ahk-e2e-manifest.cjs --input <tap-file>');
	const manifest = validateAhkE2eManifest(fs.readFileSync(path.resolve(argv[1]), 'utf8'));
	if (!manifest.complete) {
		for (const error of manifest.errors) console.error(error);
		return 1;
	}
	console.log(
		`AHK E2E corpus and native Edit coverage complete: ${manifest.executed_count} results.`
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

module.exports = { validateAhkE2eManifest };
