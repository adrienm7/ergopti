// tools/test/test-linux-package-layout.cjs

/**
 * ==============================================================================
 * MODULE: Linux Package-Layout Guard
 * DESCRIPTION:
 * Regression guard for the Linux system-package (.deb/.rpm) runtime layout. Both
 * packagers install the driver into a single runtime root and generate a
 * /usr/bin launcher that boots the daemon from that same root (via the exec'd
 * entry script plus a LUA_PATH rooted at the shared tree). If the install
 * directory and the launcher's boot path ever diverge — one bumped without the
 * other — the installed package silently fails to start, exactly the class of
 * drift the macOS bundle-layout guard catches for the .app.
 *
 * ROOT CAUSE ENCODED:
 * The runtime root, the exec'd bundle entry, and the LUA_PATH shared root must
 * agree across build-linux-deb.sh and build-linux-rpm.sh: the driver installs at
 * /usr/lib/ergopti, the wrapper execs /usr/lib/ergopti/ergopti_hotstrings.lua and
 * puts /usr/lib/ergopti/_shared/lua on LUA_PATH, the launcher lands at
 * /usr/bin/ergopti, and the systemd unit's ExecStart points at that launcher.
 * This guard fails if either packager moves the install root without updating the
 * wrapper, re-introduces a legacy static/drivers prefix, or the two packagers
 * stop agreeing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');

// Canonical runtime layout every Linux packager must agree on.
const RUNTIME_ROOT = '/usr/lib/ergopti'; // driver root inside the package
const BUNDLE_ENTRY = '/usr/lib/ergopti/ergopti_hotstrings.lua'; // what the wrapper execs
const SHARED_LUA_EXPR = '$DRIVER_ROOT/_shared/lua'; // LUA_PATH shared root, relative to the driver root
const WRAPPER_BIN = 'usr/bin/ergopti'; // generated launcher path (repo-relative to the package DESTDIR)
const SERVICE_UNIT = 'usr/lib/systemd/user/ergopti.service'; // systemd user unit path
const SERVICE_EXEC = 'ExecStart=/usr/bin/ergopti'; // the unit must boot via the wrapper

// Pre-reorg prefix that must never reappear in a packager (mirror of the macOS guard).
const LEGACY_PREFIXES = ['static/drivers'];

// The two packagers that produce an installable artifact and stage the layout.
const PACKAGERS = [
	{ label: '.deb', rel: 'tools/build/build-linux-deb.sh' },
	{ label: '.rpm', rel: 'tools/build/build-linux-rpm.sh' }
];

const errors = [];

for (const pkg of PACKAGERS) {
	const src = read(pkg.rel);
	const tag = `${pkg.rel} (${pkg.label})`;

	// 1. The driver tree installs into the canonical runtime root.
	if (!src.includes(RUNTIME_ROOT)) {
		errors.push(`${tag}: must install the driver into ${RUNTIME_ROOT}.`);
	}

	// 2. The wrapper's DRIVER_ROOT is that same runtime root...
	if (!src.includes(`DRIVER_ROOT="${RUNTIME_ROOT}"`)) {
		errors.push(`${tag}: wrapper must set DRIVER_ROOT="${RUNTIME_ROOT}".`);
	}
	// ...it execs the bundle entry from under that root (install dir == boot dir)...
	if (!src.includes(`exec luajit ${BUNDLE_ENTRY}`)) {
		errors.push(`${tag}: wrapper must exec ${BUNDLE_ENTRY} (bundle entry under the driver root).`);
	}
	// ...and it roots the shared Lua tree on LUA_PATH relative to that root.
	if (!src.includes(`SHARED_LUA="${SHARED_LUA_EXPR}"`)) {
		errors.push(`${tag}: wrapper must set SHARED_LUA="${SHARED_LUA_EXPR}" for LUA_PATH resolution.`);
	}

	// 3. The launcher and the systemd unit land at the canonical paths and agree.
	if (!src.includes(WRAPPER_BIN)) {
		errors.push(`${tag}: must generate the launcher at /${WRAPPER_BIN}.`);
	}
	if (!src.includes(SERVICE_UNIT)) {
		errors.push(`${tag}: must install the systemd user unit at /${SERVICE_UNIT}.`);
	}
	if (!src.includes(SERVICE_EXEC)) {
		errors.push(`${tag}: systemd unit must boot via ${SERVICE_EXEC}.`);
	}

	// 4. No legacy pre-reorg prefix may reappear.
	for (const legacy of LEGACY_PREFIXES) {
		if (src.includes(legacy)) {
			errors.push(`${tag}: still references the legacy '${legacy}' prefix — must be ${RUNTIME_ROOT}.`);
		}
	}
}

// ─── 5. Every packaged unit must launch the daemon with a user-facing surface ──
//
// ROOT CAUSE ENCODED: opts.tray defaults to false and the whole tray/menu block
// is gated on `if opts.tray and tray_menu`, so a unit that omits --tray yields a
// driver with no icon and no menu. All five ExecStart lines that launch the
// daemon omitted it, which means the supported install path had no user-facing
// surface at all. Enumerated as a class over every packaging file, so a new unit
// definition is covered the moment it is added.

// Files that may declare a systemd unit for this project.
const UNIT_SOURCES = [
	'static/ergopti_plus/linux/ergopti-hotstrings.service',
	'static/ergopti_plus/linux/install.sh',
	'tools/build/build-linux-deb.sh',
	'tools/build/build-linux-rpm.sh',
	'tools/build/PKGBUILD'
];

// An ExecStart launches the ergopti daemon when it points at the daemon launcher
// or the wrapper. The kanata unit is a different binary and must NOT carry --tray.
const DAEMON_EXEC_RE = /^ExecStart=(?<cmd>\S*(?:ergopti-hotstrings|\/ergopti))(?<args>.*)$/gm;

let daemonExecStartsFound = 0;

for (const rel of UNIT_SOURCES) {
	const full = path.join(ROOT, rel);
	if (!fs.existsSync(full)) {
		errors.push(`${rel}: expected packaging file is missing — update UNIT_SOURCES or restore the file.`);
		continue;
	}
	const src = fs.readFileSync(full, 'utf8');

	for (const m of src.matchAll(DAEMON_EXEC_RE)) {
		daemonExecStartsFound++;
		if (!/\s--tray(\s|$)/.test(m.groups.args)) {
			errors.push(
				`${rel}: "${m[0].trim()}" launches the daemon without --tray, so the ` +
				`installed service has no tray icon and no menu.`
			);
		}
	}

	// The kanata unit shares these files; it must never gain the daemon's flag.
	for (const line of src.split('\n')) {
		if (/^ExecStart=/.test(line) && /kanata/.test(line) && /--tray/.test(line)) {
			errors.push(`${rel}: "${line.trim()}" — --tray belongs to the ergopti daemon, not kanata.`);
		}
	}
}

if (daemonExecStartsFound === 0) {
	errors.push(
		'no daemon ExecStart line matched in any packaging file — the selector is stale, ' +
		'not the tree. A scan that silently finds nothing is the failure mode this check exists to avoid.'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Linux package layout diverges from the canonical runtime layout:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}
console.log(
	'\x1b[32m[OK] Linux .deb/.rpm install into /usr/lib/ergopti, boot the same bundle entry, ' +
	`and all ${daemonExecStartsFound} daemon ExecStart line(s) pass --tray.\x1b[0m`
);
