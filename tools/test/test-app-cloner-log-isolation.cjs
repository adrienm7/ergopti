// tools/test/test-app-cloner-log-isolation.cjs

/**
 * ============================================================================
 * MODULE: App Cloner Log Isolation - Behavioral and Source Guard
 * DESCRIPTION:
 * Proves that an unwritable diagnostic sink cannot prevent osascript launch,
 * and that every generated App Cloner surface uses a private, mode-077 log.
 * ============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const APP_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'apps', 'App Cloner.app');
const LAUNCHER_PATH = path.join(APP_ROOT, 'Contents', 'MacOS', 'AppCloner');
const CLONE_PATH = path.join(APP_ROOT, 'Contents', 'Resources', 'clone_app.sh');
const BUILDER_PATH = path.join(APP_ROOT, 'Contents', 'Resources', 'ShortcutBuilder.applescript');
const PY_CANDIDATES = ['python3', 'python'];
const results = [];

function test(name, ok, detail = '') {
	results.push({ name, ok, detail });
}

function resolvePython() {
	for (const candidate of PY_CANDIDATES) {
		const probe = spawnSync(candidate, ['--version'], { encoding: 'utf8' });
		if (!probe.error && probe.status === 0) return candidate;
	}
	return null;
}

const python = resolvePython();
if (!python) {
	console.error(`No Python interpreter found (tried ${PY_CANDIDATES.join(', ')}).`);
	process.exit(1);
}

const harness = String.raw`
import builtins
import importlib.machinery
import importlib.util
import json
import os
import sys
import types

launcher_path = sys.argv[1]
loader = importlib.machinery.SourceFileLoader("appcloner_fixture", launcher_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
subject = importlib.util.module_from_spec(spec)
loader.exec_module(subject)

events = []
created_logs = []
real_open = builtins.open
real_os_open = subject.os.open
real_run = subject.subprocess.run
real_create_log_path = getattr(subject, "create_log_path", None)

def tracked_create_log_path():
    result = real_create_log_path()
    created_logs.append(result)
    return result

def rejecting_open(file, *args, **kwargs):
    spelling = os.fspath(file)
    if "appcloner" in spelling.lower() and spelling != os.devnull:
        raise PermissionError("injected unwritable App Cloner log")
    return real_open(file, *args, **kwargs)

def rejecting_os_open(file, *args, **kwargs):
    spelling = os.fspath(file)
    if "appcloner" in spelling.lower() and spelling != os.devnull:
        raise PermissionError("injected unwritable App Cloner log")
    return real_os_open(file, *args, **kwargs)

def fake_run(argv, *args, **kwargs):
    events.append(list(argv))
    return types.SimpleNamespace(returncode=0, stdout="", stderr="")

builtins.open = rejecting_open
subject.os.open = rejecting_os_open
subject.subprocess.run = fake_run
if real_create_log_path:
    subject.create_log_path = tracked_create_log_path
try:
    subject.main()
finally:
    builtins.open = real_open
    subject.os.open = real_os_open
    subject.subprocess.run = real_run
    if real_create_log_path:
        subject.create_log_path = real_create_log_path
    for run_dir, _log_path in created_logs:
        if run_dir:
            subject.shutil.rmtree(run_dir, ignore_errors=True)

print(json.dumps(events))
`;

const behavior = spawnSync(python, ['-c', harness, LAUNCHER_PATH], {
	cwd: ROOT,
	encoding: 'utf8',
	maxBuffer: 4 * 1024 * 1024,
});
let events = [];
try {
	events = JSON.parse((behavior.stdout || '').trim());
} catch {
	// The assertions below report the full child result.
}
const behaviorDetail = JSON.stringify({ status: behavior.status,
	error: behavior.error && behavior.error.message, stdout: behavior.stdout, stderr: behavior.stderr });
test('an unwritable diagnostic log cannot prevent osascript launch',
	behavior.status === 0 && events.some((argv) => argv[0] === 'osascript'), behaviorDetail);

const launcher = fs.readFileSync(LAUNCHER_PATH, 'utf8');
const clone = fs.readFileSync(CLONE_PATH, 'utf8');
const builder = fs.readFileSync(BUILDER_PATH, 'utf8');
const combined = `${launcher}\n${clone}\n${builder}`;

test('the fixed cross-user /tmp App Cloner log is absent from every surface',
	!combined.includes('/tmp/appcloner.log'));
test('the failure dialog opens only the exact private log exported by the launcher',
	!combined.includes('/tmp/clone_diag.log')
		&& builder.includes('"Le diagnostic complet est dans " & appLogPath')
		&& builder.includes('quoted form of appLogPath')
		&& builder.includes('if appLogPath is not "" then')
		&& launcher.includes('env["ERGOPTI_APPCLONER_LOG"] = log_path or ""'));
test('the bundle launcher creates a private per-run log with mode-077 defaults',
	launcher.includes('os.umask(0o077)')
		&& launcher.includes('tempfile.mkdtemp(prefix="ergopti-appcloner-")')
		&& launcher.includes('env["ERGOPTI_APPCLONER_LOG"] = log_path or ""'));
test('clone generation accepts only its owned regular log or falls back safely',
	clone.includes('DIAG="${8:-/dev/null}"')
		&& clone.includes('! -L "$DIAG"')
		&& clone.includes('DIAG=/dev/null'));
test('each generated PWA launch owns a private mode-077 diagnostic path',
	clone.includes('PWA_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-pwa.XXXXXXXX")"')
		&& (clone.match(/umask 077/g) || []).length >= 2
		&& clone.includes('ERGOPTI_PWA_LOG="$PWA_LOG_DIR/pwa.log"'));
test('generated PWA diagnostics never persist the authenticated URL',
	!clone.split('\n').some((line) => line.includes('_log(')
		&& (line.includes('{OPEN_ARG') || line.includes('+ OPEN_ARG'))));

const literalMutant = `${launcher}\n${clone}\n${builder}\n_LOG_PATH = "/tmp/appcloner.log"`;
test('the source contract rejects reintroducing the fixed shared log literal',
	literalMutant.includes('/tmp/appcloner.log') && !combined.includes('/tmp/appcloner.log'));

console.log('TAP version 14');
console.log(`1..${results.length}`);
results.forEach((result, index) => {
	console.log(`${result.ok ? 'ok' : 'not ok'} ${index + 1} - ${result.name}`);
	if (!result.ok && result.detail) console.log(`  # ${result.detail}`);
});
console.log(`# passed: ${results.filter((result) => result.ok).length}/${results.length}`);
if (results.some((result) => !result.ok)) process.exitCode = 1;
