// tools/test/lib/windows-real-ollama.cjs

/**
 * ==============================================================================
 * MODULE: Windows Real Ollama Daemon Cases
 * DESCRIPTION:
 * The optional half of the relay end-to-end test: the official ollama.exe of the
 * repository's pin, published through the real archive path and started by the
 * real launcher, against the fake corporate network.
 *
 * FEATURES & RATIONALE:
 * 1. Optional on purpose. The release is 1.4 GB and CI must stay independent of the
 *    network, so a machine without it prints NOT EXECUTED with the command that
 *    fetches it (tools/test/fetch-real-ollama.cjs), and --required ignores that row.
 * 2. Go on Windows verifies TLS only against the system store, and this test installs
 *    no root. So https through the proxy is proven up to the daemon's own refusal
 *    of the test certificate, and the complete pulls use the daemon's documented
 *    insecure registry over plain http, through HTTP_PROXY.
 * 3. The relay accepts CONNECT only, so a complete pull cannot go through it: the
 *    relay cases prove its signed-in tunnel carries the real daemon's TLS handshake.
 * 4. USERPROFILE points into the profile, because the daemon writes its identity key
 *    under the home folder.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const {
	startFakeOllamaRegistry,
	startFakeProxy,
	startFakeSocks5Proxy,
	selfSignedCertificate
} = require('./fake-network.cjs');
const { buildTinyGguf } = require('./tiny-gguf.cjs');
const runtime = require('./windows-owned-runtime.cjs');

const RELEASE = JSON.parse(
	fs.readFileSync(path.join(runtime.SHARED, 'ai/data/ollama_release.json'), 'utf8')
);
const STAMP_NAME = 'ergopti-e2e-release.json';
const CERTIFICATE_REFUSAL = /x509|certificate/i;
const CONFIG_MEDIA_TYPE = 'application/vnd.docker.container.image.v1+json';
const MODEL_MEDIA_TYPE = 'application/vnd.ollama.image.model';
const BOOTSTRAP_SOURCE = path.join(runtime.LLM, 'ollama_managed_bootstrap.ahk');
const READY_TIMEOUT_MS = 60000;
const PULL_TIMEOUT_MS = 120000;
const INFERENCE_TIMEOUT_MS = 120000;
const POLL_MS = 100;
// A CLI restarting a server would show within this.
const CLI_RESTART_PATIENCE_MS = 3000;

/** The folder fetch-real-ollama.cjs fills. */
function releaseHome() {
	return path.join(
		process.env.LOCALAPPDATA ?? '',
		'Programs',
		`ergopti-ollama-e2e-${RELEASE.version}`
	);
}

/**
 * Finds the release this repository pins.
 * @returns {{directory: string}|{reason: string}} Its folder, or why there is none.
 */
function findRealRelease() {
	const directory = path.join(releaseHome(), 'release');
	const fetch = 'run node tools/test/fetch-real-ollama.cjs (about 1.5 GB)';
	const stampPath = path.join(releaseHome(), STAMP_NAME);
	if (!fs.existsSync(stampPath)) return { reason: `no real Ollama release here: ${fetch}` };
	const stamp = JSON.parse(fs.readFileSync(stampPath, 'utf8'));
	if (stamp.archive_sha256 !== RELEASE.assets['windows-amd64'].sha256)
		return { reason: `the fetched release is not the pinned one: ${fetch}` };
	if (runtime.sha256File(path.join(directory, 'ollama.exe')) !== stamp.ollama_sha256)
		return { reason: `the fetched ollama.exe changed: ${fetch}` };
	return { directory };
}

/** The last line of a stream, for the evidence the run prints. */
const lastLine = (text) => text.trim().split(/\r?\n/).pop().slice(0, 200);

/** A fake registry serving one generated model. */
function modelRegistry(name, mode = 'ok') {
	const model = buildTinyGguf(name);
	const config = Buffer.from(
		JSON.stringify({
			model_format: 'gguf',
			model_family: 'llama',
			model_families: ['llama'],
			model_type: 'tiny',
			file_type: 'F32',
			architecture: 'amd64',
			os: 'windows'
		})
	);
	return startFakeOllamaRegistry({
		config: { mediaType: CONFIG_MEDIA_TYPE, bytes: config },
		layers: [{ mediaType: MODEL_MEDIA_TYPE, bytes: model }],
		mode
	});
}

/** The class the AHK owner reads a pull failure as, from its own table. */
function pullErrorClass(text) {
	const source = fs.readFileSync(BOOTSTRAP_SOURCE, 'utf8').replace(/\r\n/g, '\n');
	const table = /global LLM_OLLAMA_PULL_ERROR_CLASSES := \[(.*?)\n?\]\n/s.exec(source);
	assert.ok(table, 'the bootstrap names its pull error classes');
	for (const [, needle, name] of table[1].matchAll(/\["([^"]+)", "([a-z_]+)"\]/g))
		if (text.toLowerCase().includes(needle)) return name;
	return '';
}

/** One JSON POST to the daemon on its owned port. */
async function daemonPost(run, route, body, timeoutMs) {
	const reply = await fetch(`http://127.0.0.1:${run.port}${route}`, {
		method: 'POST',
		body: JSON.stringify(body),
		signal: AbortSignal.timeout(timeoutMs)
	});
	return { status: reply.status, text: await reply.text() };
}

/** Asks the daemon for a pull from the insecure registry, to its last line. */
async function insecurePull(run, model) {
	const reply = await daemonPost(
		run,
		'/api/pull',
		{ model, insecure: true, stream: true },
		PULL_TIMEOUT_MS
	);
	const rows = reply.text
		.trim()
		.split('\n')
		.filter(Boolean)
		.map((line) => JSON.parse(line));
	return rows[rows.length - 1] ?? {};
}

/** A real inference on the daemon. */
async function generate(run, model) {
	const reply = await daemonPost(
		run,
		'/api/generate',
		{ model, prompt: 'the', raw: true, stream: false, options: { num_predict: 4, seed: 1 } },
		INFERENCE_TIMEOUT_MS
	);
	assert.equal(reply.status, 200, `the daemon answers: ${reply.text}`);
	const answer = JSON.parse(reply.text);
	assert.equal(answer.done, true, 'the inference ended');
	assert.ok(answer.prompt_eval_count >= 1, `the runner read the prompt: ${reply.text}`);
	return answer;
}

/** Every running process whose image lies under the managed root. */
function ownedProcesses(profile) {
	const root = profile.managedRoot.replace(/'/g, "''");
	const script = `@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith('${root}', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $_.ProcessId }) -join ','`;
	const done = spawnSync(
		runtime.POWERSHELL,
		['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script],
		{ encoding: 'utf8', windowsHide: true }
	);
	assert.equal(done.status, 0, done.stderr);
	return done.stdout.trim();
}

/**
 * Runs the cases.
 * @param {object} harness
 * @param {Function} harness.check Runs one named case.
 * @param {Function} harness.signedIn The same, for a case that needs a netonly session.
 * @param {Function} harness.skip Reports one row as optional and not executed.
 * @param {object} harness.relay { relayPath, relaySha256, timings }.
 * @param {object} harness.netOnly { good, wrong }, the sign-in identities.
 * @param {object} harness.tlsRegistry The fake TLS registry of the stub cases.
 * @param {Function} harness.forbiddenPortRows Who of some pids touches port 11434.
 */
async function runRealDaemonCases({
	check,
	signedIn,
	skip,
	relay,
	netOnly,
	tlsRegistry,
	forbiddenPortRows
}) {
	const found = findRealRelease();
	if (found.reason) {
		skip('real daemon: the pinned ollama.exe under the real launcher', found.reason);
		return;
	}
	console.log(`# daemon: the official ollama.exe ${RELEASE.version}`);
	const profile = runtime.createProfile({ releaseDirectory: found.directory });
	const home = path.join(profile.work, 'home');
	fs.mkdirSync(home);
	// What a pull of the insecure registry reads; https goes by the launcher's HTTPS_PROXY.
	const environment = (proxy, extra = {}) => ({
		USERPROFILE: home,
		HTTP_PROXY: `http://127.0.0.1:${proxy.port}`,
		ERGOPTI_E2E_WININET_PROXY: `127.0.0.1:${proxy.port}`,
		ERGOPTI_E2E_WININET_PAC: '',
		ERGOPTI_PROXY_OVERRIDE: '',
		...extra
	});
	const start = async (values, options = {}) => {
		const run = await runtime.launch(profile, {
			...relay,
			netOnly: options.netOnly ?? null,
			environment: values
		});
		const ready = await runtime.waitForReceipt(run, READY_TIMEOUT_MS);
		if (!ready) {
			await run.stop();
			assert.fail(`no receipt from the real daemon: ${run.stderr()} ${run.hostError()}`);
		}
		return { run, ready, environment: values };
	};
	const stop = async (run, ready) => {
		const pids = [ready.receipt.launcher_pid, ready.receipt.child_pid];
		assert.equal(forbiddenPortRows(pids), '', 'no owned process touched port 11434');
		await run.stop();
		await runtime.delay(200);
		assert.equal(ownedProcesses(profile), '', 'nothing of the daemon is left running');
		fs.rmSync(run.receiptPath, { force: true });
	};
	// The real command line, as the AHK owner's worker starts it, with the flag the
	// worker never passes: the only way the CLI reaches an http registry.
	const cliPull = async (started, model) => {
		const executable = path.join(profile.versionPath, 'ollama.exe');
		const hosted = runtime.startHosted(profile, `"${executable}" pull --insecure "${model}"`, {
			environment: {
				...started.environment,
				OLLAMA_HOST: `127.0.0.1:${started.run.port}`
			}
		});
		await hosted.finished;
		return { code: hosted.exitCode(), stderr: hosted.stderr() };
	};
	const blobFile = (registry) => {
		const digest = registry.requests.find((row) => row.path.includes('/storage/sha256:'));
		return path.join(
			profile.managedRoot,
			'models',
			'blobs',
			digest.path.slice(digest.path.lastIndexOf('/') + 1).replace(':', '-')
		);
	};
	const storageGets = (registry) =>
		registry.requests.filter((row) => row.path.startsWith('/storage/')).length;
	const answerOf = (event) => event.authority === 'registry.ollama.ai:443';

	const registry = await modelRegistry('ergopti-tiny');
	const openProxy = await startFakeProxy({
		mode: 'open',
		upstream: { port: tlsRegistry.port },
		plainUpstream: { port: registry.port }
	});
	try {
		await check('real daemon: a pull through the proxy, then a real inference', async () => {
			const started = await start(environment(openProxy));
			try {
				const { receipt } = started.ready;
				assert.equal(receipt.proxy_tunnel, 'open', 'the launcher probed the proxy');
				const version = await fetch(`http://127.0.0.1:${started.run.port}/api/version`);
				assert.equal((await version.json()).version, RELEASE.version, 'the pinned build serves');

				const last = await insecurePull(started.run, 'tiny:latest');
				assert.equal(last.status, 'success', JSON.stringify(last));
				assert.ok(
					openProxy.events.some(
						(event) => event.outcome === 'forwarded' && event.url.includes('/manifests/latest')
					),
					'the manifest came through the proxy'
				);
				const answer = await generate(started.run, 'tiny:latest');
				assert.equal(typeof answer.response, 'string');
				console.log(
					`# inference: ${answer.prompt_eval_count} prompt, ${answer.eval_count} generated`
				);
			} finally {
				await stop(started.run, started.ready);
			}
		});

		await check('real daemon: blob bytes come through the proxy too', async () => {
			// Ollama 0.40.4 dialed the storage URL after the 307 directly whatever
			// HTTPS_PROXY said (transfer.checkedClient had no Proxy); 0.40.6 picks the
			// proxy per request for every checked transfer (#19065).
			const rows = registry.requests.filter((row) => row.path.startsWith('/storage/'));
			assert.ok(rows.length > 0, 'the bytes were read from the storage URL');
			assert.ok(
				rows.every((row) => row.proxied),
				JSON.stringify(rows)
			);
			const redirects = registry.requests.filter(
				(row) => row.path.includes('/blobs/') && row.method === 'GET'
			);
			assert.ok(redirects.length > 0 && redirects.every((row) => row.proxied));
		});

		await check(
			'real daemon: a digest mismatch is named, retried from clean, and heals',
			async () => {
				const broken = await modelRegistry('ergopti-digest', 'digest_mismatch');
				const proxy = await startFakeProxy({
					mode: 'open',
					upstream: { port: tlsRegistry.port },
					plainUpstream: { port: broken.port }
				});
				const started = await start(environment(proxy));
				try {
					const first = await cliPull(started, 'digest:latest');
					assert.equal(first.code, 1, first.stderr);
					assert.equal(pullErrorClass(first.stderr), 'digest_mismatch', first.stderr);
					console.log(`# the daemon said: ${lastLine(first.stderr)}`);
					assert.ok(!fs.existsSync(blobFile(broken)), 'Ollama removed the bad layer');
					const fetched = storageGets(broken);

					const retried = await cliPull(started, 'digest:latest');
					assert.equal(retried.code, 1, 'a second mismatch stays a failure');
					assert.equal(pullErrorClass(retried.stderr), 'digest_mismatch', retried.stderr);
					assert.ok(storageGets(broken) > fetched, 'the retry downloads again');

					broken.setMode('ok');
					const healed = await cliPull(started, 'digest:latest');
					assert.equal(healed.code, 0, `the retry the owner runs can succeed: ${healed.stderr}`);
					assert.ok(fs.existsSync(blobFile(broken)), 'the layer is stored');
				} finally {
					await stop(started.run, started.ready);
					await proxy.close();
					await broken.close();
				}
			}
		);

		await check('real daemon: quit during a pull leaves nothing running', async () => {
			const stalled = await modelRegistry('ergopti-stall', 'stall');
			const proxy = await startFakeProxy({
				mode: 'open',
				upstream: { port: tlsRegistry.port },
				plainUpstream: { port: stalled.port }
			});
			const started = await start(environment(proxy));
			// The real CLI: it may start a daemon of its own when its server disappears.
			const pending = cliPull(started, 'stall:latest');
			try {
				const deadline = Date.now() + PULL_TIMEOUT_MS;
				while (storageGets(stalled) === 0) {
					assert.ok(Date.now() < deadline, 'the pull never reached the storage URL');
					await runtime.delay(POLL_MS);
				}
				const running = ownedProcesses(profile).split(',').filter(Boolean);
				assert.ok(running.length >= 2, `the daemon and its pull run: ${running}`);
				await stop(started.run, started.ready);
				const ended = await Promise.race([pending, runtime.delay(PULL_TIMEOUT_MS)]);
				assert.ok(ended, 'the pull ended with its daemon');
				assert.notEqual(ended.code, 0, 'a pull whose daemon quit is not a success');
				await runtime.delay(CLI_RESTART_PATIENCE_MS);
				assert.equal(ownedProcesses(profile), '', 'the CLI started no daemon of its own');
			} finally {
				await started.run.stop();
				await proxy.close();
				await stalled.close();
			}
		});

		await signedIn(
			'real daemon: the signed-in relay carries its TLS to the registry, which it then judges',
			async () => {
				const proxy = await startFakeProxy({ mode: 'ntlm', upstream: { port: tlsRegistry.port } });
				const names = tlsRegistry.serverNames.length;
				const started = await start(environment(proxy, { HTTP_PROXY: '' }), {
					netOnly: netOnly.good
				});
				try {
					assert.equal(started.ready.receipt.proxy_tunnel, 'relay');
					assert.equal(started.ready.receipt.proxy_relay, 'required_ntlm');
					const pulled = await runtime.pull(profile, started.run, started.ready, 'tiny:latest', {
						environment: started.environment
					});
					assert.equal(pulled.code, 1, pulled.stderr);
					assert.match(pulled.stderr, CERTIFICATE_REFUSAL, 'TLS stays end to end');
					console.log(`# the daemon said: ${lastLine(pulled.stderr)}`);
					assert.ok(
						proxy.events.some((event) => event.outcome === 'credential_verified'),
						'the proof was verified'
					);
					assert.ok(proxy.events.filter(answerOf).some((event) => event.outcome === 'tunnel'));
					assert.ok(
						tlsRegistry.serverNames.slice(names).includes('registry.ollama.ai'),
						"the daemon's own ClientHello crossed the relay"
					);
				} finally {
					await stop(started.run, started.ready);
					await proxy.close();
				}
			}
		);

		await signedIn(
			'real daemon: a refused relay keeps the daemon up, refuses the pull, inference answers',
			async () => {
				const proxy = await startFakeProxy({ mode: 'ntlm', upstream: { port: tlsRegistry.port } });
				const started = await start(environment(proxy, { HTTP_PROXY: '' }), {
					netOnly: netOnly.wrong
				});
				try {
					assert.equal(started.ready.receipt.proxy_tunnel, 'relay_refused');
					assert.equal(started.ready.receipt.proxy_relay, 'sign_in_rejected');
					const pulled = await runtime.pull(profile, started.run, started.ready, 'tiny:latest', {
						environment: started.environment
					});
					assert.equal(pulled.code, 3, pulled.stderr);
					assert.match(pulled.stderr, /proxy_relay sign_in_rejected/);
					await generate(started.run, 'tiny:latest');
				} finally {
					await stop(started.run, started.ready);
					await proxy.close();
				}
			}
		);

		await check(
			'real daemon: a socks override reaches the registry through the socks proxy',
			async () => {
				const socks = await startFakeSocks5Proxy({ upstream: { port: tlsRegistry.port } });
				const names = tlsRegistry.serverNames.length;
				const started = await start(
					environment(openProxy, { HTTP_PROXY: '', ERGOPTI_PROXY_OVERRIDE: socks.url })
				);
				try {
					const pulled = await runtime.pull(profile, started.run, started.ready, 'tiny:latest', {
						environment: started.environment
					});
					assert.equal(pulled.code, 1, pulled.stderr);
					assert.match(pulled.stderr, CERTIFICATE_REFUSAL);
					assert.ok(socks.events.some(answerOf), JSON.stringify(socks.events));
					assert.ok(tlsRegistry.serverNames.slice(names).includes('registry.ollama.ai'));
				} finally {
					await stop(started.run, started.ready);
					await socks.close();
				}
			}
		);

		await check(
			'real daemon: an https override makes the daemon judge the proxy certificate',
			async () => {
				const identity = selfSignedCertificate('fake-proxy.invalid', 'ecdsa');
				const secure = await startFakeProxy({
					mode: 'open',
					upstream: { port: tlsRegistry.port },
					identity
				});
				const started = await start(
					environment(openProxy, { HTTP_PROXY: '', ERGOPTI_PROXY_OVERRIDE: secure.url })
				);
				try {
					const pulled = await runtime.pull(profile, started.run, started.ready, 'tiny:latest', {
						environment: started.environment
					});
					assert.equal(pulled.code, 1, pulled.stderr);
					assert.match(pulled.stderr, CERTIFICATE_REFUSAL);
					console.log(`# the daemon said: ${lastLine(pulled.stderr)}`);
					assert.equal(secure.events.length, 0, 'no tunnel opens on a proxy it does not trust');
				} finally {
					await stop(started.run, started.ready);
					await secure.close();
				}
			}
		);
	} finally {
		await openProxy.close();
		await registry.close();
		profile.dispose();
	}
}

module.exports = { findRealRelease, releaseHome, runRealDaemonCases, STAMP_NAME };
