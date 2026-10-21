// tools/test/test-windows-exe-version-info.cjs
// Fails when ErgoptiPlus.exe would ship without its own version resource: the
// identity directives must be declared and not the AutoHotkey defaults, the
// version must be derived from the stamped BUNDLE_VERSION, and the build stage
// must check the compiled exe. A local Ahk2Exe, when present, builds the real
// entry and the test reads the produced resource.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const {
	ENTRY,
	BUNDLE,
	UNSTAMPED_VERSION,
	IDENTITY_DIRECTIVES,
	readDeclaredIdentity,
	expectedVersionInfo
} = require('../ci/windows-exe-version-info.cjs');

const root = path.resolve(__dirname, '../..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');

// 1. Every identity field is declared once, with a value of its own.
const identity = readDeclaredIdentity(root);
assert.deepEqual(Object.keys(identity).sort(), Object.values(IDENTITY_DIRECTIVES).sort());
for (const [property, value] of Object.entries(identity))
	assert.ok(!/autohotkey/i.test(value), `${property} must not be an AutoHotkey default: ${value}`);
assert.equal(
	identity.OriginalFilename,
	'ErgoptiPlus.exe',
	'the original file name is the shipped asset'
);
const license = read('LICENSE');
const holder = /^Copyright \(c\) (\d{4} .+)$/m.exec(license);
assert.ok(holder && /^MIT License/.test(license), 'LICENSE must name its MIT copyright holder');
assert.ok(
	identity.LegalCopyright.includes(holder[1]) && identity.LegalCopyright.includes('MIT'),
	'the copyright must be the LICENSE holder under MIT'
);

// 2. The version comes from the stamped BUNDLE_VERSION, never a literal.
const entry = read(ENTRY);
assert.ok(
	!/^;@Ahk2Exe-Set(File|Product)?Version/m.test(entry),
	'the entry must not pin a literal version'
);
const bundle = read(BUNDLE).split('\n');
const stampLine = bundle.findIndex(
	(line) => line === 'global BUNDLE_VERSION := "__BUNDLE_VERSION__"'
);
assert.ok(stampLine >= 0, 'bundle.ahk must keep the stamped BUNDLE_VERSION placeholder');
assert.equal(
	bundle[stampLine + 1],
	';@Ahk2Exe-Let U_BundleVersion = %A_PriorLine~.*"(.*)".*~$1%',
	'the version must be read from the line right after the stamp'
);
assert.equal(
	bundle[stampLine + 2],
	`;@Ahk2Exe-Let U_BundleVersion = %U_BundleVersion~_{2}BUNDLE_VERSION_{2}~${UNSTAMPED_VERSION}%`,
	'an unstamped build must be marked as a dev version'
);
assert.ok(
	!bundle[stampLine + 2].includes('__BUNDLE_VERSION__'),
	'the stamp step rewrites every literal placeholder, so the needle must not spell it'
);
assert.equal(bundle[stampLine + 3], ';@Ahk2Exe-SetVersion %U_BundleVersion%');
assert.equal(bundle.filter((line) => line.startsWith(';@Ahk2Exe-SetVersion')).length, 1);
assert.deepEqual(expectedVersionInfo('1.2.3'), {
	...identity,
	FileVersion: '1.2.3',
	ProductVersion: '1.2.3'
});
assert.equal(expectedVersionInfo('').FileVersion, UNSTAMPED_VERSION);

// 3. The build stage checks the compiled exe after compiling and before signing.
const workflow = read('.github/workflows/ci-windows.yml');
const compile = workflow.indexOf('- name: Compile ErgoptiPlus.ahk');
const verify = workflow.indexOf('- name: Verify the ErgoptiPlus.exe version resource');
const sign = workflow.indexOf('- name: Sign and verify ErgoptiPlus.exe');
assert.ok(
	compile > 0 && verify > compile && sign > verify,
	'the version check runs between compile and sign'
);
const step = workflow.slice(verify, sign);
assert.ok(step.includes('node tools/ci/windows-exe-version-info.cjs --version $version'));
assert.ok(
	step.includes('.VersionInfo') && step.includes('-cne $field.Value'),
	'the step compares every field exactly'
);

// 4. With a local compiler, the real entry builds with the declared resource.
const compiler = 'C:\\Program Files\\AutoHotkey\\Compiler\\Ahk2Exe.exe';
const runtime = 'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe';
let native = 'UNRUN (no local Ahk2Exe)';
if (process.platform === 'win32' && fs.existsSync(compiler) && fs.existsSync(runtime)) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-exe-version-'));
	try {
		const out = path.join(dir, 'ErgoptiPlus.exe');
		const compiled = spawnSync(
			compiler,
			['/in', path.join(root, ENTRY), '/out', out, '/base', runtime, '/silent'],
			{ encoding: 'utf8', timeout: 300000 }
		);
		assert.equal(compiled.status, 0, `Ahk2Exe failed: ${compiled.stdout}${compiled.stderr}`);
		const script =
			`$v=(Get-Item -LiteralPath '${out.replace(/'/g, "''")}').VersionInfo;` +
			`@{${Object.keys(expectedVersionInfo(''))
				.map((k) => `${k}=$v.${k}`)
				.join(';')}} | ConvertTo-Json -Compress`;
		const probe = spawnSync(
			'powershell.exe',
			['-NoProfile', '-NonInteractive', '-Command', script],
			{ encoding: 'utf8' }
		);
		assert.equal(probe.status, 0, probe.stderr);
		assert.deepEqual(
			JSON.parse(probe.stdout),
			expectedVersionInfo(''),
			'the built exe must carry the declared resource'
		);
		native = 'PASS (local Ahk2Exe build read back)';
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

console.log(
	`[OK] ErgoptiPlus.exe version resource: declared, derived and checked by the build stage; native ${native}.`
);
