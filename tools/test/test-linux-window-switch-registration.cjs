// tools/test/test-linux-window-switch-registration.cjs

/**
 * ==============================================================================
 * MODULE: Native Linux Window Gate Registration
 * DESCRIPTION:
 * Reads actual npm/planner/CI owners and causally removes required declarations.
 * Native execution is separate from JS drift checks. Its measured receipt must
 * include dispatcher routing; missing, undersized or foreign-SHA evidence fails.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Pipeline = require('./ci-pipeline.cjs');
const { EventEmitter } = require('node:events');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const { verifyAggregate } = require('./linux-ci-evidence.cjs');
const { run } = require('./run-linux-window-switch-receipts.cjs');

const ROOT = path.resolve(__dirname, '../..');
const NATIVE = 'tools/test/run-linux-window-switch-receipts.cjs';
const CONTRACT = 'tools/test/test-linux-window-switch-registration.cjs';
const SOURCES = [
	'static/ergopti_plus/linux/adapters/window_switch.lua',
	'static/ergopti_plus/linux/platform/window_switch_worker.lua',
	'static/ergopti_plus/linux/adapters/program_runner.lua',
	'static/ergopti_plus/linux/infra/libuv_process_group.lua',
	'static/ergopti_plus/linux/infra/libuv_exit.lua',
	'static/ergopti_plus/linux/modules/gestures/manager.lua',
	'static/ergopti_plus/linux/ergopti_hotstrings.lua',
	'static/ergopti_plus/_shared/lua/native_worker_owner.lua',
	'static/ergopti_plus/_shared/lua/cursor_window_policy.lua',
	'static/ergopti_plus/_shared/modules/actions/actions.toml',
	'static/ergopti_plus/linux/_generated/action_catalogue.lua',
	'static/ergopti_plus/linux/_generated/action_emit.lua',
	'static/ergopti_plus/linux/tests/hardware/run_window_switch_receipts.py',
	'static/ergopti_plus/linux/tests/hardware/run_window_switch_operation.lua',
	NATIVE,
	'.github/workflows/ci-linux.yml',
	'.github/linux-ci-coverage.json',
	'static/ergopti_plus/linux/tests/hardware/native_fixture_family.py',
	'static/ergopti_plus/linux/tests/hardware/run_native_fixture_family_receipts.py'
];
const COUNT_LINE =
	'window_switch_assertions=$(sed -n \'s/^Native window receipts: \\([0-9][0-9]*\\) passed, 0 failed, 0 skipped$/\\1/p\' "$RUNNER_TEMP/linux-window-switch.log" | tail -1)';

const FAMILY_COUNT_LINE =
	'native_family_assertions=$(sed -n \'s/^Native fixture family receipts: \\([0-9][0-9]*\\) passed, 0 failed, 0 skipped$/\\1/p\' "$RUNNER_TEMP/linux-window-switch.log" | tail -1)';

/** Inspects the real declarations without running any native or JS suite. */
function validate(root) {
	const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
	const scripts = JSON.parse(read('package.json')).scripts;
	assert.equal(scripts['test:linux:window-switch'], `node ./${NATIVE}`, 'native npm declaration');
	assert.equal(
		scripts['test:linux-window-switch-registration'],
		`node ./${CONTRACT}`,
		'static npm declaration'
	);
	const plannerPath = path.join(root, 'tools/test/verify-change.cjs');
	delete require.cache[require.resolve(plannerPath)];
	const planner = require(plannerPath);
	assert.equal(
		planner.GATE_COMMANDS['linux-window-switch']?.npm,
		'test:linux:window-switch',
		'native planner command'
	);
	for (const source of SOURCES)
		assert(
			planner.selectGates([source]).has('linux-window-switch'),
			`${source}: native planner selection`
		);
	assert.equal(
		planner.GATE_COMMANDS['linux-window-switch']?.platform,
		'linux',
		'native platform classification'
	);
	const native = read(NATIVE);
	assert(
		native.includes("args: ['tests/hardware/run_native_fixture_family_receipts.py']"),
		'forced native family cleanup is mandatory'
	);
	assert(
		native.includes("'tests/hardware/native_fixture_family.py'"),
		'exact family supervisor is mandatory'
	);
	assert(
		native.includes("['tests/hardware/run_window_switch_receipts.py', '--require-routing']"),
		'native wrapper requires actual dispatcher routing'
	);
	const pipeline = Pipeline.open(root);
	const job = pipeline.job('e2e-linux');
	const step = Pipeline.step(job, 'Qualify actual cursor-display window switching');
	assert.equal(
		Pipeline.stepField(step, 'if'),
		'${{ !cancelled() }}',
		'native step must run unless cancelled'
	);
	assert.equal(
		Pipeline.stepField(step, 'continue-on-error'),
		null,
		'native errors cannot be forgiven'
	);
	assert.equal(Pipeline.stepField(step, 'timeout-minutes'), '4', 'native step is bounded');
	const command = Pipeline.stepField(step, 'run');
	assert.match(command, /set -euo pipefail/);
	const packages = command.match(/apt-get install[^\n]+/)?.[0] ?? '';
	for (const prerequisite of [
		'luajit',
		'lua-luv',
		'python3',
		'xvfb',
		'openbox',
		'xdotool',
		'x11-utils',
		'x11-xserver-utils',
		'coreutils',
		'xfonts-base'
	])
		assert(packages.split(/\s+/).includes(prerequisite), `${prerequisite}: native prerequisite`);
	assert.match(
		command,
		/npm run test:linux:window-switch \| tee "\$RUNNER_TEMP\/linux-window-switch\.log"/
	);
	assert.doesNotMatch(command, /\|\| true|continue-on-error|exit 0/);
	const record = Pipeline.runOf(Pipeline.step(job, 'Record mandatory E2E evidence'));
	assert(record.includes(COUNT_LINE), 'native count must come from successful zero-skip output');
	assert(
		record.some((line) =>
			line.includes('--subject "window-switch-receipts=$window_switch_assertions"')
		),
		'measured native subject'
	);
	assert(
		record.includes(FAMILY_COUNT_LINE),
		'native family count comes from successful zero-skip output'
	);
	assert(
		record.some((line) =>
			line.includes('--subject "native-fixture-family=$native_family_assertions"')
		),
		'measured native family subject'
	);
	const manifest = JSON.parse(read('.github/linux-ci-coverage.json'));
	assert.equal(
		manifest.jobs['e2e-linux'].subjects['native-fixture-family'],
		5,
		'actual native family assertion floor'
	);
	assert.equal(manifest.jobs['e2e-linux'].classification, 'mandatory');
	assert.equal(
		manifest.jobs['e2e-linux'].subjects['window-switch-receipts'],
		34,
		'native assertion floor includes actual routing'
	);
	assert(
		read('tools/test/run-js-suite.cjs').includes(`args: ['${CONTRACT}']`),
		'static registration belongs to JS suite'
	);
	assert(
		read('tools/test/test-npm-aliases-match-the-suite.cjs').includes(`'${NATIVE}',`),
		'native execution has a separate owner'
	);
}

/** Supplies complete independent evidence to the existing Linux verdict. */
function evidenceContract() {
	const manifest = JSON.parse(
		fs.readFileSync(path.join(ROOT, '.github/linux-ci-coverage.json'), 'utf8')
	);
	const expectedSha = '111-native-evidence-fixture';
	function inputs() {
		const needs = {},
			evidence = [];
		for (const [job, contract] of Object.entries(manifest.jobs)) {
			needs[job] = { result: 'success' };
			evidence.push({
				schema_version: 1,
				job,
				sha: expectedSha,
				architecture: 'x86_64',
				distro: 'owned fixture',
				session: 'virtual X11',
				interpreter: 'LuaJIT',
				subjects: { ...contract.subjects }
			});
		}
		return { manifest, expectedSha, needs, evidence };
	}
	verifyAggregate(inputs());
	for (const [mutate, refusal] of [
		[
			(input) => {
				delete input.evidence.find((row) => row.job === 'e2e-linux').subjects[
					'window-switch-receipts'
				];
			},
			/has no evidence for window-switch-receipts/
		],
		[
			(input) => {
				input.evidence.find((row) => row.job === 'e2e-linux').subjects['window-switch-receipts'] =
					33;
			},
			/window-switch-receipts recorded 33 assertion/
		],
		[
			(input) => {
				input.evidence.find((row) => row.job === 'e2e-linux').sha = 'foreign';
			},
			/expected/
		],
		[
			(input) => {
				delete input.evidence.find((row) => row.job === 'e2e-linux').subjects[
					'native-fixture-family'
				];
			},
			/has no evidence for native-fixture-family/
		],
		[
			(input) => {
				input.evidence.find((row) => row.job === 'e2e-linux').subjects['native-fixture-family'] = 4;
			},
			/native-fixture-family recorded 4 assertion/
		],
		[
			(input) => {
				input.needs['e2e-linux'].result = 'skipped';
			},
			/mandatory job e2e-linux concluded skipped/
		]
	]) {
		const input = inputs();
		mutate(input);
		assert.throws(() => verifyAggregate(input), refusal);
	}
}

/** Runs causal registration mutations in private copies, never the checkout. */
async function main() {
	validate(ROOT);
	evidenceContract();
	for (const platform of ['darwin', 'win32']) {
		const lines = [];
		assert.equal(
			await run({
				platform,
				spawnChild: () => assert.fail('foreign host cannot run native proof'),
				log: (line) => lines.push(line)
			}),
			0
		);
		assert(lines.some((line) => line.includes('[DEFERRED]')));
		assert(!lines.some((line) => line.includes('[OK]')));
	}
	const invocations = [];
	async function observe(mode) {
		const debts = new Map();
		const signals = new EventEmitter();
		const kills = [];
		const status = await run({
			debts,
			signals,
			platform: 'linux',
			log: () => {},
			error: () => {},
			spawnChild: (command, args, options) => {
				invocations.push([command, args, options]);
				const child = new EventEmitter();
				child.pid = 123456;
				const pipe = new EventEmitter();
				child.stdio = [null, null, null, pipe];
				child.kill = (kind) => {
					kills.push(kind);
					if (mode === 'signal-refused' && kills.length === 1) throw new Error('controlled EPERM');
					if (mode === 'signal-false' && kills.length === 1) return false;
					return true;
				};
				queueMicrotask(() => {
					const token = args[args.indexOf('--token') + 1];
					const frame = (stage) => ({
						version: 1,
						stage,
						token,
						supervisor: child.pid
					});
					if (['cancel-before-ready', 'signal-refused', 'signal-false'].includes(mode))
						signals.emit('SIGTERM');
					if (mode !== 'preflight-refused')
						pipe.emit('data', Buffer.from(JSON.stringify(frame('ready')) + '\n'));
					const status =
						mode === 'exit17'
							? 17
							: ['cancel-before-ready', 'signal-refused', 'signal-false'].includes(mode)
								? 143
								: mode === 'preflight-refused'
									? 1
									: 0;
					const terminal = {
						...frame('settled'),
						status,
						acquired: 5,
						reaped: 5,
						closed: 5,
						namespace_absent: true
					};
					if (mode === 'preflight-refused')
						Object.assign(terminal, {
							stage: 'refused',
							acquired: 0,
							reaped: 0,
							closed: 0
						});
					if (mode === 'foreign') terminal.token = 'foreign';
					if (mode === 'debt') terminal.reaped = 4;
					const finish = () => {
						if (mode !== 'missing-terminal')
							pipe.emit('data', Buffer.from(JSON.stringify(terminal) + '\n'));
						if (mode !== 'missing-eof') pipe.emit('end');
						if (mode === 'spawn-error') child.emit('error', new Error('missing prerequisites'));
						child.emit(
							'close',
							mode === 'signal' ? null : status,
							mode === 'signal' ? 'SIGKILL' : null
						);
					};
					if (['signal-refused', 'signal-false'].includes(mode)) setTimeout(finish, 65);
					else finish();
				});
				return child;
			}
		});
		assert.equal(signals.listenerCount('SIGTERM'), 0, 'owned signal handlers retire');
		assert.equal(signals.listenerCount('SIGINT'), 0, 'owned signal handlers retire');
		if (
			['missing-terminal', 'missing-eof', 'foreign', 'debt', 'signal', 'spawn-error'].includes(mode)
		) {
			assert.equal(debts.size, 1, 'lost positive owner retains explicit unresolved boundary');
			assert.equal([...debts.values()][0].positiveAdmission, true);
			assert.equal(
				await run({
					platform: 'linux',
					debts,
					spawnChild: () => assert.fail('unresolved family cannot admit successor'),
					log: () => {},
					error: () => {}
				}),
				1
			);
		} else
			assert.equal(
				debts.size,
				0,
				'physical proof or safe zero-acquisition refusal leaves no lost positive family'
			);
		return { status, kills };
	}
	for (const mode of [
		'missing-terminal',
		'missing-eof',
		'foreign',
		'debt',
		'signal',
		'spawn-error'
	])
		assert.equal((await observe(mode)).status, 1, `${mode}: missing physical receipt cannot pass`);
	assert.equal((await observe('exit17')).status, 17, 'real native failure retains its exit');
	assert.equal(
		(await observe('preflight-refused')).status,
		1,
		'unavailable native prerequisite remains red without positive-owner debt'
	);
	const cancelled = await observe('cancel-before-ready');
	assert.equal(cancelled.status, 143);
	assert.deepEqual(
		cancelled.kills,
		['SIGTERM'],
		'cancellation waits for published native admission'
	);
	for (const mode of ['signal-refused', 'signal-false']) {
		const retry = await observe(mode);
		assert.equal(retry.status, 143);
		assert(retry.kills.length >= 2, 'refused exact-child signal retains owner and retries');
	}
	const first = invocations.length;
	assert.equal((await observe('pass')).status, 0);
	const calls = invocations.slice(first);
	assert.equal(calls.length, 2, 'family cleanup control and actual X11 fixture are mandatory');
	assert.equal(calls[0][0], 'python3');
	assert(calls[0][1].includes('tests/hardware/run_native_fixture_family_receipts.py'));
	assert(calls[1][1].includes('tests/hardware/run_window_switch_receipts.py'));
	assert(calls[1][1].includes('--require-routing'));
	assert(calls.every((call) => call[1][0] === 'tests/hardware/native_fixture_family.py'));
	assert.equal(calls[1][2].cwd, path.join(ROOT, 'static/ergopti_plus/linux'));
	assert.deepEqual(calls[1][2].stdio, ['ignore', 'inherit', 'inherit', 'pipe']);
	assert(
		!('timeout' in calls[1][2]),
		'owner retains cancellation instead of blindly killing only its leader'
	);
	assert(calls[1][2].env.LUA_PATH.includes('../_shared/lua/?.lua'));
	if (process.env.ERGOPTI_NATIVE_LUA_CPATH)
		assert.equal(calls[1][2].env.LUA_CPATH, process.env.ERGOPTI_NATIVE_LUA_CPATH);
	// Exercise the real planner CLI with native subprocesses replaced at its
	// process boundary. A deferred Linux gate must never be classified as pass.
	const source = path.join(ROOT, 'tools/test/verify-change.cjs');
	const originalRequire = createRequire(source);
	const entry = { exports: {} };
	const lines = [],
		commands = [];
	let exit;
	function load(name) {
		if (name === 'node:fs') return { ...fs, existsSync: () => false };
		if (name === 'node:child_process')
			return {
				execFileSync: () => 'static/ergopti_plus/linux/adapters/window_switch.lua\0',
				spawnSync: (_command, args) => {
					commands.push(args[1]);
					return { status: 0 };
				}
			};
		return originalRequire(name);
	}
	load.main = entry;
	vm.runInNewContext(fs.readFileSync(source, 'utf8'), {
		require: load,
		module: entry,
		__dirname: path.dirname(source),
		process: {
			argv: ['node', source, '--range=fixture'],
			env: process.env,
			platform: 'win32',
			exit: (code) => {
				exit = code;
			}
		},
		console: {
			log: (line) => lines.push(String(line)),
			error: (line) => lines.push(String(line))
		}
	});
	assert.equal(exit, 0, 'existing explicit deferral remains nonblocking');
	assert(
		!commands.includes('test:linux:window-switch'),
		'foreign planner cannot execute Linux native proof'
	);
	assert(lines.some((line) => line.includes('native CI remains unexecuted')));
	assert(lines.some((line) => line.includes('deferred native validation remains unexecuted')));
	assert(!lines.some((line) => line === 'verify-change: every required gate passed.'));
	const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-window-registration-'));
	let mutations = 0;
	try {
		for (const relative of [
			'package.json',
			'.github/linux-ci-coverage.json',
			'tools/test/verify-change.cjs',
			'tools/test/validate-ahk-suite-manifest.cjs',
			'tools/test/validate-ahk-e2e-manifest.cjs',
			'tools/test/test-ahk-test-coverage.cjs',
			'tools/lint/format.cjs',
			'static/ergopti_plus/_shared/tests/corpus/hotstrings/vectors.json',
			'tools/test/run-js-suite.cjs',
			'tools/test/test-npm-aliases-match-the-suite.cjs',
			NATIVE
		]) {
			const target = path.join(fixture, relative);
			fs.mkdirSync(path.dirname(target), { recursive: true });
			fs.copyFileSync(path.join(ROOT, relative), target);
		}
		fs.cpSync(path.join(ROOT, '.github/workflows'), path.join(fixture, '.github/workflows'), {
			recursive: true
		});
		validate(fixture);
		for (const [relative, mutate, refusal] of [
			[
				'package.json',
				(source) => source.replace('"test:linux:window-switch":', '"removed-native-proof":'),
				/native npm declaration/
			],
			[
				'package.json',
				(source) =>
					source.replace('"test:linux-window-switch-registration":', '"removed-static-proof":'),
				/static npm declaration/
			],
			[
				'tools/test/verify-change.cjs',
				(source) =>
					source.replace(
						/\s*'linux-window-switch': \{ npm: 'test:linux:window-switch', platform: 'linux' \},/,
						''
					),
				/native planner command/
			],
			[
				'tools/test/verify-change.cjs',
				(source) => source.replace("gate: 'linux-window-switch'", "gate: 'removed-window-proof'"),
				/native planner selection/
			],
			[
				NATIVE,
				(source) => source.replace("'--require-routing'", "'--omitted-routing'"),
				/actual dispatcher routing/
			],
			[
				'.github/workflows/ci-linux.yml',
				(source) =>
					source.replace(
						'Qualify actual cursor-display window switching',
						'Removed window qualification'
					),
				/Qualify actual cursor-display/
			],
			[
				'.github/workflows/ci-linux.yml',
				(source) =>
					source.replace(
						'npm run test:linux:window-switch | tee',
						'echo omitted-native-proof | tee'
					),
				/test:linux:window-switch/
			],
			[
				'.github/workflows/ci-linux.yml',
				(source) =>
					source.replace(
						'Qualify actual cursor-display window switching\n        if: ${{ !cancelled() }}',
						'Qualify actual cursor-display window switching\n        if: ${{ success() }}'
					),
				/native step must run/
			],
			[
				'.github/workflows/ci-linux.yml',
				(source) =>
					source.replace(
						'Qualify actual cursor-display window switching\n',
						'Qualify actual cursor-display window switching\n        continue-on-error: true\n'
					),
				/native errors cannot be forgiven/
			],
			[
				'.github/workflows/ci-linux.yml',
				(source) => source.replace('coreutils xfonts-base', 'coreutils'),
				/xfonts-base: native prerequisite/
			],

			[
				'.github/workflows/ci-linux.yml',
				(source) => source.replace(COUNT_LINE, 'window_switch_assertions=34'),
				/native count must come/
			],
			[
				'.github/workflows/ci-linux.yml',
				(source) =>
					source.replace(
						'--subject "window-switch-receipts=$window_switch_assertions"',
						'--subject "window-switch-receipts=34"'
					),
				/measured native subject/
			],
			[
				'.github/linux-ci-coverage.json',
				(source) => source.replace('"native-fixture-family": 5', '"native-fixture-family": 4'),
				/native family assertion floor/
			],
			[
				'.github/workflows/ci-linux.yml',
				(source) => source.replace(FAMILY_COUNT_LINE, 'native_family_assertions=5'),
				/native family count comes/
			],
			[
				'.github/linux-ci-coverage.json',
				(source) => source.replace('"window-switch-receipts": 34', '"window-switch-receipts": 33'),
				/assertion floor/
			],
			[
				'tools/test/run-js-suite.cjs',
				(source) => source.replace(`args: ['${CONTRACT}']`, 'args: ["omitted-window-contract"]'),
				/static registration/
			],
			[
				'tools/test/test-npm-aliases-match-the-suite.cjs',
				(source) => source.replace(`'${NATIVE}',`, ''),
				/separate owner/
			]
		]) {
			const target = path.join(fixture, relative);
			const original = fs.readFileSync(target, 'utf8');
			const changed = mutate(original);
			assert.notEqual(changed, original, 'each mutation must actually remove its declaration');
			fs.writeFileSync(target, changed);
			assert.throws(() => validate(fixture), refusal);
			fs.writeFileSync(target, original);
			mutations++;
		}
		validate(fixture);
	} finally {
		fs.rmSync(fixture, { recursive: true, force: true });
	}
	console.log(
		`PASS: Native Linux window gate registration; ${mutations} causal declaration removals refused.`
	);
}

if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});
module.exports = { validate };
