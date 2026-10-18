; tests/unit/modules/llm/navigation/test_llm_nav_hotkey_native_transaction.ahk

; ==============================================================================
; MODULE: LLM Navigation Hotkey Native Transaction
; DESCRIPTION:
; A navigation hotkey change commits its native registration with the
; durable write: a native failure restores the complete old generation and
; the new one is published once.
; ==============================================================================

#Requires AutoHotkey v2.0





_LNHT_NativeFailureCore() {
	global _LNHT_FailSpec, _LNHT_LogCalls, _LLM_Menu_NavHotkeysBound
	global _LNHT_HotIfDepth, _LNHT_LogCritical
	global _LNHT_TransactionWriterCalls, _LNHT_TransactionApplyCalls
	global _LLM_Menu
	AssertTrue(LLM_Menu_BindNavHotkeys(_LLM_Menu,
		_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log))
	OldPlan := _LLM_Menu_NavHotkeysBound
	_LNHT_FailSpec := "^7"
	PriorCritical := Critical("On")
	try AssertFalse(LLM_Menu_CommitNavModifier("val_modifiers", "ctrl",
		0, 0, _LNHT_Reject, _LNHT_TransactionPort()))
	finally Critical(PriorCritical)
	AssertEqual(0, _LNHT_TransactionWriterCalls,
		"native admission must complete before durable config I/O")
	AssertEqual(0, _LNHT_TransactionApplyCalls)
	AssertEqual("alt", _LLM_Menu["val_modifiers"],
		"a refused native generation must not publish candidate RAM")
	AssertTrue(_LLM_Menu_NavHotkeysBound == OldPlan,
		"a refused native generation must not publish candidate ownership")
	_LNHT_AssertOnlyPrefix("!")
	AssertTrue(_LNHT_LogCalls >= 1,
		"the native refusal must leave developer-visible evidence")
	AssertEqual(0, _LNHT_LogCritical,
		"native failure logging must run outside inherited Critical")
	AssertEqual(0, _LNHT_HotIfDepth,
		"the dynamic HotIf context must be closed after a refusal")
}

_LNHT_NativeFailure() {
	return _LNHT_WithPersistenceFixture(_LNHT_NativeFailureCore)
}

Test("[llm-nav-transaction] native failure restores the complete old generation",
	_LNHT_NativeFailure)

_LNHT_PoisonedPreparedPlanCannotPublishCore() {
	global Features, _LLM_Menu, _LLM_Menu_NavHotkeysBound
	global _LLM_Menu_NavActiveSlot
	AssertTrue(LLM_Menu_BindNavHotkeys(_LLM_Menu,
		_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log))
	OldFeatures := Features
	OldMenu := _LLM_Menu
	OldPlan := _LLM_Menu_NavHotkeysBound
	OldSlot := _LLM_Menu_NavActiveSlot
	CandidateFeatures := Features.Clone()
	CandidateMenu := _LLM_Menu.Clone()
	CandidateMenu["val_modifiers"] := "ctrl"
	Owner := _LLM_Menu_PrepareNavBindingCandidate(CandidateMenu,
		_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log,
		_LNHT_ForceHotIfReset)
	AssertTrue(Owner is Map)
	AssertTrue(_LLM_Menu_NavPlanIsValid(Owner["plan"], CandidateMenu))
	Owner["plan"][9]["jump_idx"] := "7"
	AssertFalse(_LLM_Menu_NavPlanIsValid(Owner["plan"], CandidateMenu),
		"a numerically coercible jump index must poison the candidate owner")
	AssertFalse(_LLM_Menu_PublishPreparedNavCandidate(CandidateFeatures,
		CandidateMenu, Owner))
	AssertTrue(Features == OldFeatures)
	AssertTrue(_LLM_Menu == OldMenu)
	AssertTrue(_LLM_Menu_NavHotkeysBound == OldPlan)
	AssertEqual(OldSlot, _LLM_Menu_NavActiveSlot,
		"a poisoned inactive plan must never acquire the active slot")
}

_LNHT_PoisonedPreparedPlanCannotPublish() {
	return _LNHT_WithPersistenceFixture(
		_LNHT_PoisonedPreparedPlanCannotPublishCore)
}

Test("[llm-nav-transaction] poisoned prepared owner cannot publish",
	_LNHT_PoisonedPreparedPlanCannotPublish)

_LNHT_HotIfCloseRetryCore() {
	global _LNHT_FailHotIfClose, _LNHT_HotIfDepth
	_LNHT_FailHotIfClose := 1
	AssertTrue(LLM_Menu_BindNavHotkeys(_LNHT_Menu("alt", "alt"),
		_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log))
	AssertEqual(0, _LNHT_HotIfDepth,
		"a transient HotIf close failure must be retried before success")
	_LNHT_AssertOnlyPrefix("!")
}

_LNHT_HotIfCloseRetry() {
	return _LNHT_WithFixture(_LNHT_HotIfCloseRetryCore)
}

Test("[llm-nav-transaction] transient HotIf close failure is recovered",
	_LNHT_HotIfCloseRetry)

_LNHT_HotIfForceResetCore() {
	global _LNHT_FailHotIfClose, _LNHT_HotIfDepth
	_LNHT_FailHotIfClose := 2
	AssertTrue(LLM_Menu_BindNavHotkeys(_LNHT_Menu("alt", "alt"),
		_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log,
		_LNHT_ForceHotIfReset))
	AssertEqual(0, _LNHT_HotIfDepth,
		"the force-reset seam must prove that no HotIf context remains selected")
	_LNHT_AssertOnlyPrefix("!")
}

_LNHT_HotIfForceReset() {
	return _LNHT_WithFixture(_LNHT_HotIfForceResetCore)
}

Test("[llm-nav-transaction] repeated HotIf close refusal uses proven reset",
	_LNHT_HotIfForceReset)

_LNHT_HotIfPersistentFailureCore() {
	global _LNHT_FailHotIfClose, _LNHT_FailForceHotIfReset
	global _LNHT_HotIfDepth, _LNHT_LogCritical
	_LNHT_FailHotIfClose := 2
	_LNHT_FailForceHotIfReset := true
	Caught := false
	try LLM_Menu_BindNavHotkeys(_LNHT_Menu("alt", "alt"),
		_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log,
		_LNHT_ForceHotIfReset)
	catch as e {
		Caught := true
		AssertTrue(e is Error)
		AssertTrue(InStr(e.Message, "HotIf reset") > 0)
	}
	AssertTrue(Caught,
		"an unproven HotIf reset must never return normal control to the caller")
	AssertEqual(0, _LNHT_LogCritical,
		"the terminal reset diagnostic must run after Critical is restored")
	AssertEqual(1, _LNHT_HotIfDepth,
		"the fault seam must prove that the context really remained selected")
}

_LNHT_HotIfPersistentFailure() {
	return _LNHT_WithFixture(_LNHT_HotIfPersistentFailureCore)
}

Test("[llm-nav-transaction] unproven HotIf reset fails fast",
	_LNHT_HotIfPersistentFailure)

_LNHT_ProductionHotIfFailureCore() {
	global _LNHT_FailHotIfClose, _LNHT_FailForceHotIfReset
	global _LNHT_TransactionWriterCalls, _LNHT_TransactionApplyCalls
	global _LNHT_TransactionNotifyCalls, _LNHT_LogCritical, _LLM_Menu
	AssertTrue(LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset))
	_LNHT_FailHotIfClose := 2
	_LNHT_FailForceHotIfReset := true
	Caught := false
	try LLM_Menu_CommitNavModifier("val_modifiers", "ctrl",
		0, 0, _LNHT_Reject, _LNHT_TransactionPort())
	catch as e {
		Caught := true
		AssertTrue(InStr(e.Message, "HotIf reset") > 0)
	}
	AssertTrue(Caught,
		"the production transaction must not normalize a poisoned HotIf owner")
	AssertEqual(0, _LNHT_TransactionWriterCalls)
	AssertEqual(0, _LNHT_TransactionApplyCalls)
	AssertEqual(0, _LNHT_TransactionNotifyCalls,
		"ordinary notification must not run under an unowned HotIf criterion")
	AssertEqual("alt", _LLM_Menu["val_modifiers"])
	AssertEqual(0, _LNHT_LogCritical)
	AssertFalse(_ConfigWriteTerminalIsActive(),
		"fail-fast preparation must still release global terminal admission")
}

_LNHT_ProductionHotIfFailure() {
	return _LNHT_WithPersistenceFixture(_LNHT_ProductionHotIfFailureCore)
}

Test("[llm-nav-transaction] production commit propagates poisoned HotIf",
	_LNHT_ProductionHotIfFailure)

_LNHT_WriterFailureKeepsOldSurfaceCore() {
	global _LNHT_TransactionWriterResult, _LNHT_TransactionWriterCalls
	global _LNHT_TransactionApplyCalls, _LNHT_TransactionNotifyCalls
	global _LNHT_WriterSawOldMenu, _LNHT_WriterSawOldSurface
	global _LNHT_NotifySawOldSurface, _LLM_Menu
	AssertTrue(LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log))
	_LNHT_TransactionWriterResult := 0
	AssertFalse(LLM_Menu_CommitNavModifier("val_modifiers", "ctrl",
		0, 0, _LNHT_Reject, _LNHT_TransactionPort()))
	AssertEqual(1, _LNHT_TransactionWriterCalls)
	AssertEqual(0, _LNHT_TransactionApplyCalls)
	AssertTrue(_LNHT_WriterSawOldMenu)
	AssertTrue(_LNHT_WriterSawOldSurface,
		"the candidate slot must remain inert while the writer owns I/O")
	AssertTrue(_LNHT_NotifySawOldSurface,
		"error reporting must run while the old slot is still active")
	AssertTrue(_LNHT_TransactionNotifyCalls >= 1)
	AssertEqual("alt", _LLM_Menu["val_modifiers"])
	_LNHT_AssertSurface("!", "!")
}

_LNHT_WriterFailureKeepsOldSurface() {
	return _LNHT_WithPersistenceFixture(_LNHT_WriterFailureKeepsOldSurfaceCore)
}

Test("[llm-nav-transaction] failed durability never activates candidate keys",
	_LNHT_WriterFailureKeepsOldSurface)

_LNHT_WriterSuccessSwapsSurfaceCore() {
	global _LNHT_TransactionWriterCalls, _LNHT_TransactionApplyCalls
	global _LNHT_WriterSawOldMenu, _LNHT_WriterSawOldSurface, _LLM_Menu
	AssertTrue(LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log))
	AssertTrue(LLM_Menu_CommitNavModifier("val_modifiers", "ctrl",
		0, 0, _LNHT_Reject, _LNHT_TransactionPort()))
	AssertEqual(1, _LNHT_TransactionWriterCalls)
	AssertEqual(1, _LNHT_TransactionApplyCalls)
	AssertTrue(_LNHT_WriterSawOldMenu)
	AssertTrue(_LNHT_WriterSawOldSurface)
	AssertEqual("ctrl", _LLM_Menu["val_modifiers"])
	_LNHT_AssertSurface("!", "^")
}

_LNHT_WriterSuccessSwapsSurface() {
	return _LNHT_WithPersistenceFixture(_LNHT_WriterSuccessSwapsSurfaceCore)
}

Test("[llm-nav-transaction] durable publication swaps RAM and keys together",
	_LNHT_WriterSuccessSwapsSurface)

_LNHT_PostApplyFailureIsPurgedCore() {
	global _LNHT_FailSpec, _LNHT_FailAfterApply, _LNHT_FailOffSpec
	global _LNHT_Hotkeys, _LLM_Menu_NavActiveSlot
	AssertTrue(LLM_Menu_BindNavHotkeys(_LNHT_Menu("alt", "alt"),
		_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log,
		_LNHT_ForceHotIfReset))
	_LNHT_FailSpec := "^7"
	_LNHT_FailAfterApply := true
	_LNHT_FailOffSpec := "^7"
	AssertFalse(LLM_Menu_BindNavHotkeys(_LNHT_Menu("ctrl", "ctrl"),
		_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log,
		_LNHT_ForceHotIfReset))
	AssertEqual(1, _LLM_Menu_NavActiveSlot,
		"an unproven rollback must leave its entire candidate slot inactive")
	AssertTrue(_LNHT_Hotkeys.Has(_LNHT_OwnedSpec(2, "^7")),
		"the fault seam must retain the applied variant whose removal was refused")
	AssertTrue(LLM_Menu_BindNavHotkeys(_LNHT_Menu("shift", "shift"),
		_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log,
		_LNHT_ForceHotIfReset))
	_LNHT_AssertOnlyPrefix("+")
	AssertFalse(_LNHT_Hotkeys.Has(_LNHT_OwnedSpec(2, "^7")),
		"recycling the inactive slot must purge every conservative stale variant")
}

_LNHT_PostApplyFailureIsPurged() {
	return _LNHT_WithFixture(_LNHT_PostApplyFailureIsPurgedCore)
}

Test("[llm-nav-transaction] post-apply registration failure is fully purged",
	_LNHT_PostApplyFailureIsPurged)

global _LNHT_FirstRestoreProfileCalls := 0
global _LNHT_FirstRestoreNavCalls := 0
global _LNHT_FirstRestoreProfileResult := false
global _LNHT_FirstRestoreNavResult := false

_LNHT_FirstRestoreProfile() {
	global _LNHT_FirstRestoreProfileCalls, _LNHT_FirstRestoreProfileResult
	_LNHT_FirstRestoreProfileCalls += 1
	return _LNHT_FirstRestoreProfileResult
}

_LNHT_FirstRestoreNav() {
	global _LNHT_FirstRestoreNavCalls, _LNHT_FirstRestoreNavResult
	_LNHT_FirstRestoreNavCalls += 1
	return _LNHT_FirstRestoreNavResult
}

_LNHT_FirstRestoreOwnsBootBindingCore() {
	global _LNHT_FirstRestoreProfileCalls, _LNHT_FirstRestoreNavCalls
	global _LNHT_FirstRestoreProfileResult, _LNHT_FirstRestoreNavResult
	global _LLM_PROFILE_HOTKEY_STATUS_DEGRADED
	_LNHT_FirstRestoreProfileCalls := 0
	_LNHT_FirstRestoreNavCalls := 0
	_LNHT_FirstRestoreProfileResult := false
	_LNHT_FirstRestoreNavResult := false
	AssertTrue(_LLM_Menu_ActivateFirstRestoreHotkeys(false,
		_LNHT_FirstRestoreProfile, _LNHT_FirstRestoreNav))
	AssertEqual(0, _LNHT_FirstRestoreProfileCalls)
	AssertEqual(0, _LNHT_FirstRestoreNavCalls,
		"ordinary tray rebuilds must never rebind the inactive transaction slot")
	for InvalidProfileResult in [false, "", "1", "-1", 1.0, -1.0,
		2, Map()] {
		_LNHT_FirstRestoreProfileResult := InvalidProfileResult
		AssertFalse(_LLM_Menu_ActivateFirstRestoreHotkeys(true,
			_LNHT_FirstRestoreProfile, _LNHT_FirstRestoreNav))
	}
	AssertEqual(8, _LNHT_FirstRestoreProfileCalls)
	AssertEqual(0, _LNHT_FirstRestoreNavCalls,
		"profile refusal must short-circuit navigation admission")
	_LNHT_FirstRestoreProfileResult := _LLM_PROFILE_HOTKEY_STATUS_DEGRADED
	_LNHT_FirstRestoreNavResult := true
	AssertTrue(_LLM_Menu_ActivateFirstRestoreHotkeys(true,
		_LNHT_FirstRestoreProfile, _LNHT_FirstRestoreNav),
		"an explicit degraded profile terminal must still admit navigation")
	_LNHT_FirstRestoreProfileResult := true
	_LNHT_FirstRestoreNavResult := false
	for InvalidNavResult in [false, "", "1", 1.0, 2, Map()] {
		_LNHT_FirstRestoreNavResult := InvalidNavResult
		AssertFalse(_LLM_Menu_ActivateFirstRestoreHotkeys(true,
			_LNHT_FirstRestoreProfile, _LNHT_FirstRestoreNav))
	}
	AssertEqual(15, _LNHT_FirstRestoreProfileCalls)
	AssertEqual(7, _LNHT_FirstRestoreNavCalls)
	_LNHT_FirstRestoreNavResult := true
	AssertTrue(_LLM_Menu_ActivateFirstRestoreHotkeys(true,
		_LNHT_FirstRestoreProfile, _LNHT_FirstRestoreNav))
	AssertEqual(16, _LNHT_FirstRestoreProfileCalls)
	AssertEqual(8, _LNHT_FirstRestoreNavCalls,
		"a retained first-restore build must retry the complete surface")
}

_LNHT_FirstRestoreOwnsBootBinding() {
	return _LNHT_WithFixture(_LNHT_FirstRestoreOwnsBootBindingCore)
}

Test("[llm-nav-transaction] only first restore owns boot-time nav binding",
	_LNHT_FirstRestoreOwnsBootBinding)

_LNHT_ProfilePredicateYieldsToPredictionCore() {
	global _LLM_Menu, _Stub_LlmTooltipText
	global _LLM_PROFILE_HOTKEY_PRED, _LLM_Menu_NavActiveSlot
	global _LLM_Menu_ProfileHotkeyOwner, _LLM_Menu_Loaded
	global LLM_PROFILE_BUILTIN_ORDER, LLM_PROFILE_HOTKEY_LIMIT
	global _LNHT_TooltipSlots, _LNHT_AppOutput
	SavedMenu := _LLM_Menu
	SavedText := _Stub_LlmTooltipText
	SavedOwner := _LLM_Menu_ProfileHotkeyOwner
	SavedLoaded := _LLM_Menu_Loaded
	HadBuiltinOrder := IsSet(LLM_PROFILE_BUILTIN_ORDER)
	HadHotkeyLimit := IsSet(LLM_PROFILE_HOTKEY_LIMIT)
	if HadBuiltinOrder
		SavedBuiltinOrder := LLM_PROFILE_BUILTIN_ORDER
	if HadHotkeyLimit
		SavedHotkeyLimit := LLM_PROFILE_HOTKEY_LIMIT
	try {
		LLM_PROFILE_BUILTIN_ORDER := ["raw", "basic", "advanced",
			"batch_advanced"]
		LLM_PROFILE_HOTKEY_LIMIT := 9
		_LLM_Menu := _LLMST_Menu()
		_LLM_Menu["enabled"] := true
		_LLM_Menu["user_profiles"] := []
		_LLM_Menu_ProfileHotkeyOwner := Map(
			"ready", true, "degraded", false,
			"plan", _LLM_Menu_BuildProfileHotkeyPlan())
		_LLM_Menu_Loaded := true
		_LNHT_ShowTooltip(["one"])
		AssertTrue(LLM_Menu_BindNavHotkeys(_LNHT_Menu("alt", "alt"),
			_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log,
			_LNHT_ForceHotIfReset))
		AssertTrue(LLM_Menu_GetHotkeyProfileOrder().Length > 0)
		Profile1 := _LNHT_ProfileNativeSpec(1)
		Profile7 := _LNHT_ProfileNativeSpec(7)
		AssertTrue(Profile1 != "" && Profile7 != "")
		AssertTrue(_LLM_PROFILE_HOTKEY_PRED.Call(Profile1),
			"default Alt navigation must not swallow the Ctrl profile surface")
		AssertFalse(LLM_Menu_NavOwnsSpec(Profile1))

		AssertTrue(LLM_Menu_BindNavHotkeys(_LNHT_Menu("alt", "ctrl"),
			_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log,
			_LNHT_ForceHotIfReset))
		Nav1 := _LNHT_ActiveNavNativeSpec("^1")
		Nav7 := _LNHT_ActiveNavNativeSpec("^7")
		AssertTrue(Nav1 != "" && Nav7 != "")
		AssertTrue(_LLM_Menu_NavSlotPredicate(
			_LLM_Menu_NavActiveSlot).Call(Nav1))
		AssertTrue(LLM_Menu_NavOwnsSpec(Nav1))
		AssertFalse(_LLM_PROFILE_HOTKEY_PRED.Call(Profile1),
			"an exact Ctrl+digit collision must belong to visible navigation")
		_LNHT_ShowTooltip(["one", "two", "three", "four", "five", "six"])
		_LNHT_AppOutput := []
		AssertFalse(_LLM_Menu_NavSlotPredicate(
			_LLM_Menu_NavActiveSlot).Call(Nav7),
			"an out-of-range Ctrl+digit variant must let Windows pass it through")
		AssertTrue(LLM_Menu_NavOwnsSpec(Nav7),
			"the reserved navigation chord must still outrank the profile variant")
		AssertFalse(_LLM_PROFILE_HOTKEY_PRED.Call(Profile7),
			"an out-of-range navigation chord must not fall through to profiles")
		AssertEqual("app", _LNHT_FirePhysical("^7"))
		AssertEqual(1, _LNHT_AppOutput.Length)

		AssertTrue(LLM_Menu_BindNavHotkeys(
			_LNHT_Menu("alt", "control+shift"), _LNHT_Hotkey,
			_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset))
		AssertFalse(LLM_Menu_NavOwnsSpec(Profile1))
		AssertTrue(_LLM_PROFILE_HOTKEY_PRED.Call(Profile1),
			"a different navigation chord must leave Ctrl profiles enabled")

		_LNHT_HideTooltip()
		ShiftNav1 := _LNHT_ActiveNavNativeSpec("^+1")
		AssertTrue(ShiftNav1 != "")
		AssertFalse(_LLM_Menu_NavSlotPredicate(
			_LLM_Menu_NavActiveSlot).Call(ShiftNav1),
			"the active navigation surface must pass through while hidden")
		AssertTrue(_LLM_PROFILE_HOTKEY_PRED.Call(Profile1))
	} finally {
		_LLM_Menu := SavedMenu
		_Stub_LlmTooltipText := SavedText
		_LLM_Menu_ProfileHotkeyOwner := SavedOwner
		_LLM_Menu_Loaded := SavedLoaded
		LLM_PROFILE_BUILTIN_ORDER := HadBuiltinOrder ? SavedBuiltinOrder : unset
		LLM_PROFILE_HOTKEY_LIMIT := HadHotkeyLimit ? SavedHotkeyLimit : unset
	}
}

_LNHT_ProfilePredicateYieldsToPrediction() {
	return _LNHT_WithFixture(_LNHT_ProfilePredicateYieldsToPredictionCore)
}

Test("[llm-nav-transaction] visible prediction owns Ctrl+digit before profiles",
	_LNHT_ProfilePredicateYieldsToPrediction)

_LNHT_EmptyModifiersCore() {
	global _LNHT_Hotkeys, _LLM_Menu_NavActiveSlot, _Stub_LlmTooltipText
	global _LNHT_TooltipSlots, _LNHT_TooltipActiveIdx, _LNHT_AppOutput
	SavedText := _Stub_LlmTooltipText
	AssertTrue(LLM_Menu_BindNavHotkeys(_LNHT_Menu("", ""),
		_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log))
	_LNHT_AssertOnlyPrefix("")
	AssertTrue(_LNHT_Hotkeys.Has(_LNHT_OwnedSpec(
		_LLM_Menu_NavActiveSlot, "7")),
		"a genuinely empty validation modifier deliberately owns bare digits")
	try {
		_LNHT_ShowTooltip(["one", "two", "three", "four", "five",
			"six", "seven"])
		Native7 := _LNHT_ActiveNavNativeSpec("7")
		AssertTrue(Native7 != "")
		AssertTrue(_LLM_Menu_NavSlotPredicate(
			_LLM_Menu_NavActiveSlot).Call(Native7))
		AssertTrue(LLM_Menu_NavOwnsSpec(Native7))
		AssertEqual("hotkey", _LNHT_FirePhysical("7"))
		AssertEqual(7, _LNHT_TooltipActiveIdx,
			"a valid empty-modifier digit must select its in-range slot")
		AssertEqual(0, _LNHT_AppOutput.Length,
			"an owned in-range digit must not also reach the application")
		_LNHT_HideTooltip()
		AssertFalse(_LLM_Menu_NavSlotPredicate(
			_LLM_Menu_NavActiveSlot).Call(Native7),
			"bare digits must pass through exactly when the tooltip is hidden")
		AssertEqual("app", _LNHT_FirePhysical("7"))
		AssertEqual(1, _LNHT_AppOutput.Length)
	} finally _Stub_LlmTooltipText := SavedText
}

_LNHT_EmptyModifiers() {
	return _LNHT_WithFixture(_LNHT_EmptyModifiersCore)
}

Test("[llm-nav-transaction] genuinely empty modifiers retain bare-key support",
	_LNHT_EmptyModifiers)

_LNHT_DigitRangeMatchesVisibleSlotsCore() {
	global _Stub_LlmTooltipText, _LNHT_TooltipSlots
	global _LNHT_TooltipActiveIdx, _LNHT_AppOutput
	SavedText := _Stub_LlmTooltipText
	try {
		for Modifier in ["", "alt"] {
			Prefix := Modifier == "" ? "" : "!"
			AssertTrue(LLM_Menu_BindNavHotkeys(_LNHT_Menu("", Modifier),
				_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log,
				_LNHT_ForceHotIfReset))
			for SlotCount in [0, 1, 6, 10] {
				Slots := []
				Loop SlotCount
					Slots.Push("slot " . A_Index)
				_LNHT_ShowTooltip(Slots)
				Loop 10 {
					Index := A_Index
					Digit := Index == 10 ? "0" : String(Index)
					Spec := Prefix . Digit
					_LNHT_TooltipActiveIdx := -1
					_LNHT_AppOutput := []
					Outcome := _LNHT_FirePhysical(Spec)
					if Index <= SlotCount {
						AssertEqual("hotkey", Outcome)
						AssertEqual(Index, _LNHT_TooltipActiveIdx)
						AssertEqual(0, _LNHT_AppOutput.Length)
					} else {
						AssertEqual("app", Outcome,
							"an out-of-range digit must use native pass-through")
						AssertEqual(-1, _LNHT_TooltipActiveIdx)
						AssertEqual(1, _LNHT_AppOutput.Length)
						AssertEqual(Spec, _LNHT_AppOutput[1])
					}
				}
			}
			_LNHT_HideTooltip()
			Loop 10 {
				Digit := A_Index == 10 ? "0" : String(A_Index)
				Spec := Prefix . Digit
				_LNHT_AppOutput := []
				AssertEqual("app", _LNHT_FirePhysical(Spec),
					"every hidden digit variant must use native pass-through")
				AssertEqual(1, _LNHT_AppOutput.Length)
				AssertEqual(Spec, _LNHT_AppOutput[1])
			}
		}
	} finally _Stub_LlmTooltipText := SavedText
}

_LNHT_DigitRangeMatchesVisibleSlots() {
	return _LNHT_WithFixture(_LNHT_DigitRangeMatchesVisibleSlotsCore)
}

Test("[llm-nav-transaction] digit variants match the visible slot range",
	_LNHT_DigitRangeMatchesVisibleSlots)

_LNHT_PermanentHotkeyAliasCore() {
	global _Stub_LlmTooltipText, _LNHT_TooltipSlots
	global _LNHT_TooltipActiveIdx
	SavedText := _Stub_LlmTooltipText
	try {
		_LNHT_ShowTooltip(["one", "two"])
		AssertTrue(LLM_Menu_BindNavHotkeys(_LNHT_Menu("alt", "alt"),
			_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log,
			_LNHT_ForceHotIfReset))
		AssertEqual("!up", _LLM_Menu_NavNativeIdentity("~!Up"))
		AssertEqual("!up", _LLM_Menu_NavNativeIdentity("$!up"))
		AssertEqual("^!7", _LLM_Menu_NavNativeIdentity("~!^7"))
		AssertEqual("^!7", _LLM_Menu_NavNativeIdentity("$^!7"))
		AssertFalse(_LLM_Menu_NavNativeIdentity("*^!7")
			== _LLM_Menu_NavNativeIdentity("^!7"),
			"wildcard hotkeys must retain their distinct physical identity")
		AssertEqual("hotkey", _LNHT_FirePhysical("~!Up", "!up"),
			"the first variant's permanent name must resolve the tilde nav variant")
		AssertEqual(2, _LNHT_TooltipActiveIdx,
			"the permanent-name alias must execute the intended navigation callback")
		AssertEqual("hotkey", _LNHT_FirePhysical("~!Down", "!down"),
			"both arrow callbacks must accept the permanent HotkeyName argument")
		AssertEqual(1, _LNHT_TooltipActiveIdx,
			"Down must wrap from the last visible slot to the first")

		_LNHT_ShowTooltip(["one", "two", "three", "four", "five", "six",
			"seven"])
		AssertTrue(LLM_Menu_BindNavHotkeys(
			_LNHT_Menu("alt", "control+alt"), _LNHT_Hotkey,
			_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset))
		PermanentDigit := StrReplace(_LNHT_NativeSpec("^!7"), "^!", "!^")
		AssertEqual("hotkey", _LNHT_FirePhysical("^!7", PermanentDigit),
			"modifier order in the permanent name must not disable the variant")
		AssertEqual(7, _LNHT_TooltipActiveIdx)
	} finally _Stub_LlmTooltipText := SavedText
}

_LNHT_PermanentHotkeyAlias() {
	return _LNHT_WithFixture(_LNHT_PermanentHotkeyAliasCore)
}

Test("[llm-nav-transaction] permanent hotkey names resolve tilde variants",
	_LNHT_PermanentHotkeyAlias)
