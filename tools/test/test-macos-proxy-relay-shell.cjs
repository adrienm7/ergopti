// tools/test/test-macos-proxy-relay-shell.cjs

/**
 * ==============================================================================
 * MODULE: macOS Ollama Daemon Under The Proxy Sign-In Relay
 * DESCRIPTION:
 * Runs the REAL run_with_proxy_sign_in_relay of network-retry.sh under bash
 * with a scripted relay beside a modelled launcher, the way the stock daemon
 * start uses it (modules/llm/ollama_server_command.lua). Pins that a proxy
 * that demands NTLM or Negotiate starts the daemon under `relay run`, that
 * every other answer starts it directly, and that the shell reads the probe
 * line exactly as the Lua policy does: the same shared vectors
 * (proxy_auth_relay_probe_vectors.json) give the same verdicts. Neither the
 * proxy nor the token may reach the log.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const SCRIPT = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'macos',
	'ai',
	'engine',
	'bootstrap',
	'network-retry.sh'
);
const VECTORS = JSON.parse(
	fs.readFileSync(
		path.join(SHARED, 'tests', 'corpus', 'network', 'proxy_auth_relay_probe_vectors.json'),
		'utf8'
	)
).vectors;
const COMMAND = fs.readFileSync(
	path.join(
		ROOT,
		'static',
		'ergopti_plus',
		'macos',
		'ai',
		'engine',
		'ollama',
		'server_command.lua'
	),
	'utf8'
);
const PROXY = 'http://proxy.corp.example:3128';
const REGISTRY = 'https://registry.ollama.ai';
const bash = bashExecutable();
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-relay-shell-'));
process.on('exit', () => fs.rmSync(scratch, { recursive: true, force: true }));

const launcher = path.join(scratch, 'ErgoptiPlus.app', 'Contents', 'MacOS', 'ErgoptiPlus');
const relay = path.join(path.dirname(launcher), 'ergopti-proxy-relay');
const calls = path.join(scratch, 'relay-calls');
const receipt = path.join(scratch, 'caches', 'proxy_relay_refusal');
/** The closed reason the last start recorded for the pull, or null. */
const recordedRefusal = () => (fs.existsSync(receipt) ? fs.readFileSync(receipt, 'utf8') : null);
fs.mkdirSync(path.dirname(launcher), { recursive: true });
fs.writeFileSync(launcher, '#!/bin/sh\nexit 0\n', { mode: 0o755 });

/** Installs a relay that answers its probe from the environment and runs its child. */
function installRelay() {
	fs.writeFileSync(
		relay,
		`#!/usr/bin/env bash
printf '%s\\n' "$*" >> '${calls}'
if [ "$1" = probe ]; then printf '%s' "$FAKE_PROBE_STDOUT"; exit "$FAKE_PROBE_EXIT"; fi
while [ "$1" != -- ]; do shift; done; shift
HTTPS_PROXY=http://ergopti:token@127.0.0.1:1 exec "$@"
`,
		{ mode: 0o755 }
	);
}

/**
 * Runs the daemon command through the shell function.
 * @returns {{ status: number, stdout: string, stderr: string, calls: string[] }}
 */
function run({
	proxy = PROXY,
	stdout = '',
	exit = 0,
	timings = '10 20 30',
	origins = REGISTRY
} = {}) {
	fs.rmSync(calls, { force: true });
	const [dial, handshake, idle] = timings.split(' ');
	const script = [
		'set -u',
		`log_info() { printf 'INFO %s\\n' "$1" >&2; }`,
		`log_error() { printf 'ERROR %s\\n' "$1" >&2; }`,
		`. '${SCRIPT}'`,
		// The launcher identity is macOS stat; this replay admits the modelled bundle.
		'managed_bootstrap_launcher_available() { return 0; }',
		`ERGOPTI_PROXY_RELAY_DIAL_MS='${dial ?? ''}'; ERGOPTI_PROXY_RELAY_HANDSHAKE_MS='${handshake ?? ''}'; ERGOPTI_PROXY_RELAY_IDLE_MS='${idle ?? ''}'`,
		`run_with_proxy_sign_in_relay /usr/bin/env OLLAMA_HOST=127.0.0.1:1 bash -c 'printf "CHILD %s %s\\n" "$OLLAMA_HOST" "\${HTTPS_PROXY:-none}"'`
	].join('\n');
	const env = {
		PATH: process.env.PATH,
		ERGOPTI_LAUNCHER_EXECUTABLE: launcher.replace(/\\/g, '/'),
		OPAQUE_NETWORK_PAC_PROBE_URLS: origins,
		FAKE_PROBE_STDOUT: stdout,
		FAKE_PROBE_EXIT: String(exit)
	};
	if (proxy) env.HTTPS_PROXY = proxy;
	// The Windows Git Bash reads this as a POSIX path too.
	env.ERGOPTI_PROXY_RELAY_REFUSAL_FILE = receipt.replace(/\\/g, '/');
	// A receipt of a previous daemon start must never survive this one.
	fs.mkdirSync(path.dirname(receipt), { recursive: true });
	fs.writeFileSync(receipt, 'stale_reason\n');
	const result = spawnSync(bash, ['-c', script], { env, encoding: 'utf8' });
	assert.equal(result.error, undefined);
	return {
		status: result.status,
		stdout: result.stdout,
		stderr: result.stderr,
		calls: fs.existsSync(calls) ? fs.readFileSync(calls, 'utf8').trim().split('\n') : []
	};
}

let checks = 0;
function noSecret(result) {
	for (const secret of ['proxy.corp.example', 'token', 'registry.ollama.ai'])
		assert.equal(result.stderr.includes(secret), false, `the log names ${secret}`);
}

// The stock daemon command calls the function, with the registry deadlines.
assert.match(COMMAND, /"run_with_proxy_sign_in_relay \/usr\/bin\/env "/);
for (const key of ['dial', 'handshake', 'idle'])
	assert.match(
		COMMAND,
		new RegExp(`Timings\\.ms\\("adapters", "proxy_relay_${key}_timeout_ms"\\)`)
	);
checks++;

// No relay bundled: the daemon starts directly, and the log says why.
fs.rmSync(relay, { force: true });
let result = run();
assert.equal(result.stdout, `CHILD 127.0.0.1:1 ${PROXY}\n`);
assert.match(result.stderr, /not installed.*\(not_installed\)/);
assert.equal(recordedRefusal(), null, 'not installed refuses nothing');
noSecret(result);
checks++;

installRelay();
// Every shared vector is read as the Lua policy reads it.
for (const vector of VECTORS) {
	result = run({ stdout: vector.stdout.replace(/\n$/, ''), exit: vector.exit_code });
	if (vector.exit_code === -1) continue; // a relay that never ran is the not-installed case above
	assert.equal(result.status, 0, vector.id);
	assert.equal(result.calls[0].split(' ')[0], 'probe', vector.id);
	assert.equal(
		result.calls[0],
		`probe --upstream ${PROXY} --authority registry.ollama.ai:443 --dial-timeout-ms 10 --handshake-timeout-ms 20`,
		vector.id
	);
	if (vector.result?.status === 'required') {
		assert.equal(
			result.calls[1],
			`run --upstream ${PROXY} --variable HTTPS_PROXY --variable https_proxy --dial-timeout-ms 10 ` +
				'--handshake-timeout-ms 20 --idle-timeout-ms 30 -- /usr/bin/env OLLAMA_HOST=127.0.0.1:1 bash -c ' +
				'printf "CHILD %s %s\\n" "$OLLAMA_HOST" "${HTTPS_PROXY:-none}"',
			vector.id
		);
		assert.equal(result.stdout, 'CHILD 127.0.0.1:1 http://ergopti:token@127.0.0.1:1\n', vector.id);
		assert.equal(recordedRefusal(), null, vector.id);
	} else if (vector.result) {
		assert.equal(result.calls.length, 1, `${vector.id}: no relay run`);
		assert.equal(result.stdout, `CHILD 127.0.0.1:1 ${PROXY}\n`, vector.id);
		assert.equal(result.stderr, '', vector.id);
		assert.equal(recordedRefusal(), null, vector.id);
	} else {
		// A refused sign-in: no proxy for the daemon, a receipt for the pull.
		assert.equal(result.calls.length, 1, `${vector.id}: no relay run`);
		assert.equal(result.stdout, 'CHILD 127.0.0.1:1 none\n', vector.id);
		assert.match(
			result.stderr,
			new RegExp(`refused \\(${vector.reason}\\): the daemon starts without the proxy`),
			vector.id
		);
		assert.equal(recordedRefusal(), `${vector.reason}\n`, vector.id);
	}
	noSecret(result);
	checks++;
}

// Only a plain http relay without credentials is probed.
for (const proxy of [
	'',
	'http://user:secret@proxy.corp.example:3128',
	'socks5://proxy.corp.example:1080',
	'https://proxy.corp.example:3128'
]) {
	result = run({ proxy, stdout: '{"schema":1,"status":"required","scheme":"ntlm"}' });
	assert.deepEqual(result.calls, [], proxy);
	assert.equal(result.stdout, `CHILD 127.0.0.1:1 ${proxy || 'none'}\n`, proxy);
	checks++;
}

// Missing deadlines or registry are a named refusal before any probe.
for (const options of [
	{ timings: '10 20' },
	{ timings: '10 x 30' },
	{ origins: '' },
	{ origins: 'http://registry.ollama.ai' }
]) {
	result = run({ ...options, stdout: '{"schema":1,"status":"required","scheme":"ntlm"}' });
	assert.deepEqual(result.calls, [], JSON.stringify(options));
	assert.match(result.stderr, /\(relay_unavailable\)/);
	assert.equal(result.stdout, 'CHILD 127.0.0.1:1 none\n');
	assert.equal(recordedRefusal(), 'relay_unavailable\n');
	checks++;
}

/**
 * Lists what a child sees of the proxy environment after one way of clearing it.
 * @param {string} body Shell lines run after sourcing the script.
 * @param {NodeJS.ProcessEnv} extra Environment of the sourcing shell.
 * @returns {string[]}
 */
function proxyEnvironmentAfter(body, extra = {}) {
	const script = ['set -u', `log_info() { :; }`, `log_error() { :; }`, `. '${SCRIPT}'`, body].join(
		'\n'
	);
	const inherited = { PATH: process.env.PATH, ...extra };
	for (const name of ['http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY'])
		inherited[name] = PROXY;
	inherited.all_proxy = PROXY;
	inherited.ALL_PROXY = PROXY;
	const result = spawnSync(bash, ['-c', script], { env: inherited, encoding: 'utf8' });
	assert.equal(result.status, 0, result.stderr);
	return result.stdout
		.split('\n')
		.filter((line) => /^[A-Za-z]+_(proxy|PROXY)=/.test(line))
		.sort();
}

// The direct override and a refused sign-in leave the same environment: no relay
// variable at all, set or empty, and every host excluded.
const NO_RELAY = ['NO_PROXY=*', 'no_proxy=*'];
assert.deepEqual(
	proxyEnvironmentAfter(`/usr/bin/env`, { ERGOPTI_PROXY_OVERRIDE: 'direct' }),
	NO_RELAY
);
checks++;
assert.deepEqual(
	proxyEnvironmentAfter(`start_without_proxy_after_refusal relay_unavailable '' /usr/bin/env`),
	NO_RELAY
);
checks++;
// The refused start clears its child only: the sourcing shell keeps its route.
assert.deepEqual(
	proxyEnvironmentAfter(
		`start_without_proxy_after_refusal relay_unavailable '' /usr/bin/env >/dev/null\n/usr/bin/env`
	).filter((line) => line.startsWith('HTTPS_PROXY=')),
	[`HTTPS_PROXY=${PROXY}`]
);
checks++;

console.log(
	`[OK] macOS daemon start under the proxy sign-in relay: ${checks} checks, shell and Lua read the same probe vectors.`
);
