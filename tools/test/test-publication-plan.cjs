// tools/test/test-publication-plan.cjs

/** Exercises retained publication authority without native jobs or publication. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const YAML = require('yaml');
const { create, receive, read, main, FIELDS } = require('../ci/publication-plan.cjs');

const env = {
	GITHUB_REPOSITORY: 'adrienm7/ergopti',
	GITHUB_SHA: 'a'.repeat(40),
	GITHUB_RUN_ID: '12345',
	GITHUB_RUN_ATTEMPT: '1',
	GITHUB_EVENT_NAME: 'push',
	GITHUB_REF: 'refs/heads/dev',
	CI_OS_SELECTION: 'all',
	CI_PLAN_RELEASE: 'true',
	CI_PLAN_VERSION: '0.0.0-dev.200',
	CI_PLAN_TAG: 'v0.0.0-dev.200',
	CI_PLAN_TITLE: 'Ergopti v0.0.0-dev.200',
	CI_PLAN_PRERELEASE: 'true',
	CI_PLAN_CHANNEL: 'dev',
	CI_PLAN_LINUX_BUNDLE: 'ErgoptiPlus-linux.tar.gz',
	CI_PLAN_NATIVE_QUALIFICATION_PROFILE: '',
	CI_PLAN_LANE_WINDOWS: 'true',
	CI_PLAN_LANE_MACOS: 'true',
	CI_PLAN_LANE_LINUX: 'true'
};
const jobs = Object.fromEntries(
	['core', 'windows', 'macos', 'linux'].map((key) => [key, { result: 'success' }])
);
let checks = 0;
function refuses(fn) {
	assert.throws(fn);
	checks++;
}
function clone(value) {
	return JSON.parse(JSON.stringify(value));
}
const record = create(env);
assert.deepEqual(receive(record, env, jobs), record.plan);
checks++;
assert.deepEqual(receive(record, { ...env, GITHUB_RUN_ATTEMPT: '2' }, jobs), record.plan);
checks++;
for (const key of [
	'GITHUB_REPOSITORY',
	'GITHUB_SHA',
	'GITHUB_RUN_ID',
	'GITHUB_REF',
	'GITHUB_EVENT_NAME'
])
	refuses(() =>
		receive(record, { ...env, [key]: key === 'GITHUB_SHA' ? 'b'.repeat(40) : 'foreign' }, jobs)
	);
refuses(() => receive(record, { ...env, GITHUB_RUN_ATTEMPT: '0' }, jobs));
const future = clone(record);
future.context.producer_attempt = '3';
refuses(() => receive(future, { ...env, GITHUB_RUN_ATTEMPT: '2' }, jobs));
for (const job of Object.keys(jobs))
	for (const status of ['failure', 'cancelled', 'skipped', '']) {
		const changed = clone(jobs);
		changed[job].result = status;
		refuses(() => receive(record, env, changed));
	}
for (const job of Object.keys(jobs)) {
	const changed = clone(jobs);
	delete changed[job];
	refuses(() => receive(record, env, changed));
}
refuses(() => receive(record, env, { ...jobs, validate: { result: 'success' } }));
for (const field of FIELDS) {
	const changed = clone(record);
	delete changed.plan[field];
	refuses(() => receive(changed, env, jobs));
}
for (const bad of [
	{ ...env, CI_PLAN_LANE_WINDOWS: 'false' },
	{
		...env,
		CI_PLAN_TAG: 'v1.2.3',
		CI_PLAN_VERSION: '1.2.3',
		CI_PLAN_TITLE: 'Ergopti v1.2.3',
		CI_PLAN_CHANNEL: 'main'
	},
	{ ...env, GITHUB_REF: 'refs/heads/main', CI_PLAN_PRERELEASE: 'false' },
	{ ...env, CI_PLAN_RELEASE: 'false' },
	{ ...env, CI_PLAN_TITLE: 'bad\nrelease=true' },
	{ ...env, CI_PLAN_LINUX_BUNDLE: '../outside.tar.gz' }
])
	refuses(() => create(bad));
refuses(() => create({ ...env, GITHUB_REF: 'refs/heads/' + 'x'.repeat(4097) }));
const stable = {
	...env,
	GITHUB_REF: 'refs/heads/main',
	CI_PLAN_VERSION: '1.0.2',
	CI_PLAN_TAG: 'v1.0.2',
	CI_PLAN_TITLE: 'Ergopti v1.0.2',
	CI_PLAN_CHANNEL: 'main',
	CI_PLAN_PRERELEASE: 'false'
};
assert.equal(receive(create(stable), stable, jobs).tag, 'v1.0.2');
checks++;
const manual = {
	...env,
	GITHUB_EVENT_NAME: 'workflow_dispatch',
	CI_OS_SELECTION: 'linux',
	CI_PLAN_RELEASE: 'false',
	CI_PLAN_VERSION: '',
	CI_PLAN_TAG: '',
	CI_PLAN_TITLE: '',
	CI_PLAN_PRERELEASE: '',
	CI_PLAN_LANE_WINDOWS: 'false',
	CI_PLAN_LANE_MACOS: 'false'
};
const subset = { ...jobs, windows: { result: 'skipped' }, macos: { result: 'skipped' } };
assert.equal(receive(create(manual), manual, subset).release, 'false');
checks++;
refuses(() => receive(create(manual), manual, jobs));
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-publication-plan-'));
try {
	const file = path.join(directory, 'plan.json'),
		output = path.join(directory, 'output');
	main(['create', file], env);
	assert.deepEqual(read(file), record);
	checks++;
	refuses(() => main(['create', file], env));
	const image = fs.readFileSync(file, 'utf8');
	for (const malformed of [
		image.trimEnd(),
		image.replace('"release":"true"', '"release":"false","release":"true"'),
		image.replace('"release"', '"relea\\u0073e"'),
		'\uFEFF' + image,
		image.replace(/\n$/, '\r\n')
	]) {
		fs.writeFileSync(file, malformed);
		refuses(() => read(file));
	}
	fs.writeFileSync(file, Buffer.alloc(65537, 32));
	refuses(() => read(file));
	refuses(() => read(directory));
	refuses(() => read(path.join(directory, 'missing')));
	fs.writeFileSync(file, image);
	const cli = path.resolve(__dirname, '../ci/publication-plan.cjs');
	const result = spawnSync(process.execPath, [cli, 'receive', file], {
		encoding: 'utf8',
		timeout: 10000,
		env: {
			...process.env,
			...env,
			GITHUB_RUN_ATTEMPT: '2',
			GITHUB_OUTPUT: output,
			CI_JOB_RESULTS: JSON.stringify(jobs)
		}
	});
	assert.equal(result.error, undefined);
	assert.equal(result.signal, null);
	assert.equal(result.status, 0);
	assert.equal(result.stderr, '');
	assert.equal(
		fs.readFileSync(output, 'utf8'),
		FIELDS.map((key) => `${key}=${record.plan[key]}\n`).join('')
	);
	checks++;
	fs.unlinkSync(file);
	const absent = spawnSync(process.execPath, [cli, 'receive', file], {
		encoding: 'utf8',
		timeout: 10000,
		env: { ...process.env, ...env, GITHUB_OUTPUT: output, CI_JOB_RESULTS: JSON.stringify(jobs) }
	});
	assert.equal(absent.status, 1);
	assert.equal(absent.signal, null);
	checks++;
} finally {
	fs.rmSync(directory, { recursive: true, force: true });
}

/**
 * Requires the actual scheduler and artifact channels before trusting a plan:
 * ci.yml validates and calls Release once every lane finished; ci-release.yml
 * receives the lane results and the selection from that caller alone.
 */
function validateWorkflow(workflow) {
	const jobs = workflow.root.jobs;
	const releaseJobs = workflow.release.jobs;
	const producer = jobs.validate.steps;
	const createStep = producer.at(-2);
	const upload = producer.at(-1);
	assert.equal(
		createStep.run,
		'node tools/ci/publication-plan.cjs create ci-publication-plan.json'
	);
	const sources = {
		release: 'meta',
		version: 'meta',
		tag: 'meta',
		title: 'meta',
		prerelease: 'meta',
		channel: 'meta',
		linux_bundle: 'contract',
		native_qualification_profile: 'qualification',
		lane_windows: 'lanes',
		lane_macos: 'lanes',
		lane_linux: 'lanes'
	};
	for (const key of FIELDS)
		assert.equal(
			createStep.env['CI_PLAN_' + key.toUpperCase()],
			'${{ steps.' + sources[key] + '.outputs.' + key + ' }}'
		);
	const selection = "${{ inputs.os_lanes || 'all' }}";
	assert.equal(createStep.env.CI_OS_SELECTION, selection);
	assert.equal(upload.uses, 'actions/upload-artifact@v4');
	assert.equal(upload.with.name, 'ci-publication-plan-${{ github.sha }}-${{ github.run_id }}');
	assert.equal(upload.with.path, 'ci-publication-plan.json');
	assert.equal(upload.with['if-no-files-found'], 'error');
	assert.equal(upload.with.overwrite, true);
	for (const lane of ['core', 'windows', 'macos', 'linux'])
		assert.deepEqual(jobs[lane].needs, ['validate', 'prepare-common']);
	const caller = jobs.publication;
	assert.equal(caller.uses, './.github/workflows/ci-release.yml');
	assert.deepEqual(caller.needs, ['macos', 'windows', 'linux', 'core']);
	assert.equal(caller.if, 'always() && !cancelled()');
	assert.deepEqual(caller.with, { os_lanes: selection, lane_results: '${{ toJSON(needs) }}' });
	assert.deepEqual(Object.keys(releaseJobs), ['publication-plan', 'release']);
	assert.deepEqual(Object.keys(workflow.release.on.workflow_call.inputs), [
		'os_lanes',
		'lane_results'
	]);
	const preflight = releaseJobs['publication-plan'];
	assert.equal(preflight.needs, undefined);
	assert.equal(preflight.if, undefined);
	assert.ok(!preflight.permissions && !JSON.stringify(preflight).includes('secrets.'));
	const download = preflight.steps.find((step) => step.uses === 'actions/download-artifact@v4');
	assert.equal(download.with.name, upload.with.name);
	assert.equal(download.with.path, 'publication-plan');
	const receiveStep = preflight.steps.at(-1);
	assert.equal(receiveStep.id, 'plan');
	assert.equal(receiveStep.env.CI_JOB_RESULTS, '${{ inputs.lane_results }}');
	assert.equal(receiveStep.env.CI_OS_SELECTION, '${{ inputs.os_lanes }}');
	assert.equal(
		receiveStep.run,
		'node tools/ci/publication-plan.cjs receive publication-plan/ci-publication-plan.json'
	);
	for (const key of FIELDS.filter((key) => !key.startsWith('lane_')))
		assert.equal(preflight.outputs[key], '${{ steps.plan.outputs.' + key + ' }}');
	assert.deepEqual(releaseJobs.release.needs, ['publication-plan']);
	assert.equal(
		releaseJobs.release.if,
		"github.event_name == 'push' && needs.publication-plan.outputs.release == 'true'"
	);
	assert.ok(!JSON.stringify(releaseJobs.release).includes('needs.validate.outputs.'));
	for (const field of [
		'tag',
		'version',
		'title',
		'prerelease',
		'channel',
		'linux_bundle',
		'native_qualification_profile'
	])
		assert.ok(
			JSON.stringify(releaseJobs.release).includes('needs.publication-plan.outputs.' + field)
		);
}
const readWorkflow = (file) =>
	YAML.parse(fs.readFileSync(path.resolve(__dirname, '../../.github/workflows', file), 'utf8'));
const workflow = { root: readWorkflow('ci.yml'), release: readWorkflow('ci-release.yml') };
validateWorkflow(workflow);
checks++;
for (const mutate of [
	(w) => {
		w.root.jobs.validate.steps.pop();
	},
	(w) => {
		w.root.jobs.validate.steps.at(-2).env.CI_PLAN_RELEASE = 'true';
	},
	(w) => {
		w.root.jobs.validate.steps.at(-1).with.name = 'unbound';
	},
	(w) => {
		w.root.jobs.core.needs = [];
	},
	(w) => {
		w.release.jobs['publication-plan'].steps.at(-1).env.CI_JOB_RESULTS = '{}';
	},
	(w) => {
		w.root.jobs.publication.with.lane_results = '{}';
	},
	(w) => {
		w.root.jobs.publication.needs = ['macos', 'windows', 'linux'];
	},
	(w) => {
		w.root.jobs.publication.if = 'success()';
	},
	(w) => {
		w.release.jobs['publication-plan'].needs = ['release'];
	},
	(w) => {
		w.release.jobs['publication-plan'].steps.at(-1).run = 'echo release=true >> "$GITHUB_OUTPUT"';
	},
	(w) => {
		w.release.jobs['publication-plan'].outputs.tag = '${{ inputs.tag }}';
	},
	(w) => {
		w.release.jobs.release.needs = ['validate'];
	},
	(w) => {
		w.release.jobs.release.if = 'always()';
	},
	(w) => {
		w.release.jobs.release.env.ERGOPTI_DEV_RELEASE_TAG = '${{ needs.validate.outputs.tag }}';
	}
]) {
	const changed = clone(workflow);
	mutate(changed);
	refuses(() => validateWorkflow(changed));
}
for (const lane of ['core', 'windows', 'macos', 'linux'])
	for (const needs of [
		['validate'],
		['prepare-common'],
		['validate', 'prepare-common', 'foreign'],
		['validate', 'prepare-common', 'prepare-common'],
		['validate', 'prepare-common', 'core']
	]) {
		const changed = clone(workflow);
		changed.root.jobs[lane].needs = needs;
		refuses(() => validateWorkflow(changed));
	}
console.log(`Publication plan controls: ${checks} passed; no publication or native qualification.`);
