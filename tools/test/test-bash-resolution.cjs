// tools/test/test-bash-resolution.cjs

/**
 * ==============================================================================
 * MODULE: Tools Spawn Git's Bash, Never WSL's
 * DESCRIPTION:
 * Regression guard for the bash that build and test scripts spawn on Windows.
 *
 * WHAT WENT WRONG:
 * Five test scripts and the domain build spawned a bare "bash", and three
 * Python tests spawned shutil.which("bash"). From PowerShell that name is WSL's
 * launcher, so the scripts ran inside a Linux distribution with /mnt/<drive>
 * paths: six JS suite checks were red from PowerShell and green from Git Bash.
 * Nine other scripts carried resolvers of their own, whose fallbacks disagreed
 * (a bare "bash", "/bin/bash", a fixed C:\Program Files path). The npm
 * scripts test:linux, test:linux:e2e and build:linux started a bare "bash"
 * too: npm hands a script line to cmd.exe on Windows, so from PowerShell
 * verify-change ran the Linux suite inside WSL, never on the host.
 *
 * WHAT THIS PINS:
 * 1. The shared resolver, run for real: on Windows its bash is Git for
 *    Windows' own (an MSYS kernel name, not "Linux"); elsewhere it is the
 *    /bin/bash the scripts' shebangs name, and it runs.
 * 2. The detectors below, checked against each shape they reject and each
 *    replacement they accept, so a detector that matches nothing fails.
 * 3. No tool spawns a bare "bash" or "sh", whether as the program of a spawn
 *    or execFile call or as a command string (exec, execSync, a spawn with
 *    shell: true, a Python argument list), no second resolver names a
 *    bash.exe, and no Python tool asks PATH for bash: each would reach WSL
 *    again from PowerShell. Floors keep a broken scan from passing.
 * 4. No package.json script starts a bare "bash" or "sh" in any of its
 *    commands.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const { SYSTEM_BASH, bashExecutable, gitForWindowsRoot } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const TOOLS = path.join(ROOT, 'tools');
const RESOLVERS = new Set(['tools/lib/git-bash.cjs', 'tools/lib/git_bash.py']);
// This guard's own fixtures spell every rejected shape on purpose.
const SELF = 'tools/test/test-bash-resolution.cjs';

// Floors: the scripts migrated to the shared resolvers when this guard landed.
// The Python floor dropped from 3 when karabiner_manifest_test.py stopped
// replaying the build's Karabiner download, which left with the bundled
// installer (the app no longer vendors it); it spawns no shell any more.
const MIN_JS_CONSUMERS = 15;
const MIN_PY_CONSUMERS = 2;
const MIN_SCANNED = 100;

// ==================================================
// ==================================================
// ======= 1/ The resolver, run for real ============
// ==================================================
// ==================================================

const bash = bashExecutable();
const probe = spawnSync(bash, ['-c', 'uname -s'], { encoding: 'utf8', timeout: 30000 });
assert.equal(probe.status, 0, `${bash} -c 'uname -s' failed: ${probe.stderr || probe.error}`);
const kernel = probe.stdout.trim();
if (process.platform === 'win32') {
	assert.ok(path.isAbsolute(bash), `the Windows bash must be an absolute path, got ${bash}`);
	assert.ok(
		bash.toLowerCase().startsWith(gitForWindowsRoot().toLowerCase()),
		`${bash} is not inside the Git for Windows installation ${gitForWindowsRoot()}`
	);
	assert.match(
		kernel,
		/^(MINGW|MSYS)/,
		`${bash} runs on "${kernel}": that is not Git for Windows' bash`
	);
} else {
	assert.equal(bash, fs.existsSync(SYSTEM_BASH) ? SYSTEM_BASH : 'bash');
	assert.notEqual(kernel, '', 'bash printed no kernel name');
}

// ==================================================
// ==================================================
// ======= 2/ The detectors, checked ================
// ==================================================
// ==================================================

const errors = [];

/**
 * True when a shell command line starts a bare bash or sh in any of its
 * commands: npm, exec and a spawn with shell: true hand the line to cmd.exe
 * on Windows, where that name is WSL's launcher.
 * @param {string} commandLine
 * @returns {boolean}
 */
function runsBareShell(commandLine) {
	return commandLine
		.split(/&&|\|\||[;|&]/)
		.some((command) => /^\s*(?:bash|sh)(?:\.exe)?(?:\s|$)/.test(command));
}

// The first argument of a child_process call when it is a string literal: the
// program of spawn and execFile, the command line of exec and of a spawn with
// shell: true. runsBareShell() reads both, since a program name is a one-word
// command line.
const JS_SPAWN_ARGUMENT =
	/\b(?:spawnSync|spawn|execFileSync|execFile|execSync|exec)\s*\(\s*(['"`])((?:\\.|(?!\1)[^\\])*)\1/g;
// The first element of a Python subprocess argument list, or its command string.
const PY_SPAWN_ARGUMENT =
	/\b(?:run|Popen|call|check_call|check_output)\s*\(\s*\[?\s*(['"])((?:\\.|(?!\1)[^\\])*)\1/g;

/**
 * True when source text hands a bare bash or sh to a spawn call.
 * @param {string} text Source text without comments.
 * @param {RegExp} pattern JS_SPAWN_ARGUMENT or PY_SPAWN_ARGUMENT.
 * @returns {boolean}
 */
function spawnsBareShell(text, pattern) {
	for (const match of text.matchAll(pattern)) if (runsBareShell(match[2])) return true;
	return false;
}

const COMMAND_LINE_CASES = [
	['bash tools/build/build-linux-driver.sh --skip-smoke', true],
	["cd static/ergopti_plus/linux && bash -c 'luajit tests/run.lua' --", true],
	['sh ./tools/dev/install.sh', true],
	['node ./tools/lib/git-bash.cjs tools/build/build-linux-driver.sh --skip-smoke', false],
	['node ./tools/test/run-linux-lua.cjs tests/run.lua', false],
	['shx rm -rf build && node ./tools/x.cjs', false]
];
const JS_SPAWN_CASES = [
	["spawnSync('bash', ['-c', 'true'])", true],
	['spawn("sh", ["-c", "true"])', true],
	["execFileSync('bash', [script])", true],
	["execSync('bash tools/build/build-linux-driver.sh --skip-smoke')", true],
	['exec(`cd ${dir} && bash x.sh`, done)', true],
	["spawnSync('sh -c true', { shell: true })", true],
	["spawnSync(bashExecutable(), ['-c', 'true'])", false],
	["execSync('git ls-files', { cwd: ROOT })", false],
	["execSync('shasum -a 256 file')", false]
];
const PY_SPAWN_CASES = [
	['subprocess.run(["bash", "-c", script])', true],
	["subprocess.check_output(['sh', path])", true],
	['subprocess.run("bash x.sh", shell=True)', true],
	['subprocess.run([bash_executable(), "-c", script])', false],
	['subprocess.run(["git", "--exec-path"])', false]
];
for (const [commandLine, bare] of COMMAND_LINE_CASES) {
	if (runsBareShell(commandLine) !== bare)
		errors.push(
			`runsBareShell(${JSON.stringify(commandLine)}) answered ${!bare}, expected ${bare}: the detector is broken`
		);
}
for (const [cases, pattern] of [
	[JS_SPAWN_CASES, JS_SPAWN_ARGUMENT],
	[PY_SPAWN_CASES, PY_SPAWN_ARGUMENT]
]) {
	for (const [source, bare] of cases) {
		if (spawnsBareShell(source, pattern) !== bare)
			errors.push(
				`spawnsBareShell(${JSON.stringify(source)}) answered ${!bare}, expected ${bare}: the detector is broken`
			);
	}
}

// ==================================================
// ==================================================
// ======= 3/ No tool resolves bash on its own ======
// ==================================================
// ==================================================

/** Every tools/ source file of the given extensions, as repo-relative paths. */
function sources(dir, extensions, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		if (entry.name === 'node_modules' || entry.name === '__pycache__') continue;
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) sources(full, extensions, out);
		else if (extensions.includes(path.extname(entry.name)))
			out.push(path.relative(ROOT, full).split(path.sep).join('/'));
	}
	return out;
}

/** Source text without comments; string literals are kept, since they are what is checked. */
function code(file) {
	const text = fs.readFileSync(path.join(ROOT, file), 'utf8');
	if (file.endsWith('.py'))
		return text
			.split('\n')
			.filter((line) => !/^\s*#/.test(line))
			.join('\n');
	return text
		.replace(/\/\*[\s\S]*?\*\//g, '')
		.split('\n')
		.filter((line) => !/^\s*\/\//.test(line))
		.join('\n');
}

const BASH_EXE = /bash\.exe/;
const PY_WHICH_BASH = /\bwhich\s*\(\s*(['"])bash\1/;
const JS_CONSUMER = /require\(\s*['"][./]*(?:lib|tools\/lib)\/git-bash\.cjs['"]\s*\)/;
const PY_CONSUMER = /\bbash_executable\s*\(\s*\)/;

let jsConsumers = 0;
let pyConsumers = 0;
const scanned = sources(TOOLS, ['.cjs', '.js', '.mjs', '.py']);
for (const file of scanned) {
	if (RESOLVERS.has(file) || file === SELF) continue;
	const text = code(file);
	if (file.endsWith('.py')) {
		if (PY_WHICH_BASH.test(text))
			errors.push(`${file}: asks PATH for bash; use tools.lib.git_bash.bash_executable()`);
		if (spawnsBareShell(text, PY_SPAWN_ARGUMENT))
			errors.push(`${file}: spawns a bare "bash"/"sh"; use tools.lib.git_bash.bash_executable()`);
		if (BASH_EXE.test(text))
			errors.push(
				`${file}: names a bash executable itself; use tools.lib.git_bash.bash_executable()`
			);
		if (PY_CONSUMER.test(text)) pyConsumers++;
		continue;
	}
	if (spawnsBareShell(text, JS_SPAWN_ARGUMENT))
		errors.push(
			`${file}: spawns a bare "bash"/"sh"; use bashExecutable() from tools/lib/git-bash.cjs`
		);
	if (BASH_EXE.test(text))
		errors.push(
			`${file}: names a bash executable itself, a second resolver; use tools/lib/git-bash.cjs`
		);
	if (JS_CONSUMER.test(text)) jsConsumers++;
}

// ==================================================
// ==================================================
// ======= 4/ No npm script starts a bare bash ======
// ==================================================
// ==================================================

const MIN_NPM_SCRIPTS = 100;

const npmScripts = Object.entries(
	JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8')).scripts || {}
);
for (const [name, commandLine] of npmScripts) {
	if (runsBareShell(commandLine))
		errors.push(
			`package.json "${name}": starts a bare "bash"/"sh" through npm's shell, WSL's from PowerShell; ` +
				'start a bash script with node ./tools/lib/git-bash.cjs, or spawn the program from a node script'
		);
}

if (npmScripts.length < MIN_NPM_SCRIPTS)
	errors.push(`read only ${npmScripts.length} package.json script(s) (floor ${MIN_NPM_SCRIPTS})`);
if (scanned.length < MIN_SCANNED)
	errors.push(`scanned only ${scanned.length} tools/ file(s) (floor ${MIN_SCANNED})`);
if (jsConsumers < MIN_JS_CONSUMERS) {
	errors.push(
		`only ${jsConsumers} script(s) use tools/lib/git-bash.cjs (floor ${MIN_JS_CONSUMERS}): the scan is broken or a script lost its resolver`
	);
}
if (pyConsumers < MIN_PY_CONSUMERS) {
	errors.push(
		`only ${pyConsumers} Python file(s) call bash_executable() (floor ${MIN_PY_CONSUMERS})`
	);
}

if (errors.length > 0) {
	console.error("\x1b[31m[ERROR] a tool can reach a bash other than the shared resolver's:\x1b[0m");
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] bash is ${bash} (${kernel}); ${jsConsumers} JS and ${pyConsumers} Python consumer(s) ` +
		`of the shared resolver, no bare spawn in ${scanned.length} tools/ file(s) ` +
		`or ${npmScripts.length} npm script(s).\x1b[0m`
);

// Native cwd bytes must survive both real unit runners and complete discovery.
// The ambient and actual same-runtime-without-lfs controls use the same native
// luv file; an optional installed module cannot hide a broken discovery branch.
if (process.platform === 'linux') {
	const { REQUIRED_LUA_SERIES } = require('./lib/host-toolchain.cjs');
	const linuxRuntime = require('./run-linux-lua.cjs').findRuntime();
	const macRuntime = 'lua';
	assert.ok(linuxRuntime, 'The existing native Linux Lua runner is required');
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-runner-path-'));
	// Two drivers, two provider modes, and three physical prefixes must all run.
	const EXPECTED_NATIVE_PATH_CASES = 12;
	const observedCases = new Set();
	const providerMarker = 'Native discovery: same runtime and real luv; lfs unavailable';
	const withoutLfsSource = [
		'local native = require("luv")',
		'assert(native.exepath() == os.getenv("ERGOPTI_TEST_NATIVE_LUA"), "the native Lua executable changed")',
		'local library = assert(package.searchpath("luv", package.cpath))',
		'assert(native.fs_realpath(library) == os.getenv("ERGOPTI_TEST_NATIVE_LUV"), "the native luv library changed")',
		'assert(not pcall(require, "lfs"), "the without-lfs control unexpectedly resolved lfs")',
		'io.write(' + JSON.stringify(providerMarker + '\n') + ')'
	].join('\n');

	/** Observe the actual interpreter and library selected by the ordinary host. */
	function nativeFacts(program) {
		const source = [
			'local native = require("luv")',
			'assert(debug.getinfo(native.fs_stat,"S").what=="C", "the native provider must be real")',
			'local library = assert(package.searchpath("luv", package.cpath))',
			'local values = {assert(native.exepath()), assert(native.fs_realpath(library)), _VERSION, package.path, os.getenv("LD_LIBRARY_PATH") or ""}',
			'io.write(table.concat(values, string.char(0)), string.char(0))'
		].join('\n');
		const observed = spawnSync(program, ['-e', source], {
			cwd: ROOT,
			encoding: 'utf8',
			timeout: 30000
		});
		assert.ifError(observed.error);
		assert.equal(observed.status, 0, observed.stderr);
		const fields = observed.stdout.split(String.fromCharCode(0));
		assert.equal(fields.pop(), '');
		assert.equal(fields.length, 5);
		const [executable, library, version, luaPath, loaderPath] = fields;
		assert.ok(path.isAbsolute(executable) && path.isAbsolute(library));
		assert.ok(fs.statSync(executable).isFile() && fs.statSync(library).isFile());
		return { executable, library, version, luaPath, loaderPath };
	}

	/** Isolate a real native provider, bypassing environment-setting shell aliases. */
	function withoutLfs(name, program, facts) {
		const directory = path.join(temporary, 'native-providers', name);
		const binaries = path.join(directory, 'bin');
		fs.mkdirSync(binaries, { recursive: true, mode: 0o700 });
		fs.symlinkSync(facts.library, path.join(directory, 'luv.so'));
		fs.symlinkSync(facts.executable, path.join(binaries, program));
		const cpath = path.join(directory, '?.so');
		const abi = facts.version.match(/^Lua (\d+)\.(\d+)$/);
		assert.ok(abi, 'The actual interpreter must acknowledge its Lua ABI');
		const env = {
			...process.env,
			PATH: binaries + path.delimiter + (process.env.PATH || ''),
			LUA_CPATH: cpath,
			LUA_PATH: facts.luaPath,
			LD_LIBRARY_PATH: facts.loaderPath,
			ERGOPTI_TEST_NATIVE_LUA: facts.executable,
			ERGOPTI_TEST_NATIVE_LUV: facts.library
		};
		env['LUA_CPATH_' + abi[1] + '_' + abi[2]] = cpath;
		env['LUA_PATH_' + abi[1] + '_' + abi[2]] = facts.luaPath;
		return env;
	}

	try {
		const linuxFacts = nativeFacts(linuxRuntime);
		const macFacts = nativeFacts(macRuntime);
		assert.equal(
			macFacts.version,
			'Lua ' + REQUIRED_LUA_SERIES,
			'The macOS runner uses the canonical pinned Lua series, never the Linux LuaJIT preference'
		);
		const withoutLinux = withoutLfs('linux', linuxRuntime, linuxFacts);
		const withoutMac = withoutLfs('macos', macRuntime, macFacts);
		for (const prefix of ['ordinary', 'literal\\backslash', 'literal\nnewline']) {
			const checkout = path.join(temporary, prefix);
			for (const name of ['linux', 'macos']) {
				const driver = path.join(checkout, 'static/ergopti_plus', name);
				fs.mkdirSync(driver, { recursive: true });
				for (const entry of fs.readdirSync(path.join(ROOT, 'static/ergopti_plus', name), {
					withFileTypes: true
				})) {
					const source = path.join(ROOT, 'static/ergopti_plus', name, entry.name);
					const target = path.join(driver, entry.name);
					if (entry.name === 'tests') fs.cpSync(source, target, { recursive: true });
					else fs.symlinkSync(source, target);
				}
			}
			fs.symlinkSync(
				path.join(ROOT, 'static/ergopti_plus/_shared'),
				path.join(checkout, 'static/ergopti_plus/_shared')
			);
			const tools = path.join(checkout, 'tools');
			fs.mkdirSync(path.join(tools, 'test'), { recursive: true });
			fs.copyFileSync(
				path.join(TOOLS, 'test/run-linux-lua.cjs'),
				path.join(tools, 'test/run-linux-lua.cjs')
			);
			fs.symlinkSync(path.join(TOOLS, 'control'), path.join(tools, 'control'));
			const home = path.join(checkout, 'home');
			fs.mkdirSync(home);
			for (const mode of ['ambient', 'without-lfs']) {
				const isolated = mode === 'without-lfs';
				const prefixArguments = isolated ? ['-e', withoutLfsSource] : [];
				const commands = [
					{
						name: 'Linux',
						program: process.execPath,
						args: [
							path.join(tools, 'test/run-linux-lua.cjs'),
							...prefixArguments,
							'tests/run.lua',
							'--module=infra',
							'--only=keeps the POSIX request tool'
						],
						cwd: checkout,
						count: 1,
						marker: /ok   keeps the POSIX request tool/,
						env: isolated ? withoutLinux : process.env
					},
					{
						name: 'macOS',
						program: isolated ? macFacts.executable : macRuntime,
						args: [
							...prefixArguments,
							'tests/run.lua',
							'--only=tests.unit.infra.text_and_paths.paths.test_native_path'
						],
						cwd: path.join(checkout, 'static/ergopti_plus/macos'),
						count: 5,
						marker: /ok   posix-backslash-separator-owner/,
						env: isolated ? withoutMac : process.env
					}
				];
				for (const command of commands) {
					const launched = spawnSync(command.program, command.args, {
						cwd: command.cwd,
						encoding: 'utf8',
						timeout: 30000,
						maxBuffer: 8 * 1024 * 1024,
						env: { ...command.env, HOME: home }
					});
					assert.ifError(launched.error);
					assert.equal(
						launched.status,
						0,
						command.name +
							' ' +
							mode +
							' ' +
							JSON.stringify(prefix) +
							': ' +
							launched.stdout +
							'\n' +
							launched.stderr
					);
					assert.match(launched.stdout, command.marker);
					if (isolated) assert.equal(launched.stdout.split(providerMarker).length - 1, 1);
					if (command.name === 'Linux') {
						const group = launched.stdout.match(/Module group "infra": (\d+) of (\d+) module\(s\)/);
						assert.ok(group, 'The complete declared infrastructure group must be loaded');
						assert.ok(Number(group[1]) > 0 && Number(group[2]) >= Number(group[1]));
						assert.match(launched.stdout, new RegExp('Total modules:\\s+' + group[1] + '\\n'));
					} else {
						assert.match(launched.stdout, /Total modules:\s+1\n/);
					}
					assert.match(
						launched.stdout,
						new RegExp('Passed tests:\\s+' + command.count + '\\nFailed tests:\\s+0')
					);
					const identity = JSON.stringify([command.name, mode, prefix]);
					assert.ok(!observedCases.has(identity), 'Duplicate native path matrix case: ' + identity);
					observedCases.add(identity);
					console.log(
						'[OK] ' +
							command.name +
							' ' +
							mode +
							' native prefix ' +
							JSON.stringify(prefix) +
							' executes ' +
							command.count +
							' existing case(s) without loader errors.'
					);
				}
			}
		}
		assert.equal(
			observedCases.size,
			EXPECTED_NATIVE_PATH_CASES,
			'The complete native path matrix must run'
		);
		// The source contract must see a newline inside a basename too. A regular
		// declared file is the healthy control; hiding the undeclared emission
		// would turn the second actual contract run into a false green.
		const censusRoot = path.join(temporary, 'source-census\nfixture');
		fs.mkdirSync(censusRoot);
		const censusSource = String.raw`
local function read(path)
 local handle = assert(io.open(path, "rb"))
 local value = assert(handle:read("*a")); assert(handle:close()); return value
end
local function write(path, text)
 local handle = assert(io.open(path, "wb")); assert(handle:write(text)); assert(handle:close())
end
package.path = arg[4] .. "/?.lua;" .. arg[4] .. "/?/init.lua;" .. package.path
local inventory = require("hotpath_segments")
local registry = assert(require("toml_codec").decode(read(arg[3])))
local contract = assert(loadfile(arg[1]))()
local declarations = {}
for name in pairs(inventory.for_driver("macos")) do
 declarations[#declarations + 1] = string.format('HotPath.log_if_slow(%q)\n', name)
end
write(arg[2] .. "/declared.lua", table.concat(declarations))
local cases = 0
local helpers = {
 describe = function(_, body) body() end,
 it = function(_, body) body(); cases = cases + 1 end,
 assert_true = function(value, detail) assert(value, detail) end,
 assert_eq = function(value, expected, detail) assert(value == expected, detail) end,
}
local options = { driver = "macos", root = arg[2],
 call_pattern = 'HotPath%.log_if_slow%(%s*"([^"]+)"',
 default_slow_ms = assert(registry.logger.hotpath_slow_ms),
}
contract.register(helpers, options)
assert(cases > 0); io.write("CENSUS_CONTROL_PASSED=", cases, "\n")
write(arg[2] .. "/hidden\nemission.lua", 'HotPath.log_if_slow("source-census-newline-undeclared")\n')
contract.register(helpers, options)
io.write("CENSUS_HIDDEN_ACCEPTED\n")
`;
		const census = spawnSync(
			macFacts.executable,
			[
				'-e',
				withoutLfsSource,
				'-',
				path.join(ROOT, 'static/ergopti_plus/_shared/lua/test/hotpath_segments_contract.lua'),
				censusRoot,
				path.join(ROOT, 'static/ergopti_plus/_shared/modules/timings/constants.toml'),
				path.join(ROOT, 'static/ergopti_plus/_shared/lua')
			],
			{ input: censusSource, env: withoutMac, cwd: ROOT, encoding: 'utf8', timeout: 30000 }
		);
		assert.ifError(census.error);
		assert.match(census.stdout, /CENSUS_CONTROL_PASSED=[1-9][0-9]*\n/);
		assert.notEqual(
			census.status,
			0,
			'The complete source census must reject the hidden undeclared emission'
		);
		assert.match(census.stderr, /source-census-newline-undeclared/);
		assert.ok(!census.stdout.includes('CENSUS_HIDDEN_ACCEPTED'));
		console.log(
			'[OK] The source census rejects an undeclared emission in a newline-bearing filename.'
		);
		// A real child environment complements the driver's getenv-boundary unit
		// cases. No display conversion may redirect allocations outside TMPDIR.
		const nativeTempSource = String.raw`
package.path = arg[1] .. "/?.lua;" .. arg[1] .. "/?/init.lua;" .. arg[2] .. "/?.lua;" .. arg[2] .. "/?/init.lua;" .. package.path
local native = require("luv")
local expected = assert(arg[3])
assert(os.getenv("TMPDIR") == expected, "the child must receive the actual TMPDIR environment")
local returned = require("tests.helpers").temp_dir()
local expected_root = assert(native.fs_realpath(expected))
assert(native.fs_realpath(returned) == expected_root, "the returned TMPDIR must name the exact existing owned directory")
local allocation
local ok, failure = xpcall(function()
 allocation = assert(native.fs_mkdtemp(returned .. "/allocated.XXXXXX"))
 assert(native.fs_realpath(allocation .. "/..") == expected_root, "the real allocation must stay beneath the owned TMPDIR")
end, debug.traceback)
if allocation then assert(native.fs_rmdir(allocation), "the exact owned allocation must retire") end
if not ok then error(failure, 0) end
io.write("NATIVE_TEMP_ALLOCATION_RETIRED\n")
`;
		const EXPECTED_TEMP_PATH_CASES = 3;
		const tempCases = new Set();
		for (const [label, character] of [
			['backslash', '\\'],
			['quote', "'"],
			['newline', '\n']
		]) {
			assert.equal(character.length, 1, 'The fixture must contain the actual special character');
			const expected = path.join(temporary, 'scratch' + character + label);
			fs.mkdirSync(expected);
			const child = spawnSync(
				macFacts.executable,
				[
					'-e',
					withoutLfsSource,
					'-',
					path.join(ROOT, 'static/ergopti_plus/macos'),
					path.join(ROOT, 'static/ergopti_plus/_shared/lua'),
					expected
				],
				{
					input: nativeTempSource,
					cwd: ROOT,
					env: { ...withoutMac, TMPDIR: expected },
					encoding: 'utf8',
					timeout: 30000
				}
			);
			assert.ifError(child.error);
			assert.equal(
				child.status,
				0,
				'Native TMPDIR ' + label + ': ' + child.stdout + '\n' + child.stderr
			);
			assert.equal(child.stdout.split('NATIVE_TEMP_ALLOCATION_RETIRED\n').length - 1, 1);
			assert.equal(fs.readdirSync(expected).length, 0, 'Every actual owned allocation must retire');
			assert.ok(!tempCases.has(label), 'A native TMPDIR case must not run twice');
			tempCases.add(label);
			console.log(
				'[OK] Native TMPDIR ' + label + ' allocates and retires within the exact owned directory.'
			);
		}
		assert.equal(
			tempCases.size,
			EXPECTED_TEMP_PATH_CASES,
			'Every native TMPDIR path case must run'
		);
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
	}
}
