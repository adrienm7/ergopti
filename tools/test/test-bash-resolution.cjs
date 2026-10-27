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
const vm = require('node:vm');
const { parse } = require('acorn');
const { spawnSync } = require('node:child_process');
const { SYSTEM_BASH, bashExecutable, bashPath, gitForWindowsRoot } = require('../lib/git-bash.cjs');

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

// A native cwd is data: POSIX backslashes and newlines cannot become separators
// or shell record boundaries before the actual Linux test loader starts.
if (process.platform === 'linux') {
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-runner-path-'));
	try {
		const runtime = require('./run-linux-lua.cjs').findRuntime();
		assert.ok(runtime, 'the native Linux runner needs its declared Lua runtime');
		const probe = spawnSync(
			runtime,
			[
				'-e',
				[
					'local uv=require("luv"); assert(debug.getinfo(uv.fs_stat,"S").what=="C")',
					'local library=assert(package.searchpath("luv",package.cpath))',
					'io.write(library,"\\0",tostring(pcall(require,"lfs")),"\\0")'
				].join(';')
			],
			{ cwd: ROOT, encoding: 'utf8' }
		);
		assert.ifError(probe.error);
		assert.equal(probe.status, 0, probe.stderr);
		const [library, ambientLfs] = probe.stdout.split('\0');
		assert.ok(library);
		const nativeModules = path.join(temporary, 'native-modules');
		fs.mkdirSync(nativeModules);
		fs.symlinkSync(path.resolve(ROOT, library), path.join(nativeModules, 'luv.so'));
		const withoutLfs = {
			...process.env,
			LUA_CPATH: `${nativeModules}/?.so`,
			LUA_CPATH_5_4: `${nativeModules}/?.so`,
			LUA_PATH: ';;',
			LUA_PATH_5_4: ';;'
		};
		const absence = spawnSync(
			runtime,
			[
				'-e',
				'local uv=require("luv"); assert(debug.getinfo(uv.fs_stat,"S").what=="C"); assert(not pcall(require,"lfs"))'
			],
			{ cwd: ROOT, env: withoutLfs, encoding: 'utf8' }
		);
		assert.ifError(absence.error);
		assert.equal(absence.status, 0, absence.stderr);
		console.log(
			`[OK] Genuine native luv; ambient lfs=${ambientLfs}; isolated C module search refuses lfs.`
		);
		for (const prefix of ['ordinary', 'literal\\backslash', 'literal\nnewline']) {
			const checkout = path.join(temporary, prefix);
			const driver = path.join(checkout, 'static/ergopti_plus/linux');
			fs.mkdirSync(driver, { recursive: true });
			for (const entry of fs.readdirSync(path.join(ROOT, 'static/ergopti_plus/linux'), {
				withFileTypes: true
			})) {
				const source = path.join(ROOT, 'static/ergopti_plus/linux', entry.name);
				const target = path.join(driver, entry.name);
				if (entry.name === 'tests') fs.cpSync(source, target, { recursive: true });
				else fs.symlinkSync(source, target);
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
			for (const [mode, environment] of [
				['ambient', process.env],
				['without-lfs', withoutLfs]
			]) {
				const launched = spawnSync(
					process.execPath,
					[
						path.join(tools, 'test/run-linux-lua.cjs'),
						'tests/run.lua',
						'--module=infra',
						'--only=keeps the POSIX request tool'
					],
					{
						cwd: checkout,
						encoding: 'utf8',
						timeout: 30000,
						maxBuffer: 8 * 1024 * 1024,
						env: { ...environment, HOME: home }
					}
				);
				assert.ifError(launched.error);
				assert.equal(
					launched.status,
					0,
					`${JSON.stringify(prefix)}/${mode}: ${launched.stdout}\n${launched.stderr}`
				);
				assert.match(launched.stdout, /ok   keeps the POSIX request tool/);
				assert.match(launched.stdout, /Passed tests:\s+1\nFailed tests:\s+0/);
				console.log(
					`[OK] Linux native prefix ${JSON.stringify(prefix)}/${mode} executes one existing case without loader errors.`
				);
			}
		}
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
	}
}

/** Exercises filesystem authority, rather than a converted string comparison. */
function checkNativeBashPaths(convert) {
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-bash-path-'));
	try {
		const prefixes =
			process.platform === 'win32'
				? ['ordinary']
				: ['ordinary', 'literal\\backslash', 'literal\nlinefeed'];
		for (const prefix of prefixes) {
			const directory = path.join(scratch, prefix);
			fs.mkdirSync(directory);
			const file = path.join(directory, 'payload');
			fs.writeFileSync(file, 'native path bytes');
			const result = spawnSync(
				bash,
				['-c', 'test -f "$1" && cat -- "$1"', 'native-path', convert(file)],
				{
					encoding: 'utf8',
					timeout: 10000
				}
			);
			assert.ifError(result.error);
			assert.equal(result.signal, null);
			assert.equal(result.status, 0, `${JSON.stringify(prefix)}: ${result.stderr}`);
			assert.equal(result.stdout, 'native path bytes');
			if (process.platform !== 'win32') assert.equal(convert(file), file);
		}
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
}
checkNativeBashPaths(bashPath);

// Execute the actual exported implementation under a Windows host model.
// This is lexical coverage, not a claim that native Windows Bash ran here.
const windowsPathModule = { exports: {} };
vm.runInNewContext(fs.readFileSync(path.join(TOOLS, 'lib/git-bash.cjs'), 'utf8'), {
	require,
	module: windowsPathModule,
	process: { platform: 'win32' }
});
assert.equal(typeof windowsPathModule.exports.bashPath, 'function');
for (const [native, expected] of [
	['C:\\Users\\native path\\file', '/c/Users/native path/file'],
	['D:/native path/file', '/d/native path/file'],
	['relative\\file', 'relative/file'],
	['/usr/bin/file', '/usr/bin/file']
])
	assert.equal(windowsPathModule.exports.bashPath(native), expected);
assert.throws(() => bashPath(null), TypeError);

/** Finds a direct private converter without rejecting Windows-only fixture bridges. */
function fixturePathBinding(source) {
	const tree = parse(source, { ecmaVersion: 'latest' });
	const imports = [];
	const calls = [];
	const privateConverters = [];
	const unsafeBoundaries = [];
	function conversion(node) {
		if (!node || typeof node !== 'object') return false;
		if (
			node.type === 'ConditionalExpression' &&
			node.test?.operator === '===' &&
			node.test.left?.object?.name === 'process' &&
			node.test.left.property?.name === 'platform' &&
			node.test.right?.value === 'win32'
		)
			return conversion(node.alternate);
		if (
			node.type === 'CallExpression' &&
			node.callee.property?.name === 'replaceAll' &&
			node.arguments[0]?.value === '\\' &&
			node.arguments[1]?.value === '/'
		)
			return true;
		return Object.values(node).some((value) =>
			Array.isArray(value)
				? value.some(conversion)
				: value && typeof value === 'object' && conversion(value)
		);
	}
	function visit(node, windowsContext = false) {
		if (!node || typeof node !== 'object') return;
		if (
			node.type === 'VariableDeclarator' &&
			node.id.type === 'ObjectPattern' &&
			node.init?.callee?.name === 'require' &&
			node.init.arguments[0]?.value === '../lib/git-bash.cjs'
		) {
			for (const property of node.id.properties) {
				if (property.key?.name === 'bashPath') imports.push(property.value.name);
			}
		}
		if (node.type === 'CallExpression' && node.callee.name === 'bashPath') calls.push(node);
		if (
			!windowsContext &&
			node.type === 'CallExpression' &&
			['spawnSync', 'spawn', 'execFileSync', 'execFile'].includes(
				node.callee.name || node.callee.property?.name
			) &&
			node.arguments.some(conversion)
		)
			unsafeBoundaries.push(node);
		if (
			['IfStatement', 'ConditionalExpression'].includes(node.type) &&
			node.test?.operator === '===' &&
			node.test.left?.object?.name === 'process' &&
			node.test.left.property?.name === 'platform' &&
			node.test.right?.value === 'win32'
		) {
			visit(node.consequent, true);
			visit(node.alternate, windowsContext);
			return;
		}
		const callable =
			node.type === 'FunctionDeclaration'
				? node
				: node.type === 'VariableDeclarator' &&
					  ['ArrowFunctionExpression', 'FunctionExpression'].includes(node.init?.type)
					? node.init
					: null;
		let guarded = windowsContext;
		if (callable) {
			const body = callable.body;
			const first = body.body?.[0];
			const test = first?.test;
			const windowsOnly =
				first?.type === 'IfStatement' &&
				test?.operator === '!==' &&
				test.left?.object?.name === 'process' &&
				test.left.property?.name === 'platform' &&
				test.right?.value === 'win32' &&
				first.consequent.type === 'ReturnStatement';
			guarded = guarded || windowsOnly;
			const returns = [];
			function collectReturns(value) {
				if (
					!value ||
					typeof value !== 'object' ||
					['FunctionExpression', 'ArrowFunctionExpression', 'FunctionDeclaration'].includes(
						value.type
					)
				)
					return;
				if (value.type === 'ReturnStatement') returns.push(value.argument);
				for (const child of Object.values(value)) {
					if (Array.isArray(child)) child.forEach(collectReturns);
					else if (child && typeof child === 'object') collectReturns(child);
				}
			}
			collectReturns(body);
			const convertedLocals =
				body.body
					?.filter((statement) => statement.type === 'VariableDeclaration')
					.flatMap((statement) => statement.declarations)
					.filter((declaration) => conversion(declaration.init)) || [];
			const returnsConvertedLocal = returns.some(
				(value) =>
					value?.type === 'Identifier' &&
					convertedLocals.some((declaration) => declaration.id.name === value.name)
			);
			if (
				!windowsOnly &&
				(body.type !== 'BlockStatement'
					? conversion(body)
					: returns.some(conversion) || returnsConvertedLocal)
			)
				privateConverters.push(callable);
		}
		for (const value of Object.values(node)) {
			if (Array.isArray(value)) value.forEach((child) => visit(child, guarded));
			else if (value && typeof value === 'object') visit(value, guarded);
		}
	}
	visit(tree);
	return (
		imports.length === 1 &&
		imports[0] === 'bashPath' &&
		calls.length > 0 &&
		privateConverters.length === 0 &&
		unsafeBoundaries.length === 0
	);
}
assert.equal(
	fixturePathBinding(
		"const { bashPath } = require('../lib/git-bash.cjs'); consume(bashPath(file));"
	),
	true
);
assert.equal(fixturePathBinding(''), false);
assert.equal(
	fixturePathBinding(
		"const bashPath = value => value.replaceAll('\\\\', '/'); consume(bashPath(file));"
	),
	false
);
assert.equal(
	fixturePathBinding(
		"const { bashPath } = require('../lib/git-bash.cjs'); const privatePath = value => value.replaceAll('\\\\', '/'); consume(privatePath(file));"
	),
	false
);
assert.equal(
	fixturePathBinding(
		"const { bashPath } = require('../lib/git-bash.cjs'); consume(bashPath(file)); spawnSync(bash, [file.replaceAll('\\\\', '/')]);"
	),
	false
);
assert.equal(
	fixturePathBinding(
		"const { bashPath } = require('../lib/git-bash.cjs'); consume(bashPath(file)); if (process.platform === 'win32') spawnSync(bash, [file.replaceAll('\\\\', '/')]);"
	),
	true
);
assert.equal(
	fixturePathBinding(
		"const { bashPath } = require('../lib/git-bash.cjs'); consume(bashPath(file)); function privatePath(value) { const converted = value.replaceAll('\\\\', '/'); return converted; }"
	),
	false
);
for (const fixture of [
	'test-linux-uninstall-sandbox.cjs',
	'test-linux-package-setup.cjs',
	'test-linux-tracked-copy.cjs',
	'test-linux-source-toolchain.cjs',
	'test-linux-install-layout-registry.cjs',
	'test-linux-canonical-pack-upgrade.cjs',
	'test-linux-tray-icon-assets.cjs',
	'test-linux-launcher-deps.cjs',
	'test-linux-network-runtime.cjs',
	'test-linux-portable-network-runtime.cjs'
]) {
	assert.ok(
		fixturePathBinding(fs.readFileSync(path.join(__dirname, fixture), 'utf8')),
		`${fixture} must consume the one native Bash-path owner without a private converter`
	);
}
console.log(
	'[OK] Native Bash paths retain filesystem bytes; ten fixture callers share the tested owner.'
);
