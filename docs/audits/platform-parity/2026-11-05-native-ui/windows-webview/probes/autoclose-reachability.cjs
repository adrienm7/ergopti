'use strict';
const fs = require('node:fs'),
	path = require('node:path'),
	vm = require('node:vm'),
	assert = require('node:assert/strict');
const root = path.resolve(process.argv[2] || process.env.SOURCE_ROOT || '.');
const host = fs.readFileSync(
	path.join(root, 'static/ergopti_plus/windows/ui/personal_toml_editor_webview.ahk'),
	'utf8'
);
const initBody = host.match(/_HsEdWeb_InitDataJs\(\) \{([\s\S]*?)\n\}/)?.[1];
assert(initBody, 'actual native init owner exists');
const mode = initBody.match(/\",open_mode:\"\s*\.\s*_HsEdWeb_JsStr\(\"([^\"]+)\"\)/)?.[1];
assert.equal(mode, 'menu', 'actual Windows initializer emits menu');
const source = fs.readFileSync(
	path.join(root, 'static/ergopti_plus/_shared/ui/hotstring_editor/script.js'),
	'utf8'
);
const at = source.indexOf('// ======= 15/ Event Wiring');
assert(at > 0);
function run(openMode) {
	const posts = [];
	const fields = {};
	const field = (id) =>
		(fields[id] ??= {
			value: id === 'e-trig' ? 'new-trigger' : id === 'e-out' ? 'new-output' : '',
			checked: false,
			classList: { add() {}, remove() {} },
			focus() {}
		});
	const ctx = vm.createContext({
		document: { getElementById: field },
		makeHostBridge: () => () => {},
		setTimeout: () => 1,
		clearTimeout() {},
		console
	});
	ctx.window = ctx;
	vm.runInContext(source.slice(0, at), ctx);
	ctx.__mode = openMode;
	ctx.__post = (action, data) => posts.push({ action, data });
	vm.runInContext(
		`D={sections:[{name:'personal',description:'Personal',entries:[]}]};edEntry={si:0,ei:null};openMode=__mode;autoClose=true;
clearEntryErrors=()=>{};serializeTrigEditor=e=>e.value;serializeEditor=e=>e.value;parsePrio=()=>null;render=()=>{};closeModal=()=>{};toLua=__post;saveEntry(false);`,
		ctx
	);
	return {
		mode: openMode,
		autoClose: true,
		actions: posts.map((p) => p.action),
		postedEntry: posts[0].data.sections.personal.entries[0]
	};
}
const actual = run(mode),
	control = run('shortcut');
assert.deepEqual(actual.actions, ['save']);
assert.deepEqual(control.actions, ['save', 'close']);
console.log(
	JSON.stringify(
		{
			sourceRoot: root,
			provenance:
				'actual Windows init mode extracted; actual shared saveEntry/persist in JS VM; AHK/native write failure not executed',
			actualWindows: actual,
			syntheticShortcutControl: control,
			conclusion:
				'Windows automatic save→close failure repro is unreachable through current native initializer; no WVB-003'
		},
		null,
		2
	)
);
