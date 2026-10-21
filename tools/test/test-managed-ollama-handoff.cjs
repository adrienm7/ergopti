// tools/test/test-managed-ollama-handoff.cjs

/**
 * ============================================================================
 * MODULE: Managed Ollama Build Handoff Contract Tests
 * DESCRIPTION:
 * The clean managed Ollama source build runs in its own macOS E2E cell and
 * hands its sealed bytes to the cell that receives models with it. These
 * checks build a complete handoff from the real runtime contract and bridge
 * sources, then refuse every way a receiving cell could admit something other
 * than this commit's clean build of its own architecture: another commit, run
 * or attempt, changed or missing or extra members, other bridge sources, a
 * catalogue that lists other bytes, and a missing, failed, duplicated or
 * expired producer. The workflow's artifact and cell names are pinned to the
 * names the receiver waits for.
 * ============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const YAML = require('yaml');
const Handoff = require('../ci/managed-ollama-handoff.cjs');
const { API_PAGE_SIZE } = require('../ci/github-api-page.cjs');
const { roleLot } = require('../ci/macos-stage-roles.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const CONTRACT_PATH = 'static/ergopti_plus/_shared/modules/llm/managed_ollama_runtime.json';
const CONTRACT_BYTES = fs.readFileSync(path.join(ROOT, CONTRACT_PATH));
const CONTRACT = JSON.parse(CONTRACT_BYTES.toString('utf8'));
const sha256 = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const SHA = 'c'.repeat(40);
const CONTEXT = { sha: SHA, runId: '42', attempt: 2, architecture: 'amd64' };
let controls = 0;

const SOURCES = Object.fromEntries(
	CONTRACT.source_fingerprint_paths.map((relative) => [
		relative,
		sha256(fs.readFileSync(path.join(ROOT, relative)))
	])
);

/** Writes one complete, internally consistent producer output tree. */
function producerTree(scratch, context = CONTEXT) {
	const asset = CONTRACT.assets['macos-' + context.architecture].filename;
	const assets = path.join(scratch, 'build', 'assets');
	fs.mkdirSync(assets, { recursive: true });
	const assetBytes = Buffer.from('clean native asset ' + context.architecture);
	fs.writeFileSync(path.join(assets, asset), assetBytes);
	const provenance = {
		schema_version: 1,
		capability: CONTRACT.capability,
		version: CONTRACT.version,
		runtime_contract_sha256: sha256(CONTRACT_BYTES),
		repository_source_sha256: SOURCES,
		repository_commit: context.sha,
		platform: 'darwin',
		source_commit: CONTRACT.source_commit,
		go_version: CONTRACT.go_version,
		architecture: context.architecture,
		filename: asset,
		sha256: sha256(assetBytes),
		bytes: assetBytes.length
	};
	const provenanceBytes = Buffer.from(JSON.stringify(provenance, null, 2) + '\n');
	fs.writeFileSync(path.join(assets, asset + '.provenance.json'), provenanceBytes);
	fs.writeFileSync(path.join(assets, asset + '.go-tests.jsonl'), '{"Action":"pass"}\n');
	fs.writeFileSync(path.join(assets, asset + '.go-tests.stderr.txt'), '');
	fs.writeFileSync(
		path.join(assets, asset + '.go-tests.receipt.json'),
		JSON.stringify({
			schema_version: 1,
			repository_commit: context.sha,
			repository_source_sha256: SOURCES,
			runtime_contract_sha256: sha256(CONTRACT_BYTES),
			source_commit: CONTRACT.source_commit,
			go_version: CONTRACT.go_version,
			platform: 'darwin',
			architecture: context.architecture,
			native_execution: true
		})
	);
	const catalogue = path.join(scratch, 'build', 'staged', 'managed_ollama_release.json');
	fs.mkdirSync(path.dirname(catalogue), { recursive: true });
	fs.writeFileSync(
		catalogue,
		JSON.stringify({
			schema_version: 1,
			repository_commit: context.sha,
			runtime_contract_sha256: sha256(CONTRACT_BYTES),
			repository_source_sha256: SOURCES,
			assets: {
				['darwin-' + context.architecture]: {
					filename: asset,
					sha256: provenance.sha256,
					bytes: provenance.bytes,
					provenance_sha256: sha256(provenanceBytes)
				}
			}
		})
	);
	fs.writeFileSync(path.join(scratch, 'build', 'official-input-receipt.json'), '{}\n');
	fs.writeFileSync(path.join(scratch, 'managed-ollama-producer-build.log'), 'built\n');
	return {
		ERGOPTI_OLLAMA_ASSET: path.join(assets, asset),
		ERGOPTI_OLLAMA_CATALOGUE: catalogue,
		ERGOPTI_OLLAMA_BUILD_ROOT: path.join(scratch, 'build'),
		RUNNER_TEMP: scratch
	};
}

/** Seals a fresh producer tree and returns the handoff directory. */
function sealed(scratch, context = CONTEXT) {
	const environment = producerTree(scratch, context);
	const directory = path.join(scratch, 'handoff');
	Handoff.seal(
		directory,
		context,
		Handoff.producerSources(CONTRACT, context.architecture, environment),
		ROOT
	);
	return directory;
}

function withScratch(callback) {
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ollama-handoff-'));
	try {
		return callback(scratch);
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
}

/** Rewrites a JSON member, optionally resealing the manifest so only the binding can refuse. */
function editJson(directory, name, change, reseal = true) {
	const file = path.join(directory, name);
	const value = JSON.parse(fs.readFileSync(file, 'utf8'));
	change(value);
	fs.writeFileSync(file, JSON.stringify(value));
	if (reseal && name !== Handoff.MANIFEST) {
		const bytes = fs.readFileSync(file);
		editJson(directory, Handoff.MANIFEST, (manifest) => {
			manifest.members[name] = { sha256: sha256(bytes), bytes: bytes.length };
		});
	}
}

function refuses(label, mutate, pattern, context = CONTEXT) {
	withScratch((scratch) => {
		const directory = sealed(scratch);
		mutate(directory, scratch);
		assert.throws(() => Handoff.verify(directory, context, ROOT), pattern, label);
	});
	controls++;
}

// ─────────────────────────────────────────────────
// A complete clean build is admitted and installed where the cell reads it
// ─────────────────────────────────────────────────
withScratch((scratch) => {
	const directory = sealed(scratch);
	const { manifest, files } = Handoff.verify(directory, CONTEXT, ROOT, 2);
	assert.equal(manifest.source_sha, SHA);
	assert.equal(files.size, Handoff.members(CONTRACT, 'amd64').length);
	const receiving = path.join(scratch, 'receiving');
	const environment = {
		ERGOPTI_OLLAMA_ASSET: path.join(
			receiving,
			'build',
			'assets',
			Handoff.members(CONTRACT, 'amd64')[0]
		),
		ERGOPTI_OLLAMA_CATALOGUE: path.join(
			receiving,
			'build',
			'staged',
			'managed_ollama_release.json'
		),
		ERGOPTI_OLLAMA_BUILD_ROOT: path.join(receiving, 'build'),
		RUNNER_TEMP: receiving
	};
	Handoff.install(files, CONTRACT, 'amd64', environment);
	assert.deepEqual(
		fs.readFileSync(environment.ERGOPTI_OLLAMA_ASSET),
		files.get(Handoff.members(CONTRACT, 'amd64')[0])
	);
	assert.throws(() => Handoff.install(files, CONTRACT, 'amd64', environment), /EEXIST/);
	assert.throws(() => Handoff.verify(directory, CONTEXT, ROOT, 1), /another build attempt/);
	controls += 2;
});

// ─────────────────────────────────────────────────
// Every foreign or altered handoff is refused
// ─────────────────────────────────────────────────
const asset = Handoff.members(CONTRACT, 'amd64')[0];
refuses(
	'an asset built from another commit',
	(directory) =>
		editJson(directory, asset + '.provenance.json', (value) => {
			value.repository_commit = 'd'.repeat(40);
		}),
	/repository_commit does not bind this build/
);
refuses(
	'a handoff sealed for another commit',
	(directory) =>
		editJson(directory, Handoff.MANIFEST, (value) => {
			value.source_sha = 'd'.repeat(40);
		}),
	/built from another commit/
);
refuses(
	'a handoff of another run',
	(directory) =>
		editJson(directory, Handoff.MANIFEST, (value) => {
			value.run_id = '41';
		}),
	/another run/
);
refuses(
	'a handoff from a future attempt',
	(directory) =>
		editJson(directory, Handoff.MANIFEST, (value) => {
			value.run_attempt = 3;
		}),
	/future or invalid attempt/
);
refuses(
	'a handoff for the other architecture',
	() => {},
	/targets another host|Unknown asset|exactly the sealed members/,
	{
		...CONTEXT,
		architecture: 'arm64'
	}
);
refuses(
	'asset bytes changed after sealing',
	(directory) => fs.appendFileSync(path.join(directory, asset), 'x'),
	/changed after sealing/
);
refuses(
	'asset bytes changed and resealed',
	(directory) => {
		fs.appendFileSync(path.join(directory, asset), 'x');
		const bytes = fs.readFileSync(path.join(directory, asset));
		editJson(directory, Handoff.MANIFEST, (value) => {
			value.members[asset] = { sha256: sha256(bytes), bytes: bytes.length };
		});
	},
	/sha256 does not bind this build/
);
refuses(
	'a missing member',
	(directory) => fs.rmSync(path.join(directory, 'managed-ollama-producer-build.log')),
	/exactly the sealed members/
);
refuses(
	'an extra member',
	(directory) => fs.writeFileSync(path.join(directory, 'cached-go-build.tar'), ''),
	/exactly the sealed members/
);
refuses(
	'a nested member directory',
	(directory) => fs.mkdirSync(path.join(directory, 'nested')),
	/exactly the sealed members/
);
refuses(
	'other bridge sources',
	(directory) =>
		editJson(directory, asset + '.provenance.json', (value) => {
			value.repository_source_sha256 = {
				...value.repository_source_sha256,
				[CONTRACT.source_fingerprint_paths[0]]: '0'.repeat(64)
			};
		}),
	/other bridge sources/
);
refuses(
	'another runtime contract',
	(directory) =>
		editJson(directory, asset + '.provenance.json', (value) => {
			value.runtime_contract_sha256 = '0'.repeat(64);
		}),
	/runtime_contract_sha256 does not bind/
);
refuses(
	'native Go tests that did not execute',
	(directory) =>
		editJson(directory, asset + '.go-tests.receipt.json', (value) => {
			value.native_execution = false;
		}),
	/native_execution does not bind/
);
refuses(
	'native Go tests of another commit',
	(directory) =>
		editJson(directory, asset + '.go-tests.receipt.json', (value) => {
			value.repository_commit = 'd'.repeat(40);
		}),
	/Native Go receipt repository_commit/
);
refuses(
	'a catalogue that lists other bytes',
	(directory) =>
		editJson(directory, 'managed_ollama_release.json', (value) => {
			Object.values(value.assets)[0].sha256 = '0'.repeat(64);
		}),
	/catalogue lists other asset bytes/
);
refuses(
	'a catalogue of another commit',
	(directory) =>
		editJson(directory, 'managed_ollama_release.json', (value) => {
			value.repository_commit = 'd'.repeat(40);
		}),
	/catalogue names another commit/
);
refuses(
	'a catalogue with a second asset',
	(directory) =>
		editJson(directory, 'managed_ollama_release.json', (value) => {
			value.assets.extra = Object.values(value.assets)[0];
		}),
	/one sealed asset/
);
refuses(
	'an unsealed manifest field',
	(directory) =>
		editJson(directory, Handoff.MANIFEST, (value) => {
			value.cache = 'go-build';
		}),
	/Closed handoff manifest fields/
);
// The producer refuses to seal what the receiver would refuse.
withScratch((scratch) => {
	const environment = producerTree(scratch);
	const provenance = environment.ERGOPTI_OLLAMA_ASSET + '.provenance.json';
	const value = JSON.parse(fs.readFileSync(provenance, 'utf8'));
	value.repository_commit = 'd'.repeat(40);
	fs.writeFileSync(provenance, JSON.stringify(value));
	assert.throws(
		() =>
			Handoff.seal(
				path.join(scratch, 'handoff'),
				CONTEXT,
				Handoff.producerSources(CONTRACT, 'amd64', environment),
				ROOT
			),
		/does not bind this build/
	);
	controls++;
});

// ─────────────────────────────────────────────────
// The receiver waits for, or refuses, exactly its own architecture's build cell
// ─────────────────────────────────────────────────
const producerName = 'macOS / ' + Handoff.producerJobSuffix('amd64');
const job = (overrides = {}) => ({
	name: producerName,
	status: 'in_progress',
	conclusion: null,
	run_attempt: 2,
	...overrides
});
const artifact = (attempt = 2, overrides = {}) => ({
	name: Handoff.artifactName({ ...CONTEXT, attempt }),
	expired: false,
	id: 7,
	...overrides
});
const otherCell = { ...job(), name: 'macOS / ' + Handoff.producerJobSuffix('arm64') };
for (const [label, jobs, artifacts, expected] of [
	['no producer cell listed yet', [otherCell], [], { state: 'wait' }],
	['producer still building', [job(), otherCell], [], { state: 'wait' }],
	['an earlier attempt artifact is not this attempt', [job()], [artifact(1)], { state: 'wait' }],
	[
		'sealed handoff of the current producer attempt',
		[job(), otherCell],
		[artifact(2)],
		{ state: 'ready', name: artifact(2).name, id: 7, attempt: 2 }
	],
	[
		'successful earlier attempt kept by a partial rerun',
		[job({ status: 'completed', conclusion: 'success', run_attempt: 1 })],
		[artifact(1)],
		{ state: 'ready', name: artifact(1).name, id: 7, attempt: 1 }
	]
]) {
	assert.deepEqual(Handoff.select(jobs, artifacts, CONTEXT), expected, label);
	controls++;
}
for (const [label, jobs, artifacts, pattern] of [
	[
		'a failed build cell',
		[job({ status: 'completed', conclusion: 'failure' })],
		[],
		/concluded failure/
	],
	[
		'a cancelled build cell',
		[job({ status: 'completed', conclusion: 'cancelled' })],
		[artifact()],
		/concluded cancelled/
	],
	[
		'a successful build without its artifact',
		[job({ status: 'completed', conclusion: 'success' })],
		[],
		/uploaded no handoff/
	],
	['duplicate build cells', [job(), job()], [], /Duplicate managed Ollama build cells/],
	[
		'duplicate build artifacts',
		[job()],
		[artifact(), artifact()],
		/Duplicate managed Ollama build artifacts/
	],
	['an expired build artifact', [job()], [artifact(2, { expired: true })], /expired/],
	[
		'a build attempt from the future',
		[job({ run_attempt: 3 })],
		[],
		/Invalid managed Ollama build attempt/
	]
]) {
	assert.throws(() => Handoff.select(jobs, artifacts, CONTEXT), pattern, label);
	controls++;
}
assert.equal(
	Handoff.select(
		[job()],
		[artifact(2, { name: artifact(2).name.replace(SHA, 'd'.repeat(40)) })],
		CONTEXT
	).state,
	'wait',
	'an artifact of another commit is never selected'
);
controls++;

// ─────────────────────────────────────────────────
// The application build waits for both qualifying cells, never fewer
// ─────────────────────────────────────────────────
const RUN = { sha: SHA, runId: '42', attempt: 2 };
const qualifier = (architecture, overrides = {}) => ({
	name: 'macOS / ' + Handoff.qualifierJobSuffix(architecture),
	status: 'completed',
	conclusion: 'success',
	run_attempt: 2,
	...overrides
});
const inputs = (architecture, overrides = {}) => ({
	name: Handoff.qualifiedArtifactName(RUN, architecture),
	expired: false,
	id: 9,
	...overrides
});
const bothInputs = [inputs('arm64'), inputs('amd64')];
for (const [label, jobs, artifacts, expected] of [
	['no qualifying cell listed yet', [job()], [], { state: 'wait', waiting: ['arm64', 'amd64'] }],
	[
		'Intel still qualifying after Apple silicon succeeded',
		[qualifier('arm64'), qualifier('amd64', { status: 'in_progress', conclusion: null })],
		bothInputs,
		{ state: 'wait', waiting: ['amd64'] }
	],
	[
		'an uploaded input whose cell is still receiving models',
		[qualifier('arm64', { status: 'in_progress', conclusion: null }), qualifier('amd64')],
		bothInputs,
		{ state: 'wait', waiting: ['arm64'] }
	],
	[
		'both qualifying cells succeeded with their inputs',
		[qualifier('arm64'), qualifier('amd64'), job()],
		bothInputs,
		{ state: 'ready', names: bothInputs.map((row) => row.name) }
	],
	[
		'an earlier successful attempt kept by a partial rerun',
		[qualifier('arm64', { run_attempt: 1 }), qualifier('amd64')],
		bothInputs,
		{ state: 'ready', names: bothInputs.map((row) => row.name) }
	]
]) {
	assert.deepEqual(Handoff.selectQualified(jobs, artifacts, RUN), expected, label);
	controls++;
}
for (const [label, jobs, artifacts, pattern] of [
	[
		'a failed qualifying cell',
		[qualifier('arm64'), qualifier('amd64', { conclusion: 'failure' })],
		bothInputs,
		/Managed Ollama \(macOS 15, Intel\)\) cell concluded failure/
	],
	[
		'a cancelled qualifying cell',
		[qualifier('arm64', { conclusion: 'cancelled' }), qualifier('amd64')],
		bothInputs,
		/concluded cancelled/
	],
	[
		'a successful qualifying cell without its inputs',
		[qualifier('arm64'), qualifier('amd64')],
		[inputs('arm64')],
		/uploaded no qualified inputs/
	],
	[
		'inputs of another commit',
		[qualifier('arm64'), qualifier('amd64')],
		[inputs('arm64'), inputs('amd64', { name: inputs('amd64').name.replace(SHA, 'd'.repeat(40)) })],
		/uploaded no qualified inputs/
	],
	[
		'duplicate qualifying cells',
		[qualifier('arm64'), qualifier('arm64'), qualifier('amd64')],
		bothInputs,
		/Duplicate managed Ollama qualifying cells/
	],
	[
		'duplicate qualified inputs',
		[qualifier('arm64'), qualifier('amd64')],
		[...bothInputs, inputs('amd64')],
		/Duplicate qualified managed Ollama inputs/
	],
	[
		'expired qualified inputs',
		[qualifier('arm64'), qualifier('amd64')],
		[inputs('arm64'), inputs('amd64', { expired: true })],
		/expired/
	],
	[
		'a qualifying attempt from the future',
		[qualifier('arm64', { run_attempt: 3 }), qualifier('amd64')],
		bothInputs,
		/Invalid managed Ollama qualifying attempt/
	]
]) {
	assert.throws(() => Handoff.selectQualified(jobs, artifacts, RUN), pattern, label);
	controls++;
}

// ─────────────────────────────────────────────────
// The workflow uploads and names exactly what the receiver waits for
// ─────────────────────────────────────────────────
const workflow = YAML.parse(
	fs.readFileSync(path.join(ROOT, '.github/workflows/ci-macos.yml'), 'utf8')
);
const e2e = workflow.jobs['e2e-hs'];
assert.equal(e2e.name, 'E2E tests');
for (const architecture of ['arm64', 'amd64'])
	assert.equal(
		Handoff.producerJobSuffix(architecture),
		'E2E tests (' + roleLot('e2e', 'managed-ollama-build', architecture, '') + ')'
	);
const hand = e2e.steps.find(
	(step) => step.name === 'Hand the clean native source build to its receiving cell'
);
assert.equal(
	hand.with.name,
	'managed-ollama-build-${{ env.MACOS_STAGE_ARCHITECTURE }}-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}'
);
assert.equal(
	Handoff.artifactName({ ...CONTEXT, architecture: 'arm64' }),
	['managed-ollama-build', 'arm64', SHA, '42', '2'].join('-')
);
assert.equal(hand.with.path, '${{ runner.temp }}/managed-ollama-handoff');
assert.deepEqual(e2e.permissions, { contents: 'read', actions: 'read' });
const producerSteps = e2e.steps.filter((step) => /'managed-ollama-build'/.test(step.if ?? ''));
assert.ok(
	!producerSteps.some(
		(step) => /actions\/cache/.test(step.uses ?? '') || /GOCACHE|GOMODCACHE/.test(step.run ?? '')
	),
	'the clean build never restores a cache'
);
controls += 5;
// The build that packages beside E2E waits for exactly the uploaded inputs.
for (const architecture of ['arm64', 'amd64'])
	assert.equal(
		Handoff.qualifierJobSuffix(architecture),
		'E2E tests (' + roleLot('e2e', 'managed-ollama-native', architecture, '') + ')'
	);
const qualifiedUpload = e2e.steps.find(
	(step) => step.name === 'Upload qualified native inputs for the application catalogue'
);
assert.equal(
	qualifiedUpload.with.name,
	'managed-ollama-inputs-${{ env.MACOS_STAGE_ARCHITECTURE }}-${{ github.sha }}-${{ github.run_id }}'
);
assert.equal(
	Handoff.qualifiedArtifactName(RUN, 'amd64'),
	['managed-ollama-inputs', 'amd64', SHA, '42'].join('-')
);
const build = workflow.jobs['package-macos'];
assert.deepEqual(build.needs, ['test-hs'], 'the build runs beside E2E');
assert.deepEqual(build.permissions, { contents: 'read', actions: 'read' });
const names = build.steps.map((step) => step.name);
const awaiting = names.indexOf('Await both source-qualified native producer inputs');
const download = names.indexOf('Receive both source-qualified native producer inputs');
assert.ok(awaiting > 0 && download === awaiting + 1, 'the build waits right before downloading');
assert.equal(build.steps[awaiting].run, 'node tools/ci/managed-ollama-handoff.cjs await-qualified');
assert.equal(build.steps[awaiting].env.GITHUB_TOKEN, '${{ github.token }}');
assert.equal(
	build.steps[download].with.pattern,
	'managed-ollama-inputs-*-${{ github.sha }}-${{ github.run_id }}'
);
assert.ok(
	names.indexOf('Build ErgoptiPlus.app') > download,
	'the application is built from the qualified inputs only'
);
controls += 4;

// A run listing is read one page of API_PAGE_SIZE at a time: GitHub answered
// 502 for every jobs page of 70 or more jobs of a three-OS dispatch.
const paging = (async () => {
	assert.equal(API_PAGE_SIZE, 50, 'GitHub answers 502 for heavier jobs pages');
	const rows = Array.from({ length: 2 * API_PAGE_SIZE + 1 }, (_, id) => ({ id }));
	const routes = [];
	const read = async (route) => {
		routes.push(route);
		const match = /[?&]per_page=(\d+)&page=(\d+)$/.exec(route);
		assert.ok(match, 'every listing names its page size and page');
		const size = Number(match[1]);
		const page = Number(match[2]);
		return { jobs: rows.slice((page - 1) * size, page * size) };
	};
	assert.deepEqual(await Handoff.listAll('/runs/1/jobs?filter=latest', 'jobs', read), rows);
	assert.deepEqual(
		routes,
		[1, 2, 3].map((page) => '/runs/1/jobs?filter=latest&per_page=50&page=' + page)
	);
	controls++;
})();

paging.then(
	() =>
		console.log(
			`PASS: managed Ollama build handoff — ${controls} admission, refusal and wiring controls.`
		),
	(error) => {
		console.error(error);
		process.exitCode = 1;
	}
);
