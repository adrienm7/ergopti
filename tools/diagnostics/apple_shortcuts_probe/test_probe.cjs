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
				fileHandleWithStandardError: {
					writeData: (data) => checkpoints.push(data.bytes)
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

// The following are explicit native-bridge models, never native permission proof.
function permissionCase(options = {}, args) {
	if (arguments.length < 2) args = ['--permission-preflight'];
	const calls = [],
		markers = [];
	const owner = { descriptorType: 0x62756e64 };
	const pointer = { fixtureOwner: owner };
	let pointerReads = 0;
	Object.defineProperty(owner, 'aeDesc', {
		get() {
			pointerReads++;
			if (options.pointerThrow) throw new Error('PRIVATE POINTER');
			return options.noPointer ? null : pointer;
		}
	});
	const api = {
		NSUTF8StringEncoding: 4,
		NSFileHandle: {
			fileHandleWithStandardError: {
				writeData(data) {
					markers.push(data.bytes);
				}
			}
		},
		NSString: {
			stringWithString(value) {
				return {
					dataUsingEncoding() {
						return { bytes: value, length: Buffer.byteLength(value) };
					}
				};
			}
		},
		kAECoreSuite: 0x636f7265,
		kAEGetData: options.badConstant ? true : 0x67657464,
		typeApplicationBundleID: 0x62756e64,
		NSAppleEventDescriptor: {
			descriptorWithBundleIdentifier(target) {
				calls.push(['descriptor', target]);
				assert.equal(target, 'com.apple.shortcuts.events');
				if (options.noDescriptor) return null;
				if (options.badDescriptor) owner.descriptorType = 0;
				return owner;
			}
		},
		AEDeterminePermissionToAutomateTarget(ref, eventClass, eventID, ask) {
			calls.push(['native', ref, eventClass, eventID, ask]);
			assert.equal(ref, pointer, 'pass the exact retained inner pointer, not an ObjC object');
			assert.equal(ref.fixtureOwner, owner);
			assert.equal(eventClass, 0x636f7265, 'use the SDK core read event class');
			assert.equal(eventID, 0x67657464, 'use the SDK get-data event ID');
			assert.equal(ask, false, 'never prompt to manufacture a preflight result');
			if (options.nativeThrow) throw new Error('PRIVATE NATIVE DETAIL');
			if (options.replaceDescriptor) owner.descriptorType = 0;
			return Object.hasOwn(options, 'code') ? options.code : 0;
		}
	};
	if (options.noFunction) delete api.AEDeterminePermissionToAutomateTarget;
	const context = {
		ObjC: {
			import(name) {
				calls.push(['import', name]);
				assert.ok(['Foundation', 'CoreServices'].includes(name));
				if (name === 'CoreServices' && options.importThrow) throw new Error('PRIVATE IMPORT');
			}
		},
		Application(target) {
			assert.equal(target, 'com.apple.shortcuts.events');
			calls.push(['Application', target]);
			return {
				shortcuts() {
					calls.push(['catalogue']);
					if (options.catalogueThrow) throw new Error('PRIVATE CATALOGUE REFUSAL');
					return [entry('independent-id', 'independent-name')];
				}
			};
		},
		$: api
	};
	vm.createContext(context);
	vm.runInContext(source, context);
	const raw = context.run(args);
	return {
		calls,
		markers,
		raw,
		value: JSON.parse(raw),
		pointerReads,
		owner,
		pointer
	};
}
function onlyPreflight(result) {
	return result.markers.filter((value) => value.startsWith('ASCP:P:'));
}
function originalCatalogue(result) {
	assert.equal(result.calls.filter((value) => value[0] === 'catalogue').length, 2);
	assert.deepEqual(
		result.markers.filter((value) => /^ASCP:[1-4]\n$/.test(value)),
		['ASCP:1\n', 'ASCP:2\n', 'ASCP:3\n', 'ASCP:4\n']
	);
	assert.deepEqual(result.value, {
		version: 1,
		status: 'observed',
		choices: [{ id: 'independent-id', name: 'independent-name', accepts_input: false }],
		truncated: false
	});
}
const beforePermissionTests = passed;
test('same-process bridge keeps exact native descriptor pointer and SDK read event with no prompt', () => {
	const result = permissionCase();
	originalCatalogue(result);
	assert.equal(result.pointerReads, 1);
	assert.deepEqual(onlyPreflight(result), [
		'ASCP:P:BEGIN\n',
		'ASCP:P:CALL_ATTEMPT\n',
		'ASCP:P:RETURN:0\n'
	]);
	const events = result.calls.map((row) => row[0]);
	assert.ok(events.indexOf('native') < events.indexOf('catalogue'));
	assert.equal(result.calls.filter((row) => row[0] === 'Application').length, 1);
});
test('procNotFound permission refusal and other signed32 codes remain observations only', () => {
	for (const code of [-600, -1743, -1744, -2147483648, 2147483647, 71]) {
		const result = permissionCase({ code });
		originalCatalogue(result);
		assert.equal(onlyPreflight(result).at(-1), 'ASCP:P:RETURN:' + code + '\n');
		assert.equal(result.raw.includes('permission'), false);
		assert.equal(result.calls.filter((row) => row[0] === 'native').length, 1);
	}
});
test('native zero cannot fabricate catalogue success or invocation authorization', () => {
	const result = permissionCase({ code: 0 });
	originalCatalogue(result);
	assert.equal(Object.hasOwn(result.value, 'invocation_qualified'), false);
	assert.equal(Object.hasOwn(result.value, 'permission'), false);
	const refused = permissionCase({ code: 0, catalogueThrow: true });
	assert.deepEqual(refused.value, {
		version: 1,
		status: 'refused',
		stage: 1,
		reason: 'native_refused'
	});
	assert.equal(onlyPreflight(refused).at(-1), 'ASCP:P:RETURN:0\n');
	assert.equal(refused.calls.filter((row) => row[0] === 'catalogue').length, 1);
	assert.equal(refused.raw.includes('PRIVATE'), false);
});
test('invalid native types and out-of-range values remain closed diagnostic refusals', () => {
	for (const code of [true, false, '0', 0.25, NaN, Infinity, -2147483649, 2147483648]) {
		const result = permissionCase({ code });
		originalCatalogue(result);
		assert.equal(onlyPreflight(result).at(-1), 'ASCP:P:INVALID\n');
		assert.equal(result.raw.includes('PRIVATE'), false);
	}
});
test('missing native function and SDK constants refuse before descriptor acquisition or C call', () => {
	for (const options of [{ noFunction: true }, { badConstant: true }]) {
		const result = permissionCase(options);
		originalCatalogue(result);
		assert.deepEqual(onlyPreflight(result), ['ASCP:P:BEGIN\n', 'ASCP:P:UNAVAILABLE\n']);
		assert.equal(
			result.calls.filter((row) => row[0] === 'native' || row[0] === 'descriptor').length,
			0
		);
	}
});
test('descriptor refusal or null pointer never calls native API', () => {
	for (const options of [{ noDescriptor: true }, { badDescriptor: true }, { noPointer: true }]) {
		const result = permissionCase(options);
		originalCatalogue(result);
		assert.equal(onlyPreflight(result).at(-1), 'ASCP:P:UNAVAILABLE\n');
		assert.equal(result.calls.filter((row) => row[0] === 'native').length, 0);
	}
});
test('import and pointer getter errors expose no private detail and preserve catalogue calls', () => {
	for (const options of [{ importThrow: true }, { pointerThrow: true }]) {
		const result = permissionCase(options);
		originalCatalogue(result);
		assert.equal(onlyPreflight(result).at(-1), 'ASCP:P:REFUSED\n');
		assert.equal(result.calls.filter((row) => row[0] === 'native').length, 0);
		assert.equal(result.raw.includes('PRIVATE'), false);
	}
});
test('native bridge throw is an attempted refusal rather than returned permission status', () => {
	const result = permissionCase({ nativeThrow: true });
	originalCatalogue(result);
	assert.deepEqual(onlyPreflight(result), [
		'ASCP:P:BEGIN\n',
		'ASCP:P:CALL_ATTEMPT\n',
		'ASCP:P:REFUSED\n'
	]);
});
test('post-call native descriptor lifetime witness refuses changed descriptor', () => {
	const result = permissionCase({ replaceDescriptor: true });
	originalCatalogue(result);
	assert.equal(onlyPreflight(result).at(-1), 'ASCP:P:INVALID\n');
});
test('only the fixed sole argv opts into permission preflight', () => {
	for (const args of [
		undefined,
		[],
		['other'],
		['--permission-preflight', 'extra'],
		'--permission-preflight'
	]) {
		const result = permissionCase({}, args);
		originalCatalogue(result);
		assert.deepEqual(onlyPreflight(result), []);
		assert.equal(result.calls.filter((row) => row[0] === 'native').length, 0);
	}
});
test('permission diagnostics remain fixed content-free markers between checkpoint1 and catalogue', () => {
	const result = permissionCase();
	assert.deepEqual(result.markers, [
		'ASCP:1\n',
		'ASCP:P:BEGIN\n',
		'ASCP:P:CALL_ATTEMPT\n',
		'ASCP:P:RETURN:0\n',
		'ASCP:2\n',
		'ASCP:3\n',
		'ASCP:4\n'
	]);
	assert.equal(
		result.markers.some((value) => value.includes('independent-')),
		false
	);
});
test('native metadata import never binds a guessed ABI or launches target', () => {
	assert.equal(
		/ObjC\.bindFunction|AECreateDesc|\.launch\(|\.activate\(|\.run\(/.test(source),
		false
	);
	assert.ok(source.includes('$.kAECoreSuite') && source.includes('$.kAEGetData'));
});
assert.equal(passed - beforePermissionTests, 12);
process.stdout.write(
	'Permission preflight JXA controls: 12 passed, 0 failed; native execution UNRUN\n'
);
