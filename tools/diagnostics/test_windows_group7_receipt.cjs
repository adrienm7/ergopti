// tools/diagnostics/test_windows_group7_receipt.cjs

/** Independent malformed-protocol cases; this does not execute Windows input. */
'use strict';

const assert = require('node:assert/strict');
const { readReceipt, HEADER, COMPLETE } = require('./windows_group7_receipt.cjs');

function fixture(mode = 'idle', sequence = 'ahk-before-native') {
	const rows = [];
	for (const backend of ['SendEvent', 'SendInput']) {
		for (const kind of ['long-text', 'unicode-text', 'clipboard-paste']) {
			for (let index = 1; index <= 3; index++) {
				rows.push(
					`${backend},${kind},${index},1.0000,2.0000,${mode === 'physical' ? '6,6' : '0,0'},${mode},${sequence}`
				);
			}
		}
	}
	return [HEADER, ...rows, COMPLETE, ''].join('\n');
}

let checks = 0;
for (const mode of ['idle', 'physical']) {
	for (const sequence of ['ahk-before-native', 'native-before-ahk']) {
		const result = readReceipt(fixture(mode, sequence), { samples: 3, mode, sequence });
		assert.equal(result.groups.length, 6);
		assert.equal(result.production_qualified, false);
		assert.equal(result.physical_hook_order_qualified, false);
		assert.equal(result.simultaneous_physical_typing_qualified, false);
		checks++;
	}
}
const expected = { samples: 3, mode: 'idle', sequence: 'ahk-before-native' };
const valid = fixture();
const mutations = [
	valid.replace(HEADER, 'invalid header'),
	valid.replace(COMPLETE, 'RETAINED native stop debt'),
	valid.replace('long-text,1,', 'long-text,2,'),
	valid.replace('SendEvent,', 'SendInput,'),
	valid.replace('1.0000,2.0000', '3.0000,2.0000'),
	valid.replace('1.0000', 'NaN'),
	valid.replace('2.0000', 'Infinity'),
	valid.replace('1.0000', '-1.0000'),
	valid.replace('0,0,idle', '1,0,idle'),
	valid.replace('0,0,idle', '6,6,idle'),
	valid.replace('idle,ahk-before-native', 'physical,ahk-before-native'),
	valid.replace('ahk-before-native', 'native-before-ahk'),
	valid.replace('0,0,idle', '0.0,0,idle'),
	valid
		.split('\n')
		.filter((_, index) => index !== 4)
		.join('\n'),
	valid.replace(COMPLETE, 'unexpected line\n' + COMPLETE)
];
for (const bad of mutations) {
	assert.throws(() => readReceipt(bad, expected));
	checks++;
}
assert.throws(() =>
	readReceipt(fixture('physical').replace('6,6,physical', '0,0,physical'), {
		...expected,
		mode: 'physical'
	})
);
checks++;
assert.throws(() =>
	readReceipt(fixture('physical').replace('6,6,physical', '8193,8193,physical'), {
		...expected,
		mode: 'physical'
	})
);
checks++;
console.log(
	`Group 7 receipt verifier: ${checks}/${checks} portable protocol checks passed; Windows not executed.`
);
