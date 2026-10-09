// tools/test/test-native-menu-rows.cjs

/**
 * ==============================================================================
 * MODULE: Native Menu Rows Ratchet
 * DESCRIPTION:
 * The maintainer's rule of 2026-09-30: every tray menu is built from the
 * shared menu manifest by each driver's manifest renderer; driver code keeps
 * only the command handlers and the dynamic providers the manifest names.
 * Defining rows in driver code is the practice that let the Gestures submenu
 * put its restore and clear in a different place on each driver.
 *
 * This inventories every site where driver code still creates a menu row
 * itself, per driver, and fails when a driver's count rises above the
 * checked-in baseline (native-menu-rows-baseline.json). The baseline lists
 * each site as file:line, so the migration can drive it to zero; lower it
 * with `--update-baseline` in the commit that moves rows to the manifest.
 * Never raise it: a new row belongs in the manifest.
 *
 * WHAT COUNTS AS A NATIVE SITE (one source line each, comments skipped):
 *   Windows, every production .ahk but the renderer, its dispatcher and the
 *   tray adapter:
 *     register   RegisterMenuItem(...)            a clickable row it adds
 *     add        .Add(...) in a menu or tray file  a row, separator or submenu
 *                (Gui controls and list views elsewhere use the same name)
 *     append     MenuRenderer_Append*(...)        a declared row it places
 *     static     Map("label", t("key") ...)       a row labelled by a fixed key
 *     separator  Map("separator", true)           a separator it inserts
 *   macOS and Linux, every .lua under ui/menu/:
 *     static     label/title = i18n...("key")     a row labelled by a fixed key
 *     separator  title = "-" / separator = true   a separator it inserts
 *     native     { title = <computed>, fn|menu }  a renderer-shaped row it builds
 * A provider row whose label is computed (one per slot, model or file) is the
 * dynamic data the manifest's `list` rows exist for, and is not counted.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const BASELINE_PATH = path.join(__dirname, 'native-menu-rows-baseline.json');
const UPDATE = process.argv.includes('--update-baseline');

// The renderer and the adapters it draws through are where rows are meant to
// be created; everything else is driver code.
const WINDOWS_RENDERER = new Set([
	'windows/infra/manifest_menu.ahk',
	'windows/infra/menu_dispatcher.ahk',
	'windows/adapters/tray_menu.ahk',
	'windows/ui/menu/menu_engine.ahk',
	'windows/ui/menu/menu_rebuild.ahk'
]);

// Gui.Add's first argument is a control type; Menu.Add's is a label.
const GUI_CONTROL =
	/\.Add\(\s*"(?:Text|Button|Edit|Checkbox|CheckBox|Radio|DropDownList|DDL|ComboBox|ListBox|ListView|TreeView|Link|Hotkey|DateTime|MonthCal|Slider|Progress|GroupBox|Tab|Tab2|Tab3|StatusBar|ActiveX|Custom|Picture|Pic|UpDown)"/;

const I18N_CALL = String.raw`(?:i18n_safe|i18n_mod\s*[.:]\s*\w+|[Ii]18n\s*[.:]\s*\w+)\(\s*"`;

const RULES = {
	'.ahk': [
		{ kind: 'register', re: /\bRegisterMenuItem\(/ },
		{ kind: 'append', re: /\bMenuRenderer_Append\w*\(/ },
		{ kind: 'static', re: /\bMap\(\s*"label"\s*,\s*t\(\s*"/ },
		{ kind: 'separator', re: /\bMap\(\s*"separator"\s*,\s*true\b/ },
		{ kind: 'add', re: /\.Add\(/, unless: GUI_CONTROL, files: /(?:^windows\/ui\/menu\/|tray)/ }
	],
	'.lua': [
		{
			kind: 'static',
			re: new RegExp(String.raw`\b(?:label|title)\s*=\s*(?:"[^"]*"\s*\.\.\s*)?${I18N_CALL}`),
			unless: /^\s*local\s/
		},
		{ kind: 'separator', re: /\btitle\s*=\s*"-"|\bseparator\s*=\s*true\b/ },
		{ kind: 'native', re: /\btitle\s*=(?=.*\b(?:fn|menu)\s*=)/, unless: /^\s*local\s/ }
	]
};

// ==================================================
// ==================================================
// ======= 1/ The inventory =========================
// ==================================================
// ==================================================

/**
 * Every file under a directory with one extension, tests and generated code excluded.
 * @param {string} dir Absolute directory.
 * @param {string} ext '.ahk' or '.lua'.
 * @returns {string[]} Absolute paths, sorted.
 */
function sourceFiles(dir, ext) {
	const files = [];
	if (!fs.existsSync(dir)) return files;
	(function walk(current) {
		for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
			const full = path.join(current, entry.name);
			if (entry.isDirectory()) {
				if (!['tests', 'test', 'vendor', 'node_modules', '_generated'].includes(entry.name))
					walk(full);
			} else if (full.endsWith(ext)) {
				files.push(full);
			}
		}
	})(dir);
	return files.sort();
}

/**
 * The native sites of one source text.
 * @param {string} rel Path shown in the inventory.
 * @param {string} text File content.
 * @param {string} ext '.ahk' or '.lua'.
 * @returns {string[]} "file:line kind" entries.
 */
function sitesOf(rel, text, ext) {
	const comment = ext === '.ahk' ? /^\s*;/ : /^\s*--/;
	const sites = [];
	text.split('\n').forEach((line, index) => {
		if (comment.test(line)) return;
		for (const rule of RULES[ext]) {
			if (rule.files && !rule.files.test(rel)) continue;
			if (rule.re.test(line) && !(rule.unless && rule.unless.test(line))) {
				sites.push(`${rel}:${index + 1} ${rule.kind}`);
				return;
			}
		}
	});
	return sites;
}

/**
 * The inventory of one driver.
 * @param {string} driver 'windows', 'macos' or 'linux'.
 * @returns {string[]} Its native sites.
 */
function inventory(driver) {
	const roots =
		driver === 'windows' ? [path.join(SP, 'windows')] : [path.join(SP, driver, 'ui', 'menu')];
	const ext = driver === 'windows' ? '.ahk' : '.lua';
	const sites = [];
	const traversed = new Set();
	for (const root of roots) {
		assert.ok(
			fs.existsSync(root) && fs.statSync(root).isDirectory(),
			`${driver}: mandatory source root must exist: ${root}`
		);
		for (const file of sourceFiles(root, ext)) {
			const rel = path.relative(SP, file).split(path.sep).join('/');
			if (WINDOWS_RENDERER.has(rel)) continue;
			const text = fs.readFileSync(file, 'utf8');
			// File coverage is independent of how many handwritten rows remain.
			// Full-line comments and block comments alone are not source evidence.
			const code =
				ext === '.ahk'
					? text.replace(/\/\*[\s\S]*?\*\//g, '')
					: text.replace(/--\[(=*)\[[\s\S]*?\]\1\]/g, '');
			const comment = ext === '.ahk' ? /^\s*;/ : /^\s*--/;
			assert.ok(
				code.split('\n').some((line) => line.trim() && !comment.test(line)),
				`${driver}: production source must be nonempty: ${rel}`
			);
			traversed.add(rel);
			sites.push(...sitesOf(rel, text, ext));
		}
	}
	const retired = CURRENT_SOURCE_RETIREMENTS[driver] || [];
	for (const rel of retired) {
		assert.ok(
			LEGACY.drivers[driver].sourceFiles.includes(rel),
			'retirement must name an exact historical source'
		);
		assert.ok(
			!fs.existsSync(path.join(SP, rel)),
			`${driver}: retired production source must remain absent: ${rel}`
		);
	}
	const required = LEGACY.drivers[driver].sourceFiles.filter((rel) => !retired.includes(rel));
	assert.ok(
		traversed.size >= required.length,
		`${driver}: source coverage ${traversed.size}/${required.length} is incomplete`
	);
	for (const rel of required)
		assert.ok(
			traversed.has(rel),
			`${driver}: mandatory production source was not traversed: ${rel}`
		);
	SOURCE_COUNTS[driver] = traversed.size;
	return sites;
}

// The rules on the shapes they must tell apart.
{
	const lua = (text) => sitesOf('f.lua', text, '.lua').map((s) => s.split(' ')[1]);
	const ahk = (text) => sitesOf('windows/ui/menu/f.ahk', text, '.ahk').map((s) => s.split(' ')[1]);
	assert.deepEqual(lua('rows[#rows + 1] = { label = i18n.get("menu.x"), action = go }'), [
		'static'
	]);
	assert.deepEqual(lua('{ title = "✕ " .. i18n.get("menu.global.quit"), fn = quit }'), ['static']);
	assert.deepEqual(lua('sub[#sub + 1] = { label = i18n_safe("common.restore_recommended") }'), [
		'static'
	]);
	assert.deepEqual(lua('rows[#rows + 1] = { label = slot .. " : " .. name, action = pick }'), []);
	assert.deepEqual(lua('items[#items + 1] = { title = "-" }'), ['separator']);
	assert.deepEqual(lua('sub[#sub + 1] = { separator = true }'), ['separator']);
	assert.deepEqual(lua('table.insert(items, { title = name, fn = choose })'), ['native']);
	assert.deepEqual(lua('{ title = "⇧ Shift", mods = { "shift" } },'), []);
	assert.deepEqual(lua('local title = i18n.get("menu.x")'), []);
	assert.deepEqual(lua('-- { label = i18n.get("menu.x") }'), []);
	assert.deepEqual(ahk('RegisterMenuItem(M, Label, Fn)'), ['register']);
	assert.deepEqual(ahk('M.Add()'), ['add']);
	assert.deepEqual(ahk('M.Add(t("menu.x"), Sub)'), ['add']);
	assert.deepEqual(ahk('G.Add("Text", "w300", t("x"))'), []);
	assert.deepEqual(sitesOf('windows/ui/model_browser/init.ahk', 'lv.Add(, name)', '.ahk'), []);
	assert.deepEqual(ahk('Rows.Push(Map("label", t("menu.x"), "action", Fn))'), ['static']);
	assert.deepEqual(ahk('Rows.Push(Map("label", Name, "action", Fn))'), []);
	assert.deepEqual(ahk('Rows.Push(Map("separator", true))'), ['separator']);
	assert.deepEqual(ahk('MenuRenderer_AppendCommand(H, "llm_menu", Id, C)'), ['append']);
	assert.deepEqual(ahk('; RegisterMenuItem(M, Label, Fn)'), []);
}

// ==================================================
// ==================================================
// ======= 2/ The ratchet ===========================
// ==================================================
// ==================================================

const DRIVERS = ['windows', 'macos', 'linux'];
// A scan that stops matching would pass with nothing counted. Keep the original
// minimum against the immutable pre-migration oracle, not the migration debt.
const FLOORS = { windows: 20, macos: 20, linux: 20 };
const LEGACY_PATH = path.join(__dirname, 'fixtures', 'native-menu-census-legacy.json');
const LEGACY_SHA256 = '6ffcfa0a4da1c47fbbf299d62624e4a33933fe2908a17001b14e3592f9753aba';
const legacyBytes = fs.readFileSync(LEGACY_PATH);
assert.equal(
	crypto.createHash('sha256').update(legacyBytes).digest('hex'),
	LEGACY_SHA256,
	'the independent b06 legacy oracle must remain unchanged'
);
const LEGACY = JSON.parse(legacyBytes.toString('utf8'));

// Explicit current retirement keeps every historical excerpt and floor intact.
// Any other absent source, or resurrection of this removed provider, refuses.
const CURRENT_SOURCE_RETIREMENTS = Object.freeze({
	macos: Object.freeze(['macos/ui/menu/menu_llm/live_mode_panel.lua'])
});

const SOURCE_COUNTS = {};
const errors = [];
for (const driver of DRIVERS) {
	const observed = [];
	const ext = driver === 'windows' ? '.ahk' : '.lua';
	for (const excerpt of LEGACY.drivers[driver].excerpts) {
		const lines = Array(excerpt.lines.at(-1).line).fill('');
		for (const entry of excerpt.lines) lines[entry.line - 1] = entry.source;
		observed.push(...sitesOf(excerpt.path, lines.join('\n'), ext));
	}
	const count = observed.length;
	if (count < FLOORS[driver])
		errors.push(
			`${driver}: counted ${count} site(s), floor ${FLOORS[driver]} — the scan is broken.`
		);
	assert.deepEqual(
		observed,
		LEGACY.baseline[driver].sites,
		`${driver}: every recorded b06 legacy site must retain its original classification`
	);
}

const current = {};
for (const driver of DRIVERS) current[driver] = inventory(driver);

// Read and validate the debt ledger in both modes, before any write. Updating
// a malformed ledger or raising a count would silently bypass the ratchet.
const baseline = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
const summary = [];
for (const driver of DRIVERS) {
	const recorded = baseline[driver];
	const count = current[driver].length;
	if (!recorded || !Array.isArray(recorded.sites) || recorded.sites.length !== recorded.count) {
		errors.push(`${driver}: the baseline must record a count and one site per counted row.`);
		continue;
	}
	const sitePattern = new RegExp(
		`^${driver}/[^:]+:\\d+ (?:register|append|static|separator|add|native)$`
	);
	if (
		!Number.isSafeInteger(recorded.count) ||
		recorded.count < 0 ||
		recorded.count > LEGACY.baseline[driver].count ||
		new Set(recorded.sites).size !== recorded.sites.length ||
		!recorded.sites.every((site) => typeof site === 'string' && sitePattern.test(site))
	) {
		errors.push(
			`${driver}: the baseline must contain a valid non-increasing count and unique native sites.`
		);
		continue;
	}
	if (count > recorded.count) {
		const known = new Set(recorded.sites.map((site) => site.replace(/:\d+ /, ' ')));
		const added = current[driver].filter((site) => !known.has(site.replace(/:\d+ /, ' ')));
		errors.push(
			`${driver}: ${count} native menu row site(s), baseline ${recorded.count}. ` +
				'Declare the new rows in the shared manifest instead' +
				(added.length > 0 ? `; new in: ${added.slice(0, 12).join(', ')}` : '.')
		);
	}
	summary.push(`${driver} ${count}/${recorded.count}`);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] Menu rows must be declared in the shared manifest:\x1b[0m');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

if (UPDATE) {
	const out = {
		_comment:
			'Native menu rows still built in driver code (tools/test/test-native-menu-rows.cjs). ' +
			'Lower with --update-baseline as rows move to the shared manifest; never raise.'
	};
	for (const driver of DRIVERS)
		out[driver] = { count: current[driver].length, sites: current[driver] };
	fs.writeFileSync(BASELINE_PATH, JSON.stringify(out, null, '\t') + '\n');
	console.log(`test-native-menu-rows: baseline written to ${path.relative(ROOT, BASELINE_PATH)}`);
	process.exit(0);
}

const lowered = DRIVERS.filter((driver) => current[driver].length < baseline[driver].count);
console.log(
	`\x1b[32m[OK] native menu row sites within the baseline (${summary.join(', ')}).\x1b[0m` +
		(lowered.length > 0
			? ` ${lowered.join(', ')} dropped: lock it in with --update-baseline.`
			: '') +
		` Source coverage: ${DRIVERS.map((driver) => `${driver} ${SOURCE_COUNTS[driver]}`).join(', ')}.`
);
