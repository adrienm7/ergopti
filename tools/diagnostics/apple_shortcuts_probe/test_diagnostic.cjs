// tools/diagnostics/apple_shortcuts_probe/test_diagnostic.cjs
'use strict';
// Controlled JXA API tests only; this file never produces a native PASS.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(
	__dirname + '/' + (process.env.SHORTCUTS_EVENT_SOURCE || 'discover_diagnostic.js'),
	'utf8'
);
let passed = 0;
function entry(id, name, accepts = false) {
	return { id: () => id, name: () => name, acceptsInput: () => accepts };
}
function evaluate(collections, throws, clock = [0], writeRefusal = false) {
	const modifiers = [];
	let clockIndex = 0;
	let calls = 0;
	const checkpoints = [];
	const collection = function (options) {
		modifiers.push(options);
		calls++;
		if (throws) throw throws;
		return collections[Math.min(calls - 1, collections.length - 1)];
	};
	assert.equal(collection.length, 1, 'the recording getter observes its actual modifier');
	const context = {
		ObjC: { import: (name) => assert.equal(name, 'Foundation') },
		Application: (id) => {
			assert.equal(id, 'com.apple.shortcuts.events');
			return { shortcuts: collection };
		},
		$: {
			NSProcessInfo: {
				processInfo: {
					get systemUptime() {
						return clock[Math.min(clockIndex++, clock.length - 1)];
					}
				}
			},
			NSUTF8StringEncoding: 4,
			NSFileHandle: {
				fileHandleWithStandardError: {
					writeData: (data) => {
						if (writeRefusal && data.bytes.startsWith('ASCD:')) throw new Error('PRIVATE capture');
						checkpoints.push(data.bytes);
					}
				}
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
	const raw = context.run(['20000']);
	return {
		value: JSON.parse(raw),
		raw,
		calls,
		modifiers,
		checkpoints: checkpoints.filter((x) => x.startsWith('ASCP:')),
		diagnostics: checkpoints.filter((x) => x.startsWith('ASCD:')).map((x) => JSON.parse(x.slice(5)))
	};
}
function test(name, fn) {
	fn();
	passed++;
	process.stdout.write('ok ' + name + '\n');
}

test('actual getter receives bounded decreasing timeout modifiers', () => {
	const result = evaluate([[]], undefined, [0, 2, 4]);
	assert.deepEqual(
		result.modifiers.map((x) => x && x.timeout),
		[9, 8],
		'getter_timeout_modifiers_missing'
	);
	assert.equal(result.value.status, 'observed');
});
test('all metadata getters keep the original receiver and receive modifiers', () => {
	const row = {
		id(options) {
			assert.equal(this, row);
			assert.equal(options.timeout, 10);
			return 'fixture-id';
		},
		name(options) {
			assert.equal(this, row);
			assert.equal(options.timeout, 10);
			return 'fixture-name';
		},
		acceptsInput(options) {
			assert.equal(this, row);
			assert.equal(options.timeout, 10);
			return false;
		}
	};
	assert.equal(evaluate([[row]]).value.status, 'observed');
});
test('native integer errors retain refusal and never expose exception text', () => {
	for (const number of [-1712, -1743, 0, 2147483647]) {
		const result = evaluate(
			[],
			Object.assign(new Error('PRIVATE names ids'), { errorNumber: number })
		);
		assert.equal(result.value.status, 'refused');
		assert.equal(
			result.value.reason,
			number === -1743 ? 'automation_permission_refused' : 'native_refused'
		);
		assert.equal(result.raw.includes('PRIVATE'), false);
		const error = result.diagnostics.at(-1);
		assert.equal(error.error_type, 'integer');
		assert.equal(error.error_available, true);
		assert.equal(error.error_number, number, 'native_error_number_lost');
		assert.equal(JSON.stringify(result.diagnostics).includes('PRIVATE'), false);
	}
});
test('wrong types and out-of-range native errors are explicitly unavailable', () => {
	for (const value of ['SECRET', true, null, {}, 1.5, Infinity, 2147483648, undefined]) {
		const result = evaluate([], { errorNumber: value });
		const error = result.diagnostics.at(-1);
		assert.equal(result.value.status, 'refused');
		assert.equal(error.error_available, false);
		assert.equal(error.error_number, 0);
		assert.equal(JSON.stringify(result.diagnostics).includes('SECRET'), false);
	}
});
test('exhausted child clock refuses before a native get', () => {
	const result = evaluate([[]], undefined, [0, 20]);
	assert.equal(result.calls, 0, 'exhausted_event_budget_was_used');
	assert.equal(result.value.status, 'refused');
});
test('observation write failure preserves the original native refusal', () => {
	const result = evaluate([], { errorNumber: -1743 }, [0], true);
	assert.equal(result.value.reason, 'automation_permission_refused');
	assert.equal(result.diagnostics.length, 0, 'missing_observation_is_not_fabricated');
	assert.deepEqual(result.checkpoints, ['ASCP:1\n']);
});
test('healthy event trace contains only closed scalars', () => {
	const result = evaluate([[]]);
	assert.deepEqual(
		result.diagnostics.map((x) => [x.phase, x.stage]),
		[
			['get_entered', 1],
			['get_returned', 1],
			['get_entered', 4],
			['get_returned', 4]
		]
	);
	for (const row of result.diagnostics) {
		assert.deepEqual(Object.keys(row).sort(), [
			'error_available',
			'error_number',
			'error_type',
			'phase',
			'stage'
		]);
		assert.equal(row.error_available, false);
		assert.equal(row.error_type, 'undefined');
	}
});

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
assert.equal(passed, 20);
process.stdout.write(
	'Controlled diagnostic JXA cases: 20 passed, 0 failed; native execution untested\n'
);
