// tools/test/test-fake-network.cjs

/**
 * ==============================================================================
 * MODULE: Fake Corporate Network Controls
 * DESCRIPTION:
 * Proves the fake network can tell right from wrong, so a green end-to-end run
 * means something: a wrong NTLM password is refused and the right one tunnels,
 * each proxy mode ends the way it claims, the registry can break a digest, the PAC
 * server answers, nothing binds beyond loopback and close() really closes.
 * Runs on every OS, with no real network and no relay binary.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const http = require('node:http');
const net = require('node:net');
const tls = require('node:tls');
const {
	BASIC_CREDENTIAL,
	NTLM_CHALLENGE,
	PROXY_MODES,
	TEST_CREDENTIAL,
	md4,
	ntlmClientType3,
	ntlmType2,
	pacScript,
	startFakeOllamaRegistry,
	startFakePacServer,
	startFakeProxy,
	startFakeRegistry,
	verifyNtlmV2
} = require('./lib/fake-network.cjs');
const { buildTinyGguf } = require('./lib/tiny-gguf.cjs');

const STEP_TIMEOUT_MS = 5000;

/** One keep-alive client: sends a head, reads one proxy answer. */
function client(port) {
	const socket = net.connect(port, '127.0.0.1');
	let buffered = '';
	let closed = false;
	const waiters = [];
	const settle = () => {
		const end = buffered.indexOf('\r\n\r\n');
		while (waiters.length && (end >= 0 || closed)) {
			const head = end >= 0 ? buffered.slice(0, end) : '';
			buffered = end >= 0 ? buffered.slice(end + 4) : buffered;
			waiters.shift()(head);
			return;
		}
	};
	socket.on('data', (chunk) => {
		buffered += chunk.toString('latin1');
		settle();
	});
	socket.on('close', () => {
		closed = true;
		settle();
	});
	socket.on('error', () => {});
	return {
		socket,
		send(authorization = '') {
			const header = authorization ? `Proxy-Authorization: ${authorization}\r\n` : '';
			socket.write(
				`CONNECT registry.example:443 HTTP/1.1\r\nHost: registry.example:443\r\n${header}\r\n`
			);
			return new Promise((resolve, reject) => {
				const timer = setTimeout(
					() => reject(new Error('no proxy answer in time')),
					STEP_TIMEOUT_MS
				);
				waiters.push((head) => {
					clearTimeout(timer);
					resolve(head);
				});
				settle();
			});
		}
	};
}

/** Runs the whole NTLM exchange with one credential and returns the final status line. */
async function ntlmExchange(port, credential) {
	const peer = client(port);
	const first = await peer.send();
	assert.match(first, /^HTTP\/1\.1 407/, 'no token: the proxy demands a sign-in');
	assert.match(first, /Proxy-Authenticate: NTLM\r?$/m, 'a bare challenge first');
	const type1 = Buffer.concat([Buffer.from('NTLMSSP\0', 'latin1'), Buffer.from([1, 0, 0, 0])]);
	const second = await peer.send(`NTLM ${type1.toString('base64')}`);
	const challenge = /Proxy-Authenticate: NTLM (\S+)/.exec(second);
	assert.ok(challenge, 'type 1 is answered by a type 2');
	const type2 = Buffer.from(challenge[1], 'base64');
	assert.equal(type2.readUInt32LE(8), 2);
	assert.ok(type2.subarray(24, 32).equals(NTLM_CHALLENGE), 'the challenge is the fixed one');
	const type3 = ntlmClientType3(credential, type2.subarray(24, 32));
	const third = await peer.send(`NTLM ${type3.toString('base64')}`);
	peer.socket.destroy();
	return third.split('\r\n')[0];
}

async function testNtlm() {
	// The RFC 1320 vector of MD4 and the published NT hash of "password".
	assert.equal(md4(Buffer.from('abc')).toString('hex'), 'a448017aaf21d8525fc10ae87aa6729d');
	assert.equal(
		md4(Buffer.from('password', 'utf16le')).toString('hex'),
		'8846f7eaee8fb117ad06bdd830b7586c'
	);
	const good = ntlmClientType3(TEST_CREDENTIAL, NTLM_CHALLENGE);
	assert.ok(verifyNtlmV2(good, TEST_CREDENTIAL), 'the known credential verifies');
	const bad = ntlmClientType3({ ...TEST_CREDENTIAL, password: 'wrong' }, NTLM_CHALLENGE);
	assert.ok(!verifyNtlmV2(bad, TEST_CREDENTIAL), 'a wrong password does not');
	const other = ntlmClientType3(TEST_CREDENTIAL, Buffer.from('ffffffffffffffff', 'hex'));
	assert.ok(!verifyNtlmV2(other, TEST_CREDENTIAL), 'nor an answer to another challenge');
	assert.equal(ntlmType2().readUInt32LE(8), 2);

	const proxy = await startFakeProxy({ mode: 'ntlm' });
	try {
		assert.match(
			await ntlmExchange(proxy.port, TEST_CREDENTIAL),
			/ 200 /,
			'the right password tunnels'
		);
		assert.ok(proxy.events.some((event) => event.outcome === 'credential_verified'));
		assert.match(
			await ntlmExchange(proxy.port, { ...TEST_CREDENTIAL, password: 'wrong' }),
			/ 407 /,
			'a wrong password stays refused'
		);
		assert.ok(proxy.events.some((event) => event.outcome === 'rejected'));
		proxy.setMode('ntlm_logon');
		assert.match(
			await ntlmExchange(proxy.port, { ...TEST_CREDENTIAL, password: 'any' }),
			/ 200 /,
			'the logon twin only reads the shape'
		);
		const serialized = JSON.stringify(proxy.events);
		assert.ok(
			!serialized.includes('NTLMSSP') && !serialized.includes(TEST_CREDENTIAL.user),
			'no token or name is recorded'
		);
	} finally {
		await proxy.close();
	}
}

async function testModes() {
	const expectations = {
		open: / 200 /,
		basic: / 407 /,
		digest: / 407 /,
		refusing: / 403 /
	};
	const proxy = await startFakeProxy({ mode: 'open', slowMs: 400 });
	try {
		for (const [mode, status] of Object.entries(expectations)) {
			proxy.setMode(mode);
			const peer = client(proxy.port);
			assert.match(await peer.send(), status, mode);
			peer.socket.destroy();
		}
		proxy.setMode('basic');
		const authorized = client(proxy.port);
		const value = Buffer.from(`${BASIC_CREDENTIAL.user}:${BASIC_CREDENTIAL.password}`).toString(
			'base64'
		);
		assert.match(await authorized.send(`Basic ${value}`), / 200 /, 'the Basic credential tunnels');
		authorized.socket.destroy();

		proxy.setMode('slow');
		const started = Date.now();
		const held = client(proxy.port);
		assert.match(await held.send(), / 504 /);
		assert.ok(Date.now() - started >= 350, 'slow holds its answer');
		held.socket.destroy();

		proxy.setMode('drop');
		const dropped = client(proxy.port);
		assert.equal(await dropped.send(), '', 'drop ends the connection with no answer');

		proxy.setMode('ntlm_drop');
		const after = client(proxy.port);
		await after.send();
		const type1 = Buffer.concat([Buffer.from('NTLMSSP\0', 'latin1'), Buffer.from([1, 0, 0, 0])]);
		assert.equal(
			await after.send(`NTLM ${type1.toString('base64')}`),
			'',
			'ntlm_drop ends after the type 1'
		);

		assert.throws(() => proxy.setMode('nope'), /Unknown fake proxy mode/);
		for (const mode of PROXY_MODES) proxy.setMode(mode);
	} finally {
		await proxy.close();
	}
	const { port } = proxy;
	const refused = await new Promise((resolve) => {
		const socket = net.connect(port, '127.0.0.1');
		socket.on('error', (error) => resolve(error.code));
		socket.on('connect', () => resolve('connected'));
	});
	assert.equal(refused, 'ECONNREFUSED', 'close() really closes');
}

/** One HTTP request over TLS with the certificate pinned, through an open tunnel. */
function fetchThroughProxy(proxyPort, registry, target) {
	return new Promise((resolve, reject) => {
		const socket = net.connect(proxyPort, '127.0.0.1');
		socket.on('error', reject);
		socket.write('CONNECT registry.ollama.ai:443 HTTP/1.1\r\nHost: registry.ollama.ai:443\r\n\r\n');
		socket.once('data', (head) => {
			assert.match(String(head), / 200 /);
			const secure = tls.connect(
				{ socket, rejectUnauthorized: false, servername: 'registry.ollama.ai' },
				() => {
					const pin = crypto
						.createHash('sha256')
						.update(secure.getPeerCertificate().raw)
						.digest('hex');
					assert.equal(pin, registry.sha256, 'the pin names the fake registry');
					secure.write(
						`GET ${target} HTTP/1.1\r\nHost: registry.ollama.ai\r\nConnection: close\r\n\r\n`
					);
				}
			);
			let body = Buffer.alloc(0);
			secure.on('data', (chunk) => {
				body = Buffer.concat([body, chunk]);
			});
			secure.on('error', reject);
			secure.on('end', () => {
				socket.destroy();
				resolve(body.subarray(body.indexOf('\r\n\r\n') + 4));
			});
		});
	});
}

async function testRegistry() {
	const registry = await startFakeRegistry();
	const proxy = await startFakeProxy({ mode: 'open', upstream: { port: registry.port } });
	try {
		const manifest = JSON.parse(
			await fetchThroughProxy(proxy.port, registry, '/v2/library/stub/manifests/latest')
		);
		const { digest } = manifest.layers[0];
		const blob = await fetchThroughProxy(proxy.port, registry, `/v2/library/stub/blobs/${digest}`);
		assert.equal(`sha256:${crypto.createHash('sha256').update(blob).digest('hex')}`, digest);
		registry.setMode('digest_mismatch');
		const broken = await fetchThroughProxy(
			proxy.port,
			registry,
			`/v2/library/stub/blobs/${digest}`
		);
		assert.notEqual(
			`sha256:${crypto.createHash('sha256').update(broken).digest('hex')}`,
			digest,
			'digest_mismatch really breaks the digest'
		);
		assert.ok(proxy.events.every((event) => event.authority === 'registry.ollama.ai:443'));
	} finally {
		await proxy.close();
		await registry.close();
	}
}

/** A GET the way a client behind an HTTP proxy sends it, in absolute form. */
function plainProxyGet(port, target) {
	return new Promise((resolve, reject) => {
		http
			.get(
				{ host: '127.0.0.1', port, path: target, headers: { host: 'registry.ollama.ai' } },
				(reply) => {
					const chunks = [];
					reply.on('data', (chunk) => chunks.push(chunk));
					reply.on('end', () =>
						resolve({
							status: reply.statusCode,
							location: reply.headers.location,
							body: Buffer.concat(chunks)
						})
					);
				}
			)
			.on('error', reject);
	});
}

async function testOllamaRegistry() {
	const layer = { mediaType: 'application/vnd.ollama.image.model', bytes: buildTinyGguf() };
	assert.deepEqual(layer.bytes, buildTinyGguf(), 'the model is the same bytes on every run');
	assert.equal(layer.bytes.subarray(0, 4).toString('latin1'), 'GGUF');
	assert.notDeepEqual(layer.bytes, buildTinyGguf('other'), 'another name is another blob');
	const config = { mediaType: 'application/json', bytes: Buffer.from('{}') };
	const registry = await startFakeOllamaRegistry({ config, layers: [layer] });
	const proxy = await startFakeProxy({ mode: 'open', plainUpstream: { port: registry.port } });
	const base = 'http://registry.ollama.ai/v2/library/tiny';
	try {
		const manifest = JSON.parse(
			(await plainProxyGet(proxy.port, `${base}/manifests/latest`)).body.toString('utf8')
		);
		const { digest } = manifest.layers[0];
		const redirect = await plainProxyGet(proxy.port, `${base}/blobs/${digest}`);
		assert.equal(redirect.status, 307, 'the daemon demands a storage URL');
		const storage = new URL(redirect.location);
		const stored = await plainProxyGet(storage.port, storage.pathname);
		assert.equal(`sha256:${crypto.createHash('sha256').update(stored.body).digest('hex')}`, digest);
		registry.setMode('digest_mismatch');
		const broken = await plainProxyGet(storage.port, storage.pathname);
		assert.notEqual(
			`sha256:${crypto.createHash('sha256').update(broken.body).digest('hex')}`,
			digest
		);
		assert.equal(broken.body.length, stored.body.length, 'a mismatch keeps the size');
		assert.deepEqual(
			registry.requests.map((row) => row.proxied),
			[true, true, false, false],
			'the registry tells what came through the proxy'
		);
		proxy.setMode('refusing');
		const refused = await plainProxyGet(proxy.port, `${base}/manifests/latest`);
		assert.equal(refused.status, 405, 'only open mode forwards');
	} finally {
		await proxy.close();
		await registry.close();
	}
}

async function testPac() {
	// A route outside the PAC grammar never becomes script text.
	for (const route of ['PROXY a"; b:1', 'DIRECT\\', '', 'PROXY host'])
		assert.throws(() => pacScript(route), /is not a PAC route/, JSON.stringify(route));
	assert.equal(
		pacScript('PROXY 127.0.0.1:3128; DIRECT'),
		'function FindProxyForURL(url, host) { return "PROXY 127.0.0.1:3128; DIRECT"; }\n'
	);
	const pac = await startFakePacServer({ script: pacScript('PROXY 127.0.0.1:3128') });
	const read = (url) =>
		new Promise((resolve, reject) => {
			http
				.get(url, (response) => {
					let body = '';
					response.on('data', (chunk) => (body += chunk));
					response.on('end', () => resolve({ status: response.statusCode, body }));
				})
				.on('error', reject);
		});
	try {
		for (const url of [pac.url, pac.wpadUrl]) {
			const { status, body } = await read(url);
			assert.equal(status, 200);
			assert.match(body, /PROXY 127\.0\.0\.1:3128/);
		}
		pac.setScript('', 503);
		assert.equal((await read(pac.url)).status, 503, 'a broken PAC server is available');
		assert.deepEqual(pac.requests, ['/proxy.pac', '/wpad.dat', '/proxy.pac']);
	} finally {
		await pac.close();
	}
}

async function main() {
	await testNtlm();
	await testModes();
	await testRegistry();
	await testOllamaRegistry();
	await testPac();
	console.log(
		`[OK] Fake network: ${PROXY_MODES.length} proxy modes, NTLMv2 verification, registry and PAC checked.`
	);
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
