// tools/test/test-ollama-release-pin-parity.cjs

/**
 * ==============================================================================
 * MODULE: Ollama Release Pin Parity
 * DESCRIPTION:
 * One Ollama release is pinned for every driver: ollama_release.json owns the
 * official archives (Windows and Linux read it at runtime, macOS through its
 * generated shell projection) and managed_ollama_runtime.json owns the source
 * the macOS native HTTP build patches. Both must name the same release.
 *
 * ROOT CAUSE ENCODED:
 * Ollama 0.24.0 cannot pull qwen3.5 models. Ollama 0.40.4 deleted
 * server/internal/client/ollama/registry.go, moved x/transfer to transfer/ and
 * gave blob downloads a checked dialer that refuses non-public addresses. A
 * tree that kept any 0.24.0 asset digest, its source commit or its preimages,
 * or a producer that still named a removed seam, would keep pulling with the
 * old runtime or fail the native build. The native wrapper bypasses the checked
 * dialer, so the producer must route both transfer seams through WrapChecked.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const releaseGenerator = require('../codegen/codegen-ollama-release.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SELF = 'tools/test/test-ollama-release-pin-parity.cjs';
const RELEASE = 'static/ergopti_plus/_shared/modules/llm/ollama_release.json';
const RUNTIME = 'static/ergopti_plus/_shared/modules/llm/managed_ollama_runtime.json';
const PRODUCER = 'tools/build/build-macos-managed-ollama.py';
const BRIDGE = 'static/ergopti_plus/_shared/go/native_http';

// Independent transcription of the official v0.40.4 release (GitHub asset
// digests, cross-checked against its sha256sum.txt) and of its tag commit.
const PINNED = {
	version: '0.40.4',
	source_commit: '45e6011815c74acde6a346512856b69dd79dd22b',
	assets: {
		'macos-universal': [
			'a4ceae4b2aaf18df37ebcbfb56ba3a37a87838631112d66c2be07268693c8d58',
			167884528
		],
		'linux-amd64': ['15f31e9576d15a481e099b4145dba6e9f8c1f295927d6b8895300ae30ed3740a', 1436408810],
		'linux-arm64': ['1a314ac530d2c23bf6d2aaaf4a4aba8cc0b2a4ee8bc8fae3f3aa88bff7f7177b', 1555988008],
		'windows-amd64': [
			'7485a1172f8527db4342a63521b9342fc466185ff0855da378cc864ecf6354cf',
			1469916992
		],
		'windows-arm64': ['1fe50fb62ddcfc5fe102322e4a35043ccbf4e821adfa4ef41eee21af0aa158a7', 210017261]
	}
};

// Every 0.24.0 asset digest, its tag commit and the preimages of seams that
// 0.40.4 changed or removed. None may survive anywhere a driver or gate reads.
const RETIRED = [
	'e6d5e8b4bc0cb2a35ff7901c58d81ca2170403a819c4726f58798155fa682e38',
	'15c5f8d66ba06e0d3b4719df8868612dbd66e14e82760929bb3552e1657cdcdb',
	'6e9a3ce5f64e93312902e39c420ec336255f078a368ca25e99b339d08a6dfa4b',
	'40c523d3eeba6f4647c5ca58fe47f15b8dee79f7675ebf573458890064f424c7',
	'f248475a81a7dcd841a32e1f6c06c83310c893c49c4bdf7da8c10f3eef27231a',
	'c28ddc0a7b273cd286b680a6db0bef0c17bc0ec0',
	'6063de52240e9857334f8af210f71a3073b0b2bb8fac35c8df8b97494edf91c0',
	'4cc3da8d3cbeac187eea3bd89dcc10a191fc3d8de53a7c5c5074ba30243be21a',
	'517e83b75fa014fc3a3a9d23c316f71e10228e8d2f0c92323c627eb45e8d3887',
	'2621eef9e33b370d97a460eef80466654e4319ffea5ec0b94b3dbd79d5effd5e',
	'14ffbdd4c503e7c0fb314e221d6f430a90ad745e910fa601e6b543e4c6a00699',
	'e6ac73dca45ec039b45c640f2b29dca5a31561e6df514c10e37fe0281bedf627',
	'a6b997b339c1de4fcdaaa2e3266d3494863e391e429496973b7da5f05aa898db',
	'27f221ed12b312246074ac797952d26151b1b10f0e2731e3a42445665b950568'
];
const RETIRED_SEAMS = [
	'server/internal/client/ollama/registry.go',
	'x/transfer/download.go',
	'http.DefaultClient.Do(req)'
];

const read = (relative) => fs.readFileSync(path.join(ROOT, relative), 'utf8');
const release = JSON.parse(read(RELEASE));
const runtime = JSON.parse(read(RUNTIME));
const producer = read(PRODUCER);
let checks = 0;

function check(name, run) {
	run();
	checks += 1;
	console.log(`ok ${checks} - ${name}`);
}

check('the catalogue pins the reviewed official release', () => {
	assert.equal(release.version, PINNED.version);
	for (const [id, [sha256, bytes]] of Object.entries(PINNED.assets)) {
		assert.equal(release.assets[id].sha256, sha256, id);
		assert.equal(release.assets[id].bytes, bytes, id);
	}
	assert.deepEqual(Object.keys(release.assets).sort(), Object.keys(PINNED.assets).sort());
});

check('the macOS native source contract names the same release and tag commit', () => {
	assert.equal(runtime.version, release.version);
	assert.equal(runtime.source_commit, PINNED.source_commit);
});

check('the macOS shell projection is regenerated from the catalogue', () => {
	assert.deepEqual(releaseGenerator.generate(ROOT, { check: true }), [
		releaseGenerator.MACOS_OUTPUT
	]);
});

check('Windows and Linux read the catalogue at runtime instead of a copy', () => {
	assert.match(
		read('static/ergopti_plus/windows/modules/llm/ollama_managed_bootstrap.ahk'),
		/\\modules\\llm\\ollama_release\.json"/
	);
	assert.match(
		read('static/ergopti_plus/linux/modules/llm/ollama_install_resolver.lua'),
		/shared\("modules\/llm\/ollama_release\.json"\)/
	);
});

check('no tracked driver, tool or workflow keeps a retired 0.24.0 pin', () => {
	const tracked = execFileSync(
		'git',
		['ls-files', '-z', '--', 'static', 'tools', '.github', 'package.json'],
		{
			cwd: ROOT,
			encoding: 'utf8',
			maxBuffer: 256 * 1024 * 1024
		}
	)
		.split('\0')
		.filter((name) => name && name !== SELF && fs.existsSync(path.join(ROOT, name)));
	assert.ok(tracked.length > 1000, 'the tracked inventory must not be empty');
	const offenders = [];
	for (const name of tracked) {
		const bytes = fs.readFileSync(path.join(ROOT, name));
		if (bytes.includes(0)) continue;
		const text = bytes.toString('utf8');
		for (const literal of RETIRED)
			if (text.includes(literal)) offenders.push(`${name}: ${literal.slice(0, 12)}`);
	}
	assert.deepEqual(offenders, []);
});

check('the producer and its contract name no seam that Ollama 0.40.4 removed', () => {
	for (const seam of RETIRED_SEAMS) {
		assert.equal(producer.includes(seam), false, seam);
		assert.equal(Object.hasOwn(runtime.upstream_preimages, seam), false, seam);
		assert.equal(runtime.request_hook_paths.includes(seam), false, seam);
	}
	for (const hook of runtime.request_hook_paths)
		assert.ok(Object.hasOwn(runtime.upstream_preimages, hook), hook);
	assert.ok(runtime.request_hook_paths.includes('transfer/download.go'));
	// The ported address policy mirrors this file; an upstream edit must stop the build.
	assert.ok(Object.hasOwn(runtime.upstream_preimages, 'transfer/redirect.go'));
});

check('both checked transfer seams keep the address policy through WrapChecked', () => {
	assert.equal(producer.split('nativehttp.WrapChecked(').length - 1, 2);
	assert.match(
		producer,
		/WrapChecked\(client\.Transport, opts\.BaseURL, opts\.AllowPrivateHosts\)/
	);
	assert.match(producer, /WrapChecked\(client\.Transport, "", opts\.Insecure\)/);
	const policy = read(`${BRIDGE}/address_policy.go`);
	for (const network of ['"100.64.0.0/10"', '"198.18.0.0/15"'])
		assert.ok(policy.includes(network), network);
	assert.match(read(`${BRIDGE}/transport.go`), /if t\.Destination != nil \{/);
});

check('every native Go source joins the producer inventory', () => {
	const inventory = new Set(runtime.source_fingerprint_paths);
	const sources = fs
		.readdirSync(path.join(ROOT, BRIDGE))
		.filter((name) => name.endsWith('.go'))
		.map((name) => `${BRIDGE}/${name}`);
	assert.ok(sources.length > 10, 'the native bridge sources must be found');
	for (const source of sources) assert.ok(inventory.has(source), source);
	for (const test of [
		'TestDestinationPolicyRefusesNonPublicBeforeNativeWorker',
		'TestDestinationPolicyExplicitProxyHopBypassesCheckedDialer'
	])
		assert.ok(runtime.native_http_go_test_policy.required_passes.includes(test), test);
});

console.log(`# passed: ${checks}/${checks}`);
