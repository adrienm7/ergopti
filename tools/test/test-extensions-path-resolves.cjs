// tools/test/test-extensions-path-resolves.cjs

/**
 * ==============================================================================
 * MODULE: Extension-Pack Path Resolution Gate
 * DESCRIPTION:
 * Every site that resolves the bundled extension-pack tree must land on a
 * directory that really contains a pack. This gate resolves each expression
 * against the working tree and asserts the target exists — it never settles for
 * "the string looks plausible".
 *
 * ROOT CAUSE ENCODED:
 * static/extensions/ ceased to exist when static/ was reorganised into
 * static/ergopti_plus/. Six consumers were not updated, and every one of them
 * failed silently:
 *   - the AHK `#Include *i` suppressed the missing-file error, so
 *     BuildExtMenu_ergopti_demo() was never defined;
 *   - three AHK read sites guarded with DirExist() and became no-ops;
 *   - two macOS sites guarded with hs.fs.attributes and became no-ops;
 *   - build_static_bundle.py warned-and-continued, so the shipped .exe carried
 *     zero extension packs while CI stayed green.
 * The extensions submenu therefore never rendered on Windows or macOS, and
 * nothing anywhere went red.
 *
 * FEATURES & RATIONALE:
 * 1. Resolution, not spelling: each path is computed and probed with existsSync,
 *    which is the only check that could have caught the original break.
 * 2. Anchor file: the probe looks for the bundled pack's manifest, so an empty
 *    directory cannot satisfy it.
 * 3. Single-resolver rule: the AHK driver must reach the tree through the one
 *    _ExtensionsDir global. Three independent derivations is what let the sites
 *    drift apart in the first place.
 * 4. Ratchet: the pre-reorg literal may not reappear anywhere in the driver or
 *    the build tooling.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const STATIC = path.join(ROOT, 'static');
const DRIVERS = path.join(STATIC, 'ergopti_plus');

// The anchor: a directory only counts as the extensions tree if it holds a pack.
const ANCHOR_REL = path.join('ergopti-demo', 'manifest.toml');

const errors = [];
const notes = [];

/** Reads a repo-relative file, or null when absent. */
function read(rel) {
	const full = path.join(ROOT, rel);
	return fs.existsSync(full) ? fs.readFileSync(full, 'utf8') : null;
}

/** Asserts that `dir` is the extensions tree (exists and contains the anchor). */
function assertIsExtensionsTree(label, dir) {
	if (!fs.existsSync(dir)) {
		errors.push(`${label}: resolves to "${dir}", which does not exist.`);
		return false;
	}
	if (!fs.existsSync(path.join(dir, ANCHOR_REL))) {
		errors.push(
			`${label}: resolves to "${dir}", which exists but does not contain ` +
			`${ANCHOR_REL} — an empty directory must not satisfy this check.`
		);
		return false;
	}
	notes.push(`${label} → ${path.relative(ROOT, dir).replace(/\\/g, '/')}`);
	return true;
}

// ─── 0. The tree itself ───────────────────────────────────────────────────────

const CANONICAL = path.join(DRIVERS, 'extensions');
assertIsExtensionsTree('canonical tree', CANONICAL);

// ─── 1. Windows: the single resolver ─────────────────────────────────────────

const entry = read('static/ergopti_plus/windows/ErgoptiPlus.ahk');
if (!entry) {
	errors.push('windows/ErgoptiPlus.ahk is unreadable.');
} else {
	// _StaticDir is <bundle>/static; the global must append ergopti_plus\extensions.
	const m = entry.match(/global\s+_ExtensionsDir\s*:=\s*_StaticDir\s*\.\s*"([^"]+)"/);
	if (!m) {
		errors.push(
			'windows/ErgoptiPlus.ahk: no `global _ExtensionsDir := _StaticDir . "…"` found. ' +
			'The AHK driver must resolve the extensions root exactly once.'
		);
	} else {
		const suffix = m[1].replace(/\\/g, path.sep).replace(/^[\\/]+/, '');
		assertIsExtensionsTree('windows _ExtensionsDir', path.join(STATIC, suffix));
	}

	// The bundled pack's shortcut menu is pulled in by a relative #Include, which
	// resolves against the including file's own directory.
	const inc = entry.match(/#Include\s+\*i\s+([^\r\n]+extensions[^\r\n]+)/);
	if (!inc) {
		errors.push('windows/ErgoptiPlus.ahk: no `#Include *i …extensions…` line found.');
	} else {
		const relInclude = inc[1].trim().replace(/\\/g, path.sep);
		const resolved = path.resolve(path.join(DRIVERS, 'windows'), relInclude);
		if (!fs.existsSync(resolved)) {
			errors.push(
				`windows/ErgoptiPlus.ahk: "#Include *i ${inc[1].trim()}" resolves to ` +
				`"${resolved}", which does not exist. *i suppresses the error, so this ` +
				'is silent at runtime — BuildExtMenu_* is simply never defined.'
			);
		} else {
			notes.push('windows extension #Include resolves');
		}
	}
}

// ─── 2. Windows: no second derivation ────────────────────────────────────────

const AHK_READ_SITES = [
	'static/ergopti_plus/windows/ui/menu/menu_shortcuts.ahk',
	'static/ergopti_plus/windows/ui/menu/menu_hotstrings.ahk',
	'static/ergopti_plus/windows/ui/hotstrings_config_window/hcw_helpers.ahk'
];

for (const rel of AHK_READ_SITES) {
	const src = read(rel);
	if (src === null) {
		errors.push(`${rel}: expected read site is missing — update the list or restore the file.`);
		continue;
	}
	if (!src.includes('_ExtensionsDir')) {
		errors.push(
			`${rel}: reads the extensions tree without going through _ExtensionsDir. ` +
			'One resolver only — three independent derivations is the original defect.'
		);
	}
}

// ─── 3. macOS: base_dir is the driver root, so exactly one ".." ──────────────

const MAC_SITES = [
	'static/ergopti_plus/macos/init.lua',
	'static/ergopti_plus/macos/ui/menu/hotstring_counter.lua',
	'static/ergopti_plus/macos/ui/menu/menu_shortcuts.lua'
];

const MAC_DRIVER_ROOT = path.join(DRIVERS, 'macos');
let macSitesSeen = 0;

for (const rel of MAC_SITES) {
	const src = read(rel);
	if (src === null) {
		errors.push(`${rel}: expected read site is missing — update the list or restore the file.`);
		continue;
	}
	// Capture every "…extensions…" relative expression appended to a base_dir.
	const matches = [...src.matchAll(/base_dir\s*\.\.\s*"([^"]*extensions[^"]*)"/g)];
	if (matches.length === 0) {
		errors.push(`${rel}: no base_dir-relative extensions path found — did the expression change shape?`);
		continue;
	}
	for (const m of matches) {
		macSitesSeen++;
		const resolved = path.resolve(MAC_DRIVER_ROOT, m[1]);
		assertIsExtensionsTree(`${path.basename(rel)} ("${m[1]}")`, resolved);
	}
}

if (macSitesSeen === 0) {
	errors.push('no macOS extensions expression was checked — the selector is stale, not the tree.');
}

// ─── 4. The Windows bundler ships the tree ───────────────────────────────────

const bundler = read('tools/build/build_static_bundle.py');
if (!bundler) {
	errors.push('tools/build/build_static_bundle.py is unreadable.');
} else {
	const m = bundler.match(/\(\s*"([^"]*extensions[^"]*)"\s*,/);
	if (!m) {
		errors.push('build_static_bundle.py: ASSET_TREES declares no extensions tree — the .exe would ship none.');
	} else {
		assertIsExtensionsTree('bundler ASSET_TREES entry', path.join(ROOT, m[1]));
	}

	// The bundler must not silently skip a declared tree: that is what kept CI green.
	if (/WARN: missing directory/.test(bundler)) {
		errors.push(
			'build_static_bundle.py still warns-and-continues on a missing ASSET_TREES ' +
			'directory. A declared tree is a runtime dependency of the compiled driver, ' +
			'so a missing one must fail the build.'
		);
	}
}

// ─── 5. Ratchet: the pre-reorg literal must not come back ────────────────────

const RATCHET_TREES = [
	'static/ergopti_plus/windows',
	'static/ergopti_plus/macos',
	'static/ergopti_plus/linux',
	'tools'
];
const RATCHET_EXTS = new Set(['.ahk', '.lua', '.py', '.js', '.cjs', '.mjs', '.sh']);
const SKIP_DIRS = new Set(['node_modules', 'vendor', '_generated', 'build', 'tests', '.git']);

/** Recursively collects source files under a repo-relative directory. */
function collect(relDir, out = []) {
	const full = path.join(ROOT, relDir);
	if (!fs.existsSync(full)) return out;
	for (const e of fs.readdirSync(full, { withFileTypes: true })) {
		if (e.isDirectory()) {
			if (SKIP_DIRS.has(e.name)) continue;
			collect(path.join(relDir, e.name), out);
		} else if (RATCHET_EXTS.has(path.extname(e.name))) {
			out.push(path.join(relDir, e.name));
		}
	}
	return out;
}

// Matches the dead prefix in either slash style, but not the live
// static/ergopti_plus/extensions.
const DEAD_RE = /static[\\/]extensions/;

// Comment markers per language. The ratchet must look at CODE only: this file
// and several drivers legitimately name the dead path in prose while explaining
// the bug, and a ratchet that counts comments is a documented foot-gun in this
// repo (the hs.* purity counter has exactly that defect).
const COMMENT_MARKERS = {
	'.ahk': [';'],
	'.lua': ['--'],
	'.py': ['#'],
	'.sh': ['#'],
	'.js': ['//'],
	'.cjs': ['//'],
	'.mjs': ['//']
};

/** Returns the code part of a line, with any trailing comment removed. */
function codeOnly(line, ext) {
	let out = line;
	for (const marker of COMMENT_MARKERS[ext] || []) {
		const at = out.indexOf(marker);
		if (at !== -1) out = out.slice(0, at);
	}
	return out;
}

// This gate names the dead path in its own docstring and error messages.
const SELF_REL = path.relative(ROOT, __filename);

let ratchetFilesScanned = 0;

for (const tree of RATCHET_TREES) {
	for (const rel of collect(tree)) {
		if (path.normalize(rel) === path.normalize(SELF_REL)) continue;
		ratchetFilesScanned++;
		const ext = path.extname(rel);
		const src = fs.readFileSync(path.join(ROOT, rel), 'utf8');
		for (const [i, line] of src.split('\n').entries()) {
			if (DEAD_RE.test(codeOnly(line, ext))) {
				errors.push(
					`${rel.replace(/\\/g, '/')}:${i + 1}: references the pre-reorg ` +
					'"static/extensions" path in CODE, which has not existed since the static/ reorg.'
				);
			}
		}
	}
}

if (ratchetFilesScanned === 0) {
	errors.push('the ratchet scanned zero files — the selector is wrong, not the tree.');
}

// ─── Report ──────────────────────────────────────────────────────────────────

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Extension-pack paths do not resolve:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}

for (const n of notes) console.log('  pass  ' + n);
console.log(
	`\x1b[32m[OK] Every extension-pack path resolves to a real pack ` +
	`(${notes.length} site(s); ratchet clean over ${ratchetFilesScanned} files).\x1b[0m`
);
