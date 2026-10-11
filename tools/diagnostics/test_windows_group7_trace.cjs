// tools/diagnostics/test_windows_group7_trace.cjs

/**
 * MODULE: Windows Hook Trace Protocol Regression
 * DESCRIPTION: Independent literal diagnostic receipts and refusal controls;
 * never execute native hooks, AHK or a Windows receiving document.
 */
'use strict';
const assert = require('node:assert/strict');
const { readTrace } = require('./windows_group7_trace.cjs');
const expected = { samples: 3, sequence: 'ahk-before-native' };

/** @returns {object[]} Independent protocol fixture with literal ABI identities. */
function fixture() {
	const rows = [
		{
			type: 'start',
			schema: 1,
			owner: '8123',
			token: '901',
			generation: '1',
			qpc_frequency: '10000000',
			requested_install_sequence: expected.sequence,
			mode: 'synthetic',
			fixture_codepoint: 97,
			samples: 3,
			send_level: 31,
			send_marker: '0x00000000FFC3D42E'
		}
	];
	const callbacks = [],
		native = [];
	let caseNumber = 0;
	for (const backend of ['SendEvent', 'SendInput']) {
		for (let sample = 1; sample <= 3; sample++) {
			const caseId = `${backend}-${sample}`,
				first = 1000 + caseNumber++ * 1000;
			rows.push(
				{ type: 'emission', case_id: caseId, backend, phase: 'before', qpc: String(first) },
				{ type: 'emission', case_id: caseId, backend, phase: 'after', qpc: String(first + 20) },
				{
					type: 'receiving',
					case_id: caseId,
					backend,
					value_codepoints: [97],
					qpc: String(first + 200),
					settled: true
				}
			);
			for (const [index, channel] of ['hotif', 'down', 'hotkey', 'char', 'up'].entries()) {
				callbacks.push({
					type: 'ahk',
					sequence: String(callbacks.length + 1),
					qpc: String(first + index + 2),
					channel,
					case_id: caseId,
					...(['down', 'up'].includes(channel) ? { vk: 65, sc: 30 } : {}),
					...(['hotif', 'hotkey'].includes(channel) ? { registered_fixture: 'a' } : {}),
					...(channel === 'char' ? { codepoint: 97 } : {}),
					...(channel === 'hotif' ? { decision: true } : {})
				});
			}
			for (const up of [false, true])
				native.push({
					type: 'native',
					sequence: String(native.length + 1),
					qpc: String(first + (up ? 10 : 1)),
					extra_info: '0x00000000FFC3D42E',
					capture_sequence: '0',
					vk: 65,
					sc: 30,
					flags: up ? 144 : 16,
					time: first + (up ? 1 : 0),
					message: up ? 257 : 256,
					decision: 4,
					reserved: 0
				});
		}
	}
	rows.push(
		...callbacks,
		{
			type: 'page',
			owner: '8123',
			token: '901',
			generation: '1',
			attempted: '12',
			dropped: '0',
			first_sequence: '1',
			last_sequence: '12',
			capacity: 256,
			stored: 12,
			page_offset: 0,
			page_count: 12,
			enabled: 0,
			overflow: 0
		},
		...native,
		{
			type: 'complete',
			native_stop: true,
			inputhook_stop: true,
			trace_stop: true,
			hotkey_stop: true,
			hotif_clear: true,
			hook_order_qualified: false,
			physical_qualified: false,
			production_qualified: false
		}
	);
	return rows;
}

/** @param {object[]} rows Literal records. @returns {string} Exact JSONL. */
function encode(rows) {
	return rows.map((row) => JSON.stringify(row)).join('\n') + '\n';
}
const result = readTrace(encode(fixture()), expected);
assert.equal(result.cases.length, 6);
assert.equal(result.hook_order_qualified, false);
assert.equal(result.physical_qualified, false);
assert.equal(result.production_qualified, false);
assert.equal(result.ahk_attribution_semantics, 'owned-case-and-qpc-window');

// Native SendInput can bypass AHK's removed hook; never turn absent callbacks into PASS.
const unobservedInput = fixture().filter(
	(row) => !(row.type === 'ahk' && row.case_id.startsWith('SendInput-'))
);
const inputAbsent = readTrace(encode(unobservedInput), expected);
assert(
	inputAbsent.cases
		.filter((item) => item.backend === 'SendEvent')
		.every((item) => item.ahk_callback_status === 'PASS')
);
assert(
	inputAbsent.cases
		.filter((item) => item.backend === 'SendInput')
		.every((item) => item.ahk_callback_status === 'UNRUN')
);
assert(inputAbsent.cases.every((item) => item.native_edges.length === 2));
assert.equal(inputAbsent.production_qualified, false);
for (const channel of ['hotif', 'hotkey', 'down', 'char', 'up']) {
	const partial = fixture().filter(
		(row) => !(row.type === 'ahk' && row.case_id === 'SendInput-1' && row.channel === channel)
	);
	let sequence = 0;
	for (const row of partial) if (row.type === 'ahk') row.sequence = String(++sequence);
	assert.throws(() => readTrace(encode(partial), expected), /Missing actual/);
}
for (const type of ['native', 'receiving', 'complete']) {
	const partial = unobservedInput.filter(
		(row, index) => index !== unobservedInput.findIndex((item) => item.type === type)
	);
	assert.throws(() => readTrace(encode(partial), expected));
}

// Reentrant completion order can reverse entry-QPC order. Preserve both honestly.
const reentered = fixture();
const nativeOffset = reentered.findIndex((row) => row.type === 'native');
[reentered[nativeOffset], reentered[nativeOffset + 1]] = [
	reentered[nativeOffset + 1],
	reentered[nativeOffset]
];
reentered[nativeOffset].sequence = '1';
reentered[nativeOffset + 1].sequence = '2';
assert.equal(
	readTrace(encode(reentered), expected).native_sequence_semantics,
	'append-completion-order'
);

const mutations = [
	(rows) => {
		rows[0].mode = 'physical';
	},
	(rows) => {
		rows[0].send_marker = '0x00000000FFC3D44D';
	},
	(rows) => {
		rows[0].owner = '0';
	},
	(rows) => {
		rows[0].qpc_frequency = 10000000;
	},
	(rows) => {
		rows[0].token = '18446744073709551616';
	},
	(rows) => {
		rows.at(-1).production_qualified = true;
	},
	(rows) => {
		rows.at(-1).native_stop = false;
	},
	(rows) => {
		rows.pop();
	},
	(rows) => {
		rows[2].case_id = 'foreign';
	},
	(rows) => {
		rows[2].qpc = '0';
	},
	(rows) => {
		rows[3].value_codepoints = [97, 97];
	},
	(rows) => {
		rows.find((row) => row.type === 'ahk').sequence = '2';
	},
	(rows) => {
		rows.splice(
			rows.findIndex((row) => row.type === 'ahk' && row.channel === 'down'),
			1
		);
	},
	(rows) => {
		rows.find((row) => row.type === 'ahk').qpc = '999999';
	},
	(rows) => {
		rows.find((row) => row.type === 'ahk' && row.channel === 'char').codepoint = 98;
	},
	(rows) => {
		rows.find((row) => row.type === 'ahk' && row.channel === 'hotif').decision = false;
	},
	(rows) => {
		rows.find((row) => row.type === 'page').generation = '2';
	},
	(rows) => {
		rows.find((row) => row.type === 'page').dropped = '1';
	},
	(rows) => {
		rows.find((row) => row.type === 'page').overflow = 1;
	},
	(rows) => {
		rows.find((row) => row.type === 'page').enabled = 1;
	},
	(rows) => {
		rows.find((row) => row.type === 'page').attempted = '13';
	},
	(rows) => {
		rows.find((row) => row.type === 'page').page_count = 11;
	},
	(rows) => {
		rows.find((row) => row.type === 'native').sequence = '2';
	},
	(rows) => {
		rows.find((row) => row.type === 'native').qpc = '999999';
	},
	(rows) => {
		rows.find((row) => row.type === 'native').capture_sequence = '3';
	},
	(rows) => {
		rows.find((row) => row.type === 'native').flags = 0;
	},
	(rows) => {
		rows.find((row) => row.type === 'native').flags = 18;
	},
	(rows) => {
		rows.find((row) => row.type === 'native').decision = 5;
	},
	(rows) => {
		rows.find((row) => row.type === 'native').extra_info = '0x4552475054524D31';
	},
	(rows) => {
		rows.find((row) => row.type === 'native').reserved = 1;
	},
	(rows) => {
		rows.find((row) => row.type === 'native').time = -1;
	},
	(rows) => {
		rows.find((row) => row.type === 'native').flags = 144;
	},
	(rows) => {
		rows.splice(
			rows.findIndex((row) => row.type === 'native'),
			1
		);
	},
	(rows) => {
		rows[0].unexpected = true;
	}
];
// Callback signatures expose Vk/Sc only for InputHook key-down/key-up.
for (const channel of ['char', 'hotif', 'hotkey']) {
	mutations.push((rows) => {
		const row = rows.find((item) => item.type === 'ahk' && item.channel === channel);
		row.vk = 65;
		row.sc = 30;
	});
}
for (const channel of ['down', 'up']) {
	for (const field of ['vk', 'sc'])
		mutations.push((rows) => {
			const row = rows.find((item) => item.type === 'ahk' && item.channel === channel);
			delete row[field];
		});
}
mutations.push((rows) => {
	rows.find((item) => item.type === 'ahk' && item.channel === 'hotkey').registered_fixture = 'b';
});
for (const mutate of mutations) {
	const rows = fixture();
	mutate(rows);
	assert.throws(() => readTrace(encode(rows), expected));
}
assert.throws(
	() => readTrace(encode(fixture()).replace('"schema":1', '"schema":1,"schema":1'), expected),
	/Duplicate/
);
assert.throws(() => readTrace(encode(fixture()).trimEnd(), expected), /newline/);
assert.throws(
	() =>
		readTrace(
			encode(fixture()).replace('"qpc":"1000"', '"qpc":"1000","\\u0071pc":"1000"'),
			expected
		),
	/Noncanonical/
);
assert.throws(
	() => readTrace(encode(fixture()).replace('"qpc":"1000"', '"\\u0071pc":"1000"'), expected),
	/Noncanonical/
);
console.log(
	`Hook trace protocol: 3 independent positive receipts and ${mutations.length + 12} negative controls passed.`
);
console.log('Protocol fixtures only; native callbacks, AHK and physical capture remain UNRUN.');
