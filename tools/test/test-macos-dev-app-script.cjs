// tools/test/test-macos-dev-app-script.cjs

/**
 * ==============================================================================
 * MODULE: macOS Developer App Runner Tests
 * DESCRIPTION:
 * Runs the real tools/dev/run-macos-dev-app.sh from a fixture clone whose
 * build script, uname, pgrep, plutil, open, osascript, launchctl, ps and sleep
 * are recording shims. Proves it builds in developer source mode, opens only a
 * developer app recorded for this clone, stops a running ErgoptiPlus first
 * (quit, then the guardian launchd keeps alive booted out), fails naming the
 * survivors when a process outlives SIGKILL, refuses off macOS, and names a
 * retired ~/.hammerspoon bootstrap without deleting user configuration.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '../..');
const SCRIPT = 'tools/dev/run-macos-dev-app.sh';
const IDENTIFIERS = 'static/ergopti_plus/_shared/data/identifiers.sh';

if (process.platform === 'win32') {
	console.log('[SKIP] The macOS developer app runner is a macOS shell tool; not run on Windows.');
	process.exit(0);
}

let checks = 0;
const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-dev-app-')));

/** Writes one executable shim. */
function shim(bin, name, body) {
	fs.writeFileSync(path.join(bin, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
}

/** Builds a fixture clone; returns its paths. */
function fixture(name) {
	const clone = path.join(scratch, name, 'clone with space');
	const home = path.join(scratch, name, 'home');
	const bin = path.join(scratch, name, 'bin');
	const log = path.join(scratch, name, 'calls.log');
	for (const relative of [SCRIPT, IDENTIFIERS]) {
		fs.mkdirSync(path.dirname(path.join(clone, relative)), { recursive: true });
		fs.copyFileSync(path.join(ROOT, relative), path.join(clone, relative));
	}
	fs.mkdirSync(path.join(clone, 'static/ergopti_plus/macos'), { recursive: true });
	fs.writeFileSync(path.join(clone, 'static/ergopti_plus/macos/init.lua'), '-- driver\n');
	fs.mkdirSync(path.join(clone, 'tools/build'), { recursive: true });
	// The real build records the clone root in Info.plist; the shim plist holds it raw.
	fs.writeFileSync(
		path.join(clone, 'tools/build/build_macos_app.sh'),
		`echo "build ERGOPTI_DEV_SOURCE=$ERGOPTI_DEV_SOURCE ERGOPTI_LAUNCHER_ARCHS=$ERGOPTI_LAUNCHER_ARCHS" >> "${log}"
app="$(cd "$(dirname "$0")/../.." && pwd)/build/macos/ErgoptiPlus.app"
mkdir -p "$app/Contents"
printf '%s' "$(cd "$(dirname "$0")/../.." && pwd)" > "$app/Contents/Info.plist"\n`
	);
	// The catalogue stager records its call and answers the fixture's exit code.
	fs.writeFileSync(
		path.join(clone, 'tools/dev/stage-macos-dev-ollama-catalogue.py'),
		`import os, sys\nopen(${JSON.stringify(log)}, "a").write("catalogue\\n")\nsys.exit(int(os.environ.get("FIXTURE_CATALOGUE_EXIT", "0")))\n`
	);
	fs.mkdirSync(home, { recursive: true });
	fs.mkdirSync(bin);
	shim(bin, 'uname', 'echo "${FIXTURE_UNAME:-Darwin}"');
	// A pid that never exists, so the runner's real kill cannot reach a process.
	const pids = path.join(scratch, name, 'pids');
	// Only the bundle-path query answers: a runner that asks by process name
	// finds nothing, as it missed the guardian on the maintainer's Mac.
	shim(
		bin,
		'pgrep',
		`[ "$1 $2" = "-f /ErgoptiPlus.app/Contents/" ] && [ -s "${pids}" ] && cat "${pids}"\nexit 0`
	);
	shim(
		bin,
		'osascript',
		`echo "osascript $*" >> "${log}"\n[ "\${FIXTURE_SURVIVES:-0}" = 1 ] || : > "${pids}"`
	);
	shim(bin, 'launchctl', `echo "launchctl $*" >> "${log}"`);
	shim(bin, 'ps', 'exit 0');
	shim(bin, 'sleep', 'exit 0');
	shim(bin, 'plutil', '[ "$1" = -extract ] && [ "$3" = raw ] || exit 9\ncat "$6"');
	shim(bin, 'open', `echo "open $*" >> "${log}"`);
	return { clone, home, bin, log, pids };
}

/** Runs the real runner inside a fixture. */
function run(paths, args = [], environment = {}) {
	return spawnSync(bashExecutable(), [path.join(paths.clone, SCRIPT), ...args], {
		encoding: 'utf8',
		timeout: 20000,
		env: {
			...process.env,
			PATH: `${paths.bin}${path.delimiter}${process.env.PATH}`,
			HOME: paths.home,
			XDG_CONFIG_HOME: path.join(paths.home, '.config'),
			...environment
		}
	});
}
const calls = (paths) => (fs.existsSync(paths.log) ? fs.readFileSync(paths.log, 'utf8') : '');

function check(name, body) {
	body();
	checks++;
	console.log(`PASS ${name}`);
}

try {
	check('builds in developer source mode, then opens the app of this clone', () => {
		const paths = fixture('build');
		const result = run(paths);
		assert.equal(result.status, 0, result.stderr);
		const app = path.join(paths.clone, 'build/macos/ErgoptiPlus.app');
		assert.equal(
			calls(paths),
			`build ERGOPTI_DEV_SOURCE=1 ERGOPTI_LAUNCHER_ARCHS=native\ncatalogue\nopen ${app}\n`
		);
		assert.match(result.stdout, /Lua runs from .*clone with space\/static\/ergopti_plus\/macos/);
	});

	// The developer app reads the clone's shared data, where no managed Ollama
	// catalogue is committed: without the stager its owned Ollama install
	// refused with OLLAMA_MANAGED_CATALOGUE_MISSING on the maintainer's Mac.
	check('stages the managed Ollama catalogue before opening, and names a missing one', () => {
		const paths = fixture('catalogue');
		const staged = run(paths, []);
		assert.equal(staged.status, 0, staged.stderr);
		assert.match(calls(paths), /^catalogue\nopen /m);
		assert.doesNotMatch(staged.stdout, /WARNING: .*managed Ollama/);
		for (const [code, reason] of [
			['3', /no published managed Ollama catalogue binds this clone/],
			['1', /managed Ollama catalogue was not staged \(exit 1/]
		]) {
			fs.rmSync(paths.log);
			const result = run(paths, ['--open-only'], { FIXTURE_CATALOGUE_EXIT: code });
			assert.equal(result.status, 0, result.stderr);
			assert.match(calls(paths), /^catalogue\nopen /m);
			assert.match(result.stdout, reason);
		}
	});

	check('--open-only opens a recorded developer app without building', () => {
		const paths = fixture('open-only');
		assert.equal(run(paths).status, 0);
		fs.rmSync(paths.log);
		const result = run(paths, ['--open-only']);
		assert.equal(result.status, 0, result.stderr);
		assert.doesNotMatch(calls(paths), /^build /m);
		assert.match(calls(paths), /^catalogue\nopen /);
	});

	check('refuses an app recorded for another clone, or none at all', () => {
		const paths = fixture('foreign');
		assert.equal(run(paths, ['--open-only']).status, 1);
		assert.equal(run(paths).status, 0);
		fs.writeFileSync(
			path.join(paths.clone, 'build/macos/ErgoptiPlus.app/Contents/Info.plist'),
			'/elsewhere'
		);
		fs.rmSync(paths.log);
		const result = run(paths, ['--open-only']);
		assert.equal(result.status, 1);
		assert.match(result.stderr, /runs the Lua of \/elsewhere, not this clone/);
		assert.equal(calls(paths), '', 'a foreign developer app must not be opened');
	});

	check('quits a running ErgoptiPlus and boots its guardian out before building', () => {
		const paths = fixture('running');
		fs.writeFileSync(paths.pids, '999999991\n999999992\n');
		const result = run(paths);
		assert.equal(result.status, 0, result.stderr);
		const log = calls(paths);
		assert.match(log, /^osascript -e tell application id "com\.ergoptiplus\.app" to quit$/m);
		assert.match(log, /^launchctl bootout gui\/\d+\/com\.ergoptiplus\.remap-guardian$/m);
		assert(log.indexOf('launchctl bootout') < log.indexOf('build '), 'stop before building');
		assert.match(result.stdout, /No ErgoptiPlus process is left/);
	});

	check('fails naming the survivors when a process outlives quit, SIGTERM and SIGKILL', () => {
		const paths = fixture('survivor');
		fs.writeFileSync(paths.pids, '999999993\n');
		const result = run(paths, [], { FIXTURE_SURVIVES: '1' });
		assert.equal(result.status, 1);
		assert.match(result.stderr, /survived a quit, SIGTERM and SIGKILL/);
		assert.match(result.stderr, /Login Items & Extensions/);
		assert.doesNotMatch(calls(paths), /^(build|open) /m);
	});

	check('refuses off macOS and an unknown argument, before building', () => {
		const paths = fixture('refusals');
		const linux = run(paths, [], { FIXTURE_UNAME: 'Linux' });
		assert.equal(linux.status, 1);
		assert.match(linux.stderr, /macOS only/);
		assert.equal(run(paths, ['--build']).status, 1);
		assert.equal(calls(paths), '');
	});

	check('names a retired ~/.hammerspoon bootstrap and leaves it in place', () => {
		const paths = fixture('bootstrap');
		const bootstrap = path.join(paths.home, '.hammerspoon/init.lua');
		fs.mkdirSync(path.dirname(bootstrap));
		fs.writeFileSync(bootstrap, '-- Ergopti+ dev bootstrap (auto-generated)\n');
		const result = run(paths);
		assert.equal(result.status, 0, result.stderr);
		assert.match(result.stdout, /\.hammerspoon\/init\.lua is a retired Ergopti\+ dev bootstrap/);
		assert(fs.existsSync(bootstrap), 'user configuration must never be deleted');
	});
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
console.log(`[OK] macOS developer app runner (${checks} checks).`);
