// tools/test/test-app-cloner-shortcut-maximize.cjs

/**
 * ============================================================================
 * MODULE: App Cloner Shortcut Maximize - Behavioral Guard
 * DESCRIPTION:
 * Executes the production shortcut generator with hermetic macOS tool doubles,
 * then inspects the launcher it actually writes. The generated AppleScript must
 * receive the resolved application name as argv data instead of looking for the
 * literal shell token "$APP_NAME".
 * ============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const SOURCE_SCRIPT = path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'apps',
	'App Cloner.app', 'Contents', 'Resources', 'make_shortcut.sh');

const results = [];

function test(name, ok, detail = '') {
	results.push({ name, ok, detail });
}

function report() {
	console.log('TAP version 14');
	console.log(`1..${results.length}`);
	results.forEach((result, index) => {
		console.log(`${result.ok ? 'ok' : 'not ok'} ${index + 1} - ${result.name}`);
		if (!result.ok && result.detail) console.log(`  # ${result.detail}`);
	});
	console.log(`# passed: ${results.filter((result) => result.ok).length}/${results.length}`);
	if (results.some((result) => !result.ok)) process.exitCode = 1;
}

function resolveBash() {
	const candidates = [];
	if (process.platform === 'win32') {
		const git = spawnSync('git', ['--exec-path'], { encoding: 'utf8' });
		if (!git.error && git.status === 0)
			candidates.push(path.resolve(git.stdout.trim(), '..', '..', '..', 'bin', 'bash.exe'));
		candidates.push('C:\\Program Files\\Git\\bin\\bash.exe');
	} else {
		candidates.push('/bin/bash', 'bash');
	}
	for (const candidate of candidates) {
		const probe = spawnSync(candidate, ['--version'], { encoding: 'utf8' });
		if (!probe.error && probe.status === 0) return candidate;
	}
	return null;
}

function toBashPath(filePath) {
	const normalized = path.resolve(filePath).replace(/\\/g, '/');
	if (process.platform !== 'win32') return normalized;
	const match = normalized.match(/^([A-Za-z]):(\/.*)$/);
	if (!match) throw new Error(`cannot convert path for Git Bash: ${filePath}`);
	return `/${match[1].toLowerCase()}${match[2]}`;
}

function writeExecutable(filePath, source) {
	fs.writeFileSync(filePath, source, { encoding: 'utf8', mode: 0o755 });
	fs.chmodSync(filePath, 0o755);
}

const bash = resolveBash();
if (!bash) {
	console.error('No usable Bash interpreter found.');
	process.exit(1);
}

const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-app-cloner-'));
const fakeBin = path.join(fixtureRoot, 'bin');
const desktop = path.join(fixtureRoot, 'Desktop');
const launcher = path.join(desktop, 'Shortcut.app', 'Contents', 'MacOS', 'open_target');

try {
	fs.mkdirSync(fakeBin, { recursive: true });
	writeExecutable(path.join(fakeBin, 'qlmanage'), `#!/usr/bin/env bash
set -eu
out=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-o' ]; then shift; out="$1"; fi
  shift
done
mkdir -p "$out"
printf 'png' > "$out/preview.png"
`);
	writeExecutable(path.join(fakeBin, 'sips'), `#!/usr/bin/env bash
set -eu
out=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '--out' ]; then shift; out="$1"; fi
  shift
done
mkdir -p "$(dirname "$out")"
printf 'png' > "$out"
`);
	writeExecutable(path.join(fakeBin, 'iconutil'), `#!/usr/bin/env bash
set -eu
out=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-o' ]; then shift; out="$1"; fi
  shift
done
printf 'icns' > "$out"
`);

	const run = spawnSync(bash, [
		toBashPath(SOURCE_SCRIPT),
		'Shortcut',
		'/tmp/project',
		'/Applications/Visual Studio Code.app',
		'#123456',
		'S',
	], {
		cwd: fixtureRoot,
		encoding: 'utf8',
		maxBuffer: 4 * 1024 * 1024,
		env: {
			...process.env,
			HOME: toBashPath(fixtureRoot),
			PATH: `${toBashPath(fakeBin)}:${process.env.PATH || ''}`,
		},
	});
	const detail = JSON.stringify({ status: run.status, error: run.error && run.error.message,
		stdout: run.stdout, stderr: run.stderr });
	test('production generator writes a shortcut launcher',
		run.status === 0 && fs.existsSync(launcher), detail);

	const generated = fs.existsSync(launcher) ? fs.readFileSync(launcher, 'utf8') : '';
	test('generated AppleScript receives the resolved application name as argv',
		generated.includes('osascript "$ASFILE" "$APP_NAME"')
			&& generated.includes('on run argv')
			&& generated.includes('set appName to item 1 of argv'), generated);
	test('generated AppleScript addresses the argv value, never a literal shell token',
		generated.includes('process appName')
			&& !generated.includes('process "$APP_NAME"'), generated);
	const appAssignment = generated.match(/^APP_PATH=.*$/m);
	const appRoundtrip = appAssignment
		? spawnSync(bash, ['-c', `${appAssignment[0]}\nprintf '%s' "$APP_PATH"`], { encoding: 'utf8' })
		: { status: null, stdout: '' };
	test('generated launcher retains the chosen application path',
		appRoundtrip.status === 0
			&& appRoundtrip.stdout === '/Applications/Visual Studio Code.app', generated);
} finally {
	fs.rmSync(fixtureRoot, { recursive: true, force: true });
	report();
}
