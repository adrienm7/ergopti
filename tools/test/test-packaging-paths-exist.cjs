// tools/test/test-packaging-paths-exist.cjs

/**
 * ==============================================================================
 * MODULE: Packaging Source-Path Guard
 * DESCRIPTION:
 * Every source path a packaging script copies must exist in the tree. The deb,
 * rpm, Linux bundle and macOS .app builders name paths as shell strings, and a
 * shell string is not checked by any compiler, linter or suite.
 *
 * ROOT CAUSE ENCODED:
 * The build scripts `cp` from `linux/lib/...` and install to `/usr/lib/ergopti`
 * and `~/.local/lib/ergopti` — a source path that must track a directory rename
 * sitting on lines next to install paths that must NOT. Most of these copies are
 * written `cp -r … 2>/dev/null || true`, so a path that stops existing produces
 * no error and no non-zero exit: the package simply ships without that
 * directory, and every unit suite stays green because none of them runs a build.
 *
 * This guard is the missing half of the `lib/` → `infra/` rename. Without it,
 * getting one replacement wrong ships a broken package with a fully green
 * repository — the exact failure this backlog exists to eliminate.
 *
 * WHAT IT DELIBERATELY DOES NOT CHECK:
 * Install destinations (`/usr/lib/ergopti`, `$HOME/.local/lib/ergopti`,
 * `/usr/lib/systemd/user`) are paths on the TARGET machine, not in this tree.
 * They are collected separately and asserted to be absent from the repo, which
 * is what makes them recognisable as destinations rather than sources.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const BUILD_DIR = path.join(ROOT, 'tools', 'build');

// Floors: five build scripts today, naming dozens of source paths between them.
const MIN_SCRIPTS = 4;
const MIN_PATHS = 40;

// A repo-relative source path: one of the four top-level trees, then a path.
const SOURCE_PATH = /(?:^|[\s"'/$}])((?:windows|macos|linux|_shared)\/[A-Za-z0-9_.@-]+(?:\/[A-Za-z0-9_.@-]+)*)/g;

// Install destinations on the target machine. These must NOT be looked up here,
// and must not accidentally become source paths.
const DESTINATION = /(?:\/usr\/lib|\$\{?HOME\}?\/\.local\/lib|\/usr\/share|\/etc\/|\$DEB_ROOT|\$INSTALL_ROOT)/;

// Paths built at runtime from a variable, or globs — not statically checkable.
const NOT_STATIC = /[*?$]|\{|\}/;

const errors = [];

if (!fs.existsSync(BUILD_DIR)) {
	console.error('\x1b[31m[ERROR] tools/build does not exist.\x1b[0m');
	process.exit(1);
}

const scripts = fs.readdirSync(BUILD_DIR).filter((f) => f.endsWith('.sh'));
if (scripts.length < MIN_SCRIPTS) {
	errors.push(`found only ${scripts.length} build script(s) (floor ${MIN_SCRIPTS}) — the scan is broken`);
}

let checked = 0;
const seen = new Set();

for (const name of scripts) {
	const abs = path.join(BUILD_DIR, name);
	const lines = fs.readFileSync(abs, 'utf8').split(/\r?\n/);

	lines.forEach((line, i) => {
		const t = line.trimStart();
		if (t.startsWith('#')) return; // Prose may cite an old path

		for (const m of line.matchAll(SOURCE_PATH)) {
			const rel = m[1];
			if (NOT_STATIC.test(rel)) continue;

			// A source path that is really part of an install destination — e.g.
			// the "linux" in "$DEB_ROOT/usr/lib/ergopti/linux" — is not ours to
			// resolve. Recognised by the destination markers on the same line.
			if (DESTINATION.test(line) && !/\bcp\b|\brsync\b|\binstall\b|"\$\{?BUILD_DIR\}?"/.test(line)) continue;

			const key = `${name}:${rel}`;
			if (seen.has(key)) continue;
			seen.add(key);
			checked++;

			if (!fs.existsSync(path.join(SP, rel))) {
				errors.push(
					`tools/build/${name}:${i + 1}: copies "${rel}", which does not exist under ` +
						'static/ergopti_plus/. Most of these copies are written "|| true", so the package ' +
						'ships without it and no suite notices — every test here runs against the source ' +
						'tree, not a build.'
				);
			}
		}
	});
}

if (checked < MIN_PATHS) {
	errors.push(
		`resolved only ${checked} source path(s) (floor ${MIN_PATHS}) — the extraction stopped matching, ` +
			'and this guard would then approve packaging it never inspected'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] packaging source paths:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${checked} source path(s) named by ${scripts.length} packaging script(s) exist.\x1b[0m`
);
