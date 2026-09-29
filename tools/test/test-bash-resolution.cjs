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
const { spawnSync } = require('node:child_process');
const { SYSTEM_BASH, bashExecutable, gitForWindowsRoot } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const TOOLS = path.join(ROOT, 'tools');
const RESOLVERS = new Set(['tools/lib/git-bash.cjs', 'tools/lib/git_bash.py']);
// This guard's own fixtures spell every rejected shape on purpose.
const SELF = 'tools/test/test-bash-resolution.cjs';

// Floors: the scripts migrated to the shared resolvers when this guard landed.
const MIN_JS_CONSUMERS = 15;
const MIN_PY_CONSUMERS = 3;
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
