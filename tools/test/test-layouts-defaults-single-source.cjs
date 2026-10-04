// tools/test/test-layouts-defaults-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Layout Registry Location Single Source
 * DESCRIPTION:
 * Pins where every driver downloads keyboard layouts from to one file,
 * _shared/modules/layouts/defaults.json, and that file to the real repository
 * folder the index is committed in.
 *
 * WHY:
 * The registry URL is built from four facts (owner, repo, branch, folder). A
 * driver that retypes any of them keeps working until the folder moves or the
 * repository is renamed, then downloads a 404 on one OS only. So:
 *   1. the declared folder must exist and hold the declared index file;
 *   2. the URL template must take owner/repo from the updater defaults (the
 *      repository's one owner/repo source) instead of repeating them;
 *   3. no driver source outside tests may spell the raw-content host or the
 *      folder path, and each registry client must read defaults.json.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const DEFAULTS_PATH = path.join(SP, '_shared', 'modules', 'layouts', 'defaults.json');
const UPDATER_DEFAULTS_PATH = path.join(SP, '_shared', 'modules', 'updater', 'defaults.json');

let failures = 0;

function check(name, fn) {
	try {
		fn();
		console.log(`  ok   ${name}`);
	} catch (err) {
		failures += 1;
		console.error(`  FAIL ${name}\n       ${err.message}`);
	}
}

/** Lists driver sources, skipping tests, vendored code and generated output. */
function driverSources(dir, extensions, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		if (['tests', 'vendor', 'node_modules', '_generated', 'build'].includes(entry.name)) continue;
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) driverSources(full, extensions, out);
		else if (extensions.includes(path.extname(entry.name))) out.push(full);
	}
	return out;
}

/** Drops comments so an explanatory note cannot hide or fake a literal. */
function stripComments(source, extension) {
	if (extension === '.ahk') {
		return source
			.replace(/\/\*[\s\S]*?\*\//g, '')
			.split('\n')
			.map((line) => line.replace(/(^|\s);.*$/, '$1'))
			.join('\n');
	}
	return source.replace(/--\[\[[\s\S]*?\]\]/g, '').replace(/--.*$/gm, '');
}

const defaults = JSON.parse(fs.readFileSync(DEFAULTS_PATH, 'utf8'));
const registry = defaults.registry;
const updater = JSON.parse(fs.readFileSync(UPDATER_DEFAULTS_PATH, 'utf8'));

console.log('Layout registry location single source');

check(
	'the source census retains authored clients and excludes generated bundle inventories',
	() => {
		const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-layout-source-census-'));
		assert.ok(path.resolve(fixture).startsWith(path.resolve(os.tmpdir()) + path.sep));
		try {
			const authored = path.join(fixture, 'infra', 'registry_client.ahk');
			const inventory = path.join(fixture, 'build', 'bundle_inventory.ahk');
			fs.mkdirSync(path.dirname(authored), { recursive: true });
			fs.mkdirSync(path.dirname(inventory), { recursive: true });
			fs.writeFileSync(
				authored,
				'\uFEFF; infra/registry_client.ahk\nRegistryClient() => "authored"\n'
			);
			fs.writeFileSync(
				inventory,
				'\uFEFF; Generated asset path data.\nInventory() => ["' + registry.folder + '"]\n'
			);
			assert.deepStrictEqual(driverSources(fixture, ['.ahk']), [authored]);
		} finally {
			fs.rmSync(fixture, { recursive: true, force: true });
		}
	}
);

check('the declared folder exists and holds the declared index', () => {
	const folder = path.join(ROOT, ...registry.folder.split('/'));
	assert.ok(fs.statSync(folder).isDirectory(), `${registry.folder} is not a folder`);
	assert.ok(
		fs.existsSync(path.join(folder, registry.index_file)),
		`${registry.index_file} is missing`
	);
});

check('the URL template takes every part from a placeholder', () => {
	for (const part of ['{owner}', '{repo}', '{branch}', '{folder}', '{path}']) {
		assert.ok(registry.raw_url_template.includes(part), `raw_url_template lacks ${part}`);
	}
	assert.ok(
		registry.raw_url_template.startsWith('https://'),
		'the registry must be fetched over HTTPS'
	);
	// The URL is built from the template and the fields it names; none of them
	// may carry owner or repo itself. Other values may coincide with the repo
	// name (the Ergopti family is called ergopti) without locating anything.
	for (const key of ['owner', 'repo', 'github']) {
		assert.ok(!(key in registry), `registry.${key} repeats the updater defaults`);
	}
	for (const key of ['raw_url_template', 'folder', 'branch', 'index_file']) {
		for (const part of [updater.github.owner, updater.github.repo]) {
			assert.ok(
				!registry[key].split(/[/{}.]/).includes(part),
				`registry.${key} spells ${part} instead of reading it from the updater defaults`
			);
		}
	}
});

check('the scalars are positive and the branch is a plain name', () => {
	assert.ok(Number.isInteger(registry.download_timeout_sec) && registry.download_timeout_sec > 0);
	assert.ok(Number.isInteger(registry.max_file_bytes) && registry.max_file_bytes > 0);
	assert.match(registry.branch, /^[A-Za-z0-9._-]+$/);
	// A folder name inside the configuration folder, never a path out of it.
	assert.match(registry.local_folder, /^[A-Za-z0-9_-]+$/);
});

check('no driver source spells the registry host or folder', () => {
	const files = [
		...driverSources(path.join(SP, 'windows'), ['.ahk']),
		...driverSources(path.join(SP, 'macos'), ['.lua']),
		...driverSources(path.join(SP, 'linux'), ['.lua']),
		...driverSources(path.join(SP, '_shared', 'lua'), ['.lua'])
	];
	assert.ok(files.length > 300, `scanned only ${files.length} driver files`);
	const offenders = [];
	for (const file of files) {
		const code = stripComments(fs.readFileSync(file, 'utf8'), path.extname(file));
		if (code.includes('raw.githubusercontent.com') || code.includes(registry.folder)) {
			offenders.push(path.relative(ROOT, file));
		}
	}
	assert.deepStrictEqual(offenders, [], 'these files retype the registry location');
});

// The Lua drivers share one registry client, which receives the decoded
// defaults; each driver module that uses it reads the two files itself.
const SHARED_LUA_CLIENT = path.join(SP, '_shared', 'lua', 'layouts', 'registry.lua');

check(
	'every registry client reads the URL template and owner/repo from the shared defaults',
	() => {
		const platforms = {
			windows: driverSources(path.join(SP, 'windows'), ['.ahk']),
			macos: driverSources(path.join(SP, 'macos'), ['.lua']),
			linux: driverSources(path.join(SP, 'linux'), ['.lua'])
		};
		const shared = driverSources(path.join(SP, '_shared', 'lua'), ['.lua']);
		const code = (file) =>
			stripComments(fs.readFileSync(file, 'utf8'), path.extname(file)).replace(/\\\\?/g, '/');
		const templateUsers = [...Object.values(platforms).flat(), ...shared].filter(
			(file) => file !== SHARED_LUA_CLIENT && code(file).includes('raw_url_template')
		);
		for (const [platform, files] of Object.entries(platforms)) {
			const clients = files.filter(
				(file) =>
					/require\(\s*"layouts\.registry"\s*\)/.test(code(file)) || templateUsers.includes(file)
			);
			assert.ok(clients.length >= 1, `the ${platform} driver has no registry client`);
			for (const file of clients) {
				const rel = path.relative(ROOT, file);
				assert.ok(
					code(file).includes('modules/layouts/defaults.json'),
					`${rel} does not read the layouts defaults`
				);
				assert.ok(
					code(file).includes('modules/updater/defaults.json'),
					`${rel} does not read owner/repo from the updater defaults`
				);
			}
		}
		const strays = templateUsers.filter((file) => !Object.values(platforms).flat().includes(file));
		assert.deepStrictEqual(
			strays.map((file) => path.relative(ROOT, file)),
			[],
			'only the shared client and the driver clients may expand the URL template'
		);
	}
);

// A registry id is also a file name on every OS, so each place that accepts
// one must accept exactly what the index builder lets into the registry.
check("every copy of the registry id rule is the index builder's", () => {
	const { ID_RE } = require('../build/build-layouts-index.cjs');
	const canonical = ID_RE.source;
	assert.ok(/^\^.+\$$/.test(canonical), `the builder's id rule ${canonical} is not anchored`);
	const copies = {
		'_shared/lua/layouts/registry.lua': /M\.ID_PATTERN\s*=\s*"([^"]+)"/,
		'windows/modules/keymap/keylayout/layout_registry.ahk':
			/LAYOUT_REGISTRY_ID_PATTERN\s*:=\s*"([^"]+)"/
	};
	for (const [rel, declaration] of Object.entries(copies)) {
		const match = declaration.exec(fs.readFileSync(path.join(SP, ...rel.split('/')), 'utf8'));
		assert.ok(match, `${rel} declares no registry id pattern`);
		assert.strictEqual(
			match[1],
			canonical,
			`${rel} disagrees with the index builder about what a registry id is`
		);
	}
	const schema = JSON.parse(
		fs.readFileSync(path.join(SP, '_shared', 'core', 'config_schema', 'config.schema.json'), 'utf8')
	);
	const selection = schema.$defs.layout.properties.emulated_layout;
	assert.strictEqual(
		selection.pattern,
		`^(${canonical.slice(1, -1)})?$`,
		'config.schema.json must accept a registry id or "" (no layout) and nothing else'
	);
});

// Every registry request announces itself the same way; a second Lua copy of
// the user agent drifts the day one of them is bumped.
check("every copy of the registry user agent is the shared client's", () => {
	const read = (rel) => fs.readFileSync(path.join(SP, ...rel.split('/')), 'utf8');
	const shared = /^M\.USER_AGENT\s*=\s*"([^"]+)"$/m.exec(read('_shared/lua/layouts/registry.lua'));
	assert.ok(shared, '_shared/lua/layouts/registry.lua declares no M.USER_AGENT');
	const catalogue = stripComments(read('_shared/lua/layouts/catalogue.lua'), '.lua');
	assert.ok(
		!catalogue.includes(`"${shared[1]}"`),
		'catalogue.lua repeats the user agent instead of Registry.USER_AGENT'
	);
	assert.ok(
		catalogue.includes('Registry.USER_AGENT'),
		'catalogue.lua does not announce itself as the registry client'
	);
	const windows = /^global LAYOUT_REGISTRY_USER_AGENT := "([^"]+)"$/m.exec(
		read('windows/modules/keymap/keylayout/layout_registry.ahk')
	);
	assert.ok(windows, 'layout_registry.ahk declares no LAYOUT_REGISTRY_USER_AGENT');
	assert.strictEqual(
		windows[1],
		shared[1],
		'the Windows registry client announces another user agent'
	);
});

// The compiled Windows driver reads its Ergopti tables from the registry folder
// extracted next to it (LayoutRegistry_BundledDir: the declared folder, taken
// from the parent of the static folder), so the bundle must copy that folder to
// the same path and refuse to build without the files the emulation reads.
check('the compiled Windows driver ships the registry folder the Ergopti emulation reads', () => {
	const manifest = JSON.parse(
		fs.readFileSync(path.join(ROOT, 'tools', 'build', 'windows_bundle_manifest.json'), 'utf8')
	);
	const trees = manifest.include.map((entry) => [entry.source, entry.dest]);
	assert.ok(trees.length >= 5, `found only ${trees.length} bundle include entries`);
	assert.ok(
		trees.some(([src, dst]) => src === registry.folder && dst === registry.folder),
		`windows_bundle_manifest.json must copy ${registry.folder} to the same path`
	);
	const required = manifest.required
		.filter((entry) => entry.source === entry.dest)
		.map((entry) => entry.source);
	const ergopti = fs.readFileSync(
		path.join(SP, 'windows', 'modules', 'keymap', 'layout', 'layout_ergopti.ahk'),
		'utf8'
	);
	const ids = [...ergopti.matchAll(/^global ERGOPTI_(?:PLUS_)?LAYOUT_ID := "([a-z_]+)"$/gm)].map(
		(m) => m[1]
	);
	assert.strictEqual(
		ids.length,
		2,
		'layout_ergopti.ahk must declare the Ergopti and Ergopti+ registry ids'
	);
	for (const file of [registry.index_file, ...ids.map((id) => `${id}/${id}.keylayout`)]) {
		assert.ok(
			required.includes(`${registry.folder}/${file}`),
			`the bundle manifest's required list must name ${registry.folder}/${file}`
		);
	}
});

// The macOS layout manager installs the Ergopti layouts offline from the
// registry folder it resolves below the packaged app's static tree
// (modules/keymap/layout_registry.lua: <shared>/../../../<folder>), so the
// build must copy it there and refuse to build without its index.
check('the packaged macOS app ships the registry folder the layout manager reads', () => {
	const script = fs.readFileSync(path.join(ROOT, 'tools', 'build', 'build_macos_app.sh'), 'utf8');
	const fn = /^bundle_layout_registry\(\) \{\n[\s\S]*?\n\}\n/m.exec(script);
	assert.ok(fn, 'build_macos_app.sh defines no bundle_layout_registry()');
	const assemble = /^assemble_app\(\) \{\n[\s\S]*?\n\}\n/m.exec(script);
	assert.ok(
		assemble && /^\tbundle_layout_registry "\$static_root"$/m.test(assemble[0]),
		'assemble_app() must call bundle_layout_registry "$static_root"'
	);
	assert.ok(registry.folder.startsWith('static/'), 'the registry folder must live under static/');
	const run = (withIndex) => {
		const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-registry-pack-'));
		const source = path.join(fixture, 'repo', ...registry.folder.split('/'));
		fs.mkdirSync(path.join(source, 'ergol'), { recursive: true });
		fs.writeFileSync(path.join(source, 'ergol', 'ergol.keylayout'), 'layout');
		if (withIndex) fs.writeFileSync(path.join(source, registry.index_file), '{}');
		const staticRoot = path.join(fixture, 'app', 'static');
		fs.mkdirSync(staticRoot, { recursive: true });
		const bash = [
			'set -euo pipefail',
			'log() { :; }',
			'fail() { printf "FAIL: %s\\n" "$*" >&2; exit 1; }',
			fn[0],
			'bundle_layout_registry "$1"'
		].join('\n');
		const result = spawnSync(
			bashExecutable(),
			['-c', bash, 'fixture', staticRoot.replace(/\\/g, '/')],
			{
				encoding: 'utf8',
				env: { ...process.env, REPO_ROOT: path.join(fixture, 'repo').replace(/\\/g, '/') }
			}
		);
		const packaged = path.join(staticRoot, ...registry.folder.slice('static/'.length).split('/'));
		const outcome = {
			status: result.status,
			index: fs.existsSync(path.join(packaged, registry.index_file)),
			layout: fs.existsSync(path.join(packaged, 'ergol', 'ergol.keylayout'))
		};
		fs.rmSync(fixture, { recursive: true, force: true });
		return outcome;
	};
	const shipped = run(true);
	assert.deepStrictEqual(
		shipped,
		{ status: 0, index: true, layout: true },
		'the registry must land at <static root>/<folder below static/>'
	);
	assert.notStrictEqual(run(false).status, 0, 'a build without the registry index must fail');
});

if (failures > 0) process.exit(1);
console.log('All layout registry location checks passed.');
