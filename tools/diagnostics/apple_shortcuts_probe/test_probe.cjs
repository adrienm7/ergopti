// tools/diagnostics/apple_shortcuts_probe/test_probe.cjs
'use strict';
// Controlled JXA API tests only; this file never produces a native PASS.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(__dirname + '/discover.js', 'utf8');
let passed = 0;
function entry(id, name, accepts = false) {
	return { id: () => id, name: () => name, acceptsInput: () => accepts };
}
function evaluate(collections, throws) {
	let calls = 0;
	const checkpoints = [];
	const collection = function () {
		calls++;
		if (throws) throw throws;
		return collections[Math.min(calls - 1, collections.length - 1)];
	};
	assert.equal(collection.length, 0, 'zero JS function arity must never be a catalogue census');
	const context = {
		ObjC: { import: (name) => assert.equal(name, 'Foundation') },
		Application: (id) => {
			assert.equal(id, 'com.apple.shortcuts.events');
			return { shortcuts: collection };
		},
		$: {
			NSUTF8StringEncoding: 4,
			NSFileHandle: {
				fileHandleWithStandardError: { writeData: (data) => checkpoints.push(data.bytes) }
			},
			NSString: {
				stringWithString: (value) => ({
					dataUsingEncoding: (encoding) => {
						assert.equal(encoding, 4);
						return { length: Buffer.byteLength(value, 'utf8'), bytes: value };
					}
				})
			}
		}
	};
	vm.createContext(context);
	vm.runInContext(source, context);
	const raw = context.run();
	return { value: JSON.parse(raw), raw, calls, checkpoints };
}
function test(name, fn) {
	fn();
	passed++;
	process.stdout.write('ok ' + name + '\n');
}
test('native collection invoked despite function arity zero', () => {
	const result = evaluate([[entry('id-1', 'name')]]);
	assert.equal(result.calls, 2);
	assert.deepEqual(result.value, {
		version: 1,
		status: 'observed',
		choices: [{ id: 'id-1', name: 'name', accepts_input: false }],
		truncated: false
	});
});
test('permission throw never becomes an empty successful inventory', () => {
	const result = evaluate([], Object.assign(new Error('PRIVATE NAME'), { errorNumber: -1743 }));
	assert.equal(result.calls, 1);
	assert.deepEqual(result.value, {
		version: 1,
		status: 'refused',
		stage: 1,
		reason: 'automation_permission_refused'
	});
	assert.equal(result.raw.includes('PRIVATE'), false);
});
test('ordinary native throw emits no private detail', () => {
	const result = evaluate([], new Error('SECRET argv'));
	assert.equal(result.value.status, 'refused');
	assert.equal(result.raw.includes('SECRET'), false);
});
test('actual empty array invokes both observations', () => {
	const result = evaluate([[]]);
	assert.equal(result.calls, 2);
	assert.deepEqual(result.value, {
		version: 1,
		status: 'observed',
		choices: [],
		truncated: false
	});
});
test('non-array length field refuses', () => {
	const result = evaluate([{ length: 0 }]);
	assert.equal(result.value.status, 'refused');
});
test('structured Unicode newline NFD and duplicate names remain separate', () => {
	const name = '日本 e\u0301\n%PATH%';
	const result = evaluate([[entry('first', name), entry('second', name)]]);
	assert.deepEqual(result.value.choices, [
		{ id: 'first', name, accepts_input: false },
		{ id: 'second', name, accepts_input: false }
	]);
});
test('duplicate stable identifier refuses', () => {
	assert.equal(evaluate([[entry('same', 'a'), entry('same', 'b')]]).value.status, 'refused');
});
test('only output is capped at64 while actual catalogue query is explicit', () => {
	const result = evaluate([Array.from({ length: 65 }, (_, i) => entry('id-' + i, 'name-' + i))]);
	assert.equal(result.calls, 2);
	assert.equal(result.value.choices.length, 64);
	assert.equal(result.value.truncated, true);
});
test('changed native census refuses', () => {
	const result = evaluate([[entry('one', 'name')], []]);
	assert.equal(result.value.status, 'stale');
});
test('invalid metadata and NUL refuse', () => {
	for (const row of [entry('', 'name'), entry('x', 'bad\0name'), entry('x', 'name', 'false')])
		assert.equal(evaluate([[row]]).value.status, 'refused');
});
test('name bound measures UTF8bytes', () => {
	assert.equal(evaluate([[entry('id', '日'.repeat(1366))]]).value.status, 'refused');
});
test('final JSON byte cap refuses without emitting catalogue', () => {
	const result = evaluate([
		Array.from({ length: 64 }, (_, i) => entry('id-' + i, 'x'.repeat(2000)))
	]);
	assert.equal(result.value.status, 'refused');
	assert.equal(result.value.stage, 5);
	assert.ok(result.raw.length < 128);
});
test('fixed stage markers bracket both actual catalogue calls without payload content', () => {
	assert.deepEqual(evaluate([[entry('private-id', 'private-name')]]).checkpoints, [
		'ASCP:1\n',
		'ASCP:2\n',
		'ASCP:3\n',
		'ASCP:4\n'
	]);
	assert.deepEqual(evaluate([], new Error('private')).checkpoints, ['ASCP:1\n']);
});
assert.equal(passed, 13);
process.stdout.write('Controlled JXA cases: 13 passed, 0 failed; native execution untested\n');
