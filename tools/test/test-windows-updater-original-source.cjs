'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const cp = require('node:child_process');
const repository = path.resolve(__dirname, '../..');
const temporary = fs.mkdtempSync(
	path.join(fs.realpathSync(os.tmpdir()), 'ergopti-updater-source-')
);
const root = temporary;
const seed = path.join(temporary, 'immutable-seed');
fs.mkdirSync(seed);
const collectorPath = 'tools/ci/run-windows-updater-original-diagnostic-cohort.cjs';
const modulePath = 'tools/ci/windows-updater-original-source.cjs';
const sealerPath = 'tools/ci/seal-windows-updater-original-source.cjs';
const sdkPath = 'tools/ci/windows-updater-sdk-auth.cjs';
const sdkContractPath =
	'static/ergopti_plus/_shared/modules/updater/windows_release_toolchain.json';
const inputPath = 'tools/ci/windows-updater-original-diagnostic-cohort-inputs.json';
const oraclePath = 'tools/ci/windows-updater-original-label-oracle.json';
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');

// Acquire a finite immutable template; imports below read only owned private copies.
// These are producer inputs, never reconstructed expected cohort labels/outcomes.
const selectedInputs = JSON.parse(fs.readFileSync(path.join(repository, inputPath), 'utf8'));
assert.equal(Object.keys(selectedInputs.source_sha256).length, 21);
const templateFiles = new Set([
	...Object.keys(selectedInputs.source_sha256),
	collectorPath,
	modulePath,
	sealerPath,
	'tools/lib/owned-descriptor-read.cjs',
	sdkPath,
	sdkContractPath,
	inputPath,
	oraclePath,
	'tools/ci/manual-ci-lanes.cjs',
	'tools/ci/dev-release-qualification.cjs',
	'.github/ci/dev_release_qualification_exceptions.json',
	'.github/ci/stable_release_qualification_exception.json',
	'.github/workflows/ci.yml',
	'.github/workflows/ci-windows.yml',
	'.node-version',
	'package.json',
	'package-lock.json',
	'static/ergopti_plus/windows/vendor/ergopti_network_pac.exe',
	'static/ergopti_plus/windows/vendor/ergopti_network_pac.json',
	'static/ergopti_plus/windows/vendor/ergopti_network_pac.LICENSE.txt'
]);
const templateHashes = {};
for (const relative of templateFiles) {
	const data = fs.readFileSync(path.join(repository, relative));
	if (Object.hasOwn(selectedInputs.source_sha256, relative))
		assert.equal(sha(data), selectedInputs.source_sha256[relative]);
	const destination = path.join(seed, relative);
	fs.mkdirSync(path.dirname(destination), { recursive: true });
	fs.writeFileSync(destination, data);
	templateHashes[relative] = sha(data);
}

const env = Object.fromEntries(
	Object.entries(process.env).filter(([k]) => !k.startsWith('GITHUB_'))
);
const git = (where, args) =>
	cp.execFileSync('git', ['-c', 'core.hooksPath=/dev/null', ...args], {
		cwd: where,
		env,
		encoding: 'utf8',
		stdio: 'pipe'
	});
// Independent Python struct/zipfile-authored inert fixtures; no interpreter is executed.
const syntheticSdkArchive = Buffer.from(
	'UEsDBBQAAAAAANGwTF1pnYssAAIAAAACAAAQAAAAQXV0b0hvdGtleTY0LmV4ZU1aAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAABQRQAAZIYBAAAAAAAAAAAAAAAAAHAAAgALAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUEsDBBQAAAAAANGwTF00AvzIJAAAACQAAAAQAAAAQXV0b0hvdGtleTMyLmV4ZUluZGVwZW5kZW50IGlycmVsZXZhbnQgMzItYml0IG1lbWJlclBLAQIUAxQAAAAAANGwTF1pnYssAAIAAAACAAAQAAAAAAAAAAAAAACAAQAAAABBdXRvSG90a2V5NjQuZXhlUEsBAhQDFAAAAAAA0bBMXTQC/MgkAAAAJAAAABAAAAAAAAAAAAAAAIABLgIAAEF1dG9Ib3RrZXkzMi5leGVQSwUGAAAAAAIAAgB8AAAAgAIAAAAA',
	'base64'
);
const syntheticSdkImage = Buffer.from(
	'TVoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAFBFAABkhgEAAAAAAAAAAAAAAAAAcAACAAsCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
	'base64'
);
const syntheticSdkAliasArchive = Buffer.from(
	'UEsDBBQAAAAAANGwTF1pnYssAAIAAAACAAAQAAAAQXV0b0hvdGtleTY0LmV4ZU1aAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAABQRQAAZIYBAAAAAAAAAAAAAAAAAHAAAgALAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUEsDBBQAAAAAANGwTF023CoYGgAAABoAAAAXAAAAQXV0b0hvdGtleTY0LmV4ZTo6JERBVEFJbmRlcGVuZGVudCBhbGlhcyBzZW50aW5lbFBLAQIUAxQAAAAAANGwTF1pnYssAAIAAAACAAAQAAAAAAAAAAAAAACAAQAAAABBdXRvSG90a2V5NjQuZXhlUEsBAhQDFAAAAAAA0bBMXTbcKhgaAAAAGgAAABcAAAAAAAAAAAAAAIABLgIAAEF1dG9Ib3RrZXk2NC5leGU6OiREQVRBUEsFBgAAAAACAAIAgwAAAH0CAAAAAA==',
	'base64'
);
function prepareSyntheticSdk(directory, change = () => {}) {
	fs.writeFileSync(path.join(directory, 'source-sdk.zip'), syntheticSdkArchive);
	fs.writeFileSync(path.join(directory, 'source-sdk-image.bin'), syntheticSdkImage);
	const contract = {
		runtime: { version: '9.8.7', asset: 'AutoHotkey_9.8.7.zip', sha256: sha(syntheticSdkArchive) }
	};
	fs.writeFileSync(path.join(directory, sdkContractPath), JSON.stringify(contract));
	change(directory);
}
function sdkCase(change = () => {}) {
	return fixture((directory) =>
		prepareSyntheticSdk(directory, () => {
			change(directory);
			const archive = fs.readFileSync(path.join(directory, 'source-sdk.zip'));
			fs.writeFileSync(
				path.join(directory, sdkContractPath),
				JSON.stringify({
					runtime: { version: '9.8.7', asset: 'AutoHotkey_9.8.7.zip', sha256: sha(archive) }
				})
			);
		})
	);
}
function sdkModel(f) {
	return architectureModel(f, 'x64', {
		process: {
			env: { ...env, ERGOPTI_WINDOWS_AHK_ARCHIVE: path.join(f.directory, 'source-sdk.zip') }
		}
	}).sdk;
}
const records = [];
function fixture(change = () => {}) {
	const directory = fs.mkdtempSync(path.join(temporary, 'fixture-'));
	fs.cpSync(seed, directory, { recursive: true });
	fs.writeFileSync(path.join(directory, 'outside-source.txt'), 'independent whole-tree sentinel');
	change(directory);
	git(directory, ['init', '-q']);
	git(directory, ['config', 'user.name', 'Portable Source receiving']);
	git(directory, ['config', 'user.email', 'portable@example.invalid']);
	git(directory, ['add', '--all']);
	git(directory, ['commit', '-qm', 'Independent Source fixture']);
	const head = git(directory, ['rev-parse', 'HEAD']).trim();
	const required = createRequire(path.join(directory, collectorPath));
	return {
		directory,
		head,
		required,
		api: required('./windows-updater-original-source.cjs'),
		cli: required('./run-windows-updater-original-diagnostic-cohort.cjs'),
		context: {
			candidate: head,
			run_id: null,
			run_attempt: null,
			architecture: 'x64',
			role: 'local',
			context_bound: false
		}
	};
}
function control(name, body) {
	records.push({ name, status: 'RUNNING' });
	const result = body();
	records.at(-1).status = result === 'SKIP' ? 'SKIP' : 'PASS';
	process.stdout.write(records.at(-1).status + ' ' + name + '\n');
	return result;
}
function refuses(body, pattern) {
	assert.throws(body, (e) => e instanceof Error && (!pattern || pattern.test(e.message)));
}
function withEnvironment(values, body) {
	const original = { ...process.env };
	try {
		for (const key of Object.keys(process.env))
			if (key.startsWith('GITHUB_')) delete process.env[key];
		Object.assign(process.env, values);
		return body();
	} finally {
		for (const key of Object.keys(process.env))
			if (!Object.hasOwn(original, key)) delete process.env[key];
		for (const [key, value] of Object.entries(original)) process.env[key] = value;
	}
}
function withArguments(args, body) {
	const original = process.argv;
	try {
		process.argv = [process.execPath, 'collector.cjs', ...args];
		return body();
	} finally {
		process.argv = original;
	}
}
function quietImport(directory) {
	const program = `const cp=require('node:child_process'); for(const name of ['spawn','spawnSync','execFileSync']) cp[name]=()=>{throw new Error('Unexpected acquisition during import')}; require(${JSON.stringify(path.join(directory, collectorPath))}); require(${JSON.stringify(path.join(directory, modulePath))}); process.stdout.write('NO_MAIN_NO_RECEIPT_NO_NATIVE\\n');`;
	const result = cp.spawnSync(process.execPath, ['-e', program], {
		cwd: directory,
		env,
		encoding: 'utf8',
		timeout: 30000
	});
	assert.equal(result.error, undefined);
	assert.equal(result.signal, null);
	assert.equal(result.status, 0, result.stderr);
	assert.equal(result.stdout, 'NO_MAIN_NO_RECEIPT_NO_NATIVE\n');
	assert.equal(result.stderr, '');
}
// A private CommonJS realm models architecture only; Git, filesystem and Source bytes remain real.
// The module and CLI share Object prototypes; injected Error preserves assertion error identity.
function architectureModel(f, architecture, overrides = {}) {
	const context = vm.createContext({
		process: { ...process, arch: architecture, env: process.env, ...overrides.process },
		Error,
		Buffer,
		setTimeout,
		clearTimeout,
		console: overrides.console || console
	});
	let api, sdk;
	const required = (name) => {
		if (name === './windows-updater-original-source.cjs') {
			if (!overrides.afterRead) return api;
			return {
				...api,
				readSourceFile: (...args) => {
					const result = api.readSourceFile(...args);
					overrides.afterRead(args[0]);
					return result;
				}
			};
		}
		if (name === './windows-updater-sdk-auth.cjs') return sdk;
		if (name === 'node:child_process' && overrides.childProcess) return overrides.childProcess;
		return f.required(name);
	};
	function load(relative, code = fs.readFileSync(path.join(f.directory, relative), 'utf8')) {
		const ownedModule = { exports: {} };
		const compiled = vm.runInContext(
			'(function(require,module,__dirname){\n' + code + '\n})',
			context,
			{
				filename: path.join(f.directory, relative)
			}
		);
		compiled(required, ownedModule, path.dirname(path.join(f.directory, relative)));
		return ownedModule.exports;
	}
	api = load(modulePath);
	sdk = load(sdkPath);
	return { api, sdk, cli: load(collectorPath), context, required };
}
// Test-only realm calls the actual generator main against the owning private Git fixture.
function sealWriteFault(f, vector) {
	const before = fs.readFileSync(path.join(f.directory, inputPath));
	const context = vm.createContext({
		Buffer,
		AggregateError,
		process: { env, stdout: { write() {} } }
	});
	let refused = false,
		failure,
		closeAttempts = 0;
	const filePort = {
		...fs,
		fstatSync: (...args) => {
			if (vector.phase === 'validation') throw vector.value;
			return fs.fstatSync(...args);
		},
		writeSync: (...args) => {
			if (vector.phase === 'write') throw vector.value;
			return fs.writeSync(...args);
		},
		closeSync: (descriptor) => {
			closeAttempts += 1;
			fs.closeSync(descriptor);
			if (vector.close) throw vector.closure;
		}
	};
	const required = (name) => (name === 'node:fs' ? filePort : f.required(name));
	const ownedModule = { exports: {} };
	const code = fs.readFileSync(path.join(f.directory, sealerPath), 'utf8');
	const loaded = vm.runInContext(
		'(function(require,module,__dirname){\n' + code + '\nmodule.exports.testOnlyMain=main;\n})',
		context,
		{ filename: path.join(f.directory, sealerPath) }
	);
	loaded(required, ownedModule, path.dirname(path.join(f.directory, sealerPath)));
	try {
		ownedModule.exports.testOnlyMain(['--ref', f.head, '--write']);
	} catch (error) {
		refused = true;
		failure = error;
	} finally {
		fs.writeFileSync(path.join(f.directory, inputPath), before);
	}
	assert.equal(closeAttempts, 1, 'Source seal closure is attempted once without uncertain retry');
	return { refused, failure };
}
// Actual CLI children use only an owned private preloader; production has no test flag/export.
function sourceSealCLIVectors(f) {
	const generic = 'SOURCE_SEAL_REFUSAL stage=unclassified error_count=unknown\n';
	const paired = 'SOURCE_SEAL_REFUSAL stage=write_and_close error_count=2\n';
	return [
		{
			label: 'error/paired',
			phase: 'write',
			value: 'error',
			close: true,
			closure: 'error',
			expected: paired
		},
		{
			label: 'undefined/single',
			phase: 'write',
			value: 'undefined',
			close: false,
			expected: generic
		},
		{
			label: 'native_getter/single',
			phase: 'write',
			value: 'native_getter',
			close: false,
			expected: generic
		},
		{
			label: 'object_getter/single',
			phase: 'write',
			value: 'object_getter',
			close: false,
			expected: generic
		},
		{ label: 'proxy/single', phase: 'write', value: 'proxy', close: false, expected: generic },
		{
			label: 'native_object_message/single',
			phase: 'write',
			value: 'native_object_message',
			close: false,
			expected: generic
		},
		{
			label: 'lookalike_pair/single',
			phase: 'write',
			value: 'lookalike_pair',
			close: false,
			expected: generic
		},
		{
			label: 'ownership/single',
			phase: 'ownership',
			value: 'error',
			close: false,
			closure: 'error',
			expected: 'Source output ownership changed.\n'
		},
		{
			label: 'partial_write/paired',
			phase: 'partial_write',
			value: 'error',
			close: true,
			closure: 'error',
			expected: paired
		},
		{
			label: 'final_predicate/single',
			phase: 'final_predicate',
			value: 'error',
			close: false,
			closure: 'error',
			expected: 'Published source seal differs.\n'
		},
		{
			label: 'normal_stale',
			args: ['--ref', f.head, '--check'],
			expected: 'Source seal is stale; review the commit and run --write.\n'
		},
		{ label: 'normal_success', success: true, expected: '' }
	];
}
function sourceSealCLIChild(f, vector) {
	const preload = path.join(f.directory, 'source-seal-private-preload.cjs');
	fs.writeFileSync(
		preload,
		"'use strict';\n// Private fault injection only; no production option or export authorizes this hook.\nconst fs = require('node:fs'), path = require('node:path');\nconst vectorPath = process.env.ERGOPTI_SOURCE_SEAL_TEST_VECTOR;\nconst vector = JSON.parse(fs.readFileSync(vectorPath, 'utf8'));\nconst source = path.resolve(path.dirname(process.argv[1]), 'windows-updater-original-diagnostic-cohort-inputs.json');\nconst state = { writer_close_attempts: 0, write_calls: 0, truncate_calls: 0, message_gets: 0, coercions: 0, proxy_traps: 0 };\nconst token = 'EXPLICIT_SYNTHETIC_PRIVATE_SOURCE_SEAL_TOKEN';\nconst actual = Object.fromEntries(['openSync', 'fstatSync', 'writeSync', 'readSync', 'ftruncateSync', 'closeSync'].map(name => [name, fs[name]]));\nlet writer, reserved = false, truncated = false;\nconst inputDescriptors = new Set();\nfunction value(kind) {\n switch (kind) {\n  case 'undefined': return undefined;\n  case 'null': return null;\n  case 'false': return false;\n  case 'zero': return 0;\n  case 'negative_zero': return -0;\n  case 'nan': return NaN;\n  case 'empty_string': return '';\n  case 'bigint_zero': return 0n;\n  case 'private_string': return token;\n  case 'symbol': return Symbol(token);\n  case 'error': return new Error(token);\n  case 'native_getter': {\n   const error = new Error();\n   Object.defineProperty(error, 'message', { get() { state.message_gets++; throw new Error(token); } });\n   return error;\n  }\n  case 'object_getter': return { get message() { state.message_gets++; throw new Error(token); }, toString() { state.coercions++; return token; }, [Symbol.toPrimitive]() { state.coercions++; return token; } };\n  case 'proxy': return new Proxy({}, { get() { state.proxy_traps++; throw new Error(token); }, getOwnPropertyDescriptor() { state.proxy_traps++; throw new Error(token); } });\n  case 'native_object_message': {\n   const error = new Error();\n   error.message = { [Symbol.toPrimitive]() { state.coercions++; return token; } };\n   return error;\n  }\n  case 'lookalike_pair': {\n   const error = new AggregateError([new Error(token), new Error(token)], 'Source seal write and closure refused.');\n   Object.defineProperty(error, 'cause', { get() { state.message_gets++; throw new Error(token); } });\n   return error;\n  }\n  default: throw new Error('Unadmitted private test vector');\n }\n}\nfs.openSync = (file, flags, ...rest) => {\n const descriptor = actual.openSync(file, flags, ...rest);\n if (path.resolve(String(file)) === source) {\n  inputDescriptors.add(descriptor);\n  if (typeof flags === 'number' && (flags & fs.constants.O_RDWR)) { writer = descriptor; reserved = true; }\n }\n return descriptor;\n};\nfs.fstatSync = (descriptor, ...rest) => {\n const received = actual.fstatSync(descriptor, ...rest);\n if (reserved && descriptor === writer && vector.phase === 'validation') throw value(vector.value);\n if (reserved && descriptor === writer && vector.phase === 'ownership') return { ...received, isFile: () => received.isFile(), nlink: 2n };\n return received;\n};\nfs.writeSync = (descriptor, buffer, offset, length, position) => {\n if (reserved && descriptor === writer) {\n  state.write_calls++;\n  if (vector.phase === 'write') throw value(vector.value);\n  if (vector.phase === 'partial_write') {\n   actual.writeSync(descriptor, buffer, offset, length - 1, position);\n   throw value(vector.value);\n  }\n }\n return actual.writeSync(descriptor, buffer, offset, length, position);\n};\nfs.ftruncateSync = (descriptor, length) => {\n if (reserved && descriptor === writer) {\n  state.truncate_calls++;\n  if (vector.phase === 'truncate') { actual.ftruncateSync(descriptor, 2); throw value(vector.value); }\n  const received = actual.ftruncateSync(descriptor, length); truncated = true;\n  if (vector.phase === 'final_predicate') actual.writeSync(descriptor, Buffer.from(token), 0, token.length, 0);\n  return received;\n }\n return actual.ftruncateSync(descriptor, length);\n};\nfs.readSync = (descriptor, ...rest) => {\n if (truncated && inputDescriptors.has(descriptor) && vector.phase === 'final_read') throw value(vector.value);\n return actual.readSync(descriptor, ...rest);\n};\nfs.closeSync = (descriptor) => {\n inputDescriptors.delete(descriptor);\n if (reserved && descriptor === writer) {\n  reserved = false; state.writer_close_attempts++;\n  const received = actual.closeSync(descriptor);\n  if (vector.close) throw value(vector.closure);\n  return received;\n }\n return actual.closeSync(descriptor);\n};\nprocess.on('exit', () => fs.writeFileSync(vector.trace, JSON.stringify(state)));\n"
	);
	const vectorPath = path.join(f.directory, 'source-seal-private-vector.json');
	const trace = path.join(f.directory, 'source-seal-private-trace.json');
	const input = path.join(f.directory, inputPath);
	const before = fs.readFileSync(input);
	const oracleBefore = fs.readFileSync(path.join(f.directory, oraclePath));
	fs.writeFileSync(vectorPath, JSON.stringify({ ...vector, trace }));
	try {
		const result = cp.spawnSync(
			process.execPath,
			[
				'--require',
				preload,
				path.join(f.directory, sealerPath),
				...(vector.args || ['--ref', f.head, '--write'])
			],
			{
				cwd: f.directory,
				env: { ...env, ERGOPTI_SOURCE_SEAL_TEST_VECTOR: vectorPath },
				encoding: 'utf8',
				timeout: 30000,
				maxBuffer: 33554432
			}
		);
		return {
			result,
			state: JSON.parse(fs.readFileSync(trace, 'utf8')),
			inputChanged: !fs.readFileSync(input).equals(before),
			oracleUnchanged: fs.readFileSync(path.join(f.directory, oraclePath)).equals(oracleBefore)
		};
	} finally {
		// Restore only the test-owned seed after the actual CLI child has returned.
		fs.writeFileSync(input, before);
	}
}
function assertSourceSealCLI(f, vector, outcome) {
	const { result, state } = outcome;
	assert.equal(result.error, undefined, vector.label);
	assert.equal(result.signal, null, vector.label);
	assert.equal(result.status, vector.success ? 0 : 1, vector.label);
	assert.equal(result.stderr, vector.expected, vector.label);
	assert.equal(
		result.stdout,
		vector.success
			? `WINDOWS_UPDATER_SOURCE_SEAL ref=${f.head} inputs=21 mode=write native=false official=false\n`
			: '',
		vector.label
	);
	assert.equal(state.writer_close_attempts, vector.args ? 0 : 1, vector.label);
	assert.equal(state.message_gets, 0, vector.label);
	assert.equal(state.coercions, 0, vector.label);
	assert.equal(state.proxy_traps, 0, vector.label);
	assert.equal(outcome.oracleUnchanged, true, vector.label);
	if (['partial_write', 'truncate', 'final_predicate', 'final_read'].includes(vector.phase))
		assert.equal(outcome.inputChanged, true, 'The refusal does not promise rollback');
}
function sourceSealCLIControls(f) {
	const vectors = sourceSealCLIVectors(f);
	assert.equal(vectors.length, 12, 'Every normal actual CLI vector is enrolled');
	assert.equal(
		new Set(vectors.map((row) => row.label)).size,
		12,
		'Every actual CLI vector is unique'
	);
	const started = process.hrtime.bigint();
	for (const vector of vectors) assertSourceSealCLI(f, vector, sourceSealCLIChild(f, vector));
	const elapsed = Number(process.hrtime.bigint() - started) / 1000000;
	process.stdout.write(
		`SOURCE_SEAL_CLI controls=12 elapsed_ms=${elapsed.toFixed(3)} native=false official=false\n`
	);
}
const passiveCopy = (value) => JSON.parse(JSON.stringify(value));
async function modelMain(f, code, options = {}) {
	const evidence = path.join(f.directory, 'local-evidence');
	fs.mkdirSync(evidence);
	const ahk = path.join(f.directory, 'source-sdk-image.bin');
	const sdkEnvironment = {
		...env,
		ERGOPTI_WINDOWS_AHK_ARCHIVE: path.join(f.directory, 'source-sdk.zip')
	};
	if (options.missingArchive) delete sdkEnvironment.ERGOPTI_WINDOWS_AHK_ARCHIVE;
	let imageReads = 0;
	const calls = [],
		stdout = [],
		stderr = [],
		exits = [];
	const model = architectureModel(f, 'x64', {
		afterRead: (file) => {
			if (file === ahk && ++imageReads === 2 && options.replaceBeforeChild) {
				fs.renameSync(ahk, ahk + '.before-sdk');
				fs.writeFileSync(ahk, syntheticSdkImage);
			}
		},
		childProcess: {
			...cp,
			spawn: (...args) => {
				calls.push(args);
				throw new Error('CONTROLLED_NO_NATIVE_ACQUISITION');
			}
		},
		console: {
			log: (x) => stdout.push(String(x)),
			error: (...x) => stderr.push(x.map(String).join(' '))
		},
		process: {
			platform: 'win32',
			argv: [process.execPath, 'collector.cjs', '--local', ahk, '2.0.0.0', evidence],
			env: sdkEnvironment,
			exit: (x) => exits.push(x)
		}
	});
	model.context.require = model.required;
	model.context.module = { exports: {} };
	model.context.__dirname = path.dirname(path.join(f.directory, collectorPath));
	await vm.runInContext(code + '\nmain();', model.context, {
		filename: path.join(f.directory, collectorPath)
	});
	const receipt = JSON.parse(stdout.at(-1));
	return { calls, stdout, stderr, exits, receipt, evidence };
}
(async () => {
	control('imports collect no Source receipt and start neither main nor native children', () =>
		quietImport(fixture().directory)
	);
	control('clean actual Git and immutable twenty-one inputs receive local Source', () => {
		const f = fixture();
		const result = f.api.candidateSourceReceipt(f.context);
		assert.equal(result.candidate, f.head);
		assert.equal(result.scope, 'windows-updater-candidate-source-only');
		assert.equal(result.role, 'local');
		assert.equal(result.context_bound, false);
		assert.equal(result.run_id, null);
		assert.equal(result.run_attempt, null);
		assert.equal(result.tracked_source_clean, true);
		assert.equal(
			result.oracle_sha256,
			'2b00c32567273c9e671b3460fe54b52059032b0188f10103076523d58b59eb01'
		);
	});
	control('local explicit context uses real HEAD and absolute arguments', () => {
		const f = fixture();
		withEnvironment({}, () => {
			const args = ['--local', '/absolute/ahk.exe', '2.0.0.0', temporary];
			const v = architectureModel(f, 'x64').api.localInvocation(args);
			assert.deepEqual(passiveCopy(v.context), f.context);
			assert.deepEqual(passiveCopy(v.arguments), ['/absolute/ahk.exe', '2.0.0.0']);
			assert.equal(v.evidence_root, temporary);
			refuses(() => architectureModel(f, 'arm64').api.localInvocation(args), /architecture/);
		});
	});
	control('hosted run metadata refuses local even when value is empty', () => {
		const f = fixture();
		for (const key of [
			'GITHUB_SHA',
			'GITHUB_RUN_ID',
			'GITHUB_RUN_ATTEMPT',
			'GITHUB_EVENT_NAME',
			'GITHUB_JOB',
			'GITHUB_WORKFLOW',
			'GITHUB_ACTIONS',
			'GITHUB_ACTION'
		])
			withEnvironment({ [key]: '' }, () =>
				refuses(() => f.api.localInvocation(['--local', '/ahk', 'v', temporary]), /hosted/)
			);
	});
	control('credential binding grants no local or official authority', () => {
		const f = fixture();
		withEnvironment({}, () => {
			const model = architectureModel(f, 'x64');
			const before = model.api.localInvocation(['--local', '/ahk', 'v', temporary]);
			withEnvironment({ GITHUB_TOKEN: 'independent noncredential sentinel' }, () =>
				assert.deepEqual(model.api.localInvocation(['--local', '/ahk', 'v', temporary]), before)
			);
			assert.equal(before.context.context_bound, false);
			assert.equal(before.context.run_id, null);
		});
	});
	control('unknown mixed relative and wrong-arity modes refuse', () => {
		const f = fixture();
		for (const args of [
			['--official', '/ahk', 'v'],
			['--local', '/ahk', 'v'],
			['--local', '/ahk', '--official', temporary],
			['--local', 'relative', 'v', temporary],
			['--local', '/ahk', 'v', 'relative'],
			['--local', '/ahk', 'v', temporary, 'extra']
		])
			withEnvironment({}, () => withArguments(args, () => refuses(() => f.cli.invocation())));
	});
	control('official original manual grammar stays separate from API authentication', () => {
		const f = fixture();
		const valid = {
			GITHUB_SHA: f.head,
			GITHUB_RUN_ID: '123',
			GITHUB_RUN_ATTEMPT: '2',
			GITHUB_EVENT_NAME: 'workflow_dispatch',
			ERGOPTI_DEV_RELEASE_RELEASE: 'false'
		};
		withEnvironment(valid, () =>
			withArguments(['/ahk', 'v'], () => {
				const args = process.argv;
				const v = architectureModel(f, 'x64', { process: { argv: args } }).cli.invocation();
				assert.equal(v.local, false);
				assert.equal(v.context.role, 'candidate');
				assert.equal(v.context.context_bound, true);
				assert.equal(v.context.run_id, '123');
				assert.equal(v.context.run_attempt, '2');
				refuses(
					() => architectureModel(f, 'arm64', { process: { argv: args } }).cli.invocation(),
					/architecture/
				);
			})
		);
	});
	control('official malformed SHA IDs event and release refuse', () => {
		const f = fixture();
		const valid = {
			GITHUB_SHA: f.head,
			GITHUB_RUN_ID: '123',
			GITHUB_RUN_ATTEMPT: '2',
			GITHUB_EVENT_NAME: 'workflow_dispatch',
			ERGOPTI_DEV_RELEASE_RELEASE: 'false'
		};
		for (const change of [
			{ GITHUB_SHA: 'B'.repeat(40) },
			{ GITHUB_RUN_ID: '0' },
			{ GITHUB_RUN_ID: '1'.repeat(21) },
			{ GITHUB_RUN_ATTEMPT: '0' },
			{ GITHUB_RUN_ATTEMPT: '1'.repeat(7) },
			{ GITHUB_EVENT_NAME: 'push' },
			{ ERGOPTI_DEV_RELEASE_RELEASE: 'true' }
		])
			withEnvironment({ ...valid, ...change }, () => refuses(() => f.cli.admittedContext()));
	});
	control('Source context rejects forged labels extra fields and incoherent primitives', () => {
		const f = fixture();
		for (const v of [
			{ ...f.context, schema: 255 },
			{ ...f.context, scope: 'forged' },
			{ ...f.context, role: 'candidate' },
			{ ...f.context, context_bound: true },
			{ ...f.context, run_id: '123' },
			{ ...f.context, architecture: 'arm64' }
		])
			refuses(() => f.api.candidateSourceReceipt(v));
		const accessor = { ...f.context };
		Object.defineProperty(accessor, 'role', {
			get() {
				throw new Error('Accessor must never run');
			},
			enumerable: true
		});
		refuses(() => f.api.candidateSourceReceipt(accessor), /passive/);
		const hidden = { ...f.context };
		Object.defineProperty(hidden, 'schema', { value: 255 });
		refuses(() => f.api.candidateSourceReceipt(hidden), /roster/);
		const symbol = { ...f.context, [Symbol('extra')]: 1 };
		refuses(() => f.api.candidateSourceReceipt(symbol), /roster/);
	});
	control('inert descriptor snapshot denies Proxy label injection during spread', () => {
		const f = fixture();
		let spread = false;
		const proxied = new Proxy(
			{ ...f.context },
			{
				ownKeys(target) {
					if (spread) return [...Reflect.ownKeys(target), 'schema', 'scope'];
					return Reflect.ownKeys(target);
				},
				getOwnPropertyDescriptor(target, key) {
					if (key === 'schema' || key === 'scope')
						return {
							value: key === 'schema' ? 255 : 'forged-proxy-label',
							enumerable: true,
							configurable: true
						};
					const d = Reflect.getOwnPropertyDescriptor(target, key);
					if (key === 'context_bound') spread = true;
					return d;
				},
				get(target, key) {
					if (key === 'schema') return 255;
					if (key === 'scope') return 'forged-proxy-label';
					return Reflect.get(target, key);
				}
			}
		);
		const received = f.api.candidateSourceReceipt(proxied);
		assert.equal(received.schema, 1);
		assert.equal(received.scope, 'windows-updater-candidate-source-only');
		assert.equal(received.context_bound, false);
	});
	control('whole tracked cleanliness covers outside selected roots', () => {
		const f = fixture();
		fs.writeFileSync(path.join(f.directory, 'outside-source.txt'), 'unauthorized drift');
		refuses(() => f.api.candidateSourceReceipt(f.context));
	});
	control('foreign candidate refuses identical working bytes', () => {
		const f = fixture();
		refuses(
			() => f.api.candidateSourceReceipt({ ...f.context, candidate: 'b'.repeat(40) }),
			/HEAD changed/
		);
	});
	control('two PAC replacements without authenticated publication still refuse', () => {
		const f = fixture();
		for (const n of ['ergopti_network_pac.exe', 'ergopti_network_pac.json'])
			fs.writeFileSync(
				path.join(f.directory, 'static/ergopti_plus/windows/vendor', n),
				'independent unauthorized publication'
			);
		refuses(() => f.api.candidateSourceReceipt(f.context));
	});
	control('original independent oracle cannot be changed by a clean successor', () => {
		const f = fixture((d) => fs.appendFileSync(path.join(d, oraclePath), '\n'));
		refuses(() => f.api.candidateSourceReceipt(f.context), /oracle changed/);
	});
	control('original cohort names order and filters cannot be changed by input data', () => {
		const f = fixture((d) => {
			const file = path.join(d, inputPath),
				v = JSON.parse(fs.readFileSync(file));
			v.cohorts[0].expected_names[0] = 'independently unauthorized label';
			fs.writeFileSync(file, JSON.stringify(v));
		});
		refuses(() => f.api.candidateSourceReceipt(f.context), /labels\/order\/filters/);
	});
	control('untracked repository AHK shadow refuses', () => {
		const f = fixture();
		fs.writeFileSync(path.join(f.directory, 'unbound.AHK'), 'independent inert bytes');
		refuses(() => f.api.candidateSourceReceipt(f.context), /Unbound AHK/);
	});
	control('tracked case-ambiguous Source names refuse', () => {
		if (process.platform === 'win32') {
			process.stdout.write(
				'SKIP distinct_case_files reason=Windows_case_sensitive_namespace_not_assumed native=false\n'
			);
			return 'SKIP';
		}
		const f = fixture((d) => {
			for (const n of ['Case.ahk', 'case.ahk'])
				fs.writeFileSync(path.join(d, n), 'independent inert bytes');
		});
		refuses(() => f.api.candidateSourceReceipt(f.context), /Ambiguous/);
	});
	control('strong acquired bytes identity and maximum are actual filesystem facts', () => {
		const f = fixture(),
			file = path.join(f.directory, 'reader-vector.bin');
		const bytes = Buffer.from('independent source bytes');
		fs.writeFileSync(file, bytes);
		const v = f.api.readSourceFile(file);
		assert.deepEqual(v.bytes, bytes);
		assert.equal(v.sha256, sha(bytes));
		assert.equal(v.identity.size, String(bytes.length));
		refuses(() => f.api.readSourceFile(file, bytes.length - 1), /acquisition/);
		// Faults exercise the actual reader and descriptor; none is native acceptance.
		const originalRead = new Error('Independent source receiving refusal');
		const originalClose = new Error('Independent closure acknowledgment refusal');
		for (const vector of [
			{ read: true, value: originalRead, close: true },
			{ read: true, value: undefined, close: true },
			{ read: true, value: null, close: true },
			{ read: true, value: false, close: true },
			{ read: true, value: originalRead, close: false },
			{ read: false, close: true }
		]) {
			const actualOpen = fs.openSync,
				actualStat = fs.fstatSync,
				actualClose = fs.closeSync;
			let descriptor,
				closeAttempts = 0,
				refused = false,
				failure;
			try {
				fs.openSync = (...args) => (descriptor = actualOpen(...args));
				fs.fstatSync = (...args) => {
					if (vector.read) throw vector.value;
					return actualStat(...args);
				};
				fs.closeSync = (fd) => {
					closeAttempts += 1;
					actualClose(fd);
					if (vector.close) throw originalClose;
				};
				try {
					f.api.readSourceFile(file);
				} catch (error) {
					refused = true;
					failure = error;
				}
			} finally {
				fs.openSync = actualOpen;
				fs.fstatSync = actualStat;
				fs.closeSync = actualClose;
			}
			assert.equal(refused, true, 'Both single and paired refusals deny receiving');
			assert.equal(closeAttempts, 1, 'Uncertain close is not retried');
			assert.throws(
				() => actualStat(descriptor),
				(error) => error.code === 'EBADF'
			);
			if (vector.read && vector.close) {
				assert.ok(failure instanceof AggregateError, 'Both original failures survive');
				assert.equal(failure.cause, vector.value);
				assert.deepEqual(failure.errors, [vector.value, originalClose]);
				assert.equal(failure.errors[0], vector.value);
				assert.equal(failure.errors[1], originalClose);
			} else assert.equal(failure, vector.read ? vector.value : originalClose);
		}
		// These selected identity controls share the original finite fixture.
		const closure = new Error('Independent source seal closure refusal');
		const sealingVectors = [
			{ phase: 'write', value: originalRead, close: true, closure },
			{ phase: 'write', value: undefined, close: true, closure },
			{ phase: 'write', value: false, close: true, closure: false },
			{ phase: 'validation', value: null, close: false },
			{ close: true, closure: 0 },
			{ close: false }
		];
		for (const vector of sealingVectors) {
			const outcome = sealWriteFault(f, vector);
			assert.equal(outcome.refused, Boolean(vector.phase || vector.close));
			if (vector.phase && vector.close) {
				assert.ok(outcome.failure instanceof AggregateError);
				assert.equal(outcome.failure.cause, vector.value);
				assert.deepEqual(outcome.failure.errors, [vector.value, vector.closure]);
				assert.equal(outcome.failure.errors[0], vector.value);
				assert.equal(outcome.failure.errors[1], vector.closure);
			} else assert.equal(outcome.failure, vector.phase ? vector.value : vector.closure);
		}
		sourceSealCLIControls(f);
		const sdkFixture = sdkCase();
		const binding = sdkModel(sdkFixture);
		const image = path.join(sdkFixture.directory, 'source-sdk-image.bin');
		const before = binding.receiveSdk(image, 'CALLER_METADATA_NOT_BOUND');
		assert.equal(before.runtime_version, '9.8.7');
		assert.equal(before.member.sha256, sha(syntheticSdkImage));
		assert.equal(before.archive.sha256, sha(syntheticSdkArchive));
		assert.equal(before.pe.machine, 0x8664);
		assert.equal(before.pe.headers_only, true);
		assert.equal(before.pe.loader_validated, false);
		assert.equal(before.reported_file_version_qualified, false);
		binding.requireSameSdk(before, binding.receiveSdk(image, 'CALLER_METADATA_NOT_BOUND'));
		fs.renameSync(image, image + '.prior');
		fs.writeFileSync(image, syntheticSdkImage);
		refuses(
			() => binding.requireSameSdk(before, binding.receiveSdk(image, 'CALLER_METADATA_NOT_BOUND')),
			/receipt changed/
		);
		for (const [label, change, reason] of [
			[
				'Unix directory',
				(directory) => {
					const archive = Buffer.from(syntheticSdkArchive);
					const central = archive.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]));
					archive.writeUInt32LE(0x40000000, central + 38);
					fs.writeFileSync(path.join(directory, 'source-sdk.zip'), archive);
				},
				/file type/
			],
			[
				'Windows default stream alias',
				(directory) =>
					fs.writeFileSync(path.join(directory, 'source-sdk.zip'), syntheticSdkAliasArchive),
				/alias/
			]
		]) {
			const subject = sdkCase(change);
			refuses(
				() =>
					sdkModel(subject).receiveSdk(path.join(subject.directory, 'source-sdk-image.bin'), label),
				reason
			);
		}
	});
	control('real hardlink and symlink reader aliases refuse', () => {
		const f = fixture(),
			file = path.join(f.directory, 'reader-alias.bin');
		fs.writeFileSync(file, 'independent bytes');
		const link = path.join(f.directory, 'hard-alias.bin');
		fs.linkSync(file, link);
		refuses(() => f.api.readSourceFile(file), /unaliased/);
		if (process.platform === 'win32') {
			process.stdout.write(
				'SKIP symlink_only reason=Windows_symlink_permission_not_assumed native=false\n'
			);
			return;
		}
		const target = path.join(f.directory, 'symbol-target.bin');
		fs.writeFileSync(target, 'independent bytes');
		const symbolic = path.join(f.directory, 'symbol-alias.bin');
		fs.symlinkSync(target, symbolic);
		refuses(() => f.api.readSourceFile(symbolic), /unaliased/);
	});
	control('same-byte final pathname replacement cannot pay acquired FD identity', () => {
		const f = fixture(),
			file = path.join(f.directory, 'reader-race.bin');
		fs.writeFileSync(file, 'independent stable bytes');
		const read = fs.readSync;
		let changed = false;
		fs.readSync = function (...args) {
			const result = Reflect.apply(read, this, args);
			if (!changed) {
				changed = true;
				fs.renameSync(file, file + '.acquired');
				fs.writeFileSync(file, 'independent stable bytes');
			}
			return result;
		};
		try {
			refuses(() => f.api.readSourceFile(file), /changed during/);
		} finally {
			fs.readSync = read;
		}
		assert.equal(changed, true);
		assert.equal(fs.readFileSync(file, 'utf8'), 'independent stable bytes');
	});
	records.push({
		name: 'actual local main reaches modeled acquisition with real Source and honest metadata',
		status: 'RUNNING'
	});
	const f = fixture(prepareSyntheticSdk);
	const code = fs.readFileSync(path.join(f.directory, collectorPath), 'utf8');
	const modeled = await withEnvironment({}, () => modelMain(f, code));
	assert.equal(modeled.calls.length, 3);
	assert.equal(modeled.receipt.role, 'local');
	assert.equal(modeled.receipt.context_bound, false);
	assert.equal(modeled.receipt.official_qualified, false);
	assert.equal(modeled.receipt.context.run_id, null);
	assert.equal(modeled.receipt.context.run_attempt, null);
	assert.equal(modeled.receipt.context.candidate, f.head);
	assert.equal(modeled.receipt.source_commit, f.head);
	assert.equal(modeled.receipt.source_commit_after, f.head);
	assert.equal(modeled.receipt.native_children_retired, true);
	assert.equal(modeled.receipt.status, 'FAIL');
	assert.deepEqual(modeled.exits, [1]);
	assert.equal(
		modeled.receipt.children.every((x) => x.started === false),
		true
	);
	assert.equal(
		modeled.receipt.errors.some((x) => x.includes('Usage:')),
		false
	);
	assert.equal(path.dirname(modeled.receipt.output_directory), modeled.evidence);
	assert.match(
		path.basename(modeled.receipt.output_directory),
		/^windows-updater-original-diagnostic-local-[0-9a-f]{40}-[A-Za-z0-9]+$/
	);
	for (const vector of [
		{ label: 'missing archive', missingArchive: true, change: () => {}, reason: /absolute pinned/ },
		{
			label: 'SDK image replacement before first child',
			replaceBeforeChild: true,
			change: () => {},
			reason: /receipt changed/
		},
		{
			label: 'foreign digest',
			change: (directory) =>
				fs.writeFileSync(path.join(directory, 'source-sdk.zip'), 'foreign ZIP'),
			reason: /digest refused before parsing/
		},
		{
			label: 'foreign image',
			change: (directory) =>
				fs.writeFileSync(path.join(directory, 'source-sdk-image.bin'), 'independent foreign image'),
			reason: /member differs/
		},
		{
			label: 'Unix directory image member',
			seal: true,
			change: (directory) => {
				const archive = Buffer.from(syntheticSdkArchive);
				const central = archive.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]));
				archive.writeUInt32LE(0x40000000, central + 38);
				fs.writeFileSync(path.join(directory, 'source-sdk.zip'), archive);
			},
			reason: /file type/
		},
		{
			label: 'Windows stream alias',
			seal: true,
			change: (directory) =>
				fs.writeFileSync(path.join(directory, 'source-sdk.zip'), syntheticSdkAliasArchive),
			reason: /alias/
		}
	]) {
		const subject = vector.seal
			? sdkCase(vector.change)
			: fixture((directory) => prepareSyntheticSdk(directory, vector.change));
		const refusal = await modelMain(subject, code, vector);
		assert.equal(refusal.calls.length, 0, vector.label + ': no native child before SDK refusal');
		assert.equal(refusal.receipt.status, 'FAIL');
		assert.equal(refusal.receipt.context_bound, false);
		assert.equal(refusal.receipt.context.run_id, null);
		assert.match(refusal.receipt.errors.join(' '), vector.reason);
		assert.deepEqual(refusal.exits, [1]);
	}
	assert.equal(modeled.receipt.ahk.file_version_qualified, false);
	assert.equal(modeled.receipt.ahk.file_version_source, 'caller_provided_metadata');
	assert.equal(modeled.receipt.sdk_before.runtime_version, '9.8.7');
	assert.equal(modeled.receipt.sdk_before.native_executed, false);
	assert.equal(modeled.receipt.sdk_before.reported_file_version_qualified, false);
	assert.equal(modeled.receipt.sdk_before.pe.machine, 0x8664);
	assert.equal(modeled.receipt.sdk_before.pe.headers_only, true);
	assert.equal(modeled.receipt.sdk_before.pe.loader_validated, false);
	assert.equal(modeled.receipt.sdk_before.member.name, 'AutoHotkey64.exe');
	assert.equal(modeled.receipt.sdk_before.member.bytes, 512);
	assert.equal(modeled.receipt.sdk_before.image.sha256, sha(syntheticSdkImage));
	assert.deepEqual(modeled.receipt.sdk_after, modeled.receipt.sdk_before);
	records.at(-1).status = 'PASS';
	process.stdout.write('PASS ' + records.at(-1).name + '\n');
	control('original child commands clocks and independent oracle remain frozen', () => {
		const text = fs.readFileSync(path.join(seed, collectorPath), 'utf8');
		const child = text.slice(
			text.indexOf('async function child('),
			text.indexOf('\nasync function main(') + 1
		);
		assert.equal(Buffer.byteLength(child), 2307);
		assert.equal(sha(child), 'c768c56624297229b9886e1aae3bf3e786aceef7a2b667abceffb450727d7464');
		assert.ok(text.includes('const budgetMs = 300000;'));
		assert.ok(child.includes('\n\t\t\t\t\t\t30000\n'));
		assert.equal(
			sha(fs.readFileSync(path.join(seed, oraclePath))),
			'2b00c32567273c9e671b3460fe54b52059032b0188f10103076523d58b59eb01'
		);
	});
	assert.equal(records.length, 22);
	assert.equal(
		records.every((x) => x.status === 'PASS' || x.status === 'SKIP'),
		true
	);
	fs.writeFileSync(
		path.join(root, 'source-controls.receipt.json'),
		JSON.stringify(
			{
				passed: records.filter((x) => x.status === 'PASS').length,
				failed: 0,
				errors: 0,
				skipped: records.filter((x) => x.status === 'SKIP').length,
				subtests_skipped: process.platform === 'win32' ? 1 : 0,
				records,
				native: false,
				official: false,
				temporary
			},
			null,
			2
		) + '\n'
	);
	process.stdout.write('WINDOWS_UPDATER_SOURCE controls=22 native=false official=false\n');
})().catch((error) => {
	fs.writeFileSync(
		path.join(root, 'source-controls.first-failure.json'),
		JSON.stringify({ records, error: String(error), stack: error.stack, native: false }, null, 2) +
			'\n'
	);
	console.error(error);
	process.exitCode = 1;
});
