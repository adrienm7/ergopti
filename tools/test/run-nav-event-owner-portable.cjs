// tools/test/run-nav-event-owner-portable.cjs

/**
 * ==============================================================================
 * MODULE: Portable Navigation State-Machine Runner
 * DESCRIPTION:
 * Compiles unchanged production Windows C and its hook-free C regressions with
 * real POSIX threads. Native editor messages, hooks and keyboard injection are
 * unavailable and are never represented as a Windows qualification result.
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const SOURCE = path.join(ROOT, 'static/ergopti_plus/windows/native/nav_event_owner');
const SUPPORT = path.join(__dirname, 'support/nav_event_owner_portable');
const NATIVE_ONLY = 'native editor receiver matrix';

/**
 * Resolves every named case from the unchanged native executable's own table.
 * @param {string} source Authored native test source.
 * @returns {string[]} Unique test names, including the native-only editor case.
 */
function testNamesFromSource(source) {
	const table = source.match(/NavTestCase tests\[\] = \{([\s\S]*?)\n\t\};/);
	assert.ok(table, 'Native navigation test registration table is missing.');
	const names = [...table[1].matchAll(/\{\s*"([^"\n]+)"\s*,\s*[A-Za-z_]\w*\s*\}/g)].map(
		(match) => match[1]
	);
	const residue = table[1]
		.replace(/\{\s*"([^"\n]+)"\s*,\s*[A-Za-z_]\w*\s*\}/g, '')
		.replace(/[\s,]/g, '');
	assert.equal(residue, '', 'Every native registration must be parsed before selecting cases.');
	assert.ok(names.length >= 34, 'Native registration floor must not shrink silently.');
	assert.equal(new Set(names).size, names.length, 'Native test names must be unique.');
	assert.equal(
		names.filter((name) => name === NATIVE_ONLY).length,
		1,
		'Native-only editor registration must occur exactly once.'
	);
	return names;
}

/**
 * Reads the production registration census without compiling or claiming native proof.
 * @returns {string[]} Every exact registered native test name.
 */
function testNames() {
	return testNamesFromSource(fs.readFileSync(path.join(SOURCE, 'nav_event_owner_test.c'), 'utf8'));
}

/**
 * Requires an exact successful child outcome, preserving assertion output.
 * @param {string} command Executable to run without a shell.
 * @param {string[]} args Literal arguments.
 * @returns {void}
 */
function execute(command, args) {
	const result = spawnSync(command, args, {
		cwd: ROOT,
		stdio: 'inherit',
		timeout: 30000
	});
	if (result.error) throw result.error;
	assert.equal(result.signal, null, `${command} terminated by ${result.signal}.`);
	assert.equal(result.status, 0, `${command} exited with ${result.status}.`);
}

/**
 * Runs portable cases only; a requested native case fails preparation.
 * @param {string[]} argv Optional exact native test name.
 * @returns {void}
 */
function run(argv) {
	assert.equal(process.platform, 'linux', 'This runner requires an actual Linux host.');
	assert.equal(process.arch, 'x64', 'The production navigation ABI requires x64.');
	assert.ok(argv.length <= 1, 'Expected at most one exact test name.');
	const allNames = testNames();
	if (argv.length) {
		assert.ok(allNames.includes(argv[0]), `Unknown native test name: ${argv[0]}`);
		assert.notEqual(argv[0], NATIVE_ONLY, 'The native editor matrix requires Windows.');
	}
	const names = argv.length ? argv : allNames.filter((name) => name !== NATIVE_ONLY);
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-nav-portable-'));
	try {
		const binary = path.join(temporary, 'nav_event_owner_test');
		const runtimeBinary = path.join(temporary, 'runtime_test');
		const compiler = process.env.CC || 'cc';
		execute(compiler, ['--version']);
		const flags = [
			'-std=c11',
			'-Wall',
			'-Wextra',
			'-Werror',
			'-D_POSIX_C_SOURCE=200809L',
			'-D_WIN32=1',
			'-DERGOPTI_NAV_TESTING=1',
			'-pthread',
			'-I',
			SUPPORT,
			'-I',
			SOURCE
		];
		execute(compiler, [
			...flags,
			path.join(SUPPORT, 'runtime_test.c'),
			path.join(SUPPORT, 'runtime.c'),
			'-o',
			runtimeBinary
		]);
		execute(runtimeBinary, []);
		execute(compiler, [
			...flags,
			path.join(SOURCE, 'nav_event_owner.c'),
			path.join(SOURCE, 'replay_route_core.c'),
			path.join(SOURCE, 'terminal_output_plan.c'),
			path.join(SOURCE, 'hook_trace.c'),
			path.join(SOURCE, 'nav_event_owner_test.c'),
			path.join(SUPPORT, 'runtime.c'),
			'-o',
			binary
		]);
		for (const name of names) execute(binary, [name]);
		console.log(`Portable production C cases passed: ${names.length}/${names.length}.`);
		console.log('Windows native qualification: unavailable on this target.');
		console.log(`Windows-only case not executed: ${NATIVE_ONLY}.`);
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
	}
}

if (require.main === module) {
	try {
		run(process.argv.slice(2));
	} catch (error) {
		console.error(`FAIL portable navigation: ${error.message}`);
		process.exitCode = 1;
	}
}

module.exports = { run, testNames, testNamesFromSource };
