// tools/test/test-windows-exe-version-info.cjs
// Fails when ErgoptiPlus.exe would ship without its own version resource: the
// identity directives must be generated from tools/lib/app-metadata.cjs and not
// the AutoHotkey defaults, the copyright must end at the stamped build year,
// the version must be derived from the stamped BUNDLE_VERSION, and the build
// stage must check the compiled exe. A local Ahk2Exe, when present, builds the
// real entry and the test reads the produced resource.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const {
	ENTRY,
	BUNDLE,
	INCLUDE,
	UNSTAMPED_VERSION,
	IDENTITY_DIRECTIVES,
	identity: identityOf,
	renderInclude,
	expectedVersionInfo,
	asciiJson
} = require('../ci/windows-exe-version-info.cjs');
const metadata = require('../lib/app-metadata.cjs');

const root = path.resolve(__dirname, '../..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
const meta = metadata.readMetadata();

/**
 * Evaluates the Ahk2Exe directives of the include as the compiler does: Let
 * assigns a U_ variable, %U_x% reads one and %U_x~needle~replacement% applies
 * a regular expression to it; Set* writes a resource field.
 */
function evaluateDirectives(text, variables) {
	const vars = { ...variables };
	const deref = (value) =>
		value.replace(/%(U_[A-Za-z]+)(?:~([^~]*)~([^%]*))?%/g, (_, name, needle, replacement) => {
			assert.ok(Object.hasOwn(vars, name), `${name} is read before it is assigned`);
			return needle === undefined
				? vars[name]
				: vars[name].replace(new RegExp(needle), replacement.replace(/\$(\d)/g, '$$$1'));
		});
	const fields = {};
	const byDirective = new Map(Object.entries(IDENTITY_DIRECTIVES));
	for (const line of text.replace(/^\uFEFF/, '').split('\n')) {
		const let_ = /^;@Ahk2Exe-Let (U_[A-Za-z]+) = (.*)$/.exec(line);
		if (let_) {
			vars[let_[1]] = deref(let_[2]);
			continue;
		}
		const set = /^;@Ahk2Exe-(Set[A-Za-z]+|Set Comments,) (.*)$/.exec(line);
		if (set) {
			assert.ok(byDirective.has(set[1]), `unexpected directive ${set[1]}`);
			assert.ok(!Object.hasOwn(fields, byDirective.get(set[1])), `${set[1]} is set twice`);
			fields[byDirective.get(set[1])] = deref(set[2]);
		}
	}
	return fields;
}

// 1. Every identity field is generated once from the shared metadata, with a
//    value of its own, and the entry types none of them.
const include = read(INCLUDE);
assert.equal(include, renderInclude(), `${INCLUDE} is stale: run npm run codegen:exe-version-info`);
assert.ok(include.startsWith('\uFEFF'), 'the generated include keeps the AHK UTF-8 BOM');
const entry = read(ENTRY);
assert.ok(
	!/^;@Ahk2Exe-Set(?!Version)/m.test(entry),
	'the entry must not type an identity directive: they are generated'
);
assert.match(
	entry,
	/^#Include core\/lifecycle\/engine\/bundle\.ahk\n#Include _generated\/exe_version_info\.ahk$/m,
	'the generated directives follow bundle.ahk, whose Let assigns the build year they read'
);
const stampedYear = meta.firstYear + 2;
for (const [year, built] of [
	[stampedYear, String(stampedYear)],
	[meta.firstYear, '__BUNDLE_BUILD_YEAR__'],
	[meta.firstYear, String(meta.firstYear)]
]) {
	const identity = evaluateDirectives(include, { U_BundleBuildYear: built });
	assert.deepEqual(
		identity,
		identityOf(year),
		`the exe built in ${built} shows the shared metadata`
	);
}
const identity = identityOf(stampedYear);
assert.deepEqual(Object.keys(identity).sort(), Object.values(IDENTITY_DIRECTIVES).sort());
for (const [property, value] of Object.entries(identity))
	assert.ok(!/autohotkey/i.test(value), `${property} must not be an AutoHotkey default: ${value}`);
assert.equal(
	identity.OriginalFilename,
	'ErgoptiPlus.exe',
	'the original file name is the shipped asset'
);
const license = read('LICENSE');
const holder = /^Copyright \(c\) (\d{4}) (.+)$/m.exec(license);
assert.ok(holder && /^MIT License/.test(license), 'LICENSE must name its MIT copyright holder');
assert.equal(
	identity.LegalCopyright,
	`Copyright © ${holder[1]}–${stampedYear} ${holder[2]}. MIT License.`,
	'the copyright must be the LICENSE holder under MIT, ending at the build year'
);
assert.ok(identity.Comments.includes(meta.homepage), 'the comments name the website');
assert.ok(identity.Comments.includes(meta.issues), 'the comments name the issue tracker');
// The expected values cross a PowerShell pipe: escaped, no code page alters them.
assert.ok(/^[\x20-\x7e]*$/.test(asciiJson(identity)));
assert.deepEqual(JSON.parse(asciiJson(identity)), identity);

// 2. The version comes from the stamped BUNDLE_VERSION, never a literal.
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
assert.deepEqual(expectedVersionInfo('1.2.3', stampedYear), {
	...identity,
	FileVersion: '1.2.3',
	ProductVersion: '1.2.3'
});
assert.equal(expectedVersionInfo('', stampedYear).FileVersion, UNSTAMPED_VERSION);
// The build year is stamped right before the line its Let reads.
const yearLine = bundle.findIndex(
	(line) => line === 'global BUNDLE_BUILD_YEAR := "__BUNDLE_BUILD_YEAR__"'
);
assert.ok(yearLine >= 0, 'bundle.ahk must keep the stamped BUNDLE_BUILD_YEAR placeholder');
assert.equal(bundle[yearLine + 1], ';@Ahk2Exe-Let U_BundleBuildYear = %A_PriorLine~.*"(.*)".*~$1%');
assert.ok(!include.includes('__BUNDLE_BUILD_YEAR__'), 'the stamp step must not rewrite the needle');

// 3. The build stage checks the compiled exe after compiling and before signing.
const workflow = read('.github/workflows/ci-windows.yml');
const compile = workflow.indexOf('- name: Compile ErgoptiPlus.ahk');
const verify = workflow.indexOf('- name: Verify the ErgoptiPlus.exe version resource');
const sign = workflow.indexOf('- name: Sign and verify ErgoptiPlus.exe');
assert.ok(
	compile > 0 && verify > compile && sign > verify,
	'the version check runs between compile and sign'
);
const stampYear = workflow.indexOf('- name: Stamp BUNDLE_BUILD_YEAR');
assert.ok(stampYear > 0 && stampYear < compile, 'the build year is stamped before the compile');
const yearStep = workflow.slice(stampYear, workflow.indexOf('- name:', stampYear + 10));
assert.ok(yearStep.includes('node tools/lib/app-metadata.cjs build-year'));
assert.ok(yearStep.includes('$text.Replace("__BUNDLE_BUILD_YEAR__", $year)'));
assert.ok(yearStep.includes('[Text.UTF8Encoding]::new($true)'), 'the stamp keeps the AHK BOM');
const step = workflow.slice(verify, sign);
assert.ok(step.includes('node tools/ci/windows-exe-version-info.cjs --version $version'));
for (const stage of [yearStep, step])
	assert.ok(
		!stage.includes('ERGOPTI_BUILD_COMMIT') && !stage.includes('SOURCE_DATE_EPOCH'),
		'the stamp and the check both read the year of the checked-out commit'
	);
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
			`@{${Object.keys(expectedVersionInfo('', meta.firstYear))
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
			expectedVersionInfo('', meta.firstYear),
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
