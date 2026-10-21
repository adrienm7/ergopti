// tools/ci/managed-ollama-handoff.cjs
'use strict';

/**
 * ============================================================================
 * MODULE: Managed Ollama Native Build Handoff
 * DESCRIPTION:
 * The clean managed Ollama source build runs in its own macOS E2E cell,
 * "Managed Ollama build (<architecture>)", in parallel with the Swift and
 * XCTest qualification of the "Managed Ollama (<architecture>)" cell that
 * receives it. The build cell seals its exact outputs into one artifact; the
 * receiving cell waits for that artifact, then admits it only when every file
 * is the sealed byte stream and the provenance binds this commit, this run,
 * this architecture and the bridge sources of the receiving checkout. Nothing
 * is cached: the producer still builds from a fresh Go cache on every run.
 *
 * Commands (both read the GitHub Actions environment):
 *   seal <dir>      copy the build outputs into <dir> and write handoff.json
 *   receive <dir>   wait for this run's build artifact of the cell's
 *                   architecture, download it into the empty <dir>, verify it
 *                   and install its files where the receiving steps read them
 *   await-qualified wait, in the application build that runs beside E2E, until
 *                   both "Managed Ollama (<architecture>)" cells succeeded and
 *                   uploaded the qualified inputs the build packages
 * ============================================================================
 */

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const { API_PAGE_SIZE } = require('./github-api-page.cjs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const CONTRACT = 'static/ergopti_plus/_shared/modules/llm/managed_ollama_runtime.json';
const CATALOGUE = 'managed_ollama_release.json';
const OFFICIAL_RECEIPT = 'official-input-receipt.json';
const PRODUCER_LOG = 'managed-ollama-producer-build.log';
const MANIFEST = 'handoff.json';
const LABELS = Object.freeze({ arm64: 'Apple silicon', amd64: 'Intel' });
// The visible cell names, macOS version included, come from the stage plan owner.
const { roleLot } = require('./macos-stage-roles.cjs');
const POLL_MILLISECONDS = 15000;

const sha256 = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');

/** The reviewed runtime contract of a checkout, with its own digest. */
function contractOf(root) {
	const bytes = fs.readFileSync(path.join(root, CONTRACT));
	return { contract: JSON.parse(bytes.toString('utf8')), digest: sha256(bytes) };
}

/** The exact member set of one architecture's handoff, manifest excluded. */
function members(contract, architecture) {
	assert.ok(Object.hasOwn(LABELS, architecture), 'Unknown handoff architecture');
	const asset = contract.assets['macos-' + architecture]?.filename;
	assert.ok(typeof asset === 'string' && /^[\w.-]+\.tgz$/.test(asset), 'Unknown asset name');
	return [
		asset,
		asset + '.provenance.json',
		asset + '.go-tests.jsonl',
		asset + '.go-tests.stderr.txt',
		asset + '.go-tests.receipt.json',
		CATALOGUE,
		OFFICIAL_RECEIPT,
		PRODUCER_LOG
	];
}

/** The artifact name for one build attempt; the consumer never guesses another. */
function artifactName(context) {
	return [
		'managed-ollama-build',
		context.architecture,
		context.sha,
		context.runId,
		String(context.attempt)
	].join('-');
}

/** The visible matrix cell name of the producer; the lane prefix may differ. */
function producerJobSuffix(architecture) {
	assert.ok(Object.hasOwn(LABELS, architecture), 'Unknown handoff architecture');
	return 'E2E tests (' + roleLot('e2e', 'managed-ollama-build', architecture, '') + ')';
}

/** The visible matrix cell name of the cell that qualifies one architecture's inputs. */
function qualifierJobSuffix(architecture) {
	assert.ok(Object.hasOwn(LABELS, architecture), 'Unknown handoff architecture');
	// The Intel role runs as two cells; its runtime cell uploads the inputs.
	const scenario = architecture === 'amd64' ? 'runtime' : '';
	return 'E2E tests (' + roleLot('e2e', 'managed-ollama-native', architecture, scenario) + ')';
}

/** The qualified native inputs one qualifying cell uploads for the application build. */
function qualifiedArtifactName(context, architecture) {
	assert.ok(Object.hasOwn(LABELS, architecture), 'Unknown handoff architecture');
	return ['managed-ollama-inputs', architecture, context.sha, context.runId].join('-');
}

function validateContext(context) {
	assert.match(context.sha, /^[a-f0-9]{40}$/, 'Invalid handoff source');
	assert.match(String(context.runId), /^[1-9][0-9]*$/, 'Invalid handoff run');
	assert.ok(
		Number.isSafeInteger(context.attempt) && context.attempt > 0,
		'Invalid handoff attempt'
	);
	assert.ok(Object.hasOwn(LABELS, context.architecture), 'Unknown handoff architecture');
	return context;
}

function environmentContext() {
	return validateContext({
		sha: process.env.GITHUB_SHA,
		runId: process.env.GITHUB_RUN_ID,
		attempt: Number(process.env.GITHUB_RUN_ATTEMPT),
		architecture: process.env.ERGOPTI_OLLAMA_EXPECTED_ARCHITECTURE
	});
}

/** A regular, unlinked file's bytes. */
function regular(file) {
	const status = fs.lstatSync(file);
	assert.ok(status.isFile() && !status.isSymbolicLink(), 'Not a regular handoff file: ' + file);
	return fs.readFileSync(file);
}

/** The bridge-source digests the producer must have compiled, from this checkout. */
function fingerprint(root, contract) {
	return Object.fromEntries(
		contract.source_fingerprint_paths.map((relative) => [
			relative,
			sha256(regular(path.join(root, relative)))
		])
	);
}

/**
 * Verifies a handoff directory against this checkout and run, returning its members.
 * @param {string} directory The downloaded artifact directory.
 * @param {object} context {sha, runId, attempt, architecture} of the receiving cell.
 * @param {string} root The receiving checkout.
 * @param {number|null} producerAttempt The attempt of the build cell that was awaited.
 * @returns {{manifest: object, files: Map<string, Buffer>}}
 */
function verify(directory, context, root = ROOT, producerAttempt = null) {
	validateContext(context);
	const { contract, digest } = contractOf(root);
	const expected = members(contract, context.architecture);
	const entries = fs.readdirSync(directory, { withFileTypes: true });
	assert.deepEqual(
		entries.map((entry) => entry.name).sort(),
		[...expected, MANIFEST].sort(),
		'The handoff must hold exactly the sealed members'
	);
	for (const entry of entries)
		assert.ok(entry.isFile() && !entry.isSymbolicLink(), 'Foreign handoff member: ' + entry.name);
	const manifest = JSON.parse(regular(path.join(directory, MANIFEST)).toString('utf8'));
	assert.deepEqual(
		Object.keys(manifest).sort(),
		['architecture', 'members', 'run_attempt', 'run_id', 'schema', 'source_sha'],
		'Closed handoff manifest fields required'
	);
	assert.equal(manifest.schema, 1);
	assert.equal(manifest.source_sha, context.sha, 'The handoff was built from another commit');
	assert.equal(manifest.run_id, String(context.runId), 'The handoff belongs to another run');
	assert.ok(
		Number.isSafeInteger(manifest.run_attempt) &&
			manifest.run_attempt > 0 &&
			manifest.run_attempt <= context.attempt,
		'The handoff comes from a future or invalid attempt'
	);
	assert.equal(manifest.architecture, context.architecture, 'The handoff targets another host');
	if (producerAttempt !== null)
		assert.equal(manifest.run_attempt, producerAttempt, 'The handoff names another build attempt');
	assert.deepEqual(Object.keys(manifest.members).sort(), [...expected].sort());
	const files = new Map();
	for (const name of expected) {
		const bytes = regular(path.join(directory, name));
		assert.deepEqual(
			manifest.members[name],
			{ sha256: sha256(bytes), bytes: bytes.length },
			'Handoff member changed after sealing: ' + name
		);
		files.set(name, bytes);
	}
	const [asset, provenanceName, , , receiptName] = expected;
	const assetBytes = files.get(asset);
	const sources = fingerprint(root, contract);
	const provenance = JSON.parse(files.get(provenanceName).toString('utf8'));
	for (const [field, value] of Object.entries({
		repository_commit: context.sha,
		runtime_contract_sha256: digest,
		source_commit: contract.source_commit,
		go_version: contract.go_version,
		version: contract.version,
		capability: contract.capability,
		architecture: context.architecture,
		platform: 'darwin',
		filename: asset,
		sha256: sha256(assetBytes),
		bytes: assetBytes.length
	}))
		assert.equal(provenance[field], value, 'Provenance ' + field + ' does not bind this build');
	assert.deepEqual(
		provenance.repository_source_sha256,
		sources,
		'The asset was built from other bridge sources'
	);
	const receipt = JSON.parse(files.get(receiptName).toString('utf8'));
	for (const [field, value] of Object.entries({
		repository_commit: context.sha,
		runtime_contract_sha256: digest,
		source_commit: contract.source_commit,
		go_version: contract.go_version,
		architecture: context.architecture,
		platform: 'darwin',
		native_execution: true
	}))
		assert.equal(receipt[field], value, 'Native Go receipt ' + field + ' does not bind this build');
	assert.deepEqual(receipt.repository_source_sha256, sources, 'Native Go tests ran other sources');
	const catalogue = JSON.parse(files.get(CATALOGUE).toString('utf8'));
	assert.equal(catalogue.repository_commit, context.sha, 'The catalogue names another commit');
	assert.equal(catalogue.runtime_contract_sha256, digest, 'The catalogue names another contract');
	assert.deepEqual(
		catalogue.repository_source_sha256,
		sources,
		'The catalogue names other sources'
	);
	const listed = Object.values(catalogue.assets ?? {});
	assert.equal(listed.length, 1, 'The catalogue must list the one sealed asset');
	assert.equal(listed[0].filename, asset);
	assert.equal(listed[0].sha256, provenance.sha256, 'The catalogue lists other asset bytes');
	assert.equal(listed[0].bytes, provenance.bytes);
	assert.equal(listed[0].provenance_sha256, sha256(files.get(provenanceName)));
	return { manifest, files };
}

/** Copies the producer's outputs and seals them for the receiving cell. */
function seal(directory, context, sources, root = ROOT) {
	validateContext(context);
	const { contract } = contractOf(root);
	const expected = members(contract, context.architecture);
	assert.ok(!fs.existsSync(directory), 'The handoff directory is already owned');
	fs.mkdirSync(directory, { recursive: true });
	const manifest = {
		schema: 1,
		source_sha: context.sha,
		run_id: String(context.runId),
		run_attempt: context.attempt,
		architecture: context.architecture,
		members: {}
	};
	for (const name of expected) {
		assert.ok(Object.hasOwn(sources, name), 'No producer output for ' + name);
		const bytes = regular(sources[name]);
		fs.writeFileSync(path.join(directory, name), bytes, { flag: 'wx' });
		manifest.members[name] = { sha256: sha256(bytes), bytes: bytes.length };
	}
	fs.writeFileSync(path.join(directory, MANIFEST), JSON.stringify(manifest, null, 2) + '\n', {
		flag: 'wx'
	});
	// The producer refuses to hand off what the receiver would refuse.
	verify(directory, context, root);
	return manifest;
}

/** Where the producer wrote each member, from the cell's environment. */
function producerSources(contract, architecture, environment = process.env) {
	const [asset, provenance, jsonl, stderr, receipt] = members(contract, architecture);
	const assets = path.dirname(environment.ERGOPTI_OLLAMA_ASSET);
	assert.equal(path.basename(environment.ERGOPTI_OLLAMA_ASSET), asset, 'Unexpected asset path');
	return {
		[asset]: environment.ERGOPTI_OLLAMA_ASSET,
		[provenance]: path.join(assets, provenance),
		[jsonl]: path.join(assets, jsonl),
		[stderr]: path.join(assets, stderr),
		[receipt]: path.join(assets, receipt),
		[CATALOGUE]: environment.ERGOPTI_OLLAMA_CATALOGUE,
		[OFFICIAL_RECEIPT]: path.join(environment.ERGOPTI_OLLAMA_BUILD_ROOT, OFFICIAL_RECEIPT),
		[PRODUCER_LOG]: path.join(environment.RUNNER_TEMP, PRODUCER_LOG)
	};
}

/** Installs admitted members at the exact paths the receiving steps read. */
function install(files, contract, architecture, environment = process.env) {
	const sources = producerSources(contract, architecture, environment);
	for (const [name, bytes] of files) {
		const destination = sources[name];
		assert.ok(destination, 'No destination for ' + name);
		fs.mkdirSync(path.dirname(destination), { recursive: true });
		fs.writeFileSync(destination, bytes, { flag: 'wx' });
	}
}

/**
 * Chooses the producer artifact, or refuses once the producer cannot deliver one.
 * @param {Array<{name: string, status: string, conclusion: string|null, run_attempt: number}>} jobs
 * @param {Array<{name: string, expired: boolean, id: number}>} artifacts
 * @param {object} context The receiving cell's context.
 * @returns {{state: 'wait'}|{state: 'ready', name: string, id: number}}
 */
function select(jobs, artifacts, context) {
	validateContext(context);
	const suffix = producerJobSuffix(context.architecture);
	const producers = jobs.filter(
		(job) => job.name === suffix || String(job.name).endsWith(' / ' + suffix)
	);
	assert.ok(producers.length <= 1, 'Duplicate managed Ollama build cells');
	if (producers.length === 0) return { state: 'wait' };
	const producer = producers[0];
	assert.ok(
		Number.isSafeInteger(producer.run_attempt) &&
			producer.run_attempt > 0 &&
			producer.run_attempt <= context.attempt,
		'Invalid managed Ollama build attempt'
	);
	if (producer.status === 'completed' && producer.conclusion !== 'success')
		throw new Error('The managed Ollama build cell concluded ' + producer.conclusion);
	const name = artifactName({ ...context, attempt: producer.run_attempt });
	const found = artifacts.filter((artifact) => artifact.name === name);
	assert.ok(found.length <= 1, 'Duplicate managed Ollama build artifacts');
	if (found.length === 1) {
		assert.equal(found[0].expired, false, 'The managed Ollama build artifact expired');
		return { state: 'ready', name, id: found[0].id, attempt: producer.run_attempt };
	}
	if (producer.status === 'completed')
		throw new Error('The successful managed Ollama build cell uploaded no handoff');
	return { state: 'wait' };
}

/**
 * Lets the application build, which runs beside E2E, wait for the native
 * inputs it packages. An architecture is ready only once its qualifying cell
 * has completed successfully, so the build never packages an input whose
 * model receiving is still running or failed; a successful cell that left no
 * inputs, a failed one or a duplicate refuses at once instead of waiting.
 * @param {Array<{name: string, status: string, conclusion: string|null, run_attempt: number}>} jobs
 * @param {Array<{name: string, expired: boolean, id: number}>} artifacts
 * @param {{sha: string, runId: string, attempt: number}} context The build job's run.
 * @returns {{state: 'wait', waiting: string[]}|{state: 'ready', names: string[]}}
 */
function selectQualified(jobs, artifacts, context) {
	validateContext({ ...context, architecture: 'arm64' });
	const waiting = [];
	const names = [];
	for (const architecture of Object.keys(LABELS)) {
		const suffix = qualifierJobSuffix(architecture);
		const cells = jobs.filter(
			(job) => job.name === suffix || String(job.name).endsWith(' / ' + suffix)
		);
		assert.ok(cells.length <= 1, 'Duplicate managed Ollama qualifying cells');
		const cell = cells[0];
		if (cell === undefined || cell.status !== 'completed') {
			waiting.push(architecture);
			continue;
		}
		assert.ok(
			Number.isSafeInteger(cell.run_attempt) &&
				cell.run_attempt > 0 &&
				cell.run_attempt <= context.attempt,
			'Invalid managed Ollama qualifying attempt'
		);
		if (cell.conclusion !== 'success')
			throw new Error('The ' + suffix + ' cell concluded ' + cell.conclusion);
		const name = qualifiedArtifactName(context, architecture);
		const found = artifacts.filter((artifact) => artifact.name === name);
		assert.ok(found.length <= 1, 'Duplicate qualified managed Ollama inputs');
		if (found.length === 0)
			throw new Error('The successful ' + suffix + ' cell uploaded no qualified inputs');
		assert.equal(found[0].expired, false, 'The qualified managed Ollama inputs expired');
		names.push(name);
	}
	return waiting.length > 0 ? { state: 'wait', waiting } : { state: 'ready', names };
}

async function api(route) {
	const response = await fetch(process.env.GITHUB_API_URL + route, {
		headers: {
			Accept: 'application/vnd.github+json',
			Authorization: 'Bearer ' + process.env.GITHUB_TOKEN,
			'X-GitHub-Api-Version': '2022-11-28'
		}
	});
	if (!response.ok) throw new Error('GitHub API ' + route + ' answered ' + response.status);
	return response.json();
}

/**
 * Lists every record of one run listing, one page of API_PAGE_SIZE at a time.
 * @param {string} route API route of the listing, with or without a query.
 * @param {string} key Field holding the records (jobs or artifacts).
 * @param {(route: string) => Promise<object>} read Reads one API route.
 * @returns {Promise<object[]>}
 */
async function listAll(route, key, read = api) {
	const rows = [];
	for (let page = 1; ; page++) {
		const body = await read(
			route + (route.includes('?') ? '&' : '?') + 'per_page=' + API_PAGE_SIZE + '&page=' + page
		);
		rows.push(...body[key]);
		if (body[key].length < API_PAGE_SIZE) return rows;
	}
}

async function awaitArtifact(context, deadlineMinutes, choose = select, what = 'build handoff') {
	const run = '/repos/' + process.env.GITHUB_REPOSITORY + '/actions/runs/' + context.runId;
	const deadline = Date.now() + deadlineMinutes * 60000;
	for (;;) {
		const jobs = await listAll(run + '/jobs?filter=latest', 'jobs');
		const artifacts = await listAll(run + '/artifacts', 'artifacts');
		const choice = choose(jobs, artifacts, context);
		if (choice.state === 'ready') return choice;
		if (Date.now() > deadline) throw new Error('The managed Ollama ' + what + ' never arrived');
		await new Promise((resolve) => setTimeout(resolve, POLL_MILLISECONDS));
	}
}

function fetchArtifact(id, directory) {
	assert.ok(!fs.existsSync(directory), 'The handoff download directory is already owned');
	fs.mkdirSync(directory, { recursive: true });
	const archive = directory + '.zip';
	const url =
		process.env.GITHUB_API_URL +
		'/repos/' +
		process.env.GITHUB_REPOSITORY +
		'/actions/artifacts/' +
		id +
		'/zip';
	// curl drops the token on the redirect to the storage host.
	for (const [command, args] of [
		[
			'curl',
			[
				'--fail',
				'--location',
				'--silent',
				'--show-error',
				'--retry',
				'3',
				'--proto',
				'=https',
				'--header',
				'Authorization: Bearer ' + process.env.GITHUB_TOKEN,
				'--output',
				archive,
				url
			]
		],
		['unzip', ['-q', archive, '-d', directory]]
	]) {
		const result = spawnSync(command, args, { stdio: 'inherit' });
		if (result.status !== 0) throw new Error(command + ' failed with ' + result.status);
	}
	fs.rmSync(archive);
}

async function main(args) {
	const [command, directory] = args;
	if (command === 'await-qualified') {
		assert.equal(args.length, 1);
		const run = {
			sha: process.env.GITHUB_SHA,
			runId: process.env.GITHUB_RUN_ID,
			attempt: Number(process.env.GITHUB_RUN_ATTEMPT)
		};
		const choice = await awaitArtifact(run, 40, selectQualified, 'qualified inputs');
		console.log('Qualified managed Ollama inputs ready: ' + choice.names.join(', '));
		return;
	}
	const context = environmentContext();
	if (command === 'seal') {
		assert.equal(args.length, 2);
		const { contract } = contractOf(ROOT);
		const manifest = seal(directory, context, producerSources(contract, context.architecture));
		console.log('Sealed managed Ollama handoff ' + artifactName(context));
		console.log(JSON.stringify(manifest.members));
		fs.appendFileSync(process.env.GITHUB_OUTPUT, 'name=' + artifactName(context) + '\n');
	} else {
		assert.equal(command, 'receive');
		assert.equal(args.length, 2);
		const choice = await awaitArtifact(context, 45);
		console.log('Received managed Ollama handoff ' + choice.name);
		fetchArtifact(choice.id, directory);
		const { manifest, files } = verify(directory, context, ROOT, choice.attempt);
		install(files, contractOf(ROOT).contract, context.architecture);
		console.log(
			'Admitted the clean managed Ollama build of ' +
				context.sha +
				' (build attempt ' +
				manifest.run_attempt +
				')'
		);
	}
}

module.exports = {
	listAll,
	members,
	artifactName,
	producerJobSuffix,
	qualifierJobSuffix,
	qualifiedArtifactName,
	verify,
	seal,
	select,
	selectQualified,
	producerSources,
	install,
	MANIFEST
};
if (require.main === module)
	main(process.argv.slice(2)).catch((error) => {
		console.error('[FAIL] managed Ollama handoff: ' + error.message);
		process.exitCode = 1;
	});
