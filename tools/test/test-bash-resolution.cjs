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
 * (a bare "bash", "/bin/bash", a fixed C:\Program Files path).
 *
 * WHAT THIS PINS:
 * 1. The shared resolver, run for real: on Windows its bash is Git for
 *    Windows' own (an MSYS kernel name, not "Linux"); elsewhere it is the
 *    /bin/bash the scripts' shebangs name, and it runs.
 * 2. No tool spawns a bare "bash" or "sh", no second resolver names a
 *    bash.exe, and no Python tool asks PATH for bash: each would reach WSL
 *    again from PowerShell. Floors keep a broken scan from passing.
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
// ======= 2/ No tool resolves bash on its own ======
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

const SPAWN_BARE_SHELL = /\b(?:spawnSync|spawn|execFileSync|execFile)\s*\(\s*(['"`])(?:bash|sh)\1/;
const BASH_EXE = /bash\.exe/;
const PY_WHICH_BASH = /\bwhich\s*\(\s*(['"])bash\1/;
const JS_CONSUMER = /require\(\s*['"][./]*(?:lib|tools\/lib)\/git-bash\.cjs['"]\s*\)/;
const PY_CONSUMER = /\bbash_executable\s*\(\s*\)/;

const errors = [];
let jsConsumers = 0;
let pyConsumers = 0;
const scanned = sources(TOOLS, ['.cjs', '.js', '.mjs', '.py']);
for (const file of scanned) {
	if (RESOLVERS.has(file)) continue;
	const text = code(file);
	if (file.endsWith('.py')) {
		if (PY_WHICH_BASH.test(text))
			errors.push(`${file}: asks PATH for bash; use tools.lib.git_bash.bash_executable()`);
		if (BASH_EXE.test(text))
			errors.push(
				`${file}: names a bash executable itself; use tools.lib.git_bash.bash_executable()`
			);
		if (PY_CONSUMER.test(text)) pyConsumers++;
		continue;
	}
	if (SPAWN_BARE_SHELL.test(text))
		errors.push(
			`${file}: spawns a bare "bash"/"sh"; use bashExecutable() from tools/lib/git-bash.cjs`
		);
	if (BASH_EXE.test(text))
		errors.push(
			`${file}: names a bash executable itself, a second resolver; use tools/lib/git-bash.cjs`
		);
	if (JS_CONSUMER.test(text)) jsConsumers++;
}

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
		`of the shared resolver, no bare spawn in ${scanned.length} tools/ file(s).\x1b[0m`
);
