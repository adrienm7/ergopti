// tools/test/test-dev-tool-paths.cjs

/**
 * ==============================================================================
 * MODULE: Dev-Tool Path Guard
 * DESCRIPTION:
 * Regression guard for the private-AHK workflow tools under tools/dev/ (the
 * sync/strip/watch scripts plus the pm2 install/uninstall-ahk-watcher.js pair). The
 * static/drivers -> static/ergopti_plus and scripts -> tools/dev reorg left
 * sync-private-ahk.js, watch-ahk.js and the watcher installers pointing at dead pre-reorg paths
 * (static/hotstrings/.local_ahk_path, static/drivers/autohotkey/ErgoptiPlus.ahk,
 * scripts/*.js, the removed update-ahk-date.js, and the removed Python hotstrings
 * generator). The whole private-sync pipeline was therefore broken: every run
 * either no-op'd on a missing override or crashed on a missing script.
 *
 * ROOT CAUSE ENCODED:
 * These dev tools must reference only LIVE post-reorg paths, must agree on a
 * single canonical .local_ahk_path location, and that location must be the one
 * .gitignore actually protects. This guard fails if any dead path signature
 * reappears or the override location drifts between the tools and .gitignore.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DEV = path.join(ROOT, 'tools', 'dev');

const SCRIPTS = [
	'sync-private-ahk.js',
	'remove_ahk_personal_configuration.js',
	'watch-ahk.js',
	'install-ahk-watcher.js',
	'uninstall-ahk-watcher.js'
];

// Canonical post-reorg override location, expressed both as a slash path (for
// .gitignore) and as a path.join segment sequence (for the JS sources).
const OVERRIDE_SLASH = 'static/ergopti_plus/windows/.local_ahk_path';

// Dead path signatures — matched in BOTH `path.join('a', 'b')` segment form and
// 'a/b' slash-literal form so a regression in either style is caught.
const DEAD = [
	{ label: "static/drivers", re: /['"]static['"]\s*,\s*['"]drivers['"]|static\/drivers/ },
	{ label: "static/hotstrings", re: /['"]static['"]\s*,\s*['"]hotstrings['"]|static\/hotstrings/ },
	{ label: "scripts/ dir for a tool script", re: /['"]scripts['"]\s*,\s*['"][\w.-]+\.js['"]|scripts\/[\w.-]+\.js/ },
	{ label: "removed 0_generate_hotstrings.py", re: /0_generate_hotstrings/ },
	{ label: "removed update-ahk-date.js", re: /update-ahk-date/ }
];

// path.join segment form of the canonical override: 'ergopti_plus', 'windows', '.local_ahk_path'.
const OVERRIDE_JOIN_RE = /['"]ergopti_plus['"]\s*,\s*['"]windows['"]\s*,\s*['"]\.local_ahk_path['"]/;
const PUBLIC_JOIN_RE = /['"]ergopti_plus['"]\s*,\s*['"]windows['"]\s*,\s*['"]ErgoptiPlus\.ahk['"]/;

const errors = [];

function read(rel) {
	return fs.readFileSync(path.join(DEV, rel), 'utf8');
}

// 1. No dead path signature in any of the three tools.
for (const s of SCRIPTS) {
	const src = read(s);
	for (const d of DEAD) {
		if (d.re.test(src)) {
			errors.push(`${s}: references dead path "${d.label}" — must use the post-reorg location.`);
		}
	}
}

// 2. The tools that read the override must agree on the canonical location.
for (const s of ['sync-private-ahk.js', 'watch-ahk.js', 'install-ahk-watcher.js']) {
	if (!OVERRIDE_JOIN_RE.test(read(s))) {
		errors.push(`${s}: must read .local_ahk_path from static/ergopti_plus/windows/.local_ahk_path.`);
	}
}

// 3. The sync tool must write the public file to its live location.
if (!PUBLIC_JOIN_RE.test(read('sync-private-ahk.js'))) {
	errors.push('sync-private-ahk.js: public file must be static/ergopti_plus/windows/ErgoptiPlus.ahk.');
}

// 4. .gitignore must actually protect that override location.
const gitignore = fs.readFileSync(path.join(ROOT, '.gitignore'), 'utf8');
if (!gitignore.split(/\r?\n/).some((l) => l.trim() === OVERRIDE_SLASH)) {
	errors.push(`.gitignore: must ignore "${OVERRIDE_SLASH}" so the private override pointer is never tracked.`);
}

// 5. NO tool anywhere under tools/ may hardcode one machine's checkout.
//
// This check used to be scoped to tools/dev/, and tools/build/ carried two:
// gen-process-prediction-corpus.lua resolved both its module path and its output
// path from "D:/Documents/GitHub/ergopti/…". The generator therefore could not
// run on any other machine or in CI — it would fail to require the shared parser,
// or write its corpus to a directory that does not exist. A path a contributor
// cannot use is a path that quietly makes a tool single-user.
const ABSOLUTE_HOME = [
	{ label: 'a Windows drive-letter checkout', re: /["'][A-Za-z]:[/\\](?:Users|Documents|Dev|Projects|src)[/\\]/i },
	{ label: 'a Unix home checkout', re: /["']\/(?:Users|home)\/[A-Za-z][\w.-]*\// },
];

/** Every tracked file under tools/, minus this guard itself. */
function toolFiles(dir, acc = []) {
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (e.name !== 'node_modules') toolFiles(p, acc);
		} else if (/\.(js|cjs|mjs|lua|py|sh|ps1)$/i.test(e.name)) {
			acc.push(p);
		}
	}
	return acc;
}

const SELF = path.join(ROOT, 'tools', 'test', 'test-dev-tool-paths.cjs');
for (const abs of toolFiles(path.join(ROOT, 'tools'))) {
	if (abs === SELF) continue;
	const text = fs.readFileSync(abs, 'utf8');
	const rel = path.relative(ROOT, abs).replace(/\\/g, '/');
	text.split(/\r?\n/).forEach((line, i) => {
		if (/^\s*(\/\/|#|--|;)/.test(line)) return;   // prose may cite a path
		for (const { label, re } of ABSOLUTE_HOME) {
			if (re.test(line)) {
				errors.push(`${rel}:${i + 1}: hardcodes ${label} — derive the repo root from the script's own location instead.`);
			}
		}
	});
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Dead or inconsistent dev-tool paths:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}
console.log('\x1b[32m[OK] Private-AHK dev tools reference only live post-reorg paths.\x1b[0m');
