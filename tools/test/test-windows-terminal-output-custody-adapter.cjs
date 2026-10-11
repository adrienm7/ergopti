// tools/test/test-windows-terminal-output-custody-adapter.cjs

/**
 * MODULE: Guarded Windows Terminal Output Custody Source Gate
 * DESCRIPTION: Check actual native helper bodies, ABI argument widths and
 * independent natural-modifier tables. Never execute AHK, a DLL or native hooks.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ROOT = path.resolve(__dirname, '../..');
const DRIVER = path.join(ROOT, 'static/ergopti_plus/windows');
const PUBLIC = [
	'LLM_NavEventOwner_PlanTerminalOutput',
	'LLM_NavEventOwner_BeginTerminalOutputAttempt',
	'LLM_NavEventOwner_AcknowledgeTerminalOutput',
	'LLM_NavEventOwner_ConsumeTerminalOutput',
	'LLM_NavEventOwner_CancelTerminalOutput'
];
const EXPORTS = [
	'ErgoptiNav_PlanTerminalOutput',
	'ErgoptiNav_BeginTerminalOutputAttempt',
	'ErgoptiNav_AcknowledgeTerminalOutput',
	'ErgoptiNav_ConsumeTerminalOutput',
	'ErgoptiNav_CancelTerminalOutput'
];
// Independent pinned Win32 natural identities, separated by descriptor axis.
const SC = [0x01d, 1, 0x11d, 2, 0x038, 4, 0x138, 8, 0x02a, 16, 0x036, 32, 0x15b, 64, 0x15c, 128];
const VK = [0xa2, 1, 0xa3, 2, 0xa4, 4, 0xa5, 8, 0xa0, 16, 0xa1, 32, 0x5b, 64, 0x5c, 128];

const VALUE_BINDINGS = [
	'AssertThrows(LLM_NavEventOwner_AcknowledgeTerminalOutput.Bind(Handle, Attempt, Prefix))',
	'_LNTOC_WithState(_LNTOC_UnknownPlanVector.Bind(Mutation, 0))',
	'_LNTOC_WithState(_LNTOC_UnknownAttemptVector.Bind(Mutation, 0))',
	'_LNTOC_WithState(_LNTOC_ThrowVector.Bind(Operation))'
];

/**
 * Require actual ABI bindings and independent fail-closed source boundaries.
 * @param {string} source - Guarded production AHK source.
 * @param {string} tests - Independently authored AHK protocol regressions.
 * @returns {void}
 */
function validate(source, tests) {
	for (const name of PUBLIC) {
		assert.match(source, new RegExp(`^${name}\\(`, 'm'), `Missing public custody entry: ${name}`);
	}
	for (const name of EXPORTS) {
		assert.equal(source.split(`"${name}"`).length - 1, 1, `Missing exact native binding: ${name}`);
	}
	const signatures = [
		[
			'_LLM_TerminalOutputNativePlan',
			EXPORTS[0],
			'Owner, Token, Sequence, Text, Length, Key',
			'"UInt64", Owner, "UInt64", Token, "UInt64", Sequence, "Ptr", Text, "UInt", Length, "Ptr", Key, "Int"'
		],
		[
			'_LLM_TerminalOutputNativeBegin',
			EXPORTS[1],
			'Owner, Key, Units, Count, Attempt',
			'"UInt64", Owner, "Ptr", Key, "Ptr", Units, "UInt", 2048, "Ptr", Count, "Ptr", Attempt, "Int"'
		],
		[
			'_LLM_TerminalOutputNativeAcknowledge',
			EXPORTS[2],
			'Owner, Key, Attempt, Accepted',
			'"UInt64", Owner, "Ptr", Key, "UInt64", Attempt, "UInt", Accepted, "Int"'
		]
	];
	const bodyOf = (name, parameters) => {
		const match = source.match(new RegExp(`^${name}\\(([^)]*)\\) \\{\\n([\\s\\S]*?)\\n\\}`, 'm'));
		assert.ok(match, `Missing native helper body: ${name}`);
		assert.equal(match[1], parameters, `Native helper parameters differ: ${name}`);
		const body = match[2].replace(/\s+/g, ' ').trim();
		assert.match(
			body,
			/return DllCall\(_LLM_NavEventOwnerNativeExport\(/,
			`Missing DllCall body: ${name}`
		);
		return body;
	};
	for (const [name, exported, parameters, arguments_] of signatures) {
		assert.equal(
			bodyOf(name, parameters),
			`return DllCall(_LLM_NavEventOwnerNativeExport("${exported}"), ${arguments_})`,
			`Native ABI body differs: ${name}`
		);
	}
	assert.equal(
		bodyOf('_LLM_TerminalOutputNativeRetire', 'Owner, Key, Operation'),
		'Export := Operation == "consume_terminal_output" ? "ErgoptiNav_ConsumeTerminalOutput" : "ErgoptiNav_CancelTerminalOutput" return DllCall(_LLM_NavEventOwnerNativeExport(Export), "UInt64", Owner, "Ptr", Key, "Int")',
		'Native retirement ABI body differs.'
	);
	assert.doesNotMatch(source, /\b(?:SendInput|SendEvent|SendText|SendMessage|PostMessage)\s*\(/);
	assert.doesNotMatch(source, /"(?:delivery_enabled|cohort_complete)"\s*,\s*true/);
	assert.match(source, /Owner := _LLM_NavEventOwnerTerminalRouteOwner/);
	assert.match(source, /Generation := _LLM_NavEventOwnerTerminalRouteGeneration/);
	assert.match(source, /Record\["unknown"\] := true/);
	const maps = source.match(
		/Natural := Route\["axis"\] == 2\s*\? Map\(([^)]*)\)\s*: Map\(([^)]*)\)/
	);
	assert.ok(maps, 'Natural modifier identities require distinct SC and VK tables.');
	const numbers = (text) =>
		[...text.matchAll(/0x[\da-f]+|\b\d+\b/gi)].map((match) => Number(match[0]));
	assert.deepEqual(numbers(maps[1]), SC, 'The SC table borrows a VK identity.');
	assert.deepEqual(numbers(maps[2]), VK, 'The VK table borrows a SC identity.');
	for (const binding of VALUE_BINDINGS)
		assert(
			tests.includes(binding),
			'Every loop vector must bind its current value before invocation.'
		);

	assert.equal(
		(tests.match(/^Test\("terminal output custody:.*\(todo49-output-custody-adapter\)"/gm) || [])
			.length,
		12,
		'Every independently authored native AHK case must remain registered.'
	);
}

const source = fs.readFileSync(path.join(DRIVER, 'adapters/terminal_output_custody.ahk'), 'utf8');
const tests = fs.readFileSync(
	path.join(DRIVER, 'tests/unit/llm_nav_event_owner/test_terminal_output_custody.ahk'),
	'utf8'
);
validate(source, tests);
assert.throws(() => validate('', tests), /Missing public custody entry/);
assert.throws(
	() => validate(source.replace('"ErgoptiNav_AcknowledgeTerminalOutput"', '"WrongAck"'), tests),
	/Missing exact native binding/
);
assert.throws(() => validate(`${source}\nSendInput("x")`, tests));
assert.throws(() =>
	validate(source.replace('"delivery_enabled", false', '"delivery_enabled", true'), tests)
);
assert.throws(() => validate(source.replace('Map(0x01D, 1', 'Map(0xA2, 1'), tests), /SC table/);
assert.throws(() => validate(source.replace('Map(0xA2, 1', 'Map(0x01D, 1'), tests), /VK table/);
assert.throws(() =>
	validate(source, tests.replace(/^Test\("terminal output custody:[^\n]*\n/m, ''))
);
assert.throws(
	() =>
		validate(
			source.replace('"UInt64", Attempt, "UInt", Accepted', '"UInt", Attempt, "UInt", Accepted'),
			tests
		),
	/Native ABI body differs/
);
assert.throws(
	() =>
		validate(
			source.replace(
				'return DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiNav_PlanTerminalOutput")',
				'return FakeCall(_LLM_NavEventOwnerNativeExport("ErgoptiNav_PlanTerminalOutput")'
			),
			tests
		),
	/Missing DllCall body/
);
for (const binding of VALUE_BINDINGS)
	assert.throws(
		() => validate(source, tests.replace(binding, 'RemovedValueBinding()')),
		/loop vector must bind/
	);
console.log(
	'AHK custody source bindings: 5 native ABI bindings, 12 authored cases and 13 negative controls passed.'
);
console.log(
	'Source selection only; all 12 AHK cases and Windows native delivery remain UNRUN here.'
);
