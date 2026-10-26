// tools/test/test-linux-elf-needed-closure.cjs

/**
 * ==============================================================================
 * MODULE: Linux AppImage Needed-Library Closure
 * DESCRIPTION:
 * Pins tools/build/check-elf-needed-closure.cjs: every library a bundled ELF
 * file needs is in the image or on the documented recipient list, an unbundled
 * dependency fails, and the build and the install job both run the check.
 *
 * FEATURES & RATIONALE:
 * 1. Real ELF files: a gcc-built executable needing a shared library is checked
 *    with the real readelf, bundled (passes) and then removed from the tree
 *    (fails, naming the library). Without gcc that control is reported skipped.
 * 2. The recipient list is data with a reason per group; its glibc baseline is
 *    the ceiling the symbol-version check enforces, and musl is documented as
 *    unsupported.
 * 3. Fixtures allocate with os.tmpdir() and never assume TMPDIR.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const Closure = require('../build/check-elf-needed-closure.cjs');
const Ceiling = require('../build/check-elf-glibc-ceiling.cjs');

const read = (relative) => fs.readFileSync(path.join(ROOT, relative), 'utf8');
const data = JSON.parse(fs.readFileSync(Closure.RECIPIENT_LIBRARIES, 'utf8'));
const recipient = Closure.recipientLibraries(data);
let passed = 0;
let skipped = 0;

// 1. Parsing.
const DYNAMIC = [
	'Dynamic section at offset 0x2d98 contains 28 entries:',
	'  Tag        Type                         Name/Value',
	' 0x0000000000000001 (NEEDED)             Shared library: [libayatana-indicator3.so.7]',
	' 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]',
	' 0x000000000000000e (SONAME)             Library soname: [libayatana-appindicator3.so.1]',
	' 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN]'
].join('\n');
assert.deepEqual(Closure.parseDynamic(DYNAMIC), {
	needed: ['libayatana-indicator3.so.7', 'libc.so.6'],
	soname: 'libayatana-appindicator3.so.1'
});
passed++;

// 2. The recipient list.
assert.equal(
	data.baseline.glibc,
	Ceiling.GLIBC_CEILING,
	'the documented baseline is the enforced ceiling'
);
assert.equal(data.baseline.reference_image, Ceiling.OLDEST_LTS_IMAGE);
assert.match(data.baseline.musl, /unsupported/);
assert.match(data.baseline.musl, /startup\.linux_appimage_musl_body/);
assert.ok(recipient.has('libc.so.6') && recipient.has('ld-linux-x86-64.so.2'));
assert.ok(recipient.has('libgtk-3.so.0') && recipient.has('libstdc++.so.6'));
assert.ok(!recipient.has('libcurl.so.4'), "curl is bundled, never the recipient's");
assert.ok(!recipient.has('libselinux.so.1'));
assert.throws(
	() =>
		Closure.recipientLibraries({ version: 1, groups: [{ id: 'x', reason: 'short', sonames: [] }] }),
	/reason/
);
assert.throws(
	() =>
		Closure.recipientLibraries({
			version: 1,
			groups: [{ id: 'x', reason: 'r'.repeat(50), sonames: ['liba.so.1', 'liba.so.1'] }]
		}),
	/twice/
);
passed++;

// 3. The check over a tree, with injected readelf output.
function tree(files) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-needed-'));
	for (const [name, content] of Object.entries(files)) {
		fs.mkdirSync(path.dirname(path.join(root, name)), { recursive: true });
		fs.writeFileSync(path.join(root, name), content);
	}
	return root;
}
const ELF = Buffer.from([0x7f, 0x45, 0x4c, 0x46, 0, 0, 0, 0]);
const dynamics = {
	'usr/bin/luajit':
		' (NEEDED) Shared library: [libc.so.6]\n (NEEDED) Shared library: [libluv.so.1]',
	'usr/lib/libluv.so.1.0':
		' (SONAME) Library soname: [libluv.so.1]\n (NEEDED) Shared library: [libc.so.6]'
};
const good = tree({
	'usr/bin/luajit': ELF,
	'usr/lib/libluv.so.1.0': ELF,
	'usr/lib/ergopti/x.lua': 'x'
});
const injected = (file) => dynamics[path.relative(good, file).split(path.sep).join('/')];
let result = Closure.checkClosure([good], injected, recipient);
assert.equal(result.checked.length, 2);
assert.deepEqual(result.violations, [], 'a soname provided by a bundled file resolves');
dynamics['usr/bin/luajit'] += '\n (NEEDED) Shared library: [libselinux.so.1]';
result = Closure.checkClosure([good], injected, recipient);
assert.deepEqual(
	result.violations.map((v) => [path.basename(v.path), v.needed]),
	[['luajit', 'libselinux.so.1']],
	'an unbundled dependency that is not on the recipient list fails'
);
assert.equal(Closure.checkClosure([tree({ 'a.txt': 'x' })], injected, recipient).checked.length, 0);
passed++;

// 4. Real ELF files and the real readelf.
const gcc = spawnSync('gcc', ['--version'], { encoding: 'utf8' });
const readelf = spawnSync('readelf', ['--version'], { encoding: 'utf8' });
if (gcc.status === 0 && readelf.status === 0) {
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-needed-real-'));
	const source = (name, text) => fs.writeFileSync(path.join(work, name), text);
	source('lib.c', 'int ergopti_answer(void) { return 42; }\n');
	source(
		'main.c',
		'int ergopti_answer(void);\nint main(void) { return ergopti_answer() == 42 ? 0 : 1; }\n'
	);
	execFileSync('gcc', [
		'-shared',
		'-fPIC',
		'-Wl,-soname,libergoptifixture.so.7',
		'-o',
		path.join(work, 'libergoptifixture.so.7'),
		path.join(work, 'lib.c')
	]);
	execFileSync('gcc', [
		'-o',
		path.join(work, 'main'),
		path.join(work, 'main.c'),
		'-L' + work,
		'-l:libergoptifixture.so.7'
	]);
	const image = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-needed-image-'));
	fs.mkdirSync(path.join(image, 'usr/bin'), { recursive: true });
	fs.mkdirSync(path.join(image, 'usr/lib'), { recursive: true });
	fs.copyFileSync(path.join(work, 'main'), path.join(image, 'usr/bin/main'));
	fs.copyFileSync(
		path.join(work, 'libergoptifixture.so.7'),
		path.join(image, 'usr/lib/libergoptifixture.so.7')
	);
	const readDynamic = (file) =>
		execFileSync('readelf', ['--dynamic', '--wide', file], {
			encoding: 'utf8',
			env: { ...process.env, LC_ALL: 'C' }
		});
	let real = Closure.checkClosure([image], readDynamic, recipient);
	assert.deepEqual(real.violations, [], 'a bundled library resolves in a real executable');
	fs.rmSync(path.join(image, 'usr/lib/libergoptifixture.so.7'));
	real = Closure.checkClosure([image], readDynamic, recipient);
	assert.deepEqual(
		real.violations.map((v) => v.needed),
		['libergoptifixture.so.7'],
		'the same executable fails once its library is left out of the image'
	);
	const cli = spawnSync(
		process.execPath,
		[path.join(ROOT, 'tools/build/check-elf-needed-closure.cjs'), image],
		{ encoding: 'utf8' }
	);
	assert.equal(cli.status, 1);
	assert.match(cli.stderr, /libergoptifixture\.so\.7/);
	passed++;
} else {
	skipped++;
	console.log('[SKIP] real ELF control: gcc or readelf is not installed here.');
}

// 5. Wiring: the build and the install job run the check.
const builder = read('tools/build/build-linux-appimage.sh');
assert.match(builder, /\nnode "\$SCRIPT_DIR\/check-elf-needed-closure\.cjs" "\$APPDIR"\n/);
assert.ok(
	builder.indexOf('check-elf-glibc-ceiling.cjs" "$APPDIR"') <
		builder.indexOf('check-elf-needed-closure.cjs" "$APPDIR"'),
	'the closure check follows the symbol-version check'
);
const workflow = read('.github/workflows/ci-linux.yml');
assert.ok(
	workflow.includes('node tools/build/check-elf-needed-closure.cjs squashfs-root pkg'),
	'the install job checks the extracted image and the packages'
);
assert.ok(
	workflow.includes('bash tools/build/appimage-distro-sweep.sh "$(find pkg -name'),
	'the install job launches the image on the distribution matrix, Alpine refusal included'
);
assert.match(read('tools/build/appimage-distro-sweep.sh'), /alpine:latest/);
const readme = read('static/ergopti_plus/linux/README.md');
assert.match(
	readme,
	/linux_appimage_recipient_libraries\.json/,
	'the README names the recipient list'
);
passed++;

console.log(`[OK] AppImage needed-library closure: ${passed} group(s) passed, ${skipped} skipped.`);
