// tools/test/test-windows-hook-trace-source.cjs

/**
 * MODULE: Windows Hook Trace Source Binding Gate
 * DESCRIPTION: Require opt-in owned collection and actual ABI/build consumers.
 * Source observations do not execute Windows, hooks, AHK or receiving controls.
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ROOT = path.resolve(__dirname, '../..');
const NATIVE = 'static/ergopti_plus/windows/native/nav_event_owner/';
const EXISTING = [
	'ErgoptiEditor_Begin',
	'ErgoptiEditor_Poll',
	'ErgoptiEditor_Decide',
	'ErgoptiEditor_Close',
	'ErgoptiNav_Start',
	'ErgoptiNav_Stop',
	'ErgoptiNav_PreparePlan',
	'ErgoptiNav_CommitPlan',
	'ErgoptiNav_SetSuspended',
	'ErgoptiNav_RegisterTerminalRoutes',
	'ErgoptiNav_ListTerminalHeldRecipes',
	'ErgoptiNav_PlanTerminalOutput',
	'ErgoptiNav_BeginTerminalOutputAttempt',
	'ErgoptiNav_AcknowledgeTerminalOutput',
	'ErgoptiNav_ConsumeTerminalOutput',
	'ErgoptiNav_CancelTerminalOutput',
	'ErgoptiNav_PreviewTerminalOutput',
	'ErgoptiNav_PeekTerminalRoute',
	'ErgoptiNav_BeginTerminalCapture',
	'ErgoptiNav_CommitTerminalCapture',
	'ErgoptiNav_AbortTerminalCapture',
	'ErgoptiNav_GetTerminalCapture',
	'ErgoptiNav_BeginOwnerSwap',
	'ErgoptiNav_CommitOwnerSwap',
	'ErgoptiNav_AbortOwnerSwap',
	'ErgoptiNav_ClaimOwner',
	'ErgoptiNav_GetOwner',
	'ErgoptiNav_BeginProfileSwap',
	'ErgoptiNav_CommitProfileSwap',
	'ErgoptiNav_AbortProfileSwap',
	'ErgoptiNav_ProfilePendingMask',
	'ErgoptiNav_CanStop',
	'ErgoptiNav_PollReceipt',
	'ErgoptiNav_CompleteReceipt',
	'ErgoptiNav_PendingForToken',
	'ErgoptiNav_GetLastOsError',
	'ErgoptiNav_TestDispatch'
];
const DIAGNOSTIC = [
	'ErgoptiNav_StartHookTrace',
	'ErgoptiNav_ReadHookTrace',
	'ErgoptiNav_StopHookTrace'
];

/** @param {string} relative Repository path. @returns {string} Exact UTF-8 source. */
function read(relative) {
	return fs.readFileSync(path.join(ROOT, relative), 'utf8');
}

/** @param {object} source Production source bundle. @returns {void} */
function check(source) {
	const exports = [...source.def.matchAll(/^\s*(Ergopti\w+)\s*$/gm)].map((match) => match[1]);
	assert.deepEqual(
		exports.sort(),
		[...EXISTING, ...DIAGNOSTIC].sort(),
		'The 37 original exports must survive the diagnostic ABI.'
	);
	for (const name of DIAGNOSTIC) {
		assert.match(source.c, new RegExp(`ERGOPTI_NAV_CALL ${name}\\(`));
		assert.match(source.h, new RegExp(`ERGOPTI_NAV_CALL ${name}\\(`));
		assert(
			source.adapter.includes(`"${name}"`),
			'Production export validation lost a diagnostic binding.'
		);
	}
	const wrapper = source.c.slice(
		source.c.indexOf('static LRESULT CALLBACK NavLowLevelKeyboardProc('),
		source.c.indexOf('/**\n * Installs the hook')
	);
	assert(wrapper.includes('if (g_nav_hook_trace.enabled)'), 'Collection must be opt-in.');
	const enabled = wrapper.indexOf('if (g_nav_hook_trace.enabled)');
	const focus = wrapper.indexOf('focus.hwndFocus != g_nav_hook_trace_focus');
	const qpc = wrapper.indexOf('QueryPerformanceCounter(&clock)');
	const payload = wrapper.indexOf('memcpy(&raw, (const void *)data_pointer, sizeof(raw))');
	assert(
		enabled >= 0 && focus > enabled && qpc > focus && payload > qpc,
		'Foreground/focus and QPC admission must precede retained raw payload.'
	);
	assert(wrapper.includes('GetForegroundWindow() != (HWND)(uintptr_t)owner'));
	assert(wrapper.includes('ErgoptiTrace_RecordDrop(&g_nav_hook_trace, owner, token, generation)'));
	assert(wrapper.includes('observed.qpc = (uint64_t)clock.QuadPart'));
	assert(wrapper.includes('observed.capture_sequence = g_nav_state.terminal_next_sequence'));
	assert(
		wrapper.indexOf('NavLowLevelKeyboardProcCore(code, message, data_pointer, &decision)') <
			wrapper.indexOf('ErgoptiTrace_Push(&g_nav_hook_trace, owner, token, generation, &observed)')
	);
	assert(
		source.c.includes('process != GetCurrentProcessId()'),
		'Start must reject another process receiver.'
	);
	assert(
		source.c.includes('!IsChild(receiver, focus.hwndFocus)'),
		'Start must validate owned focus.'
	);
	assert(
		source.c.includes('g_nav_hook_trace.enabled || g_nav_hook_trace_inflight'),
		'Stop must retain live diagnostic custody.'
	);
	assert.match(
		source.c,
		/NavTerminalOutputCohortAdmittedLocked[\s\S]*?#else\s*\(void\)state;\s*return false;/
	);
	assert(
		source.builder.includes('"{source_dir}\\hook_trace.c"'),
		'Official DLL recipe must compile the trace source.'
	);
	assert(
		source.builder.includes('$traceTestSourcePath,') &&
			source.builder.includes('Running the bounded diagnostic trace test')
	);
	assert(source.cmake.includes('add_executable(ergopti_hook_trace_test'));
	assert(source.cmake.includes('add_test(NAME ergopti_hook_trace_test'));
	assert(source.runner.includes("path.join(SOURCE, 'hook_trace.c')"));
	assert(source.harness.includes('TraceNative("StartHookTrace", "UInt64", TraceOwner,'));
	assert(
		source.harness
			.replace(/\s+/g, ' ')
			.includes(
				'"UInt64", TraceToken, "UInt64", TraceGeneration, "UInt", 0, "Ptr", Entries, "UInt", 256, "Ptr", Page'
			)
	);
	for (const name of ['TraceCriterion', 'TraceHotkey', 'TraceDown', 'TraceChar', 'TraceUp'])
		assert.match(source.harness, new RegExp(`^${name}\\(`, 'm'));
	const observation = source.harness.slice(
		source.harness.indexOf('TraceObserve(Channel,'),
		source.harness.indexOf('TraceCriterion(*)')
	);
	for (const field of ['vk', 'sc'])
		assert.equal(
			(observation.match(new RegExp(`"${field}":`, 'g')) || []).length,
			1,
			'Callback keys must have a single conditional construction site.'
		);
	assert(
		source.harness.includes('TraceObserve(Channel, Vk := 0, Sc := 0,'),
		'Unobserved callback key identity must not default to fixture VK/SC.'
	);
	assert.match(
		source.harness,
		/if ObservedKey\s*Json \.= ',"vk":' \. Vk \. ',"sc":' \. Sc/,
		'Only real key callbacks may publish VK/SC fields.'
	);
	for (const channel of ['hotif', 'hotkey', 'char'])
		assert(
			source.harness.includes(`TraceObserve("${channel}", 0, 0,`),
			'Callbacks without key arguments must not fabricate a key receipt.'
		);
	for (const channel of ['down', 'up'])
		assert(
			source.harness.includes(`TraceObserve("${channel}", Vk, Sc,`),
			'InputHook key callbacks must retain their actual arguments.'
		);
	assert(
		source.harness.includes(
			'if Channel == "hotif" || Channel == "hotkey"\n\t\tJson .= \',"registered_fixture":"a"\''
		),
		'Registered fixture attribution must remain explicit.'
	);
	assert(source.supervisor.includes("'synthetic'"));
	assert(source.supervisor.includes('No kill was performed.'));
	assert(source.supervisor.includes('$Node $Reader $Stdout ([string]$Samples) $InstallSequence'));
}
const source = {
	c: read(NATIVE + 'nav_event_owner.c'),
	h: read(NATIVE + 'nav_event_owner.h'),
	def: read(NATIVE + 'nav_event_owner.def'),
	cmake: read(NATIVE + 'CMakeLists.txt'),
	adapter: read('static/ergopti_plus/windows/adapters/llm_nav_event_owner.ahk'),
	builder: read('tools/build/build_windows_nav_owner.ps1'),
	runner: read('tools/test/run-nav-event-owner-portable.cjs'),
	harness: read('static/ergopti_plus/windows/tests/hardware/group7_hook_trace.ahk'),
	supervisor: read('tools/diagnostics/run-windows-group7-trace.ps1')
};
check(source);
const mutations = [
	['def', (text) => text.replace('\tErgoptiNav_StartHookTrace\n', '')],
	['c', (text) => text.replace('if (g_nav_hook_trace.enabled) {', 'if (true) {')],
	['c', (text) => text.replace('focus.hwndFocus != g_nav_hook_trace_focus', 'false')],
	['c', (text) => text.replace('process != GetCurrentProcessId()', 'false')],
	['c', (text) => text.replace('observed.qpc = (uint64_t)clock.QuadPart', 'observed.qpc = 1')],
	[
		'c',
		(text) =>
			text.replace(
				'#else\n\t(void)state;\n\treturn false;',
				'#else\n\t(void)state;\n\treturn true;'
			)
	],
	['builder', (text) => text.replace('"{source_dir}\\hook_trace.c"', '"unused.c"')],
	['harness', (text) => text.replace('"UInt", 256, "Ptr", Page', '"UShort", 256, "Ptr", Page')],
	[
		'runner',
		(text) => text.replace("path.join(SOURCE, 'hook_trace.c')", "path.join(SOURCE, 'unused.c')")
	],
	[
		'harness',
		(text) =>
			text.replace(
				'TraceObserve(Channel, Vk := 0, Sc := 0,',
				'TraceObserve(Channel, Vk := 65, Sc := 30,'
			)
	],
	['harness', (text) => text.replace('if ObservedKey\n\t\tJson .=', 'if true\n\t\tJson .=')],
	['harness', (text) => text.replace('TraceObserve("char", 0, 0,', 'TraceObserve("char", 65, 30,')],
	[
		'harness',
		(text) =>
			text.replace(
				'if ObservedKey\n\t\tJson .=',
				'Json .= \',"vk":65\'\n\tif ObservedKey\n\t\tJson .='
			)
	]
];
for (const [name, mutate] of mutations)
	assert.throws(() => check({ ...source, [name]: mutate(source[name]) }));
console.log(
	`Hook trace source bindings: 40 preserved exports and ${mutations.length} negative controls passed.`
);
console.log('Source binding only; native Windows callback execution remains UNRUN.');
