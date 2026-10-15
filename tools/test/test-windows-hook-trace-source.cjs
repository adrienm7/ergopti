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

const SERIALIZATION = ['ErgoptiNav_SerializeTerminalOutputAttempt'];

/** @param {string} relative Repository path. @returns {string} Exact UTF-8 source. */
function read(relative) {
	return fs.readFileSync(path.join(ROOT, relative), 'utf8');
}

/**
 * Pins the guarded serializer's actual declaration, body, loader and FFI widths.
 * @param {object} source Exact production C/header/AHK source bundle.
 * @returns {void}
 */
function checkSerializationBinding(source) {
	const name = SERIALIZATION[0];
	const parameters =
		'uint64_t owner, const ErgoptiOutput_Key *key, uint64_t attempt, ' +
		'ErgoptiOutput_Win32Input *out_inputs, uint32_t capacity, uint32_t *out_count';
	const normalize = (text) => text.replace(/\s+/g, ' ').trim();
	const withoutComments = (text) =>
		text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
	for (const [kind, terminator] of [
		['c', '\\{'],
		['h', ';']
	]) {
		const declarations = [
			...withoutComments(source[kind]).matchAll(
				new RegExp(
					`ERGOPTI_NAV_API\\s+int32_t\\s+ERGOPTI_NAV_CALL\\s+${name}\\s*\\(([^)]*)\\)\\s*${terminator}`,
					'g'
				)
			)
		];
		assert.equal(
			declarations.length,
			1,
			'Exactly one actual serializer C/header declaration is required.'
		);
		assert.equal(
			normalize(declarations[0][1]),
			parameters,
			'The serializer native parameter widths changed.'
		);
	}
	const bodyMatch = withoutComments(source.c).match(
		new RegExp(`ERGOPTI_NAV_CALL\\s+${name}\\s*\\([^)]*\\)\\s*\\{([^{}]+)\\}`)
	);
	assert(bodyMatch && bodyMatch[1].trim(), 'The actual serializer helper body must exist.');
	const body = bodyMatch[1];
	const aliases = body.indexOf('NavTerminalOutputAliasesState(out_inputs,');
	const countAlias = body.indexOf('NavTerminalOutputAliasesState(out_count, sizeof(*out_count))');
	const lock = body.indexOf('EnterCriticalSection(&g_nav_state.lock)');
	const head = body.indexOf('NavCheckTerminalOutputLocked(&g_nav_state, owner, key)');
	const dispatch = body.indexOf('ErgoptiOutput_SerializeAttempt(');
	const unlock = body.indexOf('LeaveCriticalSection(&g_nav_state.lock)');
	assert(
		aliases >= 0 &&
			countAlias > aliases &&
			lock > countAlias &&
			head > lock &&
			dispatch > head &&
			unlock > dispatch,
		'Whole-owner preflight and FIFO authentication must retain the same lock through serialization.'
	);
	assert(
		body.includes(
			'&g_nav_state.terminal_output, owner, key, attempt, out_inputs, capacity, out_count'
		),
		'The bridge must serialize its authoritative retained attempt and exact caller outputs.'
	);
	const loader = source.adapter.match(
		/_LLM_NavEventOwnerNativeEnsureLoaded\([^\n]*\)\s*\{[\s\S]*?\bNames\s*:=\s*\[([^\]]+)\]/
	);
	assert(loader, 'The actual native loader export list must exist.');
	const required = [...loader[1].matchAll(/"(Ergopti\w+)"/g)].map((match) => match[1]);
	assert.deepEqual(
		required.sort(),
		[...EXISTING, ...DIAGNOSTIC, ...SERIALIZATION].sort(),
		'The real loader must require all original, diagnostic and serializer exports exactly once.'
	);
	const binding = source.custodyAdapter.match(
		/_LLM_TerminalOutputNativeSerialize\(([^)]*)\)\s*\{([^{}]+)\}/
	);
	assert(binding && binding[2].trim(), 'The actual AHK serializer helper body must exist.');
	assert.equal(normalize(binding[1]), 'Owner, Key, Attempt, Packets, Count');
	assert(
		normalize(binding[2]).includes(
			`return DllCall(_LLM_NavEventOwnerNativeExport("${name}"), "UInt64", Owner, "Ptr", Key, "UInt64", Attempt, "Ptr", Packets, "UInt", 2048, "Ptr", Count, "Int")`
		),
		'The actual AHK binding must preserve all six arguments and exact return width.'
	);
}

/** @param {object} source Production source bundle. @returns {void} */
function check(source) {
	const exports = [...source.def.matchAll(/^\s*(Ergopti\w+)\s*$/gm)].map((match) => match[1]);
	assert.deepEqual(
		exports.sort(),
		[...EXISTING, ...DIAGNOSTIC, ...SERIALIZATION].sort(),
		'The 37 original exports must survive the diagnostic ABI.'
	);
	checkSerializationBinding(source);
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
	custodyAdapter: read('static/ergopti_plus/windows/adapters/terminal_output_custody.ahk'),
	builder: read('tools/build/build_windows_nav_owner.ps1'),
	runner: read('tools/test/run-nav-event-owner-portable.cjs'),
	harness: read('static/ergopti_plus/windows/tests/hardware/group7_hook_trace.ahk'),
	supervisor: read('tools/diagnostics/run-windows-group7-trace.ps1')
};
/** Requires process-lifetime DLL custody before a fixture installs native callbacks. */
function checkModuleCustody(text, prefix) {
	const acquire = text.indexOf(
		`${prefix}Module := DllCall("LoadLibraryW", "Str", ${prefix}Dll, "Ptr")`
	);
	const guard = text.indexOf(`if !${prefix}Module`, acquire);
	const start = text.indexOf(`${prefix}Native("Start",`);
	assert(
		acquire >= 0 && guard > acquire && start > guard,
		'Retain the native callback module before Start.'
	);
	assert(
		!text.includes('DllCall("FreeLibrary"'),
		'InitOnce and callback custody lasts until process exit.'
	);
}
for (const [file, prefix] of [
	['group7_hook_trace.ahk', 'Trace'],
	['group7_send_receiving.ahk', 'Probe']
]) {
	const text = read('static/ergopti_plus/windows/tests/hardware/' + file);
	checkModuleCustody(text, prefix);
	assert.throws(() =>
		checkModuleCustody(text.replace('DllCall("LoadLibraryW"', 'DllCall("GetModuleHandleW"'), prefix)
	);
	assert.throws(() => checkModuleCustody(text + '\nDllCall("FreeLibrary", "Ptr", 1)', prefix));
}
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
const serializationMutations = [
	['def', (text) => text.replace('\tErgoptiNav_SerializeTerminalOutputAttempt\n', '')],
	['def', (text) => text + '\tErgoptiNav_ForeignSerializer\n'],
	[
		'c',
		(text) =>
			text.replace(
				'ERGOPTI_NAV_CALL ErgoptiNav_SerializeTerminalOutputAttempt(',
				'ERGOPTI_NAV_CALL ErgoptiNav_MissingSerializeTerminalOutputAttempt('
			)
	],
	[
		'h',
		(text) =>
			text.replace(
				'ERGOPTI_NAV_CALL ErgoptiNav_SerializeTerminalOutputAttempt(',
				'ERGOPTI_NAV_CALL ErgoptiNav_MissingSerializeTerminalOutputAttempt('
			)
	],
	[
		'h',
		(text) =>
			text.replace(
				'uint64_t attempt,\n\tErgoptiOutput_Win32Input *out_inputs',
				'uint32_t attempt,\n\tErgoptiOutput_Win32Input *out_inputs'
			)
	],
	[
		'c',
		(text) =>
			text.replace(
				'ErgoptiOutput_Win32Input *out_inputs, uint32_t capacity',
				'ErgoptiOutput_Win32Input *out_inputs, uint64_t capacity'
			)
	],
	['adapter', (text) => text.replace('"ErgoptiNav_SerializeTerminalOutputAttempt",', '')],
	[
		'adapter',
		(text) =>
			text.replace(
				'"ErgoptiNav_SerializeTerminalOutputAttempt",',
				'"ErgoptiNav_SerializeTerminalOutputAttempt", "ErgoptiNav_ForeignSerializer",'
			)
	],
	[
		'custodyAdapter',
		(text) =>
			text.replace(
				'_LLM_TerminalOutputNativeSerialize(Owner, Key, Attempt, Packets, Count) {',
				'_LLM_TerminalOutputMissingSerialize(Owner, Key, Attempt, Packets, Count) {'
			)
	],
	[
		'custodyAdapter',
		(text) =>
			text.replace(
				'"UInt64", Attempt, "Ptr", Packets, "UInt", 2048,',
				'"UInt", Attempt, "Ptr", Packets, "UInt", 2048,'
			)
	],
	[
		'custodyAdapter',
		(text) => text.replace('"Ptr", Packets, "UInt", 2048,', '"Ptr", Packets, "UShort", 2048,')
	],
	[
		'c',
		(text) =>
			text.replace(
				'status = NavTerminalOutputStatus(ErgoptiOutput_SerializeAttempt(',
				'status = NavTerminalOutputStatus(ErgoptiOutput_MissingSerializeAttempt('
			)
	],
	[
		'c',
		(text) =>
			text.replace(
				'NavTerminalOutputAliasesState(out_inputs, capacity * sizeof(out_inputs[0]))\n\t\t\t|| NavTerminalOutputAliasesState(out_count, sizeof(*out_count))',
				'NavTerminalOutputAliasesState(out_inputs, capacity * sizeof(out_inputs[0]))\n\t\t\t|| false'
			)
	],
	[
		'c',
		(text) => {
			const start = text.indexOf(
				'ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_SerializeTerminalOutputAttempt('
			);
			const end = text.indexOf('/** Commits only the reported exact accepted prefix', start);
			assert(start >= 0 && end > start, 'The early-unlock inverse needs the actual bridge body.');
			const body = text.slice(start, end);
			const changed = body
				.replace('\tLeaveCriticalSection(&g_nav_state.lock);\n', '')
				.replace(
					'\tif (status == ERGOPTI_NAV_STATUS_OK)\n',
					'\tLeaveCriticalSection(&g_nav_state.lock);\n\tif (status == ERGOPTI_NAV_STATUS_OK)\n'
				);
			return text.slice(0, start) + changed + text.slice(end);
		}
	]
];
for (const [name, mutate] of serializationMutations) {
	const changed = mutate(source[name]);
	assert.notEqual(
		changed,
		source[name],
		'A serializer inverse must change its actual source seam.'
	);
	assert.throws(() => check({ ...source, [name]: changed }));
}
console.log(
	`Hook trace source bindings: 37 original + 3 diagnostic + 1 serializer exports and ${mutations.length} original + ${serializationMutations.length} additive negative controls passed.`
);
console.log('Source binding only; native Windows callback execution remains UNRUN.');

/** Receives actual runner/compiler orchestration with recording ports, never a compiler or native child. */
function checkPortableCompilerHostPreparation(
	runnerRoot = __dirname,
	helper = require('./lib/portable-c-compiler.cjs')
) {
	let controls = 0;
	function control(name, callback) {
		try {
			callback();
			controls += 1;
		} catch (error) {
			error.message = name + ': ' + error.message;
			throw error;
		}
	}
	const env = {
		'ProgramFiles(x86)': 'C:\\Program Files (x86)',
		ComSpec: 'C:\\Windows\\System32\\cmd.exe',
		PATH: 'old'
	};
	const install = 'C:\\Program Files\\Microsoft Visual Studio\\2022\\BuildTools';
	const tools = install + '\\VC\\Tools\\MSVC\\14.44.1\\';
	const command = tools + 'bin\\Hostx64\\x64\\cl.exe';
	function ports(platform = 'win32', environment = env) {
		const calls = [];
		return {
			platform,
			env: environment,
			calls,
			exists: () => true,
			spawn(file, args, options) {
				calls.push({ file, args, options });
				if (file === 'cc')
					return { error: Object.assign(new Error('spawnSync cc ENOENT'), { code: 'ENOENT' }) };
				const stdout = file.endsWith('vswhere.exe')
					? install + '\r\n'
					: file === env.ComSpec
						? `INCLUDE=owned-include\r\nLIB=owned-lib\r\nVCToolsInstallDir=${tools}\r\nPath=new\r\nOWNED_UNICODE=é🙂\r\n`
						: '';
				return { status: 0, signal: null, stdout };
			}
		};
	}
	const spec = {
		sources: ['C:\\owned source\\subject.c', 'C:\\owned source\\subject_test.c'],
		binary: 'C:\\owned temp\\subject.exe',
		cwd: 'C:\\owned source',
		sanitize: false
	};
	for (const [file, sources] of [
		['run-windows-replay-route-core.cjs', ['replay_route_core.c', 'replay_route_core_test.c']],
		[
			'run-windows-terminal-output-plan.cjs',
			['replay_route_core.c', 'terminal_output_plan.c', 'terminal_output_plan_test.c']
		],
		['run-windows-hook-trace-core.cjs', ['hook_trace.c', 'hook_trace_test.c']]
	])
		control(file + ' uses the real host compiler contract', () => {
			const recording = ports();
			let removed = 0;
			const filename = path.join(runnerRoot, file);
			const subject = { exports: {} };
			const requirePort = (name) => {
				if (name === 'node:fs')
					return {
						mkdtempSync: () => path.join(runnerRoot, 'owned temporary'),
						rmSync: () => {
							removed += 1;
						}
					};
				if (name === 'node:os') return { tmpdir: () => runnerRoot };
				if (name === 'node:child_process') return { spawnSync: recording.spawn };
				if (name === './lib/portable-c-compiler.cjs')
					return { compilePortable: (request) => helper.compilePortable(request, recording) };
				return require(name);
			};
			new Function(
				'require',
				'module',
				'exports',
				'__dirname',
				'process',
				'console',
				fs.readFileSync(filename, 'utf8')
			)(
				requirePort,
				subject,
				subject.exports,
				runnerRoot,
				{ platform: 'win32', arch: 'x64', env },
				{ log() {} }
			);
			subject.exports.run([]);
			const compilation = recording.calls.find((call) => call.file === command);
			assert.ok(compilation, 'The Windows runner must invoke installed MSVC, not missing cc.');
			assert.deepEqual(
				compilation.args.filter((arg) => arg.endsWith('.c')).map((arg) => path.basename(arg)),
				sources
			);
			for (const flag of ['/TC', '/std:c11', '/W4', '/WX', '/UNDEBUG'])
				assert.ok(compilation.args.includes(flag));
			assert.equal(compilation.options.stdio, 'inherit');
			assert.equal(compilation.options.timeout, 30000);
			assert.equal(
				recording.calls.at(-1).args.length,
				0,
				'Original compiled executable must still run.'
			);
			assert.equal(recording.calls.at(-1).file.endsWith('.exe'), true);
			assert.equal(removed, 1, 'Original owned cleanup remains exactly once.');
		});
	control('MSVC discovery preserves literal quoted setup and one PATH key', () => {
		const recording = ports();
		const result = helper.resolveCompiler(recording);
		assert.equal(result.command, command);
		assert.deepEqual(
			Object.keys(result.env).filter((name) => name.toLowerCase() === 'path'),
			['Path']
		);
		assert.equal(result.env.Path, 'new');
		assert.equal(result.env.OWNED_UNICODE, 'é🙂');
		assert.equal(recording.calls[0].args.includes('-utf8'), true);
		assert.equal(recording.calls[1].options.windowsVerbatimArguments, true);
		assert.equal(recording.calls[1].options.encoding, 'utf16le');
		assert.deepEqual(recording.calls[1].args.slice(0, 4), ['/d', '/u', '/s', '/c']);
		assert.equal(
			recording.calls[1].args[4],
			`""${install}\\VC\\Auxiliary\\Build\\vcvars64.bat" >nul && set"`
		);
		assert.equal(recording.calls[0].options.shell, undefined);
	});
	for (const platform of ['linux', 'darwin'])
		control(platform + ' preserves GNU compiler flags and sanitizer request', () => {
			const recording = ports(platform, { CC: '/literal compiler/cc' });
			helper.compilePortable({ ...spec, sanitize: true }, recording);
			assert.deepEqual(recording.calls[0].args, ['--version']);
			assert.equal(recording.calls[0].file, '/literal compiler/cc');
			assert.deepEqual(recording.calls[1].args, [
				'-std=c11',
				'-Wall',
				'-Wextra',
				'-Werror',
				'-pedantic',
				'-UNDEBUG',
				'-fsanitize=address,undefined',
				'-fno-omit-frame-pointer',
				...spec.sources,
				'-o',
				spec.binary
			]);
			assert.equal(recording.calls[1].options.shell, undefined);
		});
	control('explicit Windows CC remains literal and never enters environment shell', () => {
		const recording = ports('win32', { CC: 'C:\\literal compiler\\clang.exe & not a shell' });
		helper.compilePortable(spec, recording);
		assert.equal(recording.calls.length, 2);
		assert.equal(recording.calls[0].file, recording.env.CC);
		assert.equal(recording.calls[1].options.shell, undefined);
	});
	control('MSVC requested sanitizer refuses before compilation', () => {
		const recording = ports();
		assert.throws(
			() => helper.compilePortable({ ...spec, sanitize: true }, recording),
			/cannot provide.*sanitizer/
		);
		assert.equal(recording.calls.length, 2);
	});
	control('missing compiler discovery stays fatal', () => {
		assert.throws(
			() => helper.resolveCompiler({ ...ports(), exists: () => false }),
			/requires.*vswhere/
		);
	});
	control('failed compiler discovery stays fatal', () => {
		assert.throws(
			() => helper.resolveCompiler({ ...ports(), spawn: () => ({ status: 7, signal: null }) }),
			/exited with 7/
		);
	});
	control('ambiguous installation stays fatal', () => {
		assert.throws(
			() =>
				helper.resolveCompiler({
					...ports(),
					spawn: () => ({ status: 0, signal: null, stdout: install + '\n' + install + '\n' })
				}),
			/exactly one/
		);
	});
	control('partial MSVC environment stays fatal', () => {
		const recording = ports();
		const spawn = recording.spawn;
		assert.throws(
			() =>
				helper.resolveCompiler({
					...recording,
					spawn: (file, args, options) =>
						file === env.ComSpec
							? { status: 0, signal: null, stdout: 'INCLUDE=only\n' }
							: spawn(file, args, options)
				}),
			/did not publish/
		);
	});
	for (const result of [
		{ error: Object.assign(new Error('missing explicit CC'), { code: 'ENOENT' }) },
		{ status: 9, signal: null },
		{ status: null, signal: 'SIGTERM' }
	])
		control(
			'compiler failure cannot become success ' +
				(result.error?.code || result.signal || result.status),
			() => {
				assert.throws(() =>
					helper.compilePortable(spec, {
						...ports('linux', { CC: 'explicit-cc' }),
						spawn: () => result
					})
				);
			}
		);
	control('an explicit unprovisioned MSVC compiler refuses', () => {
		assert.throws(
			() => helper.resolveCompiler(ports('win32', { CC: 'cl.exe' })),
			/provisioned environment/
		);
	});
	control('implicit MSVC flags cannot silently disable the original C assertions', () => {
		assert.throws(
			() => helper.compilePortable(spec, ports('win32', { ...env, _CL_: '/DNDEBUG' })),
			/implicit flags.*assertion contract/
		);
	});
	control('unsafe environment shell path refuses', () => {
		const recording = ports();
		assert.throws(
			() =>
				helper.resolveCompiler({
					...recording,
					spawn: () => ({ status: 0, signal: null, stdout: 'C:\\bad%variable%\n' })
				}),
			/closed shell argument/
		);
	});
	return { recording_controls: controls, real_compilers: 0, native_children: 0 };
}

console.log(
	'Portable C host preparation recording controls:',
	checkPortableCompilerHostPreparation()
);
