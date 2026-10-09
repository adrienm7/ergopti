// tools/test/test-managed-bootstrap-policy.cjs
// Independent canonical-policy and generated-image drift controls.

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { render } = require('../codegen/codegen-managed-bootstrap.cjs');
const root = path.resolve(__dirname, '../..');
const shared = path.join(root, 'static/ergopti_plus/_shared/modules');
const bootstrap = fs.readFileSync(path.join(shared, 'llm/managed_ollama_bootstrap.json'));
const proxy = fs.readFileSync(path.join(shared, 'network/proxy_policy.json'));
const generated = fs.readFileSync(
	path.join(
		root,
		'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedBootstrapPolicy.generated.swift'
	),
	'utf8'
);
assert.equal(render(bootstrap, proxy), generated);
const policy = JSON.parse(bootstrap);
assert.equal(policy.hmac_domain, 'ERGOPTI_NATIVE_NETWORK_BOOTSTRAP_V1\n');
assert.deepEqual(policy.trust_environment, ['SSL_CERT_FILE', 'SSL_CERT_DIR']);
assert.equal(policy.maximum_metadata_bytes, 1048576);
assert.equal(policy.maximum_certificate_bytes, 16777216);
assert.equal(policy.maximum_certificate_files, 1024);
let controls = 6;
for (const [key, value] of [
	['schema_version', true],
	['schema_version', 2],
	['maximum_metadata_bytes', 0],
	['maximum_metadata_bytes', 1.5],
	['maximum_certificate_bytes', null],
	['maximum_certificate_files', -1],
	['hmac_domain', 'missing-boundary'],
	['trust_environment', []],
	['trust_environment', ['one']],
	['trust_environment', ['one', 'one']],
	['trust_environment', ['SSL_CERT_FILE', 'invalid=value']],
	['trust_environment', ['SSL_CERT_FILE', 'https_proxy']],
	['foreign', 1]
]) {
	assert.throws(() => render(Buffer.from(JSON.stringify({ ...policy, [key]: value })), proxy));
	controls++;
}
assert.throws(() =>
	render(
		Buffer.from(
			bootstrap
				.toString()
				.replace('"schema_version": 1', '"schema_version": 1, "schema_version": 1')
		),
		proxy
	)
);
controls++;
assert.throws(() =>
	render(
		bootstrap,
		Buffer.from(
			proxy.toString().replace('"schema_version": 1', '"schema_version": 1, "schema_version": 1')
		)
	)
);
controls++;
assert.throws(() => render(Buffer.concat([bootstrap, Buffer.from([255])]), proxy));
controls++;
for (const key of ['system_lookup_environment_exclusions', 'environment_bypass_precedence']) {
	const original = JSON.parse(proxy);
	for (const value of [[], ['same', 'same'], ['wrong name'], null]) {
		assert.throws(() =>
			render(bootstrap, Buffer.from(JSON.stringify({ ...original, [key]: value })))
		);
		controls++;
	}
}
const changed = Buffer.from(JSON.stringify({ ...policy, maximum_metadata_bytes: 1048577 }));
assert.notEqual(render(changed, proxy), generated);
controls++;
assert.notEqual(
	generated.replace('maximumMetadataBytes = 1048576', 'maximumMetadataBytes = 1'),
	render(bootstrap, proxy)
);
controls++;
// Scan actual Swift target inputs, rather than only comparing the generated
// file to its own generator: that drift check missed a duplicate type owner.
const launcherSources = path.join(root, 'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus');
function swiftSources(directory, prefix = '') {
	const sources = new Map();
	for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
		assert.equal(entry.isSymbolicLink(), false, 'Swift source inventory must be physical');
		const name = prefix + entry.name;
		if (entry.isDirectory()) {
			for (const [relative, bytes] of swiftSources(path.join(directory, entry.name), name + '/'))
				sources.set(relative, bytes);
		} else if (entry.isFile() && entry.name.endsWith('.swift')) {
			sources.set(name, fs.readFileSync(path.join(directory, entry.name), 'utf8'));
		}
	}
	return sources;
}

// A bounded nominal-type source guard, not a Swift compiler. Ignore comments,
// strings (including raw/multiline strings) and nested nominal declarations.
function topLevelPolicyTypes(source) {
	const tokens = [];
	let at = 0;
	while (at < source.length) {
		if (source.startsWith('//', at)) {
			const next = source.indexOf('\n', at);
			at = next < 0 ? source.length : next + 1;
			continue;
		}
		if (source.startsWith('/*', at)) {
			let depth = 1;
			at += 2;
			while (at < source.length && depth) {
				if (source.startsWith('/*', at)) {
					depth++;
					at += 2;
				} else if (source.startsWith('*/', at)) {
					depth--;
					at += 2;
				} else at++;
			}
			assert.equal(depth, 0, 'unterminated Swift comment');
			continue;
		}
		const opening = /^(#*)("""|")/.exec(source.slice(at));
		if (opening) {
			const end = opening[2] + opening[1];
			const escape = '\\' + opening[1];
			at += opening[0].length;
			let closed = false;
			while (at < source.length) {
				if (source.startsWith(escape, at)) at += escape.length + 1;
				else if (source.startsWith(end, at)) {
					at += end.length;
					closed = true;
					break;
				} else at++;
			}
			assert.equal(closed, true, 'unterminated Swift string');
			continue;
		}
		const name = /^[A-Za-z_][A-Za-z0-9_]*/.exec(source.slice(at));
		if (name) {
			tokens.push(name[0]);
			at += name[0].length;
		} else {
			if ('{}'.includes(source[at])) tokens.push(source[at]);
			at++;
		}
	}
	let depth = 0;
	const names = [];
	for (let index = 0; index < tokens.length; index++) {
		if (tokens[index] === '{') depth++;
		else if (tokens[index] === '}') depth--;
		else if (
			depth === 0 &&
			['enum', 'struct', 'class', 'actor', 'protocol', 'typealias'].includes(tokens[index])
		) {
			const name = tokens[index + 1];
			if (['ManagedBootstrapPolicy', 'ManagedNetworkBootstrapPolicy'].includes(name))
				names.push(name);
		}
		assert.ok(depth >= 0, 'Swift declaration scope is balanced');
	}
	assert.equal(depth, 0, 'Swift declaration scope is balanced');
	return names;
}

function assertPolicyOwners(sources) {
	const expected = new Map([
		['ManagedBootstrapPolicy', 'ManagedBootstrapDownload.swift'],
		['ManagedNetworkBootstrapPolicy', 'ManagedBootstrapPolicy.generated.swift']
	]);
	const actual = new Map([...expected.keys()].map((name) => [name, []]));
	for (const [file, source] of sources) {
		for (const name of topLevelPolicyTypes(source)) actual.get(name).push(file);
	}
	for (const [name, file] of expected)
		assert.deepEqual(actual.get(name), [file], name + ' has one exact owner');
}

const sources = swiftSources(launcherSources);
assertPolicyOwners(sources);
controls++;
const duplicate = new Map(sources);
duplicate.set('ForeignPolicy.swift', 'struct ManagedNetworkBootstrapPolicy {}\n');
assert.throws(() => assertPolicyOwners(duplicate));
controls++;
const oldCollision = new Map(sources);
oldCollision.set(
	'ManagedBootstrapPolicy.generated.swift',
	generated.replace('enum ManagedNetworkBootstrapPolicy', 'enum ManagedBootstrapPolicy')
);
assert.throws(() => assertPolicyOwners(oldCollision));
controls++;
for (const name of ['ManagedBootstrapPolicy', 'ManagedNetworkBootstrapPolicy']) {
	const missing = new Map(sources);
	const file =
		name === 'ManagedBootstrapPolicy'
			? 'ManagedBootstrapDownload.swift'
			: 'ManagedBootstrapPolicy.generated.swift';
	missing.set(
		file,
		missing.get(file).replace(new RegExp('\\b' + name + '\\b', 'g'), 'UnrelatedPolicy')
	);
	assert.throws(() => assertPolicyOwners(missing));
	controls++;
}
const misleading = new Map(sources);
misleading.set(
	'CommentAndNestedPolicy.swift',
	'// struct ManagedBootstrapPolicy {}\n/* enum ManagedNetworkBootstrapPolicy {} /* struct ManagedBootstrapPolicy {} */ */\nlet text = #"enum ManagedNetworkBootstrapPolicy {}"#\nlet multiline = """\nstruct ManagedBootstrapPolicy {}\n"""\nstruct Container { struct ManagedBootstrapPolicy {} }\n'
);
assertPolicyOwners(misleading);
controls++;
for (const [file, members] of [
	['OwnedSuspendedImageGuardian.swift', ['maximumProxyBytes', 'maximumMetadataBytes']],
	[
		'ManagedCertificateAuthorities.swift',
		[
			'trustEnvironment',
			'maximumCertificateFiles',
			'maximumCertificateBytes',
			'maximumCertificateFiles'
		]
	]
]) {
	const reads = [
		...sources.get(file).matchAll(/\bManaged(?:Network)?BootstrapPolicy\.([A-Za-z_][A-Za-z0-9_]*)/g)
	];
	assert.deepEqual(
		reads.map((match) => match[0]),
		members.map((member) => 'ManagedNetworkBootstrapPolicy.' + member)
	);
	controls++;
}
console.log(`Managed bootstrap policy: ${controls} controls passed; native SDK not executed.`);
