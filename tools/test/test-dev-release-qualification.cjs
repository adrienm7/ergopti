// tools/test/test-dev-release-qualification.cjs
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { spawnSync } = require('node:child_process');
const os = require('node:os');
const q = require('../ci/dev-release-qualification.cjs');
const { validateAhkSuiteManifest } = require('./validate-ahk-suite-manifest.cjs');
const { run } = require('./run-linux-window-switch-receipts.cjs');
const { verifyAggregate } = require('./linux-ci-evidence.cjs');
const ROOT = path.resolve(__dirname, '../..');
const MacStage = require('./fixtures/macos-stage-source.cjs');
const raw = fs.readFileSync(q.POLICY_PATH, 'utf8'),
	policy = q.parseClosedJson(raw);
const ctx = {
	github_actions: 'true',
	repository: policy.repository,
	event_name: policy.event_name,
	ref: policy.ref,
	release: true,
	prerelease: policy.prerelease,
	channel: policy.channel,
	tag: policy.tag,
	version: policy.version
};
const now = '2026-10-08T23:00:00Z',
	sha = 'a'.repeat(40);
const profile = q.authorizeQualificationProfile(policy.id, ctx, now);
assert.equal(q.resolveQualificationProfile(ctx, now), profile);
assert.throws(() => q.authorizeQualificationProfile('unknown', ctx, now));
for (const [key, value] of [
	['github_actions', ''],
	['event_name', 'pull_request'],
	['ref', 'refs/heads/main'],
	['repository', 'foreign/repo'],
	['release', false],
	['release', 'true'],
	['prerelease', 'false'],
	['channel', 'main'],
	['version', '0.0.0-dev.156'],
	['tag', 'v0.0.0-dev.156'],
	['version', '0.0.0-dev.158'],
	['tag', 'v0.0.0-dev.158']
]) {
	const bad = { ...ctx, [key]: value };
	assert.equal(q.resolveQualificationProfile(bad, now), null);
	assert.throws(() => q.authorizeQualificationProfile(policy.id, bad, now));
}
assert.equal(q.resolveQualificationProfile(ctx, policy.expires_at), null);
assert.throws(() => q.authorizeQualificationProfile(policy.id, ctx, policy.expires_at));
assert.throws(() => q.resolveQualificationProfile({ ...ctx, unknown: true }, now));
assert.throws(() => q.validatePolicy({ ...policy, unknown: true }));
assert.throws(() => q.validatePolicy({ ...policy, release: 1 }));
assert.throws(() => q.parseClosedJson('{"x":1,"x":2}'));
assert.throws(() => q.parseClosedJson('{"x":{"a":1,"a":2}}'));
assert.deepEqual(q.parseClosedJson('{"x":"escaped \\" quote"}'), { x: 'escaped " quote' });
assert.throws(() => q.validatePolicy({ ...policy, scopes: { ...policy.scopes, unknown: {} } }));
const duplicate = JSON.parse(raw);
duplicate.scopes['macos-brew-archive'].name = duplicate.scopes['windows-pac-full-url'].name;
assert.throws(() => q.validatePolicy(duplicate));
let calls = [];
const name = profile.scopes['windows-pac-full-url'].name;
const registry = ['head', name, 'trusted staging', 'tail'].map((name) => ({
	name,
	callback: () => {
		calls.push(name);
		return name;
	}
}));
for (const entry of q.selectRegistry(registry, null, 'windows-pac-full-url').selected)
	entry.callback();
assert.deepEqual(
	calls,
	registry.map((x) => x.name)
);
calls = [];
const selected = q.selectRegistry(registry, profile, 'windows-pac-full-url');
for (const entry of selected.selected) entry.callback();
assert.deepEqual(calls, ['head', 'trusted staging', 'tail']);
assert.deepEqual(
	selected.deferred.map((x) => x.name),
	[name]
);
assert.throws(() => q.selectRegistry([...registry, registry[1]], profile, 'windows-pac-full-url'));
assert.throws(() =>
	q.selectRegistry(
		registry.filter((x) => x.name !== name),
		profile,
		'windows-pac-full-url'
	)
);
assert.throws(() => q.selectRegistry(registry, profile, 'unknown'));
const failing = registry.map((x) => ({
	...x,
	callback: () => {
		if (x.name === 'tail') throw Error('other original failure');
	}
}));
assert.throws(() => {
	for (const row of q.selectRegistry(failing, profile, 'windows-pac-full-url').selected)
		row.callback();
}, /other original failure/);
const receipt = q.qualificationReceipt(profile, 'linux-window-receipts', { source_sha: sha });
assert.equal(receipt.qualified, false);
assert.equal(receipt.status, 'deferred');
q.validateQualificationReceipt(receipt, 'linux-window-receipts', sha, ctx, now);
assert.throws(() =>
	q.validateQualificationReceipt(
		{ ...receipt, qualified: true },
		'linux-window-receipts',
		sha,
		ctx,
		now
	)
);
assert.throws(() =>
	q.validateQualificationReceipt(receipt, 'linux-window-receipts', 'b'.repeat(40), ctx, now)
);
const execution = {
	complete: true,
	planned: 3,
	executed_count: 3,
	passed: 3,
	failed: 0,
	executed: [
		{ name: 'head', status: 'ok', duration_ms: 1 },
		{ name: 'trusted staging', status: 'ok', duration_ms: 2 },
		{ name: 'tail', status: 'ok', duration_ms: 3 }
	]
};
const selectedTap = [
	'1..3',
	'RUNNING 1/3 - head',
	'ok 1 - head',
	'# duration_ms 1 1',
	'RUNNING 2/3 - trusted staging',
	'ok 2 - trusted staging',
	'# duration_ms 2 2',
	'RUNNING 3/3 - tail',
	'ok 3 - tail',
	'# duration_ms 3 3',
	'# 3 passed, 0 failed.'
].join(String.fromCharCode(10));
const strictExecution = validateAhkSuiteManifest(selectedTap);
assert.equal(strictExecution.complete, true, JSON.stringify(strictExecution.errors));
assert.equal(
	validateAhkSuiteManifest(
		selectedTap.replace('ok 2 - trusted staging', 'ok 2 - trusted staging # SKIP')
	).complete,
	false
);
const tap =
	registry.map((x, i) => '# QUALIFICATION_ELIGIBLE ' + (i + 1) + ' - ' + x.name).join('\n') +
	'\n# DEFERRED qualification - ' +
	name;
const account = q.ahkQualificationManifest(tap, execution, profile, sha);
assert.equal(account.eligible_count, 4);
assert.equal(account.executed_count, 3);
assert.equal(account.deferred_count, 1);
assert.equal(account.passed, 3);
assert.equal(account.entries[1].status, 'deferred');
assert.equal(account.entries[1].duration_ms, null);
assert.equal(account.qualified, false);
assert.throws(() =>
	q.ahkQualificationManifest(
		tap.replace('trusted staging', 'missing test'),
		execution,
		profile,
		sha
	)
);
const e = {
	schema_version: 1,
	job: 'e2e-linux',
	sha,
	architecture: 'x64',
	distro: 'ubuntu',
	session: 'x11',
	interpreter: 'controlled',
	subjects: { family: 5 },
	qualification: receipt
};
const aggregate = {
	manifest: {
		schema_version: 1,
		jobs: {
			'e2e-linux': {
				classification: 'mandatory',
				subjects: { family: 5, 'window-switch-receipts': 34 }
			}
		}
	},
	needs: { 'e2e-linux': { result: 'success' } },
	evidence: [e],
	expectedSha: sha,
	qualificationContext: ctx,
	qualificationNow: now
};
assert.equal(verifyAggregate(aggregate).qualified, false);
assert.throws(() =>
	verifyAggregate({ ...aggregate, qualificationContext: { ...ctx, ref: 'refs/heads/main' } })
);
assert.throws(() =>
	verifyAggregate({ ...aggregate, evidence: [{ ...e, subjects: { family: 4 } }] })
);
assert.throws(() =>
	verifyAggregate({ ...aggregate, needs: { 'e2e-linux': { result: 'failure' } } })
);
assert.throws(() =>
	verifyAggregate({
		...aggregate,
		evidence: [{ ...e, subjects: { family: 5, 'window-switch-receipts': 34 } }]
	})
);
assert.throws(() =>
	verifyAggregate({ ...aggregate, evidence: [{ ...e, qualification: undefined }] })
);
const framework = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/windows/tests/test_framework.ahk'),
	'utf8'
);
assert(framework.includes('Profile := _AHK_QUALIFICATION_PROFILE'));
assert(!framework.includes('Profile := EnvGet("ERGOPTI_DEV_QUALIFICATION_PROFILE")'));
assert(framework.includes('Deferred.Length != 1'));
// Helper-only children load this complete library without production JSON.
// A static unresolved parser reference emits a load-time warning before any
// profile guard can run, and a hidden synchronous child can then block the suite.
assert(!/\bJsonParse\s*\(/.test(framework), 'helper-only framework has no static JSON dependency');
assert(framework.includes('if !(Parser is Func)'));
assert(framework.includes('if _TEST_QUALIFICATION_PARSER is Func'));
assert(framework.includes('_TEST_QUALIFICATION_PARSER := Parser'));
assert(framework.includes('Policy := Parser.Call(FileRead('));
const principal = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/windows/tests/run_all.ahk'),
	'utf8'
);
const parserInclude = principal.indexOf('#Include ../infra/json.ahk');
const parserRegistration = principal.indexOf('TestQualificationRegisterParser(JsonParse)');
assert(parserInclude >= 0 && parserRegistration > parserInclude);
assert.equal((principal.match(/^TestQualificationRegisterParser\(JsonParse\)$/gm) || []).length, 1);
assert(principal.includes('#Include unit/suite/test_qualification_parser_owner.ahk'));
const cliOwner = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-qualification-model-'));
try {
	const envFile = path.join(cliOwner, 'github-env.txt');
	const receiptFile = path.join(cliOwner, 'qualification.json');
	const result = spawnSync(
		process.execPath,
		[
			path.join(ROOT, 'tools/ci/dev-release-qualification.cjs'),
			'--scope',
			'macos-brew-archive',
			'--github-env',
			envFile,
			'--receipt',
			receiptFile
		],
		{
			encoding: 'utf8',
			env: {
				...process.env,
				GITHUB_ACTIONS: 'true',
				GITHUB_REPOSITORY: policy.repository,
				GITHUB_EVENT_NAME: 'push',
				GITHUB_REF: 'refs/heads/main',
				GITHUB_SHA: sha,
				ERGOPTI_DEV_RELEASE_RELEASE: 'true',
				ERGOPTI_DEV_RELEASE_PRERELEASE: 'true',
				ERGOPTI_DEV_RELEASE_CHANNEL: 'main',
				ERGOPTI_DEV_RELEASE_TAG: policy.tag,
				ERGOPTI_DEV_RELEASE_VERSION: policy.version,
				ERGOPTI_DEV_QUALIFICATION_PROFILE: policy.id
			}
		}
	);
	assert.equal(result.status, 0);
	assert.equal(fs.readFileSync(envFile, 'utf8'), 'ERGOPTI_DEV_QUALIFICATION_PROFILE=\n');
	const full = JSON.parse(fs.readFileSync(receiptFile, 'utf8'));
	assert.equal(full.profile_id, null);
	assert.equal(full.status, 'full');
	assert.equal(full.qualified, false);
} finally {
	for (const name of ['github-env.txt', 'qualification.json']) {
		const file = path.join(cliOwner, name);
		if (fs.existsSync(file)) fs.unlinkSync(file);
	}
	fs.rmdirSync(cliOwner);
}
const fixtures = [
	{ args: ['tests/hardware/run_native_fixture_family_receipts.py'], timeout: 1 },
	{
		args: [
			profile.scopes['linux-window-receipts'].path,
			...profile.scopes['linux-window-receipts'].args
		],
		timeout: 1
	}
];
async function simulate(context, status = 0, entries = fixtures, afterFamilySignal = null) {
	const spawned = [],
		logs = [],
		receipts = [];
	const signals = new EventEmitter();
	let pid = 100;
	const result = await run({
		platform: 'linux',
		...(context === undefined ? {} : { qualificationContext: context }),
		qualificationNow: now,
		fixtures: entries,
		signals,
		debts: new Map(),
		log: (x) => logs.push(x),
		error: (x) => logs.push(x),
		recordQualification: (r) => receipts.push(r),
		spawnChild: (_command, args) => {
			spawned.push(args.at(-1));
			const child = new EventEmitter();
			child.pid = ++pid;
			const pipe = new EventEmitter();
			child.stdio = [null, null, null, pipe];
			child.kill = () => true;
			const token = args[args.indexOf('--token') + 1];
			setImmediate(() => {
				pipe.emit(
					'data',
					Buffer.from(
						JSON.stringify({ version: 1, token, supervisor: child.pid, stage: 'ready' }) + '\n'
					)
				);
				pipe.emit(
					'data',
					Buffer.from(
						JSON.stringify({
							version: 1,
							token,
							supervisor: child.pid,
							stage: 'settled',
							status,
							acquired: 1,
							reaped: 1,
							closed: 1,
							namespace_absent: true
						}) + '\n'
					)
				);
				pipe.emit('end');
				child.emit('close', status, null);
				// Resolve the family receipt first; the awaiting fixture loop has not resumed.
				if (status === 0 && spawned.length === 1 && afterFamilySignal)
					signals.emit(afterFamilySignal);
			});
			return child;
		}
	});
	assert.equal(signals.listenerCount('SIGINT'), 0);
	assert.equal(signals.listenerCount('SIGTERM'), 0);
	return { result, spawned, logs, receipts };
}
(async () => {
	const prior = process.env.GITHUB_SHA;
	process.env.GITHUB_SHA = sha;
	try {
		const full = await simulate({ ...ctx, tag: 'v0.0.0-dev.158', version: '0.0.0-dev.158' });
		assert.equal(full.result, 0);
		assert.equal(full.spawned.length, 2);
		assert.equal(full.receipts.length, 0);

		const releaseEnvironment = {
			GITHUB_ACTIONS: ctx.github_actions,
			GITHUB_REPOSITORY: ctx.repository,
			GITHUB_EVENT_NAME: ctx.event_name,
			GITHUB_REF: ctx.ref,
			ERGOPTI_DEV_RELEASE_RELEASE: 'true',
			ERGOPTI_DEV_RELEASE_PRERELEASE: ctx.prerelease,
			ERGOPTI_DEV_RELEASE_CHANNEL: ctx.channel,
			ERGOPTI_DEV_RELEASE_TAG: ctx.tag,
			ERGOPTI_DEV_RELEASE_VERSION: ctx.version
		};
		const savedEnvironment = new Map(
			Object.keys(releaseEnvironment).map((key) => [key, process.env[key]])
		);
		const embeddedFixtures = [
			{ args: ['owned-launcher.py', 'owned-hang.lua', 'owned-fork.py'], timeout: 1 }
		];
		try {
			for (const override of [
				{},
				{ GITHUB_REF: 'refs/heads/main' },
				{ GITHUB_EVENT_NAME: 'pull_request' },
				{ ERGOPTI_DEV_RELEASE_TAG: 'v0.0.0-dev.158', ERGOPTI_DEV_RELEASE_VERSION: '0.0.0-dev.158' }
			]) {
				Object.assign(process.env, releaseEnvironment, override);
				const embedded = await simulate(undefined, 0, embeddedFixtures);
				assert.equal(embedded.result, 0);
				assert.equal(embedded.spawned.length, 1);
				assert.equal(embedded.receipts.length, 0);
				assert(!embedded.logs.some((line) => line.startsWith('[DEFERRED]')));
			}
			Object.assign(process.env, releaseEnvironment);
			await assert.rejects(
				() => simulate(q.environmentContext(), 0, embeddedFixtures),
				/Qualification fixture must match/
			);
			await assert.rejects(
				() => simulate({ ...ctx, unknown: true }),
				/Invalid closed qualification fields/
			);
		} finally {
			for (const [key, value] of savedEnvironment) {
				if (value === undefined) delete process.env[key];
				else process.env[key] = value;
			}
		}
		for (const explicitFull of [
			{ ...ctx, ref: 'refs/heads/main' },
			{ ...ctx, event_name: 'pull_request' }
		]) {
			const ordinary = await simulate(explicitFull);
			assert.equal(ordinary.result, 0);
			assert.equal(ordinary.spawned.length, 2);
			assert.equal(ordinary.receipts.length, 0);
		}
		const wrapperSource = fs.readFileSync(
			path.join(ROOT, 'tools/test/run-linux-window-switch-receipts.cjs'),
			'utf8'
		);
		assert.equal(
			wrapperSource.split('run({ qualificationContext: qualification.environmentContext() }).then(')
				.length,
			2,
			'principal CLI requests profile explicitly exactly once'
		);
		const deferred = await simulate(ctx);
		assert.equal(deferred.result, 0);
		assert.equal(deferred.spawned.length, 1);
		assert(deferred.spawned[0].includes('family'));
		assert.equal(deferred.receipts.length, 1);
		assert(!deferred.logs.some((x) => x.startsWith('[OK]')));
		const failed = await simulate(ctx, 7);
		assert.equal(failed.result, 7);
		assert.equal(failed.receipts.length, 0);
		await assert.rejects(() => simulate(ctx, 0, [...fixtures, fixtures[1]]));
		const requestedSignal = process.env.ERGOPTI_QUALIFICATION_MODEL_CANCEL;
		if (requestedSignal) assert(['SIGINT', 'SIGTERM'].includes(requestedSignal));
		for (const kind of requestedSignal ? [requestedSignal] : ['SIGINT', 'SIGTERM']) {
			const cancelled = await simulate(ctx, 0, fixtures, kind);
			assert.equal(
				cancelled.result,
				kind === 'SIGINT' ? 130 : 143,
				kind + ' after closed family must remain cancelled'
			);
			assert.equal(cancelled.spawned.length, 1);
			assert.equal(cancelled.receipts.length, 0);
			assert(
				!cancelled.logs.some((line) => line.startsWith('[OK]') || line.startsWith('[DEFERRED]'))
			);
		}
	} finally {
		if (prior === undefined) delete process.env.GITHUB_SHA;
		else process.env.GITHUB_SHA = prior;
	}
	console.log(
		'Dev qualification policy and actual selection/evidence wrappers: closed contexts, full defaults, exact deferrals and failure preservation passed. Native execution untested.'
	);
})().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});

// Full execution replaces the retired one-release all-suite bypass.
{
	const pipeline = require('./ci-pipeline.cjs');
	const workflows = {
		'ci.yml': [
			'prepare-common',
			'validate',
			'macos',
			'windows',
			'linux',
			'core',
			'publication-plan',
			'release'
		],
		'ci-common.yml': [
			'shared-validation',
			'common-e2e',
			'common-build',
			'common-testbuild',
			'common-unit-verdict'
		],
		'ci-windows.yml': ['test-ahk', 'e2e-ahk', 'package-windows', 'launch-windows', 'windows-ok'],
		'ci-macos.yml': ['test-hs', 'e2e-hs', 'package-macos', 'launch', 'macos-ok'],
		'ci-linux.yml': ['test-linux', 'e2e-linux', 'package-linux', 'install-linux', 'linux-ok']
	};
	const ordinaryConditions = {
		macos: "needs.validate.outputs.lane_macos == 'true'",
		windows: "needs.validate.outputs.lane_windows == 'true'",
		linux: "needs.validate.outputs.lane_linux == 'true'",
		'publication-plan': 'always() && !cancelled()',
		release: "github.event_name == 'push' && needs.publication-plan.outputs.release == 'true'",
		'common-unit-verdict': 'always()',
		'windows-ok': 'always()',
		'macos-ok': 'always()',
		'package-linux':
			"${{ !cancelled() && needs.e2e-linux.outputs.ci_unit_result == 'success' && (needs.e2e-linux.result == 'success' || (github.event_name == 'workflow_dispatch' && needs.e2e-linux.result == 'failure')) }}",
		'linux-ok': 'always()'
	};
	let jobs = 0,
		steps = 0;
	for (const [file, required] of Object.entries(workflows)) {
		const relative = '.github/workflows/' + file;
		const source = fs.readFileSync(path.join(ROOT, relative), 'utf8');
		assert.doesNotMatch(
			source,
			/fast_prerelease|ERGOPTI_FAST_PRERELEASE|--fast-action/,
			file + ': retired input, command and receipt wiring cannot authorize skips'
		);
		const actual = pipeline.jobsOfText(source, relative);
		assert.deepEqual(
			actual.map((job) => job.id),
			required,
			file + ': every job class is retained'
		);
		for (const job of actual) {
			jobs++;
			assert.notEqual(job.body.trim(), '', job.id + ': job evidence cannot be empty');
			assert.equal(
				pipeline.field(job.body, 'if'),
				ordinaryConditions[job.id] ?? null,
				job.id + ': only the original ordinary admission may select this full job'
			);
			assert.equal(
				pipeline.field(job.body, 'continue-on-error'),
				null,
				job.id + ': a failure cannot be converted into success'
			);
			for (const step of pipeline.steps(job.body)) {
				steps++;
				assert.doesNotMatch(
					step.body,
					/fast_prerelease|ERGOPTI_FAST_PRERELEASE|--fast-action/,
					job.id + ': every retained step uses its ordinary admission'
				);
			}
		}
	}
	const macosSource = fs.readFileSync(path.join(ROOT, '.github/workflows/ci-macos.yml'), 'utf8');
	for (const role of [
		'e2e-hs',
		'tooltip-canvas',
		'managed-ollama-native',
		'item36-native',
		'lease-silence-native',
		'launch',
		'cold-bootstrap-native'
	]) {
		const actualJob = pipeline
			.jobsOfText(macosSource, '.github/workflows/ci-macos.yml')
			.find((job) => job.id === MacStage.stage[role]);
		assert(actualJob, role + ': the actual matrix stage is retained');
		const retained = MacStage.selected(actualJob.body, role);
		assert(retained.length > 0, role + ': original role steps cannot disappear');
		for (const step of retained)
			assert.equal(pipeline.stepField(step.body, 'continue-on-error'), null);
		assert.throws(() =>
			MacStage.selected(
				actualJob.body.replaceAll(
					"env.MACOS_STAGE_ROLE == '" + role + "'",
					"env.MACOS_STAGE_ROLE == 'foreign'"
				),
				role
			)
		);
		assert.throws(() =>
			MacStage.selected(
				actualJob.body.replaceAll("steps.stage-admission.outcome == 'success'", 'true'),
				role
			)
		);
	}
	assert.equal(jobs - 1, 27);
	assert.equal(jobs, 28);
	assert(steps > 150, 'full step inventory cannot be vacuous');
	const rootSource = fs.readFileSync(path.join(ROOT, '.github/workflows/ci.yml'), 'utf8');
	const rootJobs = pipeline.jobsOfText(rootSource, '.github/workflows/ci.yml');
	const release = rootJobs.find((job) => job.id === 'release');
	assert(release, 'the real release owner is retained');
	assert.equal(
		pipeline.field(release.body, 'if'),
		"github.event_name == 'push' && needs.publication-plan.outputs.release == 'true'"
	);
	assert.deepEqual(pipeline.needsOf(release.body), ['publication-plan']);
	const publicationPlan = rootJobs.find((job) => job.id === 'publication-plan');
	assert(publicationPlan, 'the ordinary source-bound publication preflight is retained');
	assert.deepEqual(pipeline.needsOf(publicationPlan.body), ['macos', 'windows', 'linux', 'core']);
	const owner = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-retired-fast-cli-'));
	try {
		for (const event of ['push', 'pull_request', 'workflow_dispatch']) {
			for (const args of [
				['--fast-action', 'select'],
				['--fast-action', 'admit'],
				['--fast-action', 'receipt', '--lane', 'windows'],
				['--fast-action', 'receipt', '--lane', 'macos'],
				['--fast-action', 'receipt', '--lane', 'linux']
			]) {
				const result = spawnSync(
					process.execPath,
					[path.join(ROOT, 'tools/ci/dev-release-qualification.cjs'), ...args],
					{
						cwd: owner,
						encoding: 'utf8',
						env: {
							...process.env,
							GITHUB_ACTIONS: 'true',
							GITHUB_REPOSITORY: policy.repository,
							GITHUB_EVENT_NAME: event,
							GITHUB_REF: policy.ref,
							GITHUB_SHA: sha,
							ERGOPTI_DEV_RELEASE_RELEASE: 'true',
							ERGOPTI_DEV_RELEASE_PRERELEASE: 'true',
							ERGOPTI_DEV_RELEASE_CHANNEL: policy.channel,
							ERGOPTI_DEV_RELEASE_TAG: policy.tag,
							ERGOPTI_DEV_RELEASE_VERSION: policy.version,
							ERGOPTI_FAST_PRERELEASE: 'true',
							GITHUB_OUTPUT: path.join(owner, 'output.txt'),
							GITHUB_STEP_SUMMARY: path.join(owner, 'summary.txt')
						}
					}
				);
				assert.equal(result.error, undefined, 'the actual closed CLI executes');
				assert.equal(result.status, 1, event + ': the retired request is refused');
				assert.match(result.stderr, /^Invalid qualification command arguments\.\r?\n$/);
				assert.equal(result.stdout, '', 'no historical receipt is minted as present authority');
				assert.deepEqual(
					fs.readdirSync(owner),
					[],
					'refusal creates no output, receipt or summary'
				);
			}
		}
	} finally {
		fs.rmSync(owner, { recursive: true, force: true });
	}
	for (const name of ['fastPrerelease', 'validateFastPrerelease', 'fastPrereleaseReceipt'])
		assert.equal(
			Object.hasOwn(q, name),
			false,
			name + ': retired API cannot grant execution authority'
		);
	console.log(
		'Retired fast157: all27 job classes and retained steps use full defaults; actual obsolete CLI refuses without side effects.'
	);
}

// The proposed stable option is isolated from the original five-scope dev policy.
{
	const stable = q.parseClosedJson(fs.readFileSync(q.STABLE_POLICY_PATH, 'utf8'));
	const exact = {
		github_actions: 'true',
		repository: 'adrienm7/ergopti',
		event_name: 'push',
		ref: 'refs/heads/main',
		release: true,
		prerelease: 'false',
		channel: 'main',
		tag: 'v1.0.0',
		version: '1.0.0'
	};
	const before = new Date('2026-10-09T21:00:00Z');
	const accepted = q.authorizeQualificationProfile(stable.id, exact, before);
	assert.equal(
		q.authorizeQualificationProfile(stable.id, exact, new Date('2026-10-09T22:30:00Z')),
		accepted,
		'the renewed human v1 publication window admits the same thirteen scopes after midnight Paris'
	);
	assert.deepEqual(q.deferredScopes(accepted), [
		'macos-brew-archive',
		'macos-shortcuts-discovery',
		'macos-launch-appleevents',
		'macos-native-pac',
		'macos-native-http',
		'macos-stubbed-unit',
		'macos-stubbed-e2e',
		'windows-native-desktop',
		'linux-simultaneous-native',
		'linux-unit-suite',
		'linux-e2e-suite',
		'core-js-suite',
		'macos-native-model-receiving'
	]);
	assert.equal(
		q.resolveQualificationProfile(exact, before),
		null,
		'unscoped Windows/Linux callers stay full'
	);
	for (const scope of ['windows-pac-full-url', 'linux-window-receipts']) {
		assert.equal(q.resolveQualificationProfile(exact, before, scope), null);
		assert.throws(
			() => q.qualificationReceipt(accepted, scope, { source_sha: sha }),
			/Unknown qualification receipt scope/
		);
	}
	for (const scope of q.deferredScopes(accepted)) {
		assert.equal(q.resolveQualificationProfile(exact, before, scope), accepted);
		const receipt = q.qualificationReceipt(accepted, scope, { source_sha: sha });
		assert.equal(receipt.qualified, false);
		assert.equal(receipt.status, 'deferred');
		assert.equal(receipt.source_sha, sha);
		assert.equal(receipt.tag, 'v1.0.0');
		assert.equal(receipt.expires_at, '2026-10-10T02:00:00Z');
		q.validateQualificationReceipt(receipt, scope, sha, exact, before);
		assert.throws(() =>
			q.validateQualificationReceipt({ ...receipt, qualified: true }, scope, sha, exact, before)
		);
		assert.throws(() =>
			q.validateQualificationReceipt(receipt, scope, 'b'.repeat(40), exact, before)
		);
	}
	for (const runner of ['macos-15', 'macos-15-intel']) {
		for (const scenario of ['clean', 'karabiner_config']) {
			const row = q.launchQualificationReceipt(accepted, scenario, runner, { source_sha: sha });
			assert.equal(row.status, 'deferred');
			assert.equal(row.qualified, false);
			q.validateLaunchQualificationReceipt(row, scenario, runner, sha, exact, before);
		}
		assert.equal(
			q.launchQualificationReceipt(accepted, 'configured_symlink', runner, { source_sha: sha })
				.status,
			'full',
			'unrelated launch scenarios remain mandatory'
		);
	}
	for (const [field, value] of [
		['github_actions', 'false'],
		['repository', 'foreign/repo'],
		['event_name', 'workflow_dispatch'],
		['event_name', 'pull_request'],
		['ref', 'refs/heads/dev'],
		['release', false],
		['release', 'true'],
		['prerelease', 'true'],
		['channel', 'dev'],
		['tag', 'v1.0.1'],
		['version', '1.0.1']
	]) {
		assert.equal(q.stablePublicationProfile({ ...exact, [field]: value }, before), null);
		assert.throws(() =>
			q.authorizeQualificationProfile(stable.id, { ...exact, [field]: value }, before)
		);
	}
	assert.equal(
		q.authorizeQualificationProfile(stable.id, exact, new Date('2026-10-10T01:59:59.999Z')),
		accepted,
		'the proposed window admits the existing profile only before the exact cutoff'
	);
	assert.equal(
		q.stablePublicationProfile(exact, new Date('2026-10-10T02:00:00.001Z')),
		null,
		'the proposed window refuses one millisecond after expiry'
	);
	assert.equal(q.stablePublicationProfile(exact, new Date(stable.expires_at)), null);
	assert.throws(() =>
		q.stablePublicationNotice(stable.id, exact, sha, new Date(stable.expires_at))
	);
	assert.throws(() => q.stablePublicationNotice(stable.id, exact, '', before));
	assert.throws(() => q.stablePublicationNotice('foreign', exact, sha, before));
	const notice = q.stablePublicationNotice(stable.id, exact, sha, before);
	assert.match(notice, /NATIVE AND HARNESS QUALIFICATION DEFERRED \/ qualified:false/);
	assert.ok(notice.includes(sha));
	assert.ok(
		notice.includes(
			'Known macOS reports remain under investigation: Karabiner lease failures (including watchdog exit 73 and PONG/READY timeouts), and an active Homebrew upgrade leaving Hammerspoon running without ErgoptiPlus. This release does not claim those reports repaired.'
		)
	);
	assert.equal(
		q.deferredScopes(accepted).length,
		13,
		'only the ten explicitly approved added scopes extend the original three'
	);
	assert.ok(
		notice.includes(
			'Compilation, packaging, macOS signing, source and asset integrity, installation and all other tests remain required'
		)
	);
	assert.equal(
		q.stablePublicationNotice('', { ...exact, event_name: 'pull_request' }, '', before),
		''
	);
	for (const [field, value] of [
		['tag', 'v1.0.1'],
		['version', '1.0.1'],
		['expires_at', '2026-10-10T22:00:00Z'],
		['repository', 'foreign/repo']
	]) {
		assert.throws(
			() => q.validatePolicy({ ...stable, [field]: value }),
			/Invalid one-candidate stable boundary/
		);
	}
	const broadened = JSON.parse(JSON.stringify(stable));
	broadened.scopes['windows-pac-full-url'] = policy.scopes['windows-pac-full-url'];
	assert.throws(() => q.validatePolicy(broadened), /Invalid closed qualification fields/);
	console.log(
		'Draft stable v1.0.0: exact thirteen approved scopes, all unlisted work full, strict expiry and source-bound public limits PASS.'
	);
}

// Both fresh clock and artifact guards must immediately precede each external channel push.
{
	const workflow = fs.readFileSync(path.join(ROOT, '.github/workflows/ci.yml'), 'utf8');
	const guard = 'node tools/ci/dev-release-qualification.cjs --publication-admit >/dev/null';
	const signatureGuard = 'node tools/ci/windows-stable-signing.cjs --publication-admit >/dev/null';
	function requirePublicationGuard(source, push) {
		assert.equal(source.split(push).length, 2, 'the actual publication push must be unique');
		const prefix = source.slice(0, source.indexOf(push)).trimEnd();
		assert.equal(
			prefix
				.split(/\r?\n/)
				.slice(-2)
				.map((line) => line.trim())
				.join('\n'),
			guard + '\n' + signatureGuard,
			'fresh qualification admission must precede publication'
		);
	}
	for (const push of [
		'git -C "$worktree" push origin "HEAD:refs/heads/${branch}"',
		'git -C "$tap" push origin HEAD'
	]) {
		requirePublicationGuard(workflow, push);
		const actual = guard + '\n              ' + signatureGuard + '\n              ' + push;
		assert.ok(workflow.includes(actual), 'the inverse must withdraw the exact executed guard');
		assert.throws(
			() => requirePublicationGuard(workflow.replace(actual, push), push),
			/fresh qualification admission/
		);
		for (const replacement of [
			guard + '\n              ' + push,
			signatureGuard + '\n              ' + push,
			signatureGuard + '\n              ' + guard + '\n              ' + push
		]) {
			assert.throws(
				() => requirePublicationGuard(workflow.replace(actual, replacement), push),
				/fresh qualification admission/
			);
		}
	}
	console.log(
		'Stable publication: both actual external channel pushes retain fresh admission; guard omission refuses.'
	);
}

// Standing stable signature permission never defers any tests.
{
	const Signing = require('../ci/windows-stable-signing.cjs');
	const context = {
		github_actions: 'true',
		repository: 'adrienm7/ergopti',
		event_name: 'push',
		ref: 'refs/heads/main',
		release: true,
		prerelease: 'false',
		channel: 'main',
		tag: 'v1.0.1',
		version: '1.0.1'
	};
	const source = 'a'.repeat(40),
		hash = 'b'.repeat(64),
		clock = new Date('2026-10-11T09:00:00Z');
	const proposed = { ...Signing.POLICY, authorized: true };
	assert.equal(typeof Signing.POLICY.authorized, 'boolean');
	if (!Signing.POLICY.authorized)
		assert.throws(() => Signing.admit(context, source, source, clock));
	else Signing.admit(context, source, source, clock);
	Signing.admit(context, source, source, clock, proposed);
	Signing.admit(context, source, source, clock, proposed);
	Signing.admit(context, source, source, new Date('2027-10-11T07:00:00Z'), proposed);
	Signing.admit({ ...context, tag: 'v1.0.2', version: '1.0.2' }, source, source, clock, proposed);
	Signing.requireFreshUnsigned('true');
	for (const value of ['false', undefined, '', true]) {
		assert.throws(() => Signing.requireFreshUnsigned(value));
	}
	for (const patch of [
		{ github_actions: 'false' },
		{ event_name: 'workflow_dispatch' },
		{ event_name: 'pull_request' },
		{ ref: 'refs/heads/dev' },
		{ release: false },
		{ prerelease: 'true' },
		{ channel: 'dev' },
		{ tag: 'v1.0.0' },
		{ version: '1.0.0' },
		{ repository: 'foreign/repository' }
	]) {
		assert.throws(() => Signing.admit({ ...context, ...patch }, source, source, clock, proposed));
	}
	assert.throws(() => Signing.admit(context, source, 'c'.repeat(40), clock, proposed));
	assert.throws(() => Signing.admit(context, 'A'.repeat(40), 'A'.repeat(40), clock, proposed));
	Signing.admit(context, source, source, new Date('2026-10-11T07:00:00Z'), proposed);
	assert.throws(() => Signing.admit(context, source, source, new Date('invalid'), proposed));
	assert.throws(() =>
		Signing.admit(context, source, source, clock, { ...Signing.POLICY, authorized: false })
	);
	const value = Signing.receipt(context, source, source, hash, clock, proposed);
	Signing.validateReceipt(value, context, source, source, hash, clock, proposed);
	for (const patch of [
		{ signature: 'Valid' },
		{ qualified: true },
		{ tests: 'deferred' },
		{ source_sha: 'c'.repeat(40) },
		{ sha256: 'd'.repeat(64) },
		{ tag: 'v1.0.2' },
		{ artifact: 'foreign.exe' },
		{ extra: true }
	]) {
		assert.throws(() =>
			Signing.validateReceipt(
				{ ...value, ...patch },
				context,
				source,
				source,
				hash,
				clock,
				proposed
			)
		);
	}
	assert(Signing.notice(source, context.tag).includes('UNSIGNED / qualified:false'));
	assert(Signing.notice(source, context.tag).includes('SignPath Foundation'));
	assert.equal(value.tests, 'mandatory');
	assert(Signing.notice(source, context.tag).includes('v1.0.1/windows-signing-qualification.json'));
	assert(Signing.notice(source, context.tag).includes('All tests, build, package'));
	for (const version of [
		'1.0.2-dev.1',
		'01.0.2',
		'1.0',
		'',
		undefined,
		{ toString: () => '1.0.2' }
	]) {
		assert.throws(() =>
			Signing.admit({ ...context, tag: 'v' + version, version }, source, source, clock, proposed)
		);
	}
	assert(Signing.notice(source, 'v1.0.2').includes('v1.0.2/windows-signing-qualification.json'));
	assert.throws(() => Signing.notice(source, 'v1.0.2-dev.1'));
	assert.throws(() => Signing.validatePolicy({ ...proposed, expires_at: '2027-01-01T00:00:00Z' }));
	assert.throws(() =>
		Signing.admit(context, source, source, new Date('2026-10-10T23:59:59.999Z'), proposed)
	);
	console.log('[OK] standing unsigned signature permission and source-bound receipt guards.');
}

// Suite deferrals carry empty execution counts and cannot waive package/install evidence.
{
	const stable = JSON.parse(fs.readFileSync(q.STABLE_POLICY_PATH, 'utf8'));
	const exact = {
		...ctx,
		ref: stable.ref,
		event_name: stable.event_name,
		prerelease: stable.prerelease,
		channel: stable.channel,
		tag: stable.tag,
		version: stable.version
	};
	const time = '2026-10-09T21:00:00Z';
	const admitted = q.authorizeQualificationProfile(stable.id, exact, time);
	const manifest = { schema_version: 1, jobs: {} };
	const needs = {};
	const evidence = [];
	for (const job of ['test-linux', 'e2e-linux', 'package-linux', 'install-linux']) {
		manifest.jobs[job] = { classification: 'mandatory', subjects: { assertions: 1 } };
		needs[job] = { result: 'success' };
		const doc = {
			schema_version: 1,
			job,
			sha,
			architecture: 'amd64',
			distro: 'ubuntu',
			session: 'fixture',
			interpreter: 'fixture',
			subjects: { assertions: 1 }
		};
		if (job === 'test-linux' || job === 'e2e-linux') {
			doc.subjects = {};
			doc.suite_qualification = q.qualificationReceipt(
				admitted,
				job === 'test-linux' ? 'linux-unit-suite' : 'linux-e2e-suite',
				{ source_sha: sha }
			);
		}
		evidence.push(doc);
	}
	const args = {
		manifest,
		needs,
		evidence,
		expectedSha: sha,
		qualificationContext: exact,
		qualificationNow: time
	};
	assert.equal(
		verifyAggregate(args).qualified,
		false,
		'actual aggregate reports deferred, never qualified'
	);
	for (const value of [1, 'empty', []]) {
		const bad = structuredClone(evidence);
		bad[0].subjects = value;
		assert.throws(
			() => verifyAggregate({ ...args, evidence: bad }),
			'malformed empty subjects refuse'
		);
	}
	const nonempty = structuredClone(evidence);
	nonempty[0].subjects = { assertions: 1 };
	assert.throws(() => verifyAggregate({ ...args, evidence: nonempty }));
	const foreign = structuredClone(evidence);
	foreign[0].suite_qualification.source_sha = 'b'.repeat(40);
	assert.throws(() => verifyAggregate({ ...args, evidence: foreign }));
	assert.throws(() => verifyAggregate({ ...args, qualificationNow: stable.expires_at }));
	for (const job of ['package-linux', 'install-linux']) {
		assert.throws(
			() => verifyAggregate({ ...args, evidence: evidence.filter((doc) => doc.job !== job) }),
			'package/install evidence remains mandatory'
		);
		assert.throws(
			() => verifyAggregate({ ...args, needs: { ...needs, [job]: { result: 'cancelled' } } }),
			'package/install cancellation refuses'
		);
	}
	console.log(
		'Linux deferred suite envelopes: actual aggregate plus ten malformed/source/expiry/package/install refusals PASS.'
	);
	// A sharded E2E matrix defers once per row: the same run-wide receipt, every row present.
	const rows = ['first-row', 'second-row'];
	const shardedManifest = structuredClone(manifest);
	shardedManifest.jobs['e2e-linux'].shards = rows;
	const e2eDeferral = evidence.find((doc) => doc.job === 'e2e-linux');
	const sharded = [
		...evidence.filter((doc) => doc.job !== 'e2e-linux'),
		...rows.map((shard) => ({ ...structuredClone(e2eDeferral), shard }))
	];
	const shardedArgs = { ...args, manifest: shardedManifest, evidence: sharded };
	assert.equal(verifyAggregate(shardedArgs).qualified, false, 'every deferred row is admitted');
	assert.throws(
		() =>
			verifyAggregate({
				...shardedArgs,
				evidence: sharded.filter((doc) => doc.shard !== 'second-row')
			}),
		/no evidence from shard second-row/,
		'a deferred matrix still needs every row'
	);
	const mixed = structuredClone(sharded);
	const executed = mixed.find((doc) => doc.shard === 'second-row');
	delete executed.suite_qualification;
	executed.subjects = { assertions: 1 };
	assert.throws(
		() => verifyAggregate({ ...shardedArgs, evidence: mixed }),
		/Duplicate|duplicate/,
		'a row cannot claim execution of a deferred suite'
	);
	assert.throws(
		() => verifyAggregate({ ...args, evidence: [...evidence, structuredClone(e2eDeferral)] }),
		/Duplicate deferred suite evidence/,
		'an unsharded job still refuses a repeated deferral'
	);
}

// The separately approved v1.0.2 profile cannot waive an unlisted test or installation.
{
	const approved = q.parseClosedJson(fs.readFileSync(q.STABLE_V102_POLICY_PATH, 'utf8'));
	const context = {
		github_actions: 'true',
		repository: 'adrienm7/ergopti',
		event_name: 'push',
		ref: 'refs/heads/main',
		release: true,
		prerelease: 'false',
		channel: 'main',
		tag: 'v1.0.2',
		version: '1.0.2'
	};
	const clock = '2026-10-17T14:00:00Z';
	const scopes = [
		'macos-native-pac',
		'macos-native-http',
		'macos-brew-archive',
		'macos-native-model-receiving',
		'macos-shortcuts-discovery',
		'macos-launch-appleevents',
		'macos-owned-runtime'
	];
	const selected = q.authorizeQualificationProfile(q.STABLE_V102_PROFILE_ID, context, clock);
	assert.deepEqual(q.deferredScopes(selected), scopes);
	assert.equal(q.stablePublicationProfile(context, clock), selected);
	for (const scope of scopes) {
		assert.equal(q.resolveQualificationProfile(context, clock, scope), selected);
		const receipt = q.qualificationReceipt(selected, scope, {
			source_sha: sha
		});
		assert.equal(q.scopeDisposition(receipt, scope, sha, context, clock), 'deferred');
		for (const patch of [
			{ qualified: true },
			{ source_sha: 'b'.repeat(40) },
			{ version: '1.0.3' },
			{ expires_at: '2026-10-13T07:00:00Z' },
			{ extra: true }
		])
			assert.throws(() => q.scopeDisposition({ ...receipt, ...patch }, scope, sha, context, clock));
		assert.throws(() => q.scopeDisposition(receipt, scope, sha, context, approved.expires_at));
	}
	for (const [key, value] of [
		['github_actions', 'false'],
		['repository', 'foreign/repo'],
		['event_name', 'pull_request'],
		['event_name', 'workflow_dispatch'],
		['ref', 'refs/heads/dev'],
		['release', false],
		['prerelease', 'true'],
		['channel', 'dev'],
		['tag', 'v1.0.3'],
		['version', '1.0.3']
	]) {
		const foreign = { ...context, [key]: value };
		for (const scope of scopes)
			assert.equal(q.resolveQualificationProfile(foreign, clock, scope), null);
		assert.throws(() => q.authorizeQualificationProfile(approved.id, foreign, clock));
	}
	assert.equal(q.resolveQualificationProfile(context, approved.expires_at, scopes[0]), null);
	for (const scope of [
		'windows-pac-full-url',
		'core-js-suite',
		'linux-unit-suite',
		'linux-e2e-suite',
		'macos-stubbed-unit',
		'macos-stubbed-e2e',
		'macos-launch-appleevents-unadmitted'
	]) {
		assert.equal(q.resolveQualificationProfile(context, clock, scope), null);
		assert.throws(() => q.qualificationReceipt(selected, scope, { source_sha: sha }));
	}
	assert.throws(() =>
		q.selectRegistry(
			[{ name: 'native Windows PAC', callback() {} }],
			selected,
			'windows-pac-full-url'
		)
	);
	const broad = structuredClone(approved);
	broad.scopes['macos-native-pac'].methods.ManagedHTTPWorkerTests = [
		'testWorkerMustRemainMandatory'
	];
	assert.throws(() => q.validateStableV102Policy(broad));
	const sibling = structuredClone(approved);
	sibling.scopes['macos-brew-archive'].name = 'testOrdinaryArchiveInstall';
	assert.throws(() => q.validateStableV102Policy(sibling));
	const extraScope = structuredClone(approved);
	extraScope.scopes['core-js-suite'] = approved.scopes['macos-native-http'];
	assert.throws(() => q.validateStableV102Policy(extraScope));
	// Earlier consent and a pending proposal cannot authorize the newly added model scope.
	for (const patch of [
		{ authorization_quote: 'oui' },
		{ authorization_quote: 'PENDING_EXPLICIT_HUMAN_APPROVAL' },
		{ id: 'stable-v1-0-1-20261010-three-macos-native-scopes' },
		{ expires_at: '2099-10-12T07:00:00Z' }
	])
		assert.throws(() => q.validateStableV102Policy({ ...approved, ...patch }));
	const model = approved.scopes['macos-native-model-receiving'];
	assert.deepEqual(model.architectures, ['arm64', 'amd64']);
	assert.deepEqual(model.profiles, ['pac-inline', 'pac-url', 'explicit-proxy']);
	for (const patch of [
		{ architectures: ['arm64'] },
		{ architectures: ['arm64', 'amd64', 'foreign'] },
		{ profiles: ['pac-inline', 'pac-url'] },
		{ profiles: ['pac-inline', 'pac-url', 'explicit-proxy', 'foreign'] },
		{ args: ['managed-ollama-native', 'Qualify actual native PAC and WPAD XCTest controls'] },
		{ command: 'foreign' }
	]) {
		const altered = structuredClone(approved);
		Object.assign(altered.scopes['macos-native-model-receiving'], patch);
		assert.throws(() => q.validateStableV102Policy(altered));
	}
	const shortcuts = approved.scopes['macos-shortcuts-discovery'];
	assert.deepEqual(
		{ kind: shortcuts.kind, path: shortcuts.path, args: shortcuts.args },
		{ kind: 'command', path: 'tools/diagnostics/apple_shortcuts_probe/run_probe.py', args: [] }
	);
	for (const patch of [
		{ path: 'tools/diagnostics/apple_shortcuts_probe/test_probe.py' },
		{ args: ['--foreign'] },
		{ command: 'foreign' },
		{ kind: 'swift_test_file' }
	]) {
		const altered = structuredClone(approved);
		Object.assign(altered.scopes['macos-shortcuts-discovery'], patch);
		assert.throws(() => q.validateStableV102Policy(altered));
	}
	const missingShortcuts = structuredClone(approved);
	delete missingShortcuts.scopes['macos-shortcuts-discovery'];
	assert.throws(() => q.validateStableV102Policy(missingShortcuts));
	const launchMatrix = approved.scopes['macos-launch-appleevents'];
	assert.deepEqual(launchMatrix.scenarios, ['clean', 'karabiner_config']);
	assert.deepEqual(launchMatrix.runners, ['macos-15', 'macos-15-intel']);
	for (const patch of [
		{ scenarios: ['clean'] },
		{ scenarios: ['clean', 'karabiner_config', 'foreign'] },
		{ runners: ['macos-15'] },
		{ runners: ['macos-15', 'macos-15-intel', 'foreign'] },
		{ path: 'tools/diagnostics/foreign.py' },
		{ args: [] }
	]) {
		const altered = structuredClone(approved);
		Object.assign(altered.scopes['macos-launch-appleevents'], patch);
		assert.throws(() => q.validateStableV102Policy(altered));
	}
	for (const scenario of launchMatrix.scenarios) {
		for (const runner of launchMatrix.runners) {
			const receipt = q.launchQualificationReceipt(selected, scenario, runner, { source_sha: sha });
			assert.equal(receipt.qualified, false);
			assert.equal(receipt.status, 'deferred');
			assert.equal(
				q.validateLaunchQualificationReceipt(receipt, scenario, runner, sha, context, clock),
				receipt
			);
			for (const patch of [
				{ source_sha: 'b'.repeat(40) },
				{ qualified: true },
				{ scenario: 'foreign' },
				{ runner: 'foreign' }
			])
				assert.throws(() =>
					q.validateLaunchQualificationReceipt(
						{ ...receipt, ...patch },
						scenario,
						runner,
						sha,
						context,
						clock
					)
				);
		}
	}
	assert.equal(
		q.launchQualificationReceipt(selected, 'other_scenario', 'macos-15', { source_sha: sha })
			.status,
		'full'
	);
	assert.throws(() =>
		q.launchQualificationReceipt(selected, 'clean', 'foreign', { source_sha: sha })
	);
	assert.deepEqual(q.STABLE_V102_PAC_METHODS, approved.scopes['macos-native-pac'].methods);
	assert.deepEqual(q.STABLE_V102_BREW_METHODS, {
		HomebrewArchiveAcceptanceTests: [approved.scopes['macos-brew-archive'].name]
	});
	assert(Object.isFrozen(q.STABLE_V102_PAC_METHODS.ManagedHTTPWireTests));
	assert(Object.isFrozen(q.STABLE_V102_BREW_METHODS.HomebrewArchiveAcceptanceTests));
	const notice = q.stablePublicationNotice(approved.id, context, sha, clock);
	for (const literal of [
		'DEFERRED / qualified:false',
		'Native Apple Shortcuts catalogue discovery remains unqualified',
		'v1.0.2',
		'Worker12',
		'arm64/amd64 across pac-inline, pac-url and explicit-proxy',
		'portable model controls',
		'owned-process/client-only',
		'ordinary verified archive installation/launch',
		'Native Homebrew ZIP installation, XZ upgrade and refusal preservation remain unqualified'
	])
		assert(notice.includes(literal));
	assert(notice.includes(sha));
	console.log(
		'[OK] v1.0.2 exact six scopes, mandatory siblings, context/expiry/source/metadata refusals.'
	);

	const owner = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-v101-qualification-'));
	try {
		const files = [
			['macos-native-pac', 'arm64'],
			['macos-native-pac', 'amd64'],
			['macos-native-http', 'arm64'],
			['macos-native-http', 'amd64'],
			['macos-brew-archive', ''],
			['macos-native-model-receiving', 'arm64'],
			['macos-native-model-receiving', 'amd64'],
			['macos-shortcuts-discovery', '']
		].map(([scope, architecture]) => {
			const file = path.join(
				owner,
				'stable-' + scope + (architecture ? '-' + architecture : '') + '.json'
			);
			const raw = JSON.stringify(q.qualificationReceipt(selected, scope, { source_sha: sha }));
			fs.writeFileSync(file, raw);
			return { file, raw };
		});
		for (const scenario of launchMatrix.scenarios) {
			for (const runner of launchMatrix.runners) {
				const file = path.join(
					owner,
					'stable-macos-launch-appleevents-' + scenario + '-' + runner + '.json'
				);
				const raw = JSON.stringify(
					q.launchQualificationReceipt(selected, scenario, runner, { source_sha: sha })
				);
				fs.writeFileSync(file, raw);
				files.push({ file, raw });
			}
		}
		assert.equal(files.length, 12);
		q.admitCommandReceipts(owner, context, sha, clock);
		for (const entry of files) {
			fs.unlinkSync(entry.file);
			assert.throws(() => q.admitCommandReceipts(owner, context, sha, clock));
			fs.writeFileSync(entry.file, entry.raw);
			const forged = JSON.parse(entry.raw);
			forged.source_sha = 'b'.repeat(40);
			fs.writeFileSync(entry.file, JSON.stringify(forged));
			assert.throws(() => q.admitCommandReceipts(owner, context, sha, clock));
			fs.writeFileSync(entry.file, entry.raw);
		}
		q.admitCommandReceipts(owner, context, sha, clock);
		assert.throws(() => q.admitCommandReceipts(owner, context, sha, approved.expires_at));
		console.log(
			'[OK] all twelve actual publication receipt filenames required; every missing/foreign source refuses.'
		);

		// Run the real CLI entry with a fixed test clock, retaining all source and file operations.
		const vm = require('node:vm');
		const helper = path.resolve(
			path.dirname(q.STABLE_V102_POLICY_PATH),
			'../../tools/ci/dev-release-qualification.cjs'
		);
		const source = fs.readFileSync(helper, 'utf8');
		const env = {
			GITHUB_ACTIONS: 'true',
			GITHUB_REPOSITORY: context.repository,
			GITHUB_EVENT_NAME: 'push',
			GITHUB_REF: context.ref,
			GITHUB_SHA: sha,
			ERGOPTI_DEV_RELEASE_RELEASE: 'true',
			ERGOPTI_DEV_RELEASE_PRERELEASE: 'false',
			ERGOPTI_DEV_RELEASE_CHANNEL: 'main',
			ERGOPTI_DEV_RELEASE_TAG: context.tag,
			ERGOPTI_DEV_RELEASE_VERSION: context.version
		};
		function invoke(args, policyOverride) {
			const output = [];
			const effects = Object.create(fs);
			effects.readFileSync = (file, ...rest) =>
				policyOverride && path.resolve(file) === q.STABLE_V102_POLICY_PATH
					? JSON.stringify(policyOverride)
					: fs.readFileSync(file, ...rest);
			const sandbox = {
				__dirname: path.dirname(helper),
				module: { exports: {} },
				require: (name) => (name === 'node:fs' ? effects : require(name)),
				process: { argv: ['node', helper, ...args], env },
				console: {
					log: (value) => output.push(value),
					error: (value) => output.push(value)
				},
				Date: class extends Date {
					constructor(...args) {
						super(...(args.length ? args : [clock]));
					}
				}
			};
			vm.runInNewContext(source + '\nmain(process.argv.slice(2));', sandbox, {
				filename: helper
			});
			return output;
		}
		const receiptPath = path.join(owner, 'cli-brew.json');
		const environmentPath = path.join(owner, 'github-env.txt');
		invoke([
			'--scope',
			'macos-brew-archive',
			'--receipt',
			receiptPath,
			'--github-env',
			environmentPath
		]);
		assert.equal(fs.readFileSync(environmentPath, 'utf8'), 'ERGOPTI_DEV_QUALIFICATION_PROFILE=\n');
		assert.equal(
			q.scopeDisposition(
				JSON.parse(fs.readFileSync(receiptPath, 'utf8')),
				'macos-brew-archive',
				sha,
				context,
				clock
			),
			'deferred'
		);
		assert.deepEqual(
			invoke(['--scope', 'macos-brew-archive', '--validate-scope-receipt-profile', receiptPath]),
			[approved.id]
		);
		const bad = JSON.parse(fs.readFileSync(receiptPath, 'utf8'));
		bad.qualified = true;
		fs.writeFileSync(receiptPath, JSON.stringify(bad));
		assert.throws(() =>
			invoke(['--scope', 'macos-brew-archive', '--validate-scope-receipt-profile', receiptPath])
		);
		const inactive = structuredClone(approved);
		inactive.authorized = false;
		const fullPath = path.join(owner, 'inactive.json');
		invoke(['--scope', 'macos-native-pac', '--receipt', fullPath], inactive);
		assert.equal(JSON.parse(fs.readFileSync(fullPath, 'utf8')).status, 'full');
		assert.deepEqual(
			invoke(
				['--scope', 'macos-native-pac', '--validate-scope-receipt-profile', fullPath],
				inactive
			),
			['']
		);
		console.log(
			'[OK] real CLI preserves empty Package.swift selector, fresh profile validation and inactive full behavior.'
		);
	} finally {
		fs.rmSync(owner, { recursive: true, force: true });
	}
}

// The v1.0.3 profile defers any subset of five scopes; PAC and HTTP stay mandatory.
{
	const V103 = require('./fixtures/stable-v103-profile.cjs');
	const approved = q.parseClosedJson(fs.readFileSync(q.STABLE_V103_POLICY_PATH, 'utf8'));
	const context = {
		github_actions: 'true',
		repository: 'adrienm7/ergopti',
		event_name: 'push',
		ref: 'refs/heads/main',
		release: true,
		prerelease: 'false',
		channel: 'main',
		tag: 'v1.0.3',
		version: '1.0.3'
	};
	const clock = '2026-10-19T10:00:00Z';
	const deferrable = [
		'macos-brew-archive',
		'macos-native-model-receiving',
		'macos-shortcuts-discovery',
		'macos-launch-appleevents',
		'macos-owned-runtime'
	];
	assert.deepEqual([...q.STABLE_V103_DEFERRABLE_SCOPE_IDS], deferrable);
	assert.equal(approved.id, q.STABLE_V103_PROFILE_ID);
	assert.equal(approved.id, 'stable-v1-0-3-20261018-macos-native-scopes');
	assert.equal(approved.authorization_quote, 'v1.0.3 depuis dev complet');
	assert.deepEqual(Object.keys(approved.scopes), [...q.STABLE_V103_SCOPE_IDS]);
	if (approved.scopes['macos-owned-runtime'])
		assert.deepEqual(
			approved.scopes['macos-owned-runtime'].methods,
			JSON.parse(JSON.stringify(q.STABLE_V102_OWNED_RUNTIME_METHODS))
		);
	q.validateStableV103Policy(approved);

	// Each boundary field refuses a foreign value.
	for (const patch of [
		{ id: q.STABLE_V102_PROFILE_ID },
		{ id: 'stable-v1-0-3-20261018-seven-macos-native-scopes' },
		{ authorization_quote: 'Différer pour 1.0.2 (Recommandé)' },
		{ authorized: 'true' },
		{ tag: 'v1.0.2' },
		{ tag: 'v1.0.4' },
		{ version: '1.0.2' },
		{ version: '1.0.3-dev.1' },
		{ expires_at: '2026-10-20T22:00:00Z' },
		{ expires_at: '2026-10-26T22:00:00Z' },
		{ ref: 'refs/heads/dev' },
		{ channel: 'dev' },
		{ prerelease: 'true' },
		{ event_name: 'workflow_dispatch' },
		{ release: false },
		{ repository: 'foreign/ergopti' },
		{ authorization_note: 'two\nlines' },
		{ extra: true }
	])
		assert.throws(() => q.validateStableV103Policy({ ...approved, ...patch }), Error, patch);
	const missingField = structuredClone(approved);
	delete missingField.authorization_note;
	assert.throws(() => q.validateStableV103Policy(missingField));

	// Any subset of the five scopes is accepted, in the declared order only.
	for (const subset of V103.subsets(deferrable)) {
		const policy = V103.policyFor(q, subset);
		q.validateStableV103Policy(policy, subset);
		if (subset.length > 1)
			assert.throws(() => q.validateStableV103Policy(policy, [...subset].reverse()), /order/);
		for (const foreign of ['macos-native-pac', 'macos-native-http', 'core-js-suite', 'foreign']) {
			const extra = structuredClone(policy);
			extra.scopes[foreign] = policy.scopes[subset[0]];
			assert.throws(() => q.validateStableV103Policy(extra, subset), Error, foreign);
			assert.throws(() => q.validateStableV103Policy(extra, [...subset, foreign]), Error, foreign);
		}
		const missing = structuredClone(policy);
		delete missing.scopes[subset[0]];
		assert.throws(() => q.validateStableV103Policy(missing, subset));
	}
	assert.throws(() => q.validateStableV103Policy({ ...approved, scopes: {} }, []));
	assert.throws(() =>
		q.validateStableV103Policy(approved, [...q.STABLE_V103_SCOPE_IDS, q.STABLE_V103_SCOPE_IDS[0]])
	);

	// Exact methods, matrices and commands cannot widen or narrow.
	const full = V103.policyFor(q, deferrable);
	for (const [scope, patch] of [
		['macos-brew-archive', { name: 'testOrdinaryArchiveInstall' }],
		['macos-brew-archive', { path: 'Tests/ErgoptiPlusTests/Foreign.swift' }],
		['macos-native-model-receiving', { architectures: ['arm64'] }],
		['macos-native-model-receiving', { profiles: ['pac-inline', 'pac-url'] }],
		['macos-shortcuts-discovery', { args: ['--foreign'] }],
		['macos-launch-appleevents', { scenarios: ['clean'] }],
		['macos-launch-appleevents', { runners: ['macos-15'] }],
		['macos-owned-runtime', { path: 'Tests' }],
		['macos-owned-runtime', { reason: '' }]
	]) {
		const altered = structuredClone(full);
		Object.assign(altered.scopes[scope], patch);
		assert.throws(() => q.validateStableV103Policy(altered, deferrable), Error, scope);
	}
	for (const mutate of [
		(methods) => methods.OwnedRuntimeNamespaceCloseOrderTests.pop(),
		(methods) => methods.OwnedRuntimeNamespaceCloseOrderTests.push('testForeign'),
		(methods) => (methods.ManagedHTTPWorkerTests = ['testWorkerMustRemainMandatory']),
		(methods) => delete methods.OwnedRuntimeMaintenanceJournalAdmissionTests
	]) {
		const altered = structuredClone(full);
		mutate(altered.scopes['macos-owned-runtime'].methods);
		assert.throws(() => q.validateStableV103Policy(altered, deferrable));
	}

	// The shipped profile owns exactly its listed scopes for the v1.0.3 main push only.
	const selected = q.authorizeQualificationProfile(approved.id, context, clock);
	assert.equal(q.stablePublicationProfile(context, clock), selected);
	assert.deepEqual(q.deferredScopes(selected), [...q.STABLE_V103_SCOPE_IDS]);
	for (const scope of [...deferrable, 'macos-native-pac', 'macos-native-http', 'core-js-suite'])
		assert.equal(
			q.resolveQualificationProfile(context, clock, scope),
			q.STABLE_V103_SCOPE_IDS.includes(scope) ? selected : null,
			scope
		);
	for (const [key, value] of [
		['github_actions', 'false'],
		['repository', 'foreign/repo'],
		['event_name', 'workflow_dispatch'],
		['ref', 'refs/heads/dev'],
		['release', false],
		['prerelease', 'true'],
		['channel', 'dev'],
		['tag', 'v1.0.2'],
		['tag', 'v1.0.4'],
		['version', '1.0.2'],
		['version', '1.0.4']
	]) {
		const foreign = { ...context, [key]: value };
		assert.equal(q.stablePublicationProfile(foreign, clock), null, key);
		for (const scope of deferrable)
			assert.notEqual(q.resolveQualificationProfile(foreign, clock, scope), selected);
		assert.throws(() => q.authorizeQualificationProfile(approved.id, foreign, clock));
	}
	assert.equal(q.stablePublicationProfile(context, approved.expires_at), null);
	assert.throws(() => q.authorizeQualificationProfile(approved.id, context, approved.expires_at));
	// The v1.0.2 profile never covers v1.0.3, nor v1.0.3 the v1.0.2 publication.
	assert.throws(() => q.authorizeQualificationProfile(q.STABLE_V102_PROFILE_ID, context, clock));
	assert.equal(
		q.stablePublicationProfile({ ...context, tag: 'v1.0.2', version: '1.0.2' }, clock).id,
		q.STABLE_V102_PROFILE_ID
	);
	for (const scope of q.STABLE_V103_SCOPE_IDS) {
		const receipt = q.qualificationReceipt(selected, scope, { source_sha: sha });
		assert.equal(q.scopeDisposition(receipt, scope, sha, context, clock), 'deferred');
		assert.throws(() =>
			q.scopeDisposition({ ...receipt, version: '1.0.2' }, scope, sha, context, clock)
		);
	}
	for (const scope of ['macos-native-pac', 'macos-native-http'])
		assert.throws(() => q.qualificationReceipt(selected, scope, { source_sha: sha }));
	const notice = q.stablePublicationNotice(approved.id, context, sha, clock);
	assert(notice.includes(sha));
	assert(notice.includes('Only stable v1.0.3 main push before 2026-10-25T22:00:00Z is authorized'));
	assert(notice.includes('native PAC/WPAD XCTest and independent managed HTTP client'));
	assert(!notice.includes('macos-native-pac:'));
	assert(!notice.includes('macos-native-http:'));
	console.log(
		'[OK] v1.0.3 profile: exact boundary, any subset of five scopes, PAC/HTTP mandatory.'
	);

	// Publication needs exactly the deferred receipts of the listed scopes.
	const owner = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-v103-qualification-'));
	try {
		const files = [];
		const suffixes = {
			'macos-brew-archive': [''],
			'macos-native-model-receiving': ['arm64', 'amd64'],
			'macos-shortcuts-discovery': ['']
		};
		for (const scope of q.STABLE_V103_SCOPE_IDS)
			for (const suffix of suffixes[scope] || []) {
				const file = path.join(owner, 'stable-' + scope + (suffix ? '-' + suffix : '') + '.json');
				const raw = JSON.stringify(q.qualificationReceipt(selected, scope, { source_sha: sha }));
				fs.writeFileSync(file, raw);
				files.push({ file, raw });
			}
		if (q.STABLE_V103_SCOPE_IDS.includes('macos-launch-appleevents'))
			for (const scenario of ['clean', 'karabiner_config'])
				for (const runner of ['macos-15', 'macos-15-intel']) {
					const file = path.join(
						owner,
						'stable-macos-launch-appleevents-' + scenario + '-' + runner + '.json'
					);
					const raw = JSON.stringify(
						q.launchQualificationReceipt(selected, scenario, runner, { source_sha: sha })
					);
					fs.writeFileSync(file, raw);
					files.push({ file, raw });
				}
		q.admitCommandReceipts(owner, context, sha, clock);
		for (const entry of files) {
			fs.unlinkSync(entry.file);
			assert.throws(() => q.admitCommandReceipts(owner, context, sha, clock));
			fs.writeFileSync(entry.file, entry.raw);
		}
	} finally {
		fs.rmSync(owner, { recursive: true, force: true });
	}

	// Dropping scopes is the constant plus the JSON; none left means no profile at all.
	for (const subset of V103.subsets(deferrable)) {
		const shrunk = V103.loadWithV103Scopes(subset);
		const profile = shrunk.stablePublicationProfile(context, clock);
		assert.equal(profile.id, approved.id);
		assert.deepEqual([...shrunk.deferredScopes(profile)], subset);
		for (const scope of [...deferrable, 'macos-native-pac', 'macos-native-http'])
			assert.equal(
				shrunk.resolveQualificationProfile(context, clock, scope),
				subset.includes(scope) ? profile : null
			);
		const text = shrunk.stablePublicationNotice(approved.id, context, sha, clock);
		for (const scope of deferrable)
			assert.equal(text.includes(scope + ':'), subset.includes(scope));
	}
	const none = V103.loadWithV103Scopes([]);
	assert.equal(none.stablePublicationProfile(context, clock), null);
	assert.throws(() => none.authorizeQualificationProfile(approved.id, context, clock));
	assert.throws(() => none.stablePublicationNotice(approved.id, context, sha, clock));
	assert.equal(none.stablePublicationNotice('', context, sha, clock), '');
	for (const scope of [...deferrable, 'macos-native-pac', 'macos-native-http'])
		assert.equal(none.resolveQualificationProfile(context, clock, scope), null);
	assert.equal(
		none.stablePublicationProfile({ ...context, tag: 'v1.0.2', version: '1.0.2' }, clock).id,
		q.STABLE_V102_PROFILE_ID
	);
	assert.throws(() => V103.loadWithV103Scopes([], true), /Delete the stable profile file/);
	assert.throws(() => V103.loadWithV103Scopes(['macos-native-pac']));
	assert.throws(() => V103.loadWithV103Scopes(['foreign']));
	console.log(
		'[OK] v1.0.3 shrinks one scope at a time; an empty list needs no file and selects no profile.'
	);
}
