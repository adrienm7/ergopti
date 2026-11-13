// tools/test/run-go-proxy-relay.cjs

/**
 * ==============================================================================
 * MODULE: Go Proxy Sign-In Relay Gate
 * DESCRIPTION:
 * Runs the Go tests of the local NTLM/Negotiate relay
 * (_shared/core/network/native/go/native_http/proxyrelay and cmd/ergopti-proxy-relay,
 * docs/design/proxy-auth-relay.md) offline, with the race detector and the
 * installed toolchain only. A missing toolchain or a run in which a required
 * test did not pass is a failure: "no test files" is never green. The real
 * GSS-API test needs cgo and the host's libgssapi_krb5; it must pass, not skip.
 * ==============================================================================
 */

'use strict';

const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const MODULE = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'core',
	'network',
	'native',
	'go',
	'native_http'
);
// The relay packages only: the module's other files are spliced into Ollama
// and need its dependencies (golang.org/x/sys), which this gate never fetches.
const PACKAGES = ['./proxyrelay/', './cmd/ergopti-proxy-relay/'];

// Every test the relay must answer; a renamed or skipped one fails the gate.
const REQUIRED_TESTS = [
	'TestProbeOutcomes',
	'TestNTLMStaysOnOneConnectionAndReconnectsOnlyBeforeAToken',
	'TestProbeDeadlinesAndUnreachable',
	'TestRelayTunnelsAfterSigningIn',
	'TestRelayRefusesClientsWithoutTheRunToken',
	'TestRelayRefusesPlainHTTPAndNamesUpstreamRefusals',
	'TestLoopbackPeerOnly',
	'TestContractMirrorsTheCanonicalJSON',
	'TestGSSWithoutATicketIsSignInUnavailable',
	'TestRunServesTheChildAndReturnsItsExitCode',
	'TestProbeLineMatchesTheSharedVectors'
];

/**
 * Lists the required tests a verbose `go test` transcript does not report as passed.
 * @param {string} transcript Combined stdout and stderr of `go test -v`.
 * @returns {string[]} Missing test names, empty when every one passed.
 */
function missingPasses(transcript) {
	return REQUIRED_TESTS.filter((name) => !transcript.includes(`--- PASS: ${name} (`));
}

/**
 * Runs the twin and returns the process exit code.
 * @param {object} [options]
 * @param {Function} [options.spawn] Injected spawnSync for the gate's own tests.
 * @returns {number}
 */
function run({ spawn = spawnSync } = {}) {
	// GOTOOLCHAIN=local never downloads a toolchain and GOPROXY=off never
	// fetches a module: the relay is standard-library only and CI stays offline.
	const result = spawn('go', ['test', '-race', '-count=1', '-v', ...PACKAGES], {
		cwd: MODULE,
		encoding: 'utf8',
		env: {
			...process.env,
			CGO_ENABLED: '1',
			GOTOOLCHAIN: 'local',
			GOPROXY: 'off',
			GOFLAGS: '-mod=readonly'
		}
	});
	if (result.error) {
		console.error(`[FAIL] Go proxy relay: the Go toolchain could not run (${result.error.code}).`);
		return 1;
	}
	const transcript = `${result.stdout || ''}${result.stderr || ''}`;
	if (result.status !== 0) {
		process.stderr.write(transcript);
		console.error(`[FAIL] Go proxy relay: go test exited with ${result.status}.`);
		return 1;
	}
	const missing = missingPasses(transcript);
	if (missing.length > 0) {
		process.stderr.write(transcript);
		console.error(`[FAIL] Go proxy relay: no passing run of ${missing.join(', ')}.`);
		return 1;
	}
	console.log(`[OK] Go proxy relay: ${REQUIRED_TESTS.length} required tests passed.`);
	return 0;
}

if (require.main === module) process.exitCode = run();

module.exports = { run, missingPasses, REQUIRED_TESTS };
