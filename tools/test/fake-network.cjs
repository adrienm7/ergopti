// tools/test/fake-network.cjs

/**
 * ==============================================================================
 * MODULE: Fake Corporate Network Launcher
 * DESCRIPTION:
 * Runs the loopback proxy, PAC server and registry of lib/fake-network.cjs from a
 * shell, for a manual or a foreign-language check: prints one JSON line with every
 * address and the test credentials, then serves until stdin closes or Ctrl+C.
 *
 * USAGE:
 *   npm run tool:fake-network -- [--mode=ntlm] [--registry-mode=digest_mismatch]
 * ==============================================================================
 */

'use strict';

const {
	BASIC_CREDENTIAL,
	PROXY_MODES,
	TEST_CREDENTIAL,
	pacScript,
	startFakePacServer,
	startFakeProxy,
	startFakeRegistry
} = require('./lib/fake-network.cjs');

/** Reads one --name=value option. */
function option(name, fallback) {
	const prefix = `--${name}=`;
	const found = process.argv.slice(2).find((argument) => argument.startsWith(prefix));
	return found ? found.slice(prefix.length) : fallback;
}

async function main() {
	const mode = option('mode', 'ntlm');
	if (!PROXY_MODES.includes(mode))
		throw new TypeError(`--mode must be one of ${PROXY_MODES.join(', ')}`);
	const registry = await startFakeRegistry({ mode: option('registry-mode', 'ok') });
	const proxy = await startFakeProxy({ mode, upstream: { port: registry.port } });
	const pac = await startFakePacServer({ script: pacScript(`PROXY 127.0.0.1:${proxy.port}`) });
	const close = async () => {
		await Promise.all([proxy.close(), pac.close(), registry.close()]);
		process.exit(0);
	};
	process.on('SIGINT', close);
	process.on('SIGTERM', close);
	process.stdin.on('end', close);
	process.stdin.resume();
	console.log(
		JSON.stringify({
			proxy: proxy.url,
			mode,
			pac: pac.url,
			wpad: pac.wpadUrl,
			registry_port: registry.port,
			registry_certificate_sha256: registry.sha256,
			ntlm_credential: TEST_CREDENTIAL,
			basic_credential: BASIC_CREDENTIAL
		})
	);
}

main().catch((error) => {
	console.error(`[FAIL] Fake network: ${error.message}`);
	process.exit(1);
});
