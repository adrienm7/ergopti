// tools/test/test-ollama-release-pin-parity.cjs

/**
 * ==============================================================================
 * MODULE: Ollama Release Pin Parity
 * DESCRIPTION:
 * One Ollama release is pinned for every driver: ollama_release.json owns the
 * official archives (Windows and Linux read it at runtime) and
 * managed_ollama_runtime.json owns the source the macOS native HTTP build
 * patches. Both must name the same release.
 *
 * ROOT CAUSE ENCODED:
 * Ollama 0.24.0 cannot pull qwen3.5 models. Ollama 0.40.4 deleted
 * server/internal/client/ollama/registry.go, moved x/transfer to transfer/ and
 * gave blob downloads a checked dialer that refuses non-public addresses. A
 * tree that kept any 0.24.0 asset digest, its source commit or its preimages,
 * or a producer that still named a removed seam, would keep pulling with the
 * old runtime or fail the native build. The native wrapper bypasses the checked
 * dialer, so the producer must route both transfer seams through WrapChecked.
 * A generated macOS shell copy of the pin (ollama-release.sh) was read by
 * nothing and claimed the size only drove a progress bar, while every driver
 * refuses a wrong size; it was retired with its generator (OLL-12).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const { execFileSync } = require('node:child_process');
const generators = require('../build/generators.cjs');
const PinTool = require('../build/pin-ollama-release.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SELF = 'tools/test/test-ollama-release-pin-parity.cjs';
const RELEASE = 'static/ergopti_plus/_shared/ai/data/ollama_release.json';
const RUNTIME = 'static/ergopti_plus/_shared/ai/data/managed_ollama_runtime.json';
const PRODUCER = 'tools/build/build-macos-managed-ollama.py';
const BRIDGE = 'static/ergopti_plus/_shared/core/network/native/go/native_http';

// Independent transcription of the official v0.40.6 release (its sha256sum.txt,
// cross-checked by streaming each asset through SHA-256) and of its tag commit.
// The third value of an asset is its unpacked size. TODO(OLL-14): provisional,
// three times the archive, until tools/build/pin-ollama-release.cjs runs on the
// real archives in CI and its --write output replaces them.
const PINNED = {
	version: '0.40.6',
	source_commit: '2476d5ead197abe04629651028f83d48dc75d2b2',
	assets: {
		'macos-universal': [
			'b2b55434865a668decb494110d7fd970eed3ecc8837be2872f672ccbb95df974',
			174459907,
			523379721
		],
		'linux-amd64': [
			'c164ab8b1b28e2a247c29719b8e404c423c5b83ae64c3ab4e59d50c7ff7fc5e0',
			1438364593,
			4315093779
		],
		'linux-arm64': [
			'0a279d9428ad17b06fdb7dddf3b059b2c148433585fa3b30676a102fc459bb9f',
			1560414226,
			4681242678
		],
		'windows-amd64': [
			'e359637575302f288d76c0007c408a4be9c7376d59c4f28684d63b232a44b427',
			1471164488,
			4413493464
		],
		'windows-arm64': [
			'82cace1a134f88e7e7092dcf79304eff5950b88dbfabc03f19be09f8be20ee65',
			210482819,
			631448457
		]
	}
};

// Every 0.24.0 and 0.40.4 asset digest, their tag commits and the preimages of
// seams a later release changed or removed (0.40.4 fetched blob bytes outside
// the proxy). None may survive anywhere a driver or gate reads.
const RETIRED = [
	'a4ceae4b2aaf18df37ebcbfb56ba3a37a87838631112d66c2be07268693c8d58',
	'15f31e9576d15a481e099b4145dba6e9f8c1f295927d6b8895300ae30ed3740a',
	'1a314ac530d2c23bf6d2aaaf4a4aba8cc0b2a4ee8bc8fae3f3aa88bff7f7177b',
	'7485a1172f8527db4342a63521b9342fc466185ff0855da378cc864ecf6354cf',
	'1fe50fb62ddcfc5fe102322e4a35043ccbf4e821adfa4ef41eee21af0aa158a7',
	'45e6011815c74acde6a346512856b69dd79dd22b',
	'fe3ed501f8cc2779c681dbe24ca9efb4e2f3db7fed46c94f87aa0d873fe71fc4',
	'23b3202e270e8f3dba0c716c128529432db02e8b1e40e6d73c94345abf6cfde4',
	'd9299dd65146ba3dd5f4a5c7efe012795c763dcaa04ee6915086a2ac68665f0b',
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
	for (const [id, [sha256, bytes, unpacked]] of Object.entries(PINNED.assets)) {
		assert.equal(release.assets[id].sha256, sha256, id);
		assert.equal(release.assets[id].bytes, bytes, id);
		assert.equal(release.assets[id].unpacked_bytes, unpacked, id);
	}
	assert.deepEqual(Object.keys(release.assets).sort(), Object.keys(PINNED.assets).sort());
});

check('the macOS native source contract names the same release and tag commit', () => {
	assert.equal(runtime.version, release.version);
	assert.equal(runtime.source_commit, PINNED.source_commit);
});

check('no unread projection of the catalogue is generated (oll-12)', () => {
	const retired = 'static/ergopti_plus/macos/ai/engine/ollama/ollama-release.sh';
	assert.equal(fs.existsSync(path.join(ROOT, retired)), false, retired);
	assert.equal(fs.existsSync(path.join(ROOT, 'tools/codegen/codegen-ollama-release.cjs')), false);
	const outputs = generators.GENERATORS.flatMap((generator) => generator.outputs);
	assert.ok(outputs.length > 10, 'the generator inventory must be read');
	assert.equal(outputs.includes(retired), false, retired);
});

check('Windows and Linux read the catalogue at runtime instead of a copy', () => {
	assert.match(
		read('static/ergopti_plus/windows/ai/engine/ollama/managed_bootstrap.ahk'),
		/\\ai\\data\\ollama_release\.json"/
	);
	assert.match(
		read('static/ergopti_plus/linux/ai/engine/ollama/install_resolver.lua'),
		/shared\("ai\/data\/ollama_release\.json"\)/
	);
});

check('no tracked driver, tool or workflow keeps a retired 0.24.0 or 0.40.4 pin', () => {
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

check('every pinned asset names its unpacked size (oll-14)', () => {
	for (const [id, asset] of Object.entries(release.assets)) {
		assert.ok(Number.isSafeInteger(asset.unpacked_bytes) && asset.unpacked_bytes > 0, id);
	}
});

// ========================================
// ========================================
// ======= Synthetic Archives =======
// ========================================
// ========================================

/** One ustar header block, its checksum computed. */
function tarHeader(name, size, type, link = '') {
	const header = Buffer.alloc(512);
	header.write(name, 0, 100, 'utf8');
	header.write('0000644\0', 100, 'ascii');
	header.write('0001750\0', 108, 'ascii');
	header.write('0001750\0', 116, 'ascii');
	header.write(`${size.toString(8).padStart(11, '0')}\0`, 124, 'ascii');
	header.write('00000000000\0', 136, 'ascii');
	header.write('        ', 148, 'ascii');
	header.write(type, 156, 'ascii');
	header.write(link, 157, 100, 'utf8');
	header.write('ustar\u000000', 257, 'ascii');
	let sum = 0;
	for (const byte of header) sum += byte;
	header.write(`${sum.toString(8).padStart(6, '0')}\0 `, 148, 'ascii');
	return header;
}

/** A tar entry: its header and its data padded to whole blocks. */
function tarEntry(name, data, type = '0', link = '') {
	const body = Buffer.from(data);
	const padding = Buffer.alloc((512 - (body.length % 512)) % 512);
	return Buffer.concat([tarHeader(name, body.length, type, link), body, padding]);
}

/** One pax record, its length prefix counting itself. */
function paxRecord(key, value) {
	const text = ` ${key}=${value}\n`;
	let length = text.length;
	while (`${length}${text}`.length !== length) length = `${length}${text}`.length;
	return `${length}${text}`;
}

// A folder, two files, a symlink and a hard link (no bytes), a GNU long name and
// a pax size record that overrides its header's zero size: 1000+70000+5+300.
const LONG_NAME = `lib/${'n'.repeat(120)}.so`;
const TAR = Buffer.concat([
	tarEntry('lib/', '', '5'),
	tarEntry('ollama', Buffer.alloc(1000, 1)),
	tarEntry('lib/libggml.so', Buffer.alloc(70000, 2)),
	tarEntry('lib/link.so', '', '2', 'libggml.so'),
	tarEntry('ollama-hard', '', '1', 'ollama'),
	tarEntry('././@LongLink', `${LONG_NAME}\0`, 'L'),
	tarEntry(LONG_NAME.slice(0, 99), Buffer.alloc(5, 3)),
	tarEntry('PaxHeaders/big', paxRecord('size', 300), 'x'),
	Buffer.concat([tarHeader('lib/big.so', 0, '0'), Buffer.alloc(300, 4), Buffer.alloc(212)]),
	Buffer.alloc(1024)
]);
const TAR_UNPACKED = 1000 + 70000 + 5 + 300;

/** A zip of deflated entries and a folder, with its central directory. */
function zipArchive(entries) {
	const locals = [];
	const central = [];
	let offset = 0;
	for (const [name, data] of entries) {
		const raw = Buffer.from(data);
		const packed = name.endsWith('/') ? raw : zlib.deflateRawSync(raw);
		const method = name.endsWith('/') ? 0 : 8;
		const fields = Buffer.alloc(16);
		fields.writeUInt32LE(zlib.crc32(raw), 0);
		fields.writeUInt32LE(packed.length, 4);
		fields.writeUInt32LE(raw.length, 8);
		const nameBytes = Buffer.from(name, 'utf8');
		const local = Buffer.alloc(30);
		local.writeUInt32LE(0x04034b50, 0);
		local.writeUInt16LE(20, 4);
		local.writeUInt16LE(method, 8);
		fields.copy(local, 14, 0, 12);
		local.writeUInt16LE(nameBytes.length, 26);
		const record = Buffer.alloc(46);
		record.writeUInt32LE(0x02014b50, 0);
		record.writeUInt16LE(20, 4);
		record.writeUInt16LE(20, 6);
		record.writeUInt16LE(method, 10);
		fields.copy(record, 16, 0, 12);
		record.writeUInt16LE(nameBytes.length, 28);
		record.writeUInt32LE(offset, 42);
		locals.push(local, nameBytes, packed);
		central.push(record, nameBytes);
		offset += local.length + nameBytes.length + packed.length;
	}
	const directory = Buffer.concat(central);
	const end = Buffer.alloc(22);
	end.writeUInt32LE(0x06054b50, 0);
	end.writeUInt16LE(entries.length, 8);
	end.writeUInt16LE(entries.length, 10);
	end.writeUInt32LE(directory.length, 12);
	end.writeUInt32LE(offset, 16);
	return Buffer.concat([...locals, directory, end]);
}

const ZIP = zipArchive([
	['lib/', ''],
	['ollama.exe', Buffer.alloc(4096, 7)],
	['lib/ollama/ggml.dll', Buffer.alloc(20000, 9)]
]);
const ZIP_UNPACKED = 4096 + 20000;

async function asyncCheck(name, run) {
	await run();
	checks += 1;
	console.log(`ok ${checks} - ${name}`);
}

async function main() {
	const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ollama-pin-'));
	try {
		const files = {
			'ollama-windows-amd64.zip': ZIP,
			'ollama-darwin.tgz': zlib.gzipSync(TAR),
			'ollama-linux-amd64.tar.zst': zlib.zstdCompressSync(TAR)
		};
		for (const [name, data] of Object.entries(files))
			fs.writeFileSync(path.join(folder, name), data);
		const digest = (data) => crypto.createHash('sha256').update(data).digest('hex');

		await asyncCheck(
			'the pin tool sums the unpacked files of a zip, a tgz and a tar.zst (oll-14)',
			async () => {
				for (const [name, data] of Object.entries(files)) {
					const measured = await PinTool.measureArchive(path.join(folder, name), name);
					assert.equal(measured.sha256, digest(data), name);
					assert.equal(measured.bytes, data.length, name);
					assert.equal(
						measured.unpacked_bytes,
						name.endsWith('.zip') ? ZIP_UNPACKED : TAR_UNPACKED,
						name
					);
					assert.ok(measured.unpacked_bytes > data.length, `${name} unpacks beyond its archive`);
				}
			}
		);

		await asyncCheck(
			'the pin tool checks then writes the measured fields only (oll-14)',
			async () => {
				const catalogue = path.join(folder, 'ollama_release.json');
				const assets = {};
				for (const [name, data] of Object.entries(files)) {
					assets[name] = {
						filename: name,
						sha256: digest(data),
						bytes: data.length,
						unpacked_bytes: 1
					};
				}
				fs.writeFileSync(
					catalogue,
					JSON.stringify({ schema_version: 1, version: '0.0.1', assets })
				);
				const refused = await PinTool.pin({ catalogue, archives: folder, write: false });
				assert.equal(refused.length, 3);
				assert.ok(refused.every((line) => line.includes('.unpacked_bytes: pinned 1, measured')));
				assert.equal(
					JSON.parse(fs.readFileSync(catalogue, 'utf8')).assets['ollama-darwin.tgz'].unpacked_bytes,
					1
				);
				await PinTool.pin({ catalogue, archives: folder, write: true });
				const written = JSON.parse(fs.readFileSync(catalogue, 'utf8'));
				assert.equal(written.assets['ollama-windows-amd64.zip'].unpacked_bytes, ZIP_UNPACKED);
				assert.equal(written.assets['ollama-linux-amd64.tar.zst'].unpacked_bytes, TAR_UNPACKED);
				assert.equal(written.version, '0.0.1');
				assert.deepEqual(await PinTool.pin({ catalogue, archives: folder, write: false }), []);
			}
		);

		await asyncCheck('the pin tool refuses a truncated or altered archive (oll-14)', async () => {
			const truncated = path.join(folder, 'truncated.tgz');
			fs.writeFileSync(truncated, zlib.gzipSync(TAR.subarray(0, 4096)));
			await assert.rejects(PinTool.measureArchive(truncated), /before its end marker/);
			const altered = Buffer.from(TAR);
			altered[0] ^= 1;
			const corrupt = path.join(folder, 'corrupt.tgz');
			fs.writeFileSync(corrupt, zlib.gzipSync(altered));
			await assert.rejects(PinTool.measureArchive(corrupt), /checksum/);
			const zip64 = Buffer.from(ZIP);
			zip64.writeUInt32LE(0xffffffff, zip64.length - 6);
			const wide = path.join(folder, 'wide.zip');
			fs.writeFileSync(wide, zip64);
			await assert.rejects(PinTool.measureArchive(wide), /zip64/);
		});
	} finally {
		fs.rmSync(folder, { recursive: true, force: true });
	}
	console.log(`# passed: ${checks}/${checks}`);
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
