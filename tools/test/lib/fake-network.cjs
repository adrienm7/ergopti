// tools/test/lib/fake-network.cjs

/**
 * ==============================================================================
 * MODULE: Fake Corporate Network
 * DESCRIPTION:
 * Loopback stand-ins for what a company network puts between a client and a
 * model registry: an HTTP CONNECT proxy (open, Basic, NTLM, Negotiate, refusing,
 * slow, dropping), over plain TCP or TLS, a SOCKS5 proxy (open or username), a
 * PAC/WPAD file server, an Ollama-like registry over TLS and a Perplexity-like
 * Agent API.
 *
 * FEATURES & RATIONALE:
 * 1. Every listener binds 127.0.0.1 on an ephemeral port, so there is no firewall
 *    prompt, no collision with a real service and no real network: a CONNECT is
 *    only ever tunneled to the configured loopback upstream, whatever it names.
 * 2. The NTLM exchange is real: a fixed type 2 challenge and a full NTLMv2
 *    verification of the type 3 against a known test credential, so a client that
 *    computes the wrong answer is refused the way a domain would refuse it.
 * 3. A sign-in token is never stored or logged: events carry closed outcome names.
 *    The "*_logon" modes check only the shape of a type 3, for the case where the
 *    client signs in as the real user and no password is known.
 * 4. Every close() ends open sockets, so a test cannot hang on a tunnel.
 * ==============================================================================
 */

'use strict';

const crypto = require('node:crypto');
const http = require('node:http');
const net = require('node:net');
const tls = require('node:tls');

const LOOPBACK = '127.0.0.1';
const HEAD_LIMIT_BYTES = 32768;
const DEFAULT_SLOW_MS = 30000;

// The fixed type 2 server challenge and the known credential of the fake domain.
const NTLM_CHALLENGE = Buffer.from('0123456789abcdef', 'hex');
const NTLM_SIGNATURE = Buffer.from('NTLMSSP\0', 'latin1');
// UNICODE, REQUEST_TARGET, SIGN, SEAL, NTLM, ALWAYS_SIGN, TARGET_TYPE_DOMAIN,
// EXTENDED_SESSIONSECURITY, TARGET_INFO, VERSION, 128, KEY_EXCH, 56: what a real
// server answers.
const NTLM_TYPE2_FLAGS = 0xe2898235;
const TEST_CREDENTIAL = Object.freeze({
	domain: 'FAKECORP',
	user: 'relay-test',
	password: 'Known-Test-Password-1'
});
const BASIC_CREDENTIAL = Object.freeze({ user: 'basic-test', password: 'Known-Basic-Password-1' });

/**
 * Every proxy mode, each with the authentication it demands and how it ends.
 * ntlm and negotiate verify the known credential; the *_logon twins accept any
 * well-formed type 3; *_slow and *_drop misbehave after the first challenge.
 */
const PROXY_MODES = Object.freeze([
	'open',
	'basic',
	'ntlm',
	'ntlm_logon',
	'ntlm_slow',
	'ntlm_drop',
	'negotiate',
	'negotiate_logon',
	'negotiate_lowercase',
	'digest',
	'refusing',
	'slow',
	'drop'
]);

// ====================================
// ======= 1/ NTLM primitives =========
// ====================================

/**
 * MD4, which NTLM requires and which OpenSSL 3 no longer offers by default.
 * @param {Buffer} message The input.
 * @returns {Buffer} The 16-byte digest.
 */
const { md4 } = require('../../lib/md4.cjs');

const hmacMd5 = (key, ...parts) => {
	const hmac = crypto.createHmac('md5', key);
	for (const part of parts) hmac.update(part);
	return hmac.digest();
};

/**
 * NTOWFv2: the NTLMv2 key of one credential.
 * @param {{domain: string, user: string, password: string}} credential The identity.
 * @returns {Buffer} The response key.
 */
function ntlmV2Key({ domain, user, password }) {
	const hash = md4(Buffer.from(password, 'utf16le'));
	return hmacMd5(hash, Buffer.from(user.toUpperCase() + domain, 'utf16le'));
}

/**
 * Builds the fixed type 2 challenge, with a target info list as a real server sends.
 * @returns {Buffer} The message.
 */
function ntlmType2() {
	const target = Buffer.from(TEST_CREDENTIAL.domain, 'utf16le');
	const pair = (id, value) => {
		const head = Buffer.alloc(4);
		head.writeUInt16LE(id, 0);
		head.writeUInt16LE(value.length, 2);
		return Buffer.concat([head, value]);
	};
	// A fixed time keeps the message fixed; a real server sends its clock.
	const timestamp = Buffer.alloc(8);
	timestamp.writeBigUInt64LE(133000000000000000n);
	const info = Buffer.concat([
		pair(2, target),
		pair(1, Buffer.from('FAKEPROXY', 'utf16le')),
		pair(7, timestamp),
		pair(0, Buffer.alloc(0))
	]);
	const size = 56;
	const header = Buffer.alloc(size);
	NTLM_SIGNATURE.copy(header);
	header.writeUInt32LE(2, 8);
	header.writeUInt16LE(target.length, 12);
	header.writeUInt16LE(target.length, 14);
	header.writeUInt32LE(size, 16);
	header.writeUInt32LE(NTLM_TYPE2_FLAGS, 20);
	NTLM_CHALLENGE.copy(header, 24);
	header.writeUInt16LE(info.length, 40);
	header.writeUInt16LE(info.length, 42);
	header.writeUInt32LE(size + target.length, 44);
	return Buffer.concat([header, target, info]);
}

/**
 * Reads the fields of a type 3 that the verification needs.
 * @param {Buffer} message The token.
 * @returns {{response: Buffer, domain: string, user: string}|null} Null when malformed.
 */
function parseType3(message) {
	if (
		message.length < 64 ||
		!message.subarray(0, 8).equals(NTLM_SIGNATURE) ||
		message.readUInt32LE(8) !== 3
	)
		return null;
	const field = (offset) => {
		const length = message.readUInt16LE(offset);
		const start = message.readUInt32LE(offset + 4);
		return start + length > message.length ? null : message.subarray(start, start + length);
	};
	const response = field(20);
	const domain = field(28);
	const user = field(36);
	if (!response || !domain || !user || response.length < 24) return null;
	return {
		response,
		domain: domain.toString('utf16le'),
		user: user.toString('utf16le')
	};
}

/**
 * Verifies an NTLMv2 type 3 against the fixed challenge and a known credential.
 * @param {Buffer} message The token.
 * @param {{domain: string, user: string, password: string}} credential The identity.
 * @returns {boolean} True when the proof matches.
 */
function verifyNtlmV2(message, credential) {
	const parsed = parseType3(message);
	if (!parsed || parsed.user.toUpperCase() !== credential.user.toUpperCase()) return false;
	const proof = parsed.response.subarray(0, 16);
	const blob = parsed.response.subarray(16);
	const key = ntlmV2Key({ ...credential, domain: parsed.domain });
	return crypto.timingSafeEqual(proof, hmacMd5(key, NTLM_CHALLENGE, blob));
}

/**
 * The client side of the exchange, for the tool's own controls: an NTLMv2 type 3
 * for a challenge. Production never computes this; SSPI does.
 * @param {{domain: string, user: string, password: string}} credential The identity.
 * @param {Buffer} challenge The server challenge.
 * @returns {Buffer} The message.
 */
function ntlmClientType3(credential, challenge) {
	const blob = Buffer.concat([
		Buffer.from('0101000000000000', 'hex'),
		Buffer.alloc(8),
		crypto.randomBytes(8),
		Buffer.alloc(8)
	]);
	const proof = hmacMd5(ntlmV2Key(credential), challenge, blob);
	const response = Buffer.concat([proof, blob]);
	const domain = Buffer.from(credential.domain, 'utf16le');
	const user = Buffer.from(credential.user, 'utf16le');
	const header = Buffer.alloc(64);
	NTLM_SIGNATURE.copy(header);
	header.writeUInt32LE(3, 8);
	const place = (offset, value, start) => {
		header.writeUInt16LE(value.length, offset);
		header.writeUInt16LE(value.length, offset + 2);
		header.writeUInt32LE(start, offset + 4);
	};
	place(20, response, 64);
	place(28, domain, 64 + response.length);
	place(36, user, 64 + response.length + domain.length);
	return Buffer.concat([header, response, domain, user]);
}

/** The first NTLM message type in a token, raw or wrapped in SPNEGO; 0 if none. */
function ntlmMessageType(token) {
	const at = token.indexOf(NTLM_SIGNATURE);
	return at < 0 || at + 12 > token.length ? 0 : token.readUInt32LE(at + 8);
}

/** Wraps a DER value under one tag; lengths up to 64 KiB are all this needs. */
function der(tag, ...values) {
	const body = Buffer.concat(values);
	const length =
		body.length < 0x80
			? Buffer.from([body.length])
			: body.length < 0x100
				? Buffer.from([0x81, body.length])
				: Buffer.from([0x82, body.length >> 8, body.length & 0xff]);
	return Buffer.concat([Buffer.from([tag]), length, body]);
}

/** The SPNEGO NegTokenResp that carries a type 2 back to a Negotiate client. */
function spnegoChallenge(type2) {
	const ntlmOid = Buffer.from('2b06010401823702020a', 'hex');
	return der(
		0xa1,
		der(
			0x30,
			der(0xa0, der(0x0a, Buffer.from([1]))),
			der(0xa1, der(0x06, ntlmOid)),
			der(0xa2, der(0x04, type2))
		)
	);
}

// ===================================
// ======= 2/ The CONNECT proxy ======
// ===================================

/** What one CONNECT sent, from its raw head. */
function parseHead(text) {
	const lines = text.split('\r\n');
	const [method, target] = lines[0].split(' ');
	const headers = {};
	for (const line of lines.slice(1)) {
		const colon = line.indexOf(':');
		if (colon > 0)
			headers[line.slice(0, colon).trim().toLowerCase()] = line.slice(colon + 1).trim();
	}
	return { method, target, headers };
}

/** The status line, headers and empty body of a proxy answer. */
function answer(status, reason, headers = []) {
	return `HTTP/1.1 ${status} ${reason}\r\n${[...headers, 'Content-Length: 0'].join('\r\n')}\r\n\r\n`;
}

/**
 * Starts the proxy.
 * @param {object} [options]
 * @param {string} [options.mode] One of PROXY_MODES.
 * @param {{host?: string, port: number}} [options.upstream] Where a tunnel goes.
 * @param {{port: number}} [options.plainUpstream] Where open mode forwards a plain
 *     http request; without it such a request is refused with a 405.
 * @param {number} [options.slowMs] How long the slow modes hold their answer.
 * @param {object} [options.credential] The NTLM identity to verify.
 * @param {object} [options.identity] selfSignedCertificate(): serves TLS, an https relay.
 * @returns {Promise<object>} { port, url, events, setMode, close }; with an
 *     identity also sha256, the digest a client pins.
 */
async function startFakeProxy({
	mode = 'open',
	upstream = null,
	plainUpstream = null,
	slowMs = DEFAULT_SLOW_MS,
	credential = TEST_CREDENTIAL,
	identity = null
} = {}) {
	const state = { mode };
	const events = [];
	const sockets = new Set();
	const timers = new Set();
	const assertMode = (name) => {
		if (!PROXY_MODES.includes(name)) throw new TypeError(`Unknown fake proxy mode: ${name}`);
	};
	assertMode(mode);

	const openTunnel = (socket, authority, leftover) => {
		events.push({ type: 'connect', authority, outcome: 'tunnel' });
		socket.removeAllListeners('data');
		// Paused until the pipe below: a ClientHello sent right after the 200 would
		// otherwise be read by nobody and lost.
		socket.pause();
		socket.write('HTTP/1.1 200 Connection established\r\n\r\n');
		if (!upstream) {
			socket.resume();
			return;
		}
		const target = net.connect(upstream.port, LOOPBACK, () => {
			if (leftover.length) target.write(leftover);
			socket.pipe(target);
			target.pipe(socket);
		});
		sockets.add(target);
		target.on('close', () => {
			sockets.delete(target);
			socket.destroy();
		});
		target.on('error', () => socket.destroy());
		socket.on('close', () => target.destroy());
	};

	// A plain http request in absolute form, the shape an HTTP proxy sees: forwarded
	// to the loopback upstream, whatever host it names, marked as having come this way.
	const forwardPlain = (socket, request) => {
		events.push({ type: 'forward', url: request.target, outcome: 'forwarded' });
		const target = new URL(request.target);
		const upstreamRequest = http.request(
			{
				host: LOOPBACK,
				port: plainUpstream.port,
				method: request.method,
				path: `${target.pathname}${target.search}`,
				headers: { ...request.headers, 'x-fake-proxy': 'forwarded', connection: 'close' }
			},
			(reply) => {
				const head = Object.entries(reply.headers)
					.filter(([name]) => name !== 'connection' && name !== 'transfer-encoding')
					.map(([name, value]) => `${name}: ${value}`);
				socket.write(
					`HTTP/1.1 ${reply.statusCode} ${reply.statusMessage}\r\n${[...head, 'Connection: close'].join('\r\n')}\r\n\r\n`
				);
				reply.pipe(socket);
			}
		);
		upstreamRequest.on('error', () => socket.destroy());
		upstreamRequest.end();
	};

	const signInStep = (socket, request, authority, scheme, leftover) => {
		const current = state.mode;
		const value = request.headers['proxy-authorization'];
		const logon = current.endsWith('_logon');
		const challengeLine = (token) => `Proxy-Authenticate: ${scheme}${token ? ` ${token}` : ''}`;
		if (!value || !value.toLowerCase().startsWith(`${scheme.toLowerCase()} `)) {
			events.push({ type: 'connect', authority, outcome: 'demand_sign_in' });
			socket.write(
				answer(407, 'Proxy Authentication Required', [challengeLine(''), 'Connection: keep-alive'])
			);
			return;
		}
		const token = Buffer.from(value.slice(scheme.length + 1), 'base64');
		const kind = ntlmMessageType(token);
		if (kind === 1) {
			events.push({ type: 'sign_in', step: 'type1', scheme });
			if (current === 'ntlm_drop') {
				events.push({ type: 'connect', authority, outcome: 'dropped' });
				socket.destroy();
				return;
			}
			if (current === 'ntlm_slow') {
				events.push({ type: 'connect', authority, outcome: 'held' });
				return;
			}
			const type2 = ntlmType2();
			// SSPI's Negotiate without a domain sends a raw NTLM message and refuses a
			// wrapped answer (SEC_E_INVALID_TOKEN, seen live): the answer follows the
			// client's own framing, as a real server's does.
			const framed = token.indexOf(NTLM_SIGNATURE) > 0;
			const wrapped = framed ? spnegoChallenge(type2) : type2;
			socket.write(
				answer(407, 'Proxy Authentication Required', [
					challengeLine(wrapped.toString('base64')),
					'Connection: keep-alive'
				])
			);
			return;
		}
		if (kind === 3) {
			const message = token.subarray(token.indexOf(NTLM_SIGNATURE));
			const accepted = logon ? parseType3(message) !== null : verifyNtlmV2(message, credential);
			events.push({
				type: 'sign_in',
				step: 'type3',
				scheme,
				outcome: accepted ? (logon ? 'shape_accepted' : 'credential_verified') : 'rejected'
			});
			if (accepted) {
				openTunnel(socket, authority, leftover);
				return;
			}
		} else {
			events.push({ type: 'sign_in', step: 'foreign_token', scheme, outcome: 'rejected' });
		}
		socket.write(
			answer(407, 'Proxy Authentication Required', [challengeLine(''), 'Connection: close'])
		);
		socket.end();
	};

	const handleRequest = (socket, request, leftover) => {
		const authority = request.target;
		const current = state.mode;
		if (request.method !== 'CONNECT' && plainUpstream && current === 'open') {
			forwardPlain(socket, request);
			return;
		}
		if (request.method !== 'CONNECT') {
			events.push({ type: 'request', method: request.method, outcome: 'refused' });
			socket.end(answer(405, 'Method Not Allowed', ['Connection: close']));
			return;
		}
		switch (current) {
			case 'open':
				openTunnel(socket, authority, leftover);
				return;
			case 'basic': {
				const expected = Buffer.from(
					`${BASIC_CREDENTIAL.user}:${BASIC_CREDENTIAL.password}`
				).toString('base64');
				if (request.headers['proxy-authorization'] === `Basic ${expected}`) {
					openTunnel(socket, authority, leftover);
					return;
				}
				events.push({ type: 'connect', authority, outcome: 'demand_basic' });
				socket.write(
					answer(407, 'Proxy Authentication Required', [
						'Proxy-Authenticate: Basic realm="fake"',
						'Connection: keep-alive'
					])
				);
				return;
			}
			case 'digest':
				events.push({ type: 'connect', authority, outcome: 'demand_digest' });
				socket.end(
					answer(407, 'Proxy Authentication Required', [
						'Proxy-Authenticate: Digest realm="fake", nonce="fixed"',
						'Connection: close'
					])
				);
				return;
			case 'ntlm':
			case 'ntlm_logon':
			case 'ntlm_slow':
			case 'ntlm_drop':
				signInStep(socket, request, authority, 'NTLM', leftover);
				return;
			case 'negotiate':
			case 'negotiate_logon':
				signInStep(socket, request, authority, 'Negotiate', leftover);
				return;
			case 'negotiate_lowercase':
				events.push({ type: 'connect', authority, outcome: 'demand_sign_in' });
				socket.end(
					'HTTP/1.1 407 Proxy Authentication Required\r\nproxy-authenticate: negotiate\r\nConnection: close\r\n\r\n'
				);
				return;
			case 'refusing':
				events.push({ type: 'connect', authority, outcome: 'refused' });
				socket.end(answer(403, 'Forbidden', ['Connection: close']));
				return;
			case 'slow': {
				events.push({ type: 'connect', authority, outcome: 'held' });
				const timer = setTimeout(() => {
					timers.delete(timer);
					socket.end(answer(504, 'Gateway Timeout', ['Connection: close']));
				}, slowMs);
				timers.add(timer);
				return;
			}
			case 'drop':
				events.push({ type: 'connect', authority, outcome: 'dropped' });
				socket.destroy();
				return;
			default:
				throw new TypeError(`Unhandled fake proxy mode: ${current}`);
		}
	};

	const onConnection = (socket) => {
		sockets.add(socket);
		let buffered = Buffer.alloc(0);
		socket.on('close', () => sockets.delete(socket));
		socket.on('error', () => {});
		socket.on('data', (chunk) => {
			buffered = Buffer.concat([buffered, chunk]);
			for (;;) {
				const end = buffered.indexOf('\r\n\r\n');
				if (end < 0) {
					if (buffered.length > HEAD_LIMIT_BYTES) socket.destroy();
					return;
				}
				const head = buffered.subarray(0, end).toString('latin1');
				buffered = buffered.subarray(end + 4);
				handleRequest(socket, parseHead(head), buffered);
				if (socket.destroyed || socket.listenerCount('data') === 0) return;
			}
		});
	};
	const server = identity
		? tls.createServer({ key: identity.key, cert: identity.cert }, onConnection)
		: net.createServer(onConnection);
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, LOOPBACK, resolve);
	});
	const { port } = server.address();
	return {
		port,
		url: `${identity ? 'https' : 'http'}://${LOOPBACK}:${port}`,
		...(identity ? { sha256: identity.sha256 } : {}),
		events,
		setMode(next) {
			assertMode(next);
			state.mode = next;
			events.length = 0;
		},
		close: () => closeServer(server, sockets, timers)
	};
}

/** Closes one listener and everything it still holds open. */
function closeServer(server, sockets, timers = new Set()) {
	for (const timer of timers) clearTimeout(timer);
	timers.clear();
	for (const socket of sockets) socket.destroy();
	return new Promise((resolve) => server.close(() => resolve()));
}

/**
 * Starts a SOCKS5 relay (RFC 1928, username method of RFC 1929). As with the
 * CONNECT proxy, a tunnel only ever reaches the loopback upstream.
 * @param {object} options
 * @param {{port: number}} options.upstream Where a tunnel goes.
 * @param {{user: string, password: string}} [options.credential] Demands this login.
 * @returns {Promise<object>} { port, url, events, close }.
 */
async function startFakeSocks5Proxy({ upstream, credential = null }) {
	const events = [];
	const sockets = new Set();
	const server = net.createServer((socket) => {
		sockets.add(socket);
		socket.on('close', () => sockets.delete(socket));
		socket.on('error', () => {});
		let buffered = Buffer.alloc(0);
		let step = 'greeting';
		const take = (count) => {
			if (buffered.length < count) return null;
			const head = buffered.subarray(0, count);
			buffered = buffered.subarray(count);
			return head;
		};
		const greeting = () => {
			if (buffered.length < 2 || buffered.length < 2 + buffered[1]) return false;
			const methods = [...take(2 + buffered[1]).subarray(2)];
			const method = credential ? 2 : 0;
			if (!methods.includes(method)) {
				events.push({ type: 'connect', outcome: 'no_method' });
				socket.end(Buffer.from([5, 0xff]));
				return false;
			}
			socket.write(Buffer.from([5, method]));
			step = credential ? 'login' : 'request';
			return true;
		};
		const login = () => {
			if (buffered.length < 2) return false;
			const nameLength = buffered[1];
			if (buffered.length < 3 + nameLength) return false;
			const secretLength = buffered[2 + nameLength];
			if (buffered.length < 3 + nameLength + secretLength) return false;
			const frame = take(3 + nameLength + secretLength);
			const user = frame.subarray(2, 2 + nameLength).toString('utf8');
			const password = frame.subarray(3 + nameLength).toString('utf8');
			const accepted = user === credential.user && password === credential.password;
			events.push({ type: 'sign_in', outcome: accepted ? 'credential_verified' : 'rejected' });
			if (!accepted) {
				socket.end(Buffer.from([1, 1]));
				return false;
			}
			socket.write(Buffer.from([1, 0]));
			step = 'request';
			return true;
		};
		const request = () => {
			if (buffered.length < 5) return false;
			const type = buffered[3];
			const addressLength = type === 1 ? 4 : type === 4 ? 16 : 1 + buffered[4];
			if (buffered.length < 4 + addressLength + 2) return false;
			const frame = take(4 + addressLength + 2);
			const address = frame.subarray(4, 4 + addressLength);
			const host =
				type === 1
					? [...address].join('.')
					: type === 4
						? address.toString('hex')
						: address.subarray(1).toString('utf8');
			const port = frame.readUInt16BE(4 + addressLength);
			events.push({ type: 'connect', authority: `${host}:${port}`, outcome: 'tunnel', atyp: type });
			socket.removeAllListeners('data');
			socket.pause();
			socket.write(Buffer.from([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]));
			const target = net.connect(upstream.port, LOOPBACK, () => {
				if (buffered.length) target.write(buffered);
				socket.pipe(target);
				target.pipe(socket);
			});
			sockets.add(target);
			target.on('close', () => {
				sockets.delete(target);
				socket.destroy();
			});
			target.on('error', () => socket.destroy());
			socket.on('close', () => target.destroy());
			return false;
		};
		const steps = { greeting, login, request };
		socket.on('data', (chunk) => {
			buffered = Buffer.concat([buffered, chunk]);
			while (steps[step]());
		});
	});
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, LOOPBACK, resolve);
	});
	const { port } = server.address();
	return {
		port,
		url: `socks5://${LOOPBACK}:${port}`,
		events,
		close: () => closeServer(server, sockets)
	};
}

// ========================================
// ======= 3/ The PAC / WPAD server =======
// ========================================

/**
 * Starts the file server a PAC URL or a WPAD lookup reads.
 * @param {object} [options]
 * @param {string} [options.script] The FindProxyForURL source, served at /proxy.pac and /wpad.dat.
 * @param {number} [options.status] An answer other than 200, for a broken server.
 * @returns {Promise<object>} { port, url, wpadUrl, requests, setScript, close }.
 */
async function startFakePacServer({ script = pacScript('DIRECT'), status = 200 } = {}) {
	const state = { script, status };
	const requests = [];
	const sockets = new Set();
	const server = http.createServer((request, response) => {
		requests.push(request.url);
		if (request.url !== '/proxy.pac' && request.url !== '/wpad.dat') {
			response.writeHead(404);
			response.end();
			return;
		}
		response.writeHead(state.status, { 'Content-Type': 'application/x-ns-proxy-autoconfig' });
		response.end(state.status === 200 ? state.script : '');
	});
	server.on('connection', (socket) => {
		sockets.add(socket);
		socket.on('close', () => sockets.delete(socket));
	});
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, LOOPBACK, resolve);
	});
	const { port } = server.address();
	return {
		port,
		url: `http://${LOOPBACK}:${port}/proxy.pac`,
		wpadUrl: `http://${LOOPBACK}:${port}/wpad.dat`,
		requests,
		setScript(next, nextStatus = 200) {
			state.script = next;
			state.status = nextStatus;
		},
		close: () => closeServer(server, sockets)
	};
}

/**
 * A PAC that answers one route for every destination.
 * @param {string} route "DIRECT" or "PROXY host:port", as FindProxyForURL returns it.
 * @returns {string} The script.
 */
function pacScript(route) {
	// A route is a list of "DIRECT" or "<TYPE> host:port" entries. Holding it
	// to that grammar keeps quotes and backslashes out of the generated source.
	const entry = '(?:DIRECT|(?:PROXY|HTTPS|SOCKS|SOCKS5) [A-Za-z0-9.-]+:[0-9]{1,5})';
	if (typeof route !== 'string' || !new RegExp(`^${entry}(?:; ?${entry})*$`).test(route))
		throw new Error(`pacScript: ${JSON.stringify(route)} is not a PAC route`);
	return `function FindProxyForURL(url, host) { return "${route}"; }\n`;
}

// ======================================
// ======= 4/ The model registry ========
// ======================================

/**
 * A self-signed Ed25519 certificate, built here because Node can sign but cannot
 * write X.509. Clients pin its digest: no CA store is touched, and a client that
 * accepted another certificate would prove the tunnel is not end to end.
 * @param {string} commonName The subject and issuer.
 * @param {'ed25519'|'ecdsa'} [algorithm] ecdsa (P-256) for a Windows TLS client:
 *     Schannel refuses an Ed25519 certificate.
 * @returns {{key: string, cert: string, sha256: string}} PEM values and the DER digest.
 */
function selfSignedCertificate(commonName, algorithm = 'ed25519') {
	const { publicKey, privateKey } =
		algorithm === 'ecdsa'
			? crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
			: crypto.generateKeyPairSync('ed25519');
	const signing = der(
		0x30,
		der(0x06, Buffer.from(algorithm === 'ecdsa' ? '2a8648ce3d040302' : '2b6570', 'hex'))
	);
	const name = der(
		0x30,
		der(
			0x31,
			der(0x30, der(0x06, Buffer.from('550403', 'hex')), der(0x0c, Buffer.from(commonName)))
		)
	);
	const time = (date) =>
		der(0x17, Buffer.from(`${date.toISOString().slice(2, 19).replace(/[-:T]/g, '')}Z`));
	const now = Date.now();
	const tbs = der(
		0x30,
		der(0xa0, der(0x02, Buffer.from([2]))),
		der(0x02, Buffer.from([1])),
		signing,
		name,
		der(0x30, time(new Date(now - 3600000)), time(new Date(now + 86400000))),
		name,
		publicKey.export({ format: 'der', type: 'spki' })
	);
	const signature = crypto.sign(algorithm === 'ecdsa' ? 'sha256' : null, tbs, privateKey);
	const certificate = der(0x30, tbs, signing, der(0x03, Buffer.from([0]), signature));
	const pem = certificate.toString('base64').replace(/(.{64})(?=.)/g, '$1\n');
	return {
		key: privateKey.export({ format: 'pem', type: 'pkcs8' }),
		cert: `-----BEGIN CERTIFICATE-----\n${pem}\n-----END CERTIFICATE-----\n`,
		sha256: crypto.createHash('sha256').update(certificate).digest('hex')
	};
}

/**
 * Starts the registry: /v2/library/<model>/manifests/<tag> and its blobs, plus an
 * Ollama-like POST /api/pull stream. In digest_mismatch mode a blob's bytes do not
 * hash to the manifest's digest, as in the macOS field run of 2026-10-31.
 * @param {object} [options]
 * @param {'ok'|'digest_mismatch'} [options.mode] The blob behaviour.
 * @returns {Promise<object>} { port, cert, sha256, requests, serverNames, setMode, close }.
 */
async function startFakeRegistry({ mode = 'ok' } = {}) {
	const state = { mode };
	const requests = [];
	const sockets = new Set();
	const blob = Buffer.from('fake model layer bytes\n');
	const digest = `sha256:${crypto.createHash('sha256').update(blob).digest('hex')}`;
	const manifest = JSON.stringify({
		schemaVersion: 2,
		layers: [{ mediaType: 'application/vnd.ollama.image.model', digest, size: blob.length }]
	});
	const identity = selfSignedCertificate('fake-registry.invalid');
	const send = (socket, status, type, body) => {
		const bytes = Buffer.from(body);
		socket.end(
			Buffer.concat([
				Buffer.from(
					`HTTP/1.1 ${status} OK\r\nContent-Type: ${type}\r\nContent-Length: ${bytes.length}\r\nConnection: close\r\n\r\n`
				),
				bytes
			])
		);
	};
	const serverNames = [];
	const options = {
		key: identity.key,
		cert: identity.cert,
		// Reached before the client judges the certificate, so a client that goes on to
		// refuse it still shows who it meant to talk to.
		SNICallback: (name, done) => {
			serverNames.push(name);
			done(null, null);
		}
	};
	const server = tls.createServer(options, (socket) => {
		sockets.add(socket);
		socket.on('close', () => sockets.delete(socket));
		socket.on('error', () => {});
		let buffered = '';
		socket.on('data', (chunk) => {
			buffered += chunk.toString('latin1');
			if (!buffered.includes('\r\n\r\n')) return;
			const { method, target } = parseHead(buffered.slice(0, buffered.indexOf('\r\n\r\n')));
			requests.push(`${method} ${target}`);
			if (method === 'POST' && target === '/api/pull') {
				const statuses =
					state.mode === 'digest_mismatch'
						? [
								{ status: 'pulling manifest' },
								{ error: 'digest mismatch, file must be downloaded again' }
							]
						: [{ status: 'pulling manifest' }, { status: 'success' }];
				send(
					socket,
					200,
					'application/x-ndjson',
					statuses.map((row) => `${JSON.stringify(row)}\n`).join('')
				);
			} else if (method === 'GET' && /^\/v2\/library\/[^/]+\/manifests\/[^/]+$/.test(target)) {
				send(socket, 200, 'application/vnd.docker.distribution.manifest.v2+json', manifest);
			} else if (method === 'GET' && target.endsWith(`/blobs/${digest}`)) {
				send(
					socket,
					200,
					'application/octet-stream',
					state.mode === 'digest_mismatch' ? Buffer.from('corrupted layer bytes!!\n') : blob
				);
			} else {
				send(socket, 404, 'text/plain', 'not found');
			}
		});
	});
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, LOOPBACK, resolve);
	});
	return {
		port: server.address().port,
		cert: identity.cert,
		sha256: identity.sha256,
		requests,
		serverNames,
		setMode(next) {
			state.mode = next;
		},
		close: () => closeServer(server, sockets)
	};
}

/**
 * Starts a registry the real daemon can pull from without TLS (`insecure`): the
 * protocol as the real one speaks it, a manifest, HEAD for a blob's size, and a
 * 307 from the blob to a storage URL on another host name, which is what the
 * daemon's downloader demands before it takes the bytes.
 * @param {object} options
 * @param {{mediaType: string, bytes: Buffer}} options.config The config blob.
 * @param {{mediaType: string, bytes: Buffer}[]} options.layers The layers.
 * @param {'ok'|'digest_mismatch'|'stall'} [options.mode] The storage behaviour:
 *     stall answers half a blob and then holds the connection.
 * @returns {Promise<object>} { port, manifestDigest, requests, setMode, close };
 *     a request row is { method, path, proxied, range }.
 */
async function startFakeOllamaRegistry({ config, layers, mode = 'ok' }) {
	const state = { mode };
	const requests = [];
	const sockets = new Set();
	const describe = ({ mediaType, bytes }) => ({
		mediaType,
		digest: `sha256:${crypto.createHash('sha256').update(bytes).digest('hex')}`,
		size: bytes.length
	});
	const blobs = new Map([config, ...layers].map((blob) => [describe(blob).digest, blob.bytes]));
	const manifest = JSON.stringify({
		schemaVersion: 2,
		mediaType: 'application/vnd.docker.distribution.manifest.v2+json',
		config: describe(config),
		layers: layers.map(describe)
	});
	const server = http.createServer((request, response) => {
		const url = request.url;
		requests.push({
			method: request.method,
			path: url,
			proxied: request.headers['x-fake-proxy'] === 'forwarded',
			range: request.headers.range ?? ''
		});
		const storage = /^\/storage\/(sha256:[0-9a-f]{64})$/.exec(url);
		const blob = /^\/v2\/library\/[^/]+\/blobs\/(sha256:[0-9a-f]{64})$/.exec(url);
		if (/^\/v2\/library\/[^/]+\/manifests\/[^/]+$/.test(url)) {
			response.writeHead(200, {
				'Content-Type': 'application/vnd.docker.distribution.manifest.v2+json',
				'Content-Length': Buffer.byteLength(manifest)
			});
			response.end(request.method === 'HEAD' ? undefined : manifest);
		} else if (blob && blobs.has(blob[1]) && request.method === 'HEAD') {
			response.writeHead(200, { 'Content-Length': blobs.get(blob[1]).length });
			response.end();
		} else if (blob && blobs.has(blob[1])) {
			// Another host name for one server: the daemon stops following at that hop.
			response.writeHead(307, {
				Location: `http://${LOOPBACK}:${server.address().port}/storage/${blob[1]}`,
				'Content-Length': 0
			});
			response.end();
		} else if (storage && blobs.has(storage[1])) {
			const bytes = Buffer.from(blobs.get(storage[1]));
			if (state.mode === 'stall') {
				response.writeHead(200, { 'Content-Length': bytes.length });
				response.write(bytes.subarray(0, bytes.length >> 1));
				return;
			}
			if (state.mode === 'digest_mismatch') bytes[0] ^= 0xff;
			response.writeHead(200, { 'Content-Length': bytes.length });
			response.end(bytes);
		} else {
			response.writeHead(404);
			response.end();
		}
	});
	server.on('connection', (socket) => {
		sockets.add(socket);
		socket.on('close', () => sockets.delete(socket));
	});
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, LOOPBACK, resolve);
	});
	return {
		port: server.address().port,
		requests,
		setMode(next) {
			state.mode = next;
		},
		close: () => closeServer(server, sockets)
	};
}

// ======================================
// ======= 5/ The Agent API =============
// ======================================

/** The documented answer: a tool item stands before the message. */
function agentAnswer(model) {
	return {
		id: 'resp_fake',
		object: 'response',
		model,
		status: 'completed',
		error: null,
		output: [
			{ type: 'search_results', queries: [], results: [] },
			{
				type: 'message',
				role: 'assistant',
				status: 'completed',
				content: [{ type: 'output_text', text: 'OK', annotations: [] }]
			}
		],
		usage: { input_tokens: 10, output_tokens: 2, total_tokens: 12, cost: { total_cost: 0 } }
	};
}

/**
 * Starts the fake Agent API: POST /v1/agent and GET /v1/models, with the refusals
 * of docs.perplexity.ai read on 2026-11-01. A key is compared and never recorded.
 * @param {object} options
 * @param {string} options.key The expected Bearer key.
 * @returns {Promise<object>} { port, baseUrl, events, close }.
 */
async function startFakeAgentApi({ key }) {
	const events = [];
	const sockets = new Set();
	const send = (response, status, value) => {
		response.writeHead(status, { 'Content-Type': 'application/json' });
		response.end(JSON.stringify(value));
	};
	const refuse = (response, status, message) => {
		events.push({ type: 'refused', status, message });
		send(response, status, { error: { message, type: 'invalid_request' } });
	};
	const server = http.createServer((request, response) => {
		if (request.method === 'GET' && request.url === '/v1/models') {
			send(response, 200, {
				object: 'list',
				data: ['perplexity/sonar', 'perplexity/kimi-k3'].map((id) => ({
					id,
					object: 'model',
					created: 0,
					owned_by: 'perplexity'
				}))
			});
			return;
		}
		if (request.method !== 'POST' || request.url !== '/v1/agent') {
			refuse(response, 404, 'not found');
			return;
		}
		const chunks = [];
		request.on('data', (chunk) => chunks.push(chunk));
		request.on('end', () => {
			if (request.headers.authorization !== `Bearer ${key}`) {
				refuse(response, 401, 'invalid api key');
				return;
			}
			let body;
			try {
				body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
			} catch {
				refuse(response, 400, 'body is not JSON');
				return;
			}
			if (typeof body.model !== 'string' || body.input === undefined) {
				refuse(response, 400, 'input and a model are required');
				return;
			}
			if ('messages' in body || 'max_tokens' in body) {
				refuse(response, 400, 'chat completion fields are not accepted');
				return;
			}
			if (!Number.isInteger(body.max_output_tokens) || body.max_output_tokens < 1) {
				refuse(response, 400, 'max_output_tokens is required');
				return;
			}
			events.push({ type: 'agent', body });
			send(response, 200, agentAnswer(body.model));
		});
	});
	server.on('connection', (socket) => {
		sockets.add(socket);
		socket.on('close', () => sockets.delete(socket));
	});
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, LOOPBACK, resolve);
	});
	const { port } = server.address();
	return {
		port,
		baseUrl: `http://${LOOPBACK}:${port}/v1`,
		events,
		close: () => closeServer(server, sockets)
	};
}

module.exports = {
	BASIC_CREDENTIAL,
	LOOPBACK,
	NTLM_CHALLENGE,
	PROXY_MODES,
	TEST_CREDENTIAL,
	md4,
	ntlmClientType3,
	ntlmType2,
	pacScript,
	selfSignedCertificate,
	startFakeAgentApi,
	startFakeOllamaRegistry,
	startFakePacServer,
	startFakeProxy,
	startFakeRegistry,
	startFakeSocks5Proxy,
	verifyNtlmV2
};
