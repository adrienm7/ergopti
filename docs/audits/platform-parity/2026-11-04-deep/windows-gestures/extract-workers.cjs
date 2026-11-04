'use strict';
// Evaluate only literal string concatenations in the actual AHK worker builders.
// No AHK/runtime behavior is simulated here; emitted PS bodies are tested by pwsh.
const fs = require('fs'),
	assert = require('assert'),
	root = '/workspace/ergopti/static/ergopti_plus/windows',
	out = __dirname;
const data = fs.readFileSync(root + '/_generated/touchpad_registry.ahk', 'utf8');
const reg = data.match(/"powershell_key", "([^"]+)"/)[1];
const vals = [
	...data.slice(data.indexOf('"values", [')).matchAll(/Map\("name", "([^"]+)", "value", (\d+)\)/g)
]
	.map((m) => `  '${m[1]}' = ${m[2]}\r\n`)
	.join('');
function terms(expr) {
	let r = [],
		start = 0,
		q = false;
	for (let i = 0; i < expr.length; i++) {
		if (expr[i] === '`' && q) {
			i++;
			continue;
		}
		if (expr[i] === '"') q = !q;
		if (!q && expr.slice(i, i + 3) === ' . ') {
			r.push(expr.slice(start, i));
			start = i + 3;
			i += 2;
		}
	}
	r.push(expr.slice(start));
	return r;
}
function extract(file, name, target) {
	const source = fs.readFileSync(root + '/' + file, 'utf8');
	const start = source.indexOf(name + '(ResultPath) {');
	assert(start >= 0);
	const body = source.slice(start).split(/\n\s*return S\n\}/)[0];
	let script = '';
	for (const line of body.split('\n')) {
		const m = line.match(/^\s*S\s*(:=|\.=)\s*(.*)$/);
		if (!m) continue;
		const text = terms(m[2])
			.map((t) => {
				if (t === 'CRLF') return '\r\n';
				if (t === 'ResultLiteral') return out + '/worker.result';
				if (t === 'TouchpadRegistryPowerShellKey()') return reg;
				if (t === 'TouchpadRegistryPowerShellValues()') return vals;
				if (t[0] === '"' && t.at(-1) === '"')
					return t
						.slice(1, -1)
						.replace(/`([`"rnt])/g, (_, x) => ({ r: '\r', n: '\n', t: '\t' })[x] || x);
				throw Error('nonliteral term ' + t);
			})
			.join('');
		if (m[1] === ':=') script = text;
		else script += text;
	}
	assert(script.includes('exit $ErgoptiExitCode'));
	fs.writeFileSync(out + '/' + target, script);
	console.log(
		target + ': extracted from ' + file + '::' + name + ', ' + script.split('\n').length + ' lines'
	);
}
extract(
	'ui/onboarding/gesture_registration.ahk',
	'_Onboarding_BuildGesturePsScript',
	'worker-onboarding.ps1'
);
extract('modules/gestures/config.ahk', '_GestureRestartBuildPsScript', 'worker-restart.ps1');
