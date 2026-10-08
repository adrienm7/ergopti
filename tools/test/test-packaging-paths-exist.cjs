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
 * The build scripts `cp` from `linux/infra/...` and install to `/usr/lib/ergopti`
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
const assert = require('node:assert/strict');
const {
	generatedNativeRecipe,
	classifyGeneratedNativeArtifacts,
	isGeneratedLinuxAsset,
	DEFAULT_OUTPUT,
	OUTPUT,
	DRIVER,
	BUILDER
} = require('./generated-linux-native-artifacts.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const LAYOUT_ROOT = path.join(ROOT, 'static', 'ergopti');
const BUILD_DIR = path.join(ROOT, 'tools', 'build');

// Floors: five build scripts today, naming dozens of source paths between them.
const MIN_SCRIPTS = 4;
const MIN_PATHS = 40;

// A repo-relative source path: one of the four top-level trees, then a path.
const SOURCE_PATH =
	/(?:^|[\s"'/$}])((?:windows|macos|linux|_shared)\/[A-Za-z0-9_.@-]+(?:\/[A-Za-z0-9_.@-]+)*)/g;

// Install destinations on the target machine. These must NOT be looked up here,
// and must not accidentally become source paths.
const DESTINATION =
	/(?:\/usr\/lib|\$\{?HOME\}?\/\.local\/lib|\/usr\/share|\/etc\/|\$DEB_ROOT|\$INSTALL_ROOT)/;

// Paths built at runtime from a variable, or globs — not statically checkable.
const NOT_STATIC = /[*?$]|\{|\}/;

// Package folders the Linux build fills from the keyboard-layout tree rather
// than from the driver tree: the .keylayout converter and the user XKB
// installer land in the driver as linux/xkb_generation/ and
// linux/xkb_installation/ (tools/test/test-linux-ships-keylayout-converter.cjs).
// A path under one of them must exist at its layout-tree source instead.
const FROM_LAYOUT_TREE = ['linux/xkb_generation', 'linux/xkb_installation'];

// The layout registry ships below the driver at its repository path
// (linux/static/layouts/registry): a path there exists at static/... of the
// repository.
const FROM_REPOSITORY_STATIC = 'linux/static/';

const errors = [];

// Generated native files are admitted separately from tracked copied assets.
// Every negative modifies one real recipe input and must fail source admission.
const generated = generatedNativeRecipe(ROOT);
assert.ok(
	generated.artifacts.has(OUTPUT),
	'the current bundle must admit its complete native recipe'
);
assert.equal(
	isGeneratedLinuxAsset(
		'ergopti_plus/linux/bin/libergopti_archive_publication.so',
		generated.artifacts
	),
	true,
	'actual resolved Linux asset matches its bundle-relative generated key'
);
for (const target of [
	'ergopti_plus/macos/bin/libergopti_archive_publication.so',
	'ergopti_plus/linux/bin/foreign.so',
	'ergopti_plus/linux/cache/libergopti_archive_publication.so'
])
	assert.equal(
		isGeneratedLinuxAsset(target, generated.artifacts),
		false,
		'foreign or user-data path cannot borrow generated asset admission'
	);

for (const [file, before, after] of [
	[DRIVER, 'bash "${SCRIPT_DIR}/build-linux-native-output.sh"', 'true'],
	[DRIVER, '"' + OUTPUT + '"', '"linux/bin/missing-native.so"'],
	[DRIVER, 'if [ ! -f "${BUILD_DIR}/${f}" ]; then', 'if false; then'],
	[BUILDER, DEFAULT_OUTPUT, 'OUTPUT_DIR="${REPO_ROOT}/build/linux/bin"'],
	[BUILDER, 'archive_publication.c"', 'missing_source.c"'],
	[BUILDER, 'ln -T --', 'cp --'],
	[BUILDER, '-Wl,-soname,libergopti_archive_publication.so', '-Wl,-soname,foreign.so']
]) {
	assert.ok(
		generated.sources[file].includes(before),
		'mutation must hit an actual native recipe input'
	);
	const sources = { ...generated.sources, [file]: generated.sources[file].replace(before, after) };
	assert.throws(() => classifyGeneratedNativeArtifacts(sources), /source recipe refused/);
}
for (const input of [
	'static/ergopti_plus/linux/native/archive_output/archive_publication.c',
	'static/ergopti_plus/linux/native/archive_output/archive_publication.h'
]) {
	const sources = { ...generated.sources, [input]: null };
	assert.throws(() => classifyGeneratedNativeArtifacts(sources), /source recipe refused/);
}
// A presence-only final check could approve a bundle that exits successfully
// despite missing required bytes. Remove only its actual captured fatal exit.
const fatalNative = /if \[ \$MISSING -gt 0 \]; then\n([\s\S]*?)\nfi/.exec(
	generated.sources[DRIVER]
);
assert.ok(
	fatalNative && fatalNative[1].includes('\n\texit 1'),
	'mutation binds the actual mandatory fatal branch'
);
const nonfatal = generated.sources[DRIVER].replace(
	fatalNative[0],
	fatalNative[0].replace('\n\texit 1', '\n\ttrue')
);
assert.notEqual(
	nonfatal,
	generated.sources[DRIVER],
	'fatal-exit removal must alter its real branch'
);
assert.throws(
	() => classifyGeneratedNativeArtifacts({ ...generated.sources, [DRIVER]: nonfatal }),
	/source recipe refused/
);
const requiredNative = /REQUIRED_FILES=\(([\s\S]*?)\n\)/.exec(generated.sources[DRIVER]);
assert.ok(requiredNative, 'mandatory native output must be inside the bundle requirement array');

if (!fs.existsSync(BUILD_DIR)) {
	console.error('\x1b[31m[ERROR] tools/build does not exist.\x1b[0m');
	process.exit(1);
}

const scripts = fs.readdirSync(BUILD_DIR).filter((f) => f.endsWith('.sh'));
if (scripts.length < MIN_SCRIPTS) {
	errors.push(
		`found only ${scripts.length} build script(s) (floor ${MIN_SCRIPTS}) — the scan is broken`
	);
}

let checked = 0;
let generatedChecked = 0;
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
			if (DESTINATION.test(line) && !/\bcp\b|\brsync\b|\binstall\b|"\$\{?BUILD_DIR\}?"/.test(line))
				continue;

			// Generated requirements never enter source deduplication: a later copy
			// from the same absent binary must still reach the original source check.
			// The default is a build destination: bundle build/linux plus linux/bin.
			// Only this complete, independently admitted builder assignment qualifies.
			if (name === path.basename(BUILDER) && line.trim() === DEFAULT_OUTPUT) {
				generatedChecked++;
				continue;
			}
			// Required generated bytes are not source-copy inputs. An arbitrary copy
			// from a missing .so still fails; only the mandatory array entry qualifies.
			if (
				name === path.basename(DRIVER) &&
				rel === OUTPUT &&
				generated.artifacts.has(rel) &&
				line.trim() === '"' + OUTPUT + '"' &&
				i >= generated.sources[DRIVER].slice(0, requiredNative.index).split('\n').length - 1 &&
				i <=
					generated.sources[DRIVER].slice(0, requiredNative.index + requiredNative[0].length).split(
						'\n'
					).length -
						1
			) {
				generatedChecked++;
				continue;
			}
			const key = `${name}:${rel}`;
			if (seen.has(key)) continue;
			seen.add(key);
			checked++;

			// The keyboard layout tree (static/ergopti/) sits beside the driver tree
			// and shares its top-level names, so a path under it resolves there.
			const start = m.index + m[0].length - rel.length;
			const layoutTree =
				/(?:^|[^A-Za-z0-9_])ergopti\/$/.test(line.slice(0, start)) ||
				FROM_LAYOUT_TREE.some((folder) => rel === folder || rel.startsWith(folder + '/'));
			const repositoryStatic = rel.startsWith(FROM_REPOSITORY_STATIC);
			const base = repositoryStatic ? ROOT : layoutTree ? LAYOUT_ROOT : SP;
			const source = repositoryStatic ? rel.slice('linux/'.length) : rel;
			if (!fs.existsSync(path.join(base, source))) {
				errors.push(
					`tools/build/${name}:${i + 1}: copies "${rel}", which does not exist under ` +
						`${path.relative(ROOT, base).split(path.sep).join('/')}/. Most of these copies are written "|| true", so the package ` +
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
	`\x1b[32m[OK] ${checked} source path(s) exist and ${generatedChecked} native output reference(s) have admitted generation recipes in ${scripts.length} packaging script(s).\x1b[0m`
);
