// tools/test/test-managed-proxy-route-contract.cjs

/**
 * ==============================================================================
 * MODULE: Managed Ollama PAC Route Contract
 * DESCRIPTION:
 * An Ollama daemon that Ergopti starts on macOS reads only HTTPS_PROXY, so a
 * Mac whose only proxy source is a company PAC could never pull a model. The
 * launcher role `--managed-proxy-route` resolves the registry through the
 * system (CFNetwork, PAC and WPAD included) and network-retry.sh exports the
 * first route it names. The Swift cannot be compiled on this host: this gate
 * pins its source contract, then runs the REAL shell policy under bash against
 * a fake launcher to prove the admission and the exported variables.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const root = path.resolve(__dirname, '..', '..');
const driver = path.join(root, 'static', 'ergopti_plus', 'macos');
const sources = path.join(driver, 'launcher', 'Sources', 'ErgoptiPlus');
const read = (file) => fs.readFileSync(file, 'utf8');
const posix = (file) => file.split(path.sep).join('/');

let passed = 0;
const check = (label, action) => {
	try {
		action();
	} catch (error) {
		error.message = `${label}: ${error.message}`;
		throw error;
	}
	passed++;
};

const worker = read(path.join(sources, 'ManagedProxyRouteWorker.swift'));
const main = read(path.join(sources, 'main.swift'));
const swiftTests = read(
	path.join(driver, 'launcher', 'Tests', 'ErgoptiPlusTests', 'ManagedProxyRouteWorkerTests.swift')
);
const policyText = read(path.join(driver, 'modules', 'llm', 'network-retry.sh'));
const proxyPolicy = JSON.parse(
	read(
		path.join(root, 'static', 'ergopti_plus', '_shared', 'modules', 'network', 'proxy_policy.json')
	)
);
const stages = JSON.parse(
	read(
		path.join(
			root,
			'static',
			'ergopti_plus',
			'_shared',
			'modules',
			'network',
			'native_http_failure_stages.json'
		)
	)
).stages;

// ===========================================================
// ===== 1/ The Swift role, pinned to its shared sources =====
// ===========================================================

check('the role flag is the one the shell calls', () => {
	assert.match(worker, /static let flag = "--managed-proxy-route"/);
	assert.ok(policyText.includes('--managed-proxy-route'));
});

check('main.swift dispatches the role before any application startup', () => {
	const dispatch = main.indexOf(
		'ManagedProxyRouteWorker.handles(arguments: CommandLine.arguments)'
	);
	assert.ok(dispatch > 0, 'the role must be dispatched');
	assert.ok(
		dispatch < main.indexOf('OwnedAutomationQueryWorker.handles(arguments: CommandLine.arguments)'),
		'it is a headless role, dispatched with the other managed workers'
	);
	assert.match(
		main,
		/Darwin\.exit\(ManagedProxyRouteWorker\.run\(arguments: CommandLine\.arguments\)\)/
	);
});

check('the selection bound is the shared max_selections', () => {
	const bound = /static let maximumSelections = (\d+)/.exec(worker);
	assert.ok(bound, 'the bound must be a named constant');
	assert.equal(Number(bound[1]), proxyPolicy.max_selections);
});

check('its failure stages exist in the shared closed inventory', () => {
	for (const symbol of ['routeEmpty', 'proxyDictionary']) {
		assert.ok(worker.includes(`ManagedHTTPFailureStage.${symbol}`), symbol);
		assert.ok(
			stages.some((stage) => stage.symbol === symbol),
			symbol
		);
	}
});

check('the refusal exit code is the one the shell policy treats as a refusal', () => {
	const shell = /OPAQUE_NETWORK_REFUSAL_EXIT_CODE=(\d+)/.exec(policyText);
	const swift = /static let unusableExit: Int32 = (\d+)/.exec(worker);
	assert.ok(shell && swift);
	assert.equal(swift[1], shell[1]);
});

check('the role never writes an address to stderr or a log', () => {
	assert.ok(
		!/Logger|NSLog|LauncherLog/.test(worker),
		'no logger: stdout is the route, stderr a stage code'
	);
	const stderrWrites = worker.match(/standardError\.write\([^\n]*\)/g) || [];
	assert.equal(stderrWrites.length, 1);
	assert.ok(stderrWrites[0].includes('"STAGE "'), 'only a stage code reaches stderr');
});

check('only http and socks5 routes with a safe host and a port range are exported', () => {
	assert.match(worker, /scheme = "http"/);
	assert.match(worker, /scheme = "socks5"/);
	assert.match(worker, /\(1\.\.\.65535\)\.contains\(port\.intValue\)/);
	assert.match(worker, /isSafeHost\(host\)/);
});

check('the XCTest file covers the exportable and the refused shapes', () => {
	for (const name of [
		'testDirectRouteIsExportedAsDirect',
		'testHttpAndHttpsProxiesBecomeAnHttpProxyUrl',
		'testSocksProxyBecomesSocks5AndIPv6IsBracketed',
		'testHostThatCouldSmuggleAnotherUrlIsRefused',
		'testPortOutsideTheRangeOrMissingIsRefused',
		'testOriginMustBeAnHttpsUrlWithoutCredentials',
		'testArgumentsOutsideTheContractAreAUsageError',
		'testUnreadableSettingsExitWithTheLookupStage',
		'testAStaticPacScriptSelectsTheFirstRoute',
		'testAPacThatSaysDirectIsExportedAsDirect'
	]) {
		assert.ok(swiftTests.includes(`func ${name}()`), name);
	}
});

// ===========================================================
// ===== 2/ The shell policy, run for real against a fake =====
// ===========================================================

const bash = bashExecutable();
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-route-'));
const launcher = path.join(scratch, 'fake-launcher.sh');
const argumentsLog = path.join(scratch, 'launcher-arguments.txt');
fs.writeFileSync(
	launcher,
	[
		'#!/bin/sh',
		'printf "%s\\n" "$*" >> "$FAKE_ARGUMENTS_LOG"',
		'if [ "$FAKE_LAUNCHER_STATUS" = 0 ]; then printf "%s\\n" "$FAKE_LAUNCHER_OUTPUT"; exit 0; fi',
		'printf "%s\\n" "$FAKE_LAUNCHER_OUTPUT" >&2',
		'exit "$FAKE_LAUNCHER_STATUS"',
		''
	].join('\n'),
	{ mode: 0o755 }
);

/**
 * Sources the real policy and runs one admission against the fake launcher.
 * @param {object} options
 * @param {'opaque'|'static'} options.mode Which admission runs.
 * @param {boolean} [options.probe] Whether the caller names the registry origin.
 * @param {string} [options.output] What the fake launcher prints.
 * @param {number} [options.status] The fake launcher's exit status.
 * @param {string} [options.relay] An explicit HTTPS_PROXY the caller exported.
 * @param {boolean} [options.launcherAvailable] Whether the launcher identity check passes.
 * @returns {{ code: number, stdout: string, stderr: string, calls: string }}
 */
function admission(options) {
	fs.rmSync(argumentsLog, { force: true });
	const snapshot =
		options.mode === 'opaque'
			? 'printf "%s\\n" "<dictionary> {" " ProxyAutoConfigEnable : 1" "}"'
			: 'printf "%s\\n" "<dictionary> {" " ProxyAutoConfigEnable : 1" " ProxyAutoConfigURLString : http://pac.example/proxy.pac" "}"';
	const script = [
		`log_info() { printf '[T] %s\\n' "$1" >&2; }`,
		`log_error() { printf '[T] %s\\n' "$1" >&2; }`,
		options.probe === false ? '' : `OPAQUE_NETWORK_PAC_PROBE_URL='https://registry.ollama.ai'`,
		`. '${posix(path.join(driver, 'modules', 'llm', 'network-retry.sh'))}'`,
		`managed_bootstrap_launcher_available() { return ${options.launcherAvailable === false ? 1 : 0}; }`,
		`opaque_system_proxy_snapshot() { ${snapshot}; }`,
		`ERGOPTI_LAUNCHER_EXECUTABLE='${posix(launcher)}'`,
		options.mode === 'opaque' ? 'apply_system_network opaque' : 'apply_system_network',
		'status=$?',
		'printf "RESULT|%s|%s|%s|%s\\n" "$status" "${HTTPS_PROXY-unset}" "${https_proxy-unset}" "${NO_PROXY-unset}"',
		'exit "$status"'
	].join('\n');
	const environment = { ...process.env };
	for (const name of [
		'http_proxy',
		'HTTP_PROXY',
		'https_proxy',
		'HTTPS_PROXY',
		'all_proxy',
		'ALL_PROXY',
		'no_proxy',
		'NO_PROXY'
	]) {
		delete environment[name];
	}
	if (options.relay) environment.HTTPS_PROXY = options.relay;
	environment.FAKE_ARGUMENTS_LOG = posix(argumentsLog);
	environment.FAKE_LAUNCHER_OUTPUT = options.output ?? '';
	environment.FAKE_LAUNCHER_STATUS = String(options.status ?? 0);
	const result = spawnSync(bash, ['-c', script], { env: environment, encoding: 'utf8' });
	assert.equal(result.error, undefined, String(result.error));
	return {
		code: result.status,
		stdout: result.stdout,
		stderr: result.stderr,
		calls: fs.existsSync(argumentsLog) ? fs.readFileSync(argumentsLog, 'utf8') : '',
		result: /RESULT\|(\d+)\|([^|]*)\|([^|]*)\|(.*)/.exec(result.stdout)
	};
}

const REFUSAL = 'cannot be used by this client. No download was started.';

try {
	check('a PAC resolved to a relay admits the pull and exports HTTPS_PROXY', () => {
		const run = admission({ mode: 'opaque', output: 'ROUTE http://relay.corp:3128' });
		assert.equal(run.code, 0, run.stderr);
		assert.equal(run.result[2], 'http://relay.corp:3128');
		assert.equal(run.result[3], 'http://relay.corp:3128');
		assert.equal(run.result[4], 'localhost,127.0.0.1,::1', 'loopback never goes through the relay');
		assert.equal(run.calls.trim(), '--managed-proxy-route https://registry.ollama.ai 20');
		assert.ok(!run.stderr.includes('relay.corp'), 'the route is never logged');
		assert.ok(
			!/proxy/i.test(run.stderr),
			'a normal line never carries the word the classifier matches'
		);
	});

	check('a SOCKS route is exported for Go to dial', () => {
		const run = admission({ mode: 'opaque', output: 'ROUTE socks5://10.0.0.2:1080' });
		assert.equal(run.code, 0, run.stderr);
		assert.equal(run.result[2], 'socks5://10.0.0.2:1080');
	});

	check('a PAC that answers DIRECT admits the pull with no proxy', () => {
		const run = admission({ mode: 'opaque', output: 'ROUTE direct' });
		assert.equal(run.code, 0, run.stderr);
		assert.equal(run.result[2], 'unset');
		assert.equal(run.result[3], 'unset');
		assert.equal(run.result[4], 'localhost,127.0.0.1,::1');
	});

	check('a lookup that fails keeps the refusal and names only the stage', () => {
		const run = admission({ mode: 'opaque', status: 78, output: 'STAGE native_pac_download' });
		assert.equal(run.code, 78);
		assert.ok(run.stderr.includes('native_pac_download'), run.stderr);
		assert.ok(run.stderr.includes(REFUSAL), run.stderr);
		assert.ok(!run.stdout.includes('RESULT|0'));
	});

	check('without a named origin the launcher is never asked and the pull stays refused', () => {
		const run = admission({ mode: 'opaque', probe: false, output: 'ROUTE http://relay.corp:3128' });
		assert.equal(run.code, 78);
		assert.equal(run.calls, '', 'a client that names no origin gets no lookup');
		assert.ok(run.stderr.includes(REFUSAL));
	});

	check('an unavailable launcher keeps the refusal', () => {
		const run = admission({ mode: 'opaque', launcherAvailable: false, output: 'ROUTE direct' });
		assert.equal(run.code, 78);
		assert.equal(run.calls, '');
	});

	check('a relay the caller exported wins and no lookup runs', () => {
		const run = admission({
			mode: 'opaque',
			relay: 'http://explicit.corp:8080',
			output: 'ROUTE http://other.corp:3128'
		});
		assert.equal(run.code, 0, run.stderr);
		assert.equal(run.result[2], 'http://explicit.corp:8080');
		assert.equal(run.calls, '');
	});

	check('a route that cannot be exported is refused, not guessed', () => {
		for (const output of [
			'ROUTE http://a b.example:1',
			'ROUTE ftp://relay.corp:21',
			'ROUTE',
			'garbage',
			''
		]) {
			const run = admission({ mode: 'opaque', output });
			assert.equal(run.code, 78, `${JSON.stringify(output)}: ${run.stderr}`);
			assert.equal(run.result[2], 'unset', JSON.stringify(output));
		}
	});

	check('the daemon start exports the resolved relay', () => {
		const run = admission({ mode: 'static', output: 'ROUTE http://relay.corp:3128' });
		assert.equal(run.code, 0, run.stderr);
		assert.equal(run.result[2], 'http://relay.corp:3128');
		assert.equal(run.calls.trim(), '--managed-proxy-route https://registry.ollama.ai 20');
	});

	check('the daemon still starts when the lookup fails, for the models on disk', () => {
		const run = admission({ mode: 'static', status: 78, output: 'STAGE native_pac_evaluation' });
		assert.equal(run.code, 0, run.stderr);
		assert.equal(run.result[2], 'unset');
		assert.ok(run.stderr.includes('native_pac_evaluation'), run.stderr);
	});

	check('the daemon start without a named origin never calls the launcher', () => {
		const run = admission({ mode: 'static', probe: false, output: 'ROUTE http://relay.corp:3128' });
		assert.equal(run.code, 0, run.stderr);
		assert.equal(run.calls, '');
		assert.equal(run.result[2], 'unset');
	});
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}

console.log(`\x1b[32m[OK] Managed Ollama PAC route contract (${passed} checks).\x1b[0m`);
