// tools/test/test-macos-guardian-signature-flags.cjs
// Keep public OptionSet flags source-bound; native Swift compilation remains mandatory.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const source = fs.readFileSync(
	path.resolve(
		__dirname,
		'../../static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/OwnedSuspendedImageGuardian.swift'
	),
	'utf8'
);
const approved =
	'SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures).union(.noNetworkAccess)';

function receivePublicFlags(candidate) {
	const calls = Array.from(
		candidate.matchAll(/SecStaticCodeCheckValidity\(code,\s*([^\n]+),\s*nil\) == errSecSuccess/g)
	);
	assert.equal(calls.length, 1, 'the outgoing signature owner must have one validation call');
	assert.equal(
		calls[0][1],
		approved,
		'keep strict/all-architecture anonymous enum masks and typed public noNetworkAccess'
	);
	assert.match(candidate, /outgoingBound\(\), admissionRemaining\(\) else \{ return false \}/);
}

function mutant(replacement) {
	assert.equal(
		source.split(approved).length,
		2,
		'one exact actual signature expression is required'
	);
	return source.replace(approved, replacement);
}

test('guardian signature: SDK OptionSet member preserves strict, all architectures and offline flags', () => {
	receivePublicFlags(source);
});

test('guardian signature: the actual unqualified Swift name regression is refused', () => {
	assert.throws(() =>
		receivePublicFlags(
			mutant(
				'SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSNoNetworkAccess)'
			)
		)
	);
});

test('guardian signature: strict validation cannot be removed', () => {
	assert.throws(() =>
		receivePublicFlags(
			mutant('SecCSFlags(rawValue: kSecCSCheckAllArchitectures).union(.noNetworkAccess)')
		)
	);
});

test('guardian signature: all-architecture validation cannot be removed', () => {
	assert.throws(() =>
		receivePublicFlags(mutant('SecCSFlags(rawValue: kSecCSStrictValidate).union(.noNetworkAccess)'))
	);
});

test('guardian signature: offline validation cannot be removed', () => {
	assert.throws(() =>
		receivePublicFlags(
			mutant('SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)')
		)
	);
});

test('guardian signature: public typed flag cannot be replaced by a numeric guess', () => {
	assert.throws(() =>
		receivePublicFlags(
			mutant('SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | (1 << 29))')
		)
	);
});

test('guardian signature: network access cannot be enabled', () => {
	assert.throws(() =>
		receivePublicFlags(
			mutant(
				'SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures).union(.allowNetworkAccess)'
			)
		)
	);
});
