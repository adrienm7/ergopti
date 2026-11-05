import fs from 'node:fs';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
const root = process.argv[2],
	out = process.argv[3];
assert(root);
const w = 'static/ergopti_plus/windows/';
const paths = {
	gen: w + 'modules/hotstrings/hotstrings_text_expansion.ahk',
	escape: w + 'infra/text_utils.ahk',
	engine: w + 'infra/hotstrings/hotstring_engine_main.ahk',
	preview: w + 'infra/personal_info_preview.ahk',
	hook: w + 'infra/hotstrings/hotstring_inputhook.ahk',
	builder: w + 'infra/hotstrings/hotstring_builder.ahk',
	schema: 'static/ergopti_plus/_shared/core/config_schema/config.schema.json',
	io: w + 'infra/hotstrings/personal_toml_io.ahk',
	boot: w + 'ErgoptiPlus.ahk',
	decl: 'static/ergopti_plus/_shared/modules/personal_info/fields.toml'
};
const s = Object.fromEntries(
	Object.entries(paths).map(([k, p]) => [k, fs.readFileSync(root + '/' + p, 'utf8')])
);
function body(k, name, indent = '') {
	const start = s[k].search(new RegExp('^' + indent + name + '\\(', 'm'));
	assert(start >= 0, name + ' exists');
	const end = s[k].indexOf('\n' + indent + '}', start);
	assert(end > start, name + ' closes');
	return s[k].slice(start, end + indent.length + 2);
}
function ex(k, n, b = 1, a = 5) {
	const l = s[k].split('\n');
	let c = 0;
	for (let i = 0; i < l.length; i++)
		if (l[i].includes(n)) {
			c++;
			console.log(paths[k] + ':' + (i + 1));
			for (let j = Math.max(0, i - b); j <= Math.min(l.length - 1, i + a); j++)
				console.log(`${j + 1}: ${l[j]}`);
		}
	assert(c > 0, 'nonvacuous excerpt ' + n);
}
console.log(
	'PROVENANCE: Node22 source contracts only; no AHK/Windows/GUI/form/Send/clipboard execution. Native owner fixture is generated but UNEXECUTED. Arithmetic is static configuration cardinality, not measured time or memory.'
);
for (const [k, p] of Object.entries(paths))
	console.log('sha256 ' + crypto.createHash('sha256').update(s[k]).digest('hex') + ' ' + p);
const g = body('gen', 'Generate', '\t\t');
function rootPresent(text) {
	return (
		text.includes('value := value . "{Tab}"') &&
		text.includes('value := value . hotstrings[A_LoopField]') &&
		text.includes('CreateHotstringCombo(combo, EscapeSpecialChars(value),') &&
		text.includes('if (value != "")')
	);
}
assert(rootPresent(g));
assert(
	!rootPresent(g.replace('EscapeSpecialChars(value)', 'value')),
	'whole-escape mutation must be detected'
);
assert(
	!rootPresent(
		g.replace(
			'value := value . hotstrings[A_LoopField]',
			'value := value . EscapeSpecialChars(hotstrings[A_LoopField])'
		)
	),
	'per-value-escape mutation must be detected'
);
const dynamic = body('engine', 'HSE_TryPersonalInfoCombo');
assert(dynamic.includes('if (Value == "")'));
assert(dynamic.includes('Replacement .= "{Tab}"'));
assert(dynamic.includes('Replacement .= SendEscapeLiteral(Value)'));
const esc = body('escape', 'SendEscapeLiteral');
assert(esc.includes('Escaped .= "{{}"'));
assert(esc.includes('Escaped .= "{}}"'));
const schema = JSON.parse(s.schema);
assert(
	s.schema.includes('"pattern_max_length": { "type": "integer", "minimum": 1, "maximum": 16 }')
);
console.log(
	'PIW-001: supported eager multi-field registrations escape control separators after joining and admit partially empty identities, unlike per-value escaped/all-or-nothing transient resolver.'
);
ex('gen', 'GeneratePersonalInformationHotstrings(', 0, 7);
ex('gen', 'value := value . "{Tab}"', 3, 10);
ex('gen', 'CreateHotstring("*", "@" combo', 1, 6);
ex('escape', 'if (Ch == "{")', 1, 6);
ex('engine', 'if (Value == "")', 1, 11);
ex('hook', 'try return _PIPreviewMaskedText', 3, 3);
ex('schema', '"pattern_max_length": {', 1, 2);
console.log(
	'MUTATION CONTROLS: source-contract predicate detects removing whole-string escape and moving escaping to each value; this checks source-check sensitivity only, not AHK behavior.'
);
let sum = 0n;
for (let i = 1; i <= 16; i++) {
	sum += 13n ** BigInt(i);
	if ([1, 2, 4, 8, 16].includes(i))
		console.log(
			`OBSERVED_LIMIT static 13 aliases maxLen=${i}: ${sum} generated leaves (no registration execution).`
		);
}
if (out) {
	const helpers = [
		'GeneratePersonalInformationHotstrings',
		'EscapeSpecialChars',
		'Generate',
		'CreateHotstringCombo'
	]
		.map((n) => body('gen', n, '\t\t'))
		.join('\n\n');
	const previewHelpers = ['_PIPreviewIsTagChar', '_PIPreviewTrailingTag', '_PIPreviewFieldsForTag']
		.map((n) => body('preview', n))
		.join('\n\n');
	const preamble = [
		'#Requires AutoHotkey v2.0+',
		'#NoTrayIcon',
		'#SingleInstance Off',
		'; UNEXECUTED on Linux. Exact production assembly functions; registration is a recording seam only.',
		'; No clipboard, native key send, GUI or real values.',
		'global Records := Map()',
		'global ScriptInformation := Map("MagicKey", Chr(0x2605))',
		'global PersonalInformation := Map("last_name", "LEFT", "first_name", "RIGHT")',
		'global PersonalInformationLetters := Map("n", "last_name", "p", "first_name")',
		'global PERSONAL_INFO_TAGS := Map()',
		'global PI_PREVIEW_MAX_TAG_LEN := 12',
		'global PI_PREVIEW_CATEGORY := "personal"',
		'global HSE_Buffer := ""',
		'global HSE_Suppressed := false',
		'global HSE_RebuildInProgress := false',
		'global HSE_RegistryTransitionDepth := 0',
		'global HSE_PersonalInfoCombosEnabled := true',
		'CreateHotstring(Flags, Trigger, Replacement, Options) {',
		' global Records',
		' Records[Trigger] := {Replacement: Replacement, Options: Options}',
		'}',
		''
	];
	const tests = [
		'MK := ScriptInformation["MagicKey"]',
		'GeneratePersonalInformationHotstrings(Map("n", "LEFT", "p", "RIGHT"), PersonalInformationLetters, 2)',
		'Registered := Records["@np" . MK]',
		'HSE_Buffer := "@np" . MK',
		'Transient := HSE_TryPersonalInfoCombo(MK)',
		'if Registered.Replacement != "LEFT{{}Tab{}}RIGHT"',
		' throw Error("Baseline: expected actual eager owner to escape the separator braces")',
		'if !IsObject(Transient) || Transient.Replacement != "LEFT{Tab}RIGHT"',
		' throw Error("Healthy transient control did not retain a real Tab command")',
		'Records.Clear()',
		'PersonalInformation["last_name"] := ""',
		'GeneratePersonalInformationHotstrings(Map("n", "", "p", "RIGHT"), PersonalInformationLetters, 2)',
		'if !Records.Has("@np" . MK) || Records["@np" . MK].Replacement != "RIGHT"',
		' throw Error("Baseline: expected actual eager owner to admit the partial identity")',
		'HSE_Buffer := "@np" . MK',
		'if HSE_TryPersonalInfoCombo(MK) != ""',
		' throw Error("Healthy transient empty-field control must decline whole combo")',
		'FileAppend("REPRODUCED production eager-owner separator/empty mismatch; transient healthy controls passed; no native receiving." . Chr(10), "*")',
		'ExitApp(0)'
	];
	const fixture =
		preamble.join('\n') +
		'\n' +
		helpers +
		'\n' +
		esc +
		'\n' +
		previewHelpers +
		'\n' +
		dynamic +
		'\n' +
		tests.join('\n') +
		'\n';
	fs.writeFileSync(out + '/owner-unexecuted.ahk', '\ufeff' + fixture);
	console.log(
		'UNEXECUTED owner fixture sha256 ' +
			crypto
				.createHash('sha256')
				.update('\ufeff' + fixture)
				.digest('hex') +
			' owner-unexecuted.ahk'
	);
}
console.log(
	'PASS: one grouped source-confirmed owner defect; source mutation sensitivity controls; native Windows executions=0.'
);
