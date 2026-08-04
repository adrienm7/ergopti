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
const SERVICE_UNIT = 'usr/lib/systemd/user/ergopti-hotstrings.service'; // systemd user unit path
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

// ─── 6. The remap config is a copy the daemon owns, never a link to the source ──
//
// ROOT CAUSE ENCODED: install.sh used to symlink ~/.config/kanata/ergopti.kbd at
// the tracked template, and platform/remap/manager.write_kbd() opens that exact
// path for writing on every daemon start. The first restart therefore followed
// the link and rewrote the template inside the install tree — so the file the
// parity gate reads was being overwritten by the generator the gate exists to
// check, and a machine that had ever run the daemon no longer had the config the
// repo believes it ships.
//
// Two writers, one path is the defect; the fix is that only the generator writes
// and the installer merely seeds. A regular file also means the unit below can be
// enabled before the daemon has ever run, which is the order install.sh uses.

const INSTALL_SH = 'static/ergopti_plus/linux/install.sh';
const installSrc = read(INSTALL_SH);
const KANATA_USER_CONFIG = '${KANATA_CONFIG_DIR}/ergopti.kbd';

for (const line of installSrc.split('\n')) {
	if (/^\s*ln\s+-s/.test(line) && line.includes('ergopti.kbd')) {
		errors.push(
			`${INSTALL_SH}: "${line.trim()}" links the generated remap config back at the ` +
			'tracked template; the daemon writes that path, so the link makes it overwrite its own source.'
		);
	}
}

if (!installSrc.includes(`install -m 0644 "${'${KANATA_SRC}'}" "${KANATA_USER_CONFIG}"`)) {
	errors.push(
		`${INSTALL_SH}: must seed ${KANATA_USER_CONFIG} with a copy of the template ` +
		'(install -m 0644), so the unit it enables has a loadable config before the daemon first runs.'
	);
}

// ─── 7. There is ONE unit, and every copy of it agrees ──────────────────────
//
// ROOT CAUSE ENCODED: six unit definitions lived in five files and disagreed on
// three things at once — the unit's NAME (ergopti.service vs
// ergopti-hotstrings.service), its ExecStart (/usr/bin vs ~/.local/bin) and its
// WantedBy (default.target vs graphical-session.target). A user who installed
// the .deb and then ran install.sh ended up with TWO enabled units, both
// grabbing the keyboard, and neither knew about the other.
//
// The three properties below are the ones that decide whether "log out of X11,
// log back in under Wayland, touch nothing" works:
//   - one name, so two installers cannot both enable a daemon;
//   - PartOf=graphical-session.target, so the daemon stops with the session it
//     probed rather than outliving it;
//   - no Environment=DISPLAY, because a pinned :0 is wrong on a second seat and
//     under Wayland, and silently right often enough that only the users who
//     switch ever see the bug.

const CANONICAL_UNIT_NAME = 'ergopti-hotstrings.service';

let unitBlocksSeen = 0;

for (const rel of UNIT_SOURCES) {
	const full = path.join(ROOT, rel);
	if (!fs.existsSync(full)) continue;
	const src = fs.readFileSync(full, 'utf8');

	// Any other .service filename is a second unit by definition.
	for (const m of src.matchAll(/([A-Za-z0-9_.-]+)\.service\b/g)) {
		const name = m[1] + '.service';
		if (name !== CANONICAL_UNIT_NAME && name !== 'kanata.service') {
			errors.push(
				`${rel}: names "${name}" — there is one unit, ${CANONICAL_UNIT_NAME}. ` +
				`A second name means two installers can each enable a daemon, and both grab the keyboard.`
			);
		}
	}

	// Every [Install] section must want the graphical session.
	for (const m of src.matchAll(/^WantedBy=(.+)$/gm)) {
		unitBlocksSeen++;
		if (m[1].trim() !== 'graphical-session.target') {
			errors.push(
				`${rel}: "WantedBy=${m[1].trim()}" — the daemon needs a session to read input from ` +
				`and a tray to draw into; default.target starts it on a TTY login too.`
			);
		}
	}

	// A DISPLAY pinned in a unit overrides the runtime probe.
	for (const line of src.split('\n')) {
		if (/^Environment=DISPLAY/.test(line.trim())) {
			errors.push(
				`${rel}: "${line.trim()}" — the daemon probes the display server at runtime ` +
				`(infra/display_server.lua). A pinned value is wrong on a second seat, wrong ` +
				`under Wayland, and breaks the X11-to-Wayland switch this unit exists to survive.`
			);
		}
	}
}

if (unitBlocksSeen === 0) {
	errors.push(
		'no [Install] section found in any packaging file — the selector is stale, not the tree. ' +
		'A scan that silently finds nothing is the failure mode this check exists to avoid.'
	);
}

// Every ergopti unit must stop with its session.
for (const rel of UNIT_SOURCES) {
	const full = path.join(ROOT, rel);
	if (!fs.existsSync(full)) continue;
	const src = fs.readFileSync(full, 'utf8');
	const daemonUnits = (src.match(/ExecStart=\S*(?:ergopti-hotstrings|\/ergopti)\b/g) || []).length;
	const partOf = (src.match(/^PartOf=graphical-session\.target$/gm) || []).length;
	if (daemonUnits > 0 && partOf < daemonUnits) {
		errors.push(
			`${rel}: ${daemonUnits} daemon unit(s) but ${partOf} PartOf=graphical-session.target — ` +
			`without it the daemon outlives the session it probed at startup.`
		);
	}
}

// ─── 8. The PKGBUILD ships a driver, not an empty package ───────────────────
//
// ROOT CAUSE ENCODED: the PKGBUILD's five copy lines read build/linux/*.lua,
// build/linux/modules, /adapters, /ui and /vendor — while the builder puts the
// driver under build/linux/LINUX/. Every one of those lines ended
// `2>/dev/null || true`, so makepkg SUCCEEDED and produced a package containing
// the shared Lua tree, a wrapper with no LUA_PATH, a .desktop file and a systemd
// unit, and no driver at all. Nothing caught it: the PACKAGERS list above covers
// only the two .sh packagers, and test-packaging-paths-exist.cjs filters
// tools/build to `.sh`, which a file named PKGBUILD is not.
//
// The two halves are independent and both fatal: a package with no driver, and
// a wrapper that cannot resolve `require("logger.shim")` because LUA_PATH was
// never set.

const PKGBUILD = 'tools/build/PKGBUILD';
const pkgbuildSrc = read(PKGBUILD);

// Silent-failure suffixes on a copy that stages the package payload.
for (const line of pkgbuildSrc.split('\n')) {
	const isCopy = /^\s*(cp|install)\s/.test(line);
	if (isCopy && /2>\/dev\/null\s*\|\|\s*true/.test(line)) {
		errors.push(
			`${PKGBUILD}: "${line.trim()}" — a staging copy that swallows its own failure ` +
			`makes makepkg succeed with an empty package. Let it fail.`
		);
	}
}

// The driver tree, from where the builder actually puts it.
if (!/cp -r build\/linux\/linux\/\.\s/.test(pkgbuildSrc)) {
	errors.push(
		`${PKGBUILD}: must copy the driver from build/linux/linux/ — the builder nests it ` +
		`one level deeper than build/linux/, and copying the wrong path ships no driver.`
	);
}

// The shared tree, whole. _shared/lua alone is not enough: the keycode tables,
// the hotstring packs, the locales and the resolver defaults live in
// _shared/data and _shared/modules, and the resolver fails fast without them.
if (!/cp -r build\/linux\/_shared\/\.\s/.test(pkgbuildSrc)) {
	errors.push(
		`${PKGBUILD}: must copy the whole _shared tree — _shared/lua alone omits the ` +
		`keycode tables, the hotstring packs, the locales and defaults.toml, and the ` +
		`daemon fails fast on the last of those.`
	);
}

// The wrapper needs LUA_PATH or the daemon dies on its first require.
if (!/export LUA_PATH=/.test(pkgbuildSrc)) {
	errors.push(
		`${PKGBUILD}: the wrapper must export LUA_PATH — without it the daemon cannot ` +
		`resolve a single require and exits before it logs anything useful.`
	);
}

// ─── 9. The release publishes something installable ────────────────────────
//
// ROOT CAUSE ENCODED: the Linux release uploaded install.sh, the wrapper, and
// ONE Lua file — ergopti_hotstrings.lua. Not the driver tree, not _shared. A
// user who downloaded the release got an installer, no driver, and no way to
// discover that until it failed. The asset list looked plausible because every
// path in it existed.
//
// The archive must carry the driver AND the shared tree, and must preserve
// their relative layout: the daemon resolves _shared as a SIBLING of the driver
// root, so an archive that flattens them installs a tree the daemon cannot
// navigate.

const WORKFLOW = '.github/workflows/ci.yml';
const workflowSrc = read(WORKFLOW);

// Tolerant of a shell line continuation: the archive command may be written on
// one line or split across two, and the members are what matter either way.
const tarLine = workflowSrc.match(/tar -czf[\s\S]{0,200}?-C build\/linux ([^\n]*)/);
if (!tarLine) {
	errors.push(
		`${WORKFLOW}: the Linux release must archive the driver bundle. Publishing ` +
		`individual files shipped an installer with no driver behind it.`
	);
} else {
	const members = tarLine[1].trim().split(/\s+/);
	for (const required of ['linux', '_shared', 'bin', 'install.sh']) {
		if (!members.includes(required)) {
			errors.push(
				`${WORKFLOW}: the release archive omits "${required}" — ` +
				`without it the downloaded release cannot install or cannot start.`
			);
		}
	}
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
