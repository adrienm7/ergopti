// tools/test/test-app-cloner-managed-python.cjs

/**
 * ==============================================================================
 * MODULE: App Cloner Runs On The Managed Python
 * DESCRIPTION:
 * Pins the switch of App Cloner off /usr/bin/python3: the AppCloner launcher
 * refuses in words without the managed Python link the Apps menu passes
 * (ERGOPTI_CLONER_PYTHON) or when that interpreter fails the pinned PyObjC
 * import check, and hands the link on otherwise; clone_app.sh refuses without
 * it and puts its folder first on PATH; no script executes /usr/bin/python3
 * any more; the PWA launcher a clone gets execs the versionless link.
 *
 * ROOT CAUSE ENCODED: App Cloner and the launchers it wrote ran PyObjC from
 * /usr/bin/python3, which a Mac without Apple's developer tools answers with
 * an Xcode prompt (owned_runtimes.json). A leftover /usr/bin/python3 call, a
 * launcher that started without the managed Python, or a clone that baked the
 * versioned interpreter path would bring that failure back.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const APP = path.join(ROOT, 'static/ergopti_plus/macos/apps/App Cloner.app/Contents');
const LAUNCHER = path.join(APP, 'MacOS/AppCloner');
const CLONE = path.join(APP, 'Resources/clone_app.sh');
const BUILDER = path.join(APP, 'Resources/ShortcutBuilder.applescript');

if (process.platform === 'win32') {
	console.log('[SKIP] App Cloner is a macOS bundle; not run on Windows.');
	process.exit(0);
}

let checks = 0;
/** Runs one named check. */
function check(name, body) {
	body();
	checks++;
	console.log(`PASS ${name}`);
}

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-cloner-managed-'));

/** Writes one executable named python3 in its own folder. */
function interpreter(name, status) {
	const dir = path.join(scratch, name);
	fs.mkdirSync(dir);
	fs.writeFileSync(path.join(dir, 'python3'), `#!/bin/sh\nexit ${status}\n`, { mode: 0o755 });
	return path.join(dir, 'python3');
}

// Imports the launcher, fakes every osascript call, runs the import check for
// real against the fixture interpreter, and reports what main() dispatched.
const HARNESS = String.raw`
import importlib.machinery, importlib.util, json, sys, types
loader = importlib.machinery.SourceFileLoader("appcloner_managed_python", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
subject = importlib.util.module_from_spec(spec)
loader.exec_module(subject)
real_run = subject.subprocess.run
events = []
def fake_run(argv, *args, **kwargs):
    if argv[0] == "osascript":
        events.append({"argv": list(argv), "python": (kwargs.get("env") or {}).get("ERGOPTI_CLONER_PYTHON")})
        return types.SimpleNamespace(returncode=0, stdout="", stderr="")
    if argv[0] == "zsh":
        return types.SimpleNamespace(returncode=0, stdout="", stderr="")
    return real_run(argv, *args, **kwargs)
subject.subprocess.run = fake_run
subject.os.environ["ERGOPTI_LOCALE"] = "en"
status = 0
try:
    subject.main()
except SystemExit as error:
    status = error.code
print(json.dumps({"status": status, "events": events}))
`;

/** Runs the launcher with one ERGOPTI_CLONER_PYTHON value. */
function launch(value) {
	const env = { ...process.env };
	delete env.ERGOPTI_CLONER_PYTHON;
	if (value !== undefined) env.ERGOPTI_CLONER_PYTHON = value;
	const result = spawnSync('python3', ['-c', HARNESS, LAUNCHER], { encoding: 'utf8', env });
	assert.equal(result.status, 0, result.stderr);
	return JSON.parse(result.stdout.trim().split('\n').pop());
}

const en = JSON.parse(
	fs.readFileSync(
		path.join(ROOT, 'static/ergopti_plus/_shared/core/i18n/data/locales/en.json'),
		'utf8'
	)
);

check('the launcher refuses in words without the managed Python link', () => {
	const outcome = launch(undefined);
	assert.equal(outcome.status, 1);
	assert.equal(outcome.events.length, 1, 'only the refusal dialog is shown');
	assert(outcome.events[0].argv.join('\n').includes(en['apps.cloner.python_missing']));
});

check('the launcher refuses an interpreter that fails the pinned import check', () => {
	const outcome = launch(interpreter('failing', 1));
	assert.equal(outcome.status, 1);
	assert(outcome.events[0].argv.join('\n').includes('lacks PyObjC'));
});

check('the launcher hands a working managed Python to the wizard', () => {
	const link = interpreter('working', 0);
	const outcome = launch(link);
	assert.equal(outcome.status, 0);
	const wizard = outcome.events.find((event) => event.argv[1] !== '-e');
	assert(wizard, 'the wizard runs');
	assert.equal(wizard.python, link);
});

const clone = fs.readFileSync(CLONE, 'utf8');
const setup = clone.slice(
	clone.indexOf('CLONER_PYTHON="${ERGOPTI_CLONER_PYTHON'),
	clone.indexOf("python3 -c 'import sys'")
);

check('clone_app.sh refuses without the link and leads PATH with it', () => {
	assert(setup.length > 0, 'clone_app.sh reads ERGOPTI_CLONER_PYTHON before its first python3');
	const run = (value) =>
		spawnSync('/bin/bash', ['-c', `${setup}\nprintf '%s' "$PATH"`], {
			encoding: 'utf8',
			env:
				value === undefined
					? { PATH: '/usr/bin:/bin' }
					: { PATH: '/usr/bin:/bin', ERGOPTI_CLONER_PYTHON: value }
		});
	assert.notEqual(run(undefined).status, 0);
	assert.equal(run('relative/python3').status, 64);
	assert.equal(run('/opt/managed/python3.11').status, 64, 'only the versionless link is admitted');
	const ok = run('/opt/managed/app-cloner/python3');
	assert.equal(ok.status, 0, ok.stderr);
	assert(ok.stdout.startsWith('/opt/managed/app-cloner:'));
});

check('no App Cloner script executes /usr/bin/python3 any more', () => {
	for (const [file, comment] of [
		[CLONE, /^\s*#/],
		[BUILDER, /^\s*--/],
		[LAUNCHER, /^\s*#/]
	]) {
		const executed = fs
			.readFileSync(file, 'utf8')
			.split('\n')
			.filter((line) => !comment.test(line) && line.includes('/usr/bin/python3'));
		assert.deepEqual(executed, [], `${path.basename(file)} still executes /usr/bin/python3`);
	}
	assert(fs.readFileSync(BUILDER, 'utf8').includes('system attribute "ERGOPTI_CLONER_PYTHON"'));
});

check('a clone execs the versionless link, emitted as an inert assignment', () => {
	assert.match(
		clone,
		/python3 "\$QUOTE_HELPER" shell CLONE_PYTHON "\$CLONER_PYTHON" >> "\$LAUNCHER"/
	);
	assert(clone.includes('exec "$CLONE_PYTHON" "$BUNDLE_RES/pwa_launcher.py"'));
});

fs.rmSync(scratch, { recursive: true, force: true });
console.log(`[OK] App Cloner runs on the managed Python (${checks} checks).`);
