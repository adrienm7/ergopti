// tools/test/test-ahk-startup-smoke-readiness.cjs

/** Proves actual full-startup admission with inert launches and owned disk receipts. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');

const ROOT = path.resolve(__dirname, '../..');
const OWNER = 'tools/test/test-ahk-full-startup-smoke.cjs';
const SLOTS = [
	'script_altgr_enter',
	'script_altgr_backspace',
	'script_altgr_delete',
	'script_altgr_escape'
];

/** Runs the complete real JS admission flow; no AHK or native process is started. */
async function observe(source, root, scenario) {
	const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-startup-admission-'));
	const anchor = fs.realpathSync(owned);
	const diagnostics = [];
	let warmCalls = 0;
	let retiredMetricsCalls = 0;
	let configTypesCalls = 0;
	let initialReceipt;
	let initialNonce;
	let initialFullSave;
	let launchPid = 21000;
	let forwarderReads = 0;
	const ending = 'main().then(';
	assert.equal(source.split(ending).length, 2, 'the actual startup main must have one invocation');
	const executable = source.slice(0, source.indexOf(ending)) + '\nglobalThis.bootMain = main;\n';
	try {
		const context = vm.createContext({
			__dirname: path.join(root, 'tools/test'),
			process: { platform: 'win32', pid: 20000, env: { ERGOPTI_AHK_EXE: process.execPath } },
			Buffer,
			setImmediate,
			console: {
				log: (...items) => diagnostics.push(items.join(' ')),
				error: (...items) => diagnostics.push(items.join(' '))
			},
			require(name) {
				if (name === 'os') return { ...os, tmpdir: () => owned };
				if (name === 'fs' && scenario === 'forwarder-failure') {
					const forwarder = path.join(
						root,
						'static/ergopti_plus/windows/_generated/personal_shortcuts.ahk'
					);
					return {
						...fs,
						existsSync(file) {
							return file === forwarder || fs.existsSync(file);
						},
						readFileSync(file, ...args) {
							if (file === forwarder)
								return Buffer.from(++forwarderReads === 1 ? 'initial' : 'changed');
							return fs.readFileSync(file, ...args);
						}
					};
				}
				if (name === './lib/ahk-startup-diagnostics.cjs')
					return require('./lib/ahk-startup-diagnostics.cjs');
				if (name === './lib/ahk-startup-fixture.cjs')
					return {
						createStartupCodeFixture(container) {
							if (scenario === 'setup-failure') throw new Error('inert setup failure');
							const windows = path.join(container, 'static/ergopti_plus/windows');
							fs.mkdirSync(path.join(windows, '_generated'), { recursive: true });
							return {
								windows,
								close() {
									if (scenario === 'cleanup-failure') throw new Error('inert cleanup failure');
								}
							};
						},
						prepareStartupPersonalInclude(windows) {
							fs.writeFileSync(path.join(windows, '_generated/personal_shortcuts.ahk'), 'inert');
						}
					};
				if (name === 'child_process')
					return {
						spawnSync(binary, args, options) {
							assert.equal(binary, process.execPath, 'only the inert recording port is available');
							assert.equal(args[0], '/ErrorStdOut');
							assert.equal(fs.existsSync(args[1]), true, 'the actual wrapper was written');
							const probe = options.env.ERGOPTI_STARTUP_SMOKE_DIR;
							assert.equal(path.relative(anchor, fs.realpathSync(probe)).startsWith('..'), false);
							const fixture = path.basename(probe);
							if (fixture === 'retired-metrics-config') {
								retiredMetricsCalls++;
								const file = path.join(probe, 'config/autohotkey/config.toml');
								const original = fs.readFileSync(file, 'utf8');
								assert.equal(
									original,
									'# retained legacy dashboard bindings\n[metrics]\n' +
										'metrics_shortcut_typing = "Ctrl+Alt+M" # retained typing\n' +
										'metrics_shortcut_apps = { future = { keep = 9 }, enabled = false } # retained apps\n',
									'the actual runner seeds all independently authored retired records'
								);
								let saved = original + '\n[fixture_owned]\nboot_saved = true\n';
								if (scenario === 'retired-comment') saved = saved.replace(' # retained typing', '');
								if (scenario === 'retired-banner')
									saved = saved.replace('# retained legacy dashboard bindings\n', '');
								if (scenario === 'retired-string')
									saved = saved.replace('Ctrl+Alt+M', 'Ctrl+Alt+N');
								if (scenario === 'retired-future') saved = saved.replace('keep = 9', 'keep = 10');
								if (scenario === 'retired-false')
									saved = saved.replace('enabled = false', 'enabled = 0');
								if (scenario === 'retired-malformed') saved += '\n[broken\n';
								if (scenario === 'retired-duplicate')
									saved += '# retained legacy dashboard bindings\n';
								if (scenario === 'retired-missing') fs.unlinkSync(file);
								else fs.writeFileSync(file, '\uFEFF' + saved);
							}
							if (fixture === 'literal-config-types') {
								configTypesCalls++;
								assert.equal(options.env.ERGOPTI_STARTUP_SMOKE_EXPECT_CONFIG_TYPES, '1');
								const file = path.join(probe, 'config/autohotkey/config.toml');
								if (configTypesCalls === 1)
									assert.equal(
										fs.readFileSync(file, 'utf8'),
										"[script]\nlocale = 'en'\nlog_level = 'DEBUG'\n" +
											'[personal_editor]\ndefault_section = "001"\n'
									);
								assert.match(
									fs.readFileSync(args[1], 'utf8'),
									/_StartupSmokeConfigTypesReceipt\(\)/
								);
								const typedWarm = configTypesCalls === 2;
								const corrupt = scenario.startsWith('types-warm-') ? typedWarm : !typedWarm;
								const receipt = {
									nonce: options.env.ERGOPTI_STARTUP_SMOKE_NONCE,
									pid: launchPid + 1,
									locale: 'en',
									level: 'DEBUG',
									section: '001'
								};
								if (corrupt && scenario.endsWith('-nonce')) receipt.nonce = 'f'.repeat(32);
								if (corrupt && scenario.endsWith('-numeric')) receipt.section = 1;
								if (corrupt && scenario.endsWith('-pid')) receipt.pid--;
								if (corrupt && scenario.endsWith('-level')) receipt.level = 'INFO';
								if (corrupt && scenario.endsWith('-locale')) receipt.locale = 'fr';
								if (!(corrupt && scenario.endsWith('-missing')))
									fs.writeFileSync(path.join(probe, 'config-types.json'), JSON.stringify(receipt), {
										flag: 'wx'
									});
								fs.writeFileSync(
									file,
									'[script]\nlocale = "en"\nlog_level = "DEBUG"\n' +
										'[personal_editor]\ndefault_section = ' +
										(corrupt && scenario.endsWith('-disk') ? '1' : '"001"') +
										'\n'
								);
							}
							const warm = fixture === 'fresh-config' && initialReceipt !== undefined;
							if (warm) warmCalls++;
							const pid = ++launchPid;
							const result = { pid, status: 0, stdout: Buffer.alloc(0), stderr: Buffer.alloc(0) };
							if (warm && scenario === 'early-exit') return result;
							if (warm && scenario === 'nonzero-exit') return { ...result, status: 7 };
							if (!warm && scenario === 'first-early-exit') return result;
							fs.writeFileSync(path.join(probe, 'startup-pump.txt'), 'pumped');
							fs.writeFileSync(path.join(probe, 'tray-shell.txt'), 'ready');
							let running = SLOTS;
							if (fixture === 'script-chords-off') running = [];
							if (fixture === 'script-chord-none') running = SLOTS.slice(1);
							fs.writeFileSync(
								path.join(probe, 'script-chords.txt'),
								SLOTS.flatMap((slot) =>
									[0, 1, 2].map(
										(criterion) => `${criterion}|${slot}|1|${Number(running.includes(slot))}`
									)
								).join('\n') + '\n'
							);
							if (fixture.startsWith('extension-'))
								fs.writeFileSync(
									path.join(probe, 'extension-receipt.txt'),
									[
										fixture !== 'extension-neutral',
										fixture !== 'extension-neutral',
										fixture === 'extension-enabled',
										false
									]
										.map(Number)
										.join('|')
								);
							if (fixture === 'suspend-marker')
								fs.unlinkSync(path.join(probe, 'suspend_restore.marker'));
							const logs = path.join(probe, 'ergopti_plus/logs');
							fs.mkdirSync(logs, { recursive: true });
							// A real boot logs the staged and the full Hotstrings menu
							// renders; the smoke requires both, within its budget.
							const render = (ms) =>
								`[INFO] [BootProfile] MENU/initMenu: hotstrings menu rendered: +${ms} ms (total ${ms} ms).\n`;
							// A paused AI-on boot defers its AI hotkeys and the resume
							// activates them; the smoke requires both lines (#97).
							let resume = '';
							if (fixture === 'suspend-marker') {
								if (scenario !== 'ai-deferral-missing')
									resume += '[INFO] AI hotkeys deferred to the resume: the driver is paused.\n';
								if (scenario !== 'ai-resume-missing')
									resume += '[INFO] AI hotkeys deferred by the pause are active.\n';
							}
							fs.writeFileSync(
								path.join(logs, 'ErgoptiPlus_20261004.log'),
								warm && scenario === 'logged-error'
									? '[ERROR] inert warm failure\n'
									: render(15) +
											render(scenario === 'slow-render' ? 3200 : 40) +
											resume +
											'[INFO] inert ready\n'
							);
							const receipt = {
								schema_version: 1,
								nonce: options.env.ERGOPTI_STARTUP_SMOKE_NONCE,
								pid,
								executable: binary,
								compiled: false,
								build_commit: '__COMMIT__',
								bundle_identity: '__VERSION__\n__COMMIT__',
								phase: 'ready',
								driver_ready: true,
								menu_ready: true,
								logs_flushed: true
							};
							if (!warm && fixture === 'fresh-config') {
								initialReceipt = { ...receipt };
								initialNonce = receipt.nonce;
							}
							if (warm && scenario === 'ready' && receipt.nonce !== undefined)
								assert.notEqual(receipt.nonce, initialNonce, 'warm startup requires its own nonce');
							if (warm && scenario === 'foreign-pid') receipt.pid = initialReceipt.pid;
							if (warm && scenario === 'foreign-nonce') receipt.nonce = 'f'.repeat(32);
							if (warm && scenario === 'incomplete') receipt.logs_flushed = false;
							if (receipt.nonce !== undefined)
								fs.writeFileSync(
									path.join(probe, 'ready.json'),
									warm && scenario === 'malformed'
										? '{'
										: JSON.stringify(warm && scenario === 'stale' ? initialReceipt : receipt),
									{ flag: 'wx' }
								);
							const wrapperSource = fs.readFileSync(args[1], 'utf8');
							const integrated =
								/_StartupSmokeReceipts\(\*\)\s*\{\s*_StartupSmokeFullSaveReceipt\(\)/.test(
									wrapperSource
								);
							const fullSave = {
								schema_version: 1,
								nonce: options.env.ERGOPTI_STARTUP_SMOKE_NONCE,
								pid,
								requested: 1,
								committed: 1,
								settled: 1,
								pending: false
							};
							if (!warm && fixture === 'fresh-config') initialFullSave = { ...fullSave };
							if (warm && scenario === 'save-pid') fullSave.pid = initialFullSave.pid;
							if (warm && scenario === 'save-nonce') fullSave.nonce = 'f'.repeat(32);
							if (warm && ['save-uncommitted', 'save-abandoned'].includes(scenario))
								fullSave.committed = 0;
							if (warm && scenario === 'save-pending') fullSave.pending = true;
							if (warm && scenario === 'save-string') fullSave.requested = '1';
							if (warm && scenario === 'save-zero') fullSave.requested = 0;
							if (
								integrated &&
								!(warm && scenario === 'save-missing') &&
								!(!warm && scenario === 'first-save-missing')
							)
								fs.writeFileSync(
									path.join(probe, 'full-save.json'),
									warm && scenario === 'save-malformed'
										? '{'
										: JSON.stringify(
												warm && scenario === 'save-stale' ? initialFullSave : fullSave
											),
									{ flag: 'wx' }
								);
							return result;
						}
					};
				if (name === 'smol-toml') return require(require.resolve(name, { paths: [root] }));
				assert.ok(['fs', 'path', 'node:crypto'].includes(name), 'unexpected dependency: ' + name);
				return require(name);
			}
		});
		vm.runInContext(executable, context, { filename: OWNER });
		let status, failure;
		try {
			status = await context.bootMain();
		} catch (error) {
			status = 1;
			failure = error.message;
		}
		const retained = fs
			.readdirSync(owned)
			.filter((name) => name.startsWith('ergopti-startup-diagnostics-'))
			.map((name) => JSON.parse(fs.readFileSync(path.join(owned, name, 'receipt.json'), 'utf8')));
		return {
			status,
			warmCalls,
			retiredMetricsCalls,
			configTypesCalls,
			diagnostics,
			retained,
			failure
		};
	} finally {
		assert.equal(
			fs.realpathSync(owned),
			anchor,
			'the owned fixture root identity must remain unchanged'
		);
		fs.rmSync(owned, { recursive: true, maxRetries: 5, retryDelay: 100 });
	}
}

/** Exercise the real diagnostic filesystem owner with closed, inert disk fixtures. */
function checkStartupDiagnosticRetention() {
	const owner = require('./lib/ahk-startup-diagnostics.cjs');
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-startup-retention-controls-'));
	const anchor = fs.realpathSync(temporary);
	let controls = 0;
	try {
		const source = path.join(temporary, 'source.txt');
		fs.writeFileSync(source, 'owned source');
		const nonce = 'a'.repeat(32);
		const observed = Buffer.from([239, 187, 191, 0, 255, 13, 10]);
		function packet(name, configure = () => {}) {
			const probe = path.join(temporary, name);
			fs.mkdirSync(path.join(probe, 'ergopti_plus/logs'), { recursive: true });
			const log = path.join(probe, 'ergopti_plus/logs/ErgoptiPlus_20261014.log');
			const completeLog = Buffer.from(
				'\uFEFF' + Array.from({ length: 40 }, (_, index) => `line ${index}`).join('\r\n')
			);
			fs.writeFileSync(log, completeLog);
			fs.writeFileSync(path.join(probe, 'config.toml'), 'private config must not be collected');
			const receiver = owner.createStartupDiagnostics(temporary, 'local', { owner: source });
			const result = {
				pid: 21,
				status: 7,
				signal: null,
				stdout: observed,
				stderr: Buffer.from('inert failure')
			};
			configure({ probe, log, result });
			receiver.capture(name, 'cold', probe, nonce, result);
			const retained = receiver.finish(false, true, `${name}/verdict`);
			const record = JSON.parse(fs.readFileSync(path.join(retained, 'receipt.json'), 'utf8'));
			assert.equal(record.qualified, false);
			assert.equal(record.descendant_retirement, 'unobserved');
			assert.equal(record.transitive_source_closure, 'unreceived');
			return { receiver, retained, record, completeLog };
		}
		const full = packet('full-log');
		const logMember = full.record.invocations[0].members.find((row) =>
			row.source_member?.startsWith('logs/')
		);
		assert.deepEqual(fs.readFileSync(path.join(full.retained, logMember.file)), full.completeLog);
		controls++;
		assert.deepEqual(fs.readFileSync(path.join(full.retained, '1-stdout.bin')), observed);
		controls++;
		assert.ok(!JSON.stringify(full.record).includes('private config must not be collected'));
		assert.ok(
			full.record.invocations[0].members.every((row) => row.source_member !== 'config.toml')
		);
		controls++;
		assert.ok(full.record.invocations[0].missing.includes('ready.json'));
		controls++;
		assert.equal(full.record.invocations[0].status, 7);
		controls++;
		const timed = packet('timeout', ({ result }) => {
			result.status = null;
			result.signal = 'SIGTERM';
			result.error = { code: 'ETIMEDOUT' };
		});
		assert.equal(timed.record.invocations[0].error_code, 'ETIMEDOUT');
		assert.equal(timed.record.invocations[0].child_output_completeness, 'unknown');
		controls++;
		const missing = packet('missing-streams', ({ result }) => {
			result.stdout = null;
			result.stderr = null;
		});
		assert.ok(missing.record.invocations[0].missing.includes('stdout'));
		assert.ok(!fs.existsSync(path.join(missing.retained, '1-stdout.bin')));
		controls++;
		assert.throws(() => full.receiver.finish(false, true, 'again'), /finalized twice/);
		controls++;
		assert.throws(
			() => full.receiver.capture('full-log', 'cold', temporary, nonce, {}),
			/already finalized/
		);
		controls++;
		assert.throws(() => owner.createStartupDiagnostics('relative', 'local', {}), /absolute root/);
		controls++;
		assert.throws(
			() => owner.createStartupDiagnostics(temporary, 'unknown', {}),
			/context refused/
		);
		controls++;
		const success = owner.createStartupDiagnostics(temporary, 'local', { owner: source });
		const successfulDirectory = success.directory;
		assert.equal(success.finish(true, true, 'ready'), null);
		assert.equal(fs.existsSync(successfulDirectory), false);
		controls++;
		const cleanup = owner.createStartupDiagnostics(temporary, 'local', { owner: source });
		assert.ok(cleanup.finish(true, false, 'cleanup'));
		controls++;
		assert.throws(
			() =>
				owner.createStartupDiagnostics(temporary, 'local', {
					owner: path.join(temporary, 'absent')
				}),
			(error) => {
				assert.equal(
					JSON.parse(fs.readFileSync(path.join(error.retainedStartupDiagnostics, 'receipt.json')))
						.capture_errors[0].stage,
					'source-binding'
				);
				return error.code === 'ENOENT';
			}
		);
		controls++;
		const over = path.join(temporary, 'oversized');
		const fd = fs.openSync(over, 'wx');
		fs.writeSync(fd, Buffer.from('x'), 0, 1, owner.MAX_MEMBER_BYTES);
		fs.closeSync(fd);
		assert.throws(() => owner.readDiagnosticMember(over, temporary), /capture policy/);
		controls++;
		const link = path.join(temporary, 'linked');
		fs.symlinkSync(path.join(temporary, 'full-log'), link, 'junction');
		try {
			assert.throws(
				() => owner.readDiagnosticMember(path.join(link, 'config.toml'), temporary),
				/links refused/
			);
		} finally {
			fs.unlinkSync(link);
		}
		controls++;
		assert.throws(() => owner.readDiagnosticMember(temporary, temporary));
		controls++;
		assert.throws(() => owner.readDiagnosticMember(source, path.join(temporary, 'full-log')));
		controls++;
		const many = path.join(temporary, 'many-logs');
		fs.mkdirSync(path.join(many, 'ergopti_plus/logs'), { recursive: true });
		for (let index = 0; index <= owner.MAX_LOG_MEMBERS; index++)
			fs.writeFileSync(path.join(many, 'ergopti_plus/logs', `${index}.log`), 'x');
		const refused = owner.createStartupDiagnostics(temporary, 'local', {});
		assert.throws(
			() =>
				refused.capture('many-logs', 'cold', many, nonce, {
					status: 1,
					stdout: observed,
					stderr: observed
				}),
			/log census/
		);
		const refusedPath = refused.finish(false, true, 'many-logs');
		assert.equal(
			JSON.parse(fs.readFileSync(path.join(refusedPath, 'receipt.json'))).capture_errors.length,
			1
		);
		controls++;
		const noCleanup = owner.createStartupDiagnostics(temporary, 'local', {});
		const late = noCleanup.finish(false, true, 'forwarder-invariant');
		assert.equal(
			JSON.parse(fs.readFileSync(path.join(late, 'receipt.json'))).last_stage,
			'forwarder-invariant'
		);
		controls++;
		assert.equal(controls, 20);
		console.log(
			'[OK] Twenty real filesystem startup retention controls preserve bytes and reject unsafe or incomplete observations.'
		);
	} finally {
		assert.equal(fs.realpathSync(temporary), anchor);
		fs.rmSync(temporary, { recursive: true });
	}
}

/** Exercises the actual fresh-clone reporter and verdict flow without a child. */
function checkObserverStageRetention(root = ROOT) {
	const freshOwner = 'tools/test/test-ahk-fresh-clone-startup.cjs';
	const source = fs.readFileSync(path.join(root, freshOwner), 'utf8');
	const tree = require('acorn').parse(source, { ecmaVersion: 'latest' });
	const functions = ['run', 'reportSourceObserverStages'].map((name) => {
		const matches = tree.body.filter(
			(node) => node.type === 'FunctionDeclaration' && node.id.name === name
		);
		assert.equal(matches.length, 1, 'the actual fresh-clone owner must have exactly one ' + name);
		return source.slice(matches[0].start, matches[0].end);
	});
	const observer = fs.readFileSync(
		path.join(root, 'tools/test/fixtures/observe_ahk_source_boot.ps1'),
		'utf8'
	);
	assert.match(
		observer,
		/nonce_sha256\s*=\s*\[Convert\]::ToHexString\(\[Security.Cryptography.SHA256\]::HashData\(\s*\[Text.Encoding\]::UTF8.GetBytes\(\$Nonce\)\)\)/
	);
	assert.match(observer, /\$script:observerStageRecordingFailed\s*=\s*\$true/);
	assert.match(observer, /recording_failed\s*=\s*\[bool\]\$observerStageRecordingFailed/);
	const retained = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-source-stage-controls-'));
	const nonce = 'a'.repeat(32);
	try {
		for (const scenario of [
			'success',
			'failure',
			'stale',
			'parse-failure-stale',
			'read-failure',
			'unrelated',
			'malformed',
			'recording-failed'
		]) {
			const record = {
				schema_version: 1,
				diagnostic_only: true,
				clock: 'stopwatch-monotonic',
				nonce_sha256: require('node:crypto')
					.createHash('sha256')
					.update(scenario.includes('stale') ? 'b'.repeat(32) : nonce)
					.digest('hex'),
				recording_failed: scenario === 'recording-failed',
				stages: [{ stage: 'ack-published', elapsed_ms: 12, result: -1 }]
			};
			const file = path.join(retained, 'observer-stages.json');
			fs.writeFileSync(file, scenario === 'malformed' ? '{' : JSON.stringify(record));
			const logs = [],
				errors = [];
			let launches = 0;
			const context = vm.createContext({
				root,
				probe: retained,
				path,
				assert,
				crypto: require('node:crypto'),
				fs: {
					...fs,
					readFileSync(fileName, ...args) {
						if (scenario === 'read-failure' && fileName === file)
							throw new Error('private-path-must-not-be-printed');
						return fs.readFileSync(fileName, ...args);
					}
				},
				console: { log: (line) => logs.push(line), error: (line) => errors.push(line) },
				spawnSync() {
					launches++;
					return {
						status: ['failure', 'parse-failure-stale'].includes(scenario) ? 1 : 0,
						stdout: '',
						stderr: ''
					};
				}
			});
			vm.runInContext(functions.join('\n') + '\nglobalThis.actualRun = run;', context, {
				filename: freshOwner
			});
			const args = [
				'-File',
				path.join(
					root,
					scenario === 'unrelated'
						? 'unrelated.ps1'
						: 'tools/test/fixtures/observe_ahk_source_boot.ps1'
				),
				'-Nonce',
				nonce
			];
			let caught;
			try {
				context.actualRun('inert-recording-port', args);
			} catch (error) {
				caught = error;
			}
			assert.equal(launches, 1, 'the exact owner verdict flow must execute once');
			assert.equal(
				Boolean(caught),
				['failure', 'parse-failure-stale'].includes(scenario),
				scenario + ': diagnostics cannot alter the original status verdict'
			);
			const accepted = ['success', 'failure', 'recording-failed'].includes(scenario);
			assert.equal(
				logs.length,
				accepted ? 1 : 0,
				scenario + ': only the current bound record is retained'
			);
			if (accepted)
				assert.deepEqual(JSON.parse(logs[0].slice('source-observer-stages: '.length)), record);
			else if (scenario !== 'unrelated')
				assert.ok(errors.includes('Current passive source observer stages are unavailable.'));
			assert.ok(
				!errors.join('\n').includes('private-path-must-not-be-printed'),
				'observer read failures never expose private paths'
			);
		}
	} finally {
		fs.rmSync(retained, { recursive: true });
	}
}

async function check(source, root = ROOT) {
	checkStartupDiagnosticRetention();
	const pipeline = require('./ci-pipeline.cjs').open(root);
	const unit = pipeline.job('test-ahk');
	const uploader = require('./ci-pipeline.cjs').step(unit, 'Publish AHK execution manifest');
	assert.equal(require('./ci-pipeline.cjs').stepField(uploader, 'if'), 'always()');
	assert.ok(
		unit.indexOf(uploader) > unit.indexOf('name: Test fresh Git clone bootstrap and warm startup')
	);
	assert.ok(unit.indexOf(uploader) > unit.indexOf('name: Run the full-driver startup smoke'));
	for (const member of [
		'windows-ahk-execution-manifest.json',
		'windows-ahk-suite.stdout.log',
		'windows-ahk-suite.stderr.log',
		'windows-qualification.json',
		'windows-ahk-isolated-*.json',
		'ergopti-ahk-menu-lifecycle-*/**',
		'ergopti-snapshot16-*/**',
		'ergopti-startup-diagnostics-*/**'
	])
		assert.ok(uploader.includes('${{ runner.temp }}/' + member));
	assert.ok(uploader.includes('overwrite: true'));
	assert.ok(uploader.includes('if-no-files-found: warn'));
	checkObserverStageRetention(root);
	const observations = [];
	for (const scenario of [
		'early-exit',
		'stale',
		'foreign-pid',
		'foreign-nonce',
		'incomplete',
		'malformed',
		'logged-error',
		'nonzero-exit',
		'first-early-exit',
		'save-missing',
		'save-stale',
		'save-pid',
		'save-nonce',
		'save-uncommitted',
		'save-abandoned',
		'save-pending',
		'save-string',
		'save-zero',
		'save-malformed',
		'first-save-missing',
		'retired-comment',
		'retired-banner',
		'retired-string',
		'retired-future',
		'retired-false',
		'retired-malformed',
		'retired-duplicate',
		'retired-missing',
		'ai-deferral-missing',
		'ai-resume-missing',
		'slow-render',
		'types-cold-pid',
		'types-cold-level',
		'types-cold-numeric',
		'types-cold-locale',
		'types-cold-nonce',
		'types-cold-missing',
		'types-cold-disk',
		'types-warm-pid',
		'types-warm-level',
		'types-warm-numeric',
		'types-warm-locale',
		'types-warm-nonce',
		'types-warm-missing',
		'types-warm-disk',
		'ready'
	]) {
		const result = await observe(source, root, scenario);
		observations.push({ scenario, ...result });
		assert.equal(result.retained.length, scenario === 'ready' ? 0 : 1);
		if (scenario !== 'ready') {
			const receipt = result.retained[0];
			assert.equal(receipt.qualified, false);
			assert.ok(receipt.invocations.length >= 1, 'failed startup retains actual invocation frames');
			assert.equal(receipt.invocations[0].phase, 'cold');
			assert.equal(
				receipt.invocations.some((invocation) => invocation.phase === 'warm'),
				result.warmCalls > 0,
				'the actual warm invocation retains a separate frame'
			);
			for (const invocation of receipt.invocations) {
				assert.ok(invocation.members.some((member) => member.file.endsWith('-stdout.bin')));
				assert.ok(invocation.members.some((member) => member.file.endsWith('-stderr.bin')));
			}
		}
		assert.equal(
			result.status,
			scenario === 'ready' ? 0 : 1,
			scenario + ': the actual smoke admission must require fresh complete readiness'
		);
		assert.equal(
			result.warmCalls,
			['first-early-exit', 'first-save-missing', 'slow-render'].includes(scenario) ? 0 : 1,
			scenario + ': the intended real runner branch must execute'
		);
		if (scenario.startsWith('save-'))
			assert.match(result.diagnostics.join('\n'), /reloaded-config:.*full-save receipt/);
		if (scenario === 'slow-render')
			assert.match(
				result.diagnostics.join('\n'),
				/fresh-config: a Hotstrings menu render took 3200 ms \(budget 2000 ms/
			);
		if (scenario === 'first-save-missing')
			assert.match(result.diagnostics.join('\n'), /fresh-config:.*no fresh full-save receipt/);
		if (scenario === 'early-exit')
			assert.match(result.diagnostics.join('\n'), /reloaded-config:.*no fresh readiness/);
		if (scenario === 'logged-error')
			assert.match(result.diagnostics.join('\n'), /reloaded-config reached ready with 1 error/);
		if (scenario === 'ai-deferral-missing')
			assert.match(
				result.diagnostics.join('\n'),
				/suspend-marker: the paused AI-on boot did not defer its AI hotkeys/
			);
		if (scenario === 'ai-resume-missing')
			assert.match(
				result.diagnostics.join('\n'),
				/suspend-marker: the resume did not activate the AI hotkeys its pause deferred/
			);
		if (scenario.startsWith('retired-') || scenario === 'ready')
			assert.equal(
				result.retiredMetricsCalls,
				1,
				'the actual retired-Metrics boot must execute once'
			);
		if (scenario.startsWith('types-') || scenario === 'ready')
			assert.equal(
				result.configTypesCalls,
				scenario.startsWith('types-cold-') ? 1 : 2,
				'the authored configuration must boot and independently restart'
			);
		if (scenario.startsWith('types-'))
			assert.match(result.diagnostics.join('\n'), /literal-config-types.*configuration/);
		if (scenario.startsWith('retired-'))
			assert.match(
				result.diagnostics.join('\n'),
				/retired-metrics-config:.*retired Metrics full.save/
			);
	}
	for (const scenario of ['setup-failure', 'cleanup-failure', 'forwarder-failure']) {
		const observation = await observe(source, root, scenario);
		assert.equal(observation.status, 1);
		assert.equal(
			observation.retained.length,
			1,
			'late and setup failures retain their staging directory'
		);
		assert.equal(observation.retained[0].qualified, false);
		assert.equal(
			observation.retained[0].invocations.length > 0,
			scenario !== 'setup-failure',
			'late failures retain frames; failed setup does not fabricate a native invocation'
		);
		assert.ok(
			observation.failure?.includes(
				scenario === 'forwarder-failure' ? 'personal-shortcuts' : scenario.split('-')[0]
			),
			'the original failure remains visible'
		);
	}
	return observations;
}

if (require.main === module)
	check(fs.readFileSync(path.join(ROOT, OWNER), 'utf8')).then(
		() =>
			console.log(
				'[OK] Actual startup admission cases reject stale readiness, uncommitted saves, changed config types and retired-Metrics source loss.'
			),
		(error) => {
			console.error(error);
			process.exitCode = 1;
		}
	);

module.exports = { check, observe, checkObserverStageRetention };
