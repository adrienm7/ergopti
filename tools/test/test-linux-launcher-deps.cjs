// tools/test/test-linux-launcher-deps.cjs

/**
 * ==============================================================================
 * MODULE: Linux Launcher Startup Guard
 * DESCRIPTION:
 * `static/ergopti_plus/linux/bin/ergopti-hotstrings` is the only thing standing
 * between a user who has installed the driver and a running daemon. It shipped
 * two defects that made it a wall instead of a door, and neither could be caught
 * by any Lua or AutoHotkey suite — a shell launcher belongs to no driver's test
 * runner, so it is guarded here.
 *
 * ROOT CAUSE 1 — A HARD FAILURE OVER A DEPENDENCY THE PROJECT REMOVED.
 * The launcher collected missing commands and exited 1 with
 * "Erreur : dépendances manquantes". `ydotool` was on that list, while
 * install.sh deliberately does NOT install it (the daemon writes /dev/uinput
 * itself; ydotool assumed a US layout, needed a root daemon and forked once per
 * event). So the supported install path produced a machine the launcher refused
 * to start on, and the user was told to install a package the driver stopped
 * using. NEITHER LIST IS HARDCODED HERE: both are parsed out of the two scripts,
 * so the rule keeps holding when the dependencies change, and it fails the day
 * someone adds a hard requirement the installer does not satisfy.
 *
 * ROOT CAUSE 2 — AN EXPORTED PATH TO A DIRECTORY THAT DOES NOT EXIST.
 * The launcher exported LUA_PATH over `${ERGOPTI_ROOT}/shared/lua`. The tree is
 * `_shared`, with an underscore, everywhere else — install.sh, the package
 * builder, the repo. It went unnoticed for so long because the daemon rebuilds
 * package.path from its own location before requiring anything, so the broken
 * entry was never the one that resolved a module: the export was decoration that
 * looked load-bearing. Every shared-tree path the launcher composes is therefore
 * resolved here and checked to exist, rather than read.
 *
 * The parses are floored: a regex that stopped matching would find nothing and
 * pass over nothing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVER = path.join(ROOT, 'static', 'ergopti_plus', 'linux');
const LAUNCHER = path.join(DRIVER, 'bin', 'ergopti-hotstrings');
const INSTALLER = path.join(DRIVER, 'install.sh');

const errors = [];

/** Reads a tracked script, or records why the whole guard cannot run. */
function readScript(abs, label) {
	if (!fs.existsSync(abs)) {
		errors.push(`${label} is missing at ${path.relative(ROOT, abs).split(path.sep).join('/')} — it moved, and this guard no longer covers it`);
		return '';
	}
	return fs.readFileSync(abs, 'utf8');
}

/** Drops whole-line shell comments so prose about a tool never counts as a use. */
function withoutComments(src) {
	return src
		.split(/\r?\n/)
		.filter((line) => !/^\s*#/.test(line))
		.join('\n');
}

const launcherSrc = readScript(LAUNCHER, 'the Linux launcher');
const installerSrc = readScript(INSTALLER, 'the Linux installer');
const launcherCode = withoutComments(launcherSrc);
const installerCode = withoutComments(installerSrc);




// =========================================================
// =========================================================
// ======= 1/ No Hard Failure The Installer Ignores =======
// =========================================================
// =========================================================

// The launcher's hard-failure list: every command probed inside _check_deps,
// which is the function that ends in `exit 1`.
const checkDepsBody = (launcherCode.match(/_check_deps\(\)\s*\{([\s\S]*?)\n\}/) || [])[1] || '';
const launcherDeps = [...checkDepsBody.matchAll(/_has\s+([A-Za-z0-9_.-]+)/g)].map((m) => m[1]);

if (!/exit\s+1/.test(checkDepsBody)) {
	errors.push(
		'_check_deps() no longer exits 1 — either the function was renamed (this guard then measures an ' +
			'empty string) or a missing dependency stopped being fatal, in which case say so here.'
	);
}
if (launcherDeps.length < 2) {
	errors.push(
		`parsed ${launcherDeps.length} hard dependency(ies) out of the launcher — expected at least 2. ` +
			'The parser drifted, and a subset check over nothing passes forever.'
	);
}

// What install.sh actually provides: every command handed to _check_or_install,
// plus every _install_<name> helper that probes `command -v <name>` (that is how
// kanata is installed — by its own function, not by the generic helper).
const installed = new Set([...installerCode.matchAll(/_check_or_install\s+([A-Za-z0-9_.-]+)/g)].map((m) => m[1]));
for (const m of installerCode.matchAll(/_install_([A-Za-z0-9_]+)\(\)/g)) {
	if (new RegExp(`command -v ${m[1]}\\b`).test(installerCode)) installed.add(m[1]);
}

if (installed.size < 3) {
	errors.push(
		`parsed ${installed.size} installed command(s) out of install.sh — expected at least 3; the parser drifted`
	);
}

const unmet = launcherDeps.filter((dep) => !installed.has(dep));
if (unmet.length > 0) {
	errors.push(
		`the launcher refuses to start without ${unmet.map((d) => `'${d}'`).join(', ')}, and install.sh does ` +
			'not install ' + (unmet.length > 1 ? 'them' : 'it') + '. A user who followed the supported install ' +
			'path then gets "Erreur : dépendances manquantes" and is told to install something the driver may ' +
			'no longer use. Either install it in install.sh, or stop making it fatal in the launcher.\n' +
			`      launcher requires: ${launcherDeps.join(', ')}\n` +
			`      install.sh installs: ${[...installed].sort().join(', ')}`
	);
}




// =========================================================
// =========================================================
// ======= 2/ Every Exported Path Exists =======
// =========================================================
// =========================================================

// The launcher composes its paths from shell variables, so they are resolved the
// way the shell resolves them: in order, following the same assignments. Only the
// repo-checkout branch is verifiable here — the installed branch points at
// /usr/lib/ergopti, which exists on a user's machine and not in a clone — and it
// is the branch that wins, because it is assigned last.
const vars = new Map([['SCRIPT_DIR', path.dirname(LAUNCHER)]]);

for (const line of launcherCode.split(/\r?\n/)) {
	// NAME="$(cd "${OTHER}/rel" && pwd -P)" — a walk relative to a known directory.
	let m = line.match(/^\s*([A-Z_]+)="\$\(cd "\$\{([A-Z_]+)\}\/([^"]*)"\s*&&\s*pwd -P\)"/);
	if (m && vars.has(m[2])) {
		vars.set(m[1], path.resolve(vars.get(m[2]), m[3]));
		continue;
	}
	// NAME="${OTHER}" or NAME="${OTHER}/suffix" — a plain composition.
	m = line.match(/^\s*([A-Z_]+)="\$\{([A-Z_]+)\}([^"$]*)"/);
	if (m && vars.has(m[2])) {
		vars.set(m[1], path.join(vars.get(m[2]), m[3]));
	}
}

const exportLine = (launcherCode.match(/^\s*export LUA_PATH=.*$/m) || [])[0] || '';
if (exportLine === '') {
	errors.push('no `export LUA_PATH=` line found in the launcher — the daemon would inherit whatever LUA_PATH the session had');
}

const referenced = [...new Set([...exportLine.matchAll(/\$\{([A-Z_]+)\}/g)].map((m) => m[1]))];
if (referenced.length < 2) {
	errors.push(
		`the exported LUA_PATH references ${referenced.length} variable(s) — expected at least 2 (the driver ` +
			'tree and the shared tree). The parser drifted, and an existence check over nothing passes forever.'
	);
}

for (const name of referenced) {
	const resolved = vars.get(name);
	if (!resolved) {
		errors.push(`LUA_PATH is built from \${${name}}, which no assignment in the launcher defines — it expands to the empty string`);
		continue;
	}
	// An absolute install path cannot be checked from a clone; the checkout branch can.
	if (!resolved.startsWith(ROOT)) continue;
	if (!fs.existsSync(resolved)) {
		errors.push(
			`${name} resolves to ${path.relative(ROOT, resolved).split(path.sep).join('/')}, which does not ` +
				'exist. LUA_PATH would carry an entry that can never match, and the failure is invisible: the ' +
				'daemon rebuilds package.path from its own location, so a broken export looks harmless right up ' +
				'until something relies on it.'
		);
	}
}




// =========================================================
// =========================================================
// ======= 3/ Report =======
// =========================================================
// =========================================================

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the Linux launcher cannot start where install.sh leaves a machine:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] launcher hard-requires ${launcherDeps.length} command(s), all installed by install.sh; ` +
		`${referenced.length} exported LUA_PATH root(s) resolve to real directories.\x1b[0m`
);
