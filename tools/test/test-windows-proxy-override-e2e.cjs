// tools/test/test-windows-proxy-override-e2e.cjs

/**
 * ==============================================================================
 * MODULE: Windows Proxy Override End-To-End
 * DESCRIPTION:
 * Runs the real clients of the Windows proxy override (Issue #101 point 2) through
 * the fake corporate network and asserts on what the network saw: the relay named
 * by the override is asked for the tunnel, a decoy relay and a decoy PAC are never
 * contacted, and a refused value reaches nothing and is said in words. An https
 * relay, a socks5 relay and credentials in the address go through the owned
 * loopback hop, and no credential reaches a log, a command line or a receipt.
 *
 * FEATURES & RATIONALE:
 * 1. http_client: the real adapter and its real managed worker, under AutoHotkey
 *    (tests/live/proxy_override_owner.ahk), with a detached published route value.
 * 2. Updater: the real staging worker, in its production argument and environment
 *    shape, downloads through the real route owner.
 * 3. The Ollama launcher, the daemon and the sign-in relay are proven by the
 *    override cases of test-windows-proxy-relay-e2e.cjs, whose profile they need.
 *    This test proves what the daemon is handed for the extended forms.
 * 4. A system curl never carries an override: it serves loopback requests only.
 * 5. It cannot silently skip: a missing AutoHotkey prints a "NOT EXECUTED" row, and
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
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { spawnSync, spawn } = require('node:child_process');
const {
	BASIC_CREDENTIAL,
	pacScript,
	selfSignedCertificate,
	startFakePacServer,
	startFakeProxy,
	startFakeRegistry,
	startFakeSocks5Proxy
} = require('./lib/fake-network.cjs');
const { NOT_EXECUTED_MARKER } = require('./validate-ahk-suite-manifest.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVER = path.join(ROOT, 'static/ergopti_plus/windows');
const SHARED = path.join(ROOT, 'static/ergopti_plus/_shared');
const VENDOR = path.join(DRIVER, 'vendor');
const OWNER = path.join(DRIVER, 'tests/live/proxy_override_owner.ahk');
const AUTOHOTKEY = process.env.ERGOPTI_AHK_EXE || 'C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe';
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
// A numeric destination: a socks5 client resolves names itself, and this one has none.
const NUMERIC_TARGET = 'https://192.0.2.1/feed';
const NUMERIC_AUTHORITY = '192.0.2.1:443';
const REFUSED = 'proxy.corp.invalid:3128';
const SECRET = BASIC_CREDENTIAL.password;
const USERINFO = `${BASIC_CREDENTIAL.user}:${encodeURIComponent(SECRET)}`;
// The hop's shipped TLS line, the one place the test's copy of vendor/ differs from it.
const SHIPPED_RELAY_TLS = 'new SslStream(stream, false);';
// The name production once read; the shipped hop must stay deaf to it.
const RETIRED_PIN_VARIABLE = 'ERGOPTI_TEST_RELAY_PIN_SHA256';
const COMMAND_SAMPLE_MS = 400;
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

/** Every process command line of the machine, read as a child so the fakes keep running. */
function commandLines() {
	return run(
		POWERSHELL,
		[
			'-NoLogo',
			'-NoProfile',
			'-NonInteractive',
			'-Command',
			'Get-CimInstance Win32_Process | ForEach-Object { $_.CommandLine }'
		],
		process.env
	).then((done) => done.stdout);
}

/** Runs a body while sampling the command lines; fails if the secret shows in one. */
async function withoutCredentialOnAnyCommandLine(body) {
	let running = true;
	let sampled = 0;
	const sampler = (async () => {
		while (running) {
			const lines = await commandLines();
			sampled += 1;
			assert.ok(!lines.includes(SECRET), 'a command line carries the credential');
			await new Promise((resolve) => setTimeout(resolve, COMMAND_SAMPLE_MS));
		}
	})();
	try {
		return await body();
	} finally {
		running = false;
		await sampler;
		assert.ok(sampled > 0, 'the command lines were read');
	}
}

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

/**
 * A copy of vendor/ whose hop trusts one self-signed relay. The seam exists only in
 * this test's temporary folder: the workers load it because the harness names this
 * folder as their vendor directory, and no shipped input can reach the same trust.
 * @param {string} work The test's temporary folder.
 * @param {string} sha256 The relay certificate's lowercase hexadecimal digest.
 * @returns {string} The copy's path.
 */
function trustingVendor(work, sha256) {
	const copy = path.join(work, 'trusting-vendor');
	fs.cpSync(VENDOR, copy, { recursive: true });
	const routes = path.join(copy, 'ergopti_network_routes.ps1');
	const source = fs.readFileSync(routes, 'utf8');
	assert.equal(
		source.split(SHIPPED_RELAY_TLS).length,
		2,
		'the shipped TLS line is where the test patches it'
	);
	const digest =
		'BitConverter.ToString(System.Security.Cryptography.SHA256.Create().ComputeHash(certificate.GetRawCertData()))';
	const trusting =
		'new SslStream(stream, false, (sender, certificate, chain, errors) => ' +
		`${digest}.Replace("-", "").ToLowerInvariant() == "${sha256}");`;
	fs.writeFileSync(routes, source.replace(SHIPPED_RELAY_TLS, trusting));
	return copy;
}

/** Runs the real updater staging worker in its production shape. */
async function runStaging(work, override, extra = {}, url = TARGET, vendor = VENDOR) {
	const prefix = `ERGOPTI_UPDATER_${process.pid}_${Date.now()}_1`;
	const swapSource = path.join(work, 'swap-source.ps1');
	fs.writeFileSync(swapSource, '# swap\n');
	const inputs = {
		URL: url,
		DIGEST: 'a'.repeat(64),
		NEW_EXE: path.join(work, 'staged', 'new.exe'),
		SWAP_PATH: path.join(work, 'staged', 'swap.ps1'),
		SWAP_SOURCE: swapSource,
		CURRENT: path.join(work, 'current.exe'),
		MINIMUM: '1',
		TIMEOUT: '5000',
		DOWNLOAD_MODULE: path.join(vendor, 'ergopti_updater_download.ps1'),
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
			path.join(vendor, 'ergopti_updater_staging.ps1'),
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
	const upstream = { port: registry.port };
	const secureRelay = await startFakeProxy({
		mode: 'open',
		upstream,
		identity: selfSignedCertificate('fake-relay.invalid', 'ecdsa')
	});
	const socksRelay = await startFakeSocks5Proxy({ upstream });
	const socksLogin = await startFakeSocks5Proxy({
		upstream,
		credential: { user: BASIC_CREDENTIAL.user, password: SECRET }
	});
	const trusting = trustingVendor(work, secureRelay.sha256);
	const hostOf = (fake) => fake.url.replace(/^[a-z0-9]+:\/\//, '');
	const forms = [
		{
			name: 'an https relay',
			fake: secureRelay,
			value: secureRelay.url,
			mode: 'open',
			vendor: trusting
		},
		{
			name: 'an https relay with credentials',
			fake: secureRelay,
			value: `https://${USERINFO}@${hostOf(secureRelay)}`,
			mode: 'basic',
			vendor: trusting
		},
		{
			name: 'an http relay with credentials',
			fake: relay,
			value: `http://${USERINFO}@${hostOf(relay)}`,
			mode: 'basic'
		},
		{ name: 'a socks5h relay', fake: socksRelay, value: `socks5h://${hostOf(socksRelay)}` },
		{
			name: 'a socks5 relay',
			fake: socksRelay,
			value: `socks5://${hostOf(socksRelay)}`,
			numeric: true
		},
		{
			name: 'a socks5h relay with credentials',
			fake: socksLogin,
			value: `socks5h://${USERINFO}@${hostOf(socksLogin)}`
		}
	];
	const reset = () => {
		relay.setMode('open');
		decoy.setMode('open');
		secureRelay.setMode('open');
		secureRelay.events.length = 0;
		socksRelay.events.length = 0;
		socksLogin.events.length = 0;
		pac.requests.length = 0;
	};
	const arm = (form) => {
		reset();
		if (form.mode) form.fake.setMode(form.mode);
	};
	const assertTunnel = (form, detail) => {
		assert.deepEqual(
			tunnels(form.fake)
				.map((event) => event.authority)
				.slice(0, 1),
			[form.numeric ? NUMERIC_AUTHORITY : AUTHORITY],
			detail
		);
		assert.equal(decoy.events.length, 0, 'the decoy relay saw nothing');
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

		await ahkCheck('menu row: a bad value is refused in words and never stored', async () => {
			reset();
			const typed = [REFUSED, 'ftp://proxy.invalid:21', 'http://proxy.invalid:3128/path'];
			const { rows } = await runOwner(work, {
				stored: '',
				url: 'http://127.0.0.1:9/',
				typed
			});
			rows.forEach((row) => {
				assert.equal(row.saved, 0, row.typed);
				assert.deepEqual(row.stored, [], row.typed);
				assert.deepEqual(row.shown, [`error: ${LOCALE['proxy_override.invalid']}`], row.typed);
			});
		});

		await ahkCheck(
			'menu row: https, socks and credentials are stored, and no log carries a credential',
			async () => {
				reset();
				const typed = [
					'socks5://127.0.0.1:1080',
					`http://user:${SECRET}@proxy.invalid:3128`,
					'https://proxy.invalid:443'
				];
				const { rows, logs } = await runOwner(work, {
					stored: '',
					url: 'http://127.0.0.1:9/',
					typed
				});
				rows.forEach((row) => {
					assert.equal(row.saved, 1, row.typed);
					assert.deepEqual(row.stored, [row.typed]);
					assert.deepEqual(row.shown, [`info: ${LOCALE['proxy_override.saved_relay']}`]);
				});
				assert.ok(!JSON.stringify(logs).includes(SECRET), 'no log carries the typed credential');
			}
		);

		for (const form of forms) {
			await ahkCheck(`http_client: ${form.name} carries the request`, async () => {
				arm(form);
				const url = form.numeric ? NUMERIC_TARGET : TARGET;
				const result = await withoutCredentialOnAnyCommandLine(() =>
					runOwner(
						work,
						{
							stored: form.value,
							url,
							...company,
							...(form.vendor ? { vendor: form.vendor } : {})
						},
						exported
					)
				);
				assert.equal(result.published, 1);
				assertTunnel(form, JSON.stringify(result.receipt));
				assert.equal(pac.requests.length, 0, 'the PAC was never fetched');
				assert.equal(result.curl_route.source, 'override');
				assert.ok(
					!JSON.stringify(result.receipt).includes(SECRET),
					'the receipt holds no credential'
				);
				assert.ok(!JSON.stringify(result.logs).includes(SECRET), 'no log holds the credential');
			});
		}

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

		for (const form of forms) {
			await check(`updater staging worker: ${form.name} carries the download`, async () => {
				arm(form);
				const done = await withoutCredentialOnAnyCommandLine(() =>
					runStaging(
						work,
						form.value,
						exported,
						form.numeric ? NUMERIC_TARGET : TARGET,
						form.vendor || VENDOR
					)
				);
				assert.equal(done.code, 1, 'the untrusted fake certificate ends the download');
				assertTunnel(form, done.stdout);
				assert.ok(!(done.stdout + done.stderr).includes(SECRET), 'no output holds the credential');
			});
		}

		await check(
			'updater staging worker: the shipped hop refuses a self-signed relay, whatever the environment says',
			async () => {
				arm(forms[0]);
				const done = await runStaging(work, secureRelay.url, {
					...exported,
					[RETIRED_PIN_VARIABLE]: secureRelay.sha256
				});
				assert.equal(done.code, 1);
				assert.deepEqual(tunnels(secureRelay), [], done.stdout);
				assert.equal(decoy.events.length, 0, 'the decoy relay saw nothing');
			}
		);

		await check('the shipped sources name no test pin', async () => {
			const source = fs.readFileSync(path.join(VENDOR, 'ergopti_network_routes.ps1'), 'utf8');
			assert.ok(!source.includes(RETIRED_PIN_VARIABLE), 'production reads no test variable');
		});

		await check(
			'updater staging worker: a wrong relay password reaches no origin and leaks nothing',
			async () => {
				reset();
				const wrong = `socks5h://${BASIC_CREDENTIAL.user}:not-${encodeURIComponent(SECRET)}@${hostOf(socksLogin)}`;
				const done = await runStaging(work, wrong, exported);
				assert.equal(done.code, 1);
				assert.deepEqual(tunnels(socksLogin), [], done.stdout);
				assert.ok(
					socksLogin.events.some((event) => event.outcome === 'rejected'),
					done.stdout
				);
				assert.ok(!(done.stdout + done.stderr).includes(SECRET), 'no output holds the credential');
			}
		);

		await check('the loopback hop refuses every process but its own', async () => {
			reset();
			const script = path.join(work, 'hop-owner.ps1');
			fs.writeFileSync(
				script,
				[
					`. '${path.join(VENDOR, 'ergopti_network_routes.ps1')}'`,
					`$Policy = Get-ErgoptiNetworkPolicy '${path.join(SHARED, 'modules/network/proxy_policy.json')}'`,
					`[Console]::Out.WriteLine((Resolve-ErgoptiRelayEndpoint '${`socks5h://${USERINFO}@${hostOf(socksLogin)}`}' $Policy))`,
					'[Console]::Out.Flush()',
					'[Console]::In.ReadLine() | Out-Null'
				].join('\n')
			);
			const child = spawn(
				POWERSHELL,
				['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script],
				{ env: cleanEnvironment({}), windowsHide: true }
			);
			try {
				const port = await new Promise((resolve, reject) => {
					let output = '';
					child.on('error', reject);
					child.stdout.on('data', (chunk) => {
						output += chunk;
						const found = output.match(/127\.0\.0\.1:(\d+)/);
						if (found) resolve(Number(found[1]));
					});
					setTimeout(
						() => reject(new Error(`the hop did not start: ${output}`)),
						WORKER_TIMEOUT_MS
					);
				});
				const answer = await new Promise((resolve, reject) => {
					let received = '';
					const socket = net.connect(port, '127.0.0.1', () =>
						socket.write(`CONNECT ${AUTHORITY} HTTP/1.1\r\nHost: ${AUTHORITY}\r\n\r\n`)
					);
					socket.on('data', (chunk) => (received += chunk));
					socket.on('error', () => resolve(received));
					socket.on('close', () => resolve(received));
					setTimeout(() => reject(new Error('the hop kept a foreign connection open')), 15000);
				});
				assert.equal(answer, '', 'nothing is answered to another process');
				assert.equal(socksLogin.events.length, 0, 'the relay never heard of it');
			} finally {
				child.kill();
			}
		});

		await ahkCheck(
			'only the network worker sees the override: not the driver, not a Run child, in no command line',
			async () => {
				arm(forms[forms.length - 1]);
				const value = forms[forms.length - 1].value;
				const result = await withoutCredentialOnAnyCommandLine(() =>
					runOwner(
						work,
						{ stored: value, url: 'http://127.0.0.1:9/', children: true },
						{ PSModulePath: 'C:\\foreign\\pwsh\\Modules' }
					)
				);
				assert.equal(result.driver_environment, '', "the driver's environment stays out of it");
				assert.equal(result.worker.code, 0, result.worker.stdout);
				const [acl, seen, modules] = result.worker.stdout.split('|');
				assert.equal(acl, 'DirectorySecurity', 'Get-Acl answers in the worker');
				assert.equal(seen, value, 'the worker gets the relay');
				assert.ok(!modules.includes('foreign'), 'the inherited module path is gone');
				// Windows PowerShell itself adds its machine folder in front.
				assert.ok(
					modules
						.toLowerCase()
						.endsWith(path.join(path.dirname(POWERSHELL), 'Modules').toLowerCase()),
					modules
				);
				assert.ok(/^comspec=/im.test(result.run_child), 'the Run child printed its environment');
				assert.ok(
					!/ergopti_proxy_override/i.test(result.run_child),
					'a Run child has no such variable'
				);
				assert.ok(!result.run_child.includes(SECRET), 'a Run child never sees the password');
			}
		);

		await ahkCheck(
			'a detached password refuses automatic sealing while real DPAPI downloads still work',
			async () => {
				const form = forms[forms.length - 1];
				arm(form);
				const first = await runOwner(work, {
					stored: form.value,
					seal_at_start: true,
					sample_envelope: true
				});
				assert.equal(
					first.sealed_now,
					0,
					'direct publication cannot forge a boot migration receipt'
				);
				assert.deepEqual(first.committed, [], 'no write without an admitted boot source');
				assert.equal(first.runtime_sealed, 0, 'refusal leaves the route unsealed');
				assert.equal(
					first.unchanged_unsealed,
					1,
					'refusal preserves the exact detached runtime value'
				);
				const envelope = first.sample_envelope;
				assert.match(envelope, /^dpapi:/);
				assert.ok(!envelope.includes(SECRET) && !envelope.includes(BASIC_CREDENTIAL.user));
				assertTunnel(form, JSON.stringify(first.receipt));
				arm(form);
				const next = await runOwner(work, { stored: envelope, seal_at_start: true });
				assert.equal(next.published, 1);
				assert.equal(next.sealed_now, 0, 'an already sealed value needs no migration');
				assert.equal(next.runtime_sealed, 1, 'the real DPAPI envelope is published as sealed');
				assert.deepEqual(next.committed, [], 'and writes nothing more');
				assertTunnel(form, JSON.stringify(next.receipt));
			}
		);

		await check('the daemon is handed the real relay, in its environment only', async () => {
			reset();
			const value = `socks5h://${USERINFO}@${hostOf(socksLogin)}`;
			const script = path.join(work, 'daemon.ps1');
			fs.writeFileSync(
				script,
				[
					`. '${path.join(VENDOR, 'ergopti_route_plan.ps1')}'`,
					`. '${path.join(VENDOR, 'ergopti_network_routes.ps1')}'`,
					`$Policy = '${path.join(SHARED, 'modules/network/proxy_policy.json')}'`,
					`$Defaults = '${path.join(SHARED, 'modules/updater/defaults.json')}'`,
					'$Resolve = { param($Origin) Resolve-ErgoptiNativeNetworkRoutes $Origin 30000 $null $null $Policy $Defaults }',
					"$Read = { param($Name) [Environment]::GetEnvironmentVariable($Name, 'Process') }",
					'$Probe = { param($Relay) Test-ErgoptiRelayReachable -Relay $Relay -TimeoutMs 1000 }',
					"$Plan = Get-ErgoptiOwnedProxyEnvironment -Origins @('https://registry.ollama.ai') -Resolve $Resolve -ReadEnvironment $Read -Probe $Probe",
					"[Console]::Out.Write($Plan.Environment['HTTPS_PROXY'])"
				].join('\n')
			);
			const done = await run(
				POWERSHELL,
				['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script],
				cleanEnvironment({ ERGOPTI_PROXY_OVERRIDE: value })
			);
			assert.equal(done.stdout.trim(), value, done.stderr);
		});

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

		await check(
			'signed artifact engine: a socks5h relay with credentials carries the download',
			async () => {
				const form = forms[forms.length - 1];
				arm(form);
				const script = path.join(work, 'artifact-hop.ps1');
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
						`try { Invoke-ErgoptiUpdaterArtifactDownload ([Uri]'${TARGET}') '${path.join(work, 'artifact-hop', 'out.bin')}' 5000 $State $Resolver 45000 $Tick 1024 $PolicyFile $DefaultsFile } catch { exit 1 }`
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
					cleanEnvironment({ ERGOPTI_PROXY_OVERRIDE: form.value, ...exported })
				);
				assert.equal(
					done.code,
					1,
					`the untrusted fake certificate ends the download: ${done.stderr}`
				);
				assertTunnel(form, done.stderr);
				assert.ok(!(done.stdout + done.stderr).includes(SECRET), 'no output holds the credential');
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
		await Promise.all(
			[relay, decoy, pac, registry, secureRelay, socksRelay, socksLogin].map((owner) =>
				owner.close()
			)
		);
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
