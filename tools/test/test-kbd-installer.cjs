// tools/test/test-kbd-installer.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Layout Installer Test
 * DESCRIPTION:
 * Builds the NSIS installer of the bépo layout from its four DLL images and
 * proves, without running it, that it carries exactly those images (extracted
 * back with 7-Zip and read with the independent DLL reader) and that its
 * script registers and unregisters the layout as Windows' own layouts are:
 * the KLID key and its four values, a free Layout Id, the input profile added
 * and removed, the current user's Preload and Substitutes entries cleaned.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { fromKlc } = require('../lib/kbd-dll/klc.cjs');
const { buildDlls } = require('../lib/kbd-dll/build.cjs');
const { readDll } = require('../lib/kbd-dll/reader.cjs');
const { compareLayout } = require('../lib/kbd-dll/compare.cjs');
const Installer = require('../lib/kbd-dll/installer.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const sha = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');

assert.ok(Installer.makensisAvailable(), 'makensis is required (tools/ci/ubuntu_apt.py nsis)');
const model = fromKlc(
	fs.readFileSync(path.join(ROOT, 'tools', 'test', 'fixtures', 'kbd-dll', 'bepo.klc'))
);
const { dlls } = buildDlls(model);
const built = Installer.buildInstaller(model, dlls);
assert.equal(built.file, 'bepo-setup.exe');

// The script registers what Windows reads and removes all of it again.
const script = built.script;
for (const needle of [
	'RequestExecutionLevel admin',
	`"${Installer.LAYOUTS_KEY}\\$KLID" "Layout File" "bepo.dll"`,
	'"Layout Text" "Bépo"',
	'WriteRegExpandStr HKLM',
	'"Layout Display Name" "@%SystemRoot%\\system32\\bepo.dll,-1000"',
	'"Layout Id" "$LAYOUTID"',
	`StrCpy $KLID "a0$1${model.lcid}"`,
	`input::InstallLayoutOrTip(w "040C:$KLID", i 0)`,
	`input::InstallLayoutOrTip(w "040C:$KLID", i 1)`,
	`DeleteRegKey HKLM "${Installer.LAYOUTS_KEY}\\$KLID"`,
	'!insertmacro DropValues "Keyboard Layout\\Preload"',
	'EnumRegValue $1 HKCU "Keyboard Layout\\Substitutes" $0',
	'Delete /REBOOTOK "$WINDIR\\SysWOW64\\bepo.dll"',
	'${IsNativeARM64}',
	'${DisableX64FSRedirection}'
])
	assert.ok(script.includes(needle), `installer script: ${needle}`);
// A text that would break out of an NSIS string is refused.
assert.throws(
	() => Installer.emitNsis(Object.assign({}, model, { layout_text: 'a\nb' }), { output: 'x.exe' }),
	/kbd_text_invalid|kbd_installer_text/
);
assert.ok(
	Installer.emitNsis(Object.assign({}, model, { layout_text: 'A $x', company: 'C "q"' }), {
		output: 'x.exe'
	}).includes('Name "A $$x"'),
	'a $ is escaped'
);
assert.ok(
	Installer.emitNsis(Object.assign({}, model, { company: 'C "q"' }), { output: 'x.exe' }).includes(
		'"Publisher" "C $\\"q$\\""'
	),
	'a quote is escaped'
);

// The installer carries exactly the four verified images.
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kbd-installer-test-'));
try {
	fs.writeFileSync(path.join(dir, built.file), built.bytes);
	const listed = spawnSync('7z', ['x', '-y', '-aou', `-o${path.join(dir, 'x')}`, built.file], {
		cwd: dir,
		encoding: 'utf8'
	});
	assert.equal(listed.status, 0, `7z extracts the installer: ${listed.stderr}`);
	const found = [];
	const walk = (folder) => {
		for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
			const full = path.join(folder, entry.name);
			if (entry.isDirectory()) walk(full);
			else if (/^bepo(_\d+)?\.dll$/.test(entry.name)) found.push(full);
		}
	};
	walk(path.join(dir, 'x'));
	assert.deepEqual(
		found.map((file) => sha(fs.readFileSync(file))).sort(),
		Object.values(dlls).map(sha).sort(),
		'the installer holds the four images, byte for byte'
	);
	assert.ok(
		found.some((file) => file.includes('SysWOW64')),
		'a SysWOW64 copy'
	);
	for (const file of found)
		assert.deepEqual(compareLayout(model, readDll(fs.readFileSync(file)).layout), [], file);
} finally {
	fs.rmSync(dir, { recursive: true, force: true });
}
console.log(
	`[OK] kbd installer: bepo-setup.exe (${built.bytes.length} bytes) holds the four verified DLLs and registers/unregisters the layout`
);
