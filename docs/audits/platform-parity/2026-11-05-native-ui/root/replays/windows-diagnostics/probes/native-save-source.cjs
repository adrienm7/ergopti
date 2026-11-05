'use strict';
const fs = require('node:fs'),
	path = require('node:path'),
	assert = require('node:assert/strict');
const root = process.argv[2] || process.env.ERGOPTI_AUDIT_SOURCE_ROOT;
assert.ok(root, 'Pass source root or ERGOPTI_AUDIT_SOURCE_ROOT');
const core = fs.readFileSync(
	path.join(root, 'static/ergopti_plus/windows/ui/healthcheck/core.ahk'),
	'utf8'
);
const report = fs.readFileSync(
	path.join(root, 'static/ergopti_plus/windows/ui/healthcheck/report.ahk'),
	'utf8'
);
function body(text, name) {
	const start = text.indexOf('\n' + name + '(');
	assert.ok(start >= 0, name + ' exists');
	const end = text.indexOf('\n}', start);
	assert.ok(end > start);
	return text.slice(start + 1, end + 2);
}
const shown = body(core, '_HC_ShowNativeSnapshot'),
	native = body(core, '_HC_NativeSaveSnapshot'),
	perform = body(report, 'HealthCheck_PerformAction'),
	save = body(report, '_HCReport_Save'),
	page = body(core, '_HC_PerformPageAction');
assert.ok(shown.includes('NativeSave.OnEvent("Click", _HC_NativeSaveSnapshot.Bind(Snapshot))'));
assert.ok(native.includes('return HealthCheck_PerformAction('));
assert.ok(!/Outcome|Notify|MsgBox|\.Text\s*:=|\["ok"\]/.test(native));
assert.ok(perform.includes('catch as Err {') && perform.includes('return Map("ok", false)'));
assert.ok(perform.includes('LoggerSuccess(') && perform.includes('return Outcome'));
assert.ok(
	save.includes('ResolvedWriter.Call(Path, Text)') &&
		save.includes('Written != 1') &&
		save.includes('throw Error(')
);
assert.ok(
	page.includes('(Outcome["ok"] ? "true" : "false")') && page.includes('_HC_Send(WindowEpoch, Json')
);
console.log(
	'SOURCE characterization: native Click binds direct handler; it returns the effect outcome without rendering it.'
);
console.log(
	'SOURCE healthy control: acknowledged durable writer returns Path, then Explorer is invoked.'
);
console.log(
	'SOURCE refusal control: durable writer false/throw -> caught effect refusal {ok:false}; no native result presenter.'
);
console.log(
	'SOURCE sibling control: WebView effect result renders the same outcome through an action acknowledgement.'
);
console.log(
	'NATIVE WINDOWS CHARACTERIZATION UNEXECUTED: WebView unavailable -> native fallback Save; deny the private diagnostics target write; click Save; inspect unchanged native window and logged Diagnostics action save failed.'
);
console.log(native);

const logger = fs.readFileSync(
	path.join(root, 'static/ergopti_plus/windows/infra/logger.ahk'),
	'utf8'
);
const error = fs.readFileSync(
	path.join(root, 'static/ergopti_plus/windows/ui/error_dialog/init.ahk'),
	'utf8'
);
assert.ok(logger.includes('ErrorDialog_OnError(Tag, Msg, Body, Stamp)'));
assert.ok(error.includes('NotifierSend(Heading') && error.includes('Record["message"]'));
console.log(
	'REFUTATION: LoggerError reaches ErrorDialog_OnError; unavailable WebView path announces the logged failure through NotifierSend. No confirmed silent-failure item retained.'
);
