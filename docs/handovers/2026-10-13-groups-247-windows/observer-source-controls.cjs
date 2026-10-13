// Private source evidence for the Windows-only cached InputHook hint contract.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const base = __dirname;
const relative = 'static/ergopti_plus/windows/modules/keylogger/keylogger_hook.ahk';
const original = fs.readFileSync(
	process.argv[2] || path.join(base, 'observer-before', relative),
	'utf8'
);
const corrected = fs.readFileSync(
	process.argv[3] || path.join(base, 'observer-projection', relative),
	'utf8'
);
function body(source, name) {
	const expression = new RegExp(`^${name}\\([^\\n]*\\) \\{`, 'm');
	const match = source.match(expression);
	assert(match, `Actual function must exist: ${name}`);
	let offset = match.index + match[0].length;
	const start = offset;
	let depth = 1;
	while (depth && offset < source.length) {
		if (source[offset] === '{') ++depth;
		if (source[offset] === '}') --depth;
		++offset;
	}
	assert.equal(depth, 0);
	return source.slice(start, offset - 1).replace(/^\s*;.*$/gm, '');
}
function check(source) {
	const capture = body(source, '_KL_Hook_CaptureInput');
	const guard = capture.indexOf(
		'if !Keylogger.initialized || Keylogger._shutting_down || KLHook.capture_stopping'
	);
	const epoch = capture.indexOf('if KLHook.last_hint_lifecycle != Keylogger.lifecycle_generation');
	const down = capture.indexOf('if Kind = "key"');
	assert(
		guard >= 0 && epoch > guard && down > epoch,
		'Admission and lifecycle revocation must precede cached key updates.'
	);
	const revoked = capture.slice(epoch, down);
	assert(revoked.includes('KLHook.last_vk := 0') && revoked.includes('KLHook.last_sc := 0'));
	assert(revoked.includes('KLHook.last_hint_lifecycle := Keylogger.lifecycle_generation'));
	const invalidate = body(source, 'KL_Hook_InvalidateCapture');
	assert(invalidate.includes('KLHook.last_vk := 0') && invalidate.includes('KLHook.last_sc := 0'));
	assert(invalidate.includes('KLHook.last_hint_lifecycle := 0'));
	const start = body(source, 'KL_Hook_Start');
	const subscribe = start.indexOf('HookDispatcher.Register(');
	assert(
		subscribe > start.indexOf('KLHook.last_vk := 0') && start.indexOf('KLHook.last_vk := 0') >= 0
	);
	assert(
		subscribe > start.indexOf('KLHook.last_sc := 0') && start.indexOf('KLHook.last_sc := 0') >= 0
	);
	assert(start.includes('KLHook.last_hint_lifecycle := Keylogger.lifecycle_generation'));
	const commit = body(source, '_KL_Hook_CommitInput');
	assert(commit.includes('ErgoFn.Call(delay, Intent.arrival_vk, Intent.arrival_sc)'));
	assert(commit.includes('ErgoFn.Call(delay, Intent.vk, Intent.sc, Intent.vk = 0x08)'));
}
assert.throws(() => check(original), /Admission and lifecycle revocation/);
check(corrected);
const mutations = [
	(text) =>
		text.replace(
			'if !Keylogger.initialized || Keylogger._shutting_down || KLHook.capture_stopping',
			'if false'
		),
	(text) =>
		text.replace('if KLHook.last_hint_lifecycle != Keylogger.lifecycle_generation', 'if false'),
	(text) =>
		text.replace(
			'KLHook.last_hint_lifecycle := Keylogger.lifecycle_generation',
			'KLHook.last_hint_lifecycle := 0'
		),
	(text) =>
		text.replace(
			'KLHook.capture_generation += 1\n\t\tKLHook.last_vk := 0',
			'KLHook.capture_generation += 1\n\t\tKLHook.last_vk := 1'
		),
	(text) =>
		text.replace(
			'KLHook.capture_generation += 1\n\t\tKLHook.last_vk := 0\n\t\tKLHook.last_sc := 0',
			'KLHook.capture_generation += 1\n\t\tKLHook.last_vk := 0\n\t\tKLHook.last_sc := 1'
		),
	(text) =>
		text.replace(
			'KLHook.capture_stopping := false\n\t\t\tKLHook.last_vk := 0',
			'KLHook.capture_stopping := false\n\t\t\tKLHook.last_vk := 1'
		),
	(text) =>
		text.replace(
			'ErgoFn.Call(delay, Intent.arrival_vk, Intent.arrival_sc)',
			'ErgoFn.Call(delay, Intent.arrival_vk)'
		)
];
for (const mutate of mutations) {
	const changed = mutate(corrected);
	assert.notEqual(changed, corrected);
	assert.throws(() => check(changed));
}
console.log('PASS actual source controls: original RED, corrected GREEN, 7 causal inverses.');
console.log(
	'No AHK behavior executed; 7 authored native cases remain UNRUN. No physical pairing is inferred.'
);
