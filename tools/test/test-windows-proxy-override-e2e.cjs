// tools/test/test-windows-proxy-override-e2e.cjs

/**
 * ==============================================================================
 * MODULE: Windows Proxy Override End-To-End
 * DESCRIPTION:
 * Runs the real clients of the Windows proxy override (Issue #101 point 2) through
 * the fake corporate network and asserts on what the network saw: the relay named
 * by the override is asked for the tunnel, a decoy relay and a decoy PAC are never
 * contacted, and a refused value reaches nothing and is said in words.
 *
 * FEATURES & RATIONALE:
 * 1. http_client: the real adapter and its real managed worker, under AutoHotkey
 *    (tests/live/proxy_override_owner.ahk), with the value published as boot does.
 * 2. Updater: the real staging worker, in its production argument and environment
 *    shape, downloads through the real route owner.
 * 3. The Ollama launcher, the daemon and the sign-in relay are proven by the
 *    override cases of test-windows-proxy-relay-e2e.cjs, whose profile they need.
 * 4. It cannot silently skip: a missing AutoHotkey prints a "NOT EXECUTED" row, and
 *    --required, which the Windows CI step passes, turns it into a failure.
 *
 * USAGE:
 *   node tools/test/test-windows-proxy-override-e2e.cjs [--required] [--only=<substring>]
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawnSync, spawn } = require('node:child_process');
const {
	pacScript,
	startFakePacServer,
	startFakeProxy,
	startFakeRegistry
} = require('./lib/fake-network.cjs');
const { NOT_EXECUTED_MARKER } = require('./validate-ahk-suite-manifest.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVER = path.join(ROOT, 'static/ergopti_plus/windows');
const SHARED = path.join(ROOT, 'static/ergopti_plus/_shared');
const VENDOR = path.join(DRIVER, 'vendor');
const OWNER = path.join(DRIVER, 'tests/live/proxy_override_owner.ahk');
const AUTOHOTKEY = process.env.AUTOHOTKEY_EXE || 'C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe';
const POWERSHELL = path.join(
	process.env.WINDIR || 'C:/Windows',
	'System32/WindowsPowerShell/v1.0/powershell.exe'
);
const REQUIRED = process.argv.includes('--required');
const ONLY = (process.argv.find((value) => value.startsWith('--only=')) || '').slice(
	'--only='.length
);
// No such host resolves: a request that really went direct cannot reach anything.
const TARGET_HOST = 'proxy-override-target.invalid';
const TARGET = `https://${TARGET_HOST}/feed`;
const AUTHORITY = `${TARGET_HOST}:443`;
const REFUSED = 'proxy.corp.invalid:3128';
const WORKER_TIMEOUT_MS = 90000;
const LOCALE = JSON.parse(fs.readFileSync(path.join(SHARED, 'data/locales/en.json'), 'utf8'));

let total = 0;
let failed = 0;
let notExecuted = 0;

function report(name, state, detail = '') {
	total++;
	if (state === 'ok') console.log(`ok ${total} - ${name}`);
	else if (state === 'skip') {
		notExecuted++;
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

const tunnels = (proxy) => proxy.events.filter((event) => event.outcome === 'tunnel');

/** Runs a child without blocking the event loop the fake network lives on. */
function run(command, args, environment) {
	return new Promise((resolve, reject) => {
		const child = spawn(command, args, { env: environment, windowsHide: true });
		let stdout = '';
		let stderr = '';
		child.stdout.on('data', (chunk) => (stdout += chunk));
		child.stderr.on('data', (chunk) => (stderr += chunk));
		const timer = setTimeout(() => {
			child.kill();
			reject(new Error(`${path.basename(command)} ran out of time: ${stdout} ${stderr}`));
		}, WORKER_TIMEOUT_MS);
		child.on('error', reject);
		child.on('close', (code) => {
			clearTimeout(timer);
			resolve({ code, stdout, stderr });
		});
	});
}

/** The inherited environment without any relay of the machine running the test. */
function cleanEnvironment(extra) {
	const environment = { ...process.env };
	for (const name of Object.keys(environment))
		if (/^(https?|all|no)_proxy$|^ergopti_proxy_override$/i.test(name)) delete environment[name];
	return { ...environment, ...extra };
}

/** Runs the AutoHotkey owner over one plan and returns what it wrote. */
async function runOwner(work, plan, extra = {}) {
	const planPath = path.join(work, `plan-${Date.now()}-${total}.json`);
	const resultPath = `${planPath}.result`;
	fs.writeFileSync(
		planPath,
		JSON.stringify({ shared: SHARED, vendor: VENDOR, url: TARGET, result: resultPath, ...plan })
	);
	const done = await run(
		AUTOHOTKEY,
		['/force', '/ErrorStdOut', OWNER, planPath],
		cleanEnvironment(extra)
	);
	assert.equal(done.code, 0, `the owner ran: ${done.stdout} ${done.stderr}`);
	return JSON.parse(fs.readFileSync(resultPath, 'utf8'));
}

/** Runs the real updater staging worker in its production shape. */
async function runStaging(work, override, extra = {}) {
	const prefix = `ERGOPTI_UPDATER_${process.pid}_${Date.now()}_1`;
	const swapSource = path.join(work, 'swap-source.ps1');
	fs.writeFileSync(swapSource, '# swap\n');
	const inputs = {
		URL: TARGET,
		DIGEST: 'a'.repeat(64),
		NEW_EXE: path.join(work, 'staged', 'new.exe'),
		SWAP_PATH: path.join(work, 'staged', 'swap.ps1'),
		SWAP_SOURCE: swapSource,
		CURRENT: path.join(work, 'current.exe'),
		MINIMUM: '1',
		TIMEOUT: '5000',
		DOWNLOAD_MODULE: path.join(VENDOR, 'ergopti_updater_download.ps1'),
		DEADLINE: '45000',
		STARTED_TICK: String((os.uptime() * 1000) | 0),
		PROXY_POLICY: path.join(SHARED, 'modules/network/proxy_policy.json'),
		UPDATER_DEFAULTS: path.join(SHARED, 'modules/updater/defaults.json'),
		AUTHENTICATED_SIZE: '0'
	};
	fs.mkdirSync(path.join(work, 'staged'), { recursive: true });
	const environment = { ...extra };
	for (const [name, value] of Object.entries(inputs)) environment[`${prefix}_${name}`] = value;
	if (override !== null) environment.ERGOPTI_PROXY_OVERRIDE = override;
	return run(
		POWERSHELL,
		[
			'-NoLogo',
			'-NoProfile',
			'-NonInteractive',
			'-ExecutionPolicy',
			'Bypass',
			'-File',
			path.join(VENDOR, 'ergopti_updater_staging.ps1'),
			'-TransportPrefix',
			prefix
		],
		cleanEnvironment(environment)
	);
}

async function main() {
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-proxy-override-'));
	const registry = await startFakeRegistry();
	const relay = await startFakeProxy({ mode: 'open', upstream: { port: registry.port } });
	const decoy = await startFakeProxy({ mode: 'open', upstream: { port: registry.port } });
	const pac = await startFakePacServer({ script: pacScript(`PROXY 127.0.0.1:${decoy.port}`) });
	const reset = () => {
		relay.setMode('open');
		decoy.setMode('open');
		pac.requests.length = 0;
	};
	const hasAhk = fs.existsSync(AUTOHOTKEY);
	const ahkCheck = hasAhk
		? check
		: async (name) => {
				if (ONLY && !name.includes(ONLY)) return;
				report(name, REQUIRED ? 'fail' : 'skip', `AutoHotkey is not at ${AUTOHOTKEY}`);
			};
	// A company PAC and an exported relay both name the decoy: only the override may win.
	const company = { pac_url: pac.url };
	const exported = { HTTPS_PROXY: decoy.url, https_proxy: decoy.url };

	try {
		await ahkCheck(
			'http_client: a relay override carries the request past the PAC and the exported relay',
			async () => {
				reset();
				const result = await runOwner(work, { stored: relay.url, ...company }, exported);
				assert.equal(result.published, 1);
				assert.deepEqual(
					tunnels(relay)
						.map((event) => event.authority)
						.slice(0, 1),
					[AUTHORITY],
					JSON.stringify(result)
				);
				assert.equal(decoy.events.length, 0, 'the decoy relay saw nothing');
				assert.equal(pac.requests.length, 0, 'the PAC was never fetched');
				assert.deepEqual(result.curl_route, { ok: 1, proxy: relay.url, source: 'override' });
				assert.equal(result.for_url, relay.url);
				assert.equal(result.async_resolved, 1);
				assert.equal(result.async_proxy, relay.url);
			}
		);

		await ahkCheck(
			'http_client: a direct override goes to nobody, not even the exported relay',
			async () => {
				reset();
				const result = await runOwner(work, { stored: 'direct', ...company }, exported);
				assert.equal(relay.events.length + decoy.events.length, 0, JSON.stringify(result));
				assert.equal(pac.requests.length, 0, 'the PAC was never fetched');
				assert.deepEqual(result.curl_route, { ok: 1, proxy: '', source: 'override' });
				assert.equal(result.for_url, '');
				assert.notEqual(result.status, 200, 'the unresolvable target stayed unreachable');
			}
		);

		await ahkCheck('http_client: an empty override leaves the company PAC in charge', async () => {
			reset();
			const result = await runOwner(work, { stored: '', ...company });
			assert.ok(pac.requests.length > 0, 'the worker fetched the PAC');
			assert.deepEqual(
				tunnels(decoy)
					.map((event) => event.authority)
					.slice(0, 1),
				[AUTHORITY],
				JSON.stringify(result)
			);
			assert.equal(relay.events.length, 0);
		});

		await ahkCheck(
			'http_client: a loopback destination stays direct under a relay override',
			async () => {
				reset();
				let hits = 0;
				const origin = http.createServer((request, response) => {
					hits++;
					response.end('ok');
				});
				await new Promise((resolve) => origin.listen(0, '127.0.0.1', resolve));
				try {
					const url = `http://127.0.0.1:${origin.address().port}/`;
					const result = await runOwner(work, { stored: relay.url, url });
					assert.equal(result.status, 200, JSON.stringify(result));
					assert.equal(hits >= 1, true);
					assert.equal(relay.events.length, 0, 'the relay never saw it');
					assert.equal(result.for_url, '');
				} finally {
					await new Promise((resolve) => origin.close(resolve));
				}
			}
		);

		await ahkCheck(
			'http_client: a bad stored value is refused, reaches nothing and is not read as automatic',
			async () => {
				reset();
				const result = await runOwner(work, { stored: REFUSED, ...company }, exported);
				assert.equal(result.published, 0);
				assert.equal(relay.events.length + decoy.events.length, 0, JSON.stringify(result));
				assert.equal(pac.requests.length, 0, 'it did not fall back to the PAC');
				assert.notEqual(result.status, 200);
				assert.equal(result.receipt.proxy_resolution_status, 'invalid_configuration');
				assert.equal(
					result.receipt.failure_provenance,
					'verified',
					'the failure classifier names the proxy'
				);
				assert.equal(result.curl_route.ok, 0);
				assert.equal(result.curl_route.source, 'override_refused');
				assert.match(result.for_url, /^refused: The stored proxy override is refused/);
				assert.equal(result.async_resolved, 0);
				assert.ok(
					!JSON.stringify(result).includes('proxy.corp.invalid'),
					'the value is in no result or log'
				);
			}
		);

		await ahkCheck(
			'menu row: a bad value and a relay Windows cannot use are refused in words and never stored',
			async () => {
				reset();
				const typed = [
					REFUSED,
					'ftp://proxy.invalid:21',
					'socks5://127.0.0.1:1080',
					'http://user:secret@proxy.invalid:3128',
					'https://proxy.invalid:443'
				];
				const { rows, logs } = await runOwner(work, {
					stored: '',
					url: 'http://127.0.0.1:9/',
					typed
				});
				const refusals = [
					LOCALE['proxy_override.invalid'],
					LOCALE['proxy_override.invalid'],
					LOCALE['proxy_override.windows_plain_http_only'],
					LOCALE['proxy_override.windows_plain_http_only'],
					LOCALE['proxy_override.windows_plain_http_only']
				];
				rows.forEach((row, index) => {
					assert.equal(row.saved, 0, row.typed);
					assert.deepEqual(row.stored, [], row.typed);
					assert.deepEqual(row.shown, [`error: ${refusals[index]}`], row.typed);
				});
				assert.ok(!JSON.stringify(logs).includes('secret'), 'no log carries the typed credential');
			}
		);

		await ahkCheck(
			'menu row: valid values are stored in canonical form and said in words',
			async () => {
				reset();
				const typed = ['  http://proxy.invalid:3128\t', ' Direct ', ''];
				const { rows } = await runOwner(work, { stored: '', url: 'http://127.0.0.1:9/', typed });
				assert.deepEqual(
					rows.map((row) => row.stored),
					[['http://proxy.invalid:3128'], ['direct'], ['']]
				);
				assert.deepEqual(
					rows.map((row) => row.shown),
					[
						[`info: ${LOCALE['proxy_override.saved_relay']}`],
						[`info: ${LOCALE['proxy_override.saved_direct']}`],
						[`info: ${LOCALE['proxy_override.saved_automatic']}`]
					]
				);
			}
		);

		await check(
			'updater staging worker: a relay override carries the download past the exported relay',
			async () => {
				reset();
				const done = await runStaging(work, relay.url, exported);
				assert.equal(done.code, 1, 'the untrusted fake certificate ends the download');
				assert.deepEqual(
					tunnels(relay)
						.map((event) => event.authority)
						.slice(0, 1),
					[AUTHORITY],
					done.stdout
				);
				assert.equal(decoy.events.length, 0, 'the decoy relay saw nothing');
			}
		);

		await check(
			'updater staging worker: a direct override never reaches the exported relay',
			async () => {
				reset();
				const done = await runStaging(work, 'direct', exported);
				assert.equal(done.code, 1, 'the unresolvable target stays unreachable');
				assert.equal(relay.events.length + decoy.events.length, 0, done.stdout);
			}
		);

		await check(
			'updater staging worker: a refused value downloads nothing and names the proxy stage',
			async () => {
				reset();
				const done = await runStaging(work, 'invalid', exported);
				assert.equal(done.code, 1);
				assert.equal(relay.events.length + decoy.events.length, 0, done.stdout);
				const receipt = JSON.parse(done.stdout.trim().split(/\r?\n/).pop()).receipt;
				assert.equal(receipt.stage, 'proxy_resolve', done.stdout);
				assert.equal(receipt.proxy_resolution_status, 'invalid_configuration', done.stdout);
			}
		);

		await check(
			'signed artifact engine (updater and Ollama archive): a relay override carries the download',
			async () => {
				reset();
				const script = path.join(work, 'artifact.ps1');
				fs.writeFileSync(
					script,
					[
						`. '${path.join(VENDOR, 'ergopti_updater_download.ps1')}'`,
						`. '${path.join(VENDOR, 'ergopti_network_routes.ps1')}'`,
						`$PolicyFile = '${path.join(SHARED, 'modules/network/proxy_policy.json')}'`,
						`$DefaultsFile = '${path.join(SHARED, 'modules/updater/defaults.json')}'`,
						"$State = @{ Stage = 'proxy_resolve'; Reason = 'download'; Receipt = @{}; CleanupDebt = @() }",
						'$Resolver = { param($Destination, $Budget) Resolve-ErgoptiNativeNetworkRoutes $Destination $Budget $null $null $PolicyFile $DefaultsFile }',
						'$Tick = [ErgoptiUpdaterMonotonicClock]::GetTickCount64()',
						`try { Invoke-ErgoptiUpdaterArtifactDownload ([Uri]'${TARGET}') '${path.join(work, 'artifact', 'out.bin')}' 5000 $State $Resolver 45000 $Tick 1024 $PolicyFile $DefaultsFile } catch { exit 1 }`
					].join('\n')
				);
				const done = await run(
					POWERSHELL,
					[
						'-NoLogo',
						'-NoProfile',
						'-NonInteractive',
						'-ExecutionPolicy',
						'Bypass',
						'-File',
						script
					],
					cleanEnvironment({ ERGOPTI_PROXY_OVERRIDE: relay.url, ...exported })
				);
				assert.equal(
					done.code,
					1,
					`the untrusted fake certificate ends the download: ${done.stderr}`
				);
				assert.deepEqual(
					tunnels(relay)
						.map((event) => event.authority)
						.slice(0, 1),
					[AUTHORITY],
					done.stderr
				);
				assert.equal(decoy.events.length, 0, 'the decoy relay saw nothing');
			}
		);

		await check('without the variable the staging worker keeps the exported relay', async () => {
			reset();
			const done = await runStaging(work, null, exported);
			assert.equal(done.code, 1);
			assert.deepEqual(
				tunnels(decoy)
					.map((event) => event.authority)
					.slice(0, 1),
				[AUTHORITY],
				done.stdout
			);
			assert.equal(relay.events.length, 0);
		});
	} finally {
		await Promise.all([relay.close(), decoy.close(), pac.close(), registry.close()]);
		fs.rmSync(work, { recursive: true, force: true });
	}
	console.log(`1..${total}`);
	console.log(
		`# ${total - failed - notExecuted} passed, ${failed} failed, ${notExecuted} not executed`
	);
	process.exitCode = failed ? 1 : 0;
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
