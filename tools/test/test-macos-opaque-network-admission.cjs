// tools/test/test-macos-opaque-network-admission.cjs
/**
 * ============================================================================
 * MODULE: Opaque macOS Client Network Admission Receiving
 * DESCRIPTION:
 * Replays literal route expectations through the production shell and actual
 * Lua-emitted prelude. Missing Bash/Lua is a failure on every host. Native
 * configuration snapshots are receiver inputs, not a claim of PAC evaluation.
 * ============================================================================
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const root = path.resolve(__dirname, '../..');
const policy = path.join(root, 'static/ergopti_plus/macos/modules/llm/network-retry.sh');
const shellPath = (value) => {
	const result = path.resolve(value).replace(/\\/g, '/');
	if (process.platform !== 'win32') return result;
	const match = result.match(/^([A-Za-z]):(\/.*)$/);
	assert.ok(match, `Git Bash cannot receive path ${result}`);
	return `/${match[1].toLowerCase()}${match[2]}`;
};
const quote = (value) => `'${String(value).replace(/'/g, `'\\''`)}'`;
const fixtureEnvironmentKeys = new Set([
	'HTTPS_PROXY',
	'HTTP_PROXY',
	'ALL_PROXY',
	'NO_PROXY',
	'UV_SYSTEM_CERTS',
	'SSL_CERT_FILE',
	'REQUESTS_CA_BUNDLE'
]);
function fixtureHostEnvironment(environment = process.env) {
	return Object.fromEntries(
		Object.entries(environment).filter(([key]) => !fixtureEnvironmentKeys.has(key.toUpperCase()))
	);
}
function fixturePosixEnvironment(script, environment = {}) {
	// Node's Windows spawn folds case variants before Bash sees them. Install the
	// exact receiver inputs inside the POSIX shell, before the policy captures them.
	const exports = Object.entries(environment).map(([key, value]) => {
		assert.match(key, /^[A-Za-z_][A-Za-z0-9_]*$/);
		assert.ok(fixtureEnvironmentKeys.has(key.toUpperCase()), 'receiver environment key');
		assert.equal(typeof value, 'string', 'receiver environment value');
		return `export ${key}=${quote(value)}; `;
	});
	return exports.join('') + script;
}
const vectors = [
	{
		id: 'pac-only',
		snapshot:
			'<dictionary> {\n ProxyAutoConfigEnable : 1\n ProxyAutoConfigURLString : https://config.invalid/private.pac\n}',
		code: 78,
		provenance: 'verified',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'wpad-only',
		snapshot: '<dictionary> {\n ProxyAutoDiscoveryEnable : 1\n}',
		code: 78,
		provenance: 'verified',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'pac-and-static',
		snapshot:
			'<dictionary> {\n ProxyAutoConfigEnable : 1\n HTTPSEnable : 1\n HTTPSProxy : static.invalid\n HTTPSPort : 3128\n}',
		code: 78,
		provenance: 'verified',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'static-https',
		snapshot:
			'<dictionary> {\n HTTPSEnable : 1\n HTTPSProxy : static.invalid\n HTTPSPort : 3128\n ProxyAutoConfigEnable : 0\n}',
		code: 0,
		provenance: '',
		resolution: '',
		relay: 'http://static.invalid:3128',
		child: true
	},
	{
		id: 'explicit-all-proxy',
		snapshot: '<dictionary> {\n ProxyAutoConfigEnable : 1\n}',
		env: { ALL_PROXY: 'http://chosen.invalid:3129' },
		code: 0,
		provenance: '',
		resolution: '',
		relay: 'http://chosen.invalid:3129',
		child: true
	},
	{
		id: 'failed-native-getter',
		snapshot: '',
		getterCode: 1,
		code: 78,
		provenance: 'unavailable',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'malformed-native-getter',
		snapshot: 'not a native dictionary',
		code: 78,
		provenance: 'unavailable',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'verified-no-proxy',
		snapshot: '<dictionary> {\n}',
		code: 0,
		provenance: '',
		resolution: '',
		relay: '',
		child: true
	},
	{
		id: 'https-lowercase-precedence',
		snapshot: '',
		getterCode: 1,
		env: {
			https_proxy: 'http://lower.invalid:3128',
			HTTPS_PROXY: 'http://upper.invalid:3129',
			ALL_PROXY: 'http://all.invalid:3130'
		},
		code: 0,
		provenance: '',
		resolution: '',
		relay: 'http://lower.invalid:3128',
		child: true
	},
	{
		id: 'http-only-does-not-admit-https-pac',
		snapshot: '<dictionary> {\n ProxyAutoConfigEnable : 1\n}',
		env: { HTTP_PROXY: 'http://http-only.invalid:3128' },
		code: 78,
		provenance: 'verified',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'invalid-pac-flag',
		snapshot: '<dictionary> {\n ProxyAutoConfigEnable : invalid\n}',
		code: 78,
		provenance: 'unavailable',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'invalid-wpad-flag',
		snapshot: '<dictionary> {\n ProxyAutoDiscoveryEnable : 2\n}',
		code: 78,
		provenance: 'unavailable',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'empty-pac-flag',
		snapshot: '<dictionary> {\n ProxyAutoConfigEnable : \n}',
		code: 78,
		provenance: 'unavailable',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'duplicate-conflicting-pac-flags',
		snapshot: '<dictionary> {\n ProxyAutoConfigEnable : 1\n ProxyAutoConfigEnable : 0\n}',
		code: 78,
		provenance: 'unavailable',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'duplicate-identical-wpad-flags',
		snapshot: '<dictionary> {\n ProxyAutoDiscoveryEnable : 0\n ProxyAutoDiscoveryEnable : 0\n}',
		code: 78,
		provenance: 'unavailable',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'invalid-https-flag',
		snapshot: '<dictionary> {\n HTTPSEnable : invalid\n}',
		code: 78,
		provenance: 'unavailable',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'invalid-http-flag',
		snapshot: '<dictionary> {\n HTTPEnable : 2\n}',
		code: 78,
		provenance: 'unavailable',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'invalid-socks-flag',
		snapshot: '<dictionary> {\n SOCKSEnable : -1\n}',
		code: 78,
		provenance: 'unavailable',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'container-pac-flag',
		snapshot: '<dictionary> {\n ProxyAutoConfigEnable : <array> {\n 0 : 0\n }\n}',
		code: 78,
		provenance: 'unavailable',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'unclosed-native-container',
		snapshot: '<dictionary> {\n ExceptionsList : <array> {\n 0 : *.local\n}',
		code: 78,
		provenance: 'unavailable',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'trailing-native-dictionary',
		snapshot: '<dictionary> {\n}\n<dictionary> {\n}',
		code: 78,
		provenance: 'unavailable',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'invalid-exception-array',
		snapshot: '<dictionary> {\n ExceptionsList : <array> {\n 1 : *.local\n }\n}',
		code: 78,
		provenance: 'unavailable',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'scoped-route-disagreement',
		snapshot:
			'<dictionary> {\n ProxyAutoConfigEnable : 0\n __SCOPED__ : <dictionary> {\n en0 : <dictionary> {\n ProxyAutoConfigEnable : 1\n }\n }\n}',
		code: 78,
		provenance: 'unavailable',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'scoped-static-disagreement',
		snapshot:
			'<dictionary> {\n HTTPSEnable : 1\n HTTPSProxy : first.invalid\n HTTPSPort : 3128\n __SCOPED__ : <dictionary> {\n en0 : <dictionary> {\n HTTPSEnable : 1\n HTTPSProxy : second.invalid\n HTTPSPort : 3128\n }\n }\n}',
		code: 78,
		provenance: 'unavailable',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'scoped-identical-static',
		snapshot:
			'<dictionary> {\n HTTPSEnable : 1\n HTTPSProxy : static.invalid\n HTTPSPort : 3128\n __SCOPED__ : <dictionary> {\n en0 : <dictionary> {\n HTTPSEnable : 1\n HTTPSProxy : static.invalid\n HTTPSPort : 3128\n }\n }\n}',
		code: 0,
		provenance: '',
		resolution: '',
		relay: 'http://static.invalid:3128',
		child: true
	},
	{
		id: 'scoped-identical-direct',
		snapshot:
			'<dictionary> {\n FTPPassive : 1\n __SCOPED__ : <dictionary> {\n en0 : <dictionary> {\n FTPPassive : 1\n }\n }\n}',
		code: 0,
		provenance: '',
		resolution: '',
		relay: '',
		child: true
	},
	{
		id: 'compact-native-direct',
		snapshot: '<dictionary> {}',
		code: 0,
		provenance: '',
		resolution: '',
		relay: '',
		child: true
	},
	{
		id: 'unsupported-socks-static',
		snapshot: '<dictionary> {\n SOCKSEnable : 1\n SOCKSProxy : socks.invalid\n SOCKSPort : 1080\n}',
		code: 78,
		provenance: 'verified',
		resolution: 'unavailable',
		relay: '',
		child: false
	},
	{
		id: 'curl-default-preserved',
		snapshot: '<dictionary> {\n ProxyAutoConfigEnable : 1\n}',
		env: { HTTPS_PROXY: 'http://explicit.invalid:3128' },
		mode: '',
		code: 0,
		provenance: '',
		resolution: '',
		relay: 'http://explicit.invalid:3128',
		lowerRelay: '',
		child: true
	}
];
function receivingNetworkSource(fixturePolicy) {
	assert.ok(
		fs.lstatSync(managedReceiver).isFile(),
		'only the copied real native receiver is admitted'
	);
	const networkSource = fs.readFileSync(
		path.join(root, 'static/ergopti_plus/macos/modules/llm/network_env.lua'),
		'utf8'
	);
	return [
		// This exact existence port also keeps Git Bash paths independent of
		// the host Lua file-name convention. No NetworkEnv method is replaced.
		`package.loaded["adapters.file_system"] = { exists = function(p) return p == ${JSON.stringify(shellPath(managedReceiver))} end }`,
		`local Network = assert(load(${JSON.stringify(networkSource)}, ${JSON.stringify('@' + shellPath(managedRoot) + '/modules/llm/network_env.lua')}))()`,
		`Network.policy_path = function() return ${JSON.stringify(shellPath(fixturePolicy))} end`,
		`local receiver = { path = ${JSON.stringify(shellPath(managedReceiver))}, source = ${JSON.stringify(fs.readFileSync(managedReceiver, 'utf8'))} }`
	];
}
function emittedOwners(fixturePolicy, python, binary) {
	const macos = path.join(root, 'static/ergopti_plus/macos').replace(/\\/g, '/');
	const shared = path.join(root, 'static/ergopti_plus/_shared/lua').replace(/\\/g, '/');
	const source = [
		`package.path = ${JSON.stringify(`${macos}/?.lua;${macos}/?/init.lua;${shared}/?.lua;${shared}/?/init.lua;`)} .. package.path`,
		...receivingNetworkSource(fixturePolicy),
		`local packet = require("tests.support.opaque_network_owner_fixture").capture(Network, ${JSON.stringify(shellPath(python))}, ${JSON.stringify(shellPath(binary))}, receiver)`,
		'io.write(require("json").encode(packet))'
	].join('; ');
	const generated = spawnSync(lua, ['-e', source], { cwd: root, encoding: 'utf8', timeout: 10000 });
	assert.ifError(generated.error);
	assert.equal(generated.status, 0, generated.stderr || generated.stdout);
	return JSON.parse(generated.stdout);
}
function receiveOwners(fixturePolicy, bytes, code, mode, owner) {
	const macos = path.join(root, 'static/ergopti_plus/macos').replace(/\\/g, '/');
	const shared = path.join(root, 'static/ergopti_plus/_shared/lua').replace(/\\/g, '/');
	const source = [
		`package.path = ${JSON.stringify(`${macos}/?.lua;${macos}/?/init.lua;${shared}/?.lua;${shared}/?/init.lua;`)} .. package.path`,
		...receivingNetworkSource(fixturePolicy),
		`local bytes = require("json").decode(${JSON.stringify(JSON.stringify(bytes))})`,
		`local result = require("tests.support.opaque_network_owner_fixture").receive(Network, bytes, ${code}, ${mode ? JSON.stringify(mode) : 'nil'}, receiver, ${owner ? JSON.stringify(owner) : 'nil'})`,
		'io.write(require("json").encode(result))'
	].join('; ');
	const received = spawnSync(lua, ['-e', source], { cwd: root, encoding: 'utf8', timeout: 10000 });
	assert.ifError(received.error);
	assert.equal(received.status, 0, received.stderr || received.stdout);
	return JSON.parse(received.stdout);
}
function receivePhase(chunks, code) {
	const macos = path.join(root, 'static/ergopti_plus/macos').replace(/\\/g, '/');
	const shared = path.join(root, 'static/ergopti_plus/_shared/lua').replace(/\\/g, '/');
	const source = [
		`package.path = ${JSON.stringify(`${macos}/?.lua;${macos}/?/init.lua;${shared}/?.lua;${shared}/?/init.lua;`)} .. package.path`,
		'local Json = require("json")',
		`local chunks = Json.decode(${JSON.stringify(JSON.stringify(chunks))})`,
		'local phase = require("modules.llm.opaque_network_admission").new()',
		'for _, chunk in ipairs(chunks) do phase.push(chunk) end',
		`local receipt = phase.finish(${code})`,
		'io.write(Json.encode({ has_receipt = receipt ~= nil, receipt = receipt or {} }))'
	].join('; ');
	const received = spawnSync(lua, ['-e', source], { cwd: root, encoding: 'utf8', timeout: 10000 });
	assert.ifError(received.error);
	assert.equal(received.status, 0, received.stderr || received.stdout);
	return JSON.parse(received.stdout);
}
const selectedVector = process.argv[2];
assert.ok(process.argv.length <= 3, 'receiving accepts at most one exact vector id');
const receivingVectors = selectedVector
	? vectors.filter((vector) => vector.id === selectedVector)
	: vectors;
assert.ok(
	receivingVectors.length > 0,
	'receiving vector id must belong to the independent inventory'
);
// The original macOS fixtures run on Hammerspoon's standard Lua 5.4 ABI.
// Preserve the configured interpreter exactly; an incompatible/missing one fails.
const lua = process.env.LUA || 'lua';
const luaAdmission = spawnSync(
	lua,
	[
		'-e',
		'assert(_VERSION == "Lua 5.4" and jit == nil and type(table.pack) == "function", "macOS opaque-owner receiving requires standard Lua 5.4; set LUA to that interpreter"); io.write(_VERSION)'
	],
	{ cwd: root, encoding: 'utf8', timeout: 10000 }
);
assert.ifError(luaAdmission.error);
assert.equal(luaAdmission.status, 0, luaAdmission.stderr || luaAdmission.stdout);
assert.equal(luaAdmission.stdout, 'Lua 5.4', 'standard Lua 5.4 must acknowledge its receiving ABI');
const bash = bashExecutable();
function emittedBootstrapPrelude(fixturePolicy, ownerRoot, interpreter) {
	const macos = path.join(root, 'static/ergopti_plus/macos').replace(/\\/g, '/');
	const shared = path.join(root, 'static/ergopti_plus/_shared/lua').replace(/\\/g, '/');
	const owner = shellPath(ownerRoot);
	const networkSource = fs.readFileSync(path.join(macos, 'modules/llm/network_env.lua'), 'utf8');
	const receiver = path.join(ownerRoot, 'platform/network/native_http.py');
	const admitted = fs.existsSync(receiver) ? [owner + '/platform/network/native_http.py'] : [];
	const source = [
		`package.path = ${JSON.stringify(`${macos}/?.lua;${macos}/?/init.lua;${shared}/?.lua;${shared}/?/init.lua;`)} .. package.path`,
		`local admitted = ${JSON.stringify(admitted).replace(/\[/g, '{').replace(/\]/g, '}')}`,
		'package.loaded["adapters.file_system"] = { exists = function(p) for _, v in ipairs(admitted) do if p == v then return true end end return false end }',
		`local Network = assert(load(${JSON.stringify(networkSource)}, ${JSON.stringify('@' + owner + '/modules/llm/network_env.lua')}))()`,
		`Network.policy_path = function() return ${JSON.stringify(shellPath(fixturePolicy))} end`,
		`local prelude, detail = Network.bootstrap_prelude("BOOTSTRAP", ${JSON.stringify(shellPath(interpreter))})`,
		'assert(prelude, detail); io.write(prelude)'
	].join('; ');
	const generated = spawnSync(lua, ['-e', source], { cwd: root, encoding: 'utf8', timeout: 10000 });
	assert.ifError(generated.error);
	assert.equal(generated.status, 0, generated.stderr || generated.stdout);
	return generated.stdout;
}
function emittedPrelude(fixturePolicy) {
	const macos = path.join(root, 'static/ergopti_plus/macos').replace(/\\/g, '/');
	const shared = path.join(root, 'static/ergopti_plus/_shared/lua').replace(/\\/g, '/');
	const source = [
		`package.path = ${JSON.stringify(`${macos}/?.lua;${macos}/?/init.lua;${shared}/?.lua;${shared}/?/init.lua;`)} .. package.path`,
		`local Network = assert(loadfile(${JSON.stringify(`${macos}/modules/llm/network_env.lua`)}))()`,
		`Network.policy_path = function() return ${JSON.stringify(shellPath(fixturePolicy))} end`,
		'local prelude, detail = Network.opaque_prelude("TEST")',
		'assert(prelude, detail); io.write(prelude)'
	].join('; ');
	const generated = spawnSync(lua, ['-e', source], { cwd: root, encoding: 'utf8', timeout: 10000 });
	assert.ifError(generated.error);
	assert.equal(generated.status, 0, generated.stderr || generated.stdout);
	return generated.stdout;
}
function emittedManagedPrelude(fixturePolicy) {
	const macos = path.join(root, 'static/ergopti_plus/macos').replace(/\\/g, '/');
	const shared = path.join(root, 'static/ergopti_plus/_shared/lua').replace(/\\/g, '/');
	const source = [
		`package.path = ${JSON.stringify(`${macos}/?.lua;${macos}/?/init.lua;${shared}/?.lua;${shared}/?/init.lua;`)} .. package.path`,
		...receivingNetworkSource(fixturePolicy),
		'local prelude, detail = Network.managed_http_prelude("MLX")',
		'assert(prelude, detail); io.write(prelude)'
	].join('; ');
	const generated = spawnSync(lua, ['-e', source], { cwd: root, encoding: 'utf8', timeout: 10000 });
	assert.ifError(generated.error);
	assert.equal(generated.status, 0, generated.stderr || generated.stdout);
	return generated.stdout;
}
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-opaque-network-'));
const actualPolicy = fs.readFileSync(policy, 'utf8');
const fixturePolicy = path.join(temporary, 'policy.sh');
const receiverPython = path.join(temporary, 'receiver-python');
const receiverOllama = path.join(temporary, 'receiver-ollama');
const managedRoot = path.join(
	temporary,
	'Managed.app/Contents/Resources/static/ergopti_plus/macos'
);
const managedReceiver = path.join(managedRoot, 'platform/network/native_http.py');
fs.mkdirSync(path.dirname(managedReceiver), { recursive: true });
fs.copyFileSync(
	path.join(root, 'static/ergopti_plus/macos/platform/network/native_http.py'),
	managedReceiver
);
const managedCalls = path.join(temporary, 'managed-receiver-calls');
const managedEnvironment = path.join(temporary, 'managed-receiver-environment');
const managedProbe =
	"import importlib.util,sys; s=importlib.util.spec_from_file_location('ergopti_native_admission',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m._resolve_worker()";
// This is a closed recording interpreter, never native authentication. The
// dependency refusal stops the complete original launcher before nohup.
fs.writeFileSync(
	receiverPython,
	'#!/bin/bash\n[ "$1" = -c ] || exit 64\n' +
		`if [ "$2" = ${quote(managedProbe)} ]; then\n` +
		`  [ "$#" -eq 3 ] && [ "$3" = ${quote(shellPath(managedReceiver))} ] && [ -f "$3" ] || exit 64\n` +
		`  printf 'admission\\n' >> ${quote(shellPath(managedCalls))}\n` +
		`  printf '%s\\n' "\${https_proxy-}" "\${HTTPS_PROXY-}" "\${all_proxy-}" "\${ALL_PROXY-}" "\${no_proxy-}" "\${NO_PROXY-}" "\${UV_SYSTEM_CERTS-}" "\${SSL_CERT_FILE-}" "\${REQUESTS_CA_BUNDLE-}" > ${quote(shellPath(managedEnvironment))}\n` +
		'  exit "${MANAGED_RECEIVER_CODE:-1}"\nfi\n' +
		'if [ "$#" -eq 2 ] && [ "$2" = "import huggingface_hub, truststore" ]; then\n' +
		`  printf 'dependencies\\n' >> ${quote(shellPath(managedCalls))}\n  exit 1\nfi\nexit 64\n`
);
fs.writeFileSync(
	receiverOllama,
	'#!/bin/bash\n[ "$1" = pull ] && [ "$2" = org/model ] || exit 65\nprintf "__OLLAMA_FETCH_STARTED__\\n"\n'
);
const prepared = spawnSync(
	bash,
	['-c', `chmod +x ${quote(shellPath(receiverPython))} ${quote(shellPath(receiverOllama))}`],
	{ encoding: 'utf8', timeout: 10000 }
);
assert.ifError(prepared.error);
assert.equal(prepared.status, 0, prepared.stderr || prepared.stdout);

try {
	const caseInputs = {
		https_proxy: "lower's literal $HOME ; $(printf must_not_execute)",
		HTTPS_PROXY: 'upper literal " `printf must_not_execute`',
		NO_PROXY: 'hostA,hostB',
		no_proxy: 'hostC,hostD'
	};
	const caseHost = fixtureHostEnvironment({
		...process.env,
		HtTpS_PrOxY: 'unowned-host-relay',
		nO_pRoXy: 'unowned-host-bypass'
	});
	assert.ok(
		!Object.keys(caseHost).some((key) => fixtureEnvironmentKeys.has(key.toUpperCase())),
		'host cleanup rejects every case variant of controlled inputs'
	);
	const caseReceived = spawnSync(
		bash,
		[
			'-c',
			fixturePosixEnvironment(
				'printf "%s\\n%s\\n%s\\n%s\\n" "$https_proxy" "$HTTPS_PROXY" "$NO_PROXY" "$no_proxy"',
				caseInputs
			)
		],
		{ env: caseHost, encoding: 'utf8', timeout: 10000 }
	);
	assert.ifError(caseReceived.error);
	assert.equal(caseReceived.signal, null, 'case-sensitive POSIX receiver input');
	assert.equal(caseReceived.status, 0, 'case-sensitive POSIX receiver input');
	assert.equal(caseReceived.stdout, Object.values(caseInputs).join('\n') + '\n');
	assert.equal(caseReceived.stderr, '', 'literal input cannot execute shell substitutions');
	console.log('ok - case-sensitive POSIX fixture inputs survive the actual host launch');
	for (const vector of receivingVectors) {
		const env = fixtureHostEnvironment();
		const script = `log_info() { :; }; log_error() { printf '%s\\n' "$1" >&2; }; . ${quote(shellPath(policy))};
opaque_system_proxy_snapshot() { printf '%s\\n' ${quote(vector.snapshot)}; return ${vector.getterCode || 0}; }
apply_system_network ${vector.mode === '' ? '' : 'opaque'}; received=$?;
printf '__FACT__:%s|%s|%s|%s|%s|%s\\n' "\${OPAQUE_NETWORK_FAILURE_PROVENANCE:-}" "\${OPAQUE_NETWORK_PROXY_RESOLUTION_STATUS:-}" "\${HTTPS_PROXY:-}" "\${https_proxy:-}" "\${UV_SYSTEM_CERTS:-}" "\${NO_PROXY:-}";
if [ "$received" -eq 0 ]; then printf '__CHILD_STARTED__\\n'; fi;
exit "$received"`;
		const result = spawnSync(bash, ['-c', fixturePosixEnvironment(script, vector.env)], {
			env,
			encoding: 'utf8',
			timeout: 10000
		});
		assert.ifError(result.error);
		assert.equal(result.signal, null, vector.id);
		assert.equal(result.status, vector.code, vector.id);
		const expected = `__FACT__:${vector.provenance}|${vector.resolution}|${vector.relay}|${vector.lowerRelay === undefined ? vector.relay : vector.lowerRelay}|${vector.child ? '1' : ''}|${vector.child ? 'localhost,127.0.0.1,::1' : ''}\n`;
		assert.equal(result.stdout, expected + (vector.child ? '__CHILD_STARTED__\n' : ''), vector.id);
		assert.ok(
			!result.stderr.includes('https://config.invalid/private.pac'),
			`${vector.id}: no PAC URL in failure`
		);
		if (vector.mode !== '') {
			fs.writeFileSync(
				fixturePolicy,
				`${actualPolicy}\nopaque_system_proxy_snapshot() { printf '%s\\n' ${quote(vector.snapshot)}; return ${vector.getterCode || 0}; }\n`
			);
			const prelude = emittedPrelude(fixturePolicy);
			const launched = spawnSync(
				bash,
				[
					'-c',
					fixturePosixEnvironment(
						`${prelude}printf '__CHILD_STARTED__:%s|%s|%s\\n' "\${HTTPS_PROXY:-}" "\${UV_SYSTEM_CERTS:-}" "\${NO_PROXY:-}"`,
						vector.env
					)
				],
				{ env, encoding: 'utf8', timeout: 10000 }
			);
			assert.ifError(launched.error);
			assert.equal(launched.status, vector.code, `${vector.id}: actual Lua-emitted prelude`);
			assert.equal(
				launched.stdout,
				vector.child ? `__CHILD_STARTED__:${vector.relay}|1|localhost,127.0.0.1,::1\n` : '',
				`${vector.id}: no next command after refusal`
			);
			const packet = emittedOwners(fixturePolicy, receiverPython, receiverOllama);
			assert.equal(packet.ollama.executable, '/bin/bash', `${vector.id}: original Mac pull slot`);
			assert.equal(packet.ollama.args.length, 2);
			assert.equal(packet.ollama.args[0], '-c');
			const actualPull = spawnSync(
				bash,
				['-c', fixturePosixEnvironment(packet.ollama.args[1], vector.env)],
				{
					env,
					encoding: 'utf8',
					timeout: 10000
				}
			);
			assert.ifError(actualPull.error);
			assert.equal(
				actualPull.status,
				vector.code,
				`${vector.id}: actual owner-emitted Ollama wrapper`
			);
			assert.equal(
				actualPull.stdout,
				vector.child ? '__OLLAMA_FETCH_STARTED__\n' : '',
				`${vector.id}: no outgoing CLI exec after refusal`
			);
			// The same literal receipt enters both classifiers; only Ollama's
			// actual opaque wrapper produced it. MLX's own bytes are checked below.
			const received = receiveOwners(fixturePolicy, actualPull.stderr, actualPull.status);
			const messages = vector.child
				? []
				: [`network.failure.${vector.provenance === 'verified' ? 'proxy' : 'unknown'}`];
			assert.deepEqual(
				received,
				{ ollama_messages: messages, mlx_messages: messages, report_calls: vector.child ? 0 : 2 },
				`${vector.id}: original authorized owner message reception`
			);
			if (!vector.child) {
				// These bytes exercise the two original callback classifiers only.
				// Ollama's opaque receipt is not evidence of MLX's managed routing.
				assert.deepEqual(
					receiveOwners(fixturePolicy, actualPull.stderr, actualPull.status, 'terminal_only'),
					received,
					`${vector.id}: buffered terminal stderr`
				);
				for (const mode of ['stale', 'start_refused'])
					assert.deepEqual(
						receiveOwners(fixturePolicy, actualPull.stderr, actualPull.status, mode),
						{ ollama_messages: [], mlx_messages: [], report_calls: 0 },
						`${vector.id}: ${mode} cannot publish a cause`
					);
				assert.deepEqual(
					receiveOwners(fixturePolicy, actualPull.stderr, actualPull.status, 'stale_during_report'),
					{ ollama_messages: [], mlx_messages: [], report_calls: 2 },
					`${vector.id}: reentrant report cannot publish a stale cause`
				);
			}

			if (!vector.child) {
				assert.equal(typeof packet.mlx.path, 'string');
				fs.writeFileSync(managedCalls, '');
				const actualLauncher = spawnSync(
					bash,
					['-c', fixturePosixEnvironment(packet.mlx.source, vector.env)],
					{
						env: { ...env, MANAGED_RECEIVER_CODE: '1' },
						encoding: 'utf8',
						timeout: 10000
					}
				);
				assert.ifError(actualLauncher.error);
				assert.equal(
					actualLauncher.status,
					78,
					`${vector.id}: independent managed receiver refusal, not snapshot refusal`
				);
				assert.equal(
					actualLauncher.stdout,
					`Python utilisé: ${shellPath(receiverPython)}\n`,
					`${vector.id}: no downloader execution after receiver refusal`
				);
				assert.ok(
					!actualLauncher.stdout.includes('__DLPID__'),
					`${vector.id}: no detached PID publication`
				);
				assert.equal(
					fs.readFileSync(managedCalls, 'utf8'),
					'admission\n',
					`${vector.id}: exactly one managed probe, no opaque fallback or dependency probe`
				);
				assert.ok(
					actualLauncher.stderr.includes(
						'__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:unavailable:unavailable\n'
					),
					`${vector.id}: own managed refusal receipt`
				);
				assert.deepEqual(
					receiveOwners(
						fixturePolicy,
						actualLauncher.stderr,
						actualLauncher.status,
						undefined,
						'mlx'
					),
					{ ollama_messages: [], mlx_messages: ['network.failure.unknown'], report_calls: 1 },
					`${vector.id}: MLX consumes its own unavailable receipt`
				);
				assert.deepEqual(
					receiveOwners(fixturePolicy, actualLauncher.stderr, 78, 'terminal_only', 'mlx'),
					{ ollama_messages: [], mlx_messages: ['network.failure.unknown'], report_calls: 1 },
					`${vector.id}: actual managed refusal in buffered terminal stderr`
				);
				for (const mode of ['stale', 'start_refused']) {
					assert.deepEqual(
						receiveOwners(fixturePolicy, actualLauncher.stderr, 78, mode, 'mlx'),
						{ ollama_messages: [], mlx_messages: [], report_calls: 0 },
						`${vector.id}: actual managed refusal ${mode} cannot publish`
					);
				}
				assert.deepEqual(
					receiveOwners(fixturePolicy, actualLauncher.stderr, 78, 'stale_during_report', 'mlx'),
					{ ollama_messages: [], mlx_messages: [], report_calls: 1 },
					`${vector.id}: actual managed refusal cannot publish after reentrant report`
				);
			}
		}
		console.log(`ok - ${vector.id}`);
	}
	// Independent managed-receiver expectations. The recorder authenticates no
	// native identity, performs no request and cannot reach the detached worker.
	const managedCases = [
		{
			id: 'managed-receiver-admitted-explicit-inputs',
			nativeCode: 0,
			code: 0,
			calls: 'admission\n',
			child: true
		},
		{
			id: 'managed-pac-receiver-admitted-empty-env',
			nativeCode: 0,
			code: 0,
			calls: 'admission\n',
			child: true,
			empty: true
		},
		{ id: 'managed-native-refused', nativeCode: 1, code: 78, calls: 'admission\n', child: false },
		{ id: 'managed-identity-refused', nativeCode: 64, code: 78, calls: 'admission\n', child: false }
	];
	const managedEnv = {
		https_proxy: 'http://lower.invalid:3129',
		HTTPS_PROXY: 'http://upper.invalid:3130',
		all_proxy: 'http://all-lower.invalid:3131',
		ALL_PROXY: 'http://all-upper.invalid:3132',
		no_proxy: 'lower.local',
		NO_PROXY: 'upper.local',
		UV_SYSTEM_CERTS: 'original',
		SSL_CERT_FILE: '/literal/original-ca',
		REQUESTS_CA_BUNDLE: '/literal/original-bundle'
	};
	const expectedManagedEnvironment =
		'http://lower.invalid:3129\nhttp://upper.invalid:3130\nhttp://all-lower.invalid:3131\nhttp://all-upper.invalid:3132\nlower.local\nupper.local\noriginal\n/literal/original-ca\n/literal/original-bundle\n';
	const postManagedEnvironment = path.join(temporary, 'post-managed-environment');
	fs.writeFileSync(
		fixturePolicy,
		actualPolicy +
			"\nopaque_system_proxy_snapshot() { printf '%s\\n' '<dictionary> {' ' ProxyAutoConfigEnable : 1' '}'; }\n"
	);
	for (const vector of managedCases) {
		fs.writeFileSync(managedCalls, '');
		const prelude = emittedManagedPrelude(fixturePolicy);
		const expectedEnvironment = vector.empty ? '\n\n\n\n\n\n\n\n\n' : expectedManagedEnvironment;
		const received = spawnSync(
			bash,
			[
				'-c',
				fixturePosixEnvironment(
					`PYTHON_BIN=${quote(shellPath(receiverPython))}; ` +
						prelude +
						`printf '%s\\n' "\${https_proxy-}" "\${HTTPS_PROXY-}" "\${all_proxy-}" "\${ALL_PROXY-}" "\${no_proxy-}" "\${NO_PROXY-}" "\${UV_SYSTEM_CERTS-}" "\${SSL_CERT_FILE-}" "\${REQUESTS_CA_BUNDLE-}" > ${quote(shellPath(postManagedEnvironment))}; ` +
						"printf '__MANAGED_CHILD_STARTED__\\n'",
					vector.empty ? {} : managedEnv
				)
			],
			{
				env: { ...fixtureHostEnvironment(), MANAGED_RECEIVER_CODE: String(vector.nativeCode) },
				encoding: 'utf8',
				timeout: 10000
			}
		);
		assert.ifError(received.error);
		assert.equal(received.status, vector.code, vector.id);
		assert.equal(fs.readFileSync(managedCalls, 'utf8'), vector.calls, vector.id);
		assert.equal(
			fs.readFileSync(managedEnvironment, 'utf8'),
			expectedEnvironment,
			`${vector.id}: inherited selectors, bypass and trust inputs remain untouched`
		);
		if (vector.child)
			assert.equal(
				fs.readFileSync(postManagedEnvironment, 'utf8'),
				expectedEnvironment,
				`${vector.id}: managed prelude does not rewrite inherited inputs after admission`
			);
		assert.equal(received.stdout, vector.child ? '__MANAGED_CHILD_STARTED__\n' : '', vector.id);
		assert.ok(
			received.stderr.includes(
				vector.child
					? '__ERGOPTI_OPAQUE_ADMISSION_V1__:accepted\n'
					: '__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:unavailable:unavailable\n'
			),
			vector.id
		);
		assert.ok(!received.stderr.includes('refused:verified:'), `${vector.id}: no opaque fallback`);
		console.log(`ok - ${vector.id}`);
	}
	const managedPacket = emittedOwners(fixturePolicy, receiverPython, receiverOllama);
	fs.writeFileSync(managedCalls, '');
	const admittedLauncher = spawnSync(
		bash,
		['-c', fixturePosixEnvironment(managedPacket.mlx.source, managedEnv)],
		{
			env: { ...fixtureHostEnvironment(), MANAGED_RECEIVER_CODE: '0' },
			encoding: 'utf8',
			timeout: 10000
		}
	);
	assert.ifError(admittedLauncher.error);
	assert.equal(
		admittedLauncher.status,
		1,
		'original dependency refusal stops the admitted full MLX launcher'
	);
	assert.equal(
		fs.readFileSync(managedCalls, 'utf8'),
		'admission\ndependencies\n',
		'actual full launcher admits native receiver before original dependency probe'
	);
	assert.ok(admittedLauncher.stderr.includes('__ERGOPTI_OPAQUE_ADMISSION_V1__:accepted\n'));
	assert.ok(
		!admittedLauncher.stdout.includes('__DLPID__'),
		'no detached downloader from recording interpreter'
	);
	assert.deepEqual(
		receiveOwners(
			fixturePolicy,
			admittedLauncher.stderr,
			admittedLauncher.status,
			undefined,
			'mlx'
		),
		{ ollama_messages: [], mlx_messages: [], report_calls: 0 },
		'admitted actual MLX stderr does not publish a proxy cause'
	);
	for (const mode of ['terminal_only', 'stale', 'start_refused', 'stale_during_report']) {
		assert.deepEqual(
			receiveOwners(fixturePolicy, admittedLauncher.stderr, admittedLauncher.status, mode, 'mlx'),
			{ ollama_messages: [], mlx_messages: [], report_calls: 0 },
			`admitted actual MLX stderr: ${mode} cannot invent a proxy cause`
		);
	}
	console.log('ok - managed full MLX launcher admission and original dependency refusal');
	// Literal repeated-activation expectations: no duplicate bypass or trust export.
	const activationSequences = [
		{ id: 'default-default', modes: ['', ''] },
		{ id: 'default-opaque', modes: ['', 'opaque'] },
		{ id: 'opaque-default', modes: ['opaque', ''] },
		{ id: 'opaque-opaque', modes: ['opaque', 'opaque'] }
	];
	for (const sequence of activationSequences) {
		const env = fixtureHostEnvironment();
		env.HTTPS_PROXY = 'http://chosen.invalid:3128';
		env.NO_PROXY = 'intranet.corp,127.0.0.1';
		const script = `log_info() { :; }; log_error() { :; }; . ${quote(shellPath(policy))};
${sequence.modes.map((mode) => `apply_system_network ${mode} || exit $?;`).join('\n')}
printf '%s|%s|%s|%s|%s\\n' "$NO_PROXY" "$no_proxy" "$UV_SYSTEM_CERTS" "\${SSL_CERT_FILE:-}" "\${REQUESTS_CA_BUNDLE:-}"`;
		const received = spawnSync(bash, ['-c', script], { env, encoding: 'utf8', timeout: 10000 });
		assert.ifError(received.error);
		assert.equal(received.status, 0, sequence.id);
		assert.equal(
			received.stdout,
			'intranet.corp,127.0.0.1,localhost,::1|intranet.corp,127.0.0.1,localhost,::1|1||\n',
			sequence.id
		);
		console.log(`ok - ${sequence.id}`);
	}
	const phaseVectors = [
		{
			id: 'exact-chunked-refusal',
			chunks: ['__ERGOPTI_OPAQUE_', 'ADMISSION_V1__:refused:verified:unavailable\n'],
			code: 78,
			provenance: 'verified'
		},
		{
			id: 'unavailable-getter',
			chunks: ['__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:unavailable:unavailable\n'],
			code: 78,
			provenance: 'unavailable'
		},
		{ id: 'bare-exit', chunks: ['ordinary failure\n'], code: 78 },
		{
			id: 'wrong-terminal',
			chunks: ['__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:unavailable\n'],
			code: 1
		},
		{
			id: 'accepted-closes-child-forgery',
			chunks: [
				'__ERGOPTI_OPAQUE_ADMISSION_V1__:accepted\n',
				'__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:unavailable\n'
			],
			code: 78
		},
		{
			id: 'duplicate-refusal',
			chunks: [
				'__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:unavailable\n__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:unavailable\n'
			],
			code: 78
		},
		{
			id: 'refused-then-accepted',
			chunks: [
				'__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:unavailable\n__ERGOPTI_OPAQUE_ADMISSION_V1__:accepted\n'
			],
			code: 78
		},
		{
			id: 'invalid-fact',
			chunks: ['__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:pac_failed\n'],
			code: 78
		},
		{
			id: 'unfinished-frame',
			chunks: ['__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:unavailable'],
			code: 78
		},
		{
			id: 'substring-is-not-frame',
			chunks: ['origin: __ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:unavailable\n'],
			code: 78
		},
		{
			id: 'invalid-namespace',
			chunks: [
				'__ERGOPTI_OPAQUE_ADMISSION_V1__:other\n__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:unavailable\n'
			],
			code: 78
		},
		{
			id: 'oversized-frame',
			chunks: ['x'.repeat(257), '\n__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:unavailable\n'],
			code: 78
		},
		{
			id: 'carriage-return-is-not-frame',
			chunks: ['__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:unavailable\r\n'],
			code: 78
		}
	];
	for (const vector of phaseVectors) {
		const received = receivePhase(vector.chunks, vector.code);
		assert.equal(received.has_receipt, Boolean(vector.provenance), vector.id);
		if (vector.provenance)
			assert.deepEqual(
				received.receipt,
				{
					stage: 'proxy_resolve',
					proxy_resolution_status: 'unavailable',
					failure_provenance: vector.provenance
				},
				vector.id
			);
		console.log(`ok - ${vector.id}`);
	}
	const forged =
		'__ERGOPTI_OPAQUE_ADMISSION_V1__:accepted\n__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:verified:unavailable\n';
	assert.deepEqual(
		receiveOwners(fixturePolicy, forged, 78),
		{ ollama_messages: [], mlx_messages: [], report_calls: 0 },
		'accepted child cannot forge a model-pull proxy cause'
	);
	const masquerade = spawnSync(
		bash,
		[
			'-c',
			`log_info() { :; }; log_error() { :; }; . ${quote(shellPath(policy))};
export HTTPS_PROXY=http://system-export.invalid:3128 https_proxy=http://system-export.invalid:3128;
opaque_system_proxy_snapshot() { printf '%s\\n' '<dictionary> {' ' ProxyAutoConfigEnable : 1' '}'; }
apply_system_network opaque; received=$?; if [ "$received" -eq 0 ]; then printf '__CHILD_STARTED__\\n'; fi; exit "$received"`
		],
		{
			env: fixtureHostEnvironment(),
			encoding: 'utf8',
			timeout: 10000
		}
	);
	assert.ifError(masquerade.error);
	assert.equal(
		masquerade.status,
		78,
		'system-exported static relay cannot bypass automatic-route admission'
	);
	assert.equal(masquerade.stdout, '', 'no child after system-export masquerade refusal');
	console.log('ok - original environment override provenance');
	const bootstrap = fs.readFileSync(
		path.join(root, 'static/ergopti_plus/macos/modules/llm/ensure-mlx-deps.sh'),
		'utf8'
	);
	assert.equal(
		(bootstrap.match(/apply_system_network opaque \|\| exit \$\?/g) || []).length,
		3,
		'Python download, repair rebuild and slow venv/sync each propagate refusal'
	);
	assert.ok(
		bootstrap.indexOf('apply_system_network opaque || exit $?') <
			bootstrap.indexOf('emit_marker "PYTHON_INSTALLING"'),
		'Python admission precedes download marker'
	);
	assert.ok(
		bootstrap.includes('\napply_system_network\n'),
		'native curl uv wheel and cached probes retain default activation'
	);
	const curlBootstrap = fs.readFileSync(
		path.join(root, 'static/ergopti_plus/macos/modules/llm/ensure-ollama-deps.sh'),
		'utf8'
	);
	assert.ok(
		curlBootstrap.includes('\napply_system_network\n'),
		'native curl installer retains default admission'
	);
	const localServer = fs.readFileSync(
		path.join(root, 'static/ergopti_plus/macos/modules/llm/ollama_server_command.lua'),
		'utf8'
	);
	assert.ok(
		localServer.includes('NetworkEnv.prelude("OLLAMA-SERVER")'),
		'local serving retains default static policy'
	);
	const hfPull = fs.readFileSync(
		path.join(root, 'static/ergopti_plus/macos/ui/menu/menu_llm/models_manager_mlx_download.lua'),
		'utf8'
	);
	assert.ok(
		hfPull.includes('NetworkEnv.managed_http_prelude("MLX")'),
		'actual HF pull owns managed receiver admission'
	);
	const ollamaPull = fs.readFileSync(
		path.join(root, 'static/ergopti_plus/macos/ui/menu/menu_llm/models_manager_ollama.lua'),
		'utf8'
	);
	assert.ok(
		ollamaPull.includes('NetworkEnv.opaque_prelude("OLLAMA-PULL")'),
		'actual Ollama pull owns opaque admission'
	);
	assert.ok(
		ollamaPull.includes('TaskLifecycle.native("Ollama model pull", BASH_BIN'),
		'original owned task runs the admission wrapper'
	);
	assert.ok(
		ollamaPull.includes('end, {"-c", pull_command})'),
		'exec wrapper remains in original physical slot'
	);
	console.log('ok - actual script boundary ownership');
	// The interpreter is a closed recording boundary, not native authentication.
	// The emitted production prelude still calls the existing _resolve_worker
	// owner; its native identity tests independently cover that admission.
	const bootstrapRoot = path.join(
		temporary,
		'Bootstrap.app/Contents/Resources/static/ergopti_plus/macos'
	);
	fs.mkdirSync(path.join(bootstrapRoot, 'platform/network'), { recursive: true });
	fs.mkdirSync(path.join(bootstrapRoot, 'modules/llm'), { recursive: true });
	fs.copyFileSync(
		path.join(root, 'static/ergopti_plus/macos/platform/network/native_http.py'),
		path.join(bootstrapRoot, 'platform/network/native_http.py')
	);
	fs.writeFileSync(
		path.join(bootstrapRoot, 'modules/llm/managed_bootstrap_http.py'),
		'# receiver-owned presence control\n'
	);
	const nativeCalls = path.join(temporary, 'native-admission-calls');
	const nativeInterpreter = path.join(temporary, 'native-admission-interpreter');
	fs.writeFileSync(
		nativeInterpreter,
		`#!/bin/bash\n[ "$1" = -c ] || exit 64\n` +
			`case "$2" in *'s.loader.exec_module(m); m._resolve_worker()'*) ;; *) exit 64 ;; esac\n` +
			`[ "$3" = ${quote(shellPath(path.join(bootstrapRoot, 'platform/network/native_http.py')))} ] || exit 64\n` +
			`printf 'called\n' >> ${quote(shellPath(nativeCalls))}\n[ -f "$3" ] || exit 78\nexit "\${NATIVE_ADMISSION_CODE:-0}"\n`
	);
	const executable = spawnSync(bash, ['-c', `chmod +x ${quote(shellPath(nativeInterpreter))}`], {
		encoding: 'utf8',
		timeout: 10000
	});
	assert.ifError(executable.error);
	assert.equal(executable.status, 0, executable.stderr || executable.stdout);

	const bootstrapCases = [
		{
			id: 'missing-receiver-explicit-retained',
			missing: true,
			launcher: '/owned/ErgoptiPlus',
			env: { HTTPS_PROXY: 'http://chosen.invalid:3129' },
			code: 0,
			calls: 0,
			child: true
		},
		{
			id: 'missing-receiver-native-refusal',
			missing: true,
			launcher: '/owned/ErgoptiPlus',
			code: 78,
			calls: 1,
			child: false
		},
		{ id: 'native-pac-admission', launcher: '/owned/ErgoptiPlus', code: 0, calls: 1, child: true },
		{
			id: 'native-identity-refusal-no-fallback',
			launcher: '/owned/ErgoptiPlus',
			nativeCode: 1,
			code: 78,
			calls: 1,
			child: false
		},
		{ id: 'manual-pac-refusal', launcher: '', code: 78, calls: 0, child: false },
		{
			id: 'explicit-route-retained',
			launcher: '/owned/ErgoptiPlus',
			env: { HTTPS_PROXY: 'http://chosen.invalid:3129' },
			code: 0,
			calls: 0,
			child: true
		},
		{
			id: 'lowercase-route-retained',
			launcher: '/owned/ErgoptiPlus',
			env: { https_proxy: 'http://lower.invalid:3129', HTTPS_PROXY: 'http://upper.invalid:3129' },
			code: 0,
			calls: 0,
			child: true
		}
	];
	fs.writeFileSync(
		fixturePolicy,
		actualPolicy +
			"\nopaque_system_proxy_snapshot() { printf '%s\\n' '<dictionary> {' ' ProxyAutoConfigEnable : 1' '}'; }\n"
	);
	for (const vector of bootstrapCases) {
		fs.writeFileSync(nativeCalls, '');
		const receiver = path.join(bootstrapRoot, 'platform/network/native_http.py');
		if (vector.missing) fs.renameSync(receiver, receiver + '.held');
		const bootstrapPrelude = emittedBootstrapPrelude(
			fixturePolicy,
			bootstrapRoot,
			nativeInterpreter
		);
		const received = spawnSync(
			bash,
			[
				'-c',
				`export ERGOPTI_LAUNCHER_EXECUTABLE=${quote(vector.launcher)} NATIVE_ADMISSION_CODE=${vector.nativeCode || 0}; ` +
					fixturePosixEnvironment(
						bootstrapPrelude + "printf '__BOOTSTRAP_CHILD_STARTED__\\n'",
						vector.env
					)
			],
			{ env: fixtureHostEnvironment(), encoding: 'utf8', timeout: 10000 }
		);
		if (vector.missing) fs.renameSync(receiver + '.held', receiver);
		assert.ifError(received.error);
		assert.equal(
			received.status,
			vector.code,
			`${vector.id}: exact terminal status: ${received.stderr}`
		);
		assert.equal(
			fs.readFileSync(nativeCalls, 'utf8'),
			'called\n'.repeat(vector.calls),
			`${vector.id}: interpreter admission calls`
		);
		assert.equal(
			received.stdout,
			vector.child ? '__BOOTSTRAP_CHILD_STARTED__\n' : '',
			`${vector.id}: downstream child admission`
		);
		assert.ok(
			received.stderr.includes(
				vector.child
					? '__ERGOPTI_OPAQUE_ADMISSION_V1__:accepted\n'
					: `__ERGOPTI_OPAQUE_ADMISSION_V1__:refused:${vector.calls ? 'unavailable' : 'verified'}:unavailable\n`
			),
			vector.id
		);
		console.log(`ok - ${vector.id}`);
	}
} finally {
	fs.rmSync(temporary, { recursive: true, force: true });
}
