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
assert(principal.includes('#Include unit/test_qualification_parser_owner.ahk'));
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
		'ci.yml': ['validate', 'core', 'macos', 'windows', 'linux', 'manual-verdict', 'release'],
		'ci-windows.yml': ['test-ahk', 'e2e-ahk', 'package-windows', 'launch-windows', 'windows-ok'],
		'ci-macos.yml': [
			'item36-native',
			'managed-ollama-native',
			'test-hs',
			'e2e-hs',
			'tooltip-canvas',
			'package-macos',
			'launch',
			'cold-bootstrap-native',
			'macos-ok'
		],
		'ci-linux.yml': ['test-linux', 'e2e-linux', 'package-linux', 'install-linux', 'linux-ok']
	};
	const ordinaryConditions = {
		macos: "needs.validate.outputs.lane_macos == 'true'",
		windows: "needs.validate.outputs.lane_windows == 'true'",
		linux: "needs.validate.outputs.lane_linux == 'true'",
		'manual-verdict': "always() && github.event_name == 'workflow_dispatch'",
		release: "github.event_name == 'push' && needs.validate.outputs.release == 'true'",
		'windows-ok': 'always()',
		'item36-native': "${{ github.event_name == 'workflow_dispatch' && !inputs.release }}",
		'macos-ok': 'always()',
		'package-linux':
			"${{ !cancelled() && (needs.e2e-linux.result == 'success' || (github.event_name == 'workflow_dispatch' && needs.e2e-linux.result == 'failure')) }}",
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
	assert.equal(jobs, 26);
	assert(steps > 150, 'full step inventory cannot be vacuous');
	const rootSource = fs.readFileSync(path.join(ROOT, '.github/workflows/ci.yml'), 'utf8');
	const rootJobs = pipeline.jobsOfText(rootSource, '.github/workflows/ci.yml');
	const release = rootJobs.find((job) => job.id === 'release');
	assert(release, 'the real release owner is retained');
	assert.equal(
		pipeline.field(release.body, 'if'),
		"github.event_name == 'push' && needs.validate.outputs.release == 'true'"
	);
	assert.deepEqual(pipeline.needsOf(release.body), [
		'validate',
		'core',
		'macos',
		'windows',
		'linux'
	]);
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
		'Retired fast157: all26 job classes and retained steps use full defaults; actual obsolete CLI refuses without side effects.'
	);
}
