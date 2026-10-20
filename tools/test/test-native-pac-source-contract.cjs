// tools/test/test-native-pac-source-contract.cjs
'use strict';

/** Portable source/binding/evidence controls; native URLSession/SSPI remain separate. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');
const reader = require('../diagnostics/native_pac_source_evidence.cjs');
const root = path.resolve(__dirname, '../..');
const sourceDirectory = path.join(
	root,
	'static',
	'ergopti_plus',
	'macos',
	'launcher',
	'Sources',
	'ErgoptiPlus'
);
const source = fs.readFileSync(path.join(sourceDirectory, 'ManagedPACSource.swift'), 'utf8');
const worker = fs.readFileSync(path.join(sourceDirectory, 'ManagedHTTPWorker.swift'), 'utf8');
const tests = fs.readFileSync(
	path.join(
		root,
		'static',
		'ergopti_plus',
		'macos',
		'launcher',
		'Tests',
		'ErgoptiPlusTests',
		'ManagedPACSourceTests.swift'
	),
	'utf8'
);
let passed = 0;
const check = (label, action) => {
	action();
	passed++;
};
const swiftString = (literal) => JSON.parse(literal);
const binding = /let bound = script \+ ([\s\S]+?)\n\t\tguard bound/.exec(source);
assert.ok(binding, 'the actual Swift binding template must exist');
const parts = [...binding[1].matchAll(/"(?:[^"\\]|\\.)*"|\barguments\b/g)].map((match) => match[0]);
assert.equal(parts.filter((part) => part === 'arguments').length, 1);
const bind = (script, url, host) =>
	script +
	parts
		.map((part) =>
			part === 'arguments'
				? JSON.stringify([url, host])
						.replaceAll('\u2028', '\\u2028')
						.replaceAll('\u2029', '\\u2029')
				: swiftString(part)
		)
		.join('');
const execute = (script, url, host, rawURL) => {
	const context = {};
	vm.runInNewContext(bind(script, url, host), context, { timeout: 1000 });
	return vm.runInNewContext(
		`FindProxyForURL(${JSON.stringify(rawURL)},${JSON.stringify(host)})`,
		context,
		{ timeout: 1000 }
	);
};

for (const scheme of ['http', 'https']) {
	const exact = `${scheme}://same.example:4455/a?case=%22%5C%0A`;
	check('full-request-' + scheme, () =>
		assert.equal(
			execute(
				'function FindProxyForURL(url,host){return url+"|"+host;}',
				exact,
				'same.example',
				`${scheme}://same.example:4455/`
			),
			exact + '|same.example'
		)
	);
}
check('recursive-native-function-preserves-its-own-arguments', () =>
	assert.equal(
		execute(
			'function FindProxyForURL(url,host){if(url==="internal"){return "DIRECT";}return FindProxyForURL("internal",host);}',
			'https://same.example/full',
			'same.example',
			'https://same.example/'
		),
		'DIRECT'
	)
);
check('existing-native-helpers-stay-in-the-same-context', () => {
	const context = { dnsDomainIs: (host, suffix) => host.endsWith(suffix) };
	vm.runInNewContext(
		bind(
			'function FindProxyForURL(u,h){return dnsDomainIs(h,".example")?"DIRECT":"PROXY wrong.invalid:1";}',
			'https://same.example/a',
			'same.example'
		),
		context,
		{ timeout: 1000 }
	);
	assert.equal(vm.runInNewContext('FindProxyForURL("wrong","wrong")', context), 'DIRECT');
});
for (const script of [
	'var FindProxyForURL=1;',
	'Object.defineProperty(this,"FindProxyForURL",{value:function(){return "DIRECT";},writable:false});'
]) {
	check('invalid-or-nonwritable-function-refuses', () =>
		assert.throws(() =>
			execute(script, 'https://same.example/a', 'same.example', 'https://same.example/')
		)
	);
}
check('a-global-setter-cannot-silently-discard-the-full-request-binding', () =>
	assert.throws(() =>
		execute(
			'var original=function(u,h){return u;};Object.defineProperty(this,"FindProxyForURL",{get:function(){return original;},set:function(value){}});',
			'https://same.example/full',
			'same.example',
			'https://same.example/'
		)
	)
);
check('an-alternating-global-getter-cannot-pass-only-the-installation-check', () =>
	assert.throws(() =>
		execute(
			'var saved=function(u,h){return u;};var chosen,reads=0;Object.defineProperty(this,"FindProxyForURL",{get:function(){reads++;return reads===2?chosen:saved;},set:function(value){chosen=value;}});',
			'https://same.example/full',
			'same.example',
			'https://same.example/'
		)
	)
);
check('quote-newline-and-script-separators-remain-data', () => {
	const exact = 'https://same.example/a?fixture="\\\n\u2028\u2029';
	assert.equal(
		execute('function FindProxyForURL(u,h){return u;}', exact, 'same.example', 'wrong'),
		exact
	);
});
check('every-redirect-starts-after-native-session-invalidation', () => {
	assert.match(
		source,
		/guard retain\(owner\), let result = owner\.execute\(current\) else \{ return nil \}/
	);
	assert.match(source, /let admitted = invalidated && failure == nil/);
	assert.ok(source.indexOf('settled.wait(timeout:') < source.indexOf('let admitted = invalidated'));
	assert.match(source, /completionHandler\(nil\)/);
	assert.doesNotMatch(source, /completionHandler\(request\(next\)\)/);
});
check('retirement-debt-refuses-replacement-before-construction', () => {
	assert.match(
		source,
		/guard !hasDebt, ProcessInfo\.processInfo\.systemUptime < deadline else \{ return nil \}/
	);
	assert.match(source, /guard retained\.isEmpty else \{ return false \}/);
	assert.ok(
		source.indexOf('invalidated = true') <
			source.indexOf('ManagedPACSource.retire(self)', source.indexOf('didBecomeInvalidWithError'))
	);
});
check('source-does-not-claim-logical-cancel-as-physical-settlement', () => {
	const cancellation = source.slice(
		source.indexOf('guard wait > 0'),
		source.indexOf('let admitted = invalidated')
	);
	assert.match(cancellation, /task\.cancel\(\)/);
	assert.match(cancellation, /session\.invalidateAndCancel\(\)/);
	assert.doesNotMatch(cancellation, /ManagedPACSource\.retire/);
});
check('original-clock-includes-settings-preparation', () => {
	const method = worker.slice(
		worker.indexOf('static func routes('),
		worker.indexOf('static func discoveryURLs')
	);
	assert.ok(method.indexOf('let deadline =') < method.indexOf('settingsProvider()'));
	assert.equal((method.match(/let deadline =/g) || []).length, 1);
	assert.match(method, /ProcessInfo\.processInfo\.systemUptime < deadline else \{ return nil \}/);
});
check('fullURL-binding-uses-public-script-boundary', () => {
	assert.match(worker, /let bound = try\? ManagedPACSource\.bind\(source, url: url\)/);
	assert.match(
		worker,
		/return evaluateNative\(url: url, pacURL: nil, script: bound, deadline: deadline\)/
	);
	assert.match(worker, /CFNetworkExecuteProxyAutoConfigurationScript/);
	assert.doesNotMatch(source, /JavaScriptCore|JSContext|dlopen|URLProtocol\.registerClass/);
});
check('credential-scope-cannot-follow-foreign-authority', () => {
	assert.match(source, /authority == initial/);
	assert.match(source, /challenge\.protectionSpace\.host\.lowercased\(\) == initial\.host/);
	assert.match(source, /challenge\.protectionSpace\.port == initial\.port/);
	assert.match(source, /challenge\.protectionSpace\.protocol\?\.lowercased\(\) == initial\.scheme/);
});
check('isolated-native-source-session-preserves-enterprise-hostname-trust', () => {
	for (const property of ['urlCache', 'urlCredentialStorage', 'httpCookieStorage'])
		assert.ok(source.includes(`configuration.${property} = nil`));
	assert.match(source, /ManagedCertificateAuthorities\.evaluate\(trust, adding: certificates\)/);
	assert.match(
		source,
		/data\.count <= ManagedNetworkBootstrapPolicy\.maximumPACSourceBytes - body\.count/
	);
	assert.match(source, /from\.scheme != "https" \|\| to\.scheme == "https"/);
});

check('standalone-native-producers-copy-hash-and-compile-the-source-owner', () => {
	// Follow the actual centralized recipe and its fixed caller; comments and
	// obsolete inline local names confer no copy/hash/compile evidence.
	const recipe = spawnSync(
		pythonExecutable(),
		[
			'-I',
			'-B',
			'-c',
			String.raw`
import ast
from pathlib import Path
import sys

support = Path(sys.argv[1]) / "static/ergopti_plus/macos/tests/support"
builder = ast.parse((support / "native_http_fixture_builder.py").read_bytes())
caller = ast.parse((support / "native_http_wire_client_receiving.py").read_bytes())

def unique(nodes):
    values = list(nodes)
    assert len(values) == 1, "actual source owner must be unique"
    return values[0]

def expression(node):
    return ast.unparse(node)

def function(tree, owner, name):
    cls = unique(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == owner)
    return unique(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == name)

def assignment(nodes, target):
    return unique(n for n in nodes if isinstance(n, ast.Assign)
                  and [expression(t) for t in n.targets] == [target])

mac = assignment(builder.body, "MAC")
assert ast.literal_eval(mac.value) == "static/ergopti_plus/macos/"
swift_inputs = assignment(builder.body, "SWIFT_INPUTS").value
assert isinstance(swift_inputs, ast.BinOp) and isinstance(swift_inputs.op, ast.Add)
assert isinstance(swift_inputs.left, ast.Call) and expression(swift_inputs.left.func) == "tuple"
generator = unique(swift_inputs.left.args)
assert isinstance(generator, ast.GeneratorExp)
assert expression(generator.elt) == "MAC + 'launcher/Sources/ErgoptiPlus/' + name"
loop = unique(generator.generators)
assert expression(loop.target) == "name" and not loop.ifs and not loop.is_async
assert ast.literal_eval(loop.iter) == (
    "ManagedHTTPWorker.swift", "ManagedPACSource.swift",
    "ManagedCertificateAuthorities.swift", "ManagedBootstrapPolicy.generated.swift",
)
assert expression(swift_inputs.right) == "(MAC + 'tests/support/native_http_fixture_main.swift',)"

stage = function(builder, "OwnedFixtureBuild", "_stage")
assert expression(assignment(stage.body, "content").value) == "_source(original)"
assert expression(assignment(stage.body, "target").value) == "self.root / relative"
unique(n for n in stage.body if isinstance(n, ast.Expr)
       and expression(n.value) == "target.write_bytes(content)")
assert expression(assignment(stage.body, "self.source_hashes[original]").value) == "_digest(content)"
assert expression(assignment(stage.body, "self.staged_hashes[str(relative)]").value) == "_digest(content)"
assert isinstance(stage.body[-1], ast.Return) and expression(stage.body[-1].value) == "target"

verify = function(builder, "OwnedFixtureBuild", "_verify_sources")
source_loop = unique(n for n in verify.body if isinstance(n, ast.For)
                    and expression(n.iter) == "self.source_hashes.items()")
staged_loop = unique(n for n in verify.body if isinstance(n, ast.For)
                    and expression(n.iter) == "self.staged_hashes.items()")
for loop, comparison in (
    (source_loop, "_digest(_source(relative)) != digest"),
    (staged_loop, "_digest(regular_bytes(path)[0]) != digest"),
):
    refused = unique(n for n in loop.body if isinstance(n, ast.If)
                     and expression(n.test) == comparison)
    assert any(isinstance(n, ast.Raise) for n in refused.body)

build = function(builder, "OwnedFixtureBuild", "build")
assert expression(assignment(build.body, "swift").value) == (
    "[self._stage(path, Path(path).name) for path in SWIFT_INPUTS]"
)
compiler = unique(n for n in build.body if isinstance(n, ast.Expr)
                 and isinstance(n.value, ast.Call)
                 and expression(n.value.func) == "self._command"
                 and n.value.args and isinstance(n.value.args[0], ast.List)
                 and isinstance(n.value.args[0].elts[0], ast.Constant)
                 and n.value.args[0].elts[0].value == "/usr/bin/xcrun")
arguments = compiler.value.args[0].elts
assert [ast.literal_eval(n) for n in arguments[:5]] == [
    "/usr/bin/xcrun", "swiftc", "-parse-as-library", "-D",
    "ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS",
]
unique(n for n in arguments if isinstance(n, ast.Starred)
       and expression(n.value) == "map(str, swift)")
assert {k.arg: ast.literal_eval(k.value) for k in compiler.value.keywords} == {"timeout": 60}
checks = [n.lineno for n in build.body if isinstance(n, ast.Expr)
          and expression(n.value) == "self._verify_sources()"]
assert any(line < compiler.lineno for line in checks)
assert any(line > compiler.lineno for line in checks)

setup = function(caller, "RealNativeClientReceiving", "setUpClass")
body = unique(n for n in setup.body if isinstance(n, ast.Try)).body
spec = assignment(body, "build_spec")
assert expression(spec.value.func) == "importlib.util.spec_from_file_location"
assert [expression(a) for a in spec.value.args] == [
    "'owned_native_http_build'", "Path(__file__).with_name('native_http_fixture_builder.py')",
]
module = assignment(body, "builder")
assert expression(module.value) == "importlib.util.module_from_spec(build_spec)"
load = unique(n for n in body if isinstance(n, ast.Expr)
              and expression(n.value) == "build_spec.loader.exec_module(builder)")
owned = assignment(body, "cls.build")
assert expression(owned.value) == "builder.OwnedFixtureBuild(cls.fixture)"
consume = unique(n for n in body if isinstance(n, ast.Expr)
                 and expression(n.value) == "cls.build.build()")
assert spec.lineno < module.lineno < load.lineno < owned.lineno < consume.lineno
print("PAC_CENTRAL_RECIPE_AND_FIXED_CALLER=PASS")
`,
			root
		],
		{ cwd: root, encoding: 'utf8', timeout: 10000 }
	);
	assert.equal(recipe.status, 0, recipe.stderr || recipe.stdout);
	assert.equal(recipe.signal, null);
	assert.equal(recipe.error, undefined);
	assert.equal(recipe.stdout.trim(), 'PAC_CENTRAL_RECIPE_AND_FIXED_CALLER=PASS');
	const model = fs.readFileSync(
		path.join(root, 'tools/diagnostics/macos_managed_ollama_receiving.py'),
		'utf8'
	);
	assert.match(model, /\("ManagedPACSource\.swift", pac_source\)/);
	assert.match(
		model,
		/"static\/ergopti_plus\/macos\/launcher\/Sources\/ErgoptiPlus\/ManagedPACSource\.swift",\s+pac_source,/
	);
	assert.match(model, /"swiftc",[\s\S]*?str\(pac_source\),/);
});
check('existing-linux-python-policy-admission-is-unchanged', () => {
	const result = spawnSync(
		pythonExecutable(),
		[
			'-I',
			'-c',
			`
import importlib.util,json,sys
spec=importlib.util.spec_from_file_location('actual_policy',sys.argv[2]);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
current=json.load(open(sys.argv[1],encoding='utf-8')); previous=json.loads(json.dumps(current));del previous['native_pac']['source_acquisition']
vectors=[('http://127.0.0.1/a',{},('direct',None)),('https://outside.example/a',{},('native',None)),('https://outside.example/a',{'HTTPS_PROXY':'http://proxy.example:3128'},('environment','http://proxy.example:3128'))]
for data in [previous,current]:
 policy=module.ProxyPolicy(data)
 for url,environment,expected in vectors:assert policy.route(url,environment)==expected
print('LINUX_POLICY original=3 extended=3 unchanged=true')
`,
			path.join(root, 'static/ergopti_plus/_shared/modules/network/proxy_policy.json'),
			path.join(root, 'static/ergopti_plus/_shared/python/network_proxy_policy.py')
		],
		{ encoding: 'utf8', timeout: 10000 }
	);
	assert.equal(result.error, undefined);
	assert.equal(result.status, 0, result.stderr);
	assert.equal(result.stdout.trim(), 'LINUX_POLICY original=3 extended=3 unchanged=true');
});

check('source-peer-native-start-retains-exact-owner-before-attempt', () => {
	const initialization = tests.slice(
		tests.indexOf('init() throws {'),
		tests.indexOf('private func retainDebt()')
	);
	for (const statement of [
		'retainDebt()',
		'startAttempted = true',
		'try process.run()',
		'startAcknowledged = true'
	])
		assert.ok(initialization.includes(statement));
	assert.ok(initialization.indexOf('retainDebt()') < initialization.indexOf('try process.run()'));
	assert.ok(
		initialization.indexOf('startAttempted = true') < initialization.indexOf('try process.run()')
	);
	assert.ok(
		initialization.indexOf('try process.run()') < initialization.indexOf('startAcknowledged = true')
	);
});
check('unacknowledged-source-peer-start-does-not-infer-no-child-or-close-endpoints', () => {
	const refusal = tests.slice(
		tests.indexOf('if !startAcknowledged {'),
		tests.indexOf('try? close()')
	);
	assert.match(refusal, /startupFailure = error/);
	assert.match(refusal, /throw error/);
	assert.doesNotMatch(refusal, /isRunning|\.close\(|removeAll/);
});
check('source-peer-close-refusal-latches-before-same-endpoint-retry', () => {
	const close = tests.slice(
		tests.indexOf('func close() throws {'),
		tests.indexOf('final class ManagedPACSourceTests')
	);
	for (const statement of [
		'if let cleanupFailure { throw cleanupFailure }',
		'if let startupFailure { throw startupFailure }',
		'guard process.terminationStatus == 0',
		'Self.retainedDebt.removeAll'
	])
		assert.ok(close.includes(statement));
	assert.ok(
		close.indexOf('if let cleanupFailure { throw cleanupFailure }') <
			close.indexOf('try input.fileHandleForWriting.close()')
	);
	assert.ok(
		close.indexOf('if let startupFailure { throw startupFailure }') <
			close.indexOf('if closed { return }')
	);
	assert.match(close, /catch \{\s+cleanupFailure = error\s+retainDebt\(\)/);
	assert.ok(
		close.indexOf('guard process.terminationStatus == 0') <
			close.indexOf('Self.retainedDebt.removeAll')
	);
});
check('source-peer-original-read-deadline-includes-native-acquisition', () => {
	const initialization = tests.slice(
		tests.indexOf('init() throws {'),
		tests.indexOf('private func retainDebt()')
	);
	assert.ok(initialization.indexOf('let deadline =') < initialization.indexOf('try process.run()'));
	assert.match(initialization, /profile = try Self.read\(output, deadline: deadline\)/);
	assert.equal((initialization.match(/systemUptime \+ 20/g) || []).length, 1);
});

const sourceMethods = [...tests.matchAll(/\bfunc (test\w+)\(/g)].map((match) => match[1]);
check('ten-source-tests-have-an-exact-independent-reader-inventory', () => {
	assert.equal(sourceMethods.length, 10);
	assert.deepEqual(reader.METHODS.ManagedPACSourceTests, sourceMethods);
});
const summary = (count) =>
	` Executed ${count} tests, with 0 failures (0 unexpected) in 1.0 seconds`;
const lines = [
	"Test Suite 'Selected tests' started at fixed.",
	"Test Suite 'ErgoptiPlusPackageTests.xctest' started at fixed.",
	"Test Suite 'ManagedPACSourceTests' started at fixed."
];
for (const method of sourceMethods) {
	const name = `-[ErgoptiPlusTests.ManagedPACSourceTests ${method}]`;
	lines.push(`Test Case '${name}' started.`, `Test Case '${name}' passed (0.001 seconds).`);
}
lines.push(
	"Test Suite 'ManagedPACSourceTests' passed at fixed.",
	summary(10),
	"Test Suite 'ErgoptiPlusPackageTests.xctest' passed at fixed.",
	summary(10),
	"Test Suite 'Selected tests' passed at fixed.",
	summary(10)
);
const valid = lines.join('\n');
check('exact-source-cohort-receives', () =>
	assert.equal(reader.evaluate(valid, 0, 0).complete, true)
);
for (const method of sourceMethods) {
	const name = `-[ErgoptiPlusTests.ManagedPACSourceTests ${method}]`;
	for (const state of ['failed', 'skipped'])
		check(state + method, () =>
			assert.equal(
				reader.evaluate(valid.replace(`'${name}' passed`, `'${name}' ${state}`), 0, 0).complete,
				false
			)
		);
	check('missing-' + method, () =>
		assert.equal(
			reader.evaluate(
				valid.replace(
					`Test Case '${name}' started.\nTest Case '${name}' passed (0.001 seconds).\n`,
					''
				),
				0,
				0
			).complete,
			false
		)
	);
}
for (const changed of [
	valid + '\n' + summary(10),
	valid.replace('Executed 10', 'Executed 010'),
	valid.replace('Selected tests', 'All tests'),
	valid.replace('ManagedPACSourceTests', 'ForeignTests')
])
	check('malformed-cohort-refuses', () =>
		assert.equal(reader.evaluate(changed, 0, 0).complete, false)
	);
for (const [swift, capture] of [
	[1, 0],
	[0, 1],
	[73, 0]
])
	check('native-pipeline-refusal-remains-red', () =>
		assert.equal(reader.evaluate(valid, swift, capture).complete, false)
	);

const windowsSourceFixture = fs.readFileSync(
	path.join(root, 'static/ergopti_plus/windows/tests/fixtures/pac_source_contract.ps1'),
	'utf8'
);
/** Mask PowerShell comments and string data while preserving source offsets. */
function powerShellExecutablePositions(definition) {
	const masked = definition.split('').map((value) => (value === '\n' ? '\n' : ' '));
	let quote = '';
	let here = '';
	let blockDepth = 0;
	let lineComment = false;
	for (let index = 0; index < definition.length; index++) {
		const value = definition[index];
		const next = definition[index + 1];
		if (lineComment) {
			if (value === '\n') lineComment = false;
			continue;
		}
		if (blockDepth) {
			if (value === '<' && next === '#') {
				blockDepth++;
				index++;
			} else if (value === '#' && next === '>') {
				blockDepth--;
				index++;
			}
			continue;
		}
		if (here) {
			if ((index === 0 || definition[index - 1] === '\n') && value === here && next === '@') {
				here = '';
				index++;
			}
			continue;
		}
		if (quote) {
			if (quote === '"' && value === '`') index++;
			else if (value === quote && next === quote) index++;
			else if (value === quote) quote = '';
			continue;
		}
		if (value === '`') {
			index++;
			continue;
		}
		if (value === '<' && next === '#') {
			blockDepth = 1;
			index++;
			continue;
		}
		if (value === '#') {
			lineComment = true;
			continue;
		}
		if (
			value === '@' &&
			(next === "'" || next === '"') &&
			/^[^\S\r\n]*\r?\n/.test(definition.slice(index + 2))
		) {
			here = next;
			index++;
			continue;
		}
		if (value === "'" || value === '"') {
			quote = value;
			continue;
		}
		masked[index] = value;
	}
	assert.equal(blockDepth, 0, 'PowerShell block comment must terminate.');
	assert.equal(quote, '', 'PowerShell quoted string must terminate.');
	assert.equal(here, '', 'PowerShell here string must terminate.');
	return masked.join('');
}

/** Observe only the two executable native Fetch calls, retaining their raw data. */
function windowsFetchArgumentExpressions(definition) {
	const executable = powerShellExecutablePositions(definition);
	const head = '$Fetch.Invoke($null, ';
	const expressions = [
		...definition.matchAll(/\$Fetch\.Invoke\(\$null, (@\([\s\S]*?\[int\]50\))\)/g)
	]
		.filter((match) => executable.slice(match.index, match.index + head.length) === head)
		.map((match) => match[1]);
	assert.equal(expressions.length, 2, 'Exactly two executable native Fetch families are required.');
	return expressions;
}

const fetchArgumentExpressions = windowsFetchArgumentExpressions(windowsSourceFixture);
check('both-native-source-fetch-families-retain-five-reflection-arguments', () => {
	assert.equal(fetchArgumentExpressions.length, 2);
	for (const expression of fetchArgumentExpressions)
		assert.match(
			expression,
			/^@\(\('http:\/\/127\.0\.0\.1:' \+ \$First\.Port \+ '\/' \+ \$Path\),/
		);
});

const literalFetchCalls = [
	...windowsSourceFixture.matchAll(/\$Fetch\.Invoke\(\$null, (@\([\s\S]*?\[int\]50\))\)/g)
].map((match) => match[0]);
check('comment-only-source-fetch-lookalikes-never-meet-the-executable-floor', () => {
	assert.equal(literalFetchCalls.length, 2);
	for (const definition of [
		literalFetchCalls.map((call) => '<#' + call + '#>').join('\n'),
		literalFetchCalls
			.map((call) =>
				call
					.split('\n')
					.map((line) => '# ' + line)
					.join('\n')
			)
			.join('\n'),
		'<# outer <# nested #>\n' + literalFetchCalls.join('\n') + '\n#>'
	])
		assert.throws(
			() => windowsFetchArgumentExpressions(definition),
			/Exactly two executable native Fetch/
		);
});
check('quoted-and-here-string-source-fetch-lookalikes-never-meet-the-executable-floor', () => {
	for (const definition of [
		literalFetchCalls.map((call) => "'" + call.replaceAll("'", "''") + "'").join('\n'),
		literalFetchCalls.map((call) => '"' + call + '"').join('\n'),
		"@'\n" + literalFetchCalls.join('\n') + "\n'@",
		'@"\n' + literalFetchCalls.join('\n') + '\n"@',
		"@'  \t\r\nodd' literal\n" + literalFetchCalls.join('\n') + "\n'@\n# close ' token\n",
		'@"  \t\r\nodd" literal\n' + literalFetchCalls.join('\n') + '\n"@\n# close " token\n'
	])
		assert.throws(
			() => windowsFetchArgumentExpressions(definition),
			/Exactly two executable native Fetch/
		);
});
check('real-source-fetch-data-preserves-comment-markers-escapes-and-unicode-offsets', () => {
	const prefix = '$Data = \'# <# literal 😀\'; $Quoted = "`"# <#"; $Escaped = `#\n';
	assert.deepEqual(
		windowsFetchArgumentExpressions(prefix + windowsSourceFixture),
		fetchArgumentExpressions
	);
	const withLiteralMarker = windowsSourceFixture.replaceAll(
		"'http://127.0.0.1:'",
		"'http://127.0.0.1:#<#'"
	);
	const expressions = windowsFetchArgumentExpressions(withLiteralMarker);
	assert.equal(expressions.length, 2);
	for (const expression of expressions) assert.ok(expression.includes("'http://127.0.0.1:#<#'"));
});
check('unterminated-source-comment-and-string-data-refuses-instead-of-changing-the-floor', () => {
	for (const definition of ['<#', "'", '"', "@'\n", '@"\n'])
		assert.throws(() => windowsFetchArgumentExpressions(definition), /must terminate/);
});

if (process.platform === 'win32') {
	check('actual-powershell-source-fetch-arguments-preserve-types-and-values', () => {
		const quote = (value) => "'" + value.replaceAll("'", "''") + "'";
		const command = [
			"$ErrorActionPreference = 'Stop'",
			"Add-Type -TypeDefinition @'",
			'public static class PacSourceArgumentProbe {',
			' public static string Observe(string location, long deadline, long retirement, int maximum, int redirects) {',
			'  return location + "|" + deadline + "|" + retirement + "|" + maximum + "|" + redirects;',
			' }',
			'}',
			"'@",
			"$Method = [PacSourceArgumentProbe].GetMethod('Observe')",
			"if ($Method.GetParameters().Length -ne 5) { throw 'Reflection parameter inventory differs.' }",
			'$First = [PSCustomObject]@{Port=54321}',
			'$Deadline = [long]6000',
			'$Types = @([string],[long],[long],[int],[int])',
			'$Controls = 0',
			'foreach ($Expression in @(' + fetchArgumentExpressions.map(quote).join(',') + ')) {',
			" foreach ($Path in @('utf8','utf16','redirect','foreign','invalid','oversized','unavailable')) {",
			'  $Arguments = & ([ScriptBlock]::Create($Expression))',
			"  if ($Arguments.Count -ne 5) { throw 'Source fetch argument arity differs.' }",
			'  for ($Index = 0; $Index -lt 5; $Index++) {',
			"   if ($Arguments[$Index].GetType() -ne $Types[$Index]) { throw 'Source fetch argument type differs.' }",
			'  }',
			'  $Actual = $Method.Invoke($null, $Arguments)',
			"  $Expected = 'http://127.0.0.1:54321/' + $Path + '|6000|7000|1048576|50'",
			"  if ($Actual -cne $Expected) { throw 'Source fetch argument value differs.' }",
			'  $Controls++',
			' }',
			'}',
			"if ($Controls -ne 14) { throw 'Source argument control inventory differs.' }",
			"Write-Output 'PAC_SOURCE_ARGUMENTS vectors=14 reflection=true native_fetch=false'"
		].join('\n');
		const result = spawnSync(
			path.join(process.env.SystemRoot, 'System32/WindowsPowerShell/v1.0/powershell.exe'),
			['-NoProfile', '-NonInteractive', '-Command', command],
			{ encoding: 'utf8', timeout: 10000 }
		);
		assert.equal(result.error, undefined);
		assert.equal(result.signal, null);
		assert.equal(result.status, 0, result.stderr || result.stdout);
		assert.equal(result.stderr, '');
		assert.equal(
			result.stdout.trim(),
			'PAC_SOURCE_ARGUMENTS vectors=14 reflection=true native_fetch=false'
		);
	});
}

if (process.platform !== 'win32') {
	const result = spawnSync(pythonExecutable(), ['tools/test/native_pac_source_fixture_test.py'], {
		cwd: root,
		encoding: 'utf8',
		timeout: 60000
	});
	assert.equal(result.error, undefined);
	assert.equal(result.signal, null);
	assert.equal(result.status, 0, result.stderr || result.stdout);
	assert.ok(result.stdout.includes('Planned cases: 15'));
	assert.match(result.stderr, /Ran 15 tests in/);
	assert.match(result.stderr, /\bOK\b/);
	assert.doesNotMatch(result.stderr, /skipped=/);
	process.stdout.write(result.stdout + result.stderr);
}
console.log(
	`Native PAC source contract: ${passed} portable controls passed; native Swift/SSPI not executed.`
);
