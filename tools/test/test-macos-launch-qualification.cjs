// tools/test/test-macos-launch-qualification.cjs
'use strict';

/** Portable qualification controls; no native Mac actor or process is invoked. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const vm = require('node:vm');
const q = require('../ci/dev-release-qualification.cjs');
const { recordMac, verify } = require('./desktop-ci-evidence.cjs');
const policy = JSON.parse(fs.readFileSync(q.POLICY_PATH, 'utf8'));
const scope = 'macos-launch-appleevents';
const now = '2026-10-09T00:00:00Z';
const sha = 'b188785e35752381a973b6753cee0efca887695a';
const context = {
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
assert.equal(
	typeof q.launchQualificationReceipt,
	'function',
	'Explicit fifth-scope producer must be wired'
);
const profile = q.authorizeQualificationProfile(policy.id, context, now);
assert.deepEqual(q.deferredScopes(profile), [
	'windows-pac-full-url',
	'linux-window-receipts',
	'macos-brew-archive',
	'macos-shortcuts-discovery',
	scope
]);
const scenarios = [
	'clean',
	'karabiner_config',
	'upgraded',
	'source_logs',
	'symlink_config',
	'symlink_config_documents',
	'symlink_hammerspoon',
	'symlink_logs',
	'symlink_logs_dir',
	'tilde_paths',
	'dangling_logs',
	'configured_symlink',
	'plain_open'
];
const runners = ['macos-15', 'macos-15-intel'];
const modelRoot = path.resolve(os.tmpdir());
const owner = fs.mkdtempSync(path.join(modelRoot, 'ergopti-mac-launch-proposal-'));
const previousEnvironment = ['GITHUB_SHA', 'MATRIX_RUNNER'].map((name) => [
	name,
	process.env[name]
]);
let summary;
try {
	const archive = path.join(owner, 'archive.zip');
	const resultPath = path.join(owner, 'result.json');
	const output = path.join(owner, 'evidence.json');
	fs.writeFileSync(archive, 'inert owned archive model');
	let count = 0;
	function check(callback) {
		callback();
		count++;
	}
	const records = [];
	for (const runner of runners)
		for (const scenario of scenarios) {
			const receipt = q.launchQualificationReceipt(profile, scenario, runner, { source_sha: sha });
			check(() => {
				const admitted = q.validateLaunchQualificationReceipt(
					receipt,
					scenario,
					runner,
					sha,
					context,
					now
				);
				assert.equal(
					receipt.status,
					['clean', 'karabiner_config'].includes(scenario) ? 'deferred' : 'full'
				);
				assert.equal(receipt.qualified, false);
				assert.equal(Boolean(admitted), receipt.status === 'deferred');
			});
			if (receipt.status === 'deferred') {
				process.env.GITHUB_SHA = sha;
				process.env.MATRIX_RUNNER = runner;
				const result = { scenario, failures: [], qualification: receipt, native_qualified: false };
				fs.writeFileSync(resultPath, JSON.stringify(result));
				check(() => assert.throws(() => recordMac(resultPath, archive, output), /Explicit launch/));
				check(() =>
					recordMac(resultPath, archive, output, {
						qualificationContext: context,
						qualificationNow: now
					})
				);
				records.push(JSON.parse(fs.readFileSync(output, 'utf8')));
				for (const update of [
					{ qualified: true },
					{ source_sha: 'a'.repeat(40) },
					{ scenario: 'upgraded' },
					{ runner: runner === runners[0] ? runners[1] : runners[0] },
					{ unknown: true }
				]) {
					check(() =>
						assert.throws(() =>
							q.validateLaunchQualificationReceipt(
								{ ...receipt, ...update },
								scenario,
								runner,
								sha,
								context,
								now
							)
						)
					);
				}
				for (const update of [
					{ failures: ['original lifecycle failure'] },
					{ native_qualified: true },
					{ native_delayed_timer: {} },
					{ native_karabiner_config: {} }
				]) {
					fs.writeFileSync(resultPath, JSON.stringify({ ...result, ...update }));
					check(() =>
						assert.throws(() =>
							recordMac(resultPath, archive, output, {
								qualificationContext: context,
								qualificationNow: now
							})
						)
					);
				}
			} else {
				records.push({
					schema_version: 1,
					platform: 'macos',
					sha,
					runner,
					scenario,
					package_sha256: records[0].package_sha256,
					failures: []
				});
			}
		}
	// Reuse the independently authored oracle without running its test module.
	const coldFactory = fs
		.readFileSync(path.join(__dirname, 'test-desktop-ci-evidence.cjs'), 'utf8')
		.match(/^function coldBootstrapRecord\(\) \{[\s\S]*?^\}/m);
	assert.ok(coldFactory, 'The independent cold-bootstrap receipt factory must exist');
	const coldBootstrap = JSON.parse(
		JSON.stringify(
			vm.runInNewContext('(' + coldFactory[0] + ')()', {
				fs,
				path,
				crypto: require('node:crypto'),
				__dirname
			})
		)
	);
	coldBootstrap.sha = sha;
	coldBootstrap.receipt.sha = sha;
	coldBootstrap.receipt.build_commit = sha;
	const state = {
		platform: 'macos',
		release: true,
		scenarios,
		sha,
		evidence: records,
		coldBootstrap: [coldBootstrap],
		needs: Object.fromEntries(
			[
				'test-hs',
				'e2e-hs',
				'package-macos',
				'launch',
				'tooltip-canvas',
				'managed-ollama-native',
				'cold-bootstrap-native'
			].map((name) => [name, { result: 'success' }])
		),
		qualificationContext: context,
		qualificationNow: now
	};
	check(() => verify(state));
	check(() => assert.equal(records.filter((record) => record.qualification).length, 4));
	check(() => assert.throws(() => verify({ ...state, qualificationContext: null })));
	check(() => assert.throws(() => verify({ ...state, evidence: records.slice(1) })));
	check(() => assert.throws(() => verify({ ...state, evidence: [...records, records[0]] })));
	check(() =>
		assert.throws(() =>
			verify({
				...state,
				evidence: records.map((record, index) =>
					index === 4 ? { ...record, failures: ['original error'] } : record
				)
			})
		)
	);
	const badContexts = [
		['github_actions', ''],
		['ref', 'refs/heads/main'],
		['event_name', 'pull_request'],
		['release', false],
		['version', '0.0.0-dev.157'],
		['tag', 'v0.0.0-dev.157']
	];
	for (const [key, value] of badContexts) {
		const bad = { ...context, [key]: value };
		check(() => assert.equal(q.resolveQualificationProfile(bad, now), null));
		check(() => assert.throws(() => verify({ ...state, qualificationContext: bad })));
	}
	check(() => assert.throws(() => verify({ ...state, qualificationNow: policy.expires_at })));
	check(() =>
		assert.throws(() =>
			q.validatePolicy({
				...policy,
				scopes: {
					...policy.scopes,
					[scope]: {
						...policy.scopes[scope],
						scenarios: [...policy.scopes[scope].scenarios, 'plain_open']
					}
				}
			})
		)
	);
	check(() => assert.throws(() => q.parseClosedJson('{"scope":"x","scope":"x"}')));
	const receipt = q.launchQualificationReceipt(profile, 'clean', runners[0], { source_sha: sha });
	const modelInput = path.join(owner, 'python-input.json');
	const commandSource = fs.readFileSync(
		path.resolve(__dirname, '../ci/dev-release-qualification.cjs'),
		'utf8'
	);
	const environment = {
		GITHUB_ACTIONS: 'true',
		GITHUB_REPOSITORY: context.repository,
		GITHUB_EVENT_NAME: context.event_name,
		GITHUB_REF: context.ref,
		GITHUB_SHA: sha,
		ERGOPTI_DEV_RELEASE_RELEASE: 'true',
		ERGOPTI_DEV_RELEASE_PRERELEASE: context.prerelease,
		ERGOPTI_DEV_RELEASE_CHANNEL: context.channel,
		ERGOPTI_DEV_RELEASE_TAG: context.tag,
		ERGOPTI_DEV_RELEASE_VERSION: context.version
	};
	function commandModel(env, stamp, extra = []) {
		const output = path.join(owner, 'cli-receipt.json');
		const modelModule = { exports: {} };
		const modelRequire = (name) => require(name);
		modelRequire.main = modelModule;
		const modelProcess = {
			argv: [
				'node',
				'helper',
				'--scope',
				scope,
				'--scenario',
				'clean',
				'--runner',
				runners[0],
				'--receipt',
				output,
				...extra
			],
			env,
			exitCode: 0
		};
		class ModelDate extends Date {
			constructor(...args) {
				super(...(args.length ? args : [stamp]));
			}
		}
		vm.runInNewContext(commandSource, {
			require: modelRequire,
			module: modelModule,
			__dirname: path.resolve(__dirname, '../ci'),
			process: modelProcess,
			Date: ModelDate,
			console: { log() {}, error() {} }
		});
		return { status: modelProcess.exitCode, receipt: JSON.parse(fs.readFileSync(output, 'utf8')) };
	}
	check(() => {
		const actual = commandModel(environment, now);
		assert.equal(actual.status, 0);
		assert.deepEqual(actual.receipt, receipt);
	});
	for (const update of [
		{ GITHUB_ACTIONS: '' },
		{ GITHUB_REF: 'refs/heads/main' },
		{ GITHUB_EVENT_NAME: 'pull_request' },
		{ ERGOPTI_DEV_RELEASE_VERSION: '0.0.0-dev.157' },
		{ ERGOPTI_DEV_RELEASE_TAG: 'v0.0.0-dev.157' }
	]) {
		check(() => {
			const actual = commandModel({ ...environment, ...update }, now);
			assert.equal(actual.status, 0);
			assert.equal(actual.receipt.status, 'full');
			assert.equal(actual.receipt.profile_id, null);
			assert.equal(actual.receipt.qualified, false);
		});
	}
	check(() => assert.equal(commandModel(environment, policy.expires_at).receipt.status, 'full'));
	check(() => assert.equal(commandModel(environment, now, ['--scope', 'unknown']).status, 1));
	fs.writeFileSync(
		modelInput,
		JSON.stringify({
			receipt,
			source: path.resolve(__dirname, '../diagnostics/macos_launch_gate.py')
		})
	);
	const python = process.platform === 'win32' ? 'python' : 'python3';
	const model = spawnSync(
		python,
		[path.join(__dirname, 'macos_launch_qualification_model.py'), modelInput],
		{ encoding: 'utf8', timeout: 10000 }
	);
	assert.equal(model.error, undefined);
	assert.equal(model.status, 0, model.stderr + model.stdout);
	const result = JSON.parse(model.stdout);
	assert.equal(result.native_calls, 0);
	assert.equal(result.controls, 11);
	summary = {
		controls: count,
		python_controls: result.controls,
		native_calls: 0,
		native_qualified: false,
		model_owner: owner
	};
} finally {
	for (const [name, value] of previousEnvironment) {
		if (value === undefined) delete process.env[name];
		else process.env[name] = value;
	}
	const relative = path.relative(modelRoot, path.resolve(owner));
	assert(relative && !relative.startsWith('..') && !path.isAbsolute(relative));
	assert(path.basename(owner).startsWith('ergopti-mac-launch-proposal-'));
	fs.rmSync(owner, { recursive: true, force: false });
}
console.log(JSON.stringify({ ...summary, environment_restored: true, model_retired: true }));
