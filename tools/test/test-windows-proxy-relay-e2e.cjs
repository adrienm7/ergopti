// tools/test/test-windows-proxy-relay-e2e.cjs

/**
 * ==============================================================================
 * MODULE: Windows Proxy Sign-In Relay End-To-End
 * DESCRIPTION:
 * Runs the bundled relay binary, the real managed Ollama launcher and pull worker
 * and a stub daemon through the fake corporate network, one proxy mode at a time,
 * and asserts the outcome the user would get: a pull that works, or the named
 * refusal, with the receipt's proxy_relay, the relay image's digest check, the
 * listener admitted only as the child of that exact relay, and nothing left
 * running or touching port 11434.
 *
 * FEATURES & RATIONALE:
 * 1. The sign-in is real SSPI. The relay runs in a logon session whose outbound
 *    identity is the fake domain's test credential (LOGON_NETCREDENTIALS_ONLY, the
 *    runas /netonly mechanism), so the fake proxy verifies the NTLMv2 proof with
 *    the known password. One case signs in as the real user, shape only.
 * 2. It cannot silently skip. A missing prerequisite prints a "NOT EXECUTED" TAP
 *    row with its reason and the footer counts it apart. --required, which the
 *    Windows CI step passes, turns any such row into a failure.
 * 3. Real network is out of reach: a CONNECT only reaches the loopback registry
 *    and the stub refuses any dial outside loopback (see its header).
 * 4. The official ollama.exe runs the same way when tools/test/fetch-real-ollama.cjs
 *    has fetched it: an optional mode (lib/windows-real-ollama.cjs) that --required
 *    does not demand.
 *
 * USAGE:
 *   npm run test:windows-proxy-relay-e2e [-- --required] [-- --only=<substring>]
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const {
	TEST_CREDENTIAL,
	pacScript,
	startFakePacServer,
	startFakeProxy,
	startFakeRegistry
} = require('./lib/fake-network.cjs');
const { NOT_EXECUTED_MARKER } = require('./validate-ahk-suite-manifest.cjs');
const runtime = require('./lib/windows-owned-runtime.cjs');
const { runRealDaemonCases } = require('./lib/windows-real-ollama.cjs');

const { ROOT, VENDOR } = runtime;
const REQUIRED = process.argv.includes('--required');
const ONLY = (process.argv.find((value) => value.startsWith('--only=')) || '').slice(
	'--only='.length
);
const RELAY_NAME = 'ergopti-proxy-relay.exe';
const RELAY_MANIFEST = path.join(VENDOR, 'ergopti-proxy-relay.json');
const STUB_SOURCE = path.join(__dirname, 'fixtures', 'ollama-stub');
const OWNER_SCRIPT = path.join(
	ROOT,
	'static/ergopti_plus/windows/tests/live/managed_relay_owner.ahk'
);
const DEFAULT_AHK = 'C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe';
const MODEL = 'stub-model:latest';
const GOOD_NETONLY = TEST_CREDENTIAL;
const WRONG_NETONLY = { ...TEST_CREDENTIAL, password: 'Not-The-Test-Password' };
const TIMINGS = {
	deadlineMs: 120000,
	dialMs: 2000,
	handshakeMs: 3000,
	idleMs: 30000,
	probeMs: 8000,
	listProbeMs: 1000
};
const READY_TIMEOUT_MS = 60000;
// Far longer than the same launcher takes to publish when the listener is admitted.
const RETAINED_PATIENCE_MS = 20000;
const FORBIDDEN_PORT = 11434;
// Longer than the launcher's own 5 s tunnel probe, shorter than a test's patience.
const SLOW_MS = 7000;

let total = 0;
let failed = 0;
let notExecuted = 0;
// The real daemon's row: --required never demands a 1.4 GB download from CI.
let optionalNotExecuted = 0;

function report(name, state, detail = '') {
	total++;
	if (state === 'ok') console.log(`ok ${total} - ${name}`);
	else if (state === 'skip' || state === 'optional') {
		notExecuted++;
		if (state === 'optional') optionalNotExecuted++;
		console.log(`ok ${total} - ${name}${NOT_EXECUTED_MARKER}${detail}`);
	} else {
		failed++;
		console.log(`not ok ${total} - ${name} - ${String(detail).split(/\r?\n/).join(' | ')}`);
	}
}

async function check(name, body) {
	if (ONLY && !name.includes(ONLY)) return;
	try {
		await body();
		report(name, 'ok');
	} catch (error) {
		report(name, 'fail', error.stack || error.message);
	}
}

/** Lists the proxy events of one outcome. */
const outcomes = (proxy, outcome) => proxy.events.filter((event) => event.outcome === outcome);

/** Reads the stub's event file. */
function stubEvents(file) {
	if (!fs.existsSync(file)) return [];
	return fs
		.readFileSync(file, 'utf8')
		.trim()
		.split('\n')
		.filter(Boolean)
		.map((line) => JSON.parse(line));
}

/** True while a process id exists. */
function alive(pid) {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		if (error.code === 'ESRCH') return false;
		throw error;
	}
}

/** Who holds the forbidden port, by owning process; empty when nobody touches it. */
function forbiddenPortRows(pids) {
	const script = `@(Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $_.RemotePort -eq ${FORBIDDEN_PORT} -or $_.LocalPort -eq ${FORBIDDEN_PORT} } | Where-Object { @(${pids.join(',')}) -contains $_.OwningProcess } | ForEach-Object { $_.OwningProcess }) -join ','`;
	const done = spawnSync(
		runtime.POWERSHELL,
		['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script],
		{
			encoding: 'utf8',
			windowsHide: true
		}
	);
	assert.equal(done.status, 0, done.stderr);
	return done.stdout.trim();
}

/** Each prerequisite's reason when it is missing, by its case group. */
function findGo() {
	const pin = JSON.parse(
		fs.readFileSync(path.join(runtime.SHARED, 'modules/llm/managed_ollama_runtime.json'), 'utf8')
	).go_version;
	const local = process.env.LOCALAPPDATA
		? path.join(process.env.LOCALAPPDATA, 'Programs', `go-${pin.slice(2)}`, 'bin', 'go.exe')
		: '';
	if (local && fs.existsSync(local)) return local;
	const onPath = spawnSync('go', ['version'], { encoding: 'utf8', windowsHide: true });
	return onPath.status === 0 ? 'go' : '';
}

/** Compiles the stub daemon: standard library, offline. */
function buildStub(go, output) {
	const built = spawnSync(go, ['build', '-trimpath', '-buildvcs=false', '-o', output, '.'], {
		cwd: STUB_SOURCE,
		encoding: 'utf8',
		windowsHide: true,
		env: {
			...process.env,
			GOTOOLCHAIN: 'local',
			GOPROXY: 'off',
			GOFLAGS: '-mod=readonly',
			GOWORK: 'off',
			CGO_ENABLED: '0'
		}
	});
	if (built.status !== 0) throw new Error(`The stub daemon did not build: ${built.stderr}`);
}

/** Runs the relay's probe directly under a job and a sign-in identity. */
async function hostedProbe(profile, relay, proxy, netOnly) {
	const hosted = runtime.startHosted(
		profile,
		`"${relay}" probe --upstream ${proxy.url} --authority registry.ollama.ai:443 --dial-timeout-ms ${TIMINGS.dialMs} --handshake-timeout-ms ${TIMINGS.handshakeMs}`,
		{ netOnly }
	);
	await hosted.finished;
	return {
		code: hosted.exitCode(),
		line: hosted.stdout().trim(),
		stderr: hosted.stderr(),
		hostError: hosted.hostError()
	};
}

/**
 * One launcher run against the fake network, ended and verified clean.
 * @param {object} context The shared profile, registry and relay.
 * @param {object} scenario What to run and what to expect.
 */
async function runScenario(context, scenario) {
	const { profile, registry, relayPath, relaySha256 } = context;
	registry.setMode(scenario.registry ?? 'ok');
	const proxy = await startFakeProxy({
		mode: scenario.mode ?? 'open',
		upstream: { port: registry.port },
		slowMs: SLOW_MS
	});
	const pac = scenario.pac
		? await startFakePacServer({
				script: pacScript(scenario.pacRoute ?? `PROXY 127.0.0.1:${proxy.port}`),
				status: scenario.pacStatus ?? 200
			})
		: null;
	const events = path.join(profile.work, `events-${total}-${Date.now()}.jsonl`);
	const environment = {
		ERGOPTI_STUB_EVENTS: events,
		ERGOPTI_STUB_REGISTRY_SHA256: registry.sha256,
		ERGOPTI_STUB_MODE: 'plain',
		ERGOPTI_E2E_WININET_PROXY: pac ? '' : (scenario.proxyAddress ?? `127.0.0.1:${proxy.port}`),
		ERGOPTI_E2E_WININET_PAC: pac ? pac.url : '',
		ERGOPTI_PROXY_OVERRIDE: scenario.override === 'relay' ? proxy.url : (scenario.override ?? '')
	};
	const run = await runtime.launch(profile, {
		relayPath: scenario.noRelay ? '' : relayPath,
		relaySha256,
		timings: TIMINGS,
		netOnly: scenario.netOnly ?? null,
		environment
	});
	let ready = null;
	try {
		ready = await runtime.waitForReceipt(run, READY_TIMEOUT_MS);
		assert.ok(ready, `no receipt: ${run.stderr()} ${run.hostError()}`);
		const { receipt } = ready;
		assert.equal(receipt.proxy_mode, scenario.expect.mode ?? 'relay', 'proxy_mode');
		assert.equal(receipt.proxy_tunnel, scenario.expect.tunnel, 'proxy_tunnel');
		assert.equal(receipt.proxy_relay, scenario.expect.relay, 'proxy_relay');
		assert.equal(receipt.origin, `http://127.0.0.1:${run.port}`, 'the daemon serves the test port');
		assert.notEqual(run.port, FORBIDDEN_PORT);

		const serve = stubEvents(events).find((row) => row.event === 'serve');
		assert.ok(serve, 'the stub daemon started');
		assert.equal(serve.pid, receipt.child_pid, 'the receipt names the daemon');
		assert.equal(serve.proxy, scenario.expect.daemonProxy, 'what the daemon reads as HTTPS_PROXY');
		assert.equal(serve.no_cloud, '1', 'the shared serve environment reached the daemon');
		if (scenario.expect.noProxy !== undefined)
			assert.equal(serve.no_proxy, scenario.expect.noProxy, 'what the daemon reads as NO_PROXY');
		if (scenario.expect.tunnel === 'relay') {
			assert.notEqual(
				serve.ppid,
				receipt.launcher_pid,
				'under the relay the daemon is not the launcher child'
			);
			assert.ok(alive(serve.ppid), 'the relay is running');
		} else {
			assert.equal(
				serve.ppid,
				receipt.launcher_pid,
				'without the relay the daemon is the launcher child'
			);
		}
		const pids = [receipt.launcher_pid, receipt.child_pid, serve.ppid];
		assert.equal(forbiddenPortRows(pids), '', 'no owned process touches port 11434');

		const beforePull = proxy.events.length;
		const pulled = await runtime.pull(profile, run, ready, MODEL, { environment });
		assert.equal(pulled.hostError, '', 'the pull worker ran');
		assert.equal(
			pulled.code,
			scenario.expect.pullExit,
			`pull exit: ${pulled.stdout} ${pulled.stderr}`
		);
		if (scenario.expect.pullStderr) assert.match(pulled.stderr, scenario.expect.pullStderr);
		if (scenario.expect.pullExit === 0) {
			assert.match(pulled.stdout, /success/);
			assert.ok(stubEvents(events).some((row) => row.event === 'pull_succeeded'));
			assert.ok(
				proxy.events
					.slice(beforePull)
					.every((event) => !event.authority || event.authority === 'registry.ollama.ai:443'),
				'the pull asks the proxy for the registry only'
			);
		}
		if (scenario.expect.signIn) {
			const verified = outcomes(proxy, scenario.expect.signIn);
			assert.ok(
				verified.length >= (scenario.expect.pullExit === 0 ? 2 : 1),
				`sign-ins: ${JSON.stringify(proxy.events)}`
			);
		}
		if (scenario.expect.noTunnel)
			assert.equal(outcomes(proxy, 'tunnel').length, 0, 'no tunnel opened');
		if (pac && scenario.override)
			assert.equal(pac.requests.length, 0, 'an override never reads the PAC');
		else if (pac) assert.ok(pac.requests.includes('/proxy.pac'), 'the PAC was read');
		assert.equal(
			forbiddenPortRows(pids),
			'',
			'no owned process touched port 11434 during the pull'
		);
		await run.stop();
		await runtime.delay(200);
		for (const pid of pids) assert.ok(!alive(pid), `process ${pid} ended with its owner`);
		assert.ok(
			!fs.existsSync(path.join(profile.managedRoot, 'blobs')),
			'the store stays under models'
		);
	} finally {
		await run.stop();
		await Promise.all([proxy.close(), pac ? pac.close() : null]);
		fs.rmSync(run.receiptPath, { force: true });
	}
}

/** One launcher run expected to refuse before any receipt. */
async function runRefusal(
	context,
	{ port, relayPath, relaySha256, netOnly, stubMode, retained = false, override = '' }
) {
	const { profile, registry } = context;
	const proxy = await startFakeProxy({ mode: 'ntlm', upstream: { port: registry.port } });
	const events = path.join(profile.work, `events-refusal-${Date.now()}.jsonl`);
	const run = await runtime.launch(profile, {
		port,
		relayPath,
		relaySha256,
		timings: TIMINGS,
		netOnly,
		environment: {
			ERGOPTI_STUB_EVENTS: events,
			ERGOPTI_STUB_REGISTRY_SHA256: registry.sha256,
			ERGOPTI_STUB_MODE: stubMode ?? 'plain',
			ERGOPTI_E2E_WININET_PROXY: `127.0.0.1:${proxy.port}`,
			ERGOPTI_E2E_WININET_PAC: '',
			ERGOPTI_PROXY_OVERRIDE: override
		}
	});
	try {
		// A refused listener leaves live descendants, which the launcher retains until
		// the owner's deadline ends the job: it publishes nothing and does not exit.
		const patience = retained ? RETAINED_PATIENCE_MS : READY_TIMEOUT_MS;
		assert.equal(await runtime.waitForReceipt(run, patience), null, 'no receipt is published');
		if (!retained) {
			assert.equal(run.exitCode(), 1, `the launcher refuses: ${run.stderr()} ${run.hostError()}`);
			assert.match(run.stderr(), /Owned Ollama runtime refused/);
		}
		assert.ok(!fs.existsSync(run.receiptPath), 'no receipt file remains');
		return { events: stubEvents(events), proxy: proxy.events.slice() };
	} finally {
		await run.stop();
		await proxy.close();
	}
}

/** The AHK owner over the real launcher: the receipt it admits is the one written. */
async function runOwnerRegression(context, ahk) {
	const { profile, registry, relayPath, relaySha256 } = context;
	const proxy = await startFakeProxy({ mode: 'open', upstream: { port: registry.port } });
	const port = await runtime.freePort();
	const crypto = require('node:crypto');
	const runtimeTicket = crypto.randomBytes(16).toString('hex');
	const planPath = path.join(profile.work, `owner-plan-${Date.now()}.json`);
	const resultPath = `${planPath}.result`;
	const launcherArguments = runtime.launcherArguments(profile, {
		port,
		runtimeTicket,
		relayPath,
		relaySha256,
		timings: TIMINGS
	});
	const startedTick = Number(launcherArguments[launcherArguments.indexOf('-StartedTick') + 1]);
	const named = (name) => launcherArguments[launcherArguments.indexOf(`-${name}`) + 1];
	const plan = {
		launcher: path.join(runtime.LLM, 'ollama-runtime-launch.ps1'),
		helper: named('ManagedHelperPath'),
		helper_sha256: named('ManagedHelperSha256'),
		environment: named('ServeEnvironmentPath'),
		environment_sha256: named('ServeEnvironmentSha256'),
		proxy: {
			VendorDirectory: profile.vendorDirectory,
			VendorSha256: profile.vendorSha256,
			ProxyPolicyPath: named('ProxyPolicyPath'),
			ProxyPolicySha256: named('ProxyPolicySha256'),
			UpdaterDefaultsPath: named('UpdaterDefaultsPath'),
			UpdaterDefaultsSha256: named('UpdaterDefaultsSha256'),
			RouteOriginsPath: named('RouteOriginsPath'),
			RouteOriginsSha256: named('RouteOriginsSha256'),
			ProxyRelayContractPath: named('ProxyRelayContractPath'),
			ProxyRelayContractSha256: named('ProxyRelayContractSha256'),
			ProxyRelayDialMs: TIMINGS.dialMs,
			ProxyRelayHandshakeMs: TIMINGS.handshakeMs,
			ProxyRelayIdleMs: TIMINGS.idleMs,
			ProxyRelayProbeMs: TIMINGS.probeMs,
			ProxyListProbeMs: TIMINGS.listProbeMs,
			ProxyRelayPath: relayPath,
			ProxyRelaySha256: relaySha256
		},
		target: {
			managed_root: profile.managedRoot,
			version_path: profile.versionPath,
			executable: path.join(profile.versionPath, 'ollama.exe'),
			models_dir: path.join(profile.managedRoot, 'models'),
			root_identity: profile.rootIdentity,
			version_identity: profile.stageIdentity,
			ticket: profile.ticket,
			runtime_ticket: runtimeTicket,
			manifest_sha256: profile.manifestSha256,
			origin: `http://127.0.0.1:${port}`,
			port,
			started_tick: startedTick,
			deadline_ms: TIMINGS.deadlineMs
		},
		result: resultPath,
		timeout_ms: READY_TIMEOUT_MS
	};
	fs.writeFileSync(planPath, JSON.stringify(plan));
	const done = spawnSync(ahk, ['/ErrorStdOut=UTF-8', OWNER_SCRIPT, planPath], {
		encoding: 'utf8',
		windowsHide: true,
		timeout: READY_TIMEOUT_MS + 30000,
		env: runtime.scrubbedEnvironment({
			ERGOPTI_STUB_REGISTRY_SHA256: registry.sha256,
			ERGOPTI_STUB_MODE: 'plain',
			ERGOPTI_E2E_WININET_PROXY: `127.0.0.1:${proxy.port}`,
			ERGOPTI_E2E_WININET_PAC: ''
		})
	});
	await proxy.close();
	assert.equal(done.status, 0, `the AHK owner run: ${done.stdout} ${done.stderr}`);
	const result = JSON.parse(fs.readFileSync(resultPath, 'utf8').replace(/^\uFEFF/, ''));
	assert.equal(
		result.ready,
		true,
		`the real owner admits the real receipt: ${JSON.stringify(result)}`
	);
	assert.equal(
		result.field_count,
		result.expected_field_count,
		'the owner and launcher name the same fields'
	);
	assert.equal(result.proxy_relay, 'not_applicable');
	assert.equal(result.errors, '', 'the owner reported nothing while it waited');
	assert.equal(result.stopped, true, 'the owner retired the job it started');
}

async function main() {
	console.log('# Windows proxy sign-in relay end-to-end');
	const relayPath = path.join(VENDOR, RELAY_NAME);
	const missing = [];
	if (process.platform !== 'win32')
		missing.push('it needs Windows (SSPI, job objects, the launcher)');
	else {
		if (!fs.existsSync(relayPath))
			missing.push(
				`${RELAY_NAME} is not bundled: run tools/build/build_windows_proxy_relay.ps1 -Publish`
			);
		if (!findGo())
			missing.push(
				'no Go toolchain builds the stub daemon: see docs/tooling/proxy-relay-testing.md'
			);
	}
	if (missing.length) {
		report(
			'real relay, launcher and stub daemon through the fake network',
			'skip',
			missing.join('; ')
		);
		return finish();
	}

	const manifest = JSON.parse(fs.readFileSync(RELAY_MANIFEST, 'utf8'));
	const relaySha256 = runtime.sha256File(relayPath);
	await check('the bundled relay matches the digest of its manifest', async () => {
		assert.equal(relaySha256, manifest.exe_sha256);
		const smoke = spawnSync(relayPath, [], { encoding: 'utf8', windowsHide: true });
		assert.equal(smoke.status, 2);
		assert.match(smoke.stderr, /relay_refused invalid_arguments/);
	});

	const buildDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-relay-stub-'));
	const stub = path.join(buildDirectory, 'ollama.exe');
	buildStub(findGo(), stub);
	const registry = await startFakeRegistry();
	const profile = runtime.createProfile({ stubExecutable: stub });
	console.log(
		'# daemon: stub (tools/test/fixtures/ollama-stub), real launcher, helper, relay and SSPI'
	);
	const context = { profile, registry, relayPath, relaySha256 };

	const seclogon = spawnSync('sc.exe', ['query', 'seclogon'], {
		encoding: 'utf8',
		windowsHide: true
	});
	const netOnlyProbe = async () => {
		const proxy = await startFakeProxy({ mode: 'ntlm' });
		try {
			const answer = await hostedProbe(profile, relayPath, proxy, GOOD_NETONLY);
			return answer.hostError
				? answer.hostError
				: answer.code === null
					? 'the host did not run'
					: '';
		} finally {
			await proxy.close();
		}
	};
	const netOnlyRefusal =
		seclogon.status === 0 ? await netOnlyProbe() : 'the Secondary Logon service is unavailable';
	const signedIn = (name, body) => {
		if (ONLY && !name.includes(ONLY)) return null;
		if (netOnlyRefusal) {
			report(
				name,
				'skip',
				`a netonly logon session cannot start: ${netOnlyRefusal.split(/\r?\n/)[0]}`
			);
			return null;
		}
		return check(name, body);
	};

	try {
		await check(
			'probe: every proxy mode answers its contract line (real logon, real relay)',
			async () => {
				const vectors = [
					['open', 0, '{"schema":1,"status":"not_needed"}'],
					['ntlm_logon', 0, '{"schema":1,"status":"required","scheme":"ntlm"}'],
					['negotiate_logon', 0, '{"schema":1,"status":"required","scheme":"negotiate"}'],
					['basic', 3, '{"schema":1,"status":"refused","reason":"upstream_scheme_unsupported"}'],
					['digest', 3, '{"schema":1,"status":"refused","reason":"upstream_scheme_unsupported"}'],
					['refusing', 0, '{"schema":1,"status":"not_needed"}'],
					['drop', 3, '{"schema":1,"status":"refused","reason":"upstream_protocol"}'],
					['ntlm_drop', 3, '{"schema":1,"status":"refused","reason":"upstream_protocol"}'],
					['slow', 3, '{"schema":1,"status":"refused","reason":"upstream_timeout"}'],
					['ntlm_slow', 3, '{"schema":1,"status":"refused","reason":"upstream_timeout"}']
				];
				const proxy = await startFakeProxy({ mode: 'open', slowMs: SLOW_MS });
				try {
					for (const [mode, code, line] of vectors) {
						proxy.setMode(mode);
						const answer = await hostedProbe(profile, relayPath, proxy, null);
						assert.equal(answer.line, line, mode);
						assert.equal(answer.code, code, mode);
						assert.ok(!answer.stderr.includes('127.0.0.1'), 'the relay log names no address');
					}
					await proxy.close();
					const closed = await hostedProbe(profile, relayPath, proxy, null);
					assert.equal(
						closed.line,
						'{"schema":1,"status":"refused","reason":"upstream_unreachable"}'
					);
				} finally {
					await proxy.close();
				}
			}
		);
		await signedIn(
			'probe: real SSPI signs in with the known credential, NTLMv2 proof verified',
			async () => {
				const proxy = await startFakeProxy({ mode: 'ntlm' });
				try {
					const answer = await hostedProbe(profile, relayPath, proxy, GOOD_NETONLY);
					assert.equal(
						answer.line,
						'{"schema":1,"status":"required","scheme":"ntlm"}',
						answer.hostError
					);
					assert.equal(outcomes(proxy, 'credential_verified').length, 1);
				} finally {
					await proxy.close();
				}
			}
		);
		await signedIn('probe: a wrong password is the named sign_in_rejected', async () => {
			const proxy = await startFakeProxy({ mode: 'ntlm' });
			try {
				const answer = await hostedProbe(profile, relayPath, proxy, WRONG_NETONLY);
				assert.equal(
					answer.line,
					'{"schema":1,"status":"refused","reason":"sign_in_rejected"}',
					answer.hostError
				);
				assert.equal(answer.code, 3);
				assert.equal(outcomes(proxy, 'rejected').length, 1);
			} finally {
				await proxy.close();
			}
		});

		const named = { tunnel: 'open', relay: 'not_applicable', daemonProxy: 'named_proxy' };
		const scenarios = [
			[
				'open: the daemon gets the proxy as named and the pull works',
				{ mode: 'open', expect: { ...named, pullExit: 0 } }
			],
			[
				'basic 407: no relay, the daemon reports it',
				{
					mode: 'basic',
					expect: {
						...named,
						tunnel: 'credentials',
						pullExit: 1,
						pullStderr: /Proxy Authentication Required/,
						noTunnel: true
					}
				}
			],
			[
				'digest 407: no relay, the daemon reports it',
				{
					mode: 'digest',
					expect: {
						...named,
						tunnel: 'credentials',
						pullExit: 1,
						pullStderr: /Proxy Authentication Required/,
						noTunnel: true
					}
				}
			],
			[
				'refusing: the daemon reports the 403',
				{
					mode: 'refusing',
					expect: {
						...named,
						tunnel: 'refused',
						pullExit: 1,
						pullStderr: /Forbidden/,
						noTunnel: true
					}
				}
			],
			[
				'slow: the launcher moves on, the daemon reports the 504',
				{
					mode: 'slow',
					expect: {
						...named,
						tunnel: 'unreachable',
						pullExit: 1,
						pullStderr: /Gateway Timeout/,
						noTunnel: true
					}
				}
			],
			[
				'drop: the daemon reports the lost connection',
				{
					mode: 'drop',
					expect: { ...named, tunnel: 'refused', pullExit: 1, pullStderr: /Error:/, noTunnel: true }
				}
			],
			[
				'unreachable proxy: the daemon reports it',
				{
					mode: 'open',
					proxyAddress: '127.0.0.1:1',
					expect: { ...named, tunnel: 'unreachable', pullExit: 1, pullStderr: /Error:/ }
				}
			],
			[
				'no relay installed: the login refusal stays named',
				{
					mode: 'ntlm',
					noRelay: true,
					expect: {
						tunnel: 'windows_login',
						relay: 'relay_not_installed',
						daemonProxy: 'none',
						pullExit: 3,
						pullStderr: /proxy_windows_login/,
						noTunnel: true
					}
				}
			],
			[
				'PAC answers DIRECT: no proxy reaches the daemon',
				{
					mode: 'ntlm',
					pac: true,
					pacRoute: 'DIRECT',
					expect: {
						mode: 'direct',
						tunnel: 'none',
						relay: 'not_applicable',
						daemonProxy: 'none',
						pullExit: 1,
						pullStderr: /refuses a direct registry connection/,
						noTunnel: true
					}
				}
			],
			[
				'PAC server broken: the shared policy goes direct',
				{
					mode: 'ntlm',
					pac: true,
					pacStatus: 503,
					expect: {
						mode: 'direct',
						tunnel: 'none',
						relay: 'not_applicable',
						daemonProxy: 'none',
						pullExit: 1,
						pullStderr: /refuses a direct registry connection/,
						noTunnel: true
					}
				}
			],
			[
				'proxy override: the named relay wins over the system proxy, the pull goes through it',
				{
					mode: 'open',
					override: 'relay',
					// A dead system proxy: only the override can make this pull work.
					proxyAddress: '127.0.0.1:1',
					expect: {
						mode: 'relay',
						tunnel: 'open',
						relay: 'not_applicable',
						daemonProxy: 'named_proxy',
						pullExit: 0
					}
				}
			],
			[
				'proxy override: the named relay wins over a company PAC, which is never read',
				{
					mode: 'open',
					override: 'relay',
					pac: true,
					pacRoute: 'PROXY 127.0.0.1:1',
					expect: {
						mode: 'relay',
						tunnel: 'open',
						relay: 'not_applicable',
						daemonProxy: 'named_proxy',
						pullExit: 0
					}
				}
			],
			[
				'proxy override: an NTLM relay it names goes through the sign-in relay',
				{
					mode: 'ntlm_logon',
					override: 'relay',
					proxyAddress: '127.0.0.1:1',
					expect: {
						mode: 'relay',
						tunnel: 'relay',
						relay: 'required_ntlm',
						daemonProxy: 'sign_in_relay',
						pullExit: 0,
						signIn: 'shape_accepted'
					}
				}
			],
			[
				'proxy override: direct keeps the daemon off the system proxy and off an inherited relay',
				{
					mode: 'open',
					override: 'direct',
					expect: {
						mode: 'direct',
						tunnel: 'none',
						relay: 'not_applicable',
						daemonProxy: 'none',
						noProxy: '*',
						pullExit: 1,
						pullStderr: /refuses a direct registry connection/,
						noTunnel: true
					}
				}
			],
			[
				'the real user signs in (shape only): daemon under the relay, pull works',
				{
					mode: 'ntlm_logon',
					expect: {
						tunnel: 'relay',
						relay: 'required_ntlm',
						daemonProxy: 'sign_in_relay',
						pullExit: 0,
						signIn: 'shape_accepted'
					}
				}
			],
			[
				'the real user signs in with Negotiate (shape only)',
				{
					mode: 'negotiate_logon',
					expect: {
						tunnel: 'relay',
						relay: 'required_negotiate',
						daemonProxy: 'sign_in_relay',
						pullExit: 0,
						signIn: 'shape_accepted'
					}
				}
			]
		];
		for (const [name, scenario] of scenarios)
			await check(`launcher, ${name}`, () => runScenario(context, scenario));

		const signed = [
			[
				'NTLM: daemon under the relay, proof verified on the probe and on the pull',
				{
					mode: 'ntlm',
					netOnly: GOOD_NETONLY,
					expect: {
						tunnel: 'relay',
						relay: 'required_ntlm',
						daemonProxy: 'sign_in_relay',
						pullExit: 0,
						signIn: 'credential_verified'
					}
				}
			],
			[
				'Negotiate: daemon under the relay, proof verified',
				{
					mode: 'negotiate',
					netOnly: GOOD_NETONLY,
					expect: {
						tunnel: 'relay',
						relay: 'required_negotiate',
						daemonProxy: 'sign_in_relay',
						pullExit: 0,
						signIn: 'credential_verified'
					}
				}
			],
			[
				'PAC names the NTLM proxy: real PAC worker, daemon under the relay',
				{
					mode: 'ntlm',
					pac: true,
					netOnly: GOOD_NETONLY,
					expect: {
						tunnel: 'relay',
						relay: 'required_ntlm',
						daemonProxy: 'sign_in_relay',
						pullExit: 0,
						signIn: 'credential_verified'
					}
				}
			],
			[
				'wrong password: daemon kept without the proxy, pull refused with sign_in_rejected',
				{
					mode: 'ntlm',
					netOnly: WRONG_NETONLY,
					expect: {
						tunnel: 'relay_refused',
						relay: 'sign_in_rejected',
						daemonProxy: 'none',
						pullExit: 3,
						pullStderr: /proxy_relay sign_in_rejected/,
						signIn: 'rejected',
						noTunnel: true
					}
				}
			],
			[
				'sign-in drops: pull refused with upstream_protocol',
				{
					mode: 'ntlm_drop',
					netOnly: GOOD_NETONLY,
					expect: {
						tunnel: 'relay_refused',
						relay: 'upstream_protocol',
						daemonProxy: 'none',
						pullExit: 3,
						pullStderr: /proxy_relay upstream_protocol/,
						noTunnel: true
					}
				}
			],
			[
				'sign-in hangs: pull refused with upstream_timeout',
				{
					mode: 'ntlm_slow',
					netOnly: GOOD_NETONLY,
					expect: {
						tunnel: 'relay_refused',
						relay: 'upstream_timeout',
						daemonProxy: 'none',
						pullExit: 3,
						pullStderr: /proxy_relay upstream_timeout/,
						noTunnel: true
					}
				}
			],
			[
				"digest mismatch through the relay: the pull reports Ollama's text",
				{
					mode: 'ntlm',
					registry: 'digest_mismatch',
					netOnly: GOOD_NETONLY,
					expect: {
						tunnel: 'relay',
						relay: 'required_ntlm',
						daemonProxy: 'sign_in_relay',
						pullExit: 1,
						pullStderr: /digest mismatch, file must be downloaded again/,
						signIn: 'credential_verified'
					}
				}
			]
		];
		for (const [name, scenario] of signed)
			await signedIn(`launcher, ${name}`, () => runScenario(context, scenario));

		await check('proxy override: a refused value starts nothing and contacts nobody', async () => {
			const refused = await runRefusal(context, {
				relayPath,
				relaySha256,
				netOnly: null,
				override: 'invalid'
			});
			assert.equal(refused.events.length, 0, 'no daemon ran');
			assert.equal(refused.proxy.length, 0, 'the system proxy was not contacted');
		});

		await check(
			"relay image: a digest other than the manifest's refuses before anything starts",
			async () => {
				const refused = await runRefusal(context, {
					relayPath,
					relaySha256: '0'.repeat(64),
					netOnly: null
				});
				assert.equal(refused.events.length, 0, 'no daemon ran');
				assert.equal(refused.proxy.length, 0, 'the proxy was not contacted');
			}
		);
		await check(
			'relay image: a changed binary at the admitted path refuses before anything starts',
			async () => {
				const replaced = path.join(profile.work, RELAY_NAME);
				const bytes = fs.readFileSync(relayPath);
				bytes[bytes.length - 1] ^= 0xff;
				fs.writeFileSync(replaced, bytes);
				const refused = await runRefusal(context, {
					relayPath: replaced,
					relaySha256,
					netOnly: null
				});
				assert.equal(refused.events.length, 0, 'no daemon ran');
				assert.equal(refused.proxy.length, 0, 'the proxy was not contacted');
			}
		);
		await signedIn(
			'listener: one held by a grandchild, not the exact relay child, is refused',
			async () => {
				const refused = await runRefusal(context, {
					relayPath,
					relaySha256,
					netOnly: GOOD_NETONLY,
					stubMode: 'delegate',
					retained: true
				});
				const serve = refused.events.find((row) => row.event === 'serve');
				assert.ok(serve, 'the delegated stub did listen');
			}
		);
		await check('listener: a port already held is refused before the daemon starts', async () => {
			const net = require('node:net');
			const foreign = net.createServer();
			await new Promise((resolve) => foreign.listen(0, '127.0.0.1', resolve));
			try {
				const refused = await runRefusal(context, {
					port: foreign.address().port,
					relayPath,
					relaySha256,
					netOnly: null
				});
				assert.equal(refused.events.length, 0, 'no daemon started');
			} finally {
				await new Promise((resolve) => foreign.close(resolve));
			}
		});

		const ahk = process.env.ERGOPTI_AHK_EXE || DEFAULT_AHK;
		const ownerName = 'regression c378cbe402: the real owner admits the real launcher receipt';
		if (!fs.existsSync(ahk)) report(ownerName, 'skip', `AutoHotkey v2 is not at ${ahk}`);
		else await check(ownerName, () => runOwnerRegression(context, ahk));

		await runRealDaemonCases({
			check,
			signedIn,
			skip: (name, reason) => {
				if (!ONLY || name.includes(ONLY)) report(name, 'optional', reason);
			},
			relay: { relayPath, relaySha256, timings: TIMINGS },
			netOnly: { good: GOOD_NETONLY, wrong: WRONG_NETONLY },
			tlsRegistry: registry,
			forbiddenPortRows
		});
	} finally {
		await registry.close();
		profile.dispose();
		fs.rmSync(buildDirectory, { recursive: true, force: true });
	}
	return finish();
}

function finish() {
	const passed = total - failed - notExecuted;
	console.log(`1..${total}`);
	console.log(
		`# ${passed} passed, ${failed} failed${notExecuted ? `, ${notExecuted} not executed` : ''}.`
	);
	if (REQUIRED && notExecuted > optionalNotExecuted) {
		console.log('# --required: a case that did not run is a failure here.');
		process.exitCode = 1;
	} else if (failed > 0) process.exitCode = 1;
	else if (notExecuted > optionalNotExecuted)
		console.log('SKIP (not executed): see the rows above; hosted CI runs them with --required');
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
