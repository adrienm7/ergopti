// tools/test/test-app-cloner-dock-url.cjs

/**
 * ============================================================================
 * MODULE: App Cloner Dock URL - Behavioral Guard
 * DESCRIPTION:
 * Executes the real Dock-plist Python body on a hostile application path and
 * verifies byte-exact RFC 3986 encoding plus idempotent tile replacement.
 * ============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const CLONE_SCRIPT = path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'apps',
	'App Cloner.app', 'Contents', 'Resources', 'clone_app.sh');
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
	console.error('Required Python interpreter unavailable');
	process.exit(1);
}

const source = fs.readFileSync(CLONE_SCRIPT, 'utf8');
const dockBody = source.match(
	/python3 - "\$DEST"[^\n]*<<'DOCKEOF'\n([\s\S]*?)\nDOCKEOF/);
const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-dock-url-'));

try {
	const home = path.join(fixtureRoot, 'home');
	const preferences = path.join(home, 'Library', 'Preferences');
	const dockPlist = path.join(preferences, 'com.apple.dock.plist');
	const appPath = '/Users/Élodie #100%/Apps/Dock & Tile (test).app';
	const bundleId = 'fr.ergopti.hostile-dock-url';
	fs.mkdirSync(preferences, { recursive: true });

	const oracle = spawnSync(python, ['-c',
		'from urllib.parse import quote; import sys; '
		+ 'print("file://" + quote(sys.argv[1].rstrip("/"), safe="/") + "/")',
		appPath], { encoding: 'utf8' });
	const expectedUrl = (oracle.stdout || '').trim();

	const seed = spawnSync(python, ['-c',
		'import os,plistlib,sys; os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True); '
		+ 'entry={"GUID":1,"tile-data":{"bundle-identifier":"old",'
		+ '"file-data":{"_CFURLString":sys.argv[2]}},"tile-type":"file-tile"}; '
		+ 'plistlib.dump({"persistent-apps":[entry]}, open(sys.argv[1], "wb"))',
		dockPlist, expectedUrl], { encoding: 'utf8' });

	fs.writeFileSync(path.join(fixtureRoot, 'subprocess.py'), `
class Result:
    returncode = 1
    stdout = ""
    stderr = ""

def run(*args, **kwargs):
    return Result()
`, 'utf8');
	const runner = path.join(fixtureRoot, 'dock_body.py');
	fs.writeFileSync(runner, 'import time\ntime.sleep = lambda _seconds: None\n'
		+ (dockBody ? dockBody[1] : ''), 'utf8');
	const executed = spawnSync(python,
		[runner, appPath, bundleId, '/Applications/Source.app', ''], {
			cwd: fixtureRoot,
			encoding: 'utf8',
			env: { ...process.env, HOME: home, USERPROFILE: home,
				PYTHONPATH: fixtureRoot },
		});
	const inspected = spawnSync(python, ['-c',
		'import json,plistlib,sys; '
		+ 'print(json.dumps(plistlib.load(open(sys.argv[1], "rb")), ensure_ascii=False))',
		dockPlist], { encoding: 'utf8' });
	let dock = {};
	try { dock = JSON.parse(inspected.stdout || '{}'); } catch { /* reported below */ }
	const apps = dock['persistent-apps'] || [];
	const newTile = apps.find((entry) => entry['tile-data']?.['bundle-identifier'] === bundleId);
	const actualUrl = newTile?.['tile-data']?.['file-data']?._CFURLString;

	test('the production Dock body is extracted and executes successfully',
		dockBody !== null && oracle.status === 0 && seed.status === 0
			&& executed.status === 0 && inspected.status === 0,
		JSON.stringify({ oracle: oracle.stderr, seed: seed.stderr,
			executed: executed.stderr, inspected: inspected.stderr }));
	test('the Dock tile URL matches urllib RFC 3986 quoting byte-exact',
		actualUrl === expectedUrl,
		JSON.stringify({ expectedUrl, actualUrl }));
	test('hostile UTF-8 and reserved bytes are percent-encoded',
		expectedUrl === 'file:///Users/%C3%89lodie%20%23100%25/Apps/'
			+ 'Dock%20%26%20Tile%20%28test%29.app/' && actualUrl === expectedUrl,
		JSON.stringify({ expectedUrl, actualUrl }));
	test('recreating the same encoded path replaces rather than duplicates its tile',
		apps.length === 1 && actualUrl === expectedUrl,
		JSON.stringify({ appCount: apps.length, actualUrl }));
} finally {
	fs.rmSync(fixtureRoot, { recursive: true, force: true });
}

console.log('TAP version 14');
console.log(`1..${results.length}`);
results.forEach((result, index) => {
	console.log(`${result.ok ? 'ok' : 'not ok'} ${index + 1} - ${result.name}`);
	if (!result.ok && result.detail) console.log(`  # ${result.detail}`);
});
console.log(`# passed: ${results.filter((result) => result.ok).length}/${results.length}`);
if (results.some((result) => !result.ok)) process.exitCode = 1;
