; tests/unit/test_app_picker_generation.ahk

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
			_LMT_Settle, _LMT_Quiesce, _LMT_Collect))
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
			0, _APG_Notify, _LMT_Acquire, _LMT_Settle, _LMT_Quiesce,
			_APG_CollectDisabledApps))
		MutateA := (Candidate) => _LLM_Menu_ApplyAppPickerSelection(
			Candidate, [], ReceiptA)
		AssertFalse(LLM_Menu_CommitMutation(
			"the LLM disabled-applications setting", MutateA, _APG_Apply,
			0, _APG_Notify, _LMT_Acquire, _LMT_Settle, _LMT_Quiesce,
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
