; tests/unit/test_llm_hotkey_cross_owner_collision.ahk

; ==============================================================================
; MODULE: LLM Cross-Owner Hotkey Collision Tests
; DESCRIPTION:
; Behavioural regression coverage for AHK-027. The global prediction trigger
; must reserve every latent contextual LLM chord before native registration,
; while navigation edits must preserve the already-active trigger owner.
; ==============================================================================

#Requires AutoHotkey v2.0

global _LHCC_NavAcquireCalls := 0
global _LHCC_NavSettleCalls := 0
global _LHCC_NavQuiesceCalls := 0
global _LHCC_NavCollectCalls := 0
global _LHCC_NavHotkeyCalls := 0
global _LHCC_NavHotIfCalls := 0
global _LHCC_NavResetCalls := 0
global _LHCC_RefuseCtrl5Off := false
global _LHCC_ProfileReadyCalls := 0
global _LHCC_NavReadyCalls := 0
global _LHCC_NavCommitCompleted := false
global _LHCC_ContextualRoutingCompleted := false
global _LHCC_PriorWalCompleted := false
global _LHCC_CrossLayoutPriorityCompleted := false
global _LHCC_ResolverLayout := 0x040C
global _LHCC_ResolverLayoutCalls := 0
global _LHCC_ResolverVkScanCalls := 0
global _LHCC_ResolverGetVkCalls := 0
global _LHCC_ResolverGetScCalls := 0
global _LHCC_ResolverPacked := Map()
global _LHCC_ResolverVkCodes := Map()
global _LHCC_ResolverScCodes := Map()
global _LHCC_ResolverSeenKeys := Map()
global _LHCC_FrozenReserveFailure := false

_LHCC_ResetNavBoundaryCounters() {
	global _LHCC_NavAcquireCalls, _LHCC_NavSettleCalls
	global _LHCC_NavQuiesceCalls, _LHCC_NavCollectCalls
	global _LHCC_NavHotkeyCalls, _LHCC_NavHotIfCalls, _LHCC_NavResetCalls
	_LHCC_NavAcquireCalls := 0
	_LHCC_NavSettleCalls := 0
	_LHCC_NavQuiesceCalls := 0
	_LHCC_NavCollectCalls := 0
	_LHCC_NavHotkeyCalls := 0
	_LHCC_NavHotIfCalls := 0
	_LHCC_NavResetCalls := 0
}

_LHCC_PhaseCount(Phase) {
	global _LTST_CriticalStates
	Count := 0
	for Sample in _LTST_CriticalStates {
		if Sample["phase"] == Phase
			Count += 1
	}
	return Count
}

_LHCC_EventCount(Events, Expected) {
	Count := 0
	for Event in Events {
		if Event == Expected
			Count += 1
	}
	return Count
}

_LHCC_NavAcquire(Paths) {
	global _LHCC_NavAcquireCalls
	_LHCC_NavAcquireCalls += 1
	return _LMT_Acquire(Paths)
}

_LHCC_NavSettle(Bundle) {
	global _LHCC_NavSettleCalls
	_LHCC_NavSettleCalls += 1
	return _LMT_Settle(Bundle)
}

_LHCC_NavQuiesce(Bundle) {
	global _LHCC_NavQuiesceCalls
	_LHCC_NavQuiesceCalls += 1
	return _LMT_Quiesce(Bundle)
}

_LHCC_NavCollect(CandidateFeatures, CandidateMenu) {
	global _LHCC_NavCollectCalls
	_LHCC_NavCollectCalls += 1
	return _LMT_Collect(CandidateFeatures, CandidateMenu)
}

_LHCC_NavHotkey(Args*) {
	global _LHCC_NavHotkeyCalls
	_LHCC_NavHotkeyCalls += 1
	return _LNHT_Hotkey(Args*)
}

_LHCC_NavHotIf(Args*) {
	global _LHCC_NavHotIfCalls
	_LHCC_NavHotIfCalls += 1
	return _LNHT_HotIf(Args*)
}

_LHCC_NavReset(Args*) {
	global _LHCC_NavResetCalls
	_LHCC_NavResetCalls += 1
	return _LNHT_ForceHotIfReset(Args*)
}

_LHCC_NavTransactionPort(KeyResolverFn := 0) {
	Port := _LNHT_TransactionPort()
	Port["acquire"] := _LHCC_NavAcquire
	Port["settle"] := _LHCC_NavSettle
	Port["quiesce"] := _LHCC_NavQuiesce
	Port["collect"] := _LHCC_NavCollect
	Port["hotkey"] := _LHCC_NavHotkey
	Port["hotif"] := _LHCC_NavHotIf
	Port["reset"] := _LHCC_NavReset
	if HasMethod(KeyResolverFn, "Call")
		Port["key_resolver"] := KeyResolverFn
	return Port
}

_LHCC_ResolverGetLayout() {
	global _LHCC_ResolverLayout, _LHCC_ResolverLayoutCalls
	_LHCC_ResolverLayoutCalls += 1
	return _LHCC_ResolverLayout
}

_LHCC_RecordResolverKey(Key) {
	global _LHCC_ResolverSeenKeys
	Canonical := StrLower(String(Key))
	_LHCC_ResolverSeenKeys[Canonical] :=
		_LHCC_ResolverSeenKeys.Get(Canonical, 0) + 1
}

_LHCC_ResolverVkScan(Key, Layout) {
	global _LHCC_ResolverLayout, _LHCC_ResolverVkScanCalls
	global _LHCC_ResolverPacked
	_LHCC_ResolverVkScanCalls += 1
	_LHCC_RecordResolverKey(Key)
	AssertEqual(_LHCC_ResolverLayout, Layout,
		"every key in one ownership decision must use the captured HKL")
	return _LHCC_ResolverPacked.Get(Key, -1)
}

_LHCC_ResolverGetVk(Key) {
	global _LHCC_ResolverGetVkCalls, _LHCC_ResolverVkCodes
	_LHCC_ResolverGetVkCalls += 1
	_LHCC_RecordResolverKey(Key)
	return _LHCC_ResolverVkCodes.Get(StrLower(Key), 0)
}

_LHCC_ResolverGetSc(Key) {
	global _LHCC_ResolverGetScCalls, _LHCC_ResolverScCodes
	_LHCC_ResolverGetScCalls += 1
	_LHCC_RecordResolverKey(Key)
	return _LHCC_ResolverScCodes.Get(StrLower(Key), 0)
}

_LHCC_ResolverPort() {
	return Map("get_layout", _LHCC_ResolverGetLayout,
		"vk_scan", _LHCC_ResolverVkScan,
		"get_vk", _LHCC_ResolverGetVk,
		"get_sc", _LHCC_ResolverGetSc)
}

_LHCC_Ctrl5Hotkey(Name, Action := unset, Options := unset) {
	global _LHCC_RefuseCtrl5Off
	if IsSet(Action) && !IsSet(Options) && Action == "Off"
			&& _LTST_NameMatches(Name, "^5") && _LHCC_RefuseCtrl5Off
		throw Error("injected Ctrl+5 cleanup refusal before native mutation")
	if !IsSet(Action)
		return _LTST_Hotkey(Name)
	if !IsSet(Options)
		return _LTST_Hotkey(Name, Action)
	return _LTST_Hotkey(Name, Action, Options)
}

_LHCC_ProfileReady() {
	global _LHCC_ProfileReadyCalls, _LLM_PROFILE_HOTKEY_STATUS_READY
	_LHCC_ProfileReadyCalls += 1
	return _LLM_PROFILE_HOTKEY_STATUS_READY
}

_LHCC_NavReady() {
	global _LHCC_NavReadyCalls
	_LHCC_NavReadyCalls += 1
	return 1
}





; ======================================
; ======================================
; ======= 1/ Deterministic State =======
; ======================================
; ======================================

_LHCC_InstallReservedMenuState() {
	global _LLM_Menu, _LLM_Menu_ProfileHotkeyOwner
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavSlotPlans
	global _LLM_Menu_NavActiveSlot
	_LLM_Menu["nav_modifiers"] := "alt"
	_LLM_Menu["val_modifiers"] := "ctrl+alt"
	; Replay runs before the two dynamic binders, so the policy must derive the
	; latent surface from restored state instead of consulting published owners
	_LLM_Menu_ProfileHotkeyOwner := 0
	_LLM_Menu_NavHotkeysBound := []
	_LLM_Menu_NavSlotPlans := Map(1, [], 2, [])
	_LLM_Menu_NavActiveSlot := 0
}

_LHCC_WithTriggerState(TestFn) {
	global _LLM_Menu, _LLM_Menu_ProfileHotkeyOwner
	global _LLM_Menu_ProfileHotkeyFailureCount
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavSlotPlans
	global _LLM_Menu_NavActiveSlot, LLM_PROFILE_HOTKEY_LIMIT
	global _LHCC_RefuseCtrl5Off, _LHCC_ProfileReadyCalls
	global _LHCC_NavReadyCalls
	global _LHCC_FrozenReserveFailure
	SavedNavModifiers := _LLM_Menu["nav_modifiers"]
	SavedValModifiers := _LLM_Menu["val_modifiers"]
	SavedProfileOwner := _LLM_Menu_ProfileHotkeyOwner
	SavedProfileFailureCount := _LLM_Menu_ProfileHotkeyFailureCount
	SavedNavBound := _LLM_Menu_NavHotkeysBound
	SavedNavPlans := _LLM_Menu_NavSlotPlans
	SavedNavSlot := _LLM_Menu_NavActiveSlot
	HadProfileLimit := IsSet(LLM_PROFILE_HOTKEY_LIMIT)
	if HadProfileLimit
		SavedProfileLimit := LLM_PROFILE_HOTKEY_LIMIT
	try {
		LLM_PROFILE_HOTKEY_LIMIT := 9
		_LLM_Menu_ProfileHotkeyOwner := 0
		_LLM_Menu_ProfileHotkeyFailureCount := 0
		_LHCC_FrozenReserveFailure := false
		return _LTST_WithFixture(TestFn)
	} finally {
		_LLM_Menu["nav_modifiers"] := SavedNavModifiers
		_LLM_Menu["val_modifiers"] := SavedValModifiers
		_LLM_Menu_ProfileHotkeyOwner := SavedProfileOwner
		_LLM_Menu_ProfileHotkeyFailureCount := SavedProfileFailureCount
		_LLM_Menu_NavHotkeysBound := SavedNavBound
		_LLM_Menu_NavSlotPlans := SavedNavPlans
		_LLM_Menu_NavActiveSlot := SavedNavSlot
		LLM_PROFILE_HOTKEY_LIMIT := HadProfileLimit ? SavedProfileLimit : unset
		_LPHT_ResetPorts()
		_LNHT_Reset()
		_LHCC_ResetNavBoundaryCounters()
		_LHCC_RefuseCtrl5Off := false
		_LHCC_ProfileReadyCalls := 0
		_LHCC_NavReadyCalls := 0
		_LHCC_FrozenReserveFailure := false
	}
}

_LHCC_ContextualCollisionCases() {
	Cases := [
		"TAB", "VK09", "SC00F", "VK09SC00F", "*Tab",
		"Ctrl+VK35", "Ctrl+SC006", "Ctrl+VK35SC006", "Ctrl+*5",
		"Ctrl+5 Up",
		"Alt+VK26", "Alt+SC148", "Alt+VK26SC148", "Alt+*Up",
		"Alt+VK28", "Alt+SC150", "Alt+VK28SC150",
		"Alt+VK37", "Alt+SC008", "Alt+VK37SC008", "Alt+*7",
		"LButton", "Ctrl+WheelUp",
		"XButton1", "XButton2", "Ctrl+XButton1", "Alt+XButton2",
		"LCtrl", "LControl", "RCtrl", "RControl", "LAlt", "RAlt",
		"LShift", "RShift", "LWin", "RWin"
	]
	Loop 9
		Cases.Push("Ctrl+" . A_Index)
	Cases.Push("Alt+Up")
	Cases.Push("Alt+Down")
	Loop 10 {
		Digit := A_Index == 10 ? "0" : String(A_Index)
		Cases.Push("Alt+Control+" . Digit)
	}
	return Cases
}





; =================================
; =================================
; ======= 2/ Trigger Policy =======
; =================================
; =================================

_LHCC_BootReplayRejectsLatentOwnersCore() {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global _LLM_Menu_TriggerHandle, _LLM_Menu_TriggerAhk
	global _LLM_Menu_TriggerStatus, LLM_TRIGGER_STATUS_ERROR
	global _LTST_Native, _LTST_NotifyCalls
	for RawText in _LHCC_ContextualCollisionCases() {
		_LTST_Reset()
		_LHCC_InstallReservedMenuState()
		AssertFalse(LLM_Menu_ApplyTriggerShortcut(RawText, _LTST_Hotkey,
			_LTST_Probe, _LTST_LlmCallback, 0, 0, _LTST_Notify),
			"boot replay must reject contextual collision " . RawText)
		AssertEqual(0, _LTST_Native.Count,
			"collision rejection must precede native trigger reservation")
		AssertEqual(0, HOTKEY_REGISTRAR_BINDINGS.Count)
		AssertEqual(0, HOTKEY_REGISTRAR_SPECS.Count)
		AssertEqual("", _LLM_Menu_TriggerHandle)
		AssertEqual("", _LLM_Menu_TriggerAhk)
		AssertEqual(LLM_TRIGGER_STATUS_ERROR, _LLM_Menu_TriggerStatus)
		AssertEqual(1, _LTST_NotifyCalls)
		_LTST_AssertEvents(["notify"],
			"boot collision must surface one terminal refusal")
	}

	_LTST_Reset()
	_LHCC_InstallReservedMenuState()
	AssertTrue(LLM_Menu_ApplyTriggerShortcut("Ctrl+Tab", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, 0, 0, _LTST_Notify),
		"a neighboring non-conflicting trigger must remain configurable")
	AssertTrue(_LTST_Native.Has("^tab"))
	AssertTrue(_LTST_Native["^tab"].enabled)
}

_LHCC_BootReplayRejectsLatentOwners() {
	return _LHCC_WithTriggerState(_LHCC_BootReplayRejectsLatentOwnersCore)
}
Test("[llm-hotkey-collision] boot replay reserves every contextual LLM chord",
	_LHCC_BootReplayRejectsLatentOwners)

_LHCC_RejectedBootStillArmsContextualOwnersCore() {
	global _LLM_Menu_ProfileHotkeyOwner, _LLM_Menu_NavHotkeysBound
	_LTST_Reset()
	_LHCC_InstallReservedMenuState()
	AssertFalse(LLM_Menu_ApplyTriggerShortcut("Control+Alt+7", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, 0, 0, _LTST_Notify))
	_LPHT_ResetPorts()
	ProfileStatus := _LPHT_ProfileBindPort()
	AssertTrue((ProfileStatus is Integer) && ProfileStatus == 1,
		"trigger refusal must not block the later profile binder")
	AssertTrue(_LLM_Menu_ProfileHotkeyOwnerReady())
	_LNHT_Reset()
	NavStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset)
	AssertTrue((NavStatus is Integer) && NavStatus == 1,
		"trigger refusal must not block the later navigation binder")
	AssertEqual(12, _LLM_Menu_NavHotkeysBound.Length)
}

_LHCC_RejectedBootStillArmsContextualOwners() {
	return _LHCC_WithTriggerState(
		_LHCC_RejectedBootStillArmsContextualOwnersCore)
}
Test("[llm-hotkey-collision] rejected boot trigger leaves contextual binders usable",
	_LHCC_RejectedBootStillArmsContextualOwners)

_LHCC_LiveTriggerEditRejectsBeforeCandidateMutationCore() {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global HOTKEY_REGISTRAR_NEXT_TOKEN
	global _LLM_Menu, _LLM_Menu_TriggerHandle, _LLM_Menu_TriggerAhk
	global _LLM_Menu_TriggerStatus, _LLM_Menu_TriggerRecovery
	global _LLM_Menu_TriggerRecoveryHandles
	global _LTST_WriteCalls, _LTST_NotifyCalls, _LTST_NotifyLeaseReacquired
	global _LTST_DurableValue, _LTST_JournalFiles, _LTST_CriticalStates
	global _LTST_Native, _LTST_LlmCalls, _LTST_AppDeliveries
	for Vector in [
		Map("raw", "Tab", "spec", "tab"),
		Map("raw", "VK09", "spec", "vk09"),
		Map("raw", "SC00F", "spec", "SC00F"),
		Map("raw", "*Tab", "spec", "*tab"),
		Map("raw", "Ctrl+5", "spec", "^5"),
		Map("raw", "Ctrl+VK35", "spec", "^vk35"),
		Map("raw", "Ctrl+SC006", "spec", "^SC006"),
		Map("raw", "Ctrl+*5", "spec", "^*5"),
		Map("raw", "Ctrl+5 Up", "spec", "^5 up"),
		Map("raw", "Alt+Up", "spec", "!up"),
		Map("raw", "Alt+VK26", "spec", "!vk26"),
		Map("raw", "Alt+SC148", "spec", "!SC148"),
		Map("raw", "Alt+*Up", "spec", "!*up"),
		Map("raw", "XButton1", "spec", "xbutton1"),
		Map("raw", "XButton2", "spec", "xbutton2"),
		Map("raw", "LButton", "spec", "lbutton"),
		Map("raw", "Ctrl+WheelUp", "spec", "^wheelup"),
		Map("raw", "Ctrl+XButton1", "spec", "^xbutton1"),
		Map("raw", "Alt+XButton2", "spec", "!xbutton2"),
		Map("raw", "LCtrl", "spec", "lctrl"),
		Map("raw", "RAlt", "spec", "ralt"),
		Map("raw", "Control+Alt+7", "spec", "^!7")
	] {
		_LTST_Reset()
		_LHCC_InstallReservedMenuState()
		_LTST_SeedOld()
		OldHandle := _LLM_Menu_TriggerHandle
		OldEntry := HOTKEY_REGISTRAR_BINDINGS[OldHandle]
		OldNativeSpec := OldEntry["spec"]
		OldSpecEntry := HOTKEY_REGISTRAR_SPECS[OldNativeSpec]
		OldStatus := _LLM_Menu_TriggerStatus
		OldToken := HOTKEY_REGISTRAR_NEXT_TOKEN
		_LTST_CriticalStates := []
		AssertFalse(_LTST_Commit(Vector["raw"], _LTST_Writer,
			_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback),
			"live edit must reject contextual collision " . Vector["raw"])
		AssertEqual(0, _LTST_WriteCalls,
			"collision rejection must precede the config writer")
		AssertEqual(1, _LTST_NotifyCalls)
		AssertEqual(1, _LTST_NotifyLeaseReacquired,
			"the refusal notice must run after config ownership is released")
		AssertEqual(0, _LTST_JournalFiles.Count,
			"a rejected candidate must not create a trigger WAL")
		for Sample in _LTST_CriticalStates {
			AssertFalse(Sample["phase"] == "config_read"
				|| Sample["phase"] == "config_write"
				|| Sample["phase"] == "journal_write"
				|| Sample["phase"] == "journal_move",
				"collision rejection must not create new durable authority")
		}
		AssertEqual("Ctrl+L", _LLM_Menu["trigger_shortcut"])
		AssertEqual("Ctrl+L", _LTST_DurableValue)
		AssertEqual("^l", _LLM_Menu_TriggerAhk)
		AssertEqual(OldHandle, _LLM_Menu_TriggerHandle)
		AssertEqual(OldStatus, _LLM_Menu_TriggerStatus)
		AssertTrue(HOTKEY_REGISTRAR_BINDINGS[OldHandle] == OldEntry)
		AssertTrue(HOTKEY_REGISTRAR_SPECS[OldNativeSpec] == OldSpecEntry)
		AssertEqual(OldToken, HOTKEY_REGISTRAR_NEXT_TOKEN)
		AssertFalse(_LLM_Menu_TriggerRecovery is Map)
		AssertEqual(0, _LLM_Menu_TriggerRecoveryHandles.Length)
		AssertFalse(_LTST_NativeHas(Vector["spec"]),
			"the conflict must never reach native reserve-Off")
		_LTST_AssertEvents(["notify"],
			"live collision must preserve the old owner and report once")
		AssertTrue(_LTST_Fire("^l"))
		AssertFalse(_LTST_Fire(Vector["spec"]))
		AssertEqual(1, _LTST_LlmCalls)
		AssertEqual(1, _LTST_AppDeliveries)
	}
}

_LHCC_LiveTriggerEditRejectsBeforeCandidateMutation() {
	return _LHCC_WithTriggerState(
		_LHCC_LiveTriggerEditRejectsBeforeCandidateMutationCore)
}
Test("[llm-hotkey-collision] live trigger edits preserve old WAL and native owner",
	_LHCC_LiveTriggerEditRejectsBeforeCandidateMutation)

_LHCC_UnchangedLegacyCollisionIsRetiredCore() {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_NEXT_TOKEN
	global _LLM_Menu_TriggerHandle, _LLM_Menu_TriggerAhk
	global _LLM_Menu_TriggerStatus, LLM_TRIGGER_STATUS_ACTIVE
	global LLM_TRIGGER_STATUS_ERROR, _LTST_Events, _LTST_Native
	global _LTST_LlmCalls, _LTST_AppDeliveries
	_LHCC_InstallReservedMenuState()
	OldHandle := _HotkeyRegistrarBindOwned("Ctrl+5", _LTST_LlmCallback,
		"llm:trigger", _LTST_Hotkey, _LTST_Probe)
	AssertTrue(OldHandle != "")
	OldNativeSpec := HOTKEY_REGISTRAR_BINDINGS[OldHandle]["spec"]
	_LLM_Menu_PublishTriggerRuntime("Ctrl+5", "^5", OldHandle,
		LLM_TRIGGER_STATUS_ACTIVE, [])
	OldToken := HOTKEY_REGISTRAR_NEXT_TOKEN
	_LTST_Events := []
	AssertFalse(LLM_Menu_ApplyTriggerShortcut("Ctrl+5", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, 0, 0, _LTST_Notify),
		"collision validation must precede unchanged-owner replay")
	AssertFalse(HOTKEY_REGISTRAR_BINDINGS.Has(OldHandle))
	AssertEqual(OldToken, HOTKEY_REGISTRAR_NEXT_TOKEN,
		"replay rejection must not reserve a replacement candidate")
	AssertEqual("", _LLM_Menu_TriggerHandle)
	AssertEqual("", _LLM_Menu_TriggerAhk)
	AssertEqual(LLM_TRIGGER_STATUS_ERROR, _LLM_Menu_TriggerStatus)
	AssertTrue(_LTST_Native.Has(OldNativeSpec))
	AssertFalse(_LTST_Native[OldNativeSpec].enabled)
	_LTST_AssertEvents([_LTST_RecordedNativeName(OldNativeSpec) . " Off",
		"notify"],
		"legacy collision must retire the obsolete global owner before reporting")
	AssertFalse(_LTST_Fire("^5"))
	AssertEqual(0, _LTST_LlmCalls)
	AssertEqual(1, _LTST_AppDeliveries)
}

_LHCC_UnchangedLegacyCollisionIsRetired() {
	return _LHCC_WithTriggerState(_LHCC_UnchangedLegacyCollisionIsRetiredCore)
}
Test("[llm-hotkey-collision] unchanged legacy collision cannot survive replay",
	_LHCC_UnchangedLegacyCollisionIsRetired)

; Seeds the exact runtime shape produced by an older release. The current
; registrar intentionally refuses these native spellings, so routing this
; upgrade fixture through today's reserve API would test the refusal twice and
; never exercise retirement of the already-live historical owner.
_LHCC_SeedHistoricalTriggerOwner(Raw, Spec) {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global HOTKEY_REGISTRAR_NEXT_TOKEN, _LTST_Native
	HOTKEY_REGISTRAR_NEXT_TOKEN += 1
	Handle := "legacy-hotkey#" . HOTKEY_REGISTRAR_NEXT_TOKEN
	Entry := Map(
		"handle", Handle,
		"spec", Spec,
		"display_spec", Spec,
		"chord", Raw,
		"owner", "llm:trigger",
		"physical_identity", "",
		"callback", _LTST_LlmCallback,
		"state", _HotkeyRegistrarState("active", _LTST_LlmCallback, "on"))
	HOTKEY_REGISTRAR_SPECS[Spec] := Entry
	HOTKEY_REGISTRAR_BINDINGS[Handle] := Entry
	_LTST_Native[Spec] := { callback: _LTST_LlmCallback, enabled: true }
	return Handle
}

_LHCC_ForbiddenLegacySyntaxIsRetiredCore() {
	global HOTKEY_REGISTRAR_BINDINGS
	global _LLM_Menu_TriggerHandle, _LLM_Menu_TriggerAhk
	global _LLM_Menu_TriggerStatus, LLM_TRIGGER_STATUS_ACTIVE
	global LLM_TRIGGER_STATUS_ERROR, _LTST_Events, _LTST_Native
	for Vector in [
		Map("raw", "VK09", "spec", "vk09"),
		Map("raw", "SC00F", "spec", "SC00F"),
		Map("raw", "*7", "spec", "*7"),
		Map("raw", "Ctrl+5 Up", "spec", "^5 up"),
		Map("raw", "XButton1", "spec", "xbutton1"),
		Map("raw", "XButton2", "spec", "xbutton2"),
		Map("raw", "LButton", "spec", "lbutton"),
		Map("raw", "Ctrl+XButton1", "spec", "^xbutton1"),
		Map("raw", "LCtrl", "spec", "lctrl")
	] {
		_LTST_Reset()
		_LHCC_InstallReservedMenuState()
		OldHandle := _LHCC_SeedHistoricalTriggerOwner(Vector["raw"],
			Vector["spec"])
		OldNativeSpec := Vector["spec"]
		_LLM_Menu_PublishTriggerRuntime(Vector["raw"], Vector["spec"],
			OldHandle, LLM_TRIGGER_STATUS_ACTIVE, [])
		_LTST_Events := []
		AssertFalse(LLM_Menu_ApplyTriggerShortcut(Vector["raw"], _LTST_Hotkey,
			_LTST_Probe, _LTST_LlmCallback, 0, 0, _LTST_Notify),
			"upgrade replay must retire forbidden syntax " . Vector["raw"])
		AssertFalse(HOTKEY_REGISTRAR_BINDINGS.Has(OldHandle))
		AssertEqual("", _LLM_Menu_TriggerHandle)
		AssertEqual("", _LLM_Menu_TriggerAhk)
		AssertEqual(LLM_TRIGGER_STATUS_ERROR, _LLM_Menu_TriggerStatus)
		AssertTrue(_LTST_Native.Has(OldNativeSpec))
		AssertFalse(_LTST_Native[OldNativeSpec].enabled)
		_LTST_AssertEvents([_LTST_RecordedNativeName(OldNativeSpec) . " Off",
			"notify"],
			"forbidden legacy syntax must lose native ownership before reporting")
	}
}

_LHCC_ForbiddenLegacySyntaxIsRetired() {
	return _LHCC_WithTriggerState(_LHCC_ForbiddenLegacySyntaxIsRetiredCore)
}
Test("[llm-hotkey-collision] forbidden legacy trigger syntax is retired",
	_LHCC_ForbiddenLegacySyntaxIsRetired)

_LHCC_ReplayCollisionRetainsRefusedCleanupCore() {
	global _LTST_FailOldOff, _LTST_Events, _LTST_Native
	global _LLM_Menu_TriggerHandle, _LLM_Menu_TriggerAhk
	global _LLM_Menu_TriggerStatus, _LLM_Menu_TriggerRecovery
	global _LLM_Menu_TriggerRecoveryHandles
	global LLM_TRIGGER_STATUS_CLEANUP_PENDING, LLM_TRIGGER_STATUS_ERROR
	global _LTST_NotifyCalls, _LTST_RefreshCalls
	_LHCC_InstallReservedMenuState()
	_LTST_SeedOld()
	OldHandle := _LLM_Menu_TriggerHandle
	_LTST_FailOldOff := true
	AssertFalse(LLM_Menu_ApplyTriggerShortcut("Ctrl+5", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, _LTST_Schedule, _LTST_Refresh,
		_LTST_Notify),
		"an obsolete non-conflicting owner must not survive a rejected replay")
	AssertEqual("", _LLM_Menu_TriggerHandle)
	AssertEqual("", _LLM_Menu_TriggerAhk)
	AssertEqual(LLM_TRIGGER_STATUS_CLEANUP_PENDING,
		_LLM_Menu_TriggerStatus)
	AssertTrue(_LLM_Menu_TriggerRecovery is Map)
	AssertEqual("cleanup", _LLM_Menu_TriggerRecovery["stage"])
	AssertEqual(LLM_TRIGGER_STATUS_ERROR,
		_LLM_Menu_TriggerRecovery["complete_status"])
	AssertEqual(1, _LLM_Menu_TriggerRecoveryHandles.Length)
	AssertEqual(OldHandle, _LLM_Menu_TriggerRecoveryHandles[1])
	AssertTrue(_LTST_NativeEntry("^l").enabled,
		"a refused native-Off must remain explicitly owned for recovery")
	AssertEqual(1, _LTST_NotifyCalls)
	_LTST_AssertEvents(["^l Off", "schedule", "notify"],
		"collision cleanup refusal must retain one bounded recovery owner")

	_LTST_FailOldOff := false
	_LTST_Events := []
	AssertTrue(_LTST_RunScheduled())
	AssertFalse(_LLM_Menu_TriggerRecovery is Map)
	AssertEqual(0, _LLM_Menu_TriggerRecoveryHandles.Length)
	AssertEqual(LLM_TRIGGER_STATUS_ERROR, _LLM_Menu_TriggerStatus,
		"cleanup completion must preserve the persisted-collision warning")
	AssertFalse(_LTST_NativeEntry("^l").enabled)
	AssertEqual(1, _LTST_RefreshCalls)
	_LTST_AssertEvents(["^l Off", "refresh"],
		"recovery must retire the exact old owner before refreshing the menu")
}

_LHCC_ReplayCollisionRetainsRefusedCleanup() {
	return _LHCC_WithTriggerState(
		_LHCC_ReplayCollisionRetainsRefusedCleanupCore)
}
Test("[llm-hotkey-collision] replay collision retains refused old-owner cleanup",
	_LHCC_ReplayCollisionRetainsRefusedCleanup)

_LHCC_PendingTriggerCleanupDefersContextualBindersCore() {
	global HOTKEY_REGISTRAR_BINDINGS
	global _LHCC_RefuseCtrl5Off, _LHCC_ProfileReadyCalls
	global _LHCC_NavReadyCalls, _LTST_Native
	global _LLM_Menu_TriggerRecovery, _LLM_Menu_TriggerStatus
	global LLM_TRIGGER_STATUS_ACTIVE, LLM_TRIGGER_STATUS_ERROR
	_LHCC_InstallReservedMenuState()
	OldHandle := _HotkeyRegistrarBindOwned("Ctrl+5", _LTST_LlmCallback,
		"llm:trigger", _LTST_Hotkey, _LTST_Probe)
	AssertTrue(OldHandle != "")
	OldNativeSpec := HOTKEY_REGISTRAR_BINDINGS[OldHandle]["spec"]
	_LLM_Menu_PublishTriggerRuntime("Ctrl+5", "^5", OldHandle,
		LLM_TRIGGER_STATUS_ACTIVE, [])
	_LHCC_RefuseCtrl5Off := true
	AssertFalse(LLM_Menu_ApplyTriggerShortcut("Ctrl+5", _LHCC_Ctrl5Hotkey,
		_LTST_Probe, _LTST_LlmCallback, _LTST_Schedule, _LTST_Refresh,
		_LTST_Notify))
	AssertTrue(_LLM_Menu_TriggerRecovery is Map)
	AssertTrue(_LTST_Native[OldNativeSpec].enabled)
	AssertFalse(_LLM_Menu_ActivateFirstRestoreHotkeys(true,
		_LHCC_ProfileReady, _LHCC_NavReady))
	AssertEqual(0, _LHCC_ProfileReadyCalls)
	AssertEqual(0, _LHCC_NavReadyCalls)
	CaughtPending := false
	try _LLM_Menu_RequireFirstRestoreHotkeys(true,
		_LHCC_ProfileReady, _LHCC_NavReady)
	catch as Err {
		CaughtPending := Err is TrayRootRetryPendingError
	}
	AssertTrue(CaughtPending,
		"cold contextual binding must retain the tray root until trigger cleanup")
	AssertEqual(0, _LHCC_ProfileReadyCalls)
	AssertEqual(0, _LHCC_NavReadyCalls)

	_LHCC_RefuseCtrl5Off := false
	AssertTrue(_LTST_RunScheduled())
	AssertFalse(_LLM_Menu_TriggerRecovery is Map)
	AssertEqual(LLM_TRIGGER_STATUS_ERROR, _LLM_Menu_TriggerStatus)
	AssertFalse(_LTST_Native[OldNativeSpec].enabled,
		"the stale global variant must be Off before contextual publication")
	AssertTrue(_LLM_Menu_ActivateFirstRestoreHotkeys(true,
		_LHCC_ProfileReady, _LHCC_NavReady))
	AssertEqual(1, _LHCC_ProfileReadyCalls)
	AssertEqual(1, _LHCC_NavReadyCalls)
}

_LHCC_PendingTriggerCleanupDefersContextualBinders() {
	return _LHCC_WithTriggerState(
		_LHCC_PendingTriggerCleanupDefersContextualBindersCore)
}
Test("[llm-hotkey-collision] trigger cleanup precedes contextual publication",
	_LHCC_PendingTriggerCleanupDefersContextualBinders)

_LHCC_RecoveryHandleUsesNativeIdentityCore() {
	global _LLM_Menu_TriggerAhk, _LLM_Menu_TriggerRecoveryHandles
	global LLM_TRIGGER_STATUS_CLEANUP_PENDING
	_LHCC_InstallReservedMenuState()
	RecoveryDescriptor := _LLM_Menu_HotkeyResolvedDescriptor("^+7")
	AssertTrue(RecoveryDescriptor is Map)
	RecoveryIdentity := RecoveryDescriptor["identity"]
	Handle := _HotkeyRegistrarReserveResolvedOwned("Control+Shift+7",
		_LTST_LlmCallback, "llm:trigger:recovery", RecoveryDescriptor,
		_LTST_Hotkey, _LTST_Probe)
	AssertTrue(Handle != "")
	AssertTrue(_HotkeyRegistrarActivate(Handle, _LTST_Hotkey))
	AssertTrue(_LTST_Native[RecoveryDescriptor["native_spec"]].enabled,
		"the recovery-only handle must model a live global native owner")
	_LLM_Menu_PublishTriggerRuntime("", "", "",
		LLM_TRIGGER_STATUS_CLEANUP_PENDING, [Handle])
	AssertEqual("", _LLM_Menu_TriggerAhk,
		"the regression must derive authority only from the retained handle")
	AssertEqual(1, _LLM_Menu_TriggerRecoveryHandles.Length)
	Built := _LLM_Menu_BuildNavBindingPlan(
		Map("nav_modifiers", "alt", "val_modifiers", "ctrl+shift"))
	AssertTrue(Built is Map)
	Collision := _LLM_Menu_RuntimeTriggerNavCollision(Built["plan"])
	AssertTrue(Collision["ok"])
	AssertEqual(RecoveryIdentity, Collision["identity"],
		"retained handles must compare their captured native identity")
}

_LHCC_RecoveryHandleUsesNativeIdentity() {
	return _LHCC_WithTriggerState(
		_LHCC_RecoveryHandleUsesNativeIdentityCore)
}
Test("[llm-hotkey-collision] retained trigger handles keep native ownership",
	_LHCC_RecoveryHandleUsesNativeIdentity)

_LHCC_AssertPriorWalReconcilesBeforeRefusal(RawText, CandidateSpec,
		KeyResolverFn := 0) {
	global ConfigurationFile, _LTST_DurableValue, _LTST_JournalFiles
	global _LTST_JournalPath, _LTST_WriteCalls, _LTST_WriteBatches
	global _LTST_CriticalStates, _LTST_JournalMoves
	global _LTST_Native, _LLM_Menu_TriggerHandle, _LLM_Menu_TriggerAhk
	global _LLM_Menu_TriggerStatus
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global HOTKEY_REGISTRAR_NEXT_TOKEN
	_LTST_Reset()
	_LHCC_InstallReservedMenuState()
	_LTST_SeedOld()
	OldHandle := _LLM_Menu_TriggerHandle
	OldStatus := _LLM_Menu_TriggerStatus
	CandidateDescriptor := HotkeyRegistrarResolvedNativeDescriptor(
		CandidateSpec, KeyResolverFn)
	CandidateNativeSpec := CandidateDescriptor is Map
		? CandidateDescriptor["native_spec"] : CandidateSpec
	AssertFalse(_LTST_Native.Has(CandidateNativeSpec),
		"the candidate native spec must be absent before the refusal probe")
	OldToken := HOTKEY_REGISTRAR_NEXT_TOKEN
	OldBindingCount := HOTKEY_REGISTRAR_BINDINGS.Count
	OldSpecCount := HOTKEY_REGISTRAR_SPECS.Count
	OldNativeCount := _LTST_Native.Count
	_LTST_DurableValue := "Ctrl+N"
	PriorRecord := Map(
		"phase", "pending",
		"tx_id", "collision-prior-transaction",
		"owner", ConfigurationFile,
		"old_present", 1,
		"old_value", "Ctrl+L",
		"new_value", "Ctrl+N")
	_LTST_JournalFiles[_LTST_JournalPath] :=
		_LLM_TriggerJournalSerialize(PriorRecord)
	_LTST_CriticalStates := []
	_LTST_JournalMoves := []
	Status := _LTST_Commit(RawText, _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		0, 0, KeyResolverFn)
	AssertTrue((Status is Integer) && Status == 0,
		"the old WAL must reconcile before candidate refusal " . RawText)
	AssertEqual(1, _LTST_WriteCalls,
		"only the authoritative prior rollback may reach the config writer")
	AssertEqual(1, _LTST_WriteBatches.Length)
	AssertEqual(1, _LTST_WriteBatches[1].Length)
	AssertEqual("Ctrl+L", _LTST_WriteBatches[1][1].Value,
		"the rejected candidate must never enter a durable batch")
	AssertEqual(1, _LHCC_PhaseCount("journal_write"),
		"only the prior WAL promotion may stage a journal frame")
	AssertEqual(1, _LHCC_PhaseCount("journal_move"),
		"only the prior WAL promotion may publish a journal frame")
	AssertEqual(1, _LTST_JournalMoves.Length)
	AssertTrue(_LTST_JournalMoves[1] is Map)
	AssertEqual("collision-prior-transaction",
		_LTST_JournalMoves[1]["tx_id"])
	AssertEqual("committed_old", _LTST_JournalMoves[1]["phase"])
	AssertEqual("Ctrl+N", _LTST_JournalMoves[1]["new_value"],
		"the rejected candidate must never appear in a moved WAL frame")
	AssertEqual("Ctrl+L", _LTST_DurableValue)
	AssertFalse(_LTST_JournalFiles.Has(_LTST_JournalPath),
		"the prior pending record must reach a terminal delete")
	AssertEqual("Ctrl+L", _LLM_Menu["trigger_shortcut"])
	AssertEqual("^l", _LLM_Menu_TriggerAhk)
	AssertEqual(OldHandle, _LLM_Menu_TriggerHandle)
	AssertEqual(OldStatus, _LLM_Menu_TriggerStatus)
	AssertEqual(OldToken, HOTKEY_REGISTRAR_NEXT_TOKEN,
		"candidate refusal must not allocate a registrar token")
	AssertEqual(OldBindingCount, HOTKEY_REGISTRAR_BINDINGS.Count)
	AssertEqual(OldSpecCount, HOTKEY_REGISTRAR_SPECS.Count)
	AssertEqual(OldNativeCount, _LTST_Native.Count)
	AssertFalse(_LTST_Native.Has(CandidateNativeSpec),
		"WAL repair must still precede every candidate native effect")
}

_LHCC_LiveCollisionReconcilesPriorWalCore() {
	global _LHCC_PriorWalCompleted
	for Vector in [
		Map("raw", "Ctrl+5", "spec", "^5",
			"resolver", _LHCC_UsPhysicalKey),
		Map("raw", "Ctrl+VK35", "spec", "^vk35"),
		Map("raw", "*7", "spec", "*7"),
		Map("raw", "Ctrl+5 Up", "spec", "^5 up"),
		Map("raw", "XButton1", "spec", "xbutton1"),
		Map("raw", "XButton2", "spec", "xbutton2"),
		Map("raw", "Ctrl+WheelUp", "spec", "^wheelup"),
		Map("raw", "Ctrl+XButton1", "spec", "^xbutton1"),
		Map("raw", "LCtrl", "spec", "lctrl")
	] {
		_LHCC_AssertPriorWalReconcilesBeforeRefusal(
			Vector["raw"], Vector["spec"], Vector.Get("resolver", 0))
	}
	_LHCC_PriorWalCompleted := true
}

_LHCC_LiveCollisionReconcilesPriorWal() {
	global _LHCC_PriorWalCompleted
	_LHCC_PriorWalCompleted := false
	Result := _LHCC_WithTriggerState(_LHCC_LiveCollisionReconcilesPriorWalCore)
	AssertTrue(_LHCC_PriorWalCompleted,
		"the prior-WAL fixture must reach every candidate refusal assertion")
	return Result
}
Test("[llm-hotkey-collision] prior WAL reconciles before live collision refusal",
	_LHCC_LiveCollisionReconcilesPriorWal)

_LHCC_LiveEditSeesPublishedContextualOwnersCore() {
	global _LLM_Menu_ProfileHotkeyOwner, _LLM_Menu_NavHotkeysBound
	global _LLM_Menu_NavSlotPlans, _LLM_Menu_NavActiveSlot
	global _LTST_WriteCalls, _LTST_Native
	_LHCC_InstallReservedMenuState()
	_LTST_SeedOld()
	_LPHT_ResetPorts()
	AssertTrue(_LPHT_ProfileBindPort() == 1)
	_LNHT_Reset()
	AssertTrue(LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset) == 1)
	OldProfileOwner := _LLM_Menu_ProfileHotkeyOwner
	OldNavBound := _LLM_Menu_NavHotkeysBound
	OldNavPlans := _LLM_Menu_NavSlotPlans
	OldNavSlot := _LLM_Menu_NavActiveSlot
	AssertFalse(_LTST_Commit("Ctrl+5", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback),
		"a live trigger edit must reject already-published contextual owners")
	AssertEqual(0, _LTST_WriteCalls)
	AssertTrue(_LLM_Menu_ProfileHotkeyOwner == OldProfileOwner)
	AssertTrue(_LLM_Menu_NavHotkeysBound == OldNavBound)
	AssertTrue(_LLM_Menu_NavSlotPlans == OldNavPlans)
	AssertEqual(OldNavSlot, _LLM_Menu_NavActiveSlot)
	AssertTrue(_LLM_Menu_ProfileHotkeyOwnerReady())
	AssertEqual(12, _LLM_Menu_NavHotkeysBound.Length)
	AssertFalse(_LTST_NativeHas("^5"))
}

_LHCC_LiveEditSeesPublishedContextualOwners() {
	return _LHCC_WithTriggerState(
		_LHCC_LiveEditSeesPublishedContextualOwnersCore)
}
Test("[llm-hotkey-collision] live edit preserves published contextual owners",
	_LHCC_LiveEditSeesPublishedContextualOwners)

_LHCC_ContextualRoutesCore() {
	global _LLM_Menu, _LLM_Menu_ProfileHotkeyOwner
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavSlotPlans
	global _LLM_Menu_NavActiveSlot, _LLM_Menu_Loaded
	global _LPHT_SelectedProfiles, _LPHT_AppOutput
	global _LNHT_AppOutput, _LNHT_TooltipActiveIdx
	global _LTST_WriteCalls, _LTST_LlmCalls
	global _LHCC_ContextualRoutingCompleted
	_LHCC_ContextualRoutingCompleted := false
	_LLM_Menu["trigger_shortcut"] := ""
	_LLM_Menu["nav_modifiers"] := "alt"
	_LLM_Menu["val_modifiers"] := "alt"
	_LLM_Menu_Loaded := true
	_LTST_SeedOld()

	ProfileStatus := _LPHT_ProfileBindSelectPort()
	AssertTrue((ProfileStatus is Integer) && ProfileStatus == 1)
	NavStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset)
	AssertTrue((NavStatus is Integer) && NavStatus == 1)
	OldProfileOwner := _LLM_Menu_ProfileHotkeyOwner
	OldNavBound := _LLM_Menu_NavHotkeysBound
	OldNavPlans := _LLM_Menu_NavSlotPlans
	OldNavSlot := _LLM_Menu_NavActiveSlot

	for RawText in ["Ctrl+5", "Alt+7"] {
		Status := _LTST_Commit(RawText, _LTST_Writer,
			_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback)
		AssertTrue((Status is Integer) && Status == 0,
			"live trigger edits must yield to every published contextual owner")
	}
	AssertEqual(0, _LTST_WriteCalls)
	AssertTrue(_LLM_Menu_ProfileHotkeyOwner == OldProfileOwner)
	AssertTrue(_LLM_Menu_NavHotkeysBound == OldNavBound)
	AssertTrue(_LLM_Menu_NavSlotPlans == OldNavPlans)
	AssertEqual(OldNavSlot, _LLM_Menu_NavActiveSlot)

	ProfileEvent := Map("owner", "physical-profile-5")
	_LPHT_SelectedProfiles := []
	_LPHT_AppOutput := []
	ProfileOrder := LLM_Menu_GetHotkeyProfileOrder()
	ProfileNative5 := _LPHT_NativeSpec("^5")
	AssertEqual("hotkey", _LPHT_FirePhysical("^5", ProfileEvent,
		ProfileNative5, true))
	AssertEqual(1, _LPHT_SelectedProfiles.Length)
	AssertEqual(ProfileOrder[5], _LPHT_SelectedProfiles[1])
	AssertEqual(0, _LPHT_AppOutput.Length)

	_LLM_Menu["user_profiles"] := []
	PassEvent := Map("owner", "physical-profile-pass")
	AssertEqual("app", _LPHT_FirePhysical("^5", PassEvent,
		ProfileNative5))
	AssertEqual(1, _LPHT_AppOutput.Length)
	AssertTrue(_LPHT_AppOutput[1] == PassEvent,
		"an ineligible profile variant must preserve the exact physical event")

	_LNHT_AppOutput := []
	_LNHT_ShowTooltip(["one", "two", "three", "four", "five", "six",
		"seven"])
	AssertEqual("hotkey", _LNHT_FirePhysical("!7"))
	AssertEqual(7, _LNHT_TooltipActiveIdx)
	AssertEqual(0, _LNHT_AppOutput.Length)
	_LNHT_HideTooltip()
	AssertEqual("app", _LNHT_FirePhysical("!7"))
	AssertEqual(1, _LNHT_AppOutput.Length)
	AssertEqual("!7", _LNHT_AppOutput[1],
		"an ineligible navigation variant must reach the app exactly once")
	_LNHT_AppOutput := []
	_LNHT_ShowTooltip(["one", "two", "three", "four", "five", "six"])
	AssertEqual("app", _LNHT_FirePhysical("!7"))
	AssertEqual(1, _LNHT_AppOutput.Length)
	AssertEqual("!7", _LNHT_AppOutput[1],
		"an out-of-range visible nav digit must not fall through to the trigger")

	AssertTrue(_LTST_Fire("^l"))
	AssertEqual(1, _LTST_LlmCalls,
		"the non-conflicting trigger owner must remain the only global callback")
	Owners := _LLM_Menu_BuildContextualHotkeyOwners(_LLM_Menu)
	AssertTrue(Owners is Map)
	TabIdentity := _LLM_Menu_HotkeyPhysicalIdentity("tab")
	AssertTrue(TabIdentity != "")
	AssertEqual("tooltip acceptance", Owners[TabIdentity])
	_LHCC_ContextualRoutingCompleted := true
}

_LHCC_ContextualRoutesNavFixture() {
	return _LNHT_WithFixture(_LHCC_ContextualRoutesCore)
}

_LHCC_ContextualRoutesProfileFixture() {
	return _LPHT_WithFixture(_LHCC_ContextualRoutesNavFixture)
}

_LHCC_ContextualRoutesTriggerFixture() {
	return _LTST_WithFixture(_LHCC_ContextualRoutesProfileFixture)
}

_LHCC_ContextualRoutes() {
	global _LHCC_ContextualRoutingCompleted
	Result := _LHCC_ContextualRoutesTriggerFixture()
	AssertTrue(_LHCC_ContextualRoutingCompleted,
		"the nested owner fixture must reach every terminal routing assertion")
	return Result
}
Test("[llm-hotkey-collision] contextual owners retain exact eligible routing",
	_LHCC_ContextualRoutes)





; ====================================
; ====================================
; ======= 3/ Navigation Policy =======
; ====================================
; ====================================

_LHCC_NavCommitAfterTriggerCore() {
	global Features, _LLM_Menu, _LLM_Menu_NavHotkeysBound
	global _LLM_Menu_NavSlotPlans, _LLM_Menu_NavActiveSlot
	global _LNHT_Events, _LNHT_TransactionWriterCalls
	global _LNHT_TransactionApplyCalls, _LNHT_TransactionNotifyCalls
	global _LNHT_LogCalls, _LNHT_LogCritical
	global _LNHT_HotIfDepth, _LNHT_RejectCalls
	global _LTST_Events, _LTST_LlmCalls
	global _LHCC_NavAcquireCalls, _LHCC_NavSettleCalls
	global _LHCC_NavQuiesceCalls, _LHCC_NavCollectCalls
	global _LHCC_NavHotkeyCalls, _LHCC_NavHotIfCalls, _LHCC_NavResetCalls
	global _LHCC_NavCommitCompleted
	_LHCC_NavCommitCompleted := false
	AssertTrue(LLM_Menu_ApplyTriggerShortcut("Control+Shift+7", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, 0, 0, _LTST_Notify,
		_LHCC_UsPhysicalKey),
		"the trigger must be valid against the initial Alt navigation surface")
	_LTST_Events := []
	AssertTrue(LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset,
		_LHCC_UsPhysicalKey))
	OldFeatures := Features
	OldMenu := _LLM_Menu
	OldBound := _LLM_Menu_NavHotkeysBound
	OldPlans := _LLM_Menu_NavSlotPlans
	OldSlot := _LLM_Menu_NavActiveSlot
	InactiveSlot := OldSlot == 1 ? 2 : 1
	OldInactivePlan := OldPlans[InactiveSlot]
	_LNHT_Events := []
	_LHCC_ResetNavBoundaryCounters()
	_LNHT_LogCalls := 0
	_LNHT_LogCritical := -1
	InheritedCritical := Critical(37)
	try {
		Status := LLM_Menu_CommitNavModifier("val_modifiers", "shift+ctrl",
			0, 0, _LNHT_Reject,
			_LHCC_NavTransactionPort(_LHCC_UsPhysicalKey))
		AssertTrue((Status is Integer) && Status == 0,
			"candidate navigation must yield to the active global trigger")
		AssertEqual(37, A_IsCritical,
			"navigation refusal must restore the exact inherited Critical interval")
	} finally Critical(InheritedCritical)
	AssertEqual(0, _LNHT_TransactionWriterCalls)
	AssertEqual(0, _LNHT_TransactionApplyCalls)
	AssertEqual(1, _LNHT_TransactionNotifyCalls)
	AssertEqual(0, _LNHT_RejectCalls)
	AssertEqual(1, _LHCC_NavAcquireCalls)
	AssertEqual(1, _LHCC_NavSettleCalls)
	AssertEqual(1, _LHCC_NavQuiesceCalls)
	AssertEqual(1, _LHCC_NavCollectCalls)
	AssertEqual(0, _LHCC_NavHotkeyCalls)
	AssertEqual(0, _LHCC_NavHotIfCalls)
	AssertEqual(0, _LHCC_NavResetCalls)
	AssertEqual(1, _LNHT_LogCalls,
		"a rejected navigation candidate must report exactly once")
	AssertEqual(0, _LNHT_LogCritical,
		"navigation collision diagnostics must run outside Critical")
	AssertEqual(0, _LNHT_Events.Length,
		"collision rejection must precede every HotIf and Hotkey adapter")
	AssertEqual(0, _LNHT_HotIfDepth)
	AssertTrue(Features == OldFeatures)
	AssertTrue(_LLM_Menu == OldMenu)
	AssertTrue(_LLM_Menu_NavHotkeysBound == OldBound)
	AssertTrue(_LLM_Menu_NavSlotPlans == OldPlans)
	AssertTrue(_LLM_Menu_NavSlotPlans[InactiveSlot] == OldInactivePlan,
		"the inactive native slot must remain untouched")
	AssertEqual(OldSlot, _LLM_Menu_NavActiveSlot)
	AssertEqual("alt", _LLM_Menu["val_modifiers"])
	_LNHT_AssertOnlyPrefix("!")
	AssertTrue(_LTST_Fire("^+7"))
	AssertEqual(1, _LTST_LlmCalls)

	_LNHT_Events := []
	_LNHT_TransactionWriterCalls := 0
	_LNHT_TransactionApplyCalls := 0
	_LNHT_TransactionNotifyCalls := 0
	_LNHT_LogCalls := 0
	AssertTrue(LLM_Menu_CommitNavModifier("val_modifiers", "shift",
		0, 0, _LNHT_Reject,
		_LHCC_NavTransactionPort(_LHCC_UsPhysicalKey)),
		"a neighboring navigation surface must remain configurable")
	AssertEqual(1, _LNHT_TransactionWriterCalls)
	AssertEqual(1, _LNHT_TransactionApplyCalls)
	AssertEqual(0, _LNHT_TransactionNotifyCalls)
	AssertEqual("shift", _LLM_Menu["val_modifiers"])
	_LNHT_AssertSurface("!", "+")
	AssertTrue(_LTST_Fire("^+7"))
	AssertEqual(2, _LTST_LlmCalls)
	_LHCC_NavCommitCompleted := true
}

_LHCC_NavCommitAfterTriggerPersistenceFixture() {
	return _LNHT_WithPersistenceFixture(_LHCC_NavCommitAfterTriggerCore)
}

_LHCC_NavCommitAfterTrigger() {
	global _LHCC_NavCommitCompleted
	Result := _LTST_WithFixture(
		_LHCC_NavCommitAfterTriggerPersistenceFixture)
	AssertTrue(_LHCC_NavCommitCompleted,
		"the nested transaction fixture must reach its terminal assertions")
	return Result
}
Test("[llm-hotkey-collision] nav candidates preserve the active trigger owner",
	_LHCC_NavCommitAfterTrigger)

_LHCC_TestPhysicalKey(Key, FrenchLayout) {
	LowerKey := StrLower(Key)
	if LowerKey == "tab"
		return Map("axis", "vk", "code", 0x09, "implicit_modifiers", "")
	if LowerKey == "up"
		return Map("axis", "sc", "code", 0x148, "implicit_modifiers", "")
	if LowerKey == "down"
		return Map("axis", "sc", "code", 0x150, "implicit_modifiers", "")
	if LowerKey == "numpadup"
		return Map("axis", "vk", "code", 0x26, "implicit_modifiers", "")
	DigitScans := Map(
		"1", 0x002, "2", 0x003, "3", 0x004, "4", 0x005, "5", 0x006,
		"6", 0x007, "7", 0x008, "8", 0x009, "9", 0x00A, "0", 0x00B)
	if DigitScans.Has(LowerKey) {
		return Map("axis", "vk", "code", Ord(LowerKey),
			"implicit_modifiers", FrenchLayout ? "+" : "")
	}
	if LowerKey == "(" {
		return FrenchLayout
			? Map("axis", "vk", "code", 0x35, "implicit_modifiers", "")
			: Map("axis", "vk", "code", 0x39, "implicit_modifiers", "+")
	}
	if FrenchLayout {
		FrenchAliases := Map("&", 0x31, "é", 0x32, "è", 0x37)
		if FrenchAliases.Has(LowerKey)
			return Map("axis", "vk", "code", FrenchAliases[LowerKey],
				"implicit_modifiers", "")
		; AltGr cannot be represented by the bounded scalar collision identity.
		if LowerKey == "@"
			return false
	}
	return false
}

_LHCC_FrenchPhysicalKey(Key) {
	return _LHCC_TestPhysicalKey(Key, true)
}

_LHCC_UsPhysicalKey(Key) {
	return _LHCC_TestPhysicalKey(Key, false)
}

_LHCC_DescriptorPhysicalKey(Key) {
	LowerKey := StrLower(Key)
	if LowerKey == "l"
		return Map("axis", "vk", "code", 0x4C,
			"implicit_modifiers", "")
	if LowerKey == "enter"
		return Map("axis", "vk", "code", 0x0D,
			"implicit_modifiers", "")
	if LowerKey == "numpadenter"
		return Map("axis", "sc", "code", 0x11C,
			"implicit_modifiers", "")
	return _LHCC_FrenchPhysicalKey(Key)
}

_LHCC_NavDuplicatePhysicalKey(Key) {
	if Key == "1"
		return Map("axis", "vk", "code", 0x31,
			"implicit_modifiers", "+")
	if Key == "2"
		return Map("axis", "vk", "code", 0x31,
			"implicit_modifiers", "")
	return _LHCC_UsPhysicalKey(Key)
}

_LHCC_ProfileDuplicatePhysicalKey(Key) {
	if Key == "1"
		return Map("axis", "vk", "code", 0x31,
			"implicit_modifiers", "^")
	if Key == "2"
		return Map("axis", "vk", "code", 0x31,
			"implicit_modifiers", "")
	return _LHCC_UsPhysicalKey(Key)
}

_LHCC_FailFrozenReserve(Name, Action := unset, Options := unset) {
	global _LHCC_FrozenReserveFailure
	if _LHCC_FrozenReserveFailure && IsSet(Options) && Options == "Off"
			&& Name == "^+vk35"
		throw Error("injected frozen-spec reserve refusal")
	if !IsSet(Action)
		return _LTST_Hotkey(Name)
	if !IsSet(Options)
		return _LTST_Hotkey(Name, Action)
	return _LTST_Hotkey(Name, Action, Options)
}

_LHCC_NativeResolverMatchesAhkAxisAndFlags() {
	global _LHCC_ResolverLayout, _LHCC_ResolverLayoutCalls
	global _LHCC_ResolverVkScanCalls, _LHCC_ResolverGetVkCalls
	global _LHCC_ResolverGetScCalls, _LHCC_ResolverPacked
	global _LHCC_ResolverVkCodes, _LHCC_ResolverScCodes
	global _LHCC_ResolverSeenKeys
	_LHCC_ResolverLayout := 0x040C
	_LHCC_ResolverLayoutCalls := 0
	_LHCC_ResolverVkScanCalls := 0
	_LHCC_ResolverGetVkCalls := 0
	_LHCC_ResolverGetScCalls := 0
	_LHCC_ResolverSeenKeys := Map()
	_LHCC_ResolverPacked := Map(
		"5", 0x0135, "(", 0x0035, "a", -1, "?", -1,
		"x", 0x0835, "~", 0x8035, "@", 0x0630)
	_LHCC_ResolverVkCodes := Map("numpadup", 0x26)
	_LHCC_ResolverScCodes := Map("up", 0x148)
	Resolver := HotkeyRegistrarNativeKeyResolverSnapshot(_LHCC_ResolverPort())
	AssertTrue(HasMethod(Resolver, "Call"))

	Five := Resolver.Call("5")
	AssertTrue(Five is Map)
	AssertEqual(3, Five.Count)
	AssertEqual("vk", Five["axis"])
	AssertEqual(0x35, Five["code"])
	AssertEqual("+", Five["implicit_modifiers"])
	Paren := Resolver.Call("(")
	AssertEqual("vk", Paren["axis"])
	AssertEqual(0x35, Paren["code"])
	AssertEqual("", Paren["implicit_modifiers"])

	AsciiFallback := Resolver.Call("a")
	AssertEqual(0x41, AsciiFallback["code"])
	AssertEqual("", AsciiFallback["implicit_modifiers"])
	AssertFalse(Resolver.Call("?"),
		"an unresolved non-letter must fail closed")
	AssertFalse(Resolver.Call("x"),
		"reserved VkKeyScanEx state bits must fail closed")
	AssertFalse(Resolver.Call("~"),
		"dead-key state must fail closed")
	AssertFalse(Resolver.Call("@"),
		"AltGr cannot be flattened into neutral Ctrl+Alt ownership")

	Up := Resolver.Call("Up")
	NumpadUp := Resolver.Call("NumpadUp")
	AssertEqual("sc", Up["axis"])
	AssertEqual(0x148, Up["code"])
	AssertEqual("vk", NumpadUp["axis"])
	AssertEqual(0x26, NumpadUp["code"])
	AssertEqual(1, _LHCC_ResolverLayoutCalls,
		"one resolver snapshot must capture exactly one HKL")
	AssertEqual(7, _LHCC_ResolverVkScanCalls)
	AssertEqual(1, _LHCC_ResolverGetVkCalls)
	AssertEqual(1, _LHCC_ResolverGetScCalls)
}
Test("[llm-hotkey-collision] native resolver mirrors AHK layout and key axis",
	_LHCC_NativeResolverMatchesAhkAxisAndFlags)

_LHCC_PublicDecisionCapturesOneLayoutCore() {
	global _LHCC_ResolverLayout, _LHCC_ResolverLayoutCalls
	global _LHCC_ResolverVkScanCalls, _LHCC_ResolverGetVkCalls
	global _LHCC_ResolverGetScCalls, _LHCC_ResolverPacked
	global _LHCC_ResolverVkCodes, _LHCC_ResolverScCodes
	global _LHCC_ResolverSeenKeys
	global _LLM_Menu_TriggerHandle
	_LTST_Reset()
	_LHCC_InstallReservedMenuState()
	_LHCC_ResolverLayout := 0x040C
	_LHCC_ResolverLayoutCalls := 0
	_LHCC_ResolverVkScanCalls := 0
	_LHCC_ResolverGetVkCalls := 0
	_LHCC_ResolverGetScCalls := 0
	_LHCC_ResolverSeenKeys := Map()
	_LHCC_ResolverPacked := Map("l", -1)
	Loop 10 {
		Digit := A_Index == 10 ? "0" : String(A_Index)
		_LHCC_ResolverPacked[Digit] := 0x0100 | Ord(Digit)
	}
	_LHCC_ResolverVkCodes := Map("tab", 0x09)
	_LHCC_ResolverScCodes := Map("up", 0x148, "down", 0x150)
	Status := LLM_Menu_ApplyTriggerShortcut("Ctrl+L", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, 0, 0, _LTST_Notify,
		_LHCC_ResolverPort())
	AssertTrue((Status is Integer) && Status == 1)
	AssertEqual(1, _LHCC_ResolverLayoutCalls,
		"one public admission must capture exactly one HKL for candidate and owners")
	AssertEqual(14, _LHCC_ResolverSeenKeys.Count,
		"candidate and all thirteen distinct contextual keys must use one resolver")
	NavOwnerCalls := _LHCC_ResolverSeenKeys.Get("0", 0)
	AssertTrue(NavOwnerCalls > 0,
		"the nav-only zero digit must be resolved by the captured owner")
	for Key in ["tab", "up", "down"]
		AssertEqual(NavOwnerCalls, _LHCC_ResolverSeenKeys.Get(Key, 0),
			"each single contextual owner must traverse the same resolver path: " . Key)
	Loop 9
		AssertEqual(NavOwnerCalls * 2,
			_LHCC_ResolverSeenKeys.Get(String(A_Index), 0),
			"digits 1..9 must be resolved once for profile and once for navigation")
	AssertTrue(_LHCC_ResolverSeenKeys.Get("l", 0) > 0,
		"the trigger candidate must share the contextual resolver snapshot")
	AssertTrue(_LLM_Menu_TriggerHandle != "")
	AssertEqual("^vk004C",
		HotkeyRegistrarPhysicalIdentityOf(_LLM_Menu_TriggerHandle))
}

_LHCC_PublicDecisionCapturesOneLayout() {
	return _LHCC_WithTriggerState(_LHCC_PublicDecisionCapturesOneLayoutCore)
}
Test("[llm-hotkey-collision] public admission snapshots one keyboard layout",
	_LHCC_PublicDecisionCapturesOneLayout)

_LHCC_LayoutAwarePhysicalIdentities() {
	for Pair in [
		Map("digit", "^2", "alias", "^+é"),
		Map("digit", "^5", "alias", "^+("),
		Map("digit", "^7", "alias", "^+è")
	] {
		FrenchDigit := _LLM_Menu_HotkeyPhysicalIdentity(Pair["digit"],
			_LHCC_FrenchPhysicalKey)
		FrenchAlias := _LLM_Menu_HotkeyPhysicalIdentity(Pair["alias"],
			_LHCC_FrenchPhysicalKey)
		AssertTrue(FrenchDigit != "")
		AssertEqual(FrenchDigit, FrenchAlias,
			"AZERTY character aliases must share their native contextual owner")
	}
	FrenchProfile := _LLM_Menu_HotkeyPhysicalIdentity("^5",
		_LHCC_FrenchPhysicalKey)
	AssertEqual(FrenchProfile,
		_LLM_Menu_HotkeyPhysicalIdentity("^+5", _LHCC_FrenchPhysicalKey),
		"an explicit Shift must merge with the layout's implicit Shift")
	AssertFalse(_LLM_Menu_HotkeyPhysicalIdentity("^é", _LHCC_FrenchPhysicalKey)
		== _LLM_Menu_HotkeyPhysicalIdentity("^2", _LHCC_FrenchPhysicalKey),
		"an alias without the contextual owner's Shift remains a different chord")

	State := Map("nav_modifiers", "alt", "val_modifiers", "alt")
	Conflict := _LLM_Menu_CheckTriggerContextCollision("^+(", State,
		_LHCC_FrenchPhysicalKey)
	AssertTrue(Conflict["ok"])
	AssertEqual("profile selection", Conflict["owner"])
	AssertEqual(FrenchProfile, Conflict["identity"])

	UsProfile := _LLM_Menu_HotkeyPhysicalIdentity("^5", _LHCC_UsPhysicalKey)
	UsPunctuation := _LLM_Menu_HotkeyPhysicalIdentity("^+(",
		_LHCC_UsPhysicalKey)
	AssertFalse(UsProfile == UsPunctuation,
		"physically distinct US chords must not be rejected as one owner")
	AssertFalse(_LLM_Menu_HotkeyPhysicalIdentity("up", _LHCC_FrenchPhysicalKey)
		== _LLM_Menu_HotkeyPhysicalIdentity("numpadup",
			_LHCC_FrenchPhysicalKey),
		"AHK scan-code arrows must remain distinct from VK numpad aliases")
	MalformedResolver := (*) => Map("axis", "vk", "code", "bad",
		"implicit_modifiers", "")
	AssertEqual("", _LLM_Menu_HotkeyPhysicalIdentity("^5", MalformedResolver))
	Malformed := _LLM_Menu_CheckTriggerContextCollision("^5", State,
		MalformedResolver)
	AssertFalse(Malformed["ok"],
		"malformed physical resolution must fail closed")
}
Test("[llm-hotkey-collision] policy resolves layout-dependent physical aliases",
	_LHCC_LayoutAwarePhysicalIdentities)

_LHCC_LayoutAwareEntryPointsCore() {
	global _LTST_Native, _LTST_NotifyCalls, _LTST_WriteCalls
	global _LTST_JournalFiles
	global _LNHT_LogCalls, _LNHT_LogCritical, _LNHT_Events
	global _LHCC_NavHotkeyCalls, _LHCC_NavHotIfCalls, _LHCC_NavResetCalls

	_LTST_Reset()
	_LHCC_InstallReservedMenuState()
	BootStatus := LLM_Menu_ApplyTriggerShortcut("Ctrl+Shift+(", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, 0, 0, _LTST_Notify,
		_LHCC_FrenchPhysicalKey)
	AssertTrue((BootStatus is Integer) && BootStatus == 0)
	AssertEqual(1, _LTST_NotifyCalls)
	AssertEqual(0, _LTST_Native.Count,
		"layout collision boot refusal must precede native reservation")

	_LTST_Reset()
	_LHCC_InstallReservedMenuState()
	UsBootStatus := LLM_Menu_ApplyTriggerShortcut("Ctrl+Shift+(", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, 0, 0, _LTST_Notify,
		_LHCC_UsPhysicalKey)
	AssertTrue((UsBootStatus is Integer) && UsBootStatus == 1,
		"the physically distinct US chord must remain configurable")
	UsTriggerDescriptor := _LLM_Menu_HotkeyResolvedDescriptor("^+(",
		_LHCC_UsPhysicalKey)
	AssertTrue(UsTriggerDescriptor is Map)
	AssertTrue(_LTST_Native.Has(UsTriggerDescriptor["native_spec"])
		&& _LTST_Native[UsTriggerDescriptor["native_spec"]].enabled)

	_LHCC_AssertPriorWalReconcilesBeforeRefusal("Ctrl+Shift+(", "^+(",
		_LHCC_FrenchPhysicalKey)

	_LTST_Reset()
	_LHCC_InstallReservedMenuState()
	AssertTrue(LLM_Menu_ApplyTriggerShortcut("Alt+Shift+(", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, 0, 0, _LTST_Notify,
		_LHCC_FrenchPhysicalKey))
	CandidateMenu := Map("nav_modifiers", "alt", "val_modifiers", "alt")
	Built := _LLM_Menu_BuildNavBindingPlan(CandidateMenu)
	AssertTrue(Built is Map)
	for Entry in Built["plan"]
		Entry["native_id"] := "poisoned-textual-identity"
	Collision := _LLM_Menu_RuntimeTriggerNavCollision(Built["plan"],
		_LHCC_FrenchPhysicalKey)
	AssertTrue(Collision["ok"])
	AssertTrue(Collision["identity"] != "",
		"reverse collision must resolve immutable specs, not cached textual ids")
	_LNHT_Reset()
	_LHCC_ResetNavBoundaryCounters()
	_LNHT_LogCalls := 0
	_LNHT_LogCritical := -1
	FrenchNavStatus := LLM_Menu_BindNavHotkeys(CandidateMenu,
		_LHCC_NavHotkey, _LHCC_NavHotIf, _LNHT_Log, _LHCC_NavReset,
		_LHCC_FrenchPhysicalKey)
	AssertTrue((FrenchNavStatus is Integer) && FrenchNavStatus == 0)
	AssertEqual(1, _LNHT_LogCalls)
	AssertEqual(0, _LNHT_LogCritical)
	AssertEqual(0, _LHCC_NavHotkeyCalls)
	AssertEqual(0, _LHCC_NavHotIfCalls)
	AssertEqual(0, _LHCC_NavResetCalls)
	AssertEqual(0, _LNHT_Events.Length)

	_LTST_Reset()
	_LHCC_InstallReservedMenuState()
	AssertTrue(LLM_Menu_ApplyTriggerShortcut("Alt+Shift+(", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, 0, 0, _LTST_Notify,
		_LHCC_UsPhysicalKey))
	_LNHT_Reset()
	_LHCC_ResetNavBoundaryCounters()
	UsNavStatus := LLM_Menu_BindNavHotkeys(CandidateMenu,
		_LHCC_NavHotkey, _LHCC_NavHotIf, _LNHT_Log, _LHCC_NavReset,
		_LHCC_UsPhysicalKey)
	AssertTrue((UsNavStatus is Integer) && UsNavStatus == 1,
		"the physically distinct US navigation surface must bind")
	AssertTrue(_LHCC_NavHotkeyCalls > 0)

	_LTST_Reset()
	_LHCC_InstallReservedMenuState()
	MalformedResolver := (*) => Map("axis", "vk", "code", "bad",
		"implicit_modifiers", "")
	MalformedStatus := LLM_Menu_ApplyTriggerShortcut("Ctrl+L", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, 0, 0, _LTST_Notify,
		MalformedResolver)
	AssertTrue((MalformedStatus is Integer) && MalformedStatus == 0)
	AssertEqual(0, _LTST_Native.Count,
		"malformed physical identity must fail before native reserve")
	AssertEqual(0, _LTST_WriteCalls)

	_LTST_Reset()
	_LHCC_InstallReservedMenuState()
	_LTST_SeedOld()
	MalformedLiveStatus := _LTST_Commit("Ctrl+N", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		0, 0, MalformedResolver)
	AssertTrue((MalformedLiveStatus is Integer) && MalformedLiveStatus == 0)
	AssertEqual(0, _LTST_WriteCalls)
	AssertEqual(0, _LTST_JournalFiles.Count,
		"malformed physical identity must precede every candidate WAL frame")
	AssertTrue(_LTST_NativeHas("^l") && _LTST_NativeEntry("^l").enabled)
	AssertFalse(_LTST_NativeHas("^n"))
}

_LHCC_LayoutAwareEntryPoints() {
	return _LHCC_WithTriggerState(_LHCC_LayoutAwareEntryPointsCore)
}
Test("[llm-hotkey-collision] boot live WAL and nav share one layout owner",
	_LHCC_LayoutAwareEntryPoints)

_LHCC_RegisteredOwnersKeepBindingLayoutCore() {
	global HOTKEY_REGISTRAR_BINDINGS
	global _LLM_Menu, _LLM_Menu_ProfileHotkeyOwner
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavActiveSlot
	global _LTST_Native, _LTST_WriteCalls
	global _LPHT_Hotkeys, _LNHT_Hotkeys
	global _LHCC_NavHotkeyCalls, _LHCC_NavHotIfCalls
	global _LHCC_NavResetCalls
	global LLM_TRIGGER_STATUS_CLEANUP_PENDING
	global _LPHT_HotkeyCalls, _LPHT_OpenCalls, _LPHT_CloseCalls
	global _LPHT_ResetCalls

	; A profile generation already parsed under French AZERTY owns
	; Ctrl+Shift+VK35 for its textual ^5 variant. A later US-layout trigger
	; decision must compare against that immutable native owner, not reparse ^5
	; under the new layout where it would appear to omit Shift.
	_LTST_Reset()
	_LHCC_InstallReservedMenuState()
	_LTST_SeedOld()
	_LPHT_ResetPorts()
	ProfileBindStatus := LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
		_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset, _LPHT_Select,
		_LHCC_FrenchPhysicalKey)
	AssertTrue((ProfileBindStatus is Integer) && ProfileBindStatus == 1)
	AssertTrue(_LLM_Menu_ProfileHotkeyOwnerReady())
	AssertEqual(_LLM_Menu_HotkeyPhysicalIdentity("^5",
		_LHCC_FrenchPhysicalKey),
		_LLM_Menu_ProfileHotkeyOwner["plan"][5]["physical_id"])
	ProfileFive := _LLM_Menu_ProfileHotkeyOwner["plan"][5]
	AssertEqual("^5", ProfileFive["spec"])
	AssertEqual("^+vk35", ProfileFive["native_spec"])
	AssertEqual("^+vk35", ProfileFive["native_id"])
	AssertEqual("^+vk0035", ProfileFive["physical_id"])
	AssertTrue(_LPHT_Hotkeys.Has("^+vk35"))
	AssertFalse(_LPHT_Hotkeys.Has("^5"),
		"profile Hotkey() must never reparse the logical digit after admission")
	ProfileStatus := _LTST_Commit("Ctrl+Shift+5", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		0, 0, _LHCC_UsPhysicalKey)
	AssertTrue((ProfileStatus is Integer) && ProfileStatus == 0,
		"a trigger must yield to the profile generation's registration layout")
	AssertEqual(0, _LTST_WriteCalls)
	AssertFalse(_LTST_NativeHas("^+5", _LHCC_UsPhysicalKey))
	AssertTrue(_LTST_NativeHas("^l") && _LTST_NativeEntry("^l").enabled)

	; The reverse order has the same invariant. Preserve the physical identity
	; captured with the active French trigger, then prepare a US navigation
	; generation whose textual Alt+5 resolves to that same owner.
	_LTST_Reset()
	_LHCC_InstallReservedMenuState()
	AssertTrue(LLM_Menu_ApplyTriggerShortcut("Alt+(", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, 0, 0, _LTST_Notify,
		_LHCC_FrenchPhysicalKey))
	Handle := _LLM_Menu_TriggerHandle
	AssertTrue(HOTKEY_REGISTRAR_BINDINGS.Has(Handle))
	AssertEqual(_LLM_Menu_HotkeyPhysicalIdentity("!(",
		_LHCC_FrenchPhysicalKey),
		HotkeyRegistrarPhysicalIdentityOf(Handle),
		"the trigger handle must retain its registration-layout identity")
	_LNHT_Reset()
	_LHCC_ResetNavBoundaryCounters()
	CandidateMenu := Map("nav_modifiers", "alt", "val_modifiers", "alt")
	NavStatus := LLM_Menu_BindNavHotkeys(CandidateMenu,
		_LHCC_NavHotkey, _LHCC_NavHotIf, _LNHT_Log, _LHCC_NavReset,
		_LHCC_UsPhysicalKey)
	AssertTrue((NavStatus is Integer) && NavStatus == 0,
		"navigation must yield to the trigger generation's registration layout")
	AssertEqual(0, _LHCC_NavHotkeyCalls)
	AssertEqual(0, _LHCC_NavHotIfCalls)
	AssertEqual(0, _LHCC_NavResetCalls)

	; The stored FR owner has no Shift. A US Alt+Shift digit generation is
	; physically distinct and must remain configurable. Reparsing the old "("
	; under US would invent Shift+VK39 and falsely reject the candidate's 9.
	_LNHT_Reset()
	_LHCC_ResetNavBoundaryCounters()
	DistinctMenu := Map("nav_modifiers", "alt",
		"val_modifiers", "alt+shift")
	DistinctStatus := LLM_Menu_BindNavHotkeys(DistinctMenu,
		_LHCC_NavHotkey, _LHCC_NavHotIf, _LNHT_Log, _LHCC_NavReset,
		_LHCC_UsPhysicalKey)
	AssertTrue((DistinctStatus is Integer) && DistinctStatus == 1,
		"stored owners must not create a cross-layout false collision")
	AssertTrue(_LHCC_NavHotkeyCalls > 0)

	; A cleanup owner is just as live as the primary trigger. Moving its handle
	; into recovery must preserve the FR registration identity across the US
	; decision instead of deriving it again from the human chord label.
	_LTST_Reset()
	_LHCC_InstallReservedMenuState()
	AssertTrue(LLM_Menu_ApplyTriggerShortcut("Alt+(", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, 0, 0, _LTST_Notify,
		_LHCC_FrenchPhysicalKey))
	RecoveryHandle := _LLM_Menu_TriggerHandle
	_LLM_Menu_PublishTriggerRuntime("", "", "",
		LLM_TRIGGER_STATUS_CLEANUP_PENDING, [RecoveryHandle])
	_LNHT_Reset()
	_LHCC_ResetNavBoundaryCounters()
	RecoveryStatus := LLM_Menu_BindNavHotkeys(CandidateMenu,
		_LHCC_NavHotkey, _LHCC_NavHotIf, _LNHT_Log, _LHCC_NavReset,
		_LHCC_UsPhysicalKey)
	AssertTrue((RecoveryStatus is Integer) && RecoveryStatus == 0,
		"retained cleanup handles must keep their registration-layout owner")
	AssertEqual(0, _LHCC_NavHotkeyCalls)
	AssertEqual(0, _LHCC_NavHotIfCalls)

	; Trigger replay precedes the profile binder at boot. If the layout changes
	; between them, the profile plan must perform the symmetric reverse check
	; before opening its HotIf context or registering even one digit.
	_LTST_Reset()
	_LHCC_InstallReservedMenuState()
	AssertTrue(LLM_Menu_ApplyTriggerShortcut("Ctrl+Shift+(", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, 0, 0, _LTST_Notify,
		_LHCC_UsPhysicalKey))
	ProfileTriggerHandle := _LLM_Menu_TriggerHandle
	AssertEqual(_LLM_Menu_HotkeyPhysicalIdentity("^9",
		_LHCC_FrenchPhysicalKey),
		HotkeyRegistrarPhysicalIdentityOf(ProfileTriggerHandle))
	AssertFalse(_LLM_Menu_HotkeyPhysicalIdentity("^9",
		_LHCC_UsPhysicalKey)
		== HotkeyRegistrarPhysicalIdentityOf(ProfileTriggerHandle))
	_LPHT_ResetPorts()
	ReverseProfileStatus := LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
		_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset, _LPHT_Select,
		_LHCC_FrenchPhysicalKey)
	AssertTrue((ReverseProfileStatus is Integer) && ReverseProfileStatus == 0)
	AssertEqual(0, _LPHT_HotkeyCalls)
	AssertEqual(0, _LPHT_OpenCalls)
	AssertEqual(0, _LPHT_CloseCalls)
	AssertEqual(0, _LPHT_ResetCalls)
	AssertFalse(_LLM_Menu_ProfileHotkeyOwner is Map)
	ProfileTriggerDescriptor := _LLM_Menu_HotkeyResolvedDescriptor("^+(",
		_LHCC_UsPhysicalKey)
	AssertTrue(ProfileTriggerDescriptor is Map)
	AssertTrue(_LTST_Native[ProfileTriggerDescriptor["native_spec"]].enabled)

	; Under the trigger's original US layout the profile ^9 is distinct, so the
	; reverse guard must not degrade into a blanket cross-layout refusal.
	_LPHT_ResetPorts()
	DistinctProfileStatus := LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
		_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset, _LPHT_Select,
		_LHCC_UsPhysicalKey)
	AssertTrue((DistinctProfileStatus is Integer)
		&& DistinctProfileStatus == 1)
	AssertTrue(_LLM_Menu_ProfileHotkeyOwnerReady())

	; Finally exercise the published navigation branch in the forward direction:
	; the FR !5 generation owns Alt+Shift+VK35 even after trigger admission moves
	; to US, where rebuilding the same textual menu would lose that Shift bit.
	_LTST_Reset()
	_LHCC_InstallReservedMenuState()
	_LLM_Menu["val_modifiers"] := "alt"
	_LNHT_Reset()
	_LHCC_ResetNavBoundaryCounters()
	PublishedNavStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu,
		_LHCC_NavHotkey, _LHCC_NavHotIf, _LNHT_Log, _LHCC_NavReset,
		_LHCC_FrenchPhysicalKey)
	AssertTrue((PublishedNavStatus is Integer) && PublishedNavStatus == 1)
	PublishedNavPlan := _LLM_Menu_NavHotkeysBound
	PublishedFive := false
	for Entry in PublishedNavPlan {
		if Entry.Get("spec", "") == "!5" {
			PublishedFive := Entry
			break
		}
	}
	AssertTrue(PublishedFive is Map)
	AssertEqual("!+vk35", PublishedFive["native_spec"])
	AssertEqual("!+vk35", PublishedFive["native_id"])
	AssertEqual("!+vk0035", PublishedFive["physical_id"])
	AssertTrue(_LNHT_Hotkeys.Has(_LLM_Menu_NavActiveSlot . "|!+vk35"))
	AssertFalse(_LNHT_Hotkeys.Has(_LLM_Menu_NavActiveSlot . "|!5"),
		"navigation Hotkey() must receive only the frozen explicit VK spec")
	_LTST_SeedOld()
	PublishedNavTriggerStatus := _LTST_Commit("Alt+Shift+5", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		0, 0, _LHCC_UsPhysicalKey)
	AssertTrue((PublishedNavTriggerStatus is Integer)
		&& PublishedNavTriggerStatus == 0)
	AssertEqual(0, _LTST_WriteCalls)
	AssertTrue(_LLM_Menu_NavHotkeysBound == PublishedNavPlan)
	AssertFalse(_LTST_NativeHas("!+5", _LHCC_UsPhysicalKey))
}

_LHCC_RegisteredOwnersKeepBindingLayout() {
	return _LHCC_WithTriggerState(
		_LHCC_RegisteredOwnersKeepBindingLayoutCore)
}
Test("[llm-hotkey-collision] native owners retain their registration layout",
	_LHCC_RegisteredOwnersKeepBindingLayout)

_LHCC_ResolvedDescriptorsFreezeNativeOwnersCore() {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global HOTKEY_REGISTRAR_NEXT_TOKEN
	global _LTST_Native, _LTST_Events, _LTST_CriticalStates
	global _LHCC_FrozenReserveFailure
	_LTST_Reset()
	Five := HotkeyRegistrarResolvedNativeDescriptor("^5",
		_LHCC_FrenchPhysicalKey)
	AssertTrue(Five is Map)
	AssertTrue(HotkeyRegistrarResolvedDescriptorIsValid(Five))
	AssertEqual("^5", Five["logical_spec"])
	AssertEqual("^+vk35", Five["native_spec"])
	AssertEqual("^+vk0035", Five["identity"])
	AssertEqual("character", Five["kind"])
	AssertEqual("vk", Five["axis"])
	AssertEqual(0x35, Five["code"])
	AssertEqual("+", Five["implicit_modifiers"])
	AssertTrue(HasMethod(Five["resolver"], "Call"))

	Alias := HotkeyRegistrarResolvedNativeDescriptor("^+(",
		_LHCC_FrenchPhysicalKey)
	AssertTrue(HotkeyRegistrarResolvedDescriptorIsValid(Alias))
	AssertEqual("^+(", Alias["logical_spec"])
	AssertEqual("^+vk35", Alias["native_spec"])
	AssertEqual("^+vk0035", Alias["identity"])

	Letter := HotkeyRegistrarResolvedNativeDescriptor("^L",
		_LHCC_DescriptorPhysicalKey)
	AssertTrue(HotkeyRegistrarResolvedDescriptorIsValid(Letter))
	AssertEqual("^l", Letter["logical_spec"])
	AssertEqual("^vk4C", Letter["native_spec"],
		"VK hex letters must retain the descriptor's canonical uppercase form")
	AssertEqual("^vk004C", Letter["identity"])

	Enter := HotkeyRegistrarResolvedNativeDescriptor("^Enter",
		_LHCC_DescriptorPhysicalKey)
	NumpadEnter := HotkeyRegistrarResolvedNativeDescriptor("^NumpadEnter",
		_LHCC_DescriptorPhysicalKey)
	AssertTrue(HotkeyRegistrarResolvedDescriptorIsValid(Enter))
	AssertTrue(HotkeyRegistrarResolvedDescriptorIsValid(NumpadEnter))
	AssertEqual("^enter", Enter["native_spec"],
		"named Enter must preserve AHK's specified-by-name semantics")
	AssertEqual("^vk000D", Enter["identity"])
	AssertEqual("^numpadenter", NumpadEnter["native_spec"])
	AssertEqual("^sc011C", NumpadEnter["identity"])
	AssertFalse(Enter["identity"] == NumpadEnter["identity"])

	BoundarySc := (*) => Map("axis", "sc", "code", 0x1FF,
		"implicit_modifiers", "")
	TooLargeSc := (*) => Map("axis", "sc", "code", 0x200,
		"implicit_modifiers", "")
	AssertTrue(HotkeyRegistrarResolvedDescriptorIsValid(
		HotkeyRegistrarResolvedNativeDescriptor("Up", BoundarySc)))
	AssertFalse(HotkeyRegistrarResolvedNativeDescriptor("Up", TooLargeSc))
	CharacterSc := (*) => Map("axis", "sc", "code", 0x006,
		"implicit_modifiers", "")
	AssertFalse(HotkeyRegistrarResolvedNativeDescriptor("5", CharacterSc),
		"AHK resolves character suffixes through VK, never SC")
	InvalidImplicitResolvers := [
		(*) => Map("axis", "vk", "code", 0x35,
			"implicit_modifiers", "#"),
		(*) => Map("axis", "vk", "code", 0x35,
			"implicit_modifiers", "^!"),
		(*) => Map("axis", "vk", "code", 0x35,
			"implicit_modifiers", "^^"),
		(*) => Map("axis", "vk", "code", 0x35,
			"implicit_modifiers", "+^")
	]
	for Resolver in InvalidImplicitResolvers {
		AssertFalse(HotkeyRegistrarResolvedNativeDescriptor("5", Resolver),
			"VkKeyScanEx cannot synthesize an impossible implicit modifier set")
	}

	_LTST_Events := []
	TokenBefore := HOTKEY_REGISTRAR_NEXT_TOKEN
	FrozenFive := Five.Clone()
	Handle := _HotkeyRegistrarReserveResolvedOwned("Ctrl+5",
		_LTST_LlmCallback, "llm:trigger", Five, _LTST_Hotkey, _LTST_Probe)
	AssertTrue(Handle != "")
	AssertEqual(TokenBefore + 1, HOTKEY_REGISTRAR_NEXT_TOKEN)
	AssertTrue(HOTKEY_REGISTRAR_BINDINGS.Has(Handle))
	Entry := HOTKEY_REGISTRAR_BINDINGS[Handle]
	AssertEqual("^5", Entry["display_spec"])
	AssertEqual("^+vk35", Entry["spec"])
	AssertEqual("^+vk0035", Entry["physical_identity"])
	AssertFalse(Entry.Has("resolver"),
		"published registrar owners must retain only immutable descriptor scalars")
	AssertTrue(_LTST_Native.Has("^+vk35"))
	AssertFalse(_LTST_Native.Has("^5"))
	Five["logical_spec"] := "^6"
	Five["native_spec"] := "^vk36"
	Five["identity"] := "^vk0036"
	Five["code"] := 0x36
	Five["implicit_modifiers"] := ""
	AssertTrue(_HotkeyRegistrarActivate(Handle, _LTST_Hotkey))
	AssertTrue(_HotkeyRegistrarSetEnabled(Handle, false, _LTST_Hotkey))
	AssertTrue(_HotkeyRegistrarSetEnabled(Handle, true, _LTST_Hotkey))
	AssertTrue(_HotkeyRegistrarRetire(Handle, _LTST_Hotkey))
	_LTST_AssertEvents(["^+vk35 Off", "^+vk35 On", "^+vk35 Off",
		"^+vk35 On", "^+vk35 Off"],
		"every native lifecycle phase must ignore mutations of the input descriptor")
	Five := FrozenFive

	Tombstone := HOTKEY_REGISTRAR_SPECS["^+vk35"]
	_LTST_Events := []
	_LTST_CriticalStates := []
	AliasHandle := _HotkeyRegistrarReserveResolvedOwned("Ctrl+Shift+(",
		_LTST_LlmCallback, "llm:trigger:alias", Alias,
		_LTST_Hotkey, _LTST_Probe)
	AssertTrue(AliasHandle != "")
	AssertEqual(1, _LHCC_PhaseCount("probe"),
		"an exact frozen tombstone must still probe the alias display spelling "
		. "because a raw producer can own that textual variant")
	AssertEqual("^+vk35", HOTKEY_REGISTRAR_BINDINGS[AliasHandle]["spec"])
	AssertTrue(_HotkeyRegistrarAbort(AliasHandle))

	Tombstone := HOTKEY_REGISTRAR_SPECS["^+vk35"]
	_LHCC_FrozenReserveFailure := true
	Refused := _HotkeyRegistrarReserveResolvedOwned("Ctrl+Shift+(",
		_LTST_LlmCallback, "llm:trigger:refused", Alias,
		_LHCC_FailFrozenReserve, _LTST_Probe)
	AssertEqual("", Refused)
	AssertTrue(HOTKEY_REGISTRAR_SPECS["^+vk35"] == Tombstone,
		"reserve-Off refusal must restore the exact prior tombstone object")
	_LHCC_FrozenReserveFailure := false

	BadOrder := Five.Clone()
	BadOrder["native_spec"] := "+^vk35"
	BadCase := Letter.Clone()
	BadCase["native_spec"] := "^vk4c"
	BadCoherent := Five.Clone()
	BadCoherent["identity"] := "^+vk0036"
	BadCoherent["native_spec"] := "^+vk36"
	BadCoherent["code"] := 0x36
	BadResolver := Five.Clone()
	BadResolver.Delete("resolver")
	BadImplicit := Five.Clone()
	BadImplicit["implicit_modifiers"] := "#"
	InvalidDescriptors := [
		Map("name", "zero", "value", 0),
		Map("name", "empty", "value", Map()),
		Map("name", "modifier order", "value", BadOrder),
		Map("name", "VK case", "value", BadCase),
		Map("name", "coherent wrong key", "value", BadCoherent),
		Map("name", "missing resolver", "value", BadResolver),
		Map("name", "implicit Win", "value", BadImplicit)
	]
	for Vector in InvalidDescriptors {
		AssertFalse(HotkeyRegistrarResolvedDescriptorIsValid(Vector["value"]),
			"descriptor mutation must fail closed: " . Vector["name"])
	}
	TokenBefore := HOTKEY_REGISTRAR_NEXT_TOKEN
	NativeCountBefore := _LTST_Native.Count
	_LTST_Events := []
	_LTST_CriticalStates := []
	for Vector in InvalidDescriptors {
		AssertEqual("", _HotkeyRegistrarReserveResolvedOwned("Ctrl+5",
			_LTST_LlmCallback, "llm:trigger:invalid", Vector["value"],
			_LTST_Hotkey, _LTST_Probe))
	}
	AssertEqual(TokenBefore, HOTKEY_REGISTRAR_NEXT_TOKEN)
	AssertEqual(NativeCountBefore, _LTST_Native.Count)
	AssertEqual(0, _LTST_Events.Length)
	AssertEqual(0, _LHCC_PhaseCount("probe"),
		"invalid descriptors must fail before claim, probe, or native mutation")
	return true
}

_LHCC_ResolvedDescriptorsFreezeNativeOwners() {
	Result := _LHCC_WithTriggerState(
		_LHCC_ResolvedDescriptorsFreezeNativeOwnersCore)
	AssertTrue((Result is Integer) && Result == 1,
		"the immutable descriptor fixture must reach every terminal assertion")
}
Test("[llm-hotkey-collision] resolved descriptors freeze every native lifecycle phase",
	_LHCC_ResolvedDescriptorsFreezeNativeOwners)

_LHCC_DuplicatePlanOwnersFailBeforeNativeMutationCore() {
	global _LLM_Menu_ProfileHotkeyOwner
	global _LPHT_HotkeyCalls, _LPHT_OpenCalls, _LPHT_CloseCalls
	global _LPHT_ResetCalls, _LPHT_LogCalls
	global _LNHT_LogCalls, _LNHT_Events
	global _LHCC_NavHotkeyCalls, _LHCC_NavHotIfCalls
	global _LHCC_NavResetCalls
	_LHCC_InstallReservedMenuState()
	_LPHT_ResetPorts()
	ProfileStatus := LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
		_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset, _LPHT_Select,
		_LHCC_ProfileDuplicatePhysicalKey)
	AssertTrue((ProfileStatus is Integer) && ProfileStatus == 0)
	AssertEqual(0, _LPHT_HotkeyCalls)
	AssertEqual(0, _LPHT_OpenCalls)
	AssertEqual(0, _LPHT_CloseCalls)
	AssertEqual(0, _LPHT_ResetCalls)
	AssertEqual(0, _LPHT_LogCalls)
	AssertFalse(_LLM_Menu_ProfileHotkeyOwner is Map)

	RawPlan := [Map("spec", "^1"), Map("spec", "^2")]
	AssertFalse(_LLM_Menu_AttachPlanPhysicalIdentities(RawPlan,
		_LHCC_ProfileDuplicatePhysicalKey))
	AssertFalse(RawPlan[1].Has("physical_id")
		|| RawPlan[2].Has("physical_id"),
		"duplicate admission must not partially enrich the caller's plan")

	_LNHT_Reset()
	_LHCC_ResetNavBoundaryCounters()
	_LNHT_LogCalls := 0
	CandidateMenu := Map("nav_modifiers", "alt", "val_modifiers", "shift")
	NavStatus := LLM_Menu_BindNavHotkeys(CandidateMenu,
		_LHCC_NavHotkey, _LHCC_NavHotIf, _LNHT_Log, _LHCC_NavReset,
		_LHCC_NavDuplicatePhysicalKey)
	AssertTrue((NavStatus is Integer) && NavStatus == 0)
	AssertEqual(0, _LHCC_NavHotkeyCalls)
	AssertEqual(0, _LHCC_NavHotIfCalls)
	AssertEqual(0, _LHCC_NavResetCalls)
	AssertEqual(0, _LNHT_Events.Length)
	AssertEqual(1, _LNHT_LogCalls)

	ValidPlan := _LLM_Menu_BuildProfileHotkeyPlan(_LPHT_Select,
		_LHCC_UsPhysicalKey)
	AssertTrue(ValidPlan is Array)
	PoisonedPlan := []
	for Entry in ValidPlan
		PoisonedPlan.Push(Entry.Clone())
	PoisonedPlan[2]["physical_id"] := PoisonedPlan[1]["physical_id"]
	PoisonedPlan[2]["native_spec"] := PoisonedPlan[1]["native_spec"]
	PoisonedPlan[2]["native_id"] := PoisonedPlan[1]["native_id"]
	_LLM_Menu_ProfileHotkeyOwner := Map("ready", true,
		"degraded", false, "plan", PoisonedPlan)
	AssertFalse(_LLM_Menu_ProfileHotkeyOwnerReady(),
		"a published owner with duplicated native identity must fail closed")

	ProfileFive := ValidPlan[5]
	AssertEqual("^vk35", ProfileFive["native_spec"])
	AssertEqual("^vk0035", ProfileFive["physical_id"])
	MismatchedProfilePlan := []
	for Entry in ValidPlan
		MismatchedProfilePlan.Push(Entry.Clone())
	MismatchedProfilePlan[5]["physical_id"] := "^vk0078"
	AssertTrue(_LLM_Menu_HotkeyPhysicalIdentityIsValid(
		MismatchedProfilePlan[5]["physical_id"]),
		"the profile poison must remain syntactically valid")
	_LLM_Menu_ProfileHotkeyOwner := Map("ready", true,
		"degraded", false, "plan", MismatchedProfilePlan)
	AssertFalse(_LLM_Menu_ProfileHotkeyOwnerReady(),
		"profile physical identity must match its frozen descriptor")
	NativeMismatchedProfilePlan := []
	for Entry in ValidPlan
		NativeMismatchedProfilePlan.Push(Entry.Clone())
	NativeMismatchedProfilePlan[5]["native_spec"] := "^vk41"
	NativeMismatchedProfilePlan[5]["native_id"] := "^vk41"
	_LLM_Menu_ProfileHotkeyOwner := Map("ready", true,
		"degraded", false, "plan", NativeMismatchedProfilePlan)
	AssertFalse(_LLM_Menu_ProfileHotkeyOwnerReady(),
		"profile native spec must match its frozen descriptor")

	NavMenu := Map("nav_modifiers", "alt", "val_modifiers", "alt")
	BuiltNav := _LLM_Menu_BuildNavBindingPlan(NavMenu)
	AssertTrue(BuiltNav is Map)
	NavPlan := BuiltNav["plan"]
	AssertTrue(_LLM_Menu_AttachPlanPhysicalIdentities(NavPlan,
		_LHCC_UsPhysicalKey))
	AssertEqual("!vk37", NavPlan[9]["native_spec"])
	AssertEqual("!vk0037", NavPlan[9]["physical_id"])
	NativeMismatchedNavPlan := []
	for Entry in NavPlan
		NativeMismatchedNavPlan.Push(Entry.Clone())
	NativeMismatchedNavPlan[9]["native_spec"] := "!vk41"
	NativeMismatchedNavPlan[9]["native_id"] := "!vk41"
	AssertFalse(_LLM_Menu_NavPlanIsValid(NativeMismatchedNavPlan, NavMenu),
		"navigation native spec must match its frozen descriptor")
	NavPlan[9]["physical_id"] := "!vk0078"
	AssertTrue(_LLM_Menu_HotkeyPhysicalIdentityIsValid(
		NavPlan[9]["physical_id"]),
		"the navigation poison must remain syntactically valid")
	AssertFalse(_LLM_Menu_NavPlanIsValid(NavPlan, NavMenu),
		"navigation physical identity must match its frozen descriptor")
	return true
}

_LHCC_DuplicatePlanOwnersFailBeforeNativeMutation() {
	Result := _LHCC_WithTriggerState(
		_LHCC_DuplicatePlanOwnersFailBeforeNativeMutationCore)
	AssertTrue((Result is Integer) && Result == 1,
		"the duplicate-plan fixture must reach every terminal assertion")
}
Test("[llm-hotkey-collision] duplicate contextual owners fail before native mutation",
	_LHCC_DuplicatePlanOwnersFailBeforeNativeMutation)

_LHCC_NavCleanupKeepsRegistrationLayoutCore() {
	global _LLM_Menu, _LLM_Menu_NavActiveSlot, _LLM_Menu_NavSlotPlans
	global _LNHT_Hotkeys, _LNHT_Events, _LNHT_FailSpec
	global _LNHT_FailAfterApply
	_LHCC_InstallReservedMenuState()
	_LNHT_Reset()
	_LLM_Menu["nav_modifiers"] := "alt"
	_LLM_Menu["val_modifiers"] := "ctrl"
	FrenchStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset,
		_LHCC_FrenchPhysicalKey)
	AssertTrue((FrenchStatus is Integer) && FrenchStatus == 1)
	AssertEqual(1, _LLM_Menu_NavActiveSlot)
	AssertTrue(_LNHT_Hotkeys.Has("1|^+vk35"))
	AssertFalse(_LNHT_Hotkeys.Has("1|^5"))
	FrenchPlan := _LLM_Menu_NavSlotPlans[1]

	UsStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset,
		_LHCC_UsPhysicalKey)
	AssertTrue((UsStatus is Integer) && UsStatus == 1)
	AssertEqual(2, _LLM_Menu_NavActiveSlot)
	AssertTrue(_LNHT_Hotkeys.Has("2|^vk35"))

	_LNHT_Events := []
	_LNHT_FailSpec := "^vk35"
	_LNHT_FailAfterApply := true
	RollbackStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset,
		_LHCC_UsPhysicalKey)
	AssertTrue((RollbackStatus is Integer) && RollbackStatus == 0)
	AssertTrue(_LLM_Menu_NavSlotPlans[1] == FrenchPlan)
	AssertTrue(_LNHT_Hotkeys.Has("1|^+vk35"))
	AssertFalse(_LNHT_Hotkeys.Has("1|^vk35"))
	AssertEqual(1, _LHCC_EventCount(_LNHT_Events, "1|^vk35 On"))
	AssertEqual(1, _LHCC_EventCount(_LNHT_Events, "1|^vk35 Off"))
	AssertEqual(1, _LHCC_EventCount(_LNHT_Events, "1|^+vk35 On"))

	_LNHT_Events := []
	_LNHT_FailSpec := ""
	_LNHT_FailAfterApply := false
	RecycleStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset,
		_LHCC_UsPhysicalKey)
	AssertTrue((RecycleStatus is Integer) && RecycleStatus == 1)
	AssertEqual(1, _LLM_Menu_NavActiveSlot)
	AssertFalse(_LNHT_Hotkeys.Has("1|^+vk35"))
	AssertTrue(_LNHT_Hotkeys.Has("1|^vk35"))
	AssertEqual(1, _LHCC_EventCount(_LNHT_Events, "1|^+vk35 Off"),
		"slot recycling must retire the exact prior-layout native variant")
	AssertEqual(1, _LHCC_EventCount(_LNHT_Events, "1|^vk35 On"))
	return true
}

_LHCC_NavCleanupKeepsRegistrationLayoutFixture() {
	return _LNHT_WithFixture(_LHCC_NavCleanupKeepsRegistrationLayoutCore)
}

_LHCC_NavCleanupKeepsRegistrationLayout() {
	Result := _LHCC_WithTriggerState(
		_LHCC_NavCleanupKeepsRegistrationLayoutFixture)
	AssertTrue((Result is Integer) && Result == 1,
		"the cross-layout cleanup fixture must reach every rollback assertion")
}
Test("[llm-hotkey-collision] nav cleanup reuses exact registration-layout specs",
	_LHCC_NavCleanupKeepsRegistrationLayout)

_LHCC_CrossLayoutProfileNavPriorityCore() {
	global _LLM_Menu, _LLM_Menu_Loaded, _LLM_PROFILE_HOTKEY_PRED
	global _LLM_Menu_NavActiveSlot, _LHCC_CrossLayoutPriorityCompleted
	_LHCC_CrossLayoutPriorityCompleted := false
	_LLM_Menu["trigger_shortcut"] := ""
	_LLM_Menu["nav_modifiers"] := "alt"
	_LLM_Menu["val_modifiers"] := "ctrl+shift"
	_LLM_Menu_Loaded := true
	ProfileStatus := LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
		_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset, _LPHT_Select,
		_LHCC_FrenchPhysicalKey)
	AssertTrue((ProfileStatus is Integer) && ProfileStatus == 1)
	NavStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset,
		_LHCC_UsPhysicalKey)
	AssertTrue((NavStatus is Integer) && NavStatus == 1)
	_LNHT_ShowTooltip(["one", "two", "three", "four", "five"])
	PermanentName := "+^VK35"
	AssertTrue(LLM_Menu_NavOwnsSpec(PermanentName))
	AssertTrue(_LLM_Menu_NavSlotPredicate(
		_LLM_Menu_NavActiveSlot).Call(PermanentName))
	AssertFalse(_LLM_PROFILE_HOTKEY_PRED.Call(PermanentName),
		"the profile owner must yield only to the exact physical nav variant")
	_LNHT_HideTooltip()
	try HiddenOwns := LLM_Menu_NavOwnsSpec(PermanentName)
	catch as Err {
		throw Error("hidden nav ownership raised: " . Err.Message, -1,
			Err.Extra)
	}
	AssertFalse(HiddenOwns)
	AssertTrue(_LLM_PROFILE_HOTKEY_PRED.Call(PermanentName))

	_LLM_Menu["val_modifiers"] := "ctrl"
	DistinctNavStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset,
		_LHCC_UsPhysicalKey)
	AssertTrue((DistinctNavStatus is Integer) && DistinctNavStatus == 1)
	_LNHT_ShowTooltip(["one", "two", "three", "four", "five"])
	AssertFalse(LLM_Menu_NavOwnsSpec(PermanentName))
	AssertTrue(_LLM_PROFILE_HOTKEY_PRED.Call(PermanentName),
		"a physically distinct US nav digit must not disable the FR profile")
	_LHCC_CrossLayoutPriorityCompleted := true
	return true
}

_LHCC_CrossLayoutProfileNavPriorityNavFixture() {
	return _LNHT_WithFixture(_LHCC_CrossLayoutProfileNavPriorityCore)
}

_LHCC_CrossLayoutProfileNavPriorityProfileFixture() {
	return _LPHT_WithFixture(_LHCC_CrossLayoutProfileNavPriorityNavFixture)
}

_LHCC_CrossLayoutProfileNavPriority() {
	global _LHCC_CrossLayoutPriorityCompleted
	Result := _LTST_WithFixture(
		_LHCC_CrossLayoutProfileNavPriorityProfileFixture)
	AssertTrue(_LHCC_CrossLayoutPriorityCompleted,
		"the cross-layout priority fixture must reach exact predicate routing")
	return Result
}
Test("[llm-hotkey-collision] profile and nav arbitrate one physical native owner",
	_LHCC_CrossLayoutProfileNavPriority)

_LHCC_CanonicalIdentities() {
	AssertEqual("!7", LLM_Menu_ShortcutToAhk("ALT+7"))
	AssertEqual("^+7", LLM_Menu_ShortcutToAhk("CONTROL+SHIFT+7"))
	AssertEqual("^up", LLM_Menu_ShortcutToAhk("CONTROL+UP"))
	AssertEqual("^5", LLM_Menu_ShortcutToAhk("CONTROL+5"))
	AssertEqual("^l", LLM_Menu_ShortcutToAhk("CONTROL+L"))
	AssertEqual("tab", LLM_Menu_ShortcutToAhk("TAB"))
	AssertEqual("^+7", _LLM_Menu_NavNativeIdentity("~+^7"))
	AssertEqual("^up", _LLM_Menu_NavNativeIdentity("~^Up"))
	AssertFalse(_LLM_Menu_NavNativeIdentity("^0")
		== _LLM_Menu_NavNativeIdentity("^5"))
	AssertFalse(_LLM_Menu_NavNativeIdentity("^tab")
		== _LLM_Menu_NavNativeIdentity("tab"))
	PointerKeys := ["LButton", "RButton", "MButton", "XButton1", "XButton2",
		"WheelUp", "WheelDown", "WheelLeft", "WheelRight"]
	ModifierPrefixes := ["", "Ctrl+", "Alt+", "Shift+", "Cmd+",
		"Ctrl+Alt+", "Ctrl+Shift+", "Ctrl+Cmd+", "Alt+Shift+",
		"Alt+Cmd+", "Shift+Cmd+", "Ctrl+Alt+Shift+", "Ctrl+Alt+Cmd+",
		"Ctrl+Shift+Cmd+", "Alt+Shift+Cmd+", "Ctrl+Alt+Shift+Cmd+"]
	for Key in PointerKeys {
		for Prefix in ModifierPrefixes {
			AssertEqual("", LLM_Menu_ShortcutToAhk(Prefix . Key),
				"pointer observers must retain every modifier surface: "
				. Prefix . Key)
		}
	}
	AssertEqual("^up", LLM_Menu_ShortcutToAhk("Ctrl+Up"))
	AssertEqual("^f13", LLM_Menu_ShortcutToAhk("Ctrl+F13"))
	for RawText in [
		"VK09", "SC00F", "VK09SC00F",
		"Ctrl+VK35", "Ctrl+SC006", "Ctrl+VK35SC006",
		"Alt+VK37", "Alt+SC008", "Alt+VK37SC008",
		"Alt+VK26", "Alt+SC148", "Alt+VK26SC148",
		"*Tab", "Ctrl+*5", "Alt+*7", "Alt+*Up", "Ctrl+5 Up",
		"LButton", "RButton", "MButton", "XButton1", "XButton2",
		"WheelUp", "WheelDown", "WheelLeft", "WheelRight",
		"Ctrl+LButton", "Alt+XButton2", "Shift+WheelUp",
		"LCtrl", "LControl", "RCtrl", "RControl", "LAlt", "RAlt",
		"LShift", "RShift", "LWin", "RWin"
	] {
		AssertEqual("", LLM_Menu_ShortcutToAhk(RawText),
			"LLM trigger grammar must reject native AHK syntax " . RawText)
	}
}
Test("[llm-hotkey-collision] policy compares canonical native identities",
	_LHCC_CanonicalIdentities)
