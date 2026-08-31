// tools/test/linux-ci-evidence.cjs

/**
 * ============================================================================
 * MODULE: Linux CI Evidence Contract
 * DESCRIPTION:
 * Records machine-readable proof for Linux CI subjects and verifies that every
 * mandatory manifest subject both ran and passed before linux-ok can be green.
 * ============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

function fail(message) {
	throw new Error(message);
}

function parseArgs(argv) {
	const parsed = { subjects: [] };
	for (let index = 0; index < argv.length; index += 1) {
		const argument = argv[index];
		if (!argument.startsWith('--')) fail(`unexpected argument: ${argument}`);
		const key = argument.slice(2).replace(/-/g, '_');
		const value = argv[index + 1];
		if (!value || value.startsWith('--')) fail(`missing value for ${argument}`);
		index += 1;
		if (key === 'subject') parsed.subjects.push(value);
		else parsed[key] = value;
	}
	return parsed;
}

function readJson(filePath, label) {
	try {
		return JSON.parse(fs.readFileSync(filePath, 'utf8'));
	} catch (error) {
		fail(`${label} is not readable JSON: ${error.message}`);
	}
}

function validateManifest(manifest) {
	if (manifest.schema_version !== 1 || !manifest.jobs || Array.isArray(manifest.jobs)) {
		fail('Linux CI coverage manifest must have schema_version 1 and a jobs object');
	}
	for (const [job, contract] of Object.entries(manifest.jobs)) {
		if (!['mandatory', 'optional'].includes(contract.classification)) {
			fail(`${job} has an invalid coverage classification`);
		}
		if (!contract.subjects || Object.keys(contract.subjects).length === 0) {
			fail(`${job} declares no evidence subjects`);
		}
		for (const [subject, floor] of Object.entries(contract.subjects)) {
			if (!subject || !Number.isInteger(floor) || floor < 1) {
				fail(`${job}/${subject} has an invalid assertion floor`);
			}
		}
	}
}

function validateEvidenceDocument(document, expectedSha) {
	if (document.schema_version !== 1) fail('evidence has an unsupported schema_version');
	for (const field of ['job', 'sha', 'architecture', 'distro', 'session', 'interpreter']) {
		if (typeof document[field] !== 'string' || document[field].trim() === '') {
			fail(`evidence is missing ${field}`);
		}
	}
	if (document.sha !== expectedSha) {
		fail(`${document.job} evidence belongs to ${document.sha}, expected ${expectedSha}`);
	}
	if (!document.subjects || Array.isArray(document.subjects)) {
		fail(`${document.job} evidence has no subjects object`);
	}
	for (const [subject, assertions] of Object.entries(document.subjects)) {
		if (!subject || !Number.isInteger(assertions) || assertions < 1) {
			fail(`${document.job}/${subject} has no positive executed assertion count`);
		}
	}
}

function verifyAggregate({ manifest, needs, evidence, expectedSha }) {
	validateManifest(manifest);
	if (!needs || Array.isArray(needs)) fail('needs must be an object');

	const indexedEvidence = new Map();
	for (const document of evidence) {
		validateEvidenceDocument(document, expectedSha);
		const contract = manifest.jobs[document.job];
		if (!contract) fail(`evidence names unclassified job ${document.job}`);
		for (const [subject, assertions] of Object.entries(document.subjects)) {
			if (!Object.hasOwn(contract.subjects, subject)) {
				fail(`evidence names unclassified subject ${document.job}/${subject}`);
			}
			const key = `${document.job}/${subject}`;
			if (indexedEvidence.has(key)) fail(`duplicate evidence for ${key}`);
			indexedEvidence.set(key, assertions);
		}
	}

	for (const [job, contract] of Object.entries(manifest.jobs)) {
		const dependency = needs[job];
		if (!dependency) {
			if (contract.classification === 'mandatory') fail(`mandatory job ${job} is missing from needs`);
			continue;
		}
		if (contract.classification === 'mandatory' && dependency.result !== 'success') {
			fail(`mandatory job ${job} concluded ${dependency.result || 'without a result'}`);
		}
		if (contract.classification === 'optional' && ['failure', 'cancelled'].includes(dependency.result)) {
			fail(`optional job ${job} concluded ${dependency.result}`);
		}
		if (dependency.result !== 'success') continue;
		for (const [subject, floor] of Object.entries(contract.subjects)) {
			const key = `${job}/${subject}`;
			const assertions = indexedEvidence.get(key);
			if (!assertions) fail(`successful job ${job} has no evidence for ${subject}`);
			if (assertions < floor) fail(`${key} recorded ${assertions} assertion(s), expected at least ${floor}`);
		}
	}

	for (const job of Object.keys(needs)) {
		if (!manifest.jobs[job]) fail(`needs contains unclassified Linux job ${job}`);
	}
}

function record(options) {
	for (const field of ['job', 'output', 'sha', 'architecture', 'distro', 'session', 'interpreter']) {
		if (!options[field]) fail(`record requires --${field.replace(/_/g, '-')}`);
	}
	const subjects = {};
	for (const specification of options.subjects) {
		const match = specification.match(/^([^=]+)=([1-9]\d*)$/);
		if (!match) fail(`invalid --subject value: ${specification}`);
		if (subjects[match[1]]) fail(`duplicate subject: ${match[1]}`);
		subjects[match[1]] = Number(match[2]);
	}
	if (Object.keys(subjects).length === 0) fail('record requires at least one --subject');
	const document = {
		schema_version: 1,
		job: options.job,
		sha: options.sha,
		architecture: options.architecture,
		distro: options.distro,
		session: options.session,
		interpreter: options.interpreter,
		subjects,
	};
	fs.mkdirSync(path.dirname(options.output), { recursive: true });
	fs.writeFileSync(options.output, `${JSON.stringify(document, null, 2)}\n`);
}

function loadEvidence(directory) {
	if (!fs.existsSync(directory)) fail(`evidence directory does not exist: ${directory}`);
	return fs.readdirSync(directory, { recursive: true })
		.filter((entry) => entry.endsWith('.json'))
		.map((entry) => readJson(path.join(directory, entry), `evidence ${entry}`));
}

function main(argv) {
	const [command, ...rest] = argv;
	const options = parseArgs(rest);
	if (command === 'record') {
		record(options);
		return;
	}
	if (command === 'verify') {
		for (const field of ['manifest', 'needs', 'evidence_dir', 'sha']) {
			if (!options[field]) fail(`verify requires --${field.replace(/_/g, '-')}`);
		}
		verifyAggregate({
			manifest: readJson(options.manifest, 'manifest'),
			needs: JSON.parse(options.needs),
			evidence: loadEvidence(options.evidence_dir),
			expectedSha: options.sha,
		});
		return;
	}
	fail('usage: linux-ci-evidence.cjs <record|verify> [options]');
}

if (require.main === module) {
	try {
		main(process.argv.slice(2));
	} catch (error) {
		process.stderr.write(`Linux CI evidence error: ${error.message}\n`);
		process.exitCode = 1;
	}
}

module.exports = { validateManifest, verifyAggregate };
