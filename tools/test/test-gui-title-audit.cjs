// tools/test/test-gui-title-audit.cjs

/**
 * Exercises the title guard through its real CLI in private fixture repositories.
 * The mutations cover raw windows, branded wrapper inputs and translated titles.
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const titles = require('../codegen/codegen-window-titles.cjs');
const audit = path.resolve(__dirname, '../lint/audit-gui-titles.cjs');
const repository = path.resolve(__dirname, '../..');
const sharedManifest = JSON.parse(fs.readFileSync(path.join(repository, titles.SOURCE), 'utf8'));
const localeDirectory = path.join(repository, 'static/ergopti_plus/_shared/data/locales');
const localeNames = fs.readdirSync(localeDirectory).filter((name) => name.endsWith('.json'));
assert.equal(localeNames.length, 21, 'every shipped locale participates in the title policy');
for (const locale of localeNames) {
	const strings = JSON.parse(fs.readFileSync(path.join(localeDirectory, locale), 'utf8'));
	for (const [app, entry] of Object.entries(sharedManifest.apps)) {
		assert.equal(
			typeof strings[entry.title_key],
			'string',
			`${locale}: ${app} has its title translation`
		);
		assert.equal(
			/^\s*Ergopti(?:Plus)?\b/.test(strings[entry.title_key]),
			false,
			`${locale}: ${app} passes a bare title to the shared policy`
		);
	}
}
/** Verifies the real folder owner remains reachable without native calls in infra. */
function assertFolderAdapterOwnership(sources) {
	const code = (name) => sources[name].replace(/^\s*;.*$/gm, '');
	assert.match(
		code('adapter'),
		/class\s+_Ui_FolderNative\s*\{/,
		'the adapter owns the native ABI class'
	);
	assert.doesNotMatch(
		code('infra'),
		/class\s+_Ui_FolderNative\s*\{/,
		'infra cannot duplicate the native ABI class'
	);
	assert.doesNotMatch(
		code('infra'),
		/\b(?:DllCall|CallbackCreate|CallbackFree)\s*\(/,
		'native calls belong to the adapter rather than folder orchestration'
	);
	for (const method of [
		'SHBrowseForFolderW',
		'GetWindowThreadProcessId',
		'SetWindowTextW',
		'CoTaskMemFree'
	])
		assert.ok(
			code('adapter').includes(method),
			`the adapter retains the actual ${method} primitive`
		);
	assert.match(
		code('infra'),
		/Native\s*:=\s*_Ui_FolderNative\b/,
		'the actual folder owner uses the native adapter'
	);
	assert.match(
		code('infra'),
		/^#Include %A_LineFile%\\\.\.\\\.\.\\adapters\\native_folder_picker\.ahk$/m,
		'the folder owner includes its adapter for both production and private children'
	);
	assert.match(
		code('dialogs'),
		/^#Include %A_LineFile%\\\.\.\\native_folder_picker\.ahk$/m,
		'the caption delegate includes the actual folder orchestration'
	);
	assert.match(
		code('entry'),
		/^#Include infra\/native_dialogs\.ahk$/m,
		'the production entry reaches the same caption owner'
	);
	assert.match(
		code('runner'),
		/^#Include \.\.\/infra\/native_dialogs\.ahk$/m,
		'the headless runner reaches the same caption owner'
	);
}
const folderOwnerSources = Object.fromEntries(
	Object.entries({
		adapter: 'adapters/native_folder_picker.ahk',
		infra: 'infra/native_folder_picker.ahk',
		dialogs: 'infra/native_dialogs.ahk',
		entry: 'ErgoptiPlus.ahk',
		runner: 'tests/run_all.ahk'
	}).map(([name, relative]) => [
		name,
		fs
			.readFileSync(path.join(repository, 'static/ergopti_plus/windows', relative), 'utf8')
			.replace(/^\uFEFF/, '')
	])
);
assertFolderAdapterOwnership(folderOwnerSources);
const folderMutations = [
	{
		...folderOwnerSources,
		infra: folderOwnerSources.infra + '\nDllCall("Shell32\\SHBrowseForFolderW")\n'
	},
	{ ...folderOwnerSources, infra: folderOwnerSources.infra + '\nCallbackCreate(Callback)\n' },
	{ ...folderOwnerSources, infra: folderOwnerSources.infra + '\nclass _Ui_FolderNative {}\n' },
	{
		...folderOwnerSources,
		infra: folderOwnerSources.infra.replace(/^#Include.*native_folder_picker\.ahk$/m, '')
	},
	{
		...folderOwnerSources,
		entry: folderOwnerSources.entry.replace(/^#Include infra\/native_dialogs\.ahk$/m, '')
	},
	{
		...folderOwnerSources,
		runner: folderOwnerSources.runner.replace(/^#Include \.\.\/infra\/native_dialogs\.ahk$/m, '')
	}
];
for (const mutant of folderMutations)
	assert.throws(
		() => assertFolderAdapterOwnership(mutant),
		assert.AssertionError,
		'native ownership and both real include graphs must reject each independent bypass'
	);
console.log(
	`Native folder adapter provenance mutations: ${folderMutations.length}/${folderMutations.length} passed.`
);

/** Rejects UI family coupling which can hide real folder ABI failures. */
function assertNativePolicyFamilyIsolation(source) {
	const body = (name) => {
		const found = source.match(new RegExp(`^${name}\\([^\\n]*\\) \\{\\n([\\s\\S]*?)^\\}`, 'm'));
		assert.ok(found && found[1].trim(), `${name} has a nonempty actual native case body`);
		return found[1];
	};
	const families = [
		[
			'dialogs',
			'_NDT_ActualNativeCaptionsAndResults',
			'_NDT_CheckDialogPolicy',
			'_NDT_ProbeSource'
		],
		[
			'file_picker',
			'_NDT_ActualNativeFilePickerCaptionsAndResults',
			'_NDT_CheckFilePickerPolicy',
			'_NDT_FilePickerProbeSource'
		],
		[
			'folder_picker',
			'_NDT_ActualNativeFolderPickerCaptionsAndResults',
			'_NDT_CheckFolderPickerPolicy',
			'_NDT_FolderPickerProbeSource'
		]
	];
	for (const [family, wrapper, handler, probe] of families) {
		assert.match(
			source,
			new RegExp(`^Test\\("[^"\\n]+\\(shared-window-titles\\)"[,]\\s*${wrapper}\\)`, 'm'),
			`${family} registers an independent case with the actual test runner`
		);
		assert.equal(
			body(wrapper).trim(),
			`_NDT_RunPolicyFamily("${family}", ${handler})`,
			`${family} cannot depend on another native UI family completing`
		);
		const checks = body(handler);
		assert.ok(
			checks.includes(`${probe}(Artifact, Owner)`),
			`${family} invokes its real native child`
		);
		assert.ok(
			checks.includes('_NDT_RunChild(A_AhkPath,'),
			`${family} checks owned native process completion`
		);
		for (const [, otherWrapper, otherHandler, otherProbe] of families) {
			if (otherHandler === handler) continue;
			for (const unrelated of [otherWrapper, otherHandler, otherProbe])
				assert.equal(
					checks.includes(`${unrelated}(`),
					false,
					`${family} cannot invoke ${unrelated}`
				);
		}
	}
	const ownership = body('_NDT_RunPolicyFamily');
	for (const invariant of [
		'"\\ergopti_native_" . Family',
		'Cases := _NDT_PolicyCases()',
		'generator.main(target)',
		'Owner := _NDT_NativeDialogOwner()',
		'CheckPolicy.Call(Index, Spec, Fixture, Artifact, Owner, Ownership)',
		'if Ownership.CanRetire',
		'DirDelete(Root, true)'
	])
		assert.ok(ownership.includes(invariant), `each family retains ${invariant}`);
	assert.match(
		ownership,
		/for Index, Spec in Cases \{[\s\S]*CheckPolicy\.Call/,
		'every family checks all independently generated policy cases'
	);
	const policies = body('_NDT_PolicyCases');
	assert.equal(
		(policies.match(/Expected:/g) || []).length,
		5,
		'each native family retains all five independent policy variants'
	);
	const picker = body('_NDT_FilePickerProbeSource');
	const baseline =
		'_NFPBaseline := FileSelect(35, _NFPOwnedFile, "Owned native baseline", "Owned files (*.txt)")';
	assert.ok(
		picker.includes(baseline),
		'the independent baseline calls the actual builtin directly with the exact filter'
	);
	assert.doesNotMatch(
		picker,
		/_NFPBaseline\s*:=\s*Ui_FileSelect\s*\(/,
		'the public delegate cannot answer its own baseline'
	);
	assert.ok(
		picker.indexOf(baseline) < picker.indexOf('_NFPSelected := Ui_FileSelect('),
		'the native baseline is observed before the delegate'
	);
	assert.ok(
		picker.includes('Type(_NFPBaseline) . "|" . _NFPBaseline'),
		'the direct baseline preserves native cancellation and result type'
	);
	const pickerChecks = body('_NDT_CheckFilePickerPolicy');
	for (const receipt of ['filter', 'types']) {
		const comparison = new RegExp(
			'AssertEqual\\(FileRead\\(PickerRoot \\. "\\\\baseline\\.' +
				receipt +
				'", "UTF-8"\\),\\s*FileRead\\(PickerRoot \\. "\\\\" \\. Kind \\. "\\.' +
				receipt +
				'", "UTF-8"\\)'
		);
		assert.match(
			pickerChecks,
			comparison,
			'each complete native receipt is compared exactly against the independent baseline'
		);
	}
	assert.ok(
		pickerChecks.includes('"items=2,truncated=0,selected=1|"'),
		'the actual direct baseline requires two filters and the first selection'
	);
	assert.ok(
		pickerChecks.includes('"String|", FileRead(PickerRoot . "\\baseline.result"'),
		'the direct native baseline must acknowledge cancellation'
	);
	assert.ok(
		body('_NDT_CheckFolderPickerPolicy').includes('"retired", FileRead('),
		'the independent folder case retains actual HWND retirement assertions'
	);
}
const nativePolicySource = fs.readFileSync(
	path.join(repository, 'static/ergopti_plus/windows/tests/unit/test_native_dialog_titles.ahk'),
	'utf8'
);
assertNativePolicyFamilyIsolation(nativePolicySource);
for (const original of [
	'AssertEqual(FileRead(PickerRoot . "\\baseline.filter", "UTF-8"),',
	'AssertEqual(FileRead(PickerRoot . "\\baseline.types", "UTF-8"),'
]) {
	const mutant = nativePolicySource.replace(original, original.replace('baseline', 'selected'));
	assert.notEqual(
		mutant,
		nativePolicySource,
		'each baseline mutation changes its actual comparison'
	);
	assert.throws(
		() => assertNativePolicyFamilyIsolation(mutant),
		assert.AssertionError,
		'a delegate cannot supply its own expected native receipt'
	);
}
/** Guards statement separators separately from escaped child string contents. */
function assertNativeProbeStatementSeparators(source) {
	const body = source.match(/^_NDT_FilePickerProbeSource\([^\n]*\) \{\n([\s\S]*?)^\}/m);
	assert.ok(body && body[1].trim(), 'the actual file-picker source producer is present');
	const statements = body[1].split('\n').filter((line) => line.includes('PickerTypeReceipt .= '));
	assert.equal(statements.length, 2, 'both bounded native type-label receipts participate');
	for (const statement of statements) {
		assert.match(
			statement,
			/' \. "`n"$/,
			'generated native statements end with physical LF rather than literal backtick-n'
		);
		assert.ok(
			statement.includes('"``r", "\\r"') && statement.includes('"``n", "\\n"'),
			'captured text escapes CR/LF inside the native string literal independently'
		);
	}
	return statements;
}
const nativeReceiptStatements = assertNativeProbeStatementSeparators(nativePolicySource);
for (const statement of nativeReceiptStatements) {
	const mutant = nativePolicySource.replace(statement, statement.replace(/"`n"$/, '"``n"'));
	assert.notEqual(
		mutant,
		nativePolicySource,
		'each separator mutation targets one actual producer'
	);
	assert.throws(
		() => assertNativeProbeStatementSeparators(mutant),
		assert.AssertionError,
		'each original invalid native statement separator is independently rejected'
	);
}
console.log('Native file-picker statement separator mutations: 2/2 passed.');

/** Guards actual native shell-view proof and its independent no-filter control. */
function assertNativeFileFilterBehavior(source) {
	const body = (name) => {
		const found = source.match(new RegExp(`^${name}\\([^\\n]*\\) \\{\\n([\\s\\S]*?)^\\}`, 'm'));
		assert.ok(found && found[1].trim(), `${name} participates in the native behavioral proof`);
		return found[1];
	};
	assert.match(
		source,
		/^Test\("native file filter:[^"\n]+\(shared-window-titles\)"[,]\s*_NDT_ActualNativeFileFilterBehavior\)/m,
		'genuine filter behavior registers independently of the original friendly-label case'
	);
	assert.equal(
		body('_NDT_ActualNativeFileFilterBehavior').trim(),
		'_NDT_RunPolicyFamily("file_filter_behavior", _NDT_CheckFileFilterBehaviorPolicy)',
		'the behavioral family retains all five real generated caption policies'
	);
	assert.ok(
		source.indexOf('Test("native file filter:') > source.indexOf('Test("native file picker:'),
		'the original exact label failure cannot prevent the independent behavioral case running'
	);
	const checks = body('_NDT_CheckFileFilterBehaviorPolicy');
	for (const invariant of [
		'_NDT_FileFilterObserverSource(_NDT_FileFilterUiaOwner())',
		'_NDT_FileFilterBehaviorProbeSource(Artifact, Owner, FilterObserver)',
		'for FilterKind in ["selected", "cancelled"]',
		'FileRead(FilterRoot . "\\" . FilterKind . ".observer.behavior", "UTF-8")',
		'FileRead(FilterRoot . "\\" . FilterKind . ".retirement", "UTF-8")',
		'"Array|0"',
		'"\\selected.result"',
		'if Index != 5',
		'_NDT_MutateDelegatedFilter(FilterSource, "")',
		'_NDT_MutateDelegatedFilter(FilterSource, "Changed label (*.txt)")',
		'["/ErrorStdOut", LabelMutationHarness, LabelMutationRoot], Ownership, 2, FilterBudgets.ChildMs)',
		'"Owned BIN visible under the restricted file filter", _NDT_RunChild(A_AhkPath,',
		'["/ErrorStdOut", MutationHarness, MutationRoot], Ownership, 2, FilterBudgets.ChildMs)'
	])
		assert.ok(checks.includes(invariant), `the real positive/control cases retain ${invariant}`);
	assert.ok(
		checks.indexOf('if Index != 5') > checks.indexOf('"Array|0"'),
		'all positive policies and modal assertions precede the no-filter control'
	);
	const mutation = body('_NDT_MutateDelegatedFilter');
	for (const invariant of [
		'for NativeOptions in ["35", \'"M35"\']',
		"Boundary := 'Ui_FileSelect('",
		"Changed := 'Ui_FileSelect('",
		'StrReplace(ProbeSource, Boundary, Changed, , &Mutations)',
		'AssertEqual(1, Mutations',
		'return ProbeSource'
	])
		assert.ok(
			mutation.includes(invariant),
			'filter controls mutate only each exact public delegate call'
		);
	assert.doesNotMatch(
		mutation,
		/(?<!Ui_)\bFileSelect\(/,
		'filter controls cannot corrupt the independent builtin baseline'
	);
	const observer = body('_NDT_FileFilterObserverSource');
	for (const invariant of [
		'ObserverProcess == DllCall("GetCurrentProcessId", "UInt")',
		'UIA.ElementFromHandle(ObserverView, , false)',
		'UIA.ConnectionTimeout := ObserverUiaTimeoutMs',
		'UIA.TransactionTimeout := ObserverUiaTimeoutMs',
		'ObserverElement.ProcessId != ObserverProcess',
		'StrSplit(FileRead(ObserverArgs[8], "UTF-8"), "|")',
		'ObserverItems[1] != ObserverExpectedItems[1] || ObserverItems[2] != ObserverExpectedItems[2]',
		'"shell32\\SHCreateItemFromParsingName"',
		'ComCall(5, ObserverItem, "UInt", 0, "Ptr*", &ObserverDisplay)',
		'return ObserverName == ObserverTypedName ? [ObserverName] : [ObserverName, ObserverTypedName]',
		'OwnerElement.FindElements([{Type: "ListItem", Name: OwnerName}, {Type: "DataItem", Name: OwnerName}])',
		'OwnerMatch.ProcessId != OwnerProcess',
		'if !OwnerMatch.IsOffscreen',
		'WinGetPID("ahk_id " . OwnerHandle) != OwnerProcess',
		'DllCall("GetDlgCtrlID", "Ptr", OwnerView, "Int") != 1121',
		'DllCall("GetDlgCtrlID", "Ptr", OwnerType, "Int") != 1136',
		'ControlChooseIndex(2, ObserverType)',
		'ControlChooseIndex(1, ObserverType)',
		'((A_TickCount - ObserverStarted) & 0xFFFFFFFF) >= ObserverWaitMs',
		'txt-visible|bin-hidden|all-files-bin-visible|restored-txt-visible|restored-bin-hidden|separate-client|owner-fenced',
		'FileAppend(ObserverFailure.Message, A_Args[1] . ".failure", "UTF-8-RAW")'
	])
		assert.ok(observer.includes(invariant), `the separate native client retains ${invariant}`);
	for (const phase of [
		'entry',
		'com',
		'shell-items',
		'uia-provider',
		'restricted-txt',
		'restricted-bin',
		'all-files',
		'restored',
		'complete'
	])
		assert.ok(
			observer.includes(`_NFO_Phase("${phase}", ObserverPhaseStarted)`),
			`the owned observer retains its exact ${phase} progress receipt`
		);
	assert.ok(
		observer.includes('ObserverPhaseFile.Write(ObserverPhaseToken . "|elapsed_ms="'),
		'phase receipts contain only fixed stage tokens and elapsed milliseconds'
	);
	assert.equal(
		observer.includes('InStr('),
		false,
		'no loose filename substring can prove file visibility'
	);
	assert.equal(
		observer.includes('GetChildren('),
		false,
		'the client never dumps unrelated view children'
	);
	const capture = body('_NDT_FileFilterCaptureSource');
	for (const invariant of [
		'DllCall("GetDlgCtrlID", "Ptr", PickerViewCandidate, "Int") == 1121',
		'DllCall("IsChild", "Ptr", Hwnd, "Ptr", PickerShellView)',
		'_NFPRoot . "\\baseline.filter", _NFPViewWaitMs, _NFPUiaTimeoutMs]',
		'PickerObserverHandle := ComObject("WScript.Shell").Exec(PickerObserverCommand)',
		'SubStr(FileRead(PickerObserverReceipt . ".phase", "UTF-8"), 1, 128)',
		'PickerObserverHandle.StdOut.ReadAll()',
		'PickerObserverHandle.StdErr.ReadAll()',
		'if PickerObserverErrors != ""',
		'PickerObserverHandle.Terminate()',
		'((A_TickCount - PickerObserverStarted) & 0xFFFFFFFF) < _NFPObserverBudgetMs',
		'if PickerObserverExit != 0',
		'PickerObserverOutput != "owned-filter-observed" || PickerObserverFailure != ""',
		'FileRead(PickerObserverReceipt . ".ack", "UTF-8") != "owned-filter-observed"'
	])
		assert.ok(capture.includes(invariant), `the modal owner retains ${invariant}`);
	assert.equal(
		capture.includes('GetDlgItem'),
		false,
		'the real shell view is found among owned descendants'
	);
	const probe = body('_NDT_FileFilterBehaviorProbeSource');
	for (const invariant of [
		'BehaviorSource := _NDT_FilePickerProbeSource(Artifact, Owner)',
		'DirCreate(_NFPRoot . "\\items")',
		'"\\items\\visible-filter-owned.txt"',
		'"\\items\\hidden-filter-owned.bin"',
		'if _NFPMode != "baseline" {',
		'_NDT_FileFilterCaptureSource()',
		'AssertEqual(1, ObserverBoundaries',
		'DllCall("IsWindow", "Ptr", _NFPLastHwnd)',
		'AssertEqual(1, RetirementBoundaries'
	])
		assert.ok(probe.includes(invariant), `the actual native producer retains ${invariant}`);
	assert.match(
		source,
		/^_NDT_RunChild\([^\n]*TimeoutMs := 15000\) \{/m,
		'unrelated native families preserve their original process bound'
	);
	assert.match(
		body('_NDT_RunChild'),
		/TickElapsed\(Started\) < TimeoutMs/,
		'the owned process enforces its selected bound'
	);
	const budgets = body('_NDT_FileFilterBudgets');
	for (const invariant of [
		'UiaTimeoutMs := 500',
		'ViewWaitMs := 4000',
		'ShellSpellings := 2',
		'VisibleCalls := ShellSpellings * 3',
		'AbsentCalls := ShellSpellings',
		'TransitionCalls := VisibleCalls * 2 + VisibleCalls + AbsentCalls',
		'SetupCalls := 2',
		'ObserverMs := 3 * ViewWaitMs + (TransitionCalls + AbsentCalls + SetupCalls) * UiaTimeoutMs',
		'ChildMs: 15000 + 2 * ObserverMs'
	])
		assert.ok(
			budgets.includes(invariant),
			'the process bounds derive from unchanged native query and transition bounds'
		);
	for (const index of [1, 2])
		assert.ok(
			observer.includes(
				'ControlChooseIndex(' +
					index +
					', ObserverType)\' . "`n"\n\t\t. \'ObserverStarted := A_TickCount'
			),
			'each native filter transition starts its own settling interval'
		);
	for (const invariant of [
		'ObserverWaitMs := Integer(ObserverArgs[9])',
		'ObserverUiaTimeoutMs := Integer(ObserverArgs[10])'
	])
		assert.ok(
			observer.includes(invariant),
			'the native client receives its canonical bounds through actual arguments'
		);
	for (const field of ['ObserverMs', 'ViewWaitMs', 'UiaTimeoutMs'])
		assert.ok(
			probe.includes('FilterBudgets.' + field),
			'the picker consumes every canonical native budget'
		);
	assert.ok(
		checks.includes(
			'["/ErrorStdOut", FilterHarness, FilterRoot], Ownership, 0, FilterBudgets.ChildMs)'
		),
		'the genuine child uses the bound for both real observers'
	);
}
assertNativeFileFilterBehavior(nativePolicySource);
const nativeBehaviorMutations = [
	nativePolicySource.replace('UiaTimeoutMs := 500', 'UiaTimeoutMs := 1000'),
	nativePolicySource.replace('ViewWaitMs := 4000', 'ViewWaitMs := 8000'),
	nativePolicySource.replace('ObserverMs := 3 * ViewWaitMs', 'ObserverMs := 30 * ViewWaitMs'),
	nativePolicySource.replace(
		'ObserverWaitMs := Integer(ObserverArgs[9])',
		'ObserverWaitMs := 8000'
	),
	nativePolicySource.replace('Test("native file filter:', 'DisabledCase("native file filter:'),
	nativePolicySource.replace('Name: OwnerName}', 'Name: OwnerName, mm: "SubString"}'),
	nativePolicySource.replace(
		'ControlChooseIndex(2, ObserverType)',
		'ControlChooseIndex(1, ObserverType)'
	),
	nativePolicySource.replace('ObserverProcess == DllCall("GetCurrentProcessId", "UInt")', 'false'),
	nativePolicySource.replace('if Index != 5', 'if Index != 1'),
	nativePolicySource.replace(
		'_NFO_Phase("uia-provider", ObserverPhaseStarted)',
		'_NFO_Phase("skipped", ObserverPhaseStarted)'
	),
	nativePolicySource.replace(
		'SubStr(FileRead(PickerObserverReceipt . ".phase", "UTF-8"), 1, 128)',
		'"phase skipped"'
	),
	nativePolicySource.replace(
		'((A_TickCount - PickerObserverStarted) & 0xFFFFFFFF) < _NFPObserverBudgetMs',
		'((A_TickCount - PickerObserverStarted) & 0xFFFFFFFF) < 10000'
	),
	nativePolicySource.replace('if PickerObserverErrors != ""', 'if false'),
	nativePolicySource.replace('PickerObserverHandle.Terminate()', 'PickerObserverHandle.Status'),
	nativePolicySource.replace(
		'Ownership, 2, FilterBudgets.ChildMs),\n\t\t"removing the real native filter',
		'Ownership, 0, FilterBudgets.ChildMs),\n\t\t"removing the real native filter'
	)
];
for (const mutant of nativeBehaviorMutations) {
	assert.notEqual(
		mutant,
		nativePolicySource,
		'each native behavior mutation targets an actual owner'
	);
	assert.throws(() => assertNativeFileFilterBehavior(mutant), assert.AssertionError);
}
console.log(
	`Native file-filter behavior mutations: ${nativeBehaviorMutations.length}/${nativeBehaviorMutations.length} passed.`
);

for (const [before, after, guard] of [
	[
		'_NFPBaseline := FileSelect(',
		'_NFPBaseline := Ui_FileSelect(',
		assertNativePolicyFamilyIsolation
	],
	[
		'_NFPBaseline := FileSelect(35, _NFPOwnedFile, "Owned native baseline", "Owned files (*.txt)")',
		'_NFPBaseline := FileSelect(35, _NFPOwnedFile, "Owned native baseline", "Wrong files (*.txt)")',
		assertNativePolicyFamilyIsolation
	],
	[
		'StrSplit(FileRead(ObserverArgs[8], "UTF-8"), "|")',
		'StrSplit(FileRead(ObserverArgs[7], "UTF-8"), "|")',
		assertNativeFileFilterBehavior
	],
	[
		'ObserverItems[1] != ObserverExpectedItems[1]',
		'ObserverItems[1] != ObserverItems[1]',
		assertNativeFileFilterBehavior
	],
	["Boundary := 'Ui_FileSelect('", "Boundary := 'FileSelect('", assertNativeFileFilterBehavior],
	[
		'_NDT_MutateDelegatedFilter(FilterSource, "")',
		'_NDT_MutateDelegatedFilter(FilterSource, "Owned files (*.txt)")',
		assertNativeFileFilterBehavior
	],
	['if _NFPMode != "baseline" {', 'if true {', assertNativeFileFilterBehavior]
]) {
	const mutant = nativePolicySource.replace(before, after);
	assert.notEqual(
		mutant,
		nativePolicySource,
		'each independent baseline mutation targets a real source boundary'
	);
	assert.throws(
		() => guard(mutant),
		assert.AssertionError,
		'native baseline ownership and exact observations reject each bypass'
	);
}
console.log('Native independent file baseline mutations: 7/7 passed.');

const nativePolicyMutations = [
	nativePolicySource.replace(
		/Test\("native folder picker:[\s\S]*?_NDT_ActualNativeFolderPickerCaptionsAndResults\)/,
		''
	),
	nativePolicySource.replace(
		'_NDT_RunPolicyFamily("folder_picker", _NDT_CheckFolderPickerPolicy)',
		'_NDT_RunPolicyFamily("folder_picker", _NDT_CheckFilePickerPolicy)'
	),
	nativePolicySource.replace(
		'FileAppend(_NDT_FolderPickerProbeSource(Artifact, Owner)',
		'FileAppend(_NDT_FilePickerProbeSource(Artifact, Owner)'
	),
	nativePolicySource.replace(
		'CheckPolicy.Call(Index, Spec, Fixture, Artifact, Owner, Ownership)',
		'_NDT_CheckFilePickerPolicy(Index, Spec, Fixture, Artifact, Owner, Ownership)'
	),
	nativePolicySource.replace('generator.main(target)', 'generator.skipped(target)'),
	nativePolicySource.replaceAll(
		'if Ownership.CanRetire\n\t\t\tDirDelete(Root, true)',
		'if true\n\t\t\tDirDelete(Root, true)'
	),
	nativePolicySource.replace(
		'AssertEqual(FileRead(PickerRoot . "\\baseline.filter", "UTF-8"),',
		'AssertEqual(FileRead(PickerRoot . "\\selected.filter", "UTF-8"),'
	)
];
for (const mutant of nativePolicyMutations) {
	assert.notEqual(
		mutant,
		nativePolicySource,
		'each independent family mutation changes actual source'
	);
	assert.throws(
		() => assertNativePolicyFamilyIsolation(mutant),
		assert.AssertionError,
		'native UI families reject missing registration, coupling and weakened receipts'
	);
}
console.log(
	`Native UI policy family isolation mutations: ${nativePolicyMutations.length}/${nativePolicyMutations.length} passed.`
);

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-title-audit-'));
const sourcePath = (platform) =>
	`static/ergopti_plus/${platform}/ui/error_dialog/init.${platform === 'windows' ? 'ahk' : 'lua'}`;
function put(relative, content) {
	const target = path.join(root, relative);
	fs.mkdirSync(path.dirname(target), { recursive: true });
	fs.writeFileSync(target, content);
}
const cases = [
	[
		'windows',
		'FileSelect(33, Root, "Tools", "Owned files (*.txt)")',
		1,
		'raw native file picker cannot bypass policy'
	],
	[
		'windows',
		'FileSelect("M33", Root, "ErgoptiPlus — Tools")',
		1,
		'prebranded file picker still bypasses policy'
	],
	[
		'windows',
		'Ui_FileSelect(33, "ErgoptiPlus path", "Tools", "ErgoptiPlus files (*.txt)")',
		0,
		'only the third file picker argument is a caption'
	],
	[
		'windows',
		'Ui_FileSelect(33, Root, "ErgoptiPlus — Tools")',
		1,
		'file picker caption cannot be branded twice'
	],
	[
		'windows',
		'Ui_FileSelect(33, Root, t("editor.personal_info.window_title"))',
		1,
		'translated file picker caption cannot retain stale branding'
	],
	['windows', 'Ui_FileSelect(33, Root)', 0, 'omitted file picker caption belongs to shared policy'],
	[
		'windows',
		'Ui_FileSelect(Options := "", RootDir := "", Title := "", Filter := "") {\nreturn FileSelect(Options, RootDir, WindowTitle(Title), Filter)\n}',
		0,
		'actual file picker delegate owns the third argument',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Ui_FileSelect(Options, RootDir, Title, Filter) {\nreturn FileSelect(Options, RootDir, Title, Filter)\n}',
		1,
		'file picker owner cannot drop policy',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Ui_FileSelect(Options, RootDir, Title, Filter) {\nreturn FileSelect(Options, WindowTitle(Title), Title, Filter)\n}',
		1,
		'file picker policy on the root path does not own the caption',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Other(Options, RootDir, Title, Filter) {\nreturn FileSelect(Options, RootDir, WindowTitle(Title), Filter)\n}',
		1,
		'another file picker function cannot duplicate the native owner',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	['windows', 'MsgBox("Body", "Tools")', 1, 'raw message box has no caption owner'],
	[
		'windows',
		'MsgBox("Body", "ErgoptiPlus — Tools")',
		1,
		'prebranded message box still bypasses policy'
	],
	[
		'windows',
		'MsgBox("Body", DynamicTitle, "YesNo")',
		1,
		'dynamic message box cannot bypass policy'
	],
	[
		'windows',
		'MsgBox(Body := "Body", DynamicTitle, "YesNo")',
		1,
		'argument assignment cannot disguise a raw native call as a definition'
	],
	[
		'windows',
		'if MsgBox("Body", "Tools", "YesNo") {\nreturn\n}',
		1,
		'conditional raw call is not a function declaration'
	],
	[
		'windows',
		'InputBox("Body", "Tools", "Password", "Secret")',
		1,
		'raw native input bypass is blocking'
	],
	[
		'windows',
		'Ui_MsgBox("ErgoptiPlus appears in this body", "Tools", "Icon!")',
		0,
		'only caption arguments are branded'
	],
	[
		'windows',
		'Ui_MsgBox("Body", "ErgoptiPlus — Tools")',
		1,
		'message caption cannot be branded twice'
	],
	[
		'windows',
		'if Ui_MsgBox("Body", "ErgoptiPlus — Tools", "YesNo") {\nreturn\n}',
		1,
		'conditional wrapper caption is still checked'
	],
	[
		'windows',
		'Ui_InputBox("Body", t("editor.personal_info.window_title"))',
		1,
		'one translated prebranded input caption is blocking'
	],
	[
		'windows',
		'Title := "ErgoptiPlus — Tools"\nUi_InputBox("Body", Title)',
		1,
		'input caption aliases cannot bypass double-prefix guard'
	],
	[
		'windows',
		'Ui_MsgBox("Body")\nUi_InputBox("Body", "")',
		0,
		'empty captions belong to shared product policy'
	],
	[
		'windows',
		'Ui_MsgBox(Text := "", Title := "", Options := "") {\nreturn MsgBox(Text, WindowTitle(Title), Options)\n}',
		0,
		'actual native message delegate owns its caption',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Ui_InputBox(Prompt := "", Title := "", Options := "", Default := "") {\nreturn InputBox(Prompt, WindowTitle(Title), Options, Default)\n}',
		0,
		'actual native input delegate owns its caption',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Ui_MsgBox(Text, Title, Options) {\nreturn MsgBox(Text, Title, Options)\n}',
		1,
		'central delegate itself cannot drop policy',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Other(Text, Title, Options) {\nreturn MsgBox(Text, WindowTitle(Title), Options)\n}',
		1,
		'other function in owner file cannot bypass central delegate',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Ui_MsgBox(Text, Title, Options) {\nreturn MsgBox(Text, WindowTitle(Title), Options)\n}',
		1,
		'copying a delegate to another file cannot create another caption owner'
	],
	[
		'windows',
		'Bundle_Init() {\n' + 'MsgBox("Fatal", "ErgoptiPlus")\n'.repeat(6) + '}',
		1,
		'all six former bootstrap exceptions now require shared policy',
		'static/ergopti_plus/windows/infra/bundle.ahk'
	],
	[
		'windows',
		'Bundle_Init() {\n' + 'MsgBox("Fatal", "ErgoptiPlus")\n'.repeat(7) + '}',
		1,
		'additional bootstrap native calls cannot bypass shared policy',
		'static/ergopti_plus/windows/infra/bundle.ahk'
	],
	[
		'windows',
		'ErgoptiGlobalErrorHandler(Exc, Mode) {\nMsgBox("Fatal", "ErgoptiPlus — erreur de démarrage")\n}',
		1,
		'the original startup error caption no longer bypasses policy',
		'static/ergopti_plus/windows/infra/error_net.ahk'
	],
	[
		'windows',
		'Bundle_Init() {\n' + 'Ui_MsgBox("Fatal", "")\n'.repeat(6) + '}',
		0,
		'all six bundle startup calls use the shared owner',
		'static/ergopti_plus/windows/infra/bundle.ahk'
	],
	[
		'windows',
		'ErgoptiGlobalErrorHandler(Exc, Mode) {\nUi_MsgBox("Fatal", "erreur de démarrage")\n}',
		0,
		'the startup error supplies a brandless caption',
		'static/ergopti_plus/windows/infra/error_net.ahk'
	],
	[
		'windows',
		'Other() {\nMsgBox("Fatal", "ErgoptiPlus")\n}',
		1,
		'bootstrap file cannot authorize another native owner',
		'static/ergopti_plus/windows/infra/error_net.ahk'
	],
	[
		'windows',
		'g := Gui("+Resize", t("common.error_title"))',
		1,
		'translated raw Gui bypass is blocking'
	],
	['windows', 'g := Gui("+Resize", DynamicTitle)', 1, 'dynamic raw Gui bypass is blocking'],
	[
		'windows',
		'g := Gui("+Resize", "ErgoptiPlus — Tools")',
		1,
		'branded raw Gui still bypasses shared policy'
	],
	[
		'windows',
		'g := Gui("-Caption +AlwaysOnTop", "Overlay")',
		0,
		'captionless overlays retain native options'
	],
	['windows', 'return Gui(Options, WindowTitle(Name))', 0, 'native factory composes its caption'],
	[
		'windows',
		'First() {\nTitle := "ErgoptiPlus — Tools"\n}\nSecond(Title) {\ng := Gui_Create("", Title)\n}',
		0,
		'do not borrow aliases across AHK functions'
	],
	[
		'macos',
		'local function first()\n local title = "ErgoptiPlus — Tools"\nend\nlocal function second(title)\n ui_builder.window_title(title)\nend',
		0,
		'do not borrow aliases across Lua functions'
	],
	[
		'windows',
		'return Gui_Create("+Resize +AlwaysOnTop +MinSize440x320", "ErgoptiPlus — " . t("common.error_title"))',
		1,
		'real error dialog double prefix'
	],
	[
		'windows',
		'return Gui_Create("+Resize +AlwaysOnTop +MinSize440x320", t("common.error_title"))',
		0,
		'removing the prefix repairs the same call'
	],
	['windows', 'g := Gui("+Resize", "Unbranded")', 1, 'raw Gui still needs a prefix'],
	[
		'windows',
		'; Gui_Create("", "ErgoptiPlus — comment")\ng := Gui_Create("", "Tools; utilities")',
		0,
		'comments and semicolons inside strings'
	],
	[
		'windows',
		'Title := "ErgoptiPlus — Tools"\ng := Gui_Create("", Title)',
		1,
		'local literal alias'
	],
	['macos', 'view:windowTitle("Unbranded")', 1, 'raw macOS window'],
	['macos', 'ui_builder.window_title("ErgoptiPlus — Tools")', 1, 'macOS composer'],
	['macos', 'ui_builder.set_window_title(view, "ErgoptiPlus — Tools")', 1, 'macOS retitle'],
	[
		'macos',
		'ui_builder.show_webview({ frame = frame(), title = i18n.get("editor.personal_info.window_title"), on_close = function() close() end })',
		1,
		'real translated personal-info window'
	],
	[
		'macos',
		'ui_builder.show_webview({title = i18n.get("common.error_title")})',
		0,
		'brandless translated options'
	],
	['macos', 'ui_builder.window_title(ui_builder.window_title("Tools"))', 1, 'nested composers'],
	['linux', 'manager.set_title(APP_NAME, "ErgoptiPlus — Tools")', 1, 'Linux retitle'],
	[
		'linux',
		'M.window_title(i18n.get("editor.personal_info.window_title"))',
		1,
		'Linux localized composer'
	],
	['linux', 'window:set_title("Ergopti — Tools")', 0, 'native Gtk title already branded'],
	['linux', 'window:set_title("Tools")', 1, 'native Gtk title missing brand'],
	[
		'linux',
		'--[[ manager.set_title(APP, "Ergopti — comment") ]]\nmanager.set_title(APP, i18n.get("common.error_title"))',
		0,
		'Lua long comments'
	],
	[
		'windows',
		'DirSelect("*initial", 3, "Select configuration folder")',
		1,
		'folder native body text cannot establish caption ownership'
	],
	[
		'windows',
		'DirSelect("*initial", 3, "ErgoptiPlus \u2014 Select configuration folder")',
		1,
		'branding the explanatory body cannot establish native chrome'
	],
	[
		'windows',
		'Ui_DirSelect("*initial", 3, "ErgoptiPlus \u2014 explanatory body", "Configuration folder", 0)',
		0,
		'folder body remains independent from the shared native caption'
	],
	[
		'windows',
		'Ui_DirSelect("*initial", 3, "Select folder", "ErgoptiPlus \u2014 Configuration folder", 0)',
		1,
		'folder caption must be brandless before composition'
	],
	[
		'windows',
		'Ui_DirSelect("*initial", 3, "Select folder", t("editor.personal_info.window_title"), 0)',
		1,
		'translated folder captions cannot carry a stale brand'
	],
	[
		'windows',
		'Ui_DirSelect(RootDir, Options, Prompt, Title, OwnerHwnd) {\nreturn _Ui_FolderSelect(RootDir, Options, Prompt, WindowTitle(Title), OwnerHwnd)\n}',
		0,
		'folder wrapper owns exactly the fourth caption argument',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Ui_DirSelect(RootDir, Options, Prompt, Title, OwnerHwnd) {\nreturn _Ui_FolderSelect(RootDir, Options, WindowTitle(Prompt), Title, OwnerHwnd)\n}',
		1,
		'composing the folder body cannot substitute for caption policy',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Ui_DirSelect(RootDir, Options, Prompt, Title, OwnerHwnd) {\nreturn DirSelect(RootDir, Options, WindowTitle(Title))\n}',
		1,
		'the builtin folder dialog does not expose a chrome caption argument',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Other(Title) {\nreturn _Ui_FolderSelect("", 3, "Select folder", WindowTitle(Title), 0)\n}',
		1,
		'a differently owned native folder call cannot bypass the caption wrapper',
		'static/ergopti_plus/windows/infra/native_dialogs.ahk'
	],
	[
		'windows',
		'Ui_DirSelect("*initial", 3, "Select folder", WindowTitle("Configuration folder"), 0)',
		1,
		'folder captions compose only once'
	]
];
try {
	put('tools/lint/audit-gui-titles.cjs', fs.readFileSync(audit));
	for (const platform of ['windows', 'macos', 'linux']) put(sourcePath(platform), '');
	put(
		'static/ergopti_plus/_shared/data/locales/en.json',
		JSON.stringify({
			'common.error_title': 'Error',
			'editor.personal_info.window_title': 'Personal information'
		})
	);
	put(
		'static/ergopti_plus/_shared/data/locales/fr.json',
		JSON.stringify({
			'common.error_title': 'Erreur',
			'editor.personal_info.window_title': 'ErgoptiPlus — Informations personnelles'
		})
	);
	for (const [platform, source, expected, label, override] of cases) {
		for (const relative of ['infra/native_dialogs.ahk', 'infra/bundle.ahk', 'infra/error_net.ahk'])
			fs.rmSync(path.join(root, 'static/ergopti_plus/windows', relative), { force: true });
		for (const other of ['windows', 'macos', 'linux'])
			put(sourcePath(other), other === platform && !override ? source : '');
		if (override) put(override, source);
		const result = spawnSync(
			process.execPath,
			[path.join(root, 'tools/lint/audit-gui-titles.cjs')],
			{ encoding: 'utf8' }
		);
		assert.equal(result.error, undefined, label);
		assert.equal(result.status, expected, `${label}\n${result.stdout}\n${result.stderr}`);
		if (expected)
			assert.match(
				result.stderr,
				new RegExp(
					(override || sourcePath(platform)).replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ':\\d+'
				),
				'failure identifies the actual source site'
			);
	}
	// Generate isolated artifacts from policies that change or remove branding.
	// Never rewrite the committed generated files to test customization.
	for (const policy of [
		{ prefix: 'ErgoptiPlus', separator: ' — ' },
		{ prefix: '', separator: ' — ' },
		{ prefix: 'Other product', separator: ': ' },
		{ prefix: 'Quoted "product" `name`', separator: '' },
		{ prefix: 'Other ; product', separator: ' ; ' },
		{ prefix: 'Émoji 😀', separator: ' / ' },
		{ prefix: 'Literal \\(1 + 1)', separator: ' / ' }
	]) {
		put(titles.SOURCE, JSON.stringify({ window_title: policy, apps: {} }));
		titles.main(root);
		const lua = fs.readFileSync(path.join(root, titles.LUA_OUTPUT), 'utf8');
		const ahk = fs.readFileSync(path.join(root, titles.AHK_OUTPUT), 'utf8');
		const swift = fs.readFileSync(path.join(root, titles.SWIFT_OUTPUT), 'utf8');
		assert.ok(swift.includes('let prefix = ' + JSON.stringify(policy.prefix)));
		assert.ok(swift.includes('let separator = ' + JSON.stringify(policy.separator)));
		assert.match(swift, /guard !prefix.isEmpty else \{ return label \}/);
		assert.ok(lua.includes('local PREFIX = ' + JSON.stringify(policy.prefix)));
		assert.ok(ahk.startsWith('\uFEFF'), 'AHK generated titles retain their UTF-8 BOM');
		assert.equal(/[\r]/.test(lua + ahk + swift), false, 'all generated hosts retain LF');
		assert.match(
			lua,
			/if PREFIX == "" then return label end/,
			'an empty policy prefix leaves the translated label bare'
		);
		assert.match(
			ahk,
			/if Prefix == ""\n\t\treturn Label/,
			'Windows removes its separator when the prefix is empty'
		);
		assert.ok(
			ahk.includes(
				'Prefix := "' +
					policy.prefix.replaceAll('`', '``').replaceAll('"', '`"').replaceAll(';', '`;') +
					'"'
			)
		);
		assert.ok(
			ahk.includes(
				'Separator := "' +
					policy.separator.replaceAll('`', '``').replaceAll('"', '`"').replaceAll(';', '`;') +
					'"'
			)
		);
	}
	for (const policy of [
		undefined,
		{},
		{ prefix: 1, separator: '' },
		{ prefix: '', separator: '\n' },
		{ prefix: '\u0001', separator: '' },
		{ prefix: '', separator: '\t' },
		{ prefix: '\uD800', separator: '' },
		{ prefix: '', separator: '\uDC00' },
		{ prefix: '\u2028', separator: '' },
		{ prefix: '', separator: '\u2029' }
	])
		assert.throws(
			() => titles.render(policy),
			/window_title|one line/,
			'invalid shared policies refuse generation'
		);
	console.log(`GUI title audit mutations: ${cases.length}/${cases.length} passed.`);
} finally {
	fs.rmSync(root, { recursive: true, force: true });
}
