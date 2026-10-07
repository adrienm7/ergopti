'use strict';
// Actual production bridge replay in independently created document contexts.
// Expectations are hand-authored; no DOM/native/WebKit success claim.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(
	process.argv[2] || path.join(__dirname, '../../static/ergopti_plus/_shared/ui/host_bridge.js'),
	'utf8'
);
let passed = 0,
	failed = 0;
function test(name, fn) {
	try {
		fn();
		passed++;
		console.log('PASS ' + name);
	} catch (error) {
		failed++;
		console.log('FAIL ' + name + ': ' + error.message);
	}
}
function page(seed, host = 'linux', cryptoAvailable = true) {
	const messages = [];
	const window = {
		__ergopti_host: host,
		webkit: {
			messageHandlers: {
				changelog_bridge: { postMessage: (x) => messages.push(x) },
				dl_bridge: { postMessage: (x) => messages.push(x) },
				token_bridge: { postMessage: (x) => messages.push(x) }
			}
		}
	};
	if (cryptoAvailable)
		window.crypto = {
			getRandomValues: (bytes) => {
				for (let i = 0; i < bytes.length; i++) bytes[i] = seed + i;
				return bytes;
			}
		};
	const context = vm.createContext({
		window,
		console,
		Uint8Array,
		Map,
		TextDecoder,
		setInterval,
		clearInterval
	});
	vm.runInContext(source, context);
	return { messages, context, window, call: (text) => vm.runInContext(text, context) };
}
const token = 'AAAAAAAAAAAAAAAAAAAA0001';
function initialize(p, generation = 1) {
	const nonce = p.call("getLinuxDocumentNonce('changelog_bridge')");
	assert.equal(
		p.call(
			`initializeLinuxDocumentBridge('changelog_bridge', ${generation}, '${token}', '${nonce}')`
		),
		true
	);
	return nonce;
}
function confirm(p, nonce, generation = 1) {
	return p.call(
		`confirmLinuxDocumentBridge('changelog_bridge', ${generation}, '${token}', '${nonce}')`
	);
}
test('pre-initialization actions unavailable', () => {
	const p = page(1);
	const accepted = p.call("makeHostBridge('changelog_bridge')('install')");
	assert.equal(p.messages.length, 0);
	assert.equal(accepted, false);
});
test('actual intrinsic nonce is stable and document-specific', () => {
	const a = page(1),
		b = page(2);
	const n = a.call("getLinuxDocumentNonce('changelog_bridge')");
	assert.match(n, /^[a-f0-9]{36}$/);
	assert.equal(a.call("getLinuxDocumentNonce('changelog_bridge')"), n);
	assert.notEqual(b.call("getLinuxDocumentNonce('changelog_bridge')"), n);
});
test('ACK is separate from action-ready confirmation', () => {
	const p = page(1),
		n = initialize(p);
	assert.equal(p.messages.length, 1);
	assert.equal(p.messages[0].__ergopti_document_ack.page_nonce, n);
	assert.equal(p.call("makeHostBridge('changelog_bridge')('retry')"), false);
	assert.equal(confirm(p, n), true);
	assert.equal(p.messages[1].payload, 'ready');
	assert.equal(p.messages[1].__ergopti_document.token, token);
});
test('same-URI successor refuses queued old challenge', () => {
	const a = page(1),
		n = initialize(a);
	const b = page(2);
	assert.equal(
		b.call(`initializeLinuxDocumentBridge('changelog_bridge',1,'${token}','${n}')`),
		false
	);
	assert.equal(b.messages.length, 0);
});
test('successor refuses queued old confirmation', () => {
	const a = page(1),
		n = initialize(a),
		b = page(2);
	assert.equal(confirm(b, n), false);
	assert.equal(b.messages.length, 0);
});
test('successor refuses old queued native phase effect', () => {
	const a = page(1),
		n = initialize(a),
		b = page(2);
	b.context.effects = 0;
	assert.equal(
		b.call(
			`runLinuxOwnedDocumentEffect('changelog_bridge',1,'${token}','${n}',function(){effects++})`
		),
		false
	);
	assert.equal(b.context.effects, 0);
});
test('current exact binding accepts owned phase effect', () => {
	const p = page(1),
		n = initialize(p);
	p.context.effects = 0;
	assert.equal(
		p.call(
			`runLinuxOwnedDocumentEffect('changelog_bridge',1,'${token}','${n}',function(){effects++})`
		),
		true
	);
	assert.equal(p.context.effects, 1);
});
test('older challenge cannot overwrite successor binding', () => {
	const p = page(1),
		n = initialize(p, 2);
	assert.equal(
		p.call(`initializeLinuxDocumentBridge('changelog_bridge',1,'${token}','${n}')`),
		false
	);
	assert.equal(confirm(p, n, 2), true);
	assert.equal(p.messages[1].__ergopti_document.generation, 2);
});
test('duplicate ACK binding and confirmation do not reinitialize document', () => {
	const p = page(1),
		n = initialize(p);
	assert.equal(
		p.call(`initializeLinuxDocumentBridge('changelog_bridge',1,'${token}','${n}')`),
		false
	);
	assert.equal(confirm(p, n), true);
	assert.equal(confirm(p, n), false);
	assert.equal(p.messages.length, 2);
});
test('no Crypto does not substitute guessed entropy', () => {
	const p = page(1, 'linux', false);
	assert.equal(p.call("getLinuxDocumentNonce('changelog_bridge')"), null);
	assert.equal(
		p.call(`initializeLinuxDocumentBridge('changelog_bridge',1,'${token}','${'a'.repeat(36)}')`),
		false
	);
	assert.equal(p.messages.length, 0);
});
test('malformed challenge and unsafe generation refused', () => {
	const p = page(1),
		n = p.call("getLinuxDocumentNonce('changelog_bridge')");
	for (const g of [0, -1, 0.5, 9007199254740992])
		assert.equal(
			p.call(`initializeLinuxDocumentBridge('changelog_bridge',${g},'${token}','${n}')`),
			false
		);
	assert.equal(p.call(`initializeLinuxDocumentBridge('changelog_bridge',1,'bad','${n}')`), false);
	assert.equal(p.messages.length, 0);
});
test('ordinary Linux pages preserve raw payload contract', () => {
	const p = page(1);
	p.call("makeHostBridge('token_bridge')('ready')");
	assert.equal(p.messages[0], 'ready');
});
test('Mac Versions preserves raw payload contract', () => {
	const p = page(1, 'macos');
	p.call("makeHostBridge('changelog_bridge')('ready')");
	assert.equal(p.messages[0], 'ready');
});
test('Windows keeps prior string and JSON payload contract', () => {
	const p = page(1, 'windows');
	p.window.chrome = { webview: { postMessage: (x) => p.messages.push(x) } };
	p.call("makeHostBridge('changelog_bridge')('ready')");
	p.call("makeHostBridge('changelog_bridge')({action:'retry'})");
	assert.equal(p.messages[0], 'ready');
	assert.equal(p.messages[1], '{"action":"retry"}');
});
test('network progress actions require their own actual document handshake', () => {
	const p = page(1);
	const accepted = p.call("makeHostBridge('dl_bridge')({action:'cancel',session:1})");
	assert.equal(p.messages.length, 0);
	assert.equal(accepted, false);
	const n = p.call("getLinuxDocumentNonce('dl_bridge')");
	assert.equal(p.call(`initializeLinuxDocumentBridge('dl_bridge',1,'${token}','${n}')`), true);
	assert.equal(p.call(`confirmLinuxDocumentBridge('dl_bridge',1,'${token}','${n}')`), true);
	assert.equal(p.messages[1].payload, 'ready');
});
test('network progress rejects successor queued old phase effect', () => {
	const a = page(1),
		b = page(2);
	const n = a.call("getLinuxDocumentNonce('dl_bridge')");
	a.call(`initializeLinuxDocumentBridge('dl_bridge',1,'${token}','${n}')`);
	b.context.effects = 0;
	assert.equal(
		b.call(`runLinuxOwnedDocumentEffect('dl_bridge',1,'${token}','${n}',function(){effects++})`),
		false
	);
	assert.equal(b.context.effects, 0);
});
console.log(
	JSON.stringify({ passed, failed, kind: 'pure actual production JS replay; native unexecuted' })
);
process.exitCode = failed ? 1 : 0;
