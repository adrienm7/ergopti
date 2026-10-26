// tools/test/test-app-cloner-dock-url.cjs

/**
 * ============================================================================
 * MODULE: App Cloner Dock URL - Behavioral Guard
 * DESCRIPTION:
 * Executes the actual pure URL/deduplication/append source operations on a
 * hostile path. POSIX transaction reachability and kernel locks are exercised
 * by the Hammerspoon/native Dock writer campaign; this portable guard does not
 * claim to execute native locking or the entire Dock writer.
 * ============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const CLONE_SCRIPT = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'macos',
	'apps',
	'App Cloner.app',
	'Contents',
	'Resources',
	'clone_app.sh'
);
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
const dockBody = source.match(/python3 - "\$DEST"[^\n]*<<'DOCKEOF'\n([\s\S]*?)\nDOCKEOF/);
const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-dock-url-'));

try {
	const home = path.join(fixtureRoot, 'home');
	const preferences = path.join(home, 'Library', 'Preferences');
	const dockPlist = path.join(preferences, 'com.apple.dock.plist');
	const appPath = '/Users/Élodie #100%/Apps/Dock & Tile (test).app';
	const bundleId = 'fr.ergopti.hostile-dock-url';
	fs.mkdirSync(preferences, { recursive: true });

	const oracle = spawnSync(
		python,
		[
			'-c',
			'from urllib.parse import quote; import sys; ' +
				'print("file://" + quote(sys.argv[1].rstrip("/"), safe="/") + "/")',
			appPath
		],
		{ encoding: 'utf8' }
	);
	const expectedUrl = (oracle.stdout || '').trim();

	const seed = spawnSync(
		python,
		[
			'-c',
			'import os,plistlib,sys; os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True); ' +
				'entry={"GUID":1,"tile-data":{"bundle-identifier":"old",' +
				'"file-data":{"_CFURLString":sys.argv[2]}},"tile-type":"file-tile"}; ' +
				'plistlib.dump({"persistent-apps":[entry]}, open(sys.argv[1], "wb"))',
			dockPlist,
			expectedUrl
		],
		{ encoding: 'utf8' }
	);

	const bodyFile = path.join(fixtureRoot, 'actual_dock_body.py');
	fs.writeFileSync(bodyFile, dockBody ? dockBody[1] : '', 'utf8');
	const runner = path.join(fixtureRoot, 'dock_pure_operations.py');
	fs.writeFileSync(
		runner,
		String.raw`import ast,json,os,plistlib,sys
from urllib.parse import quote

body_path,app_path,bundle_id,plist_path = sys.argv[1:]
with open(body_path, encoding="utf-8") as stream:
    tree = ast.parse(stream.read(), filename=body_path)

def exactly_one(nodes, description):
    if len(nodes) != 1:
        raise ValueError("Expected exactly one actual " + description)
    return nodes[0]

def is_name(node, name):
    return isinstance(node, ast.Name) and node.id == name

def is_dedupe(node):
    return (isinstance(node, ast.Assign) and len(node.targets) == 1
            and is_name(node.targets[0], "apps") and isinstance(node.value, ast.ListComp))

def is_append(node):
    return (isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)
            and isinstance(node.value.func, ast.Attribute)
            and is_name(node.value.func.value, "apps") and node.value.func.attr == "append")

# Walking identifies ambiguity only. Admission requires direct placement in
# the actual top-level transaction, so dead/conditional branches cannot pass.
url_function = exactly_one([node for node in ast.walk(tree)
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == "dock_file_url"], "URL function")
if url_function not in tree.body or not isinstance(url_function, ast.FunctionDef):
    raise ValueError("The pure URL function must have direct module placement")
transaction = exactly_one([node for node in tree.body if isinstance(node, ast.With)
    and len(node.items) == 1 and isinstance(node.items[0].context_expr, ast.Call)
    and is_name(node.items[0].context_expr.func, "dock_update_lock")
    and not node.items[0].context_expr.args and not node.items[0].context_expr.keywords], "Dock transaction")
dedupe = exactly_one([node for node in ast.walk(tree) if is_dedupe(node)], "deduplication operation")
append = exactly_one([node for node in ast.walk(tree) if is_append(node)], "append operation")
if dedupe not in transaction.body or append not in transaction.body or transaction.body.index(dedupe) >= transaction.body.index(append):
    raise ValueError("Pure tile operations must have ordered direct transaction placement")

# Execute original source nodes, without importing or mocking the platform
# lock module. The fixture supplies only ordinary in-memory tile state.
exec(compile(ast.Module(body=[url_function], type_ignores=[]), body_path, "exec"))
url = dock_file_url(app_path)
with open(plist_path, "rb") as stream:
    dock = plistlib.load(stream)
apps = dock["persistent-apps"]
tile_data = {"bundle-identifier": bundle_id, "file-data": {"_CFURLString": url}}
exec(compile(ast.Module(body=[dedupe, append], type_ignores=[]), body_path, "exec"))
dock["persistent-apps"] = apps
print(json.dumps(dock, ensure_ascii=False))
`,
		'utf8'
	);
	const executed = spawnSync(python, [runner, bodyFile, appPath, bundleId, dockPlist], {
		cwd: fixtureRoot,
		encoding: 'utf8'
	});
	let dock = {};
	try {
		dock = JSON.parse(executed.stdout || '{}');
	} catch {
		/* reported below */
	}
	const apps = dock['persistent-apps'] || [];
	const newTile = apps.find((entry) => entry['tile-data']?.['bundle-identifier'] === bundleId);
	const actualUrl = newTile?.['tile-data']?.['file-data']?._CFURLString;

	test(
		'the actual pure Dock URL and tile operations are extracted and execute successfully',
		dockBody !== null && oracle.status === 0 && seed.status === 0 && executed.status === 0,
		JSON.stringify({
			oracle: oracle.stderr,
			seed: seed.stderr,
			executed: executed.stderr
		})
	);
	test(
		'the Dock tile URL matches urllib RFC 3986 quoting byte-exact',
		actualUrl === expectedUrl,
		JSON.stringify({ expectedUrl, actualUrl })
	);
	test(
		'hostile UTF-8 and reserved bytes are percent-encoded',
		expectedUrl ===
			'file:///Users/%C3%89lodie%20%23100%25/Apps/' + 'Dock%20%26%20Tile%20%28test%29.app/' &&
			actualUrl === expectedUrl,
		JSON.stringify({ expectedUrl, actualUrl })
	);
	test(
		'recreating the same encoded path replaces rather than duplicates its tile',
		apps.length === 1 && actualUrl === expectedUrl,
		JSON.stringify({ appCount: apps.length, actualUrl })
	);
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
