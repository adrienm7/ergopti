// tools/test/prepare-linux-lua54-native-provider.cjs

/** Private validation-tool prerequisite; every child uses the caller's original ownPhase. */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const COMMIT = '2621884230c9072ad77f7379609b74c9d6dbeb86';
const TREE = '016c13e960e1776898fd49322f70e2e849339ad1';
const MESON_BEFORE = '011b150827402869c5f2d742868510644f92c6abdafd0dfd1fa87e350601241c';
const MESON_AFTER = '7172cb0c5e29f0ac3469ea4cbdc7b4c64f2ca87017b7ddfb0cb33ff83121d0dc';
const TEST_NAMES = Object.freeze([
	'simple example',
	'abi example',
	'variadic calls',
	'fundamental type passing',
	'structs, arrays, unions',
	'struct passing',
	'structs, unions array fields',
	'unions by value',
	'global variables',
	'memory-related utilities',
	'memory serialization',
	'callbacks',
	'table initializers',
	'parameterized types',
	'scalar types',
	'symbol redirection',
	'calling conventions',
	'constant expressions',
	'redefinitions',
	'casting rules',
	'type checks',
	'metatype',
	'metatype (5.4)'
]);
function refused() {
	throw new Error('Pinned native Lua54 provider prerequisite refused.');
}
function hash(bytes) {
	return crypto.createHash('sha256').update(bytes).digest('hex');
}
function ordinary(filename) {
	const fact = fs.lstatSync(filename, { bigint: true });
	if (!fact.isFile() || fact.isSymbolicLink()) refused();
	return fact;
}
function elf(filename) {
	ordinary(filename);
	const bytes = fs.readFileSync(filename);
	if (!bytes.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70]))) refused();
	return hash(bytes);
}
function executable(name, env) {
	if (typeof name !== 'string' || !name || /[\0\r\n]/.test(name)) refused();
	const candidates = path.isAbsolute(name)
		? [name]
		: (env.PATH || '/usr/bin:/bin')
				.split(path.delimiter)
				.filter(path.isAbsolute)
				.map((dir) => path.join(dir, name));
	for (const filename of candidates) {
		try {
			const actual = fs.realpathSync(filename);
			fs.accessSync(actual, fs.constants.X_OK);
			elf(actual);
			return actual;
		} catch {}
	}
	refused();
}
function bindMeson(bytes) {
	if (hash(bytes) !== MESON_BEFORE) refused();
	const before = "    cffi = shared_module('cffi',\n        cffi_src,\n";
	const line = "        link_args: ['-Wl,--defsym=luaopen_ffi=luaopen_cffi'],\n";
	const text = bytes.toString('utf8');
	if (text.split(before).length !== 2) refused();
	const bound = text.replace(before, before + line);
	if (hash(Buffer.from(bound)) !== MESON_AFTER || bound.replace(before + line, before) !== text)
		refused();
	return bound;
}
function vendorReceipt(rows, unionSupported) {
	if (
		!Array.isArray(rows) ||
		rows.length !== TEST_NAMES.length ||
		typeof unionSupported !== 'boolean'
	)
		refused();
	const names = new Set();
	for (const row of rows) {
		if (
			!row ||
			typeof row !== 'object' ||
			Array.isArray(row) ||
			!TEST_NAMES.includes(row.name) ||
			names.has(row.name)
		)
			refused();
		names.add(row.name);
		if (row.name === 'unions by value' && !unionSupported) {
			if (row.result !== 'SKIP' || row.returncode !== 77) refused();
		} else if (row.result !== 'OK' || row.returncode !== 0) refused();
	}
	return Object.freeze({
		passed: unionSupported ? 23 : 22,
		vendor_optional_skipped: unionSupported ? 0 : 1,
		registered: 23
	});
}
function sameProvider(first, second, firstSha, secondSha) {
	if (
		!first ||
		!second ||
		!first.isFile() ||
		!second.isFile() ||
		first.isSymbolicLink() ||
		second.isSymbolicLink() ||
		typeof first.dev !== 'bigint' ||
		typeof second.dev !== 'bigint' ||
		typeof first.ino !== 'bigint' ||
		typeof second.ino !== 'bigint' ||
		typeof first.nlink !== 'bigint' ||
		typeof second.nlink !== 'bigint' ||
		first.dev !== second.dev ||
		first.ino !== second.ino ||
		first.nlink < 2n ||
		second.nlink < 2n ||
		!/^[0-9a-f]{64}$/.test(firstSha || '') ||
		firstSha !== secondSha
	)
		refused();
}
function providerCpath(build, nativeLua54Path) {
	if (typeof build !== 'string' || !path.isAbsolute(build) || /[\0\r\n;]/.test(build)) refused();
	if (
		nativeLua54Path !== undefined &&
		(typeof nativeLua54Path !== 'string' ||
			nativeLua54Path === '' ||
			/[\0\r\n]/.test(nativeLua54Path))
	)
		refused();
	// Capture only the versioned native Lua54 path; do not borrow generic/JIT paths.
	return path.join(build, '?.so') + ';' + (nativeLua54Path === undefined ? ';' : nativeLua54Path);
}
async function prepareLua54Provider({ child, current, env, work, lua54, compiler, sourceRoot }) {
	if (
		typeof child !== 'function' ||
		typeof current !== 'function' ||
		!path.isAbsolute(work) ||
		!path.isAbsolute(sourceRoot)
	)
		refused();
	current();
	const directory = path.join(work, 'lua54-native-provider');
	const cpath = providerCpath(path.join(directory, 'build'), env.LUA_CPATH_5_4);
	fs.mkdirSync(directory, { mode: 0o700 });
	current();
	const tools = {
		git: executable('git', env),
		python: executable('/usr/bin/python3', env),
		ninja: executable('ninja', env),
		pkgconfig: executable('pkg-config', env),
		cxx: executable(env.CXX || 'c++', env),
		cc: compiler,
		lua: lua54
	};
	const toolHashes = Object.fromEntries(
		Object.entries(tools).map(([name, filename]) => [name, elf(filename)])
	);
	let sources = [],
		mesonSources = [],
		outputs = [];
	const module = path.join(directory, 'build/cffi.so');
	const alias = path.join(directory, 'build/ffi.so');
	function identityCurrent() {
		for (const [name, filename] of Object.entries(tools)) {
			fs.accessSync(filename, fs.constants.X_OK);
			if (elf(filename) !== toolHashes[name]) refused();
		}
		for (const [filename, expected] of [...sources, ...mesonSources, ...outputs]) {
			ordinary(filename);
			if (hash(fs.readFileSync(filename)) !== expected) refused();
		}
		if (outputs.length) sameProvider(ordinary(module), ordinary(alias), elf(module), elf(alias));
	}
	function admit() {
		current();
		identityCurrent();
		current();
	}
	async function phase(command, args, phaseEnv = env, cwd = directory, budgetMs = 120000) {
		admit();
		const result = await child(command, args, phaseEnv, cwd, budgetMs);
		admit();
		return result;
	}
	const source = path.join(directory, 'source');
	await phase(tools.git, [
		'clone',
		'--no-checkout',
		'--',
		'https://github.com/q66/cffi-lua.git',
		source
	]);
	await phase(tools.git, ['-C', source, 'checkout', '--detach', COMMIT]);
	const head = await phase(tools.git, ['-C', source, 'rev-parse', 'HEAD']);
	const tree = await phase(tools.git, ['-C', source, 'rev-parse', 'HEAD^{tree}']);
	const clean = await phase(tools.git, [
		'-C',
		source,
		'status',
		'--porcelain',
		'--untracked-files=all'
	]);
	if (head.stdout !== COMMIT + '\n' || tree.stdout !== TREE + '\n' || clean.stdout !== '')
		refused();
	const tracked = await phase(tools.git, ['-C', source, 'ls-files', '-z']);
	if (!tracked.stdout.endsWith('\0')) refused();
	const names = tracked.stdout.slice(0, -1).split('\0');
	if (
		!names.length ||
		new Set(names).size !== names.length ||
		names.some(
			(name) =>
				path.isAbsolute(name) || name.split('/').some((part) => part === '..' || part === '.git')
		)
	)
		refused();
	const meson = path.join(source, 'meson.build');
	admit();
	ordinary(meson);
	fs.writeFileSync(meson, bindMeson(fs.readFileSync(meson)));
	sources = names.map((name) => {
		const filename = path.join(source, name);
		ordinary(filename);
		return [filename, hash(fs.readFileSync(filename))];
	});
	admit();
	const mesonModule = await phase(tools.python, [
		'-c',
		'import mesonbuild,os; print(os.path.dirname(mesonbuild.__file__))'
	]);
	const mesonRoot = mesonModule.stdout.trim();
	if (!path.isAbsolute(mesonRoot) || mesonModule.stdout !== mesonRoot + '\n') refused();
	function capturePython(directoryName) {
		const fact = fs.lstatSync(directoryName);
		if (!fact.isDirectory() || fact.isSymbolicLink()) refused();
		for (const entry of fs.readdirSync(directoryName, { withFileTypes: true })) {
			const filename = path.join(directoryName, entry.name);
			if (entry.isSymbolicLink()) refused();
			if (entry.isDirectory()) capturePython(filename);
			else if (entry.isFile() && entry.name.endsWith('.py'))
				mesonSources.push([filename, hash(fs.readFileSync(filename))]);
		}
	}
	admit();
	capturePython(mesonRoot);
	admit();
	if (!mesonSources.length) refused();
	const pkgVersion = await phase(tools.pkgconfig, ['--modversion', 'lua5.4']);
	if (!/^5\.4\.[0-9]+\n$/.test(pkgVersion.stdout)) refused();
	const build = path.join(directory, 'build');
	const buildEnv = {
		...env,
		CXX: tools.cxx,
		CC: tools.cc,
		PKG_CONFIG: tools.pkgconfig,
		NINJA: tools.ninja
	};
	await phase(
		tools.python,
		[
			'-m',
			'mesonbuild.mesonmain',
			'setup',
			build,
			source,
			'-Dlua_version=5.4',
			'-Dlua_path=' + tools.lua,
			'-Dtests=true',
			'-Dlibffi=auto'
		],
		buildEnv
	);
	await phase(
		tools.python,
		['-m', 'mesonbuild.mesonmain', 'compile', '-C', build],
		buildEnv,
		directory,
		180000
	);
	const moduleSha = elf(module);
	const testlib = path.join(build, 'tests/libtestlib.so');
	const testlibSha = elf(testlib);
	await phase(
		tools.python,
		['-m', 'mesonbuild.mesonmain', 'test', '-C', build, '--print-errorlogs', '--no-rebuild'],
		buildEnv,
		directory,
		180000
	);
	const featureEnv = { ...buildEnv, LUA_CPATH: cpath, LUA_CPATH_5_4: cpath };
	const feature = await phase(
		tools.lua,
		[
			'-e',
			'local ffi=require("cffi"); io.write(ffi.abi("unionval") and "unionval=true\\n" or "unionval=false\\n")'
		],
		featureEnv
	);
	if (!['unionval=true\n', 'unionval=false\n'].includes(feature.stdout) || feature.stderr !== '')
		refused();
	const unionSupported = feature.stdout === 'unionval=true\n';
	if (!unionSupported && (process.platform !== 'linux' || process.arch !== 'x64')) refused();
	admit();
	const testlog = path.join(build, 'meson-logs/testlog.json');
	ordinary(testlog);
	const log = fs.readFileSync(testlog, 'utf8');
	if (!log.endsWith('\n')) refused();
	const vendor = vendorReceipt(
		log
			.trimEnd()
			.split('\n')
			.map((line) => JSON.parse(line)),
		unionSupported
	);
	if (elf(module) !== moduleSha || elf(testlib) !== testlibSha) refused();
	const flagsResult = await phase(tools.pkgconfig, ['--cflags', '--libs', 'lua5.4']);
	const flags = [flagsResult.stdout.trim(), env.CFLAGS || '', env.LDFLAGS || '']
		.filter(Boolean)
		.flatMap((value) => {
			if (typeof value !== 'string' || /[\0\r\n]/.test(value)) refused();
			return value.trim().split(/\s+/);
		});
	if (
		!flags.length ||
		flags.some((flag) => !/^-(?:I|L|l)[^\s\0]+$/.test(flag) && flag !== '-pthread')
	)
		refused();
	const witnessSource = path.join(sourceRoot, 'tools/test/fixtures/lua54-provider-entry.c');
	ordinary(witnessSource);
	const witnessSha = hash(fs.readFileSync(witnessSource));
	const witness = path.join(directory, 'native-entry-witness');
	await phase(tools.cc, [witnessSource, '-o', witness, ...flags, '-ldl']);
	const witnessElfSha = elf(witness);
	const entries = await phase(witness, [module]);
	if (
		entries.stdout !== 'Native Lua54 provider: same nonnull dynamic entries\n' ||
		entries.stderr !== ''
	)
		refused();
	admit();
	fs.linkSync(module, alias);
	sameProvider(ordinary(module), ordinary(alias), elf(module), elf(alias));
	outputs = [
		[module, moduleSha],
		[alias, moduleSha],
		[testlib, testlibSha],
		[witness, witnessElfSha],
		[witnessSource, witnessSha],
		[testlog, hash(fs.readFileSync(testlog))]
	];
	admit();
	const ffi = await phase(
		tools.lua,
		[
			'-e',
			'local ffi=require("ffi"); assert(type(ffi)=="table"); local a=assert(package.loadlib(os.getenv("ERGOPTI_PROVIDER_MODULE"),"luaopen_cffi")); local b=assert(package.loadlib(os.getenv("ERGOPTI_PROVIDER_MODULE"),"luaopen_ffi")); assert(rawequal(a,b)); io.write("Native Lua54 provider: genuine ffi entry\\n")'
		],
		{ ...featureEnv, ERGOPTI_PROVIDER_MODULE: module }
	);
	if (ffi.stdout !== 'Native Lua54 provider: genuine ffi entry\n' || ffi.stderr !== '') refused();
	admit();
	return Object.freeze({
		cpath: featureEnv.LUA_CPATH,
		current: identityCurrent,
		vendor,
		sha256: moduleSha,
		commit: COMMIT,
		tree: TREE
	});
}
module.exports = {
	prepareLua54Provider,
	bindMeson,
	vendorReceipt,
	sameProvider,
	TEST_NAMES,
	providerCpath
};
