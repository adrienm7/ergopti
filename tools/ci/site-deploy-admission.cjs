// tools/ci/site-deploy-admission.cjs

/** Admit one completed canonical CI site artifact before an independent Pages deployment. */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { resolveSiteTarget, siteLot, siteLots } = require('../dev/site-context.cjs');
const { API_PAGE_SIZE } = require('./github-api-page.cjs');
const REPOSITORY = 'adrienm7/ergopti';
const MAX_RECORDS = 1000;
// A listing that moved between pages is re-read from page one at most this often.
const CENSUS_ATTEMPTS = 3;
const CENSUS_CHANGED = Symbol('census changed between pages');

function refuse(ok, detail) {
	if (!ok) throw new Error('Site deployment admission refused: ' + detail);
}

function number(value) {
	const text = typeof value === 'number' ? String(value) : value;
	refuse(
		typeof text === 'string' && /^[1-9][0-9]*$/.test(text) && Number.isSafeInteger(Number(text)),
		'invalid positive ID or attempt.'
	);
	return text;
}

function closed(value, names) {
	refuse(value && typeof value === 'object' && !Array.isArray(value), 'expected closed object.');
	assert.deepEqual(
		Object.keys(value).sort(),
		names.slice().sort(),
		'closed deployment admission keys'
	);
}

/**
 * Collect a finite exact API census; pagination cannot silently omit or duplicate a role.
 * A run still creating jobs (other lanes' reusable workflows) can change the listing
 * between two pages, which shifts rows across page boundaries. That pass proves nothing,
 * so the census restarts from page one, a bounded number of times; every other refusal
 * stays final.
 */
async function collect(readApi, endpoint, field) {
	for (let attempt = 1; attempt <= CENSUS_ATTEMPTS; attempt++) {
		const census = await collectOnce(readApi, endpoint, field);
		if (census !== CENSUS_CHANGED) return census;
	}
	refuse(false, 'API census changed or is malformed.');
}

/** Read one census pass, or return CENSUS_CHANGED when the listing moved between pages. */
async function collectOnce(readApi, endpoint, field) {
	const records = [];
	const ids = new Set();
	let expected;
	for (let page = 1; page <= MAX_RECORDS / API_PAGE_SIZE; page++) {
		const response = await readApi(
			endpoint +
				(endpoint.includes('?') ? '&' : '?') +
				'per_page=' +
				API_PAGE_SIZE +
				'&page=' +
				page
		);
		refuse(
			Number.isSafeInteger(response.total_count) &&
				response.total_count >= 0 &&
				response.total_count <= MAX_RECORDS,
			'API census exceeds bounds.'
		);
		if (expected === undefined) expected = response.total_count;
		refuse(
			Array.isArray(response[field]) && response[field].length <= API_PAGE_SIZE,
			'API census changed or is malformed.'
		);
		if (response.total_count !== expected) return CENSUS_CHANGED;
		for (const row of response[field]) {
			const id = number(row.id);
			refuse(!ids.has(id), 'duplicate API record.');
			ids.add(id);
			records.push(row);
		}
		refuse(records.length <= expected, 'API census has extra records.');
		if (records.length === expected) return records;
		refuse(response[field].length === API_PAGE_SIZE, 'API census is incomplete.');
	}
	throw new Error('Site deployment admission refused: API census did not terminate.');
}

/** Read the actual current CI identity without deployment, branch-tip or completed-run policy. */
async function readCurrentRun(env, readApi) {
	refuse(
		env.GITHUB_ACTIONS === 'true' && env.GITHUB_REPOSITORY === REPOSITORY,
		'actual repository CI context is required.'
	);
	refuse(
		typeof env.GITHUB_SHA === 'string' && /^[a-f0-9]{40}$/.test(env.GITHUB_SHA),
		'invalid actual source SHA.'
	);
	for (const key of ['GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_REPOSITORY_ID'])
		refuse(number(env[key]) === env[key], 'canonical actual CI identity is required.');
	refuse(
		typeof env.GITHUB_EVENT_NAME === 'string' && env.GITHUB_EVENT_NAME.length > 0,
		'actual CI event is required.'
	);
	refuse(
		env.GITHUB_WORKFLOW === 'CI' && typeof readApi === 'function',
		'canonical CI workflow and API reader are required.'
	);
	const prefix = '/repos/' + REPOSITORY + '/actions';
	const run = await readApi(prefix + '/runs/' + env.GITHUB_RUN_ID);
	refuse(
		number(run.id) === env.GITHUB_RUN_ID && number(run.run_attempt) === env.GITHUB_RUN_ATTEMPT,
		'foreign current run or attempt.'
	);
	refuse(
		run.repository?.full_name === REPOSITORY &&
			number(run.repository.id) === env.GITHUB_REPOSITORY_ID,
		'foreign current run repository.'
	);
	refuse(
		typeof run.head_sha === 'string' && /^[a-f0-9]{40}$/.test(run.head_sha),
		'invalid API head SHA.'
	);
	refuse(run.event === env.GITHUB_EVENT_NAME, 'current run event differs from actual CI.');
	refuse(
		typeof run.head_branch === 'string' && run.head_branch.length > 0,
		'missing API head branch.'
	);
	refuse(
		typeof run.head_repository?.full_name === 'string' && run.head_repository.full_name.length > 0,
		'missing API head repository.'
	);
	// Pull requests may build a merge commit while the API identifies their head commit.
	if (run.event !== 'pull_request')
		refuse(run.head_sha === env.GITHUB_SHA, 'API head differs from actual CI source.');
	const workflowId = number(run.workflow_id);
	const workflow = await readApi(prefix + '/workflows/' + workflowId);
	refuse(
		number(workflow.id) === workflowId &&
			workflow.path === '.github/workflows/ci.yml' &&
			workflow.name === env.GITHUB_WORKFLOW,
		'current run is not canonical CI.'
	);
	return {
		run_id: number(run.id),
		run_attempt: number(run.run_attempt),
		head_sha: run.head_sha,
		head_branch: run.head_branch,
		event: run.event,
		workflow_id: workflowId,
		repository_id: number(run.repository.id),
		head_repository_id: number(run.head_repository.id),
		head_repository: run.head_repository.full_name
	};
}

/** Select the exact successful receipt writers for both targets across all actual attempts. */
async function selectSiteJobs(identity, readApi) {
	closed(identity, ['head_sha', 'run_id', 'run_attempt']);
	refuse(
		typeof identity.head_sha === 'string' && /^[a-f0-9]{40}$/.test(identity.head_sha),
		'invalid API head SHA.'
	);
	const headSha = identity.head_sha;
	const runId = number(identity.run_id),
		attempt = number(identity.run_attempt);
	refuse(
		runId === identity.run_id && attempt === identity.run_attempt,
		'canonical run identity is required.'
	);
	refuse(typeof readApi === 'function', 'missing API reader.');
	const prefix = '/repos/' + REPOSITORY + '/actions';
	const targets = Object.values(siteLots()).map((row) => row.target);
	const stages = [
		{ name: 'YAML, shared code & web / Build', writer: 'Build and seal production site' },
		{
			name: 'YAML, shared code & web / Install and launch',
			writer: 'Test received production site'
		}
	];
	const identities = stages.flatMap(({ name, writer }, stage) =>
		targets.map((target) => ({
			stage,
			target,
			// GitHub names a lane's stage job 'Lane / Stage / Job'; each job is named by its lot.
			name: name + ' / ' + siteLot(target),
			writer: writer + ' — ' + siteLot(target)
		}))
	);
	const jobs = await collect(readApi, prefix + '/runs/' + runId + '/jobs?filter=all', 'jobs');
	// Real receipt writers must agree with the human lot in the exact visible job name.
	// Classify every row before choosing attempts so a failed rerun cannot hide old success.
	const cells = stages.map(() => new Map(targets.map((name) => [name, []])));
	for (const job of jobs) {
		const identity = identities.find((row) => job.name === row.name);
		const markers = Array.isArray(job.steps)
			? job.steps.filter(
					(step) =>
						typeof step?.name === 'string' && stages.some((row) => step.name.includes(row.writer))
				)
			: [];
		if (identity === undefined) {
			refuse(markers.length === 0, 'foreign stage job name carries a reserved writer marker.');
			continue;
		}
		refuse(
			Array.isArray(job.steps) && job.steps.length <= MAX_RECORDS && markers.length === 1,
			'missing, duplicate or oversized stage writer metadata.'
		);
		refuse(markers[0].name === identity.writer, 'unknown target or wrong-stage writer marker.');
		refuse(Number(number(job.run_attempt)) <= Number(attempt), 'future stage job attempt.');
		refuse(
			number(job.run_id) === runId && job.head_sha === headSha,
			'stage job is not successful for this source/run.'
		);
		cells[identity.stage].get(identity.target).push({ job, writer: markers[0] });
	}
	const selectedTargets = {};
	for (const cellTarget of targets) {
		const selected = cells.map((stage) => {
			const matches = stage.get(cellTarget);
			refuse(matches.length > 0, 'missing stage job name for an authored target.');
			const latest = Math.max(...matches.map(({ job }) => Number(number(job.run_attempt))));
			const current = matches.filter(({ job }) => Number(number(job.run_attempt)) === latest);
			refuse(current.length === 1, 'duplicate stage job name for the chosen target/attempt.');
			const { job, writer } = current[0];
			refuse(
				job.status === 'completed' && job.conclusion === 'success',
				'stage job is not successful for this source/run.'
			);
			refuse(
				writer.status === 'completed' && writer.conclusion === 'success',
				'selected stage receipt writer is not successful.'
			);
			return { job_id: number(job.id), run_attempt: number(job.run_attempt) };
		});
		refuse(
			Number(number(selected[0].run_attempt)) <= Number(number(selected[1].run_attempt)),
			'stage attempt lineage runs backward.'
		);
		selectedTargets[cellTarget] = { build: selected[0], testbuild: selected[1] };
	}
	return selectedTargets;
}

/** Admit metadata only; downloaded build bytes and browser evidence must be received separately. */
async function admitProducer(selection, readApi) {
	closed(selection, ['repository', 'trigger']);
	refuse(
		selection.repository === REPOSITORY && typeof readApi === 'function',
		'foreign repository or missing API reader.'
	);
	const trigger = selection.trigger;
	refuse(trigger?.kind === 'manual' || trigger?.kind === 'workflow_run', 'unsupported trigger.');
	closed(
		trigger,
		trigger.kind === 'manual'
			? ['kind', 'run_id']
			: ['kind', 'action', 'run_id', 'source_sha', 'branch']
	);
	if (trigger.kind === 'workflow_run')
		refuse(trigger.action === 'completed', 'completion event is required.');
	const runId = number(trigger.run_id);
	const prefix = '/repos/' + REPOSITORY + '/actions';
	const run = await readApi(prefix + '/runs/' + runId);
	refuse(number(run.id) === runId, 'foreign run.');
	refuse(
		run.repository?.full_name === REPOSITORY && run.head_repository?.full_name === REPOSITORY,
		'foreign repository or fork run.'
	);
	const repositoryId = number(run.repository.id);
	const headRepositoryId = number(run.head_repository.id);
	refuse(repositoryId === headRepositoryId, 'fork repository identity.');
	refuse(
		run.event === 'push' && run.status === 'completed' && run.conclusion === 'success',
		'producer must be a completed successful push.'
	);
	refuse(
		run.head_branch === 'main' || run.head_branch === 'dev',
		'producer branch is not a deployment target.'
	);
	refuse(
		typeof run.head_sha === 'string' && /^[a-f0-9]{40}$/.test(run.head_sha),
		'invalid producer source.'
	);
	const attempt = number(run.run_attempt);
	if (trigger.kind === 'workflow_run')
		refuse(
			trigger.source_sha === run.head_sha && trigger.branch === run.head_branch,
			'completion event differs from actual producer.'
		);
	const workflow = await readApi(prefix + '/workflows/' + number(run.workflow_id));
	refuse(
		number(workflow.id) === number(run.workflow_id) &&
			workflow.path === '.github/workflows/ci.yml' &&
			workflow.name === 'CI',
		'producer workflow is not canonical CI.'
	);
	const target = run.head_branch;
	await selectSiteJobs({ head_sha: run.head_sha, run_id: runId, run_attempt: attempt }, readApi);
	const artifacts = await collect(readApi, prefix + '/runs/' + runId + '/artifacts', 'artifacts');
	const artifactIds = ['common-site-build-', 'common-site-testbuild-'].map((name) => {
		const matches = artifacts.filter((row) => row.name === name + target);
		refuse(matches.length === 1, 'missing or duplicate exact site artifact.');
		const row = matches[0],
			owner = row.workflow_run;
		refuse(
			row.expired === false &&
				typeof row.digest === 'string' &&
				/^sha256:[a-f0-9]{64}$/.test(row.digest),
			'expired or unsealed API artifact.'
		);
		refuse(
			owner &&
				number(owner.id) === runId &&
				number(owner.repository_id) === repositoryId &&
				number(owner.head_repository_id) === headRepositoryId &&
				owner.head_sha === run.head_sha &&
				owner.head_branch === target,
			'foreign artifact owner.'
		);
		return number(row.id);
	});
	refuse(artifactIds[0] !== artifactIds[1], 'artifact identities overlap.');
	const final = await readApi(prefix + '/runs/' + runId);
	for (const key of [
		'id',
		'head_sha',
		'head_branch',
		'run_attempt',
		'workflow_id',
		'event',
		'status',
		'conclusion'
	])
		refuse(final[key] === run[key], 'producer changed during metadata admission.');
	const admitted = {
		schema_version: 1,
		repository: REPOSITORY,
		source_sha: run.head_sha,
		target,
		base_path: target === 'main' ? '' : '/dev',
		run_id: runId,
		run_attempt: attempt,
		build_artifact_id: artifactIds[0],
		testbuild_artifact_id: artifactIds[1]
	};
	await requireCurrentTarget(admitted, readApi);
	return admitted;
}

function validateAdmission(admitted) {
	closed(admitted, [
		'schema_version',
		'repository',
		'source_sha',
		'target',
		'base_path',
		'run_id',
		'run_attempt',
		'build_artifact_id',
		'testbuild_artifact_id'
	]);
	refuse(
		admitted.schema_version === 1 && admitted.repository === REPOSITORY,
		'unknown admission schema or repository.'
	);
	refuse(
		typeof admitted.source_sha === 'string' && /^[a-f0-9]{40}$/.test(admitted.source_sha),
		'invalid admitted source.'
	);
	for (const key of ['run_id', 'run_attempt', 'build_artifact_id', 'testbuild_artifact_id'])
		refuse(number(admitted[key]) === admitted[key], 'admitted IDs must be canonical strings.');
	refuse(
		admitted.build_artifact_id !== admitted.testbuild_artifact_id,
		'artifact identities overlap.'
	);
	resolveSiteTarget(admitted.target, admitted.base_path);
}

/** Refuse an old CI source using the target branch itself, never a latest-run guess. */
async function requireCurrentTarget(admitted, readApi) {
	validateAdmission(admitted);
	const reference = await readApi('/repos/' + REPOSITORY + '/git/ref/heads/' + admitted.target);
	refuse(
		reference.ref === 'refs/heads/' + admitted.target &&
			reference.object?.type === 'commit' &&
			reference.object.sha === admitted.source_sha,
		'target branch no longer names the admitted source.'
	);
}

/** Read only a bounded canonical producer admission before any subsequent Git operation. */
function readAdmission(file, artifact = require('./site-artifact.cjs')) {
	const bytes = artifact.fileHash(file, { maximumBytes: 65536, capture: true }).content;
	const admitted = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
	refuse(
		bytes.equals(Buffer.from(JSON.stringify(admitted, null, 2) + '\n')),
		'admission receipt must be canonical bytes.'
	);
	validateAdmission(admitted);
	return admitted;
}

/** Validate actual downloaded output without changing GitHub identity variables or rebuilding it. */
function verifyDownloaded(admitted, files, ports = {}) {
	validateAdmission(admitted);
	closed(files, ['siteDirectory', 'buildReceiptFile', 'testbuildReceiptFile', 'sourceRoot']);
	const artifact = ports.artifact || require('./site-artifact.cjs');
	const git =
		ports.git ||
		((args) =>
			execFileSync('git', args, {
				cwd: files.sourceRoot,
				encoding: 'utf8',
				stdio: ['ignore', 'pipe', 'pipe']
			}));
	refuse(
		git(['rev-parse', '--verify', 'HEAD^{commit}']).trim() === admitted.source_sha,
		'checked-out source differs from admitted CI.'
	);
	const context = {
		source_sha: admitted.source_sha,
		run_id: admitted.run_id,
		run_attempt: admitted.run_attempt,
		target: admitted.target,
		base_path: admitted.base_path,
		lock_sha256: artifact.fileHash(path.join(files.sourceRoot, 'package-lock.json')).sha256
	};
	const cname = artifact.fileHash(path.join(files.sourceRoot, 'static/CNAME'), {
		maximumBytes: 4096,
		capture: true
	}).content;
	const build = artifact.readReceipt(files.buildReceiptFile);
	const testbuild = artifact.readTestbuild(files.testbuildReceiptFile);
	const received = artifact.verify(files.siteDirectory, build, context, cname);
	const tested = artifact.verifyTestbuild(build, testbuild, context);
	return { ...admitted, lock_sha256: context.lock_sha256, received, tested };
}

/** Preserve the real event identity without changing environment variables to imitate its producer. */
function selectionFromEvent(env, event) {
	refuse(
		env.GITHUB_ACTIONS === 'true' && env.GITHUB_REPOSITORY === REPOSITORY,
		'CLI requires the actual repository workflow context.'
	);
	refuse(event.repository?.full_name === REPOSITORY, 'foreign event repository.');
	let trigger;
	if (env.GITHUB_EVENT_NAME === 'workflow_run') {
		refuse(
			event.workflow_run?.event === 'push' &&
				event.workflow_run.status === 'completed' &&
				event.workflow_run.conclusion === 'success',
			'event must be a completed successful push.'
		);
		trigger = {
			kind: 'workflow_run',
			action: event.action,
			run_id: event.workflow_run?.id,
			source_sha: event.workflow_run?.head_sha,
			branch: event.workflow_run?.head_branch
		};
	} else {
		refuse(env.GITHUB_EVENT_NAME === 'workflow_dispatch', 'unsupported deployment event.');
		trigger = { kind: 'manual', run_id: event.inputs?.run_id };
	}
	return { repository: env.GITHUB_REPOSITORY, trigger };
}

/** CLI admission remains read-only; verify receives downloaded bytes before any write-enabled job. */
async function main(argv = process.argv.slice(2), env = process.env, ports = {}) {
	refuse(
		(argv.length === 3 && argv[0] === 'admit') ||
			(argv.length === 6 && argv[0] === 'verify') ||
			(argv.length === 2 && argv[0] === 'current'),
		'usage: admit <event-file> <output-receipt> | verify <admission-file> <site-directory> <build-receipt> <testbuild-receipt> <source-root> | current <admission-file>'
	);
	refuse(
		env.GITHUB_ACTIONS === 'true' && env.GITHUB_REPOSITORY === REPOSITORY,
		'CLI requires the actual repository workflow context.'
	);
	const artifact = ports.artifact || require('./site-artifact.cjs');
	const readApi =
		ports.readApi ||
		((endpoint) =>
			JSON.parse(
				execFileSync('gh', ['api', endpoint], {
					encoding: 'utf8',
					maxBuffer: 4 * 1024 * 1024,
					stdio: ['ignore', 'pipe', 'pipe']
				})
			));
	if (argv[0] === 'admit') {
		const bytes = artifact.fileHash(argv[1], {
			maximumBytes: 2 * 1024 * 1024,
			capture: true
		}).content;
		const event = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
		const admitted = await admitProducer(selectionFromEvent(env, event), readApi);
		fs.writeFileSync(argv[2], JSON.stringify(admitted, null, 2) + '\n', {
			flag: 'wx',
			encoding: 'utf8'
		});
		refuse(
			typeof env.GITHUB_OUTPUT === 'string' && env.GITHUB_OUTPUT.length > 0,
			'actual output path is required.'
		);
		fs.appendFileSync(
			env.GITHUB_OUTPUT,
			Object.entries(admitted)
				.map(([key, value]) => key + '=' + value + '\n')
				.join(''),
			{ encoding: 'utf8' }
		);
		console.log(
			'Admitted exact source/run site artifacts: ' + admitted.run_id + ' / ' + admitted.target
		);
	} else {
		const admitted = readAdmission(argv[1], artifact);
		if (argv[0] === 'verify')
			verifyDownloaded(
				admitted,
				{
					siteDirectory: argv[2],
					buildReceiptFile: argv[3],
					testbuildReceiptFile: argv[4],
					sourceRoot: argv[5]
				},
				ports
			);
		await requireCurrentTarget(admitted, readApi);
		console.log(
			(argv[0] === 'verify'
				? 'Received exact source/run output and browser proof: '
				: 'Target branch still names admitted source: ') +
				admitted.run_id +
				' / ' +
				admitted.target
		);
	}
}

if (require.main === module)
	main().catch((error) => {
		console.error(error.message);
		process.exitCode = 1;
	});
module.exports = {
	collect,
	readCurrentRun,
	selectSiteJobs,
	admitProducer,
	verifyDownloaded,
	selectionFromEvent,
	readAdmission,
	requireCurrentTarget,
	main,
	REPOSITORY
};
