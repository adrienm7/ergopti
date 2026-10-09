// tools/diagnostics/apple_shortcuts_probe/test_chosen_id.cjs
'use strict';
// Independent SBElementArray mirrors; successful controls do not qualify Darwin.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(
	process.env.CHOSEN_QUERY_SOURCE ||
		path.resolve(__dirname, '../../../static/ergopti_plus/macos/adapters/apple_shortcuts_query.js'),
	'utf8'
);
const ID1 = '11111111-1111-1111-1111-111111111111';
const ID2 = '22222222-2222-2222-2222-222222222222';
const item = (id, name, acceptsInput = false) => ({ id, name, acceptsInput });
function evaluate(rows, argv = ['discover', '1'], options = {}) {
	let countReads = 0,
		indexed = 0,
		selected = 0;
	const collection = {
		get count() {
			countReads++;
			return options.count === undefined ? rows.length : options.count;
		},
		objectAtIndex(index) {
			indexed++;
			return rows[index];
		},
		objectWithID(id) {
			selected++;
			return rows.find((row) => row.id === id) || item(ID2, 'wrong');
		}
	};
	const application = {
		get shortcuts() {
			if (options.throw) throw options.throw;
			return collection;
		},
		get lastError() {
			return options.nativeError || null;
		}
	};
	const context = {
		ObjC: { import: () => {}, unwrap: (value) => value },
		$: {
			SBApplication: {
				applicationWithBundleIdentifier: (id) => {
					assert.equal(id, 'com.apple.shortcuts.events');
					return application;
				}
			},
			NSUTF8StringEncoding: 4,
			NSString: {
				stringWithString: (value) => ({
					dataUsingEncoding: () => ({ length: Buffer.byteLength(value) })
				})
			}
		}
	};
	vm.createContext(context);
	vm.runInContext(source, context);
	const value = JSON.parse(context.run(argv));
	return { value, countReads, indexed, selected };
}
let passed = 0;
function test(name, body) {
	body();
	passed++;
	process.stdout.write('ok ' + name + '\n');
}
test('duplicate Unicode NFD newline names keep distinct IDs', () => {
	const result = evaluate([item(ID1, '日本 e\u0301\n'), item(ID2, '日本 e\u0301\n', true)]);
	assert.deepEqual(result.value, {
		version: 1,
		operation: 'discover',
		nonce: 1,
		status: 'observed',
		rows: [
			{ id: ID1, name: '日本 e\u0301\n', accepts_input: false },
			{ id: ID2, name: '日本 e\u0301\n', accepts_input: true }
		],
		truncated: false
	});
	assert.equal(result.countReads, 2);
	assert.equal(result.indexed, 2);
});
test('catalogue over 256 refuses before any indexed object retrieval', () => {
	const result = evaluate([], undefined, { count: 257 });
	assert.equal(result.value.reason, 'catalogue_limit');
	assert.equal(result.indexed, 0);
});
test('output choices stop at 64 with honest truncation', () => {
	const rows = Array.from({ length: 70 }, (_, index) =>
		item(index.toString(16).padStart(8, '0') + '-1111-1111-1111-111111111111', 'row')
	);
	const result = evaluate(rows);
	assert.equal(result.indexed, 64);
	assert.equal(result.value.rows.length, 64);
	assert.equal(result.value.truncated, true);
});
test('revalidation uses chosen ID twice and never enumerates', () => {
	const result = evaluate([item(ID1, 'same'), item(ID2, 'same')], ['revalidate', '77', ID2]);
	assert.equal(result.value.rows[0].id, ID2);
	assert.equal(result.countReads, 0);
	assert.equal(result.indexed, 0);
	assert.equal(result.selected, 2);
});
test('missing chosen ID refuses a different returned object', () => {
	assert.equal(evaluate([], ['revalidate', '2', ID1]).value.reason, 'missing');
});
test('native NSError permission failure never becomes successful empty inventory', () => {
	assert.equal(
		evaluate([], undefined, { nativeError: { code: -1743 } }).value.reason,
		'automation_permission_refused'
	);
});
test('typed native thrown permission failure is private', () => {
	const result = evaluate([], undefined, {
		throw: Object.assign(new Error('PRIVATE'), { errorNumber: -1743 })
	});
	assert.equal(result.value.reason, 'automation_permission_refused');
	assert.equal(JSON.stringify(result.value).includes('PRIVATE'), false);
});
test('ordinary native errors refuse and never leak exception text', () => {
	const result = evaluate([], undefined, { throw: new Error('PRIVATE') });
	assert.equal(result.value.reason, 'native_refused');
	assert.equal(JSON.stringify(result.value).includes('PRIVATE'), false);
});
test('duplicate IDs refuse independently of display names', () => {
	assert.equal(evaluate([item(ID1, 'one'), item(ID1, 'two')]).value.status, 'refused');
});
test('UTF8 byte cap refuses a multibyte name', () => {
	assert.equal(evaluate([item(ID1, 'é'.repeat(2049))]).value.status, 'refused');
});
test('invalid request refuses before accessing catalogue', () => {
	const result = evaluate([], ['revalidate', '1', '--malicious']);
	assert.equal(result.value.status, 'refused');
	assert.equal(result.selected, 0);
	assert.equal(result.countReads, 0);
});
process.stdout.write(`${passed} controlled chosen-ID JXA cases passed\n`);
