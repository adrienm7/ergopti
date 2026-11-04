; tests/unit/ui/windows/test_app_picker_generation.ahk

; ==============================================================================
; MODULE: App Picker Generation Ownership Tests
; DESCRIPTION:
; Proves that nonmodal app pickers carry one immutable owner receipt from GUI
; admission into the durable candidate transaction. A stale, duplicated, or
; base-mismatched callback must refuse before any writer or live publication.
; ==============================================================================

#Requires AutoHotkey v2.0

global _APG_WriterCalls := 0
global _APG_ApplyCalls := 0
global _APG_ReloadCalls := 0
global _APG_NotifyCalls := 0
global _APG_SupersedingReceipt := 0
global _APG_ReloadResult := 1

_APG_ResetEffects() {
	global _APG_WriterCalls, _APG_ApplyCalls, _APG_ReloadCalls
	global _APG_NotifyCalls, _APG_SupersedingReceipt
	global _APG_ReloadResult
	_APG_WriterCalls := 0
	_APG_ApplyCalls := 0
	_APG_ReloadCalls := 0
	_APG_NotifyCalls := 0
	_APG_SupersedingReceipt := 0
	_APG_ReloadResult := 1
}

_APG_Writer(Path, Updates) {
	global _APG_WriterCalls
	_APG_WriterCalls += 1
	return 1
}

_APG_Apply(Candidate) {
	global _APG_ApplyCalls
	_APG_ApplyCalls += 1
	return 1
}

_APG_Reload() {
	global _APG_ReloadCalls, _APG_ReloadResult
	_APG_ReloadCalls += 1
	return _APG_ReloadResult
}

_APG_Notify(Message, Options) {
	global _APG_NotifyCalls
	_APG_NotifyCalls += 1
	return 1
}

_APG_AcquireSupersedingLlm(Paths) {
	global _APG_SupersedingReceipt, _LLM_Menu
	_APG_SupersedingReceipt := AppPicker_IssueReceipt(
		"llm:disabled_apps", _LLM_Menu["disabled_apps"])
	return _ConfigWriteTerminalTryAcquire(Paths)
}

_APG_CollectDisabledApps(CandidateFeatures, CandidateMenu) {
	return [{ Section: "llm.trigger", Key: "disabled_apps",
		Value: CandidateMenu["disabled_apps"] }]
}

_APG_ResetOwners() {
	global _AppPickerOwnerEpochs, _AppPickerActiveReceipts
	_AppPickerOwnerEpochs := Map()
	_AppPickerActiveReceipts := Map()
}

_APG_SaveOwnerState() {
	global _AppPickerOwnerEpochs, _AppPickerActiveReceipts
	return Map("epochs", _AppPickerOwnerEpochs,
		"receipts", _AppPickerActiveReceipts)
}

_APG_RestoreOwnerState(Saved) {
	global _AppPickerOwnerEpochs, _AppPickerActiveReceipts
	_AppPickerOwnerEpochs := Saved["epochs"]
	_AppPickerActiveReceipts := Saved["receipts"]
}

_APG_GenerationsRejectStaleDuplicateAndAba() {
	Saved := _APG_SaveOwnerState()
	try {
		_APG_ResetOwners()
		A := AppPicker_IssueReceipt("llm:disabled_apps", [])
		B := AppPicker_IssueReceipt("llm:disabled_apps", [])
		AssertFalse(AppPicker_ClaimReceipt(A, []),
			"opening B must retire A before either window can publish")
		AssertTrue(AppPicker_ClaimReceipt(B, []))
		AssertFalse(AppPicker_ClaimReceipt(B, []),
			"one GUI receipt may authorize at most one candidate")

		C := AppPicker_IssueReceipt("llm:disabled_apps", [])
		D := AppPicker_IssueReceipt("llm:disabled_apps", ["x.exe"])
		AssertTrue(AppPicker_ClaimReceipt(D, ["x.exe"]))
		E := AppPicker_IssueReceipt("llm:disabled_apps", [])
		AssertTrue(AppPicker_ClaimReceipt(E, []))
		AssertFalse(AppPicker_ClaimReceipt(C, []),
			"A->B->A data equality must not revive the old A receipt")

		LateA := AppPicker_IssueReceipt("llm:disabled_apps", [])
		LateB := AppPicker_IssueReceipt("llm:disabled_apps", [])
		AssertTrue(AppPicker_RetireReceipt(LateA))
		AssertTrue(AppPicker_ClaimReceipt(LateB, []),
			"closing A after B opens must not retire B's exact receipt")

		External := AppPicker_IssueReceipt("metrics:disabled_apps", [])
		AppPicker_AdvanceOwner("metrics:disabled_apps")
		AppPicker_AdvanceOwner("metrics:disabled_apps")
		AssertFalse(AppPicker_ClaimReceipt(External, []),
			"an external A->B->A publication must retire the old base receipt")
	} finally _APG_RestoreOwnerState(Saved)
}
Test("AHK-020 app picker: generation receipts reject stale, duplicate and ABA callbacks "
	. "(ahk020-owner-generation)",
	_APG_GenerationsRejectStaleDuplicateAndAba)

_APG_BaseMismatchAndLogicalOwnersAreIndependent() {
	Saved := _APG_SaveOwnerState()
	try {
		_APG_ResetOwners()
		Llm := AppPicker_IssueReceipt("llm:disabled_apps", ["old.exe"])
		Metrics := AppPicker_IssueReceipt("metrics:disabled_apps", ["old.exe"])
		AssertFalse(AppPicker_ClaimReceipt(Llm, ["new.exe"]),
			"a live value changed outside the picker must refuse the stale base")
		AssertTrue(AppPicker_ClaimReceipt(Metrics, ["old.exe"]),
			"LLM and Metrics pickers must not invalidate one another")
		Canonical := AppPicker_IssueReceipt("metrics:disabled_apps",
			[" X.EXE ", "x.exe"])
		AssertTrue(AppPicker_ClaimReceipt(Canonical, Map("x.exe", true)),
			"base comparison must use normalized set identity, never row order")
	} finally _APG_RestoreOwnerState(Saved)
}
Test("AHK-020 app picker: exact base is checked per independent logical owner "
	. "(ahk020-base-owner)",
	_APG_BaseMismatchAndLogicalOwnersAreIndependent)

_APG_LlmClaimOccursInsideTerminalAdmission() {
	global _LLM_Menu, _APG_WriterCalls, _APG_ApplyCalls
	SavedOwners := _APG_SaveOwnerState()
	Previous := _LMT_InstallFixture()
	try {
		_APG_ResetOwners()
		_APG_ResetEffects()
		ReceiptA := AppPicker_IssueReceipt(
			"llm:disabled_apps", _LLM_Menu["disabled_apps"])
		Mutate := (Candidate) => _LLM_Menu_ApplyAppPickerSelection(
			Candidate, ["stale.exe"], ReceiptA)
		AssertFalse(LLM_Menu_CommitMutation(
			"the LLM disabled-applications setting", Mutate, _APG_Apply,
			_APG_Writer, _APG_Notify, _APG_AcquireSupersedingLlm,
			_LMT_Settle, _LMT_Collect))
		AssertEqual(0, _APG_WriterCalls,
			"a picker superseded during terminal admission must refuse before I/O")
		AssertEqual(0, _APG_ApplyCalls)
		AssertEqual(0, _LLM_Menu["disabled_apps"].Length)
	} finally {
		_LMT_RestoreFixture(Previous)
		_APG_RestoreOwnerState(SavedOwners)
	}
}
Test("AHK-020 app picker: LLM rechecks its receipt after terminal admission "
	. "(ahk020-llm-admission)",
	_APG_LlmClaimOccursInsideTerminalAdmission)

_APG_LlmNewerCommitWinsInRamAndToml() {
	global _LLM_Menu, _APG_ApplyCalls, _APG_NotifyCalls
	global ConfigurationFile
	SavedOwners := _APG_SaveOwnerState()
	Previous := _LMT_InstallFixture()
	try {
		_APG_ResetOwners()
		_APG_ResetEffects()
		try FileDelete(ConfigurationFile)
		ReceiptA := AppPicker_IssueReceipt(
			"llm:disabled_apps", _LLM_Menu["disabled_apps"])
		ReceiptB := AppPicker_IssueReceipt(
			"llm:disabled_apps", _LLM_Menu["disabled_apps"])
		MutateB := (Candidate) => _LLM_Menu_ApplyAppPickerSelection(
			Candidate, ["x.exe"], ReceiptB)
		AssertTrue(LLM_Menu_CommitMutation(
			"the LLM disabled-applications setting", MutateB, _APG_Apply,
			0, _APG_Notify, _LMT_Acquire, _LMT_Settle,
			_APG_CollectDisabledApps))
		MutateA := (Candidate) => _LLM_Menu_ApplyAppPickerSelection(
			Candidate, [], ReceiptA)
		AssertFalse(LLM_Menu_CommitMutation(
			"the LLM disabled-applications setting", MutateA, _APG_Apply,
			0, _APG_Notify, _LMT_Acquire, _LMT_Settle,
			_APG_CollectDisabledApps))
		AssertEqual(1, _APG_ApplyCalls)
		AssertEqual(1, _APG_NotifyCalls)
		AssertEqual(1, _LLM_Menu["disabled_apps"].Length)
		AssertEqual("x.exe", _LLM_Menu["disabled_apps"][1])
		Parsed := ParseTomlFile(ConfigurationFile)
		Persisted := IniCacheGet(Parsed, "llm.trigger", "disabled_apps")
		AssertEqual(1, Persisted.Length)
		AssertEqual("x.exe", Persisted[1],
			"the stale A callback must not alter the durable B image")
	} finally {
		try FileDelete(ConfigurationFile)
		_LMT_RestoreFixture(Previous)
		_APG_RestoreOwnerState(SavedOwners)
	}
}
Test("AHK-020 app picker: newer LLM commit wins in RAM and real TOML "
	. "(ahk020-llm-toml)", _APG_LlmNewerCommitWinsInRamAndToml)

_APG_MetricsDelayedOwnerCannotOverwriteNewerCommit() {
	global MetricsFilters, _APG_WriterCalls, _APG_ReloadCalls
	global _APG_ReloadResult, _APG_NotifyCalls
	global ConfigurationFile, _SaveFullConfigReady
	SavedOwners := _APG_SaveOwnerState()
	SavedApps := MetricsFilters.disabled_apps
	SavedPath := ConfigurationFile
	HadReady := IsSet(_SaveFullConfigReady)
	SavedReady := HadReady ? _SaveFullConfigReady : false
	try {
		_APG_ResetOwners()
		_APG_ResetEffects()
		ConfigurationFile := A_Temp . "\ergopti_app_picker_generation.toml"
		AssertFalse(FSStrictExists(ConfigurationFile))
		AssertEqual("absent", ConfigMigrateBoot(ConfigurationFile)["status"])
		AssertTrue(ConfigSchemaCanPrepareWrite(ConfigurationFile))
		_SaveFullConfigReady := true
		MetricsFilters.disabled_apps := Map()
		_APG_ReloadResult := 0
		ReceiptA := AppPicker_IssueReceipt("metrics:disabled_apps", [])
		ReceiptB := AppPicker_IssueReceipt("metrics:disabled_apps", [])
		AssertFalse(_MetricsSaveAppPickerAndReload(["x.exe"], _APG_Writer,
			_APG_Notify, _APG_Reload, ReceiptB))
		AssertFalse(_MetricsSaveAppPickerAndReload([], _APG_Writer,
			_APG_Notify, _APG_Reload, ReceiptA))
		AssertEqual(1, _APG_WriterCalls)
		AssertEqual(1, _APG_ReloadCalls)
		AssertEqual(1, _APG_NotifyCalls,
			"the stale callback must surface one persistence refusal")
		AssertEqual(1, MetricsFilters.disabled_apps.Count)
		AssertTrue(MetricsFilters.disabled_apps.Has("x.exe"))
	} finally {
		MetricsFilters.disabled_apps := SavedApps
		ConfigurationFile := SavedPath
		_SaveFullConfigReady := HadReady ? SavedReady : unset
		_APG_RestoreOwnerState(SavedOwners)
	}
}
Test("AHK-020 app picker: stale Metrics callback cannot overwrite newer commit "
	. "(ahk020-metrics-stale)",
	_APG_MetricsDelayedOwnerCannotOverwriteNewerCommit)

_APG_MetricsExternalAbaInvalidatesOpenPicker() {
	global MetricsFilters, ConfigurationFile, _SaveFullConfigReady
	global _APG_WriterCalls
	SavedOwners := _APG_SaveOwnerState()
	SavedApps := MetricsFilters.disabled_apps
	SavedPath := ConfigurationFile
	HadReady := IsSet(_SaveFullConfigReady)
	SavedReady := HadReady ? _SaveFullConfigReady : false
	try {
		_APG_ResetOwners()
		_APG_ResetEffects()
		ConfigurationFile := A_Temp . "\ergopti_app_picker_external_aba.toml"
		AssertFalse(FSStrictExists(ConfigurationFile))
		AssertEqual("absent", ConfigMigrateBoot(ConfigurationFile)["status"])
		AssertTrue(ConfigSchemaCanPrepareWrite(ConfigurationFile))
		_SaveFullConfigReady := true
		MetricsFilters.disabled_apps := Map()
		ReceiptA := AppPicker_IssueReceipt("metrics:disabled_apps", [])
		AssertTrue(MF_ToggleDisabledApp("x.exe", _APG_Writer, _APG_Notify))
		AssertFalse(MF_ToggleDisabledApp("x.exe", _APG_Writer, _APG_Notify),
			"the second successful toggle returns the new disabled state (false)")
		AssertEqual(2, _APG_WriterCalls)
		AssertEqual(0, MetricsFilters.disabled_apps.Count)
		AssertFalse(AppPicker_ClaimReceipt(ReceiptA, []),
			"a non-picker A->B->A producer must advance the same logical owner")
	} finally {
		MetricsFilters.disabled_apps := SavedApps
		ConfigurationFile := SavedPath
		_SaveFullConfigReady := HadReady ? SavedReady : unset
		_APG_RestoreOwnerState(SavedOwners)
	}
}
Test("AHK-020 app picker: external Metrics ABA invalidates an open picker "
	. "(ahk020-metrics-external-aba)",
	_APG_MetricsExternalAbaInvalidatesOpenPicker)

class _APG_CallableSave {
	__New() {
		this.calls := 0
		this.receipt := 0
	}

	Call(Selected, Receipt) {
		this.calls += 1
		this.receipt := Receipt
		return true
	}
}

_APG_CallbackContractAcceptsCallableObjects() {
	Saved := _APG_SaveOwnerState()
	try {
		_APG_ResetOwners()
		Receipt := AppPicker_IssueReceipt("llm:disabled_apps", [])
		Callable := _APG_CallableSave()
		AssertTrue(AppPicker_InvokeSave(Callable, ["x.exe"], Receipt))
		AssertEqual(1, Callable.calls)
		AssertTrue(Callable.receipt == Receipt)
	} finally _APG_RestoreOwnerState(Saved)
}
Test("AHK-020 app picker: callback contract accepts every callable object "
	. "(ahk020-callable)",
	_APG_CallbackContractAcceptsCallableObjects)


_APD_NativeOpen(State, Window, Receipt) {
	State.Hwnd := Window.Hwnd, State.Receipt := Receipt
	return true
}

_APD_NativeNotify(State, Message, Options) {
	State.Notifications += 1
	if State.Mode == "cancel-after-refusal" {
		AssertTrue(DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int"),
			"The genuine refused picker must still exist when its user dismisses the notification")
		AssertTrue(DllCall("User32\PostMessageW", "Ptr", State.Hwnd, "UInt", 0x10,
			"Ptr", 0, "Ptr", 0, "Int"))
		Started := A_TickCount
		while DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int") && TickElapsed(Started) < 3000
			Sleep(5)
		State.CancelObserved := !DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int")
	}
	return true
}

_APD_ApplyRefused(State) {
	State.ApplyCalls += 1
	return false
}

_APD_NativeCommit(State, Selected, Receipt) {
	State.Calls += 1
	Committed := State.Mode == "apply-refused"
		? _MetricsSaveAppPickerAndReload(Selected, 0, _APD_NativeNotify.Bind(State), _APD_ApplyRefused.Bind(State), Receipt)
		: MF_CommitDisabledApps(Selected, 0, _APD_NativeNotify.Bind(State), Receipt)
	State.Results.Push(Committed)
	return Committed
}

_APD_NativeButton(State, *) {
	State.ButtonEntries += 1
	return
}

_APD_NativeRefusedPicker(Mode) {
	global ConfigurationFile, _SaveFullConfigReady, MetricsFilters
	global _ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache
	SavedOwners := _APG_SaveOwnerState()
	Saved := {Path: ConfigurationFile, Apps: MetricsFilters.disabled_apps,
		Critical: A_IsCritical, Suspended: A_IsSuspended}
	HadReady := IsSet(_SaveFullConfigReady), SavedReady := HadReady ? _SaveFullConfigReady : unset
	Fixture := _ScopeOwnerFixture('[metrics]`ndisabled_apps = ["private_keep.exe", "private_remove.exe"]`n')
	State := {Mode: Mode, Hwnd: 0, Receipt: 0, Calls: 0, Results: [], ButtonEntries: 0, Notifications: 0, ApplyCalls: 0, CancelObserved: false}
	Window := 0, Lease := 0, Lock := 0, Primary := 0, CleanupFailure := 0
	try {
		Critical("Off"), Suspend(false)
		_APG_ResetOwners()
		ConfigurationFile := Fixture.path, _SaveFullConfigReady := true
		MetricsFilters.disabled_apps := Map("private_keep.exe", true, "private_remove.exe", true)
		Receipt := AppPicker_Show(Map("owner", "metrics:disabled_apps", "durable", true,
			"title", t("dialog.metrics.exclude_title"), "prompt", t("dialog.metrics.exclude_prompt"),
			"ok_label", t("dialog.metrics.exclude_ok"), "initial", MF_DisabledList(),
			"on_open", _APD_NativeOpen.Bind(State), "on_save", _APD_NativeCommit.Bind(State)))
		AssertTrue(Receipt is Map && Receipt == State.Receipt && Receipt["state"] == "open")
		Window := GuiFromHwnd(State.Hwnd)
		AssertTrue(Window is Gui && DllCall("User32\IsWindowVisible", "Ptr", State.Hwnd, "Int"))
		List := 0, Button := 0
		for Control in Window {
			if Control.Type == "ListView"
				List := Control
			if Control.Type == "Button" && Control.Text == t("dialog.metrics.exclude_ok")
				Button := Control
		}
		AssertTrue(IsObject(List) && IsObject(Button))
		RemovedRow := 0
		loop List.GetCount()
			if List.GetText(A_Index, 2) == "private_remove.exe"
				RemovedRow := A_Index
		AssertTrue(RemovedRow > 0)
		; Arrange an ordinary checkbox selection on the real production list.
		; Only the original native OK producer and its durable writer are SUTs.
		List.Modify(RemovedRow, "-Check")
		Selected := Map(), Row := 0
		loop {
			Row := List.GetNext(Row, "Checked")
			if !Row
				break
			Selected[List.GetText(Row, 2)] := true
		}
		AssertEqual(1, Selected.Count)
		AssertTrue(Selected.Has("private_keep.exe"))
		ButtonHwnd := Button.Hwnd
		Button.OnEvent("Click", _APD_NativeButton.Bind(State), -1)
		if Mode == "lease" {
			Lease := _ConfigWriteLeaseTryAcquire(ConfigurationFile, "app-picker-refusal-fixture")
			AssertTrue(Lease is Object, "The independent genuine configuration owner must hold this exact path")
		} else if Mode == "sharing" || Mode == "cancel-after-refusal" {
			; Reads remain allowed; writes and atomic replacement are genuinely
			; denied. This refusal occurs after the candidate claimed its receipt.
			Lock := FileOpen(ConfigurationFile, "r-wd", "UTF-8")
			AssertTrue(IsObject(Lock))
		}
		AssertTrue(FSUtf8ExactMatches(ConfigurationFile, Fixture.source))
		DllCall("User32\SendMessageW", "Ptr", ButtonHwnd, "UInt", 0xF5,
			"Ptr", 0, "Ptr", 0, "Ptr")
		Started := A_TickCount
		while State.Results.Length == 0 && TickElapsed(Started) < 3000
			Sleep(5)
		AssertEqual(1, State.ButtonEntries)
		AssertEqual(1, State.Calls, "The actual callback must reach the genuine durable metrics producer")
		AssertEqual(1, State.Results.Length)
		if Mode == "apply-refused" {
			AssertFalse(State.Results[1], "The historical combined callback still reports refused apply")
			AssertEqual(1, State.ApplyCalls, "The actual callback must reach its isolated postcommit apply port once")
			AssertFalse(FSUtf8ExactMatches(ConfigurationFile, Fixture.source), "This control must really acknowledge changed durable bytes")
			Fresh := ParseTomlFile(ConfigurationFile), Apps := IniCacheGet(Fresh, "metrics", "disabled_apps")
			AssertTrue(Apps is Array && Apps.Length == 1 && Apps[1] == "private_keep.exe")
			AssertEqual(1, MetricsFilters.disabled_apps.Count)
			AssertTrue(MetricsFilters.disabled_apps.Has("private_keep.exe"))
			_TestPrint("# app-picker-native-refusal mode=apply-refused callback_result=" . State.Results[1]
				. " apply_calls=" . State.ApplyCalls . " durable_changed=1 window_closed="
				. !DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int"))
			AssertFalse(DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int"),
				"A confirmed durable commit must close the picker even when apply returns false")
			return
		}
		if Mode == "cancel-after-refusal" {
			AssertFalse(State.Results[1])
			AssertTrue(State.CancelObserved, "A genuine native Close must complete inside the real failure presentation")
			AssertTrue(FSUtf8ExactMatches(ConfigurationFile, Fixture.source))
			AssertTrue(MetricsFilters.disabled_apps.Has("private_remove.exe"))
			AssertFalse(DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int"))
			global _AppPickerActiveReceipts
			AssertTrue(_AppPickerActiveReceipts.Get("metrics:disabled_apps", 0) != Receipt,
				"The old refusal cannot reinsert an active receipt for the native window the user already retired")
			return
		}
		AssertFalse(State.Results[1], "The real lease/sharing actor must refuse the write")
		AssertTrue(State.Notifications >= 1, "The genuine persistence refusal must be explained through its presentation port")
		AssertTrue(FSUtf8ExactMatches(ConfigurationFile, Fixture.source))
		AssertTrue(MetricsFilters.disabled_apps.Has("private_remove.exe"))
		_TestPrint("# app-picker-native-refusal mode=" . Mode . " callbacks=" . State.Calls
			. " committed=" . State.Results[1] . " source_unchanged=" . FSUtf8ExactMatches(ConfigurationFile, Fixture.source)
			. " window_retained=" . DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int") . " receipt=" . Receipt["state"])
		AssertTrue(DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int"),
			"A real refused write must preserve the native checkbox selection for retry")
		RetainedCount := 0, Row := 0
		loop {
			Row := List.GetNext(Row, "Checked")
			if !Row
				break
			RetainedCount += 1
			AssertEqual("private_keep.exe", List.GetText(Row, 2), "The retained check must still name the user's original choice")
		}
		AssertEqual(1, RetainedCount, "The complete visible checked set must survive the refusal")
		if Lease is Object
			_ConfigWriteLeaseRelease(Lease), Lease := 0
		if IsObject(Lock)
			Lock.Close(), Lock := 0
		Sleep(30)
		AssertEqual(1, State.Calls, "Release cannot replay a refused picker command")
		DllCall("User32\SendMessageW", "Ptr", ButtonHwnd, "UInt", 0xF5,
			"Ptr", 0, "Ptr", 0, "Ptr")
		Started := A_TickCount
		while State.Results.Length < 2 && TickElapsed(Started) < 3000
			Sleep(5)
		AssertEqual(2, State.ButtonEntries)
		AssertEqual(2, State.Calls)
		AssertEqual(2, State.Results.Length)
		AssertTrue(State.Results[2], "A fresh click of the same retained picker must really commit after release")
		AssertFalse(DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int"))
		Fresh := ParseTomlFile(ConfigurationFile), Apps := IniCacheGet(Fresh, "metrics", "disabled_apps")
		AssertTrue(Apps is Array && Apps.Length == 1 && Apps[1] == "private_keep.exe")
		AssertEqual(1, MetricsFilters.disabled_apps.Count)
		AssertTrue(MetricsFilters.disabled_apps.Has("private_keep.exe"))
	} catch as Failure {
		Primary := Failure
	} finally {
		Suspend(false)
		if Lease is Object
			_ConfigWriteLeaseRelease(Lease)
		if IsObject(Lock)
			Lock.Close()
		try {
			if IsObject(Window) && DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int") {
				AssertTrue(DllCall("User32\PostMessageW", "Ptr", State.Hwnd, "UInt", 0x10,
					"Ptr", 0, "Ptr", 0, "Int"))
				Started := A_TickCount
				while DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int") && TickElapsed(Started) < 3000
					Sleep(5)
				if DllCall("User32\IsWindow", "Ptr", State.Hwnd, "Int")
					throw Error("The actual private picker must retire through its own native Close")
			}
		} catch as Failure {
			CleanupFailure := Failure
			if IsObject(Window)
				Window.Destroy()
		}
		if State.Receipt is Map
			AppPicker_RetireReceipt(State.Receipt)
		MetricsFilters.disabled_apps := Saved.Apps, ConfigurationFile := Saved.Path
		_SaveFullConfigReady := HadReady ? SavedReady : unset
		_APG_RestoreOwnerState(SavedOwners)
		for Store in [_ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache]
			if Store.Has(Fixture.path)
				Store.Delete(Fixture.path)
		_ScopeOwnerCleanup(Fixture)
		Suspend(Saved.Suspended), Critical(Saved.Critical)
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}
for _APD_Mode in ["lease", "sharing", "apply-refused", "cancel-after-refusal"]
	Test("App picker native refusal: " . _APD_Mode . " preserves checkbox state and a fresh durable retry (app-picker-native-refusal-owner)",
		_APD_NativeRefusedPicker.Bind(_APD_Mode))
