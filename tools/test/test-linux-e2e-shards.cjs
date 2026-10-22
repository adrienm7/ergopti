// tools/test/test-linux-e2e-shards.cjs

/**
 * ============================================================================
 * MODULE: Linux E2E Matrix Shard Contract Tests
 * DESCRIPTION:
 * The Linux E2E job of .github/workflows/ci-linux.yml runs as a matrix of
 * domain rows so that its harnesses no longer queue one after another. The
 * split must not lose a harness, run one twice, separate a harness from the
 * step that prepares it, or let the build, the verdict or the release go ahead
 * while a row is missing. tools/test/fixtures/linux-e2e-shards.json lists every
 * step of the former single job once; this test pins the workflow to it and
 * mutation-tests each refusal on copies of the real workflow text.
 * ============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const YAML = require('yaml');
const pipeline = require('./ci-pipeline.cjs');
const LinuxE2E = require('./fixtures/linux-e2e-shards.cjs');
const { verifyAggregate } = require('./linux-ci-evidence.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const LINUX_BOX = '.github/workflows/ci-linux.yml';
const JOB = 'e2e-linux';
const WORKFLOW = fs.readFileSync(path.join(ROOT, LINUX_BOX), 'utf8');
const MANIFEST = JSON.parse(
	fs.readFileSync(path.join(ROOT, '.github/linux-ci-coverage.json'), 'utf8')
);
const FIXTURE = LinuxE2E.fixture;
const NOT_CANCELLED = '${{ !cancelled() }}';
const ROW_CLAUSE = /matrix\.shard == '([^']*)'/g;

/** The key a step is listed under: its name, or `uses: <action>` when unnamed. */
function stepKey(step) {
	return step.name ?? 'uses: ' + step.uses;
}

/** The Record step's case branches, each with the subjects it records. */
function recordBranches(run) {
	const branches = new Map();
	const lines = run.split('\n');
	let current = null;
	for (const line of lines) {
		const label = /^([a-z0-9-]+|\*)\)$/.exec(line);
		if (label) {
			current = label[1];
			assert.ok(!branches.has(current), 'duplicate record branch ' + current);
			branches.set(current, []);
			continue;
		}
		if (line === ';;') {
			current = null;
			continue;
		}
		const subject = /--subject "?([a-z0-9-]+)=/.exec(line);
		if (subject) {
			if (current === null) branches.set('<outside a row>', [subject[1]]);
			else branches.get(current).push(subject[1]);
		}
	}
	return branches;
}

/**
 * Lists every way the workflow text breaks the shard contract.
 * @param {string} text ci-linux.yml.
 * @param {object} manifest .github/linux-ci-coverage.json.
 * @returns {string[]}
 */
function problems(text, manifest = MANIFEST) {
	const found = [];
	let workflow;
	try {
		workflow = YAML.parse(text);
	} catch (error) {
		return ['the workflow is not valid YAML: ' + error.message];
	}
	const job = workflow.jobs[JOB];
	if (!job) return ['the workflow has no ' + JOB + ' job'];
	const shards = Object.keys(FIXTURE.shards);

	// The matrix: one row per fixture domain, every row run to the end.
	if (job.name !== 'E2E tests') found.push('the E2E column must keep the name E2E tests');
	if (JSON.stringify(job.strategy?.matrix?.shard) !== JSON.stringify(shards))
		found.push('the matrix rows must be exactly ' + shards.join(', '));
	if (Object.keys(job.strategy?.matrix ?? {}).length !== 1)
		found.push('the matrix must vary the shard alone');
	if (job.strategy?.['fail-fast'] !== false)
		found.push('a red row must not cancel the other rows (fail-fast: false)');
	if (job.env?.LINUX_E2E_SHARD !== '${{ matrix.shard }}')
		found.push('LINUX_E2E_SHARD must carry the matrix row');
	if (JSON.stringify(manifest.jobs[JOB]?.shards) !== JSON.stringify(shards))
		found.push('the coverage manifest must declare the same rows');

	// Every former step exactly once: in every row (shared) or in its one row.
	const keys = job.steps.map(stepKey);
	const listed = [...FIXTURE.shared, ...Object.values(FIXTURE.shards).flat()];
	for (const key of listed)
		if (keys.filter((candidate) => candidate === key).length !== 1)
			found.push('step "' + key + '" must appear exactly once in ' + JOB);
	for (const key of keys)
		if (!listed.includes(key)) found.push('step "' + key + '" belongs to no row');
	for (const step of job.steps) {
		const key = stepKey(step);
		if (!listed.includes(key)) continue;
		const rows = [...String(step.if ?? '').matchAll(ROW_CLAUSE)].map((match) => match[1]);
		const shard = LinuxE2E.shardOf(key);
		if (shard === null) {
			if (rows.length) found.push('shared step "' + key + '" must run in every row');
			continue;
		}
		if (rows.length !== 1 || rows[0] !== shard)
			found.push('step "' + key + '" must run in row ' + shard + ' alone');
		const base = String(step.if).includes('always()') ? 'always()' : NOT_CANCELLED;
		if (step.if !== LinuxE2E.condition(key, base))
			found.push('step "' + key + '" must keep its original predicate within its row');
	}
	for (const [shard, names] of Object.entries(FIXTURE.shards))
		if (names.length === 0) found.push('row ' + shard + ' runs nothing');

	// A prepared effect stays in the row, and the order, of what consumes it.
	for (const [consumer, prerequisites] of Object.entries(FIXTURE.prerequisites))
		for (const prerequisite of prerequisites) {
			const consumerAt = keys.indexOf(consumer);
			const prerequisiteAt = keys.indexOf(prerequisite);
			if (
				consumerAt < 0 ||
				prerequisiteAt < 0 ||
				prerequisiteAt > consumerAt ||
				LinuxE2E.shardOf(consumer) !== LinuxE2E.shardOf(prerequisite)
			)
				found.push('"' + consumer + '" must follow "' + prerequisite + '" in its row');
		}

	// Artifacts: names unique per row; a fixed name belongs to one row only.
	for (const step of job.steps) {
		if (!String(step.uses ?? '').startsWith('actions/upload-artifact@')) continue;
		const name = String(step.with?.name ?? '');
		if (LinuxE2E.shardOf(stepKey(step)) === null && !name.includes('${{ matrix.shard }}'))
			found.push('upload "' + stepKey(step) + '" runs in every row and needs a row-unique name');
	}
	const record = job.steps.find((step) => step.name === 'Record mandatory E2E evidence');
	const upload = job.steps.find((step) => step.name === 'Upload mandatory E2E evidence');
	if (!record || !upload) return [...found, 'the evidence record and upload must remain'];
	if (record.if !== undefined || upload.if !== undefined)
		found.push('the evidence record and upload run only when every harness of the row passed');
	if (upload.with?.name !== 'linux-ci-evidence-e2e-linux-${{ matrix.shard }}')
		found.push('each row uploads its own linux-ci-evidence-* artifact');
	if (
		upload.with?.path !== '${{ runner.temp }}/linux-ci-evidence/e2e-linux-${{ matrix.shard }}.json'
	)
		found.push('each row uploads its own evidence file (merge-multiple keeps every row)');

	// Evidence: each row records exactly its own subjects, all of them once.
	const branches = recordBranches(String(record.run));
	const recorded = [];
	for (const shard of shards) {
		const subjects = branches.get(shard);
		if (!subjects) {
			found.push('the evidence record has no branch for row ' + shard);
			continue;
		}
		if (JSON.stringify(subjects) !== JSON.stringify(FIXTURE.subjects[shard]))
			found.push('row ' + shard + ' must record exactly its fixture subjects');
		recorded.push(...subjects);
	}
	for (const label of branches.keys())
		if (label !== '*' && !shards.includes(label))
			found.push('the evidence record has a branch for unknown row ' + label);
	if (!branches.has('*')) found.push('an unknown row must fail the evidence record');
	const manifestSubjects = Object.keys(manifest.jobs[JOB]?.subjects ?? {});
	if (JSON.stringify([...recorded].sort()) !== JSON.stringify([...manifestSubjects].sort()))
		found.push('the rows must record every manifest subject exactly once');
	const run = String(record.run);
	for (const fragment of [
		'--shard "$LINUX_E2E_SHARD"',
		'--output "$RUNNER_TEMP/linux-ci-evidence/e2e-linux-$LINUX_E2E_SHARD.json"'
	])
		if (run.split(fragment).length !== 3)
			found.push('both the executed and the deferred record must carry ' + fragment);

	// Downstream: the build, the verdict and the release wait for every row.
	if (JSON.stringify(workflow.jobs['package-linux']?.needs) !== JSON.stringify([JOB]))
		found.push('package-linux must need ' + JOB + ' (the whole matrix)');
	if (!String(workflow.jobs['package-linux']?.if).includes("needs.e2e-linux.result == 'success'"))
		found.push('package-linux must require the aggregate matrix result');
	return found;
}

// ─────────────────────────────────────────────────
// The real workflow satisfies the contract
// ─────────────────────────────────────────────────
assert.deepEqual(problems(WORKFLOW), []);

// The fixture inventory is the former single job plus the model pull install: 159 steps, six shared.
const listed = [...FIXTURE.shared, ...Object.values(FIXTURE.shards).flat()];
assert.equal(new Set(listed).size, listed.length, 'a step is listed twice');
assert.equal(FIXTURE.shared.length, 6);
assert.equal(
	listed.length,
	159,
	'the former E2E job had 158 steps and gained the model pull install; none may be lost'
);
assert.deepEqual(
	Object.keys(FIXTURE.subjects),
	Object.keys(FIXTURE.shards),
	'every row declares its subjects'
);

// The scheduler and the verdict still treat e2e-linux as one mandatory job.
assert.deepEqual(
	require('../ci/ci-stage-status.cjs').JOBS.linux,
	['test-linux', 'integration-linux', 'e2e-linux', 'package-linux', 'install-linux'],
	'the Linux scheduler chain keeps e2e-linux as one link'
);
assert.deepEqual(pipeline.needsOf(pipeline.job(JOB)), ['integration-linux']);
assert.equal(MANIFEST.jobs[JOB].classification, 'mandatory');
assert.deepEqual(pipeline.needsOf(pipeline.job('package-linux')), [JOB]);
assert.deepEqual(pipeline.needsOf(pipeline.job('linux-ok')), ['install-linux', 'package-flatpak']);

// ─────────────────────────────────────────────────
// Each refusal fires on a mutated copy of the real workflow
// ─────────────────────────────────────────────────
const lines = WORKFLOW.split('\n');
const stepAt = (name) => lines.findIndex((line) => line === '      - name: ' + name);
/** Replaces the if: line of one named step. */
function withIf(name, value) {
	const at = stepAt(name);
	assert.ok(at >= 0, 'missing step ' + name);
	const ifAt = lines.findIndex((line, index) => index > at && /^ {8}if: /.test(line));
	const copy = [...lines];
	copy[ifAt] = '        if: ' + value;
	return copy.join('\n');
}
/** Removes one named step. */
function without(name) {
	const at = stepAt(name);
	assert.ok(at >= 0, 'missing step ' + name);
	let end = at + 1;
	while (end < lines.length && !/^ {6}- |^ {2}\S/.test(lines[end])) end++;
	return [...lines.slice(0, at), ...lines.slice(end)].join('\n');
}
function replaced(before, after) {
	assert.equal(WORKFLOW.split(before).length, 2, 'mutation target must be unique: ' + before);
	return WORKFLOW.replace(before, after);
}
const mutations = [
	[
		'a harness moved to another row',
		withIf(
			'AI predictions against a real Ollama',
			"${{ !cancelled() && matrix.shard == 'updater' }}"
		)
	],
	['a harness run in every row', withIf('AI predictions against a real Ollama', NOT_CANCELLED)],
	[
		'a harness disabled in its row',
		withIf(
			'AI predictions against a real Ollama',
			"${{ false && matrix.shard == 'input-display' }}"
		)
	],
	[
		'a shared step narrowed to one row',
		withIf('Prepare native GTK dependencies', "${{ !cancelled() && matrix.shard == 'updater' }}")
	],
	['a harness lost', without('Preserve competing JSON backups at native publication')],
	[
		'a prerequisite moved away from its consumer',
		withIf('Install WebKit2GTK and lgi', "${{ !cancelled() && matrix.shard == 'updater' }}")
	],
	['a row dropped from the matrix', replaced('          - platform-metrics\n', '')],
	[
		'fail-fast restored',
		replaced(
			'      fail-fast: false\n      matrix:\n        shard:\n',
			'      fail-fast: true\n      matrix:\n        shard:\n'
		)
	],
	[
		'row-blind evidence artifact',
		replaced(
			'          name: linux-ci-evidence-e2e-linux-${{ matrix.shard }}\n',
			'          name: linux-ci-evidence-e2e-linux\n'
		)
	],
	[
		'row-blind evidence file',
		replaced(
			'          path: ${{ runner.temp }}/linux-ci-evidence/e2e-linux-${{ matrix.shard }}.json\n',
			'          path: ${{ runner.temp }}/linux-ci-evidence/e2e-linux.json\n'
		)
	],
	[
		'a subject recorded by the wrong row',
		replaced('              --subject ollama-live=1\n', '              --subject daemon-live=1\n')
	],
	[
		'an unknown row recorded silently',
		replaced(
			'          *)\n              echo "::error::unknown Linux E2E shard: $LINUX_E2E_SHARD" >&2\n              exit 1\n          ;;\n',
			''
		)
	],
	[
		'the build no longer waits for E2E',
		replaced('    needs: [e2e-linux]\n', '    needs: [test-linux]\n')
	],
	['the shard variable unbound', replaced('      LINUX_E2E_SHARD: ${{ matrix.shard }}\n', '')]
];
for (const [what, text] of mutations) {
	assert.notEqual(text, WORKFLOW, what + ': the mutation must change the workflow');
	assert.ok(problems(text).length > 0, what + ' must be refused');
}
assert.ok(
	problems(WORKFLOW, {
		...MANIFEST,
		jobs: { ...MANIFEST.jobs, [JOB]: { ...MANIFEST.jobs[JOB], shards: ['input-display'] } }
	}).length > 0,
	'a manifest that forgets a row must be refused'
);

// ─────────────────────────────────────────────────
// The verdict refuses a successful matrix that lost a row's evidence
// ─────────────────────────────────────────────────
const SHA = 'f'.repeat(40);
function aggregate() {
	const needs = {};
	const evidence = [];
	for (const [job, contract] of Object.entries(MANIFEST.jobs)) {
		needs[job] = { result: 'success' };
		const rows = contract.shards ?? [null];
		for (const shard of rows)
			evidence.push({
				schema_version: 1,
				job,
				...(shard === null ? {} : { shard }),
				sha: SHA,
				architecture: 'X64',
				distro: 'ubuntu',
				session: 'fixture',
				interpreter: 'fixture',
				subjects: Object.fromEntries(
					(shard === null
						? Object.keys(contract.subjects)
						: job === JOB
							? FIXTURE.subjects[shard]
							: (contract.shard_subjects?.[shard] ?? ['unit-' + shard])
					).map((subject) => [subject, contract.subjects[subject]])
				)
			});
	}
	return { manifest: MANIFEST, needs, evidence, expectedSha: SHA };
}
verifyAggregate(aggregate());
for (const shard of LinuxE2E.shards) {
	const input = aggregate();
	input.evidence = input.evidence.filter((row) => row.shard !== shard);
	assert.throws(() => verifyAggregate(input), /no evidence from shard|has no evidence for/);
}

console.log(
	`PASS: Linux E2E runs ${LinuxE2E.shards.length} domain rows; ${listed.length} former steps each in one row or shared, ${mutations.length + 1} shard refusals, every row required by the verdict.`
);
