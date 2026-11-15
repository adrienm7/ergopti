// tools/test/test-layout-extension-payload.cjs

/**
 * ==============================================================================
 * MODULE: Layout Extension Payload Check
 * DESCRIPTION:
 * The macOS and Linux builds copy the keyboard-layout registry whole, and the
 * drivers refuse a layout extension whose manifest binds a hotstring file the
 * pack lacks, so a package without the Ergopti suffixes or magic-key
 * replacement file would boot with those sections gone (TODO 37). The Linux
 * required list also never named distancesreduction.toml. Both builds now run
 * tools/build/check_layout_extension_payload.py, which derives the bound files
 * from the source manifests. This test runs that checker on the real registry
 * and on packaged copies that lose, alter, alias or empty a bound file, and
 * proves both build scripts call it on the registry they package. The Windows
 * packaging runs it on the static bundle ZIP the exe embeds
 * (`<archive.zip>::<folder in it>`), proved the same way.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const CHECKER = path.join(ROOT, 'tools', 'build', 'check_layout_extension_payload.py');
const REGISTRY = path.join(ROOT, 'static', 'layouts', 'registry');
const PYTHON = pythonExecutable();

let failures = 0;
function check(name, fn) {
	try {
		fn();
		console.log(`  ok   ${name}`);
	} catch (error) {
		failures += 1;
		console.error(`  FAIL ${name}\n       ${error.message}`);
	}
}

/** Run the checker on a packaged copy of the real registry altered by `mutate`. */
function runPackaged(mutate) {
	const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-extension-payload-'));
	try {
		const packaged = path.join(fixture, 'registry');
		fs.cpSync(REGISTRY, packaged, { recursive: true });
		mutate(packaged);
		return spawnSync(PYTHON, ['-I', CHECKER, REGISTRY, packaged], { encoding: 'utf8' });
	} finally {
		fs.rmSync(fixture, { recursive: true, force: true });
	}
}

const hotstrings = (packaged, name) => path.join(packaged, 'ergopti', 'hotstrings', name);

check('the real registry passes and names the suffixes and magic-key replacement files', () => {
	const result = runPackaged(() => {});
	assert.equal(result.status, 0, result.stderr);
	assert.match(result.stdout, /ergopti\/hotstrings\/suffixes_a\.toml sha256=[0-9a-f]{64} /);
	assert.match(
		result.stdout,
		/ergopti\/hotstrings\/magickeyreplace\.toml sha256=[0-9a-f]{64} sections=replace/
	);
	// The file the Linux required list never named is bound and therefore required.
	assert.match(result.stdout, /ergopti\/hotstrings\/distancesreduction\.toml /);
	assert.match(result.stdout, /PASS bound=\d+/);
});

check('a package without the magic-key replacement file is refused', () => {
	const result = runPackaged((packaged) => fs.rmSync(hotstrings(packaged, 'magickeyreplace.toml')));
	assert.equal(result.status, 1);
	assert.match(result.stderr, /lacks the bound file ergopti\/hotstrings\/magickeyreplace\.toml/);
});

check('a package whose suffix file differs from its source is refused', () => {
	const result = runPackaged((packaged) =>
		fs.appendFileSync(hotstrings(packaged, 'suffixes_a.toml'), '\n# changed\n')
	);
	assert.equal(result.status, 1);
	assert.match(result.stderr, /suffixes_a\.toml differs from its source/);
});

check('a bound file shipped as a symlink is refused', () => {
	const result = runPackaged((packaged) => {
		const target = hotstrings(packaged, 'suffixes_a.toml');
		const moved = path.join(packaged, 'suffixes_a.toml');
		fs.renameSync(target, moved);
		fs.symlinkSync(moved, target);
	});
	assert.equal(result.status, 1);
	assert.match(result.stderr, /suffixes_a\.toml is not a regular file/);
});

check('a bound section the file does not declare is refused', () => {
	const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-extension-sections-'));
	try {
		for (const side of ['source', 'packaged']) {
			const dir = path.join(fixture, side, 'demo', 'hotstrings');
			fs.mkdirSync(dir, { recursive: true });
			fs.writeFileSync(
				path.join(fixture, side, 'demo', 'manifest.toml'),
				'[extension.hotstring_bindings.pack]\ncategory = "pack"\n' +
					'feature_section = "hotstrings.pack"\nsections = ["kept", "dropped"]\nsource = "common"\n'
			);
			fs.writeFileSync(path.join(dir, 'pack.toml'), '[_meta]\nsections_order = ["kept"]\n');
		}
		const result = spawnSync(
			PYTHON,
			['-I', CHECKER, path.join(fixture, 'source'), path.join(fixture, 'packaged')],
			{ encoding: 'utf8' }
		);
		assert.equal(result.status, 1);
		assert.match(result.stderr, /lacks sections \['dropped'\]/);
	} finally {
		fs.rmSync(fixture, { recursive: true, force: true });
	}
});

check('a source registry that binds no hotstring file is refused', () => {
	const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-extension-empty-'));
	try {
		fs.writeFileSync(path.join(fixture, 'index.json'), '{}');
		const result = spawnSync(PYTHON, ['-I', CHECKER, fixture, fixture], { encoding: 'utf8' });
		assert.equal(result.status, 1);
		assert.match(result.stderr, /binds no hotstring file/);
	} finally {
		fs.rmSync(fixture, { recursive: true, force: true });
	}
});

check('the macOS build verifies the registry it packages, right after copying it', () => {
	const script = fs.readFileSync(path.join(ROOT, 'tools', 'build', 'build_macos_app.sh'), 'utf8');
	const fn = /^verify_layout_extension_payload\(\) \{\n[\s\S]*?\n\}\n/m.exec(script);
	assert.ok(fn, 'build_macos_app.sh defines no verify_layout_extension_payload()');
	assert.match(fn[0], /check_layout_extension_payload\.py"/);
	assert.match(fn[0], /"\$static_root\/layouts\/registry"/);
	const assemble = /^assemble_app\(\) \{\n[\s\S]*?\n\}\n/m.exec(script);
	assert.ok(assemble, 'build_macos_app.sh defines no assemble_app()');
	assert.match(
		assemble[0],
		/^\tbundle_layout_registry "\$static_root"\n\tverify_layout_extension_payload "\$static_root"$/m
	);
});

check('the Linux build verifies its packaged registry before the missing-file verdict', () => {
	const script = fs.readFileSync(
		path.join(ROOT, 'tools', 'build', 'build-linux-driver.sh'),
		'utf8'
	);
	const call = script.indexOf('check_layout_extension_payload.py');
	const verdict = script.indexOf('if [ $MISSING -gt 0 ]; then');
	assert.ok(call > 0 && verdict > call, 'the check must run before the MISSING verdict');
	assert.ok(
		script.includes('"${BUILD_DIR}/linux/static/layouts/registry"'),
		'the check must read the packaged Linux registry'
	);
});

// The Windows static bundle is a ZIP: the registry is a folder inside it.
const ARCHIVE_FOLDER = 'static/layouts/registry';

/**
 * Run the checker on a ZIP holding a copy of the real registry under
 * ARCHIVE_FOLDER, as build_static_bundle.py writes it; `edit` names the
 * members to drop (`drop`) or to write as symlinks (`links`).
 */
function runArchive(edit) {
	const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-extension-archive-'));
	try {
		const archive = path.join(fixture, 'static_bundle.zip');
		const writer = [
			'import os, stat, sys, zipfile',
			'root, archive, folder, drop, links = sys.argv[1:6]',
			'drop, links = set(filter(None, drop.split(","))), set(filter(None, links.split(",")))',
			'with zipfile.ZipFile(archive, "w") as zf:',
			'    for base, _, files in os.walk(root):',
			'        for name in sorted(files):',
			'            full = os.path.join(base, name)',
			'            rel = os.path.relpath(full, root).replace(os.sep, "/")',
			'            if rel in drop: continue',
			'            arc = folder + "/" + rel',
			'            if rel in links:',
			'                info = zipfile.ZipInfo(arc)',
			'                info.external_attr = (stat.S_IFLNK | 0o777) << 16',
			'                zf.writestr(info, "elsewhere")',
			'            else:',
			'                zf.write(full, arc)'
		].join('\n');
		const made = spawnSync(
			PYTHON,
			[
				'-I',
				'-c',
				writer,
				REGISTRY,
				archive,
				ARCHIVE_FOLDER,
				(edit.drop || []).join(','),
				(edit.links || []).join(',')
			],
			{ encoding: 'utf8' }
		);
		assert.equal(made.status, 0, made.stderr);
		return spawnSync(PYTHON, ['-I', CHECKER, REGISTRY, `${archive}::${ARCHIVE_FOLDER}`], {
			encoding: 'utf8'
		});
	} finally {
		fs.rmSync(fixture, { recursive: true, force: true });
	}
}

check('the Windows bundle archive passes with every bound file inside it', () => {
	const result = runArchive({});
	assert.equal(result.status, 0, result.stderr);
	assert.match(
		result.stdout,
		/ergopti\/hotstrings\/magickeyreplace\.toml sha256=[0-9a-f]{64} sections=replace/
	);
	assert.match(result.stdout, /PASS bound=\d+/);
});

check('a Windows bundle archive without a bound file is refused', () => {
	const result = runArchive({ drop: ['ergopti/hotstrings/suffixes_a.toml'] });
	assert.equal(result.status, 1);
	assert.match(result.stderr, /lacks the bound file ergopti\/hotstrings\/suffixes_a\.toml/);
});

check('a bound file stored as a symlink in the Windows bundle archive is refused', () => {
	const result = runArchive({ links: ['ergopti/hotstrings/rolls.toml'] });
	assert.equal(result.status, 1);
	assert.match(result.stderr, /rolls\.toml is not a regular file/);
});

check(
	'the Windows packaging verifies the bundle archive the exe embeds, right after building it',
	() => {
		const workflow = fs.readFileSync(
			path.join(ROOT, '.github', 'workflows', 'ci-windows.yml'),
			'utf8'
		);
		const build = workflow.indexOf('run: python tools/build/build_static_bundle.py\n');
		const verify = workflow.indexOf(
			'run: python tools/build/check_layout_extension_payload.py static/layouts/registry ' +
				'"static/ergopti_plus/windows/build/static_bundle.zip::static/layouts/registry"'
		);
		assert.ok(build > 0, 'ci-windows.yml builds no static bundle');
		assert.ok(verify > build, 'the payload check must run on the built bundle archive');
		const between = workflow.slice(build, verify);
		assert.equal(
			(between.match(/\n {6}- name: /g) || []).length,
			1,
			'no step may run between them'
		);
	}
);

if (failures > 0) process.exit(1);
console.log('All layout extension payload checks passed.');
