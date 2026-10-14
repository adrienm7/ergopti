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
	validateNaturalZeroCustody(source, tests);
}

/**
 * Bind zero-unit canonical construction to the retained event-time LR receipt.
 * @param {string} source - Actual guarded AHK canonical consumer.
 * @param {string} tests - Literal independent native protocol vectors.
 * @returns {void}
 */
function validateNaturalZeroCustody(source, tests) {
	const match = source.match(
		/^_LLM_TerminalOutputCanonical\(Snapshot, State, Owner, Recipes\) \{\n([\s\S]*?)\n\}/m
	);
	assert.ok(match, 'The actual canonical terminal consumer must exist.');
	const body = match[1].replace(/\s+/g, ' ').trim();
	const zero =
		'if ((Snapshot["modifiers_lr_before"] ^ Snapshot["modifiers_lr_after"]) & Route["effective_modifiers_lr"]) == 0 return Map("text", "", "count", 0, "units", Buffer(0))';
	const offset = body.indexOf(zero);
	assert(offset >= 0, 'Natural zero custody must use the exact retained LR transition.');
	const identityGuard = body.indexOf(
		'throw ValueError("The terminal output modifier is outside its natural subset.")'
	);
	assert(
		identityGuard >= 0 && offset > identityGuard && offset < body.indexOf('Units := Buffer(10, 0)'),
		'Validate the natural identity before constructing either zero or native units.'
	);

	const families = tests.match(
		/for _LNTOC_SharedFamilyIndex, _LNTOC_SharedFamily in \[([\s\S]*?)\]\] \{/
	);
	assert.ok(families, 'The independent shared-natural family census must remain registered.');
	const rows = [...families[1].matchAll(/\[(0x[\dA-F]+), (0x[\dA-F]+), (0x[\dA-F]+)/g)].map((row) =>
		row.slice(1).map(Number)
	);
	assert.deepEqual(
		rows,
		VK.filter((_, i) => i % 2 === 0).map((vk, i) => [vk, SC[i * 2], SC[i * 2 + 1]])
	);
	for (const binding of [
		'for _LNTOC_SharedAxis in [1, 2]',
		'for _LNTOC_SharedOrigin in [1, 2]',
		'for _LNTOC_SharedEdge in [[0, 0], [0, 1], [1, 0]]',
		'_LNTOC_WithState.Bind(_LNTOC_SharedNaturalCase.Bind(_LNTOC_SharedFamily,',
		'_LNTOC_SharedAxis, _LNTOC_SharedOrigin, _LNTOC_SharedEdge[1],',
		'_LNTOC_SharedEdge[2], _LNTOC_SharedFamilyIndex)))',
		'Consumer := TerminalOutputConsumer(901, "none", State.Port, _LNTOC_ForbidSharedNaturalEmission)',
		'AssertEqual(0, Consumer.Handle["unit_count"]',
		'AssertEqual(2, State.Consumes, "A settled edge must never consume the replacement FIFO head.")',
		'for _LNTOC_SharedUnknownMode in ["throw", "untyped"]',
		'_LNTOC_WithState.Bind(_LNTOC_SharedNaturalUnknownCase.Bind(_LNTOC_SharedUnknownMode)))',
		'AssertTrue(Status["unknown"]), AssertEqual(0, Status["unit_count"])',
		'AssertFalse(LLM_NavEventOwner_ConsumeTerminalOutput(Copied))'
	])
		assert(
			tests.includes(binding),
			'Shared-natural custody must retain actual consumer/census bindings.'
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
// These perturbations are source controls, never simulated native AHK results.
assert.throws(
	() =>
		validateNaturalZeroCustody(
			source.replace(
				'Snapshot["modifiers_lr_before"] ^ Snapshot["modifiers_lr_after"]',
				'Snapshot["modifiers_lr_before"] ^ Snapshot["modifiers_lr_before"]'
			),
			tests
		),
	/exact retained LR transition/
);
assert.throws(
	() =>
		validateNaturalZeroCustody(
			source.replace('"count", 0, "units", Buffer(0)', '"count", 1, "units", Buffer(10)'),
			tests
		),
	/exact retained LR transition/
);
assert.throws(() =>
	validateNaturalZeroCustody(source, tests.replace('[0xA3, 0x11D, 0x02]', '[0xA3, 0x11D, 0x01]'))
);
assert.throws(
	() =>
		validateNaturalZeroCustody(
			source,
			tests.replace(
				'_LNTOC_WithState.Bind(_LNTOC_SharedNaturalCase.Bind(_LNTOC_SharedFamily,',
				'RemovedSharedNaturalBinding('
			)
		),
	/consumer\/census bindings/
);

assert.throws(
	() =>
		validateNaturalZeroCustody(
			source.replace(
				'throw ValueError("The terminal output modifier is outside its natural subset.")',
				'return Map("text", "", "count", 0, "units", Buffer(0))'
			),
			tests
		),
	/Validate the natural identity/
);
console.log(
	'Natural modifier canonical custody: 96 matrix cases, 2 uncertain-retirement cases and 5 negative source controls passed.'
);
console.log(
	'AHK custody source bindings: 5 native ABI bindings, 12 authored cases and 13 negative controls passed.'
);
console.log(
	'Source controls only; the retained 23-case AHK output protocol checkpoint and 98 additional authored AHK cases are UNRUN here. Windows native delivery remains UNRUN.'
);

/** Receiving-only controls preserve the old abstract emitter and native marker owner. */
function validatePackets(source, tests, headers, loader) {
	const wrapper = source.slice(
		source.indexOf('class TerminalOutputPacketConsumer'),
		source.indexOf('/** Resolves and retains the exact native FIFO head;')
	);
	assert(
		wrapper.startsWith('class TerminalOutputPacketConsumer extends TerminalOutputConsumer'),
		'Packet receiving reuses the existing consumer.'
	);
	assert.match(wrapper, /super\.__New\(Token, State, Port,/);
	const checks = [
		...wrapper.matchAll(
			/LLM_NavEventOwner_ValidateTerminalOutputPackets\(OriginalHandle, Receipt, Authority\)/g
		)
	];
	assert.equal(checks.length, 2, 'Packets require both pre/post callback validation.');
	const emit = wrapper.indexOf('this.PacketEmitter.Call(Receipt)');
	assert(
		emit > checks[0].index && emit < checks[1].index,
		'Emitter is inside immutable validation.'
	);
	assert.match(
		wrapper,
		/Record\["busy"\] := true[\s\S]*_LLM_TerminalOutputMarkUnknown\(Record, Authority\)[\s\S]*finally \{\s*Record\["busy"\] := false/
	);
	assert.match(
		wrapper,
		/this\.Attempt != Attempt \|\| !\(Accepted is Integer\)[\s\S]*Accepted < 0 \|\| Accepted > Record\["attempt_count"\]/
	);
	assert.match(source, /Attempt != Record\.Get\("owned_attempt", 0\)/);
	assert.match(source, /"serialize_terminal_output_attempt"/);
	assert.match(source, /Packets := Buffer\(81920, 0\), Count := Buffer\(4, 0\)/);
	assert.match(source, /Packets\.Size != 81920 \|\| Count\.Size != 4 \|\| Key\.Size != 24/);
	assert.match(source, /NumGet\(Count, 0, "UInt"\) != Record\["attempt_count"\]/);
	assert.match(source, /ByteCount := Record\["attempt_count"\] \* 40/);
	assert.match(source, /OwnedBytes := Buffer\(ByteCount, 0\)/);
	assert.match(source, /PublicBytes := Buffer\(OwnedBytes\.Size, 0\)/);
	assert.match(
		source,
		/_LLM_TerminalOutputCopyPacketBytes\(OwnedBytes, Packets, Record, "owned", ByteCount, 81920, Handle, Attempt, Key, Authority\)[\s\S]*_LLM_TerminalOutputValidateNativePackets\(OwnedBytes, Record\)[\s\S]*_LLM_TerminalOutputCopyPacketBytes\(PublicBytes, OwnedBytes, Record, "public", ByteCount, ByteCount, Handle, Attempt, Key, Authority\)/
	);
	assert.match(source, /_LLM_TerminalOutputValidateNativePackets\(PublicBytes, Record\)/);
	assert.match(
		source,
		/_LLM_TerminalOutputValidateNativePackets\(Record\["packet_private"\], Record\)/
	);
	assert.match(
		source,
		/Fn := Record\["port"\] is Map\s*\? _LLM_NavEventOwnerPortFn\("observe_terminal_output_packet_copy", Record\["port"\]\) : 0/
	);
	assert.match(
		source,
		/Fn\.Call\("before_" \. Stage, Destination, Source\)[\s\S]*_LLM_TerminalOutputValidateCopyIdentity\(Handle, Record, Attempt, Key, ByteCount, Authority\)[\s\S]*Destination\.Size != ByteCount \|\| Source\.Size != SourceSize[\s\S]*DllCall\("Kernel32\\RtlMoveMemory", "Ptr", Destination, "Ptr", Source, "UPtr", ByteCount\)/
	);
	assert.match(
		source,
		/Fn\.Call\("after_" \. Stage, Destination, Source\)[\s\S]*_LLM_TerminalOutputValidateCopyIdentity\(Handle, Record, Attempt, Key, ByteCount, Authority\)/
	);
	assert.match(source, /Receipt != Record\.Get\("packet_receipt", 0\)/);
	assert.match(source, /Receipt\.Get\("packets", 0\) != Record\["packet_public"\]/);
	assert.match(source, /Record\["packet_public"\]\.Size != Record\["packet_private"\]\.Size/);
	assert.match(source, /Record\["packet_private"\]\.Size != Record\["packet_byte_count"\]/);
	assert.match(source, /Record\["packet_byte_count"\] != Record\["attempt_count"\] \* 40/);
	assert.match(
		source,
		/Loop Record\["packet_private"\]\.Size[\s\S]*NumGet\(Record\["packet_public"\], A_Index - 1, "UChar"\)[\s\S]*!= NumGet\(Record\["packet_private"\], A_Index - 1, "UChar"\)/
	);
	for (const [offset, type, expected] of [
		[0, 'UInt', '1'],
		[4, 'UInt', '0'],
		[8, 'UShort', 'Vk'],
		[10, 'UShort', 'Code'],
		[12, 'UInt', 'Flags'],
		[16, 'UInt64', '0'],
		[24, 'UInt64', '_LLM_TerminalOutputReplayMarker()'],
		[32, 'UInt64', '0']
	]) {
		const base = offset ? `Offset + ${offset}` : 'Offset';
		assert(
			source.includes(`NumGet(Packets, ${base}, "${type}") != ${expected}`),
			`All INPUT bytes require exact validation: ${offset}.`
		);
	}
	assert.match(source, /Scan & 0xFF/);
	assert.match(source, /Scan & 0x100/);
	const nativeMarkers = [
		...headers.matchAll(/^#define ERGOPTI_NAV_TERMINAL_REPLAY_MARKER (0x[0-9a-f]+)ull$/gim)
	];
	assert.equal(nativeMarkers.length, 1, 'Exactly one native replay marker owner.');
	const mirror = source.match(
		/_LLM_TerminalOutputReplayMarker\(\) \{\s*return (0x[0-9a-f]+)\s*\}/i
	);
	assert(mirror, 'Explicit receiving ABI marker mirror.');
	assert.equal(
		BigInt(mirror[1]),
		BigInt(nativeMarkers[0][1]),
		'Receiving marker must match sole native authority.'
	);
	assert.match(
		source,
		/NumGet\(Packets, Offset \+ 24, "UInt64"\) != _LLM_TerminalOutputReplayMarker\(\)/
	);
	assert.match(
		source,
		/_LLM_TerminalOutputNativeSerialize\(Owner, Key, Attempt, Packets, Count\) \{\s*return DllCall\(_LLM_NavEventOwnerNativeExport\("ErgoptiNav_SerializeTerminalOutputAttempt"\),\s*"UInt64", Owner, "Ptr", Key, "UInt64", Attempt, "Ptr", Packets, "UInt", 2048,\s*"Ptr", Count, "Int"\)/
	);
	assert.match(
		loader,
		/"ErgoptiNav_CancelTerminalOutput",\s*"ErgoptiNav_SerializeTerminalOutputAttempt",/
	);
	const serialize = source.slice(
		source.indexOf('LLM_NavEventOwner_SerializeTerminalOutputAttempt(Handle, Attempt) {'),
		source.indexOf('/** Explicit protocol test ports observe')
	);
	const requireBinding = serialize.indexOf(
		'_LLM_TerminalOutputRequireRecord(Handle, Record, Authority)'
	);
	assert(
		requireBinding >= 0 && requireBinding < serialize.indexOf('if !(Status is Integer)'),
		'Native callback identity is checked before every status/refusal/bounds branch.'
	);
	assert.match(
		source,
		/_LLM_TerminalOutputRequireRecord\(Handle, Record, Authority := 0\) \{[\s\S]*Current := _LLM_TerminalOutputRecord\(Handle\)\s*if !IsObject\(Current\) \|\| Current != Record \|\| Authority\["handle"\] != Handle/
	);
	assert.match(source, /Record\["record_id"\] := ObjPtr\(Record\)/);
	assert.match(source, /Record\["record_id"\] != ObjPtr\(Record\)/);
	assert.match(
		wrapper,
		/OriginalHandle := this\.Handle[\s\S]*SerializeTerminalOutputAttempt\(OriginalHandle, Attempt\)[\s\S]*_LLM_TerminalOutputRequireRecord\(OriginalHandle, Record, Authority\)/
	);
	assert.match(wrapper, /this\.Handle != OriginalHandle \|\| this\.Attempt != Attempt/);
	assert.match(source, /_LLM_TerminalOutputUnknown\["record"\] := Record/);
	assert.match(source, /_LLM_TerminalOutputUnknown\["handle"\] := Handle/);
	assert.match(source, /if IsObject\(_LLM_TerminalOutputUnknown\)\s*return 0/);
	assert.match(
		tests,
		/_LNTOC_PacketBindingVector\.Bind\(_LNTOC_PacketBindingPhase,\s*_LNTOC_PacketBindingMutation\)/
	);
	assert.match(tests, /OriginalRecord\.Clone\(\)/);
	assert.match(tests, /AssertTrue\(_LLM_TerminalOutputUnknown\["record"\] == OriginalRecord\)/);
	assert.match(tests, /"ack-throw", "consume", "consume-throw", "cancel"/);
	assert.match(
		source,
		/return Handle is Map && _LLM_TerminalOutputRecords\.Get\(ObjPtr\(Handle\), 0\) == Record/
	);
	assert.equal(
		(wrapper.match(/!_LLM_TerminalOutputBindingCurrent\(OriginalHandle, Record\)/g) || []).length,
		2,
		'Both delegated error paths retain missing original bindings.'
	);
	const acknowledge = source.slice(
		source.indexOf('LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, Accepted) {'),
		source.indexOf('/** Settles exactly one original FIFO edge')
	);
	assert.match(
		acknowledge,
		/if IsObject\(Record\.Get\("packet_receipt", 0\)\)[\s\S]*Attempt != Record\["packet_attempt"\][\s\S]*LLM_NavEventOwner_ValidateTerminalOutputPackets\(Handle, Record\["packet_receipt"\], Authority\)/
	);
	assert.match(
		acknowledge,
		/_LLM_TerminalOutputRequireRecord\(Handle, Record, Authority\)\s*if !\(Status is Integer\)/
	);
	const retirement = source.slice(
		source.indexOf('_LLM_TerminalOutputRetire(Record, Operation, Handle) {'),
		source.indexOf('/** Resolves neutral DOWN')
	);
	assert.match(
		retirement,
		/_LLM_TerminalOutputRequireRecord\(Handle, Record, Authority\)\s*if !\(Status is Integer\)/
	);
	assert(
		acknowledge.indexOf('LLM_NavEventOwner_ValidateTerminalOutputPackets') <
			acknowledge.indexOf('Fn.Call'),
		'Direct ACK cannot bypass immutable packet validation.'
	);
	for (const binding of [
		'_LNTOC_PacketConsumerVector.Bind(_LNTOC_PacketCaseName)',
		'_LNTOC_PacketConsumerVector.Bind(_LNTOC_PacketByteCase)',
		'_LNTOC_PacketNaturalVector.Bind(_LNTOC_PacketAxis,',
		'_LNTOC_PacketForeignReceiptVector.Bind(_LNTOC_PacketForeign)'
	])
		assert(tests.includes(binding), 'Every packet vector binds current values.');
	assert.match(tests, /Loop 40 \{[\s\S]*\["native-byte-", "public-byte-"\]/);
	assert.match(tests, /AssertEqual\(0, State\.Serializes\), AssertEqual\(0, State\.Acks\.Length\)/);
	assert.match(tests, /AssertFalse\(Status\["unknown"\]\), AssertEqual\(0, Status\["accepted"\]\)/);
	assert.match(tests, /"fresh-refusal-retry"/);
	assert.match(tests, /"unknown-string", "unknown-float"/);
}
const markerHeaders = ['nav_event_owner.h', 'terminal_output_plan.h']
	.map((name) => fs.readFileSync(path.join(DRIVER, 'native/nav_event_owner', name), 'utf8'))
	.join('\n');
const packetLoader = fs.readFileSync(path.join(DRIVER, 'adapters/llm_nav_event_owner.ahk'), 'utf8');
validatePackets(source, tests, markerHeaders, packetLoader);
const packetInverses = [
	[
		source.replace(
			'class TerminalOutputPacketConsumer extends TerminalOutputConsumer',
			'class TerminalOutputPacketConsumer'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace(
			'Accepted := this.PacketEmitter.Call(Receipt)',
			'Accepted := OtherEmitter.Call(Receipt)'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace(
			'LLM_NavEventOwner_ValidateTerminalOutputPackets(OriginalHandle, Receipt, Authority)',
			'RemovedPacketValidation()'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace('Record["busy"] := true\n\t\ttry {', 'Record["busy"] := false\n\t\ttry {'),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace('this.Attempt != Attempt || !(Accepted is Integer)', 'false'),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace('Attempt != Record.Get("owned_attempt", 0)', 'false'),
		tests,
		markerHeaders,
		packetLoader
	],
	[source.replace('Packets.Size != 81920', 'Packets.Size < 1'), tests, markerHeaders, packetLoader],
	[
		source.replace('Receipt != Record.Get("packet_receipt", 0)', 'false'),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace('Receipt.Get("packets", 0) != Record["packet_public"]', 'false'),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace(
			'NumGet(Record["packet_private"], A_Index - 1, "UChar")',
			'NumGet(Record["packet_public"], A_Index - 1, "UChar")'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace('NumGet(Packets, Offset + 32, "UInt64") != 0', 'false'),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace('return 0x4552475054524D31', 'return 0x4552475054524D30'),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source,
		tests,
		markerHeaders.replace(/0x4552475054524D31ull/i, '0x4552475054524D30ull'),
		packetLoader
	],
	[
		source,
		tests,
		markerHeaders + '\n#define ERGOPTI_NAV_TERMINAL_REPLAY_MARKER 0x4552475054524D31ull\n',
		packetLoader
	],
	[
		source.replace('"UInt64", Attempt, "Ptr", Packets', '"UInt", Attempt, "Ptr", Packets'),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source,
		tests,
		markerHeaders,
		packetLoader.replace('"ErgoptiNav_SerializeTerminalOutputAttempt",', '')
	],
	[
		source.replace(
			'LLM_NavEventOwner_ValidateTerminalOutputPackets(Handle, Record["packet_receipt"], Authority)',
			'RemovedAckValidation()'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source,
		tests.replace('_LNTOC_PacketConsumerVector.Bind(_LNTOC_PacketByteCase)', 'RemovedByteVector()'),
		markerHeaders,
		packetLoader
	]
];

packetInverses.push(
	[
		source.replace(
			'NumGet(Packets, Offset + 12, "UInt") != Flags',
			'NumGet(Packets, Offset + 12, "UInt") != 0'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace(
			'NumGet(Packets, Offset + 16, "UInt64") != 0',
			'NumGet(Packets, Offset + 16, "UInt64") != 1'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace(
			'NumGet(Packets, Offset + 10, "UShort") != Code',
			'NumGet(Packets, Offset + 10, "UShort") != 0'
		),
		tests,
		markerHeaders,
		packetLoader
	]
);
packetInverses.push(
	[
		source.replace(
			'_LLM_TerminalOutputValidateNativePackets(OwnedBytes, Record)',
			'RemovedOwnedCanonicalValidation()'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace(
			'_LLM_TerminalOutputValidateNativePackets(PublicBytes, Record)',
			'RemovedPublicCanonicalValidation()'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace(
			'_LLM_TerminalOutputValidateNativePackets(Record["packet_private"], Record)',
			'RemovedPrivateCanonicalValidation()'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace('Destination.Size != ByteCount || Source.Size != SourceSize', 'false'),
		tests,
		markerHeaders,
		packetLoader
	],
	[source.replace('Fn := Record["port"] is Map', 'Fn := true'), tests, markerHeaders, packetLoader],
	[
		source.replace(
			'Fn.Call("before_" . Stage, Destination, Source)',
			'RemovedBeforeCopyObserver()'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace('Fn.Call("after_" . Stage, Destination, Source)', 'RemovedAfterCopyObserver()'),
		tests,
		markerHeaders,
		packetLoader
	]
);
packetInverses.push([
	source.replace('Record["packet_private"].Size != Record["packet_byte_count"]', 'false'),
	tests,
	markerHeaders,
	packetLoader
]);
packetInverses.push(
	[
		source.replace(
			'if !IsObject(Current) || Current != Record || Authority["handle"] != Handle',
			'if false'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace('Record["record_id"] != ObjPtr(Record)', 'false'),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace(
			'LLM_NavEventOwner_SerializeTerminalOutputAttempt(OriginalHandle, Attempt)',
			'LLM_NavEventOwner_SerializeTerminalOutputAttempt(this.Handle, Attempt)'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replaceAll(
			'this.Handle != OriginalHandle || this.Attempt != Attempt',
			'this.Attempt != Attempt'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace(
			'_LLM_TerminalOutputUnknown["record"] := Record',
			'RemovedOriginalRecordRetention()'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace(
			'if IsObject(_LLM_TerminalOutputUnknown)\n\t\treturn 0',
			'if false\n\t\treturn 0'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source,
		tests.replace(
			'_LNTOC_PacketBindingVector.Bind(_LNTOC_PacketBindingPhase,',
			'RemovedBindingVector('
		),
		markerHeaders,
		packetLoader
	],
	[
		source.replace(
			'_LLM_TerminalOutputRequireRecord(Handle, Record, Authority)\n\t\tif !(Status is Integer)',
			'RemovedPostCallbackIdentity()\n\t\tif !(Status is Integer)'
		),
		tests,
		markerHeaders,
		packetLoader
	]
);
const serializeStart = source.indexOf(
	'LLM_NavEventOwner_SerializeTerminalOutputAttempt(Handle, Attempt) {'
);
const serializeEnd = source.indexOf('/** Explicit protocol test ports observe');
packetInverses.push(
	[
		source.slice(0, serializeStart) +
			source
				.slice(serializeStart, serializeEnd)
				.replace(
					'_LLM_TerminalOutputRequireRecord(Handle, Record, Authority)',
					'RemovedPostNativeBinding()'
				) +
			source.slice(serializeEnd),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.slice(0, source.indexOf('_LLM_TerminalOutputRetire(Record, Operation, Handle) {')) +
			source
				.slice(source.indexOf('_LLM_TerminalOutputRetire(Record, Operation, Handle) {'))
				.replace(
					'_LLM_TerminalOutputRequireRecord(Handle, Record, Authority)',
					'RemovedPostRetirementBinding()'
				),
		tests,
		markerHeaders,
		packetLoader
	]
);
packetInverses.push(
	[
		source.replace(
			'return Handle is Map && _LLM_TerminalOutputRecords.Get(ObjPtr(Handle), 0) == Record',
			'return true'
		),
		tests,
		markerHeaders,
		packetLoader
	],
	[
		source.replace('!_LLM_TerminalOutputBindingCurrent(OriginalHandle, Record)', 'false'),
		tests,
		markerHeaders,
		packetLoader
	]
);
for (const [index, candidate] of packetInverses.entries())
	assert.throws(
		() => validatePackets(...candidate),
		undefined,
		`Packet inverse ${index} must reject.`
	);
console.log(
	`Packet receiving source controls: ${packetInverses.length} meaningful inverses passed; authored AHK behavior/native Windows remain UNRUN.`
);

// Original unknown custody must use only private pre-callback holder/key evidence.
function validateFrozenAuthority(candidate) {
	assert.equal(
		(candidate.match(/!_LLM_TerminalOutputAuthorityCurrent\(Authority, Record\)/g) || []).length,
		5
	);
	const capture = candidate.slice(
		candidate.indexOf('_LLM_TerminalOutputCaptureAuthority(Handle, Record) {'),
		candidate.indexOf('/** Private pre-callback evidence')
	);
	assert.match(capture, /Current := _LLM_TerminalOutputRecord\(Handle\)/);
	assert.match(capture, /Current != Record \|\| Record\["handle"\] != Handle/);
	assert.match(
		capture,
		/return Map\("handle", Handle, "owner", Record\["owner"\], "token", Record\["token"\]/
	);
	assert.match(capture, /"key", _LLM_TerminalOutputKey\(Record\)/);
	const unknown = candidate.slice(
		candidate.indexOf('_LLM_TerminalOutputMarkUnknown(Record, Authority := 0) {'),
		candidate.indexOf('/** Pins the ABI mirror')
	);
	assert.match(unknown, /Handle := Authority\["handle"\]/);
	assert.match(
		unknown,
		/Authority\["owner"\], Authority\["token"\], Authority\["sequence"\], Authority\["key"\]/
	);
	assert.doesNotMatch(
		unknown,
		/Record\["owner"\]|Record\["token"\]|Record\["sequence"\]|_LLM_TerminalOutputKey\(Record\)/
	);
	assert.match(unknown, /!_LLM_TerminalOutputAuthorityCurrent\(Authority, Record\)/);
	assert.match(unknown, /if !IsObject\(_LLM_TerminalOutputUnknown\)/);
	assert.match(candidate, /Record\.Get\("handle", 0\) != Authority\["handle"\]/);
	assert.match(
		candidate,
		/for Name in \["owner", "token", "sequence", "plan_id", "unit_count"\]\s+if !\(Record\.Get/
	);
	for (const [begin, end] of [
		['LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle) {', '/** Reports caller-observed'],
		[
			'LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, Accepted) {',
			'/** Settles exactly'
		],
		['_LLM_TerminalOutputRetire(Record, Operation, Handle) {', '/** Resolves neutral'],
		[
			'LLM_NavEventOwner_SerializeTerminalOutputAttempt(Handle, Attempt) {',
			'/** Explicit protocol test ports'
		]
	]) {
		const body = candidate.slice(
			candidate.indexOf(begin),
			candidate.indexOf(end, candidate.indexOf(begin))
		);
		const captured = body.indexOf(
			'Authority := _LLM_TerminalOutputCaptureAuthority(Handle, Record)'
		);
		assert.ok(
			captured >= 0 && captured < body.indexOf('Fn.Call'),
			`${begin}: capture before foreign native port.`
		);
		assert.match(body, /_LLM_TerminalOutputMarkUnknown\(Record, Authority\)/);
		assert.match(body, /_LLM_TerminalOutputRequireRecord\(Handle, Record, Authority\)/);
	}
	assert.match(
		candidate,
		/_LLM_TerminalOutputCopyPacketBytes\(Destination, Source, Record, Stage, ByteCount, SourceSize, Handle, Attempt, Key, Authority\)/
	);
	assert.match(
		candidate,
		/_LLM_TerminalOutputValidateCopyIdentity\(Handle, Record, Attempt, Key, ByteCount, Authority\)/
	);
	assert.match(
		candidate,
		/Authority := _LLM_TerminalOutputCaptureAuthority\(OriginalHandle, Record\)\s+try \{\s+Receipt := LLM_NavEventOwner_Serialize/
	);
	const emit = candidate.slice(
		candidate.indexOf('\t_EmitPackets(Attempt)'),
		candidate.indexOf('/** Resolves and retains')
	);
	assert.equal(
		(emit.match(/ValidateTerminalOutputPackets\(OriginalHandle, Receipt, Authority\)/g) || [])
			.length,
		2
	);
}
validateFrozenAuthority(source);
const frozenInverses = [
	[
		'original handle capture',
		'Current != Record || Record["handle"] != Handle',
		'Current != Record'
	],
	[
		'detached key capture',
		'"key", _LLM_TerminalOutputKey(Record)',
		'"key", Record["packet_private"]'
	],
	['retained original holder', 'Handle := Authority["handle"]', 'Handle := Record["handle"]'],
	[
		'retained original tuple',
		'Authority["owner"], Authority["token"], Authority["sequence"], Authority["key"]',
		'Record["owner"], Record["token"], Record["sequence"], _LLM_TerminalOutputKey(Record)'
	],
	['missing handle field', 'Record.Get("handle", 0) != Authority["handle"]', 'false'],
	['changed live holder', '!_LLM_TerminalOutputAuthorityCurrent(Authority, Record)', 'false'],
	[
		'serialized callback evidence',
		'Authority := _LLM_TerminalOutputCaptureAuthority(Handle, Record)\n\tRecord["busy"] := true',
		'Authority := 0\n\tRecord["busy"] := true'
	],
	[
		'emitter callback evidence',
		'Authority := _LLM_TerminalOutputCaptureAuthority(OriginalHandle, Record)\n\t\ttry {\n\t\t\tReceipt :=',
		'Authority := 0\n\t\ttry {\n\t\t\tReceipt :='
	]
];
for (const [name, before, after] of frozenInverses) {
	const mutant = source.replace(before, after);
	assert.notEqual(mutant, source, `Withdraw actual ${name}.`);
	assert.throws(() => validateFrozenAuthority(mutant), { code: 'ERR_ASSERTION' }, name);
	validateFrozenAuthority(source);
}
assert.ok(tests.includes('_LNTOC_FrozenAuthorityVector.Bind(_LNTOC_AuthorityPhase,'));
assert.ok(tests.includes('AssertTrue(_LLM_TerminalOutputUnknown["handle"] == Handle'));
assert.ok(tests.includes('NumGet(OriginalKey, A_Index - 1, "UChar")'));
process.stdout.write(
	'Frozen terminal authority: PASS (8 causal source inverses; 123 new authored AHK cases UNRUN).\n'
);

// Explicit SendInput is one caller-selected primitive, never a backend policy.
const explicitSender = fs.readFileSync(
	path.join(DRIVER, 'adapters/terminal_output_sendinput.ahk'),
	'utf8'
);
function validateExplicitSender(sender, receivingTests) {
	assert.match(sender, /Authority := _LLM_TerminalOutputCaptureAuthority\(Handle, Record\)/);
	assert.match(sender, /if Record\.Get\("handle", 0\) != Handle/);
	assert.match(sender, /LLM_NavEventOwner_TerminalOutputSendInputEmitter\(Handle, SendInputFn\)/);
	assert.match(sender, /if !HasMethod\(SendInputFn, "Call"\)\s+throw ValueError/);
	assert.match(
		sender,
		/return _LLM_TerminalOutputSendInputOwned\.Bind\(Handle, Record, SendInputFn, Authority\)/
	);
	assert.doesNotMatch(
		sender,
		/SendInputFn :=|SendEvent\(|delivery_enabled[^\n]*:= true|cohort_complete[^\n]*:= true/
	);
	assert.doesNotMatch(
		sender,
		/AcknowledgeTerminalOutput|CancelTerminalOutput|ConsumeTerminalOutput/
	);
	assert.match(sender, /_LLM_TerminalOutputRequireRecord\(Handle, Record, Authority\)/);
	assert.match(sender, /Attempt := Record\["owned_attempt"\]\s+Count := Record\["attempt_count"\]/);
	assert.match(sender, /if !\(Count is Integer\) \|\| Count < 1 \|\| Count > 2048/);
	assert.match(
		sender,
		/ByteCount := Count \* 40\s+Key := _LLM_TerminalOutputKey\(Record\)\s+Witness := Buffer\(ByteCount, 0\)/
	);
	const body = sender.slice(
		sender.indexOf('_LLM_TerminalOutputSendInputOwned(Handle,'),
		sender.indexOf('/** Pins custody')
	);
	assert.match(
		body,
		/try \{\s+_LLM_TerminalOutputRequireRecord\(Handle, Record, Authority\)\s+LLM_NavEventOwner_ValidateTerminalOutputPackets\(Handle, Receipt, Authority\)/
	);
	const send = body.indexOf('Accepted := SendInputFn.Call(Count, EmittedBytes, 40)');
	const checks = [
		...body.matchAll(
			/_LLM_TerminalOutputSendInputBytes\(Handle, Record, Attempt, Receipt, Key, Count, ByteCount, Witness, EmittedBytes, Authority\)/g
		)
	];
	assert.equal(checks.length, 2);
	assert.ok(
		checks[0].index < send && send < checks[1].index,
		'Native callback is enclosed by detached-byte custody validation.'
	);
	const witnessCopy = body.indexOf(
		'"Ptr", Witness.Ptr, "Ptr", Record["packet_private"].Ptr, "UPtr", ByteCount'
	);
	const detachedCheck = body.indexOf('_LLM_TerminalOutputValidateNativePackets(Witness, Record)');
	const publicCopy = body.indexOf('"Ptr", EmittedBytes.Ptr, "Ptr", Witness.Ptr, "UPtr", ByteCount');
	assert.ok(
		witnessCopy >= 0 && detachedCheck > witnessCopy && publicCopy > detachedCheck,
		'Validate private detached bytes after first copy and before publication.'
	);
	assert.match(
		body,
		/if !\(Accepted is Integer\) \|\| Accepted < 0 \|\| Accepted > Count\s+throw ValueError/
	);
	assert.match(
		body,
		/catch as Err \{[\s\S]*_LLM_TerminalOutputMarkUnknown\(Record, Authority\)\s+throw Err/
	);
	assert.match(
		sender,
		/_LLM_TerminalOutputValidateCopyIdentity\(Handle, Record, Attempt, Key, ByteCount, Authority\)/
	);
	assert.match(
		sender,
		/LLM_NavEventOwner_ValidateTerminalOutputPackets\(Handle, Receipt, Authority\)/
	);
	assert.match(
		sender,
		/if !\(Record\["attempt_count"\] is Integer\) \|\| Record\["attempt_count"\] != Count/
	);
	assert.match(
		sender,
		/Record\["packet_private"\]\.Size != ByteCount \|\| Record\["packet_public"\]\.Size != ByteCount/
	);
	assert.match(sender, /if Witness\.Size != ByteCount \|\| EmittedBytes\.Size != ByteCount/);
	assert.match(sender, /_LLM_TerminalOutputValidateNativePackets\(Witness, Record\)/);
	assert.match(sender, /_LLM_TerminalOutputValidateNativePackets\(EmittedBytes, Record\)/);
	assert.match(
		sender,
		/Loop ByteCount \{\s+Byte := NumGet\(Witness, A_Index - 1, "UChar"\)\s+if NumGet\(EmittedBytes, A_Index - 1, "UChar"\) != Byte\s+\|\| NumGet\(Record\["packet_private"\], A_Index - 1, "UChar"\) != Byte/
	);
	assert.match(
		sender,
		/if A_PtrSize != 8 \|\| !\(Count is Integer\) \|\| Count < 0 \|\| Count > 2048/
	);
	assert.match(sender, /!\(PacketSize is Integer\) \|\| PacketSize != 40/);
	assert.match(sender, /!\(Packets is Buffer\) \|\| Packets\.Size != Count \* PacketSize/);
	assert.match(
		sender,
		/if Count == 0\s+return 0\s+return DllCall\("User32\\SendInput", "UInt", Count, "Ptr", Packets\.Ptr, "Int", PacketSize, "UInt"\)/
	);
	assert.ok(
		receivingTests.includes(
			String.raw`#Include %A_LineFile%\..\..\..\..\adapters\terminal_output_sendinput.ahk`
		)
	);
	for (const caseName of [
		'full',
		'partial',
		'zero',
		'zero-cancel',
		'surrogate',
		'reentry',
		'ack-refusal',
		'ack-throw',
		'serialize-refusal',
		'throw',
		'string',
		'float',
		'negative',
		'overflow',
		'equal-forgery',
		'record-remove',
		'record-replace',
		'handle-clone'
	]) {
		assert.ok(
			receivingTests.includes(
				`Test("terminal explicit SendInput: ${caseName} (todo49-explicit-sendinput)"`
			),
			caseName
		);
	}
	for (let offset = 0; offset < 80; offset++) {
		assert.ok(
			receivingTests.includes(`_LNTOC_SendInputVector.Bind("emit-byte-${offset}")`),
			`Detached byte ${offset} is authored.`
		);
	}
	assert.ok(receivingTests.includes('Original["owned_attempt"]["units"][1]["utf16"] := 0x62'));
	assert.match(
		receivingTests,
		/_LNTOC_SendInputNaturalCase[\s\S]*AssertEqual\(0, Calls\), AssertEqual\(0, State\.Begins\)/
	);
	assert.match(
		receivingTests,
		/_LNTOC_SharedNaturalState\(Family, Axis, Origin, Up, Repeat, Index\)/
	);
}
validateExplicitSender(explicitSender, tests);
const senderInverses = [
	['mandatory explicit sender', 'if !HasMethod(SendInputFn, "Call")', 'if false'],
	[
		'bound original record',
		'.Bind(Handle, Record, SendInputFn, Authority)',
		'.Bind(Handle, OtherRecord, SendInputFn)'
	],
	['owned attempt', 'Attempt := Record["owned_attempt"]', 'Attempt := Record["packet_attempt"]'],
	[
		'original record identity',
		'_LLM_TerminalOutputRequireRecord(Handle, Record, Authority)',
		'_LLM_TerminalOutputRecord(Handle)'
	],
	[
		'private copy source',
		'"Ptr", Witness.Ptr, "Ptr", Record["packet_private"].Ptr',
		'"Ptr", Witness.Ptr, "Ptr", Receipt["packets"].Ptr'
	],
	[
		'detached canonical check',
		'_LLM_TerminalOutputValidateNativePackets(Witness, Record)',
		'_LLM_TerminalOutputValidateNativePackets(EmittedBytes, Record)'
	],
	[
		'pre/post send check',
		'Accepted := SendInputFn.Call(Count, EmittedBytes, 40)',
		'Accepted := SendInputFn.Call(Count, Receipt["packets"], 40)'
	],
	[
		'typed prefix',
		'if !(Accepted is Integer) || Accepted < 0 || Accepted > Count',
		'if Accepted < 0 || Accepted > Count'
	],
	[
		'retained unknown debt',
		'_LLM_TerminalOutputMarkUnknown(Record, Authority)',
		'_LLM_TerminalOutputRecord(Handle)'
	],
	[
		'original key snapshot',
		'_LLM_TerminalOutputValidateCopyIdentity(Handle, Record, Attempt, Key, ByteCount, Authority)',
		'_LLM_TerminalOutputValidateAttempt(Record, Attempt)'
	],
	[
		'receipt validator',
		'LLM_NavEventOwner_ValidateTerminalOutputPackets(Handle, Receipt, Authority)',
		'_LLM_TerminalOutputValidateNativePackets(Receipt["packets"], Record)'
	],
	['typed retained count', '!(Record["attempt_count"] is Integer)', 'false'],
	['detached bounds', 'if Witness.Size != ByteCount || EmittedBytes.Size != ByteCount', 'if false'],
	[
		'immutable witness',
		'Byte := NumGet(Witness, A_Index - 1, "UChar")',
		'Byte := NumGet(EmittedBytes, A_Index - 1, "UChar")'
	],
	['Win64 size', 'if A_PtrSize != 8', 'if A_PtrSize != 4'],
	['native capacity', 'Count < 0 || Count > 2048', 'Count < 0 || Count > 4096'],
	['zero native calls', 'if Count == 0\n\t\treturn 0', 'if false\n\t\treturn 0'],
	['API ABI', '"Int", PacketSize, "UInt")', '"Int", PacketSize, "Int")']
];
for (const [name, before, after] of senderInverses) {
	const mutant = explicitSender.replace(before, after);
	assert.notEqual(mutant, explicitSender, `Withdraw actual ${name}.`);
	assert.throws(() => validateExplicitSender(mutant, tests), { code: 'ERR_ASSERTION' }, name);
	validateExplicitSender(explicitSender, tests);
}
process.stdout.write(
	'Explicit terminal SendInput primitive: PASS (18 causal source inverses; 211 additional authored AHK cases UNRUN).\n'
);

const handleMutant = explicitSender.replace('if Record.Get("handle", 0) != Handle', 'if false');
assert.notEqual(handleMutant, explicitSender);
assert.throws(() => validateExplicitSender(handleMutant, tests), { code: 'ERR_ASSERTION' });
const authorityMutant = explicitSender.replace(
	'Authority := _LLM_TerminalOutputCaptureAuthority(Handle, Record)',
	'Authority := 0'
);
assert.notEqual(authorityMutant, explicitSender);
assert.throws(() => validateExplicitSender(authorityMutant, tests), { code: 'ERR_ASSERTION' });
const nativeReceivingFixture = fs.readFileSync(
	path.join(DRIVER, 'tests/fixtures/terminal_output_sendinput_receiving_fixture.ahk'),
	'utf8'
);
function validateNativeReceivingFixture(fixture) {
	assert.match(
		fixture,
		/if A_Args\.Length != 1 \|\| A_Args\[1\] != "--allow-explicit-user32-sendinput" \{\s+FileAppend[\s\S]*ExitApp\(2\)/
	);
	assert.ok(
		fixture.indexOf('ExitApp(2)') < fixture.indexOf('Gui("'),
		'Argument refusal precedes all GUI/input admission.'
	);
	assert.match(fixture, /A_AhkVersion != "2\.0\.26" \|\| A_PtrSize != 8/);
	assert.match(fixture, /Owner\["pid"\] != _TSIF\.Pid \|\| Child\["pid"\] != _TSIF\.Pid/);
	assert.match(
		fixture,
		/Owner\["thread"\] != _TSIF\.Thread \|\| Child\["thread"\] != _TSIF\.Thread/
	);
	assert.match(fixture, /GetForegroundWindow[\s\S]*GetFocus/);
	assert.match(fixture, /InstallKeybdHook\(\)/);
	assert.match(
		fixture,
		/GetKeyState\(Key, "P"\) \|\| \(DllCall\("GetAsyncKeyState", "Int", Vk, "Short"\) & 0x8000\)/
	);
	assert.match(
		fixture,
		/_TSIF_SelectedNative\(Count, Packets, Size\) \{\s+global _TSIF\s+_TSIF_Admit\(\)\s+_TSIF\.Debt := true[\s\S]*Accepted := _LLM_TerminalOutputSendInputNative\(Count, Packets, Size\)\s+_TSIF_Admit\(\)\s+return Accepted/
	);
	assert.match(fixture, /if !Consumer\.Service\(\) \|\| !Consumer\.Retired/);
	assert.match(fixture, /AssertEqual\(Expected, _TSIF\.Editor\.Value[\s\S]*_TSIF\.Debt := false/);
	assert.match(fixture, /if _TSIF\.Debt \{[\s\S]*natural_exit=false[\s\S]*return 1/);
	assert.match(fixture, /if _TSIF\.Debt \{\s+Persistent\(\)\s+return/);
	assert.match(
		fixture,
		/native_fifo_qualified=false production_qualified=false backend_policy_changed=false/
	);
	assert.doesNotMatch(
		fixture,
		/RunTests\(\)|SendEvent\(|ProcessClose\(|TerminateProcess|cohort_complete[^\n]*:= true/
	);
}
validateNativeReceivingFixture(nativeReceivingFixture);
const fixtureInverses = [
	[
		'explicit opt-in',
		'if A_Args.Length != 1 || A_Args[1] != "--allow-explicit-user32-sendinput"',
		'if false'
	],
	['original receiver pid', 'Owner["pid"] != _TSIF.Pid || Child["pid"] != _TSIF.Pid', 'false'],
	[
		'physical modifiers',
		'GetKeyState(Key, "P") || (DllCall("GetAsyncKeyState", "Int", Vk, "Short") & 0x8000)',
		'false'
	],
	[
		'pre native target',
		'_TSIF_SelectedNative(Count, Packets, Size) {\n\tglobal _TSIF\n\t_TSIF_Admit()',
		'_TSIF_SelectedNative(Count, Packets, Size) {\n\tglobal _TSIF\n\tSleep(0)'
	],
	[
		'post native target',
		'Size)\n\t_TSIF_Admit()\n\treturn Accepted',
		'Size)\n\tSleep(0)\n\treturn Accepted'
	],
	['natural unknown retention', 'Persistent()\n\t\treturn', 'ExitApp(1)\n\t\treturn']
];
for (const [name, before, after] of fixtureInverses) {
	const mutant = nativeReceivingFixture.replace(before, after);
	assert.notEqual(mutant, nativeReceivingFixture, `Withdraw actual ${name}.`);
	assert.throws(() => validateNativeReceivingFixture(mutant), { code: 'ERR_ASSERTION' }, name);
	validateNativeReceivingFixture(nativeReceivingFixture);
}
process.stdout.write(
	'Explicit original-handle/native fixture source controls: PASS (2 holder + 6 receiving inverses; all native execution UNRUN).\n'
);

/** Capture metadata does not authenticate caller events or consume native FIFO. */
function validateKleResetObserver(kle, authored) {
	const capture = kle.slice(
		kle.indexOf('KeylayoutEmulation_CaptureResetObserver(Sc) {'),
		kle.indexOf('_KLE_Emit(Sc, Shift, Option) {')
	);
	assert(capture.startsWith('KeylayoutEmulation_CaptureResetObserver(Sc) {'));
	assert.match(capture, /Factory := _KLE_ResetObserverCapture/);
	assert.match(
		capture,
		/Factory is BoundFunc && !Object\.Prototype\.HasOwnProp\.Call\(Factory, "Call"\)/
	);
	assert.match(
		capture,
		/if !_KLE_ResetObserverPlainMap\(Cohort\) \|\| !_KLE_ResetObserverPlainMap\(Binding\)/
	);
	assert.match(capture, /ObjGetBase\(Value\) != Map\.Prototype/);
	assert.match(capture, /Object\.Prototype\.HasOwnProp\.Call\(Value, Name\)/);
	assert.match(capture, /Cohort != OwnedCohort/);
	assert.match(capture, /Cohort\.Get\("bindings", 0\) != OwnedBindings/);
	assert.match(capture, /ExpectedBindings\.Get\(Sc, 0\) != Binding/);
	assert.match(capture, /_KLE_ResetObserverGeneration != Proof\["generation"\]/);
	assert.match(capture, /_KLE_ResetObserverCapture != Proof\["factory"\]/);
	assert.match(capture, /KLE_Model != Proof\["model"\]/);
	assert.match(capture, /!\(KLE_State == Proof\["state"\]\)/);
	assert.match(capture, /Proof\["bindings"\]\.Get\(Proof\["scan"\], 0\) != Binding/);
	assert.match(
		capture,
		/Binding\.Get\(Name, 0\) != Proof\[Name\] \|\| !HasMethod\(Proof\[Name\], "Call"\)/
	);
	assert.match(
		capture,
		/if !_KLE_ResetObserverCurrent\(Proof\)[\s\S]*try Active := Proof\["criterion"\]\.Call\(\)[\s\S]*if !\(Active is Integer\) \|\| Active != 1 \|\| !_KLE_ResetObserverCurrent\(Proof\)/
	);
	assert.match(capture, /return _KLE_StepCapturedResetObserver\.Bind\(Proof\)/);
	assert.match(
		capture,
		/Value := Event\[Name\][\s\S]*if !\(Value is Integer\)[\s\S]*CapturedEvent\[Name\] := Value/
	);
	assert.match(capture, /CapturedEvent\["origin"\] < 1 \|\| CapturedEvent\["origin"\] > 2/);
	assert.match(
		capture,
		/CapturedEvent\["key_up"\] != 0 \|\| CapturedEvent\["repeat"\] < 0 \|\| CapturedEvent\["repeat"\] > 1/
	);
	assert.match(
		capture,
		/Next := _KLE_ResetDeadKeyTransition\(\)[\s\S]*if !\(Next == Proof\["neutral"\]\) \|\| !_KLE_ResetObserverCurrent\(Proof\)/
	);
	assert.match(
		capture,
		/"metadata_only", true,[\s\S]*"cohort_complete", false, "transformed_output_enabled", false,[\s\S]*"native_consumed", false/
	);
	assert.doesNotMatch(capture, /\b(?:SendInput|SendEvent|SendNewResult|DllCall)\(/);
	assert.doesNotMatch(capture, /KLE_State\s*:=/);
	const registration = kle.slice(
		kle.indexOf('KeylayoutEmulation_Register(KeycodeTable,'),
		kle.indexOf('_KLE_DefaultBootDeps() {')
	);
	assert.match(
		registration,
		/if IsObject\(_KLE_ResetObserverRegistering\) \{[\s\S]*_KLE_ResetObserverRegistering\["invalid"\] := true[\s\S]*throw Error\("Layout emulation registration is already in progress\."\)/
	);
	assert.match(registration, /_KLE_ResetObserverCohort := 0, _KLE_ResetObserverCapture := 0/);
	assert.match(
		registration,
		/ResetCriterion := _KLE_PendingDeadKeyCriterion[\s\S]*HotIfFn\.Call\(ResetCriterion\)/
	);
	assert.match(
		registration,
		/"callback", KeylayoutEmulation_ResetDeadKey,[\s\S]*"criterion", ResetCriterion, "options", KLE_INPUT_LEVEL\)[\s\S]*HotkeyFn\.Call\(Binding\["name"\], Binding\["callback"\], Binding\["options"\]\)[\s\S]*Registration\["bindings"\]\[Key\] := Binding/
	);
	assert.match(
		registration,
		/try HotIfFn\.Call\(\)[\s\S]*finally \{[\s\S]*try Critical\(_AtCrit\)[\s\S]*finally \{[\s\S]*if _KLE_ResetObserverRegistering != Guard[\s\S]*Guard\["invalid"\] := true[\s\S]*_KLE_ResetObserverRegistering := 0/
	);
	assert.match(
		registration,
		/if !Guard\["invalid"\] && Registration\["bindings"\]\.Count == KLE_DEAD_RESET_KEYS\.Length/
	);
	assert.match(
		registration,
		/_KLE_ResetObserverCapture := _KLE_CaptureResetObserverOwned\.Bind\(Registration,[\s\S]*Registration\["bindings"\], Registration\["bindings"\]\.Clone\(\), _KLE_ResetObserverGeneration\)/
	);
	assert.match(kle, /KLE_State := _KLE_ResetDeadKeyTransition\(\)/);
	assert.match(kle, /_KLE_ResetDeadKeyTransition\(\) => KEYLAYOUT_NEUTRAL_STATE/);
	for (const binding of [
		'_KLTR_WithObserver.Bind(_KLTR_Positive.Bind(Scan, Origin, Repeated))',
		'_KLTR_WithObserver.Bind(_KLTR_SourceRefusal.Bind(Mutation))',
		'_KLTR_WithObserver.Bind(_KLTR_BadEvent.Bind(Vector[1], Vector[2], Vector.Length == 3))',
		'_KLTR_WithObserver.Bind(_KLTR_RegistrationRefusal.Bind(Mode))',
		'_KLTR_WithObserver.Bind(_KLTR_CriterionWithdrawal.Bind(Mutation))'
	])
		assert(authored.includes(binding), `Actual authored reset cohort binding missing: ${binding}`);
	assert.match(authored, /AssertFalse\(Result\["native_consumed"\]\)/);
	assert.match(authored, /AssertEqual\("acute", KLE_State/);
	assert.match(authored, /class _KLTR_ObservedCategory extends Map/);
	assert.match(authored, /_KLTR_Mutate\(this\.Mutation\)/);
}
const kleResetSource = fs.readFileSync(
	path.join(DRIVER, 'modules/keymap/keylayout/keylayout_emulation.ahk'),
	'utf8'
);
const kleResetTests = fs.readFileSync(
	path.join(DRIVER, 'tests/unit/test_keylayout_emulation.ahk'),
	'utf8'
);
validateKleResetObserver(kleResetSource, kleResetTests);
const kleResetInverses = [
	['capture callable override', '!Object.Prototype.HasOwnProp.Call(Factory, "Call")', 'true'],
	[
		'opaque binding getter',
		'if !_KLE_ResetObserverPlainMap(Cohort) || !_KLE_ResetObserverPlainMap(Binding)',
		'if !_KLE_ResetObserverPlainMap(Cohort)'
	],
	['owned cohort', 'Cohort != OwnedCohort', 'false'],
	['original bindings table', 'Cohort.Get("bindings", 0) != OwnedBindings', 'false'],
	['actual registered binding', 'ExpectedBindings.Get(Sc, 0) != Binding', 'false'],
	['original generation', '_KLE_ResetObserverGeneration != Proof["generation"]', 'false'],
	['capture factory identity', '_KLE_ResetObserverCapture != Proof["factory"]', 'false'],
	['source model identity', 'KLE_Model != Proof["model"]', 'false'],
	['source state identity', '!(KLE_State == Proof["state"])', 'false'],
	['binding identity', 'Proof["bindings"].Get(Proof["scan"], 0) != Binding', 'false'],
	['actual callback identity', 'Binding.Get(Name, 0) != Proof[Name]', 'false'],
	[
		'criterion successor fence',
		'if !(Active is Integer) || Active != 1 || !_KLE_ResetObserverCurrent(Proof)',
		'if !(Active is Integer) || Active != 1'
	],
	['integer caller event', 'if !(Value is Integer)', 'if false'],
	['down-only interpretation', 'CapturedEvent["key_up"] != 0', 'false'],
	[
		'post-transition source fence',
		'if !(Next == Proof["neutral"]) || !_KLE_ResetObserverCurrent(Proof)',
		'if !(Next == Proof["neutral"])'
	],
	['native consumption remains false', '"native_consumed", false', '"native_consumed", true'],
	[
		'reentrant publication refusal',
		'_KLE_ResetObserverRegistering["invalid"] := true',
		'_KLE_ResetObserverRegistering["invalid"] := false'
	],
	[
		'failure capture unavailable',
		'_KLE_ResetObserverCohort := 0, _KLE_ResetObserverCapture := 0',
		'_KLE_ResetObserverCohort := 0'
	],
	['cleanup binding fence', 'if _KLE_ResetObserverRegistering != Guard', 'if false'],
	[
		'whole successful registration',
		'if !Guard["invalid"] && Registration["bindings"].Count == KLE_DEAD_RESET_KEYS.Length',
		'if true'
	],
	['original table capture', 'Registration["bindings"].Clone()', 'Map()']
];
for (const [name, before, after] of kleResetInverses) {
	const changed = kleResetSource.replace(before, after);
	assert.notEqual(changed, kleResetSource, `Withdraw actual ${name}.`);
	assert.throws(
		() => validateKleResetObserver(changed, kleResetTests),
		{ code: 'ERR_ASSERTION' },
		name
	);
	validateKleResetObserver(kleResetSource, kleResetTests);
}
process.stdout.write(
	`KLE reset observer metadata: ${kleResetInverses.length} causal source inverses PASS; 91 authored AHK cases UNRUN; no native event authentication/consumption.\n`
);

/** Bind all frozen-authority copy mutations to the helper's actual observer key. */
function validateAuthorityCopyHook(custody, authored, loader) {
	const selectedPort = loader.slice(
		loader.indexOf('_LLM_NavEventOwnerPortFn(Name, Port := 0) {'),
		loader.indexOf('_LLM_NavEventOwnerCall(Name, DefaultFn, Args*) {')
	);
	assert.match(selectedPort, /Resolved := Port is Map \? Port : _LLM_NavEventOwnerPort/);
	assert.match(selectedPort, /Fn := Resolved\.Get\(Name, 0\)/);
	const begin = custody.indexOf(
		'_LLM_TerminalOutputCopyPacketBytes(Destination, Source, Record, Stage, ByteCount, SourceSize, Handle, Attempt, Key, Authority) {'
	);
	assert(begin >= 0, 'Actual packet-copy helper is required.');
	const consumer = custody.slice(begin, custody.indexOf('/** A callback cannot change', begin));
	const resolved = consumer.match(/_LLM_NavEventOwnerPortFn\("([a-z_]+)", Record\["port"\]\)/);
	assert(resolved, 'Read the real copy observer resolver.');
	const start = authored.indexOf(
		'_LNTOC_FrozenAuthorityVector(Phase, Mutation, Binding, Outcome) {'
	);
	assert(start >= 0, 'Retain the original frozen-authority callback.');
	const vector = authored.slice(start, authored.indexOf('for _LNTOC_AuthorityPhase in', start));
	const producer = vector.match(/State\.Port\["([a-z_]+)"\] := Copy/);
	assert(producer, 'Retain the real mutation callback installation.');
	assert.equal(
		producer[1],
		resolved[1],
		'The authored copy mutation must reach the actual packet-copy observer.'
	);
	assert.match(consumer, /Fn\.Call\("before_" \. Stage, Destination, Source\)/);
	assert.match(consumer, /Fn\.Call\("after_" \. Stage, Destination, Source\)/);
	assert.match(vector, /Copy\(Stage, Destination, Source\) \{\s+if Stage == Phase\s+Change\(\)/);
	const phases = authored.match(/for _LNTOC_AuthorityPhase in \[([^\]]+)\]/);
	assert(phases, 'Keep the original ten-phase authority matrix.');
	assert.deepEqual(
		[...phases[1].matchAll(/"([a-z_]+)"/g)].map((entry) => entry[1]),
		[
			'begin',
			'serialize',
			'before_owned',
			'after_owned',
			'before_public',
			'after_public',
			'emitter',
			'ack',
			'consume',
			'cancel'
		]
	);
}
validateAuthorityCopyHook(source, tests, packetLoader);
const oldAuthoritySetter = tests.replace(
	'State.Port["observe_terminal_output_packet_copy"] := Copy',
	'State.Port["copy_terminal_output_packets"] := Copy'
);
assert.notEqual(oldAuthoritySetter, tests);
assert.throws(() => validateAuthorityCopyHook(source, oldAuthoritySetter, packetLoader), {
	code: 'ERR_ASSERTION'
});
const foreignObserverResolver = source.replace(
	'_LLM_NavEventOwnerPortFn("observe_terminal_output_packet_copy", Record["port"])',
	'_LLM_NavEventOwnerPortFn("foreign_copy_observer", Record["port"])'
);
assert.notEqual(foreignObserverResolver, source);
assert.throws(() => validateAuthorityCopyHook(foreignObserverResolver, tests, packetLoader), {
	code: 'ERR_ASSERTION'
});
const disconnectedMutation = tests.replace(
	'if Stage == Phase\n\t\t\tChange()',
	'if false\n\t\t\tChange()'
);
assert.notEqual(disconnectedMutation, tests);
assert.throws(() => validateAuthorityCopyHook(source, disconnectedMutation, packetLoader), {
	code: 'ERR_ASSERTION'
});
const missingCopyPhase = tests.replace(
	'"before_owned", "after_owned", "before_public", "after_public", "emitter", "ack", "consume", "cancel"]',
	'"before_owned", "after_owned", "before_public", "emitter", "ack", "consume", "cancel"]'
);
assert.notEqual(missingCopyPhase, tests);
assert.throws(() => validateAuthorityCopyHook(source, missingCopyPhase, packetLoader), {
	code: 'ERR_ASSERTION'
});
const wrongPortLookup = packetLoader.replace(
	'Fn := Resolved.Get(Name, 0)',
	'Fn := Resolved.Get("foreign_copy_observer", 0)'
);
assert.notEqual(wrongPortLookup, packetLoader);
assert.throws(() => validateAuthorityCopyHook(source, tests, wrongPortLookup), {
	code: 'ERR_ASSERTION'
});
process.stdout.write(
	'Frozen-authority copy observer binding: 5 causal source inverses PASS; all667 authored AHK cases including48 affected copy mutations UNRUN.\n'
);

/**
 * Require actual preregistration authority and unknown-custody source seams.
 * This never executes AHK, native registration or a hook.
 * @param {string} loader - Actual owner adapter source.
 * @param {string} authored - Existing and additive native AHK regressions.
 * @returns {void}
 */
function validateTerminalRegistrationCustody(loader, authored) {
	const body = (name) => {
		const match = loader.match(new RegExp(`^${name}\\([^\\n]*\\) \\{\\n([\\s\\S]*?)\\n\\}`, 'm'));
		assert.ok(match, `Missing actual preregistration helper ${name}.`);
		return match[1];
	};
	const refresh = body('LLM_NavEventOwner_RefreshTerminalRoutes');
	assert.doesNotMatch(
		refresh,
		/RegisterFn\.Call\(_LLM_NavEventOwnerTerminalRouteOwner/,
		'A callback cannot receive the latest successor owner.'
	);
	const authority = body('_LLM_NavEventOwnerNativeEnsureLoaded');
	assert.match(authority, /if Request == "begin_frame" \{[\s\S]*?return BuildFrame\(\)/);
	assert.match(authority, /Frame := _LLM_NavEventOwnerTerminalRegistrationCapture\(\)/);
	assert.ok(
		authority.indexOf('Frame := _LLM_NavEventOwnerTerminalRegistrationCapture()') <
			authority.indexOf('ActiveFrame := State'),
		'The private owner captures the original frame before publishing its scope.'
	);
	assert.match(refresh, /static OriginalLoader := _LLM_NavEventOwnerNativeEnsureLoaded/);
	assert.match(refresh, /OriginalLoader\.Call\("owns_scope", NativeScope\)/);
	const captured = refresh.indexOf('NativeScope := OriginalLoader.Call("begin_frame")');
	assert.ok(
		captured >= 0 && captured < refresh.indexOf('_LLM_NavEventOwnerPortFn("terminal_route_source"')
	);
	assert.match(
		refresh,
		/NativeScope := OriginalLoader\.Call\("begin_frame"\)\s+GuardScope\(\)\s+Frame := NativeScope\["frame"\]/
	);
	assert.match(refresh, /if IsObject\(_LLM_NavEventOwnerTerminalRouteUnknown\)\s+throw Error/);
	assert.match(refresh, /RegisterFn\.Call\(Frame\["owner"\], Generation, Candidate\["layout_id"\]/);
	assert.match(
		refresh,
		/Status := OriginalNativeRegister\.Call\(Frame\["owner"\], Generation,[\s\S]*?NativeScope\["native"\]\)/
	);
	assert.match(
		refresh,
		/static OriginalNativeRegister := _LLM_NavEventOwnerNativeRegisterTerminalRoutes/
	);
	assert.match(refresh, /Frame\["native_attempted"\] := true\s+try \{/);
	assert.match(refresh, /catch as Err \{\s+RetainUnknown\(\)\s+throw Err/);
	assert.match(refresh, /Func\.Prototype\.Call\.Call\(OriginalUnknown, Frame\)/);
	const registrationPhase = refresh.slice(
		refresh.indexOf('Frame["native_attempted"] := true'),
		refresh.indexOf('if Status == -11')
	);
	assert.equal(
		(registrationPhase.match(/catch as Err \{\s+RetainUnknown\(\)\s+throw Err/g) || []).length,
		2,
		'Both the native invocation and its post-callback authority checks retain unknown custody.'
	);
	assert.match(
		refresh,
		/Witness := _LLM_NavEventOwnerTerminalRouteMarshal\(Candidate\["routes"\]\)/
	);
	assert.match(
		refresh,
		/if !_LLM_NavEventOwnerTerminalRegistrationBytesCurrent\(Bindings, Witness\)/
	);
	assert.match(
		refresh,
		/if !\(Status is Integer\) \|\| !_LLM_NavEventOwnerTerminalRegistrationStatusKnown\(Status\)/
	);
	assert.ok(
		refresh.indexOf('_LLM_NavEventOwnerTerminalRegistrationBytesCurrent(') <
			refresh.indexOf('if Status == -11')
	);
	assert.match(refresh, /Frame\["recipes"\]\[RecipeId\] := Admission/);
	assert.match(refresh, /_LLM_NavEventOwnerTerminalRoutePrune\(Candidate, Source, Port, Frame\)/);
	const current = body('_LLM_NavEventOwnerTerminalRegistrationCurrent');
	for (const [global, field] of [
		['Owner', 'owner'],
		['Generation', 'generation'],
		['Recipes', 'recipes'],
		['Models', 'models'],
		['Coverage', 'coverage'],
		['NextRecipe', 'next_recipe'],
		['NextLayout', 'next_layout']
	]) {
		assert.ok(
			current.includes(`_LLM_NavEventOwnerTerminalRoute${global} == Frame["${field}"]`),
			`Missing captured ${field} comparison.`
		);
	}
	assert.match(
		current,
		/_LLM_NavEventOwnerTerminalRegistrationRefsCurrent\(Frame\["recipes"\], Frame\["recipe_refs"\]\)/
	);
	assert.match(
		current,
		/_LLM_NavEventOwnerTerminalRegistrationObjectsCurrent\(Frame, CheckModels\)/
	);
	const objects = body('_LLM_NavEventOwnerTerminalRegistrationObjectsCurrent');
	assert.match(
		objects,
		/if !CheckModels && !_LLM_NavEventOwnerTerminalRegistrationBuildModelsCurrent\(Frame\)/
	);
	assert.doesNotMatch(objects, /if CheckModels \{/);
	assert.match(objects, /for Id, Expected in Frame\["model_objects"\]/);
	const buildingModels = body('_LLM_NavEventOwnerTerminalRegistrationBuildModelsCurrent');
	assert.match(
		buildingModels,
		/for Id, Identity in Original\s+if !Models\.Has\(Id\) \|\| Models\[Id\] != Identity/
	);
	assert.match(buildingModels, /Models\.Count != Original\.Count \+ \(NewModel \? 1 : 0\)/);
	assert.match(buildingModels, /Models\[Key\] != Frame\["build_model_cell"\]/);
	assert.match(
		buildingModels,
		/_LLM_NavEventOwnerTerminalRegistrationRefsCurrent\(Models\[Key\], Frame\["build_model_fields"\]\)/
	);
	const build = body('_LLM_NavEventOwnerTerminalRouteBuild');
	assert.ok(
		build.indexOf('Frame["build_model_cell"] := Identity') <
			build.indexOf('Source["eligible"].Call')
	);
	assert.match(
		refresh,
		/_LLM_NavEventOwnerTerminalRouteBuild\(Source, Generation, Frame, NativeScope\["guard"\]\)/
	);
	const retained = body('_LLM_NavEventOwnerTerminalRegistrationRetain');
	assert.match(retained, /"route_fields", Admission\["route"\]\.Clone\(\)/);
	assert.match(retained, /"recipe_fields", Recipe is Map \? Recipe\.Clone\(\) : 0/);
	assert.match(
		retained,
		/Models\[Id\] := Map\("model", Identity\["model"\], "id", Identity\["id"\]\)/
	);
	const bytes = body('_LLM_NavEventOwnerTerminalRegistrationBytesCurrent');
	assert.match(bytes, /Actual\.Size != Expected\.Size/);
	assert.match(
		bytes,
		/Loop Expected\.Size\s+if NumGet\(Actual, A_Index - 1, "UChar"\) != NumGet\(Expected, A_Index - 1, "UChar"\)/
	);
	const advance = body('_LLM_NavEventOwnerTerminalRegistrationAdvance');
	assert.match(
		advance,
		/ExpectedRecipe := Frame\["next_recipe"\] \+ Candidate\["routes"\]\.Length/
	);
	assert.match(advance, /Route\["recipe_id"\] != Frame\["next_recipe"\] \+ Index/);
	const unknown = body('_LLM_NavEventOwnerTerminalRegistrationUnknown');
	assert.match(
		unknown,
		/if !IsObject\(_LLM_NavEventOwnerTerminalRouteUnknown\)\s+_LLM_NavEventOwnerTerminalRouteUnknown := Frame/
	);
	assert.doesNotMatch(unknown, /Delete|Cancel|Register|Stop|:= 0/);
	const prune = body('_LLM_NavEventOwnerTerminalRoutePrune');
	assert.match(prune, /HeldFn\.Call\(Frame\["owner"\], HeldBuffer, 64\)/);
	assert.match(
		prune,
		/_LLM_NavEventOwnerNativeListTerminalHeldRecipes\(\s*Frame\["owner"\], HeldBuffer, 64\)/
	);
	assert.match(
		prune,
		/if !_LLM_NavEventOwnerTerminalRegistrationCurrent\(Frame\) \{\s+RetainUnknown\(\)/
	);
	assert.match(prune, /Func\.Prototype\.Call\.Call\(OriginalUnknown, Frame\)/);
	assert.match(
		prune,
		/throw ValueError\("Retirement cannot borrow a successor registration owner\."\)\s+\}\s+for RecipeId in RetireRecipes/
	);
	assert.match(prune, /_LLM_NavEventOwnerTerminalRegistrationRetain\(Frame\)\s+return true/);
	for (const literal of [
		'"source", "register", "held"',
		'"route-object", "route-field", "recipe-object", "recipe-field", "recipe-model"',
		'"bindings-byte", "bindings-size"',
		'Unknown["route_objects"][17]["model"] == Model',
		'The retry never reaches a successor/native callback.'
	])
		assert.ok(authored.includes(literal), `Missing independent custody vector ${literal}.`);
}
const registrationTests = fs.readFileSync(
	path.join(DRIVER, 'tests/unit/llm_nav_event_owner/test_terminal_route_metadata.ahk'),
	'utf8'
);
validateTerminalRegistrationCustody(packetLoader, registrationTests);
const registrationInverses = [
	[
		'_LLM_NavEventOwnerTerminalRegistrationObjectsCurrent',
		'if !CheckModels && !_LLM_NavEventOwnerTerminalRegistrationBuildModelsCurrent(Frame)',
		'if false'
	],
	['_LLM_NavEventOwnerTerminalRegistrationBuildModelsCurrent', 'Models[Id] != Identity', 'false'],
	[
		'_LLM_NavEventOwnerTerminalRegistrationBuildModelsCurrent',
		'Models.Count != Original.Count + (NewModel ? 1 : 0)',
		'false'
	],
	[
		'_LLM_NavEventOwnerTerminalRegistrationBuildModelsCurrent',
		'Models[Key] != Frame["build_model_cell"]',
		'false'
	],
	[
		'_LLM_NavEventOwnerTerminalRegistrationBuildModelsCurrent',
		'_LLM_NavEventOwnerTerminalRegistrationRefsCurrent(Models[Key], Frame["build_model_fields"])',
		'true'
	],
	[
		'LLM_NavEventOwner_RefreshTerminalRoutes',
		'_LLM_NavEventOwnerTerminalRouteBuild(Source, Generation, Frame, NativeScope["guard"])',
		'_LLM_NavEventOwnerTerminalRouteBuild(Source, Generation)'
	],
	[
		'LLM_NavEventOwner_RefreshTerminalRoutes',
		'if IsObject(_LLM_NavEventOwnerTerminalRouteUnknown)',
		'if false'
	],
	[
		'LLM_NavEventOwner_RefreshTerminalRoutes',
		'RegisterFn.Call(Frame["owner"],',
		'RegisterFn.Call(_LLM_NavEventOwnerTerminalRouteOwner,'
	],
	[
		'LLM_NavEventOwner_RefreshTerminalRoutes',
		'OriginalNativeRegister.Call(Frame["owner"],',
		'OriginalNativeRegister.Call(_LLM_NavEventOwnerTerminalRouteOwner,'
	],
	[
		'LLM_NavEventOwner_RefreshTerminalRoutes',
		'Frame["native_attempted"] := true',
		'Frame["native_attempted"] := false'
	],
	[
		'LLM_NavEventOwner_RefreshTerminalRoutes',
		'catch as Err {\n\t\t\t\tRetainUnknown()',
		'catch as Err {\n\t\t\t\tSleep(0)'
	],
	[
		'LLM_NavEventOwner_RefreshTerminalRoutes',
		'Witness := _LLM_NavEventOwnerTerminalRouteMarshal(Candidate["routes"])',
		'Witness := Bindings'
	],
	[
		'LLM_NavEventOwner_RefreshTerminalRoutes',
		'if !_LLM_NavEventOwnerTerminalRegistrationBytesCurrent(Bindings, Witness)',
		'if false'
	],
	[
		'LLM_NavEventOwner_RefreshTerminalRoutes',
		'if !(Status is Integer) || !_LLM_NavEventOwnerTerminalRegistrationStatusKnown(Status)',
		'if !Status'
	],
	[
		'LLM_NavEventOwner_RefreshTerminalRoutes',
		'Frame["recipes"][RecipeId] := Admission',
		'_LLM_NavEventOwnerTerminalRouteRecipes[RecipeId] := Admission'
	],
	[
		'LLM_NavEventOwner_RefreshTerminalRoutes',
		'_LLM_NavEventOwnerTerminalRoutePrune(Candidate, Source, Port, Frame)',
		'_LLM_NavEventOwnerTerminalRoutePrune(Candidate, Source, Port)'
	],
	[
		'_LLM_NavEventOwnerTerminalRegistrationCurrent',
		'_LLM_NavEventOwnerTerminalRouteOwner == Frame["owner"]',
		'true'
	],
	[
		'_LLM_NavEventOwnerTerminalRegistrationCurrent',
		'_LLM_NavEventOwnerTerminalRouteGeneration == Frame["generation"]',
		'true'
	],
	[
		'_LLM_NavEventOwnerTerminalRegistrationCurrent',
		'_LLM_NavEventOwnerTerminalRouteRecipes == Frame["recipes"]',
		'true'
	],
	[
		'_LLM_NavEventOwnerTerminalRegistrationCurrent',
		'_LLM_NavEventOwnerTerminalRouteModels == Frame["models"]',
		'true'
	],
	[
		'_LLM_NavEventOwnerTerminalRegistrationCurrent',
		'_LLM_NavEventOwnerTerminalRouteNextRecipe == Frame["next_recipe"]',
		'true'
	],
	[
		'_LLM_NavEventOwnerTerminalRegistrationCurrent',
		'_LLM_NavEventOwnerTerminalRegistrationObjectsCurrent(Frame, CheckModels)',
		'true'
	],
	[
		'_LLM_NavEventOwnerTerminalRegistrationRetain',
		'"route_fields", Admission["route"].Clone()',
		'"route_fields", Admission["route"]'
	],
	[
		'_LLM_NavEventOwnerTerminalRegistrationRetain',
		'"recipe_fields", Recipe is Map ? Recipe.Clone() : 0',
		'"recipe_fields", Recipe'
	],
	['_LLM_NavEventOwnerTerminalRegistrationBytesCurrent', 'Actual.Size != Expected.Size', 'false'],
	['_LLM_NavEventOwnerTerminalRegistrationBytesCurrent', 'Loop Expected.Size', 'Loop 0'],
	[
		'_LLM_NavEventOwnerTerminalRegistrationAdvance',
		'Route["recipe_id"] != Frame["next_recipe"] + Index',
		'false'
	],
	[
		'_LLM_NavEventOwnerTerminalRegistrationUnknown',
		'_LLM_NavEventOwnerTerminalRouteUnknown := Frame',
		'_LLM_NavEventOwnerTerminalRouteUnknown := 0'
	],
	[
		'_LLM_NavEventOwnerTerminalRoutePrune',
		'HeldFn.Call(Frame["owner"], HeldBuffer, 64)',
		'HeldFn.Call(_LLM_NavEventOwnerTerminalRouteOwner, HeldBuffer, 64)'
	],
	[
		'_LLM_NavEventOwnerTerminalRoutePrune',
		'_LLM_NavEventOwnerNativeListTerminalHeldRecipes(Frame["owner"],',
		'_LLM_NavEventOwnerNativeListTerminalHeldRecipes(_LLM_NavEventOwnerTerminalRouteOwner,'
	],
	[
		'_LLM_NavEventOwnerTerminalRoutePrune',
		'throw ValueError("Retirement cannot borrow a successor registration owner.")',
		'Sleep(0)'
	],
	[
		'_LLM_NavEventOwnerTerminalRoutePrune',
		'_LLM_NavEventOwnerTerminalRegistrationRetain(Frame)\n\t\treturn true',
		'Sleep(0)\n\t\treturn true'
	],
	[
		'_LLM_NavEventOwnerNativeEnsureLoaded',
		'Frame := _LLM_NavEventOwnerTerminalRegistrationCapture()',
		'Frame := Map()'
	],
	['_LLM_NavEventOwnerNativeEnsureLoaded', 'return BuildFrame()', 'return Map()'],
	[
		'LLM_NavEventOwner_RefreshTerminalRoutes',
		'NativeScope := OriginalLoader.Call("begin_frame")',
		'NativeScope := Map()'
	],
	['LLM_NavEventOwner_RefreshTerminalRoutes', 'Frame := NativeScope["frame"]', 'Frame := Map()'],
	[
		'LLM_NavEventOwner_RefreshTerminalRoutes',
		'OriginalLoader.Call("owns_scope", NativeScope)',
		'true'
	],
	[
		'LLM_NavEventOwner_RefreshTerminalRoutes',
		'Candidate["routes"].Length, NativeScope["native"])',
		'Candidate["routes"].Length)'
	],
	[
		'LLM_NavEventOwner_RefreshTerminalRoutes',
		'Func.Prototype.Call.Call(OriginalUnknown, Frame)',
		'OriginalUnknown.Call(Frame)'
	],
	[
		'_LLM_NavEventOwnerTerminalRoutePrune',
		'Func.Prototype.Call.Call(OriginalUnknown, Frame)',
		'OriginalUnknown.Call(Frame)'
	]
];
for (const [name, before, after] of registrationInverses) {
	const region = packetLoader.match(
		new RegExp(`^${name}\\([^\\n]*\\) \\{\\n[\\s\\S]*?\\n\\}`, 'm')
	);
	assert.ok(region);
	const changed = region[0].replace(before, after);
	assert.notEqual(changed, region[0], `Registration inverse missed ${name}.`);
	const mutant = packetLoader.replace(region[0], changed);
	assert.throws(
		() => validateTerminalRegistrationCustody(mutant, registrationTests),
		{ code: 'ERR_ASSERTION' },
		`Registration inverse missed ${name}: ${before}`
	);
}
process.stdout.write(
	`Terminal preregistration custody: ${registrationInverses.length} causal source inverses PASS; 111 authored AHK cases UNRUN; no native activation or settlement inferred.\n`
);
