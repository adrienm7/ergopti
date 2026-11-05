import fs from 'node:fs';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
const root = process.argv[2],
	out = process.argv[3];
assert(root && out);
const paths = {
	io: 'static/ergopti_plus/windows/infra/hotstrings/personal_toml_io.ahk',
	loader: 'static/ergopti_plus/windows/infra/toml/toml_loader.ahk',
	helpers: 'static/ergopti_plus/windows/infra/toml/toml_helpers.ahk',
	actions: 'static/ergopti_plus/windows/modules/gestures/actions.ahk',
	editor: 'static/ergopti_plus/windows/ui/editors.ahk'
};
const s = Object.fromEntries(
	Object.entries(paths).map(([k, p]) => [k, fs.readFileSync(root + '/' + p, 'utf8')])
);
function body(k, n) {
	const a = s[k].search(new RegExp('^' + n + '\\(', 'm'));
	assert(a >= 0, n);
	const z = s[k].indexOf('\n}', a);
	assert(z > a, n + ' closes');
	return s[k].slice(a, z + 2);
}
function ex(k, n, b = 1, a = 6) {
	const l = s[k].split('\n');
	let c = 0;
	for (let i = 0; i < l.length; i++)
		if (l[i].includes(n)) {
			c++;
			console.log(paths[k] + ':' + (i + 1));
			for (let j = Math.max(0, i - b); j <= Math.min(l.length - 1, i + a); j++)
				console.log(`${j + 1}: ${l[j]}`);
		}
	assert(c > 0);
}
console.log(
	'PROVENANCE: source-only PIW-002. No AHK execution. Actual Lua codec compatibility oracle is separate; no ported regex is counted as Windows execution.'
);
for (const [k, p] of Object.entries(paths))
	console.log('sha256 ' + crypto.createHash('sha256').update(s[k]).digest('hex') + ' ' + p);
const read = body('io', 'ReadPersonalInfoToml');
assert(read.includes('NextInformation := OpeningInformation.Clone()'));
assert(read.includes('if RegExMatch(Line, \'i)^(\\w+)\\s*=\\s*"((?:[^"\\\\]|\\\\.)*)"\', &KM)'));
assert(read.includes('"source", Map("admitted", true, "present", true, "bytes", Bytes'));
assert(
	s.actions.includes('Fn: (*) => GestureOpenIfExists(ScriptInformation["PersonalInfoTomlPath"])')
);
console.log(
	'PIW-002 source: valid literal-string/quoted-key known fields have no matching assignment branch, yet source cache records admitted bytes and runtime retains defaults. Explicit form Save requires source consent but that certifies source bytes, not successful field decoding.'
);
ex('actions', '"open_personal_info",', 0, 3);
ex('io', "if RegExMatch(Line, 'i)^(\\w+)", 2, 8);
ex('io', 'NextInformation := OpeningInformation.Clone()', 2, 5);
ex('io', '"source", Map("admitted", true', 4, 3);
ex('editor', 'for PersonalInformationKey, OldValue', 1, 11);
ex('io', '_PersonalInfoEditorSourcesEqual(EditorSource["source"], Source)', 3, 5);
const fixtureSource =
	[
		'#Requires AutoHotkey v2.0+',
		'#NoTrayIcon',
		'#SingleInstance Off',
		'; UNEXECUTED. Actual ReadPersonalInfoToml and actual decoding helpers on synthetic artifact files only.',
		'global PersonalInformation := Map("first_name", "PLACEHOLDER")',
		'global PersonalInformationLetters := Map("p", "first_name")',
		'global _ReadPersonalInfoTomlCache := false',
		'global _TomlUnreadableFiles := Map()',
		'global LogCalls := 0',
		'LoggerWarn(Args*) {',
		' global LogCalls',
		' LogCalls += 1',
		'}',
		'LoggerError(Args*) {',
		' global LogCalls',
		' LogCalls += 1',
		'}',
		'FSStrictExists(Path) => FileExist(Path) != ""',
		'FSReadBytesStrict(Path) => FileRead(Path, "RAW")',
		body('loader', 'UnescapeTomlString'),
		body('helpers', 'TOML_UnescapeBasicStringContents'),
		body('io', '_PersonalInfoDecodeSourceBytes'),
		read,
		'',
		'for Case in ["double", "literal", "quoted-key"] {',
		' PersonalInformation := Map("first_name", "PLACEHOLDER")',
		' PersonalInformationLetters := Map("p", "first_name")',
		' _ReadPersonalInfoTomlCache := false',
		' LogCalls := 0',
		' Path := A_ScriptDir . "\\reader-" . Case . ".toml"',
		' ReadPersonalInfoToml(Path)',
		' Expected := Case == "double" ? "SYNTHETIC" : "PLACEHOLDER"',
		' if PersonalInformation["first_name"] != Expected',
		'  throw Error("Unexpected actual reader result for " . Case)',
		' if !_ReadPersonalInfoTomlCache["source"]["admitted"]',
		'  throw Error("Actual reader did not publish admitted source")',
		' if LogCalls != 0 || _TomlUnreadableFiles.Has(Path)',
		'  throw Error("This path unexpectedly diagnosed/latches unsupported valid syntax")',
		'}',
		'FileAppend("REPRODUCED actual reader known-field literal/quoted-key omission with admitted source; healthy double-quoted control; no clipboard/native desktop." . Chr(10), "*")',
		'ExitApp(0)'
	].join('\n') + '\n';
fs.writeFileSync(out + '/reader-unexecuted.ahk', '\ufeff' + fixtureSource);
fs.writeFileSync(
	out + '/reader-double.toml',
	'[info]\nfirst_name = "SYNTHETIC"\n[letters]\np = "first_name"\n'
);
fs.writeFileSync(
	out + '/reader-literal.toml',
	"[info]\nfirst_name = 'SYNTHETIC'\n[letters]\np = 'first_name'\n"
);
fs.writeFileSync(
	out + '/reader-quoted-key.toml',
	'[info]\n"first_name" = "SYNTHETIC"\n[letters]\np = "first_name"\n'
);
console.log(
	'Generated actual-owner AHK reader fixture and3 private synthetic sources, UNEXECUTED. sha256=' +
		crypto
			.createHash('sha256')
			.update('\ufeff' + fixtureSource)
			.digest('hex')
);
console.log('PASS source contract. Native Windows execution=0.');
