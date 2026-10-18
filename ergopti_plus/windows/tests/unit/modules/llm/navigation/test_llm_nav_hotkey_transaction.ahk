; tests/unit/modules/llm/navigation/test_llm_nav_hotkey_transaction.ahk

; ==============================================================================
; MODULE: LLM Navigation Hotkey Transaction Tests
; DESCRIPTION:
; Root-cause regression coverage for AHK-017 and AHK-025. Invalid modifier text
; must be refused before persistence, a fallible native rebind must publish one
; complete surface, and an out-of-range digit must remain native pass-through.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Deterministic seams =======
; ======================================
; ======================================

global _LNHT_Hotkeys := Map()
global _LNHT_Events := []
global _LNHT_FailSpec := ""
global _LNHT_LogCalls := 0
global _LNHT_CommitCalls := 0
global _LNHT_RejectCalls := 0
global _LNHT_LastCandidate := 0
global _LNHT_HotIfDepth := 0
global _LNHT_FailHotIfClose := 0
global _LNHT_LogCritical := -1
global _LNHT_CurrentSlot := 0
global _LNHT_FailAfterApply := false
global _LNHT_FailOffSpec := ""
global _LNHT_FailForceHotIfReset := false
global _LNHT_TransactionWriterResult := 1
global _LNHT_TransactionWriterCalls := 0
global _LNHT_TransactionApplyCalls := 0
global _LNHT_TransactionNotifyCalls := 0
global _LNHT_WriterSawOldMenu := false
global _LNHT_WriterSawOldSurface := false
global _LNHT_NotifySawOldSurface := false
global _LNHT_AppOutput := []
global _LNHT_TooltipSlots := []
global _LNHT_TooltipActiveIdx := 1

LLM_Tooltip_GetSlots() {
	global _LNHT_TooltipSlots
	return _LNHT_TooltipSlots.Clone()
}

LLM_Tooltip_GetActiveIdx() {
	global _LNHT_TooltipActiveIdx
	return _LNHT_TooltipActiveIdx
}

LLM_Tooltip_SetActiveIdx(Index) {
	global _LNHT_TooltipActiveIdx, _LNHT_TooltipSlots
	if Index < 1 || Index > _LNHT_TooltipSlots.Length
		return false
	_LNHT_TooltipActiveIdx := Index
	return true
}

_LNHT_ShowTooltip(Slots, ActiveIdx := 1) {
	global _LNHT_TooltipSlots, _LNHT_TooltipActiveIdx
	global _Stub_LlmTooltipText, _Stub_LlmPresentedRecord
	_LNHT_TooltipSlots := Slots is Array ? Slots.Clone() : []
	if _LNHT_TooltipSlots.Length == 0 {
		_LNHT_TooltipActiveIdx := 1
		_Stub_LlmTooltipText := ""
		_Stub_LlmPresentedRecord := 0
		return
	}
	_LNHT_TooltipActiveIdx := Max(1, Min(ActiveIdx,
		_LNHT_TooltipSlots.Length))
	Lifecycle := {
		Outcome: "", AcceptSource: Map(), AppName: ""
	}
	_Stub_LlmPresentedRecord := {
		Kind: "prediction", Slots: _LNHT_TooltipSlots.Clone(),
		ActiveIdx: _LNHT_TooltipActiveIdx, Lifecycle: Lifecycle
	}
	_Stub_LlmTooltipText := _LNHT_TooltipSlots[
		_LNHT_TooltipActiveIdx]
}

_LNHT_HideTooltip() {
	global _Stub_LlmTooltipText, _Stub_LlmPresentedRecord
	_Stub_LlmTooltipText := ""
	_Stub_LlmPresentedRecord := 0
}

_LNHT_PredicateSlot(Predicate) {
	global _LLM_Nav_HotIfPred1, _LLM_Nav_HotIfPred2
	if Predicate == _LLM_Nav_HotIfPred1
		return 1
	if Predicate == _LLM_Nav_HotIfPred2
		return 2
	return 0
}

; The native spec the navigation plan freezes for LogicalSpec: its digits are
; their digit-row keys (_LLM_Menu_NavDigitRowKey), on every host layout.
_LNHT_NativeSpec(LogicalSpec, KeyResolverFn := 0) {
	Descriptor := HotkeyRegistrarResolvedNativeDescriptor(LogicalSpec,
		_LLM_Menu_NavDigitRowKey.Bind(
			_LLM_Menu_HotkeyKeyResolverSnapshot(KeyResolverFn)))
	return Descriptor is Map ? Descriptor["native_spec"] : LogicalSpec
}

_LNHT_NameMatches(Name, LogicalSpec) {
	return Name == LogicalSpec || Name == _LNHT_NativeSpec(LogicalSpec)
}

_LNHT_OwnedSpec(Slot, LogicalSpec) {
	global _LNHT_Hotkeys
	Exact := Slot . "|" . LogicalSpec
	if _LNHT_Hotkeys.Has(Exact)
		return Exact
	return Slot . "|" . _LNHT_NativeSpec(LogicalSpec)
}

_LNHT_ActiveNavNativeSpec(LogicalSpec) {
	global _LLM_Menu_NavHotkeysBound
	if _LLM_Menu_NavHotkeysBound is Array {
		for Entry in _LLM_Menu_NavHotkeysBound {
			if Entry is Map && Entry.Get("spec", "") == LogicalSpec
				return Entry.Get("native_spec", "")
		}
	}
	return ""
}

_LNHT_ProfileNativeSpec(Index) {
	global _LLM_Menu_ProfileHotkeyOwner
	if !(_LLM_Menu_ProfileHotkeyOwner is Map)
		return ""
	Plan := _LLM_Menu_ProfileHotkeyOwner.Get("plan", 0)
	if !(Plan is Array) || !Plan.Has(Index)
		return ""
	Entry := Plan[Index]
	return Entry is Map ? Entry.Get("native_spec", "") : ""
}

_LNHT_CallbackAcceptsHotkeyName(Callback) {
	if !HasMethod(Callback, "Call")
		return false
	try return Callback.MinParams <= 1
		&& (Callback.IsVariadic || Callback.MaxParams >= 1)
	catch
		return false
}

_LNHT_Hotkey(Args*) {
	global _LNHT_Hotkeys, _LNHT_Events, _LNHT_FailSpec, _LNHT_CurrentSlot
	global _LNHT_FailOffSpec
	if !(_LNHT_CurrentSlot == 1 || _LNHT_CurrentSlot == 2)
		throw Error("Hotkey called without a navigation HotIf owner")
	Spec := Args[1]
	Action := Args[2]
	Mode := Args.Length >= 3 ? Args[3] : ""
	if !(Action is String) && !_LNHT_CallbackAcceptsHotkeyName(Action)
		throw ValueError("injected callback rejects the native HotkeyName")
	OwnedSpec := _LNHT_CurrentSlot . "|" . Spec
	_LNHT_Events.Push(OwnedSpec . " " . (Action is String ? Action : Mode))
	ShouldFail := _LNHT_FailSpec != ""
		&& _LNHT_NameMatches(Spec, _LNHT_FailSpec)
		&& !(Action is String && Action == "Off")
	if ShouldFail && !_LNHT_FailAfterApply {
		_LNHT_FailSpec := ""
		throw Error("injected native registration failure")
	}
	if (Action is String && Action == "Off") {
		if (_LNHT_FailOffSpec != ""
				&& _LNHT_NameMatches(Spec, _LNHT_FailOffSpec)) {
			_LNHT_FailOffSpec := ""
			throw Error("injected native deregistration failure")
		}
		if !_LNHT_Hotkeys.Has(OwnedSpec)
			throw TargetError("injected missing HotIf variant")
		_LNHT_Hotkeys.Delete(OwnedSpec)
		return
	}
	_LNHT_Hotkeys[OwnedSpec] := Action
	if ShouldFail {
		_LNHT_FailSpec := ""
		throw Error("injected post-registration failure")
	}
}

_LNHT_HotIf(Args*) {
	global _LNHT_HotIfDepth, _LNHT_FailHotIfClose, _LNHT_CurrentSlot
	if Args.Length {
		Slot := _LNHT_PredicateSlot(Args[1])
		if !(Slot == 1 || Slot == 2)
			throw Error("unknown navigation predicate")
		_LNHT_CurrentSlot := Slot
		_LNHT_HotIfDepth := 1
		return
	}
	if (_LNHT_FailHotIfClose > 0) {
		_LNHT_FailHotIfClose -= 1
		throw Error("injected HotIf close failure")
	}
	_LNHT_HotIfDepth -= 1
	_LNHT_CurrentSlot := 0
}

_LNHT_ForceHotIfReset(*) {
	global _LNHT_HotIfDepth, _LNHT_CurrentSlot
	global _LNHT_FailForceHotIfReset
	if _LNHT_FailForceHotIfReset
		throw Error("injected force-reset failure")
	_LNHT_HotIfDepth := 0
	_LNHT_CurrentSlot := 0
}

_LNHT_Log(*) {
	global _LNHT_LogCalls, _LNHT_LogCritical
	_LNHT_LogCalls += 1
	_LNHT_LogCritical := A_IsCritical
}

_LNHT_Reject(*) {
	global _LNHT_RejectCalls
	_LNHT_RejectCalls += 1
	return false
}

_LNHT_Apply(*) {
	return true
}

_LNHT_TransactionApply(*) {
	global _LNHT_TransactionApplyCalls
	_LNHT_TransactionApplyCalls += 1
	return true
}

_LNHT_ActiveHas(Spec) {
	global _LNHT_Hotkeys, _LLM_Menu_NavActiveSlot
	return _LNHT_Hotkeys.Has(_LNHT_OwnedSpec(_LLM_Menu_NavActiveSlot, Spec))
}

_LNHT_FirePhysical(Spec, PermanentSpec := "") {
	global _LNHT_Hotkeys, _LNHT_AppOutput, _LLM_Menu_NavActiveSlot
	OwnedSpec := _LNHT_OwnedSpec(_LLM_Menu_NavActiveSlot, Spec)
	Predicate := _LLM_Menu_NavSlotPredicate(_LLM_Menu_NavActiveSlot)
	HotIfSpec := PermanentSpec == "" ? _LNHT_NativeSpec(Spec) : PermanentSpec
	if Predicate.Call(HotIfSpec) && _LNHT_Hotkeys.Has(OwnedSpec) {
		_LNHT_Hotkeys[OwnedSpec].Call(HotIfSpec)
		return "hotkey"
	}
	_LNHT_AppOutput.Push(Spec)
	return "app"
}

_LNHT_TransactionWriter(Path, Updates) {
	global _LNHT_TransactionWriterResult, _LNHT_TransactionWriterCalls
	global _LNHT_WriterSawOldMenu, _LNHT_WriterSawOldSurface, _LLM_Menu
	_LNHT_TransactionWriterCalls += 1
	_LNHT_WriterSawOldMenu := _LLM_Menu["val_modifiers"] == "alt"
	_LNHT_WriterSawOldSurface := _LNHT_ActiveHas("!7")
		&& !_LNHT_ActiveHas("^7")
	return _LNHT_TransactionWriterResult
}

_LNHT_TransactionNotify(*) {
	global _LNHT_TransactionNotifyCalls, _LNHT_NotifySawOldSurface
	_LNHT_TransactionNotifyCalls += 1
	_LNHT_NotifySawOldSurface := _LNHT_ActiveHas("!7")
		&& !_LNHT_ActiveHas("^7")
	return true
}

_LNHT_TransactionPort() {
	return Map("apply", _LNHT_TransactionApply,
		"writer", _LNHT_TransactionWriter,
		"notify", _LNHT_TransactionNotify, "acquire", _LMT_Acquire,
		"settle", _LMT_Settle,
		"collect", _LMT_Collect, "hotkey", _LNHT_Hotkey,
		"hotif", _LNHT_HotIf, "log", _LNHT_Log,
		"reset", _LNHT_ForceHotIfReset)
}

_LNHT_Commit(Context, MutateFn, ApplyFn) {
	global _LNHT_CommitCalls, _LNHT_LastCandidate
	_LNHT_CommitCalls += 1
	Candidate := Map("nav_modifiers", "alt", "val_modifiers", "alt")
	AssertTrue(MutateFn.Call(Candidate),
		"the detached modifier mutation must authorize exactly one field update")
	_LNHT_LastCandidate := Candidate
	return true
}

_LNHT_Reset() {
	global _LNHT_Hotkeys, _LNHT_Events, _LNHT_FailSpec
	global _LNHT_LogCalls, _LNHT_CommitCalls, _LNHT_RejectCalls
	global _LNHT_LastCandidate
	global _LNHT_HotIfDepth, _LNHT_FailHotIfClose, _LNHT_LogCritical
	global _LNHT_CurrentSlot, _LNHT_FailAfterApply
	global _LNHT_FailOffSpec, _LNHT_FailForceHotIfReset
	global _LNHT_TransactionWriterResult, _LNHT_TransactionWriterCalls
	global _LNHT_TransactionApplyCalls, _LNHT_TransactionNotifyCalls
	global _LNHT_WriterSawOldMenu, _LNHT_WriterSawOldSurface
	global _LNHT_NotifySawOldSurface
	global _LNHT_AppOutput, _LNHT_TooltipSlots, _LNHT_TooltipActiveIdx
	_LNHT_Hotkeys := Map()
	_LNHT_Events := []
	_LNHT_FailSpec := ""
	_LNHT_LogCalls := 0
	_LNHT_CommitCalls := 0
	_LNHT_RejectCalls := 0
	_LNHT_LastCandidate := 0
	_LNHT_HotIfDepth := 0
	_LNHT_FailHotIfClose := 0
	_LNHT_LogCritical := -1
	_LNHT_CurrentSlot := 0
	_LNHT_FailAfterApply := false
	_LNHT_FailOffSpec := ""
	_LNHT_FailForceHotIfReset := false
	_LNHT_TransactionWriterResult := 1
	_LNHT_TransactionWriterCalls := 0
	_LNHT_TransactionApplyCalls := 0
	_LNHT_TransactionNotifyCalls := 0
	_LNHT_WriterSawOldMenu := false
	_LNHT_WriterSawOldSurface := false
	_LNHT_NotifySawOldSurface := false
	_LNHT_AppOutput := []
	_LNHT_TooltipSlots := []
	_LNHT_TooltipActiveIdx := 1
}

_LNHT_Menu(Nav, Val) {
	return Map("nav_modifiers", Nav, "val_modifiers", Val)
}

_LNHT_AssertOnlyPrefix(Prefix) {
	_LNHT_AssertSurface(Prefix, Prefix)
}

_LNHT_AssertSurface(NavPrefix, ValPrefix) {
	global _LNHT_Hotkeys, _LLM_Menu_NavActiveSlot
	OwnedPrefix := _LLM_Menu_NavActiveSlot . "|"
	Count := 0
	for OwnedSpec in _LNHT_Hotkeys {
		if InStr(OwnedSpec, OwnedPrefix) == 1
			Count += 1
	}
	AssertEqual(12, Count,
		"a complete navigation surface owns two arrows and ten digits")
	AssertTrue(_LNHT_Hotkeys.Has(_LNHT_OwnedSpec(_LLM_Menu_NavActiveSlot,
		"~" . NavPrefix . "Up")))
	AssertTrue(_LNHT_Hotkeys.Has(_LNHT_OwnedSpec(_LLM_Menu_NavActiveSlot,
		"~" . NavPrefix . "Down")))
	Loop 10 {
		Digit := A_Index == 10 ? "0" : String(A_Index)
		AssertTrue(_LNHT_Hotkeys.Has(_LNHT_OwnedSpec(
			_LLM_Menu_NavActiveSlot, ValPrefix . Digit)),
			"the complete generation must retain " . ValPrefix . Digit)
	}
}

_LNHT_WithPersistenceFixture(TestFn) {
	global _LLM_Menu, Features
	Previous := _LMT_InstallFixture()
	try {
		_LLM_Menu["nav_modifiers"] := "alt"
		_LLM_Menu["val_modifiers"] := "alt"
		AssertTrue(_LLM_Menu_SyncToFeatures(Features, _LLM_Menu))
		return _LNHT_WithFixture(TestFn)
	} finally _LMT_RestoreFixture(Previous)
}

_LNHT_WithFixture(TestFn) {
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavSlotPlans
	global _LLM_Menu_NavActiveSlot
	global _Stub_LlmTooltipText, _Stub_LlmPresentedRecord
	SavedBound := _LLM_Menu_NavHotkeysBound
	SavedPlans := _LLM_Menu_NavSlotPlans
	SavedSlot := _LLM_Menu_NavActiveSlot
	SavedText := _Stub_LlmTooltipText
	SavedRecord := _Stub_LlmPresentedRecord
	try {
		_LNHT_Reset()
		_LLM_Menu_NavHotkeysBound := []
		_LLM_Menu_NavSlotPlans := Map(1, [], 2, [])
		_LLM_Menu_NavActiveSlot := 0
		return TestFn.Call()
	} finally {
		_LLM_Menu_NavHotkeysBound := SavedBound
		_LLM_Menu_NavSlotPlans := SavedPlans
		_LLM_Menu_NavActiveSlot := SavedSlot
		_LNHT_Reset()
		_Stub_LlmTooltipText := SavedText
		_Stub_LlmPresentedRecord := SavedRecord
	}
}





; ==================================
; ==================================
; ======= 2/ Admission tests =======
; ==================================
; ==================================

_LNHT_InvalidTextCore() {
	global _LNHT_CommitCalls, _LNHT_RejectCalls, _LNHT_Events
	global _LLM_Menu_NavActiveSlot
	global _LNHT_TooltipSlots, _LNHT_TooltipActiveIdx, _LNHT_AppOutput
	global _Stub_LlmTooltipText
	SavedText := _Stub_LlmTooltipText
	try {
		AssertTrue(LLM_Menu_BindNavHotkeys(_LNHT_Menu("alt", "alt"),
			_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log,
			_LNHT_ForceHotIfReset))
		OldSlot := _LLM_Menu_NavActiveSlot
		_LNHT_Events := []
		for InvalidValue in ["crtl", "+", "++"] {
			_LNHT_Events := []
			AssertFalse(LLM_Menu_CommitNavModifier("val_modifiers",
				InvalidValue, _LNHT_Commit, 0, _LNHT_Reject))
			AssertEqual(0, _LNHT_Events.Length,
				"syntax rejection must happen before any native surface mutation")
			AssertEqual(OldSlot, _LLM_Menu_NavActiveSlot)
			_LNHT_AssertOnlyPrefix("!")
		}
		AssertEqual(0, _LNHT_CommitCalls,
			"invalid nonempty modifier text must be refused before persistence")
		AssertEqual(3, _LNHT_RejectCalls,
			"each invalid spelling must produce one user-visible refusal")

		_LNHT_ShowTooltip(["one", "two", "three", "four", "five", "six"])
		AssertEqual("app", _LNHT_FirePhysical("7"))
		AssertEqual(1, _LNHT_AppOutput.Length)
		AssertEqual("7", _LNHT_AppOutput[1],
			"a rejected typo must deliver the physical digit exactly once")
	} finally _Stub_LlmTooltipText := SavedText
}

_LNHT_InvalidText() {
	return _LNHT_WithFixture(_LNHT_InvalidTextCore)
}

Test("[llm-nav-transaction] malformed text is refused before persistence",
	_LNHT_InvalidText)

_LNHT_ValidTextCore() {
	global _LNHT_CommitCalls, _LNHT_RejectCalls, _LNHT_LastCandidate
	AssertTrue(LLM_Menu_CommitNavModifier("nav_modifiers",
		" control+shift ", _LNHT_Commit, _LNHT_Apply, _LNHT_Reject))
	AssertEqual(1, _LNHT_CommitCalls)
	AssertEqual(0, _LNHT_RejectCalls)
	AssertEqual("control+shift", _LNHT_LastCandidate["nav_modifiers"],
		"valid modifier text must reach the detached candidate trimmed")
	AssertEqual("alt", _LNHT_LastCandidate["val_modifiers"],
		"the mutation must leave its sibling field unchanged")
}

_LNHT_ValidText() {
	return _LNHT_WithFixture(_LNHT_ValidTextCore)
}

Test("[llm-nav-transaction] valid text reaches one detached commit",
	_LNHT_ValidText)

_LNHT_InvalidBindCore() {
	global _LNHT_Events
	AssertTrue(LLM_Menu_BindNavHotkeys(_LNHT_Menu("alt", "alt"),
		_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log))
	for InvalidValue in ["crtl", "+", "++"] {
		_LNHT_Events := []
		AssertFalse(LLM_Menu_BindNavHotkeys(
			_LNHT_Menu("alt", InvalidValue), _LNHT_Hotkey,
			_LNHT_HotIf, _LNHT_Log))
		AssertEqual(0, _LNHT_Events.Length,
			"invalid state must not disable or register any native hotkey")
		_LNHT_AssertOnlyPrefix("!")
	}
}

_LNHT_InvalidBind() {
	return _LNHT_WithFixture(_LNHT_InvalidBindCore)
}

Test("[llm-nav-transaction] invalid state preserves the old native surface",
	_LNHT_InvalidBind)

_LNHT_CompositeStateCore() {
	global _LNHT_Events
	AssertTrue(LLM_Menu_BindNavHotkeys(_LNHT_Menu("alt", "alt"),
		_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log))
	_LNHT_Events := []
	AssertFalse(LLM_Menu_BindNavHotkeys(
		Map("nav_modifiers", ["ctrl"], "val_modifiers", "alt"),
		_LNHT_Hotkey, _LNHT_HotIf, _LNHT_Log))
	AssertEqual(0, _LNHT_Events.Length,
		"a composite modifier must not degrade into the empty-modifier binding")
	_LNHT_AssertOnlyPrefix("!")
}

_LNHT_CompositeState() {
	return _LNHT_WithFixture(_LNHT_CompositeStateCore)
}

Test("[llm-nav-transaction] composite state cannot become bare-key bindings",
	_LNHT_CompositeState)
