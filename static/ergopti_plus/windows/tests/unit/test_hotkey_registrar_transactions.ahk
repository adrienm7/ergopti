; tests/unit/test_hotkey_registrar_transactions.ahk

; ==============================================================================
; MODULE: Hotkey registrar ownership and exception-atomic transactions
; DESCRIPTION:
; Behavioural proof that every exact native spec has one registrar owner, that an
; unpublished action never fires, and that an AHK Hotkey() exception restores
; the exact pre-call authority without speculative native compensation.
; ==============================================================================

#Requires AutoHotkey v2.0

global _HKRT_NativeBindings := Map()
global _HKRT_Events := []
global _HKRT_ThrowInstallSpecs := Map()
global _HKRT_ThrowOnSpecs := Map()
global _HKRT_ThrowOffSpecs := Map()
global _HKRT_FireBeforeActions := Map()
global _HKRT_BeforeActionHook := 0
global _HKRT_BeforeInstallHook := 0
global _HKRT_AfterActionHook := 0
global _HKRT_AfterInstallHook := 0
global _HKRT_BeforeProbeHook := 0
global _HKRT_ProbeThrows := false
global _HKRT_ProbeCalls := 0
global _HKRT_ProbeNames := []
global _HKRT_ReentrantHandle := ""
global _HKRT_FirstCalls := 0
global _HKRT_SecondCalls := 0
global _HKRT_ZeroArityCalls := 0
global _HKRT_AppDeliveries := 0
global _HKRT_HotIfContext := "global"
global _HKRT_HotIfCalls := 0
global _HKRT_GetVkCalls := 0
global _HKRT_GetScCalls := 0

_HKRT_Reset() {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global HOTKEY_REGISTRAR_NEXT_TOKEN
	global _HKRT_NativeBindings, _HKRT_Events
	global _HKRT_ThrowInstallSpecs, _HKRT_ThrowOnSpecs, _HKRT_ThrowOffSpecs
	global _HKRT_FireBeforeActions, _HKRT_BeforeActionHook
	global _HKRT_BeforeInstallHook, _HKRT_AfterInstallHook
	global _HKRT_AfterActionHook, _HKRT_BeforeProbeHook
	global _HKRT_ProbeThrows, _HKRT_ProbeCalls, _HKRT_ProbeNames
	global _HKRT_ReentrantHandle
	global _HKRT_FirstCalls, _HKRT_SecondCalls, _HKRT_ZeroArityCalls
	global _HKRT_AppDeliveries
	global _HKRT_HotIfContext, _HKRT_HotIfCalls
	global _HKRT_GetVkCalls, _HKRT_GetScCalls
	HOTKEY_REGISTRAR_BINDINGS := Map()
	HOTKEY_REGISTRAR_SPECS := Map()
	HOTKEY_REGISTRAR_NEXT_TOKEN := 0
	_HKRT_NativeBindings := Map()
	_HKRT_Events := []
	_HKRT_ThrowInstallSpecs := Map()
	_HKRT_ThrowOnSpecs := Map()
	_HKRT_ThrowOffSpecs := Map()
	_HKRT_FireBeforeActions := Map()
	_HKRT_BeforeActionHook := 0
	_HKRT_BeforeInstallHook := 0
	_HKRT_AfterActionHook := 0
	_HKRT_AfterInstallHook := 0
	_HKRT_BeforeProbeHook := 0
	_HKRT_ProbeThrows := false
	_HKRT_ProbeCalls := 0
	_HKRT_ProbeNames := []
	_HKRT_ReentrantHandle := ""
	_HKRT_FirstCalls := 0
	_HKRT_SecondCalls := 0
	_HKRT_ZeroArityCalls := 0
	_HKRT_AppDeliveries := 0
	_HKRT_HotIfContext := "global"
	_HKRT_HotIfCalls := 0
	_HKRT_GetVkCalls := 0
	_HKRT_GetScCalls := 0
}

; Models the exception ordering implemented by AHK v2.0.26 Hotkey::Dynamic:
; validation errors occur before mutation, and action-only On/Off cannot raise
; after changing the native enabled bit.
_HKRT_NativeHotkey(Name, Action := unset, Options := unset) {
	global _HKRT_NativeBindings, _HKRT_Events
	global _HKRT_ThrowInstallSpecs, _HKRT_ThrowOnSpecs, _HKRT_ThrowOffSpecs
	global _HKRT_FireBeforeActions, _HKRT_BeforeActionHook
	global _HKRT_BeforeInstallHook, _HKRT_AfterInstallHook
	global _HKRT_AfterActionHook
	if !IsSet(Action)
		return _HKRT_NativeBindings.Has(Name)
	if IsSet(Options) {
		_HKRT_Events.Push(Name . " " . Options)
		if HasMethod(_HKRT_BeforeInstallHook, "Call") {
			Hook := _HKRT_BeforeInstallHook
			_HKRT_BeforeInstallHook := 0
			Hook.Call(Name, Options)
		}
		if _HKRT_ThrowInstallSpecs.Has(Name)
			throw ValueError("injected validation failure before native install")
		_HKRT_NativeBindings[Name] := {
			callback: Action,
			enabled: Options == "On"
		}
		if HasMethod(_HKRT_AfterInstallHook, "Call") {
			Hook := _HKRT_AfterInstallHook
			_HKRT_AfterInstallHook := 0
			Hook.Call(Name, Options)
		}
		return true
	}

	Event := Name . " " . Action
	_HKRT_Events.Push(Event)
	if _HKRT_FireBeforeActions.Has(Event)
		_HKRT_PhysicalPress(Name)
	if HasMethod(_HKRT_BeforeActionHook, "Call") {
		Hook := _HKRT_BeforeActionHook
		_HKRT_BeforeActionHook := 0
		Hook.Call(Name, Action)
	}
	if (Action == "On") {
		if _HKRT_ThrowOnSpecs.Has(Name)
			throw Error("injected On refusal before native mutation")
		if !_HKRT_NativeBindings.Has(Name)
			throw TargetError("injected nonexistent hotkey")
		_HKRT_NativeBindings[Name].enabled := true
		if HasMethod(_HKRT_AfterActionHook, "Call") {
			Hook := _HKRT_AfterActionHook
			_HKRT_AfterActionHook := 0
			Hook.Call(Name, Action)
		}
		return true
	}
	if (Action == "Off") {
		if _HKRT_ThrowOffSpecs.Has(Name)
			throw Error("injected Off refusal before native mutation")
		if !_HKRT_NativeBindings.Has(Name)
			throw TargetError("injected nonexistent hotkey")
		_HKRT_NativeBindings[Name].enabled := false
		if HasMethod(_HKRT_AfterActionHook, "Call") {
			Hook := _HKRT_AfterActionHook
			_HKRT_AfterActionHook := 0
			Hook.Call(Name, Action)
		}
		return true
	}
	throw ValueError("unexpected fake Hotkey action")
}

_HKRT_Probe(Name) {
	global _HKRT_NativeBindings, _HKRT_ProbeThrows, _HKRT_ProbeCalls
	global _HKRT_BeforeProbeHook
	_HKRT_ProbeCalls += 1
	if HasMethod(_HKRT_BeforeProbeHook, "Call") {
		Hook := _HKRT_BeforeProbeHook
		_HKRT_BeforeProbeHook := 0
		Hook.Call(Name)
	}
	if _HKRT_ProbeThrows
		throw Error("injected probe failure")
	return _HKRT_NativeBindings.Has(Name)
}

; AHK treats ~/\$ as attributes of the same permanent hotkey name. This probe
; deliberately models that lookup while retaining the suffix-text distinction
; between a raw producer (^v) and a frozen explicit VK owner (^vk56).
_HKRT_AliasAwareProbe(Name) {
	global _HKRT_NativeBindings, _HKRT_ProbeCalls, _HKRT_ProbeNames
	_HKRT_ProbeCalls += 1
	_HKRT_ProbeNames.Push(Name)
	Needle := RegExReplace(StrLower(Name), "^[~$]+")
	for NativeName in _HKRT_NativeBindings {
		if RegExReplace(StrLower(NativeName), "^[~$]+") == Needle
			return true
	}
	return false
}

; Models a physical press, not merely callback invocation. An absent or disabled
; variant reaches the application; an enabled suppressing variant calls AHK.
_HKRT_PhysicalPress(Name) {
	global _HKRT_NativeBindings, _HKRT_AppDeliveries
	if !_HKRT_NativeBindings.Has(Name) {
		_HKRT_AppDeliveries += 1
		return true
	}
	Binding := _HKRT_NativeBindings[Name]
	if !Binding.enabled {
		_HKRT_AppDeliveries += 1
		return true
	}
	Binding.callback.Call("fake-hotkey")
	return true
}

_HKRT_SelectGlobalHotIf() {
	global _HKRT_HotIfContext, _HKRT_HotIfCalls
	_HKRT_HotIfCalls += 1
	_HKRT_HotIfContext := "global"
}

_HKRT_ContextCheckedHotkey(Name, Action := unset, Options := unset) {
	global _HKRT_HotIfContext
	if (_HKRT_HotIfContext != "global")
		throw Error("native mutation inherited contextual HotIf")
	if !IsSet(Action)
		return _HKRT_NativeHotkey(Name)
	if !IsSet(Options)
		return _HKRT_NativeHotkey(Name, Action)
	return _HKRT_NativeHotkey(Name, Action, Options)
}

_HKRT_ContextCheckedProbe(Name) {
	global _HKRT_HotIfContext
	if (_HKRT_HotIfContext != "global")
		throw Error("native probe inherited contextual HotIf")
	return _HKRT_Probe(Name)
}

_HKRT_First(*) {
	global _HKRT_FirstCalls
	_HKRT_FirstCalls += 1
}

_HKRT_Second(*) {
	global _HKRT_SecondCalls
	_HKRT_SecondCalls += 1
}

_HKRT_LetterNResolver(Key) {
	if StrLower(Key) == "n"
		return Map("axis", "vk", "code", 0x4E,
			"implicit_modifiers", "")
	return false
}

_HKRT_LetterVResolver(Key) {
	if StrLower(Key) == "v"
		return Map("axis", "vk", "code", 0x56,
			"implicit_modifiers", "")
	return false
}

_HKRT_DigitResolver(Key) {
	if Key == "6"
		return Map("axis", "vk", "code", 0x36,
			"implicit_modifiers", "")
	return false
}

_HKRT_ExplicitAliasGetVk(*) {
	global _HKRT_GetVkCalls
	_HKRT_GetVkCalls += 1
	return 0x26
}

_HKRT_ExplicitAliasGetSc(Key) {
	global _HKRT_GetScCalls
	_HKRT_GetScCalls += 1
	return StrLower(Key) == "up" ? 0x148 : 0
}

_HKRT_ZeroArity() {
	global _HKRT_ZeroArityCalls
	_HKRT_ZeroArityCalls += 1
}

_HKRT_Bind(Chord, Callback, Owner := "test", HotkeyFn := 0,
		ProbeFn := 0, HotIfFn := 0) {
	if !HasMethod(HotkeyFn, "Call")
		HotkeyFn := _HKRT_NativeHotkey
	if !HasMethod(ProbeFn, "Call")
		ProbeFn := _HKRT_Probe
	return _HotkeyRegistrarBindOwned(Chord, Callback, Owner,
		HotkeyFn, ProbeFn, HotIfFn)
}

_HKRT_Reserve(Chord, Callback, Owner := "test", HotkeyFn := 0,
		ProbeFn := 0, HotIfFn := 0) {
	if !HasMethod(HotkeyFn, "Call")
		HotkeyFn := _HKRT_NativeHotkey
	if !HasMethod(ProbeFn, "Call")
		ProbeFn := _HKRT_Probe
	return _HotkeyRegistrarReserveOwned(Chord, Callback, Owner,
		HotkeyFn, ProbeFn, HotIfFn)
}

_HKRT_AssertEvents(Expected, Message) {
	global _HKRT_Events
	AssertEqual(Expected.Length, _HKRT_Events.Length, Message . " (event count)")
	for Index, Event in Expected
		AssertEqual(Event, _HKRT_Events[Index], Message . " (event " . Index . ")")
}

_HKRT_CountNeedle(Haystack, Needle) {
	Count := 0
	Position := 1
	while Position := InStr(Haystack, Needle, , Position) {
		Count += 1
		Position += StrLen(Needle)
	}
	return Count
}

_HKRT_AttemptReentrantBind(*) {
	global _HKRT_ReentrantHandle
	_HKRT_ReentrantHandle := _HKRT_Bind("Ctrl+R", _HKRT_Second, "llm:trigger")
}

_HKRT_CorruptClaimState(Name, *) {
	global HOTKEY_REGISTRAR_SPECS
	Entry := HOTKEY_REGISTRAR_SPECS[Name]
	Entry["state"] := _HotkeyRegistrarState("corrupt", 0, "unknown")
}

_HKRT_PressDuringNativeReturn(Name, *) {
	_HKRT_PhysicalPress(Name)
}

_HKRT_ReserveIsInertUntilActivate() {
	global HOTKEY_REGISTRAR_BINDINGS
	global _HKRT_FirstCalls, _HKRT_AppDeliveries
	_HKRT_Reset()
	Handle := _HKRT_Reserve("Ctrl+U", _HKRT_First, "metrics:typing")
	AssertTrue(Handle != "")
	Spec := HOTKEY_REGISTRAR_BINDINGS[Handle]["spec"]
	_HKRT_AssertEvents([Spec . " Off"],
		"reserve must install exactly one disabled native wrapper")
	AssertEqual("reserved", HOTKEY_REGISTRAR_BINDINGS[Handle]["state"]["phase"])
	_HKRT_PhysicalPress(Spec)
	AssertEqual(0, _HKRT_FirstCalls,
		"an inert reservation must not publish its candidate action")
	AssertEqual(1, _HKRT_AppDeliveries,
		"a disabled reservation must pass the physical press to the application")
	AssertTrue(_HotkeyRegistrarActivate(Handle, _HKRT_NativeHotkey))
	_HKRT_PhysicalPress(Spec)
	AssertEqual(1, _HKRT_FirstCalls)
	AssertEqual(1, _HKRT_AppDeliveries)
}
Test("hotkey registrar: reserve stays inert until explicit activation "
	. "(hotkey-reserve-inert-until-activate)", _HKRT_ReserveIsInertUntilActivate)

_HKRT_PublicCallbackReceivesNoNativeArguments() {
	global HOTKEY_REGISTRAR_BINDINGS, _HKRT_ZeroArityCalls
	_HKRT_Reset()
	Handle := _HKRT_Bind("Ctrl+Z", _HKRT_ZeroArity, "metrics:typing")
	AssertTrue(Handle != "")
	_HKRT_PhysicalPress(HOTKEY_REGISTRAR_BINDINGS[Handle]["spec"])
	AssertEqual(1, _HKRT_ZeroArityCalls,
		"a public zero-arity callback must ignore native Hotkey arguments")
}
Test("hotkey registrar: public callback receives no native arguments "
	. "(hotkey-callback-zero-arity)",
	_HKRT_PublicCallbackReceivesNoNativeArguments)

_HKRT_FirstPressAfterNativeOnIsNeverDropped() {
	global _HKRT_AfterActionHook, _HKRT_FirstCalls, _HKRT_AppDeliveries
	_HKRT_Reset()
	Handle := _HKRT_Reserve("Ctrl+F10", _HKRT_First, "metrics:typing")
	AssertTrue(Handle != "")
	_HKRT_AfterActionHook := _HKRT_PressDuringNativeReturn
	AssertTrue(_HotkeyRegistrarActivate(Handle, _HKRT_NativeHotkey))
	AssertEqual(1, _HKRT_FirstCalls,
		"activate must dispatch a press after native On but before stable publication")
	AssertEqual(0, _HKRT_AppDeliveries,
		"the newly active native variant must suppress that dispatched press")

	_HKRT_Reset()
	Handle := _HKRT_Bind("Ctrl+F11", _HKRT_First, "metrics:typing")
	AssertTrue(Handle != "")
	AssertTrue(_HotkeyRegistrarSetEnabled(Handle, false, _HKRT_NativeHotkey))
	_HKRT_AfterActionHook := _HKRT_PressDuringNativeReturn
	AssertTrue(_HotkeyRegistrarSetEnabled(Handle, true, _HKRT_NativeHotkey))
	AssertEqual(1, _HKRT_FirstCalls,
		"setEnabled must dispatch a press in its native-On publication window")
	AssertEqual(0, _HKRT_AppDeliveries,
		"reenabling must not leak that dispatched press to the application")
}
Test("hotkey registrar: first press after native On is never dropped "
	. "(hotkey-enable-window-no-drop)",
	_HKRT_FirstPressAfterNativeOnIsNeverDropped)

_HKRT_AbortReleasesInertReservation() {
	global HOTKEY_REGISTRAR_BINDINGS
	global _HKRT_FirstCalls, _HKRT_SecondCalls, _HKRT_AppDeliveries
	_HKRT_Reset()
	Handle := _HKRT_Reserve("Ctrl+A", _HKRT_First, "metrics:typing")
	AssertTrue(Handle != "")
	Spec := HOTKEY_REGISTRAR_BINDINGS[Handle]["spec"]
	AssertTrue(_HotkeyRegistrarAbort(Handle))
	AssertEqual(0, HotkeyRegistrarLiveCount())
	_HKRT_PhysicalPress(Spec)
	AssertEqual(0, _HKRT_FirstCalls)
	AssertEqual(1, _HKRT_AppDeliveries,
		"an aborted disabled variant must keep passing physical input")
	Replacement := _HKRT_Bind("Ctrl+A", _HKRT_Second, "metrics:apps")
	AssertTrue(Replacement != "")
	_HKRT_PhysicalPress(HOTKEY_REGISTRAR_BINDINGS[Replacement]["spec"])
	AssertEqual(1, _HKRT_SecondCalls)
}
Test("hotkey registrar: abort retires an inert reservation "
	. "(hotkey-reserve-abort)", _HKRT_AbortReleasesInertReservation)

_HKRT_InvalidInstallLeavesNoPhantomOwner() {
	global HOTKEY_REGISTRAR_SPECS, _HKRT_ThrowInstallSpecs
	global _HKRT_AppDeliveries
	_HKRT_Reset()
	Spec := "^i"
	_HKRT_ThrowInstallSpecs[Spec] := true
	AssertEqual("", _HKRT_Bind("Ctrl+I", _HKRT_First, "metrics:typing"),
		"a native ValueError must be an ordinary bind refusal")
	_HKRT_AssertEvents([Spec . " Off"],
		"invalid install must not trigger speculative cleanup calls")
	AssertEqual(0, HotkeyRegistrarLiveCount())
	AssertFalse(HOTKEY_REGISTRAR_SPECS.Has(Spec),
		"an invalid new key must not leave a private phantom reservation")
	_HKRT_PhysicalPress(Spec)
	AssertEqual(1, _HKRT_AppDeliveries,
		"a refused hotkey must leave the application-visible chord intact")
	_HKRT_ThrowInstallSpecs.Delete(Spec)
	AssertTrue(_HKRT_Bind("Ctrl+I", _HKRT_First, "metrics:typing") != "",
		"the same chord must be immediately retryable")
}
Test("hotkey registrar: invalid native install leaves no phantom owner "
	. "(hotkey-invalid-install-no-phantom)",
	_HKRT_InvalidInstallLeavesNoPhantomOwner)

_HKRT_ReserveFailureRestoresPriorTombstone() {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global _HKRT_ThrowInstallSpecs
	_HKRT_Reset()
	Handle := _HKRT_Bind("Ctrl+J", _HKRT_First, "metrics:typing")
	AssertTrue(Handle != "")
	Spec := HOTKEY_REGISTRAR_BINDINGS[Handle]["spec"]
	AssertTrue(_HotkeyRegistrarRetire(Handle, _HKRT_NativeHotkey))
	PriorEntry := HOTKEY_REGISTRAR_SPECS[Spec]
	_HKRT_ThrowInstallSpecs[Spec] := true
	AssertEqual("", _HKRT_Reserve("Ctrl+J", _HKRT_Second, "metrics:apps"))
	AssertTrue(HOTKEY_REGISTRAR_SPECS[Spec] == PriorEntry,
		"a failed tombstone replacement must restore the exact prior identity")
	AssertEqual("retired", PriorEntry["state"]["phase"])
}
Test("hotkey registrar: reserve refusal restores prior tombstone identity "
	. "(hotkey-reserve-refusal-restores-tombstone)",
	_HKRT_ReserveFailureRestoresPriorTombstone)

_HKRT_ActivateFailureRestoresExactReserve() {
	global HOTKEY_REGISTRAR_BINDINGS, _HKRT_Events
	global _HKRT_ThrowOnSpecs, _HKRT_FireBeforeActions
	global _HKRT_FirstCalls, _HKRT_AppDeliveries
	_HKRT_Reset()
	Handle := _HKRT_Reserve("Ctrl+T", _HKRT_First, "metrics:typing")
	Before := HOTKEY_REGISTRAR_BINDINGS[Handle]["state"]
	_HKRT_Events := []
	Spec := HOTKEY_REGISTRAR_BINDINGS[Handle]["spec"]
	_HKRT_FireBeforeActions[Spec . " On"] := true
	_HKRT_ThrowOnSpecs[Spec] := true
	AssertFalse(_HotkeyRegistrarActivate(Handle, _HKRT_NativeHotkey))
	_HKRT_AssertEvents([Spec . " On"],
		"failed activation must issue no compensating native action")
	AssertTrue(HOTKEY_REGISTRAR_BINDINGS[Handle]["state"] == Before,
		"failed activation must restore the exact immutable reserve snapshot")
	AssertEqual(0, _HKRT_FirstCalls,
		"the desired action must not publish inside the failed On writer window")
	AssertEqual(1, _HKRT_AppDeliveries,
		"native Off must pass a concurrent physical press to the application")
	_HKRT_ThrowOnSpecs.Delete(Spec)
	AssertTrue(_HotkeyRegistrarActivate(Handle, _HKRT_NativeHotkey),
		"the same reservation must remain retryable")
}
Test("hotkey registrar: failed On restores the exact inert snapshot "
	. "(hotkey-on-throw-restores-reserved)",
	_HKRT_ActivateFailureRestoresExactReserve)

_HKRT_PublicBindFailureHasNoGhostAction() {
	global HOTKEY_REGISTRAR_SPECS, _HKRT_ThrowOnSpecs
	global _HKRT_FireBeforeActions, _HKRT_FirstCalls, _HKRT_AppDeliveries
	_HKRT_Reset()
	Spec := "^q"
	_HKRT_FireBeforeActions[Spec . " On"] := true
	_HKRT_ThrowOnSpecs[Spec] := true
	AssertEqual("", _HKRT_Bind("Ctrl+Q", _HKRT_First, "metrics:typing"))
	_HKRT_AssertEvents([Spec . " Off", Spec . " On"],
		"public bind failure must stop without a compensating Off")
	AssertEqual(0, _HKRT_FirstCalls,
		"a bind returning an empty handle must never publish ghost action authority")
	AssertEqual(1, _HKRT_AppDeliveries)
	AssertEqual(0, HotkeyRegistrarLiveCount())
	AssertEqual("retired", HOTKEY_REGISTRAR_SPECS[Spec]["state"]["phase"])
	_HKRT_PhysicalPress(Spec)
	AssertEqual(2, _HKRT_AppDeliveries,
		"the rejected disabled variant must continue passing physical input")
}
Test("hotkey registrar: public On refusal has no ghost action "
	. "(hotkey-public-bind-failure-no-ghost)",
	_HKRT_PublicBindFailureHasNoGhostAction)

_HKRT_OffFailureRestoresExactActiveState() {
	global HOTKEY_REGISTRAR_BINDINGS, _HKRT_Events
	global _HKRT_ThrowOffSpecs, _HKRT_FireBeforeActions
	global _HKRT_FirstCalls, _HKRT_AppDeliveries
	_HKRT_Reset()
	Handle := _HKRT_Bind("Ctrl+Space", _HKRT_First, "metrics:typing")
	Before := HOTKEY_REGISTRAR_BINDINGS[Handle]["state"]
	_HKRT_Events := []
	_HKRT_FireBeforeActions["^space Off"] := true
	_HKRT_ThrowOffSpecs["^space"] := true
	AssertFalse(_HotkeyRegistrarRetire(Handle, _HKRT_NativeHotkey))
	_HKRT_AssertEvents(["^space Off"],
		"failed retirement must issue no compensating native On")
	AssertTrue(HOTKEY_REGISTRAR_BINDINGS[Handle]["state"] == Before,
		"failed retirement must restore the exact active snapshot")
	AssertEqual(1, _HKRT_FirstCalls,
		"a press before refused Off must retain the published action authority")
	AssertEqual(0, _HKRT_AppDeliveries)
	_HKRT_ThrowOffSpecs.Delete("^space")
	AssertTrue(_HotkeyRegistrarRetire(Handle, _HKRT_NativeHotkey))
	_HKRT_PhysicalPress("^space")
	AssertEqual(1, _HKRT_AppDeliveries,
		"successful cleanup must restore application delivery")
}
Test("hotkey registrar: failed Off restores exact active authority "
	. "(hotkey-off-throw-restores-active)",
	_HKRT_OffFailureRestoresExactActiveState)

_HKRT_EnableFailureRestoresExactDisabledState() {
	global HOTKEY_REGISTRAR_BINDINGS, _HKRT_Events
	global _HKRT_ThrowOnSpecs, _HKRT_FireBeforeActions
	global _HKRT_FirstCalls, _HKRT_AppDeliveries
	_HKRT_Reset()
	Handle := _HKRT_Bind("Ctrl+E", _HKRT_First, "metrics:typing")
	AssertTrue(_HotkeyRegistrarSetEnabled(Handle, false, _HKRT_NativeHotkey))
	Before := HOTKEY_REGISTRAR_BINDINGS[Handle]["state"]
	_HKRT_Events := []
	Spec := HOTKEY_REGISTRAR_BINDINGS[Handle]["spec"]
	_HKRT_FireBeforeActions[Spec . " On"] := true
	_HKRT_ThrowOnSpecs[Spec] := true
	AssertFalse(_HotkeyRegistrarSetEnabled(Handle, true, _HKRT_NativeHotkey))
	_HKRT_AssertEvents([Spec . " On"],
		"failed enable must issue no compensating native Off")
	AssertTrue(HOTKEY_REGISTRAR_BINDINGS[Handle]["state"] == Before,
		"failed enable must restore the exact disabled snapshot")
	AssertEqual(0, _HKRT_FirstCalls,
		"failed enable must not expose desired action before native success")
	AssertEqual(1, _HKRT_AppDeliveries)
	_HKRT_ThrowOnSpecs.Delete(Spec)
	AssertTrue(_HotkeyRegistrarSetEnabled(Handle, true, _HKRT_NativeHotkey))
	_HKRT_PhysicalPress(Spec)
	AssertEqual(1, _HKRT_FirstCalls)
}
Test("hotkey registrar: failed enable restores exact disabled authority "
	. "(hotkey-enable-throw-restores-disabled)",
	_HKRT_EnableFailureRestoresExactDisabledState)

_HKRT_DisableFailureRestoresExactActiveState() {
	global HOTKEY_REGISTRAR_BINDINGS, _HKRT_Events
	global _HKRT_ThrowOffSpecs, _HKRT_FireBeforeActions
	global _HKRT_FirstCalls
	_HKRT_Reset()
	Handle := _HKRT_Bind("Ctrl+K", _HKRT_First, "metrics:typing")
	Before := HOTKEY_REGISTRAR_BINDINGS[Handle]["state"]
	_HKRT_Events := []
	Spec := HOTKEY_REGISTRAR_BINDINGS[Handle]["spec"]
	_HKRT_FireBeforeActions[Spec . " Off"] := true
	_HKRT_ThrowOffSpecs[Spec] := true
	AssertFalse(_HotkeyRegistrarSetEnabled(Handle, false, _HKRT_NativeHotkey))
	_HKRT_AssertEvents([Spec . " Off"],
		"failed disable must issue no compensating native On")
	AssertTrue(HOTKEY_REGISTRAR_BINDINGS[Handle]["state"] == Before)
	AssertEqual(1, _HKRT_FirstCalls,
		"failed Off must retain the prior published action authority")
	_HKRT_ThrowOffSpecs.Delete(Spec)
	AssertTrue(_HotkeyRegistrarSetEnabled(Handle, false, _HKRT_NativeHotkey))
}
Test("hotkey registrar: failed disable restores exact active authority "
	. "(hotkey-disable-throw-restores-active)",
	_HKRT_DisableFailureRestoresExactActiveState)

_HKRT_ReserveIdentityLossFailsFastAtEveryExit() {
	global _HKRT_NativeBindings, _HKRT_ThrowInstallSpecs
	global _HKRT_BeforeInstallHook, _HKRT_AfterInstallHook
	global _HKRT_BeforeProbeHook
	_HKRT_Reset()
	_HKRT_AfterInstallHook := _HKRT_CorruptClaimState
	AssertThrows(() => _HKRT_Reserve("Ctrl+F1", _HKRT_First),
		"reserve publication identity loss must fail fast")

	_HKRT_Reset()
	_HKRT_BeforeInstallHook := _HKRT_CorruptClaimState
	_HKRT_ThrowInstallSpecs["^f2"] := true
	AssertThrows(() => _HKRT_Reserve("Ctrl+F2", _HKRT_First),
		"reserve install-refusal rollback identity loss must fail fast")

	_HKRT_Reset()
	_HKRT_NativeBindings["^f3"] := { callback: _HKRT_First, enabled: true }
	_HKRT_BeforeProbeHook := _HKRT_CorruptClaimState
	AssertThrows(() => _HKRT_Reserve("Ctrl+F3", _HKRT_First),
		"occupied-probe rollback identity loss must fail fast")
}
Test("hotkey registrar: every reserve identity loss fails fast "
	. "(hotkey-reserve-identity-loss-fail-fast)",
	_HKRT_ReserveIdentityLossFailsFastAtEveryExit)

_HKRT_PublicationLossAfterNativeSuccessFailsFast() {
	global _HKRT_AfterActionHook
	_HKRT_Reset()
	Handle := _HKRT_Reserve("Ctrl+F4", _HKRT_First, "metrics:typing")
	AssertTrue(Handle != "")
	_HKRT_AfterActionHook := _HKRT_CorruptClaimState
	AssertThrows(() => _HotkeyRegistrarActivate(Handle, _HKRT_NativeHotkey),
		"activate publication identity loss must fail fast")

	_HKRT_Reset()
	Handle := _HKRT_Bind("Ctrl+F6", _HKRT_First, "metrics:typing")
	AssertTrue(Handle != "")
	_HKRT_AfterActionHook := _HKRT_CorruptClaimState
	AssertThrows(() => _HotkeyRegistrarRetire(Handle, _HKRT_NativeHotkey),
		"retire publication identity loss must fail fast")

	_HKRT_Reset()
	Handle := _HKRT_Bind("Ctrl+F8", _HKRT_First, "metrics:typing")
	AssertTrue(Handle != "")
	_HKRT_AfterActionHook := _HKRT_CorruptClaimState
	AssertThrows(() => _HotkeyRegistrarSetEnabled(Handle, false,
		_HKRT_NativeHotkey),
		"setEnabled publication identity loss must fail fast")
}
Test("hotkey registrar: every post-native publication loss fails fast "
	. "(hotkey-publication-loss-fail-fast)",
	_HKRT_PublicationLossAfterNativeSuccessFailsFast)

_HKRT_RollbackLossAfterNativeRefusalFailsFast() {
	global _HKRT_BeforeActionHook, _HKRT_ThrowOnSpecs, _HKRT_ThrowOffSpecs
	_HKRT_Reset()
	Handle := _HKRT_Reserve("Ctrl+F5", _HKRT_First, "metrics:typing")
	AssertTrue(Handle != "")
	_HKRT_BeforeActionHook := _HKRT_CorruptClaimState
	_HKRT_ThrowOnSpecs["^f5"] := true
	AssertThrows(() => _HotkeyRegistrarActivate(Handle, _HKRT_NativeHotkey),
		"activate rollback identity loss must fail fast")

	_HKRT_Reset()
	Handle := _HKRT_Bind("Ctrl+F7", _HKRT_First, "metrics:typing")
	AssertTrue(Handle != "")
	_HKRT_BeforeActionHook := _HKRT_CorruptClaimState
	_HKRT_ThrowOffSpecs["^f7"] := true
	AssertThrows(() => _HotkeyRegistrarRetire(Handle, _HKRT_NativeHotkey),
		"retire rollback identity loss must fail fast")

	_HKRT_Reset()
	Handle := _HKRT_Bind("Ctrl+F9", _HKRT_First, "metrics:typing")
	AssertTrue(Handle != "")
	_HKRT_BeforeActionHook := _HKRT_CorruptClaimState
	_HKRT_ThrowOffSpecs["^f9"] := true
	AssertThrows(() => _HotkeyRegistrarSetEnabled(Handle, false,
		_HKRT_NativeHotkey),
		"setEnabled rollback identity loss must fail fast")
}
Test("hotkey registrar: every failed native rollback identity loss fails fast "
	. "(hotkey-rollback-loss-fail-fast)",
	_HKRT_RollbackLossAfterNativeRefusalFailsFast)

_HKRT_OwnersCannotBeClobbered() {
	global HOTKEY_REGISTRAR_BINDINGS
	global _HKRT_NativeBindings, _HKRT_ProbeThrows
	global _HKRT_FirstCalls, _HKRT_SecondCalls
	_HKRT_Reset()
	FirstHandle := _HKRT_Bind("Ctrl+B", _HKRT_First, "keyboard:ctrl_b")
	AssertTrue(FirstHandle != "")
	AssertEqual("", _HKRT_Bind("Ctrl+B", _HKRT_Second, "llm:trigger"),
		"a second registrar owner must be refused")
	_HKRT_PhysicalPress(HOTKEY_REGISTRAR_BINDINGS[FirstHandle]["spec"])
	AssertEqual(1, _HKRT_FirstCalls)
	AssertEqual(0, _HKRT_SecondCalls)

	ForeignSpec := "^q"
	_HKRT_NativeBindings[ForeignSpec] := {
		callback: _HKRT_First, enabled: true }
	AssertEqual("", _HKRT_Bind("Ctrl+Q", _HKRT_Second, "metrics:apps"),
		"a foreign same-process variant must never be overwritten")
	_HKRT_ProbeThrows := true
	AssertEqual("", _HKRT_Bind("Ctrl+W", _HKRT_Second, "metrics:apps"),
		"an indeterminate native probe must fail closed")
}
Test("hotkey registrar: active and foreign owners are never clobbered",
	_HKRT_OwnersCannotBeClobbered)

_HKRT_TextualForeignVariantSurvivesFrozenAdmission() {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global _HKRT_NativeBindings, _HKRT_ProbeCalls, _HKRT_ProbeNames
	global _HKRT_Events
	Descriptor := HotkeyRegistrarResolvedNativeDescriptor("^v",
		_HKRT_LetterVResolver)
	AssertTrue(HotkeyRegistrarResolvedDescriptorIsValid(Descriptor))
	AssertEqual("^vk56", Descriptor["native_spec"])

	for RawSpec in ["~^v", "$^v"] {
		_HKRT_Reset()
		Foreign := { callback: _HKRT_First, enabled: true }
		_HKRT_NativeBindings[RawSpec] := Foreign
		Handle := _HotkeyRegistrarReserveResolvedOwned("Ctrl+V",
			_HKRT_Second, "llm:trigger", Descriptor,
			_HKRT_NativeHotkey, _HKRT_AliasAwareProbe)
		AssertEqual("", Handle,
			"frozen admission must see raw owner " . RawSpec)
		AssertEqual(0, HOTKEY_REGISTRAR_BINDINGS.Count)
		AssertEqual(0, HOTKEY_REGISTRAR_SPECS.Count,
			"an occupied textual alias must leave no frozen phantom claim")
		AssertEqual(1, _HKRT_ProbeCalls,
			"the textual spelling must be probed before the frozen spelling")
		AssertEqual(1, _HKRT_ProbeNames.Length)
		AssertEqual("^v", _HKRT_ProbeNames[1],
			"the probe must use the permanent textual suffix, without ~/\$")
		AssertEqual(0, _HKRT_Events.Length,
			"textual-owner refusal must happen before native mutation")
		AssertTrue(_HKRT_NativeBindings.Has(RawSpec))
		AssertTrue(_HKRT_NativeBindings[RawSpec] == Foreign,
			"the raw textual producer must retain exact callback authority")
		AssertFalse(_HKRT_NativeBindings.Has("^vk56"))
	}
}
Test("hotkey registrar: frozen specs still probe textual native owners "
	. "(hotkey-frozen-textual-owner-probe)",
	_HKRT_TextualForeignVariantSurvivesFrozenAdmission)

_HKRT_GenericAltGrCharacterKeepsTextualContract() {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global _HKRT_NativeBindings
	_HKRT_Reset()
	Handle := _HotkeyRegistrarReserveOwned("@", _HKRT_First,
		"metrics:typing", _HKRT_NativeHotkey, _HKRT_Probe)
	AssertTrue(Handle != "",
		"the generic registrar must preserve valid AltGr character shortcuts")
	Entry := HOTKEY_REGISTRAR_BINDINGS[Handle]
	AssertEqual("@", Entry["display_spec"])
	AssertEqual("@", Entry["spec"],
		"an intentionally unrepresentable generic character must stay textual")
	AssertEqual("", Entry["physical_identity"])
	AssertTrue(HOTKEY_REGISTRAR_SPECS.Has("@"))
	AssertTrue(_HKRT_NativeBindings.Has("@"))
	_HKRT_AssertEvents(["@ Off"],
		"generic AltGr reserve must use the original textual spec")
	AssertTrue(_HotkeyRegistrarActivate(Handle, _HKRT_NativeHotkey))
	_HKRT_AssertEvents(["@ Off", "@ On"],
		"generic AltGr activation must retain the original textual spec")
}
Test("hotkey registrar: generic AltGr characters retain textual registration "
	. "(hotkey-generic-altgr-textual-contract)",
	_HKRT_GenericAltGrCharacterKeepsTextualContract)

_HKRT_EmptyOwnerStillOwnsItsExactSpec() {
	global _HKRT_FirstCalls, _HKRT_SecondCalls
	_HKRT_Reset()
	FirstHandle := _HKRT_Bind("Ctrl+F12", _HKRT_First, "")
	AssertTrue(FirstHandle != "")
	AssertEqual("", _HKRT_Bind("Ctrl+F12", _HKRT_Second, "llm:trigger"),
		"an empty diagnostic owner label must not mean unowned")
	_HKRT_PhysicalPress("^f12")
	AssertEqual(1, _HKRT_FirstCalls)
	AssertEqual(0, _HKRT_SecondCalls)
}
Test("hotkey registrar: empty owner labels still own their exact native spec "
	. "(hotkey-empty-owner-still-conflicts)",
	_HKRT_EmptyOwnerStillOwnsItsExactSpec)

_HKRT_RetireKeepsOwnershipUntilNativeOffReturns() {
	global HOTKEY_REGISTRAR_BINDINGS
	global _HKRT_BeforeActionHook, _HKRT_ReentrantHandle, _HKRT_SecondCalls
	_HKRT_Reset()
	Handle := _HKRT_Bind("Ctrl+R", _HKRT_First, "metrics:typing")
	AssertTrue(Handle != "")
	_HKRT_BeforeActionHook := _HKRT_AttemptReentrantBind
	AssertTrue(_HotkeyRegistrarRetire(Handle, _HKRT_NativeHotkey))
	AssertEqual("", _HKRT_ReentrantHandle,
		"retiring ownership must reject a replacement until native Off returns")
	Replacement := _HKRT_Bind("Ctrl+R", _HKRT_Second, "llm:trigger")
	AssertTrue(Replacement != "")
	_HKRT_PhysicalPress(HOTKEY_REGISTRAR_BINDINGS[Replacement]["spec"])
	AssertEqual(1, _HKRT_SecondCalls)
}
Test("hotkey registrar: native Off cannot disable a reentrant replacement",
	_HKRT_RetireKeepsOwnershipUntilNativeOffReturns)

_HKRT_GlobalHotIfContextIsExplicit() {
	global HOTKEY_REGISTRAR_BINDINGS
	global _HKRT_HotIfContext, _HKRT_HotIfCalls
	global _HKRT_FirstCalls, _HKRT_AppDeliveries
	_HKRT_Reset()
	_HKRT_HotIfContext := "contextual-bind"
	Handle := _HKRT_Bind("Ctrl+G", _HKRT_First, "metrics:typing",
		_HKRT_ContextCheckedHotkey, _HKRT_ContextCheckedProbe,
		_HKRT_SelectGlobalHotIf)
	AssertTrue(Handle != "")
	Spec := HOTKEY_REGISTRAR_BINDINGS[Handle]["spec"]
	AssertEqual("global", _HKRT_HotIfContext,
		"bind must deliberately leave global HotIf selected")
	_HKRT_HotIfContext := "outside-context"
	_HKRT_PhysicalPress(Spec)
	AssertEqual(1, _HKRT_FirstCalls,
		"the global variant must fire outside the caller's former context")
	_HKRT_HotIfContext := "contextual-unbind"
	AssertTrue(_HotkeyRegistrarRetire(Handle, _HKRT_ContextCheckedHotkey,
		_HKRT_SelectGlobalHotIf))
	AssertEqual("global", _HKRT_HotIfContext)
	AssertTrue(_HKRT_HotIfCalls >= 4,
		"probe, reserve, activate and retire must each select global HotIf")
	_HKRT_PhysicalPress(Spec)
	AssertEqual(1, _HKRT_AppDeliveries)
}
Test("hotkey registrar: native operations ignore inherited HotIf context "
	. "(hotkey-global-hotif-context)", _HKRT_GlobalHotIfContextIsExplicit)

_HKRT_CanonicalAliasesHaveOneExactOwner() {
	global _HKRT_FirstCalls
	_HKRT_Reset()
	AssertEqual("^!+#f9",
		HotkeyRegistrarNativeSpec(["cmd", "shift", "alt", "ctrl", "ctrl"], "F9"),
		"native modifier order must be ctrl, alt, shift, win")
	for Pair in [
		["Esc", "Escape", "^escape"],
		["Return", "Enter", "^enter"],
		["BS", "Backspace", "^backspace"],
		["Del", "Delete", "^delete"],
		["Ins", "Insert", "^insert"]
	] {
		AssertEqual(Pair[3], HotkeyRegistrarNativeSpec(["ctrl"], Pair[1]))
		AssertEqual(Pair[3], HotkeyRegistrarNativeSpec(["ctrl"], Pair[2]))
	}
	Handle := _HKRT_Bind("Ctrl+Esc", _HKRT_First, "metrics:typing")
	AssertTrue(Handle != "")
	AssertEqual("Ctrl+Escape", HotkeyRegistrarChordOf(Handle))
	AssertEqual("", _HKRT_Bind("Ctrl+Escape", _HKRT_Second, "llm:trigger"),
		"canonical aliases must not create sibling exact-spec owners")
	_HKRT_PhysicalPress("^escape")
	AssertEqual(1, _HKRT_FirstCalls)
}
Test("hotkey registrar: canonical aliases and modifier order share one exact owner "
	. "(hotkey-canonical-alias-single-owner)",
	_HKRT_CanonicalAliasesHaveOneExactOwner)

_HKRT_GenericStaysTextualAndResolvedFreezesNativeSpec() {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	Descriptor := HotkeyRegistrarResolvedNativeDescriptor("^n",
		_HKRT_LetterNResolver)
	AssertTrue(HotkeyRegistrarResolvedDescriptorIsValid(Descriptor))
	AssertEqual("^n", Descriptor["logical_spec"])
	AssertEqual("^vk4E", Descriptor["native_spec"])
	AssertEqual("^vk004E", Descriptor["identity"])

	_HKRT_Reset()
	Generic := _HKRT_Reserve("Ctrl+N", _HKRT_First, "metrics:typing")
	AssertTrue(Generic != "")
	GenericEntry := HOTKEY_REGISTRAR_BINDINGS[Generic]
	AssertEqual("^n", GenericEntry["spec"],
		"the generic registrar must retain its established textual contract")
	AssertEqual("^n", GenericEntry["display_spec"])
	AssertEqual("", GenericEntry["physical_identity"])
	AssertEqual("", HotkeyRegistrarPhysicalIdentityOf(Generic))
	AssertTrue(_HotkeyRegistrarActivate(Generic, _HKRT_NativeHotkey))
	AssertTrue(_HotkeyRegistrarSetEnabled(Generic, false, _HKRT_NativeHotkey))
	AssertTrue(_HotkeyRegistrarSetEnabled(Generic, true, _HKRT_NativeHotkey))
	AssertTrue(_HotkeyRegistrarRetire(Generic, _HKRT_NativeHotkey))
	_HKRT_AssertEvents(["^n Off", "^n On", "^n Off", "^n On", "^n Off"],
		"the complete generic lifecycle must retain the textual native spec")
	AssertTrue(HOTKEY_REGISTRAR_SPECS.Has("^n"))
	AssertEqual("retired",
		HOTKEY_REGISTRAR_SPECS["^n"]["state"]["phase"])
	AssertFalse(HOTKEY_REGISTRAR_SPECS.Has("^vk4E"))

	_HKRT_Reset()
	Strict := _HotkeyRegistrarReserveResolvedOwned("Ctrl+N", _HKRT_First,
		"llm:trigger", Descriptor, _HKRT_NativeHotkey, _HKRT_Probe)
	AssertTrue(Strict != "")
	StrictEntry := HOTKEY_REGISTRAR_BINDINGS[Strict]
	AssertEqual("^vk4E", StrictEntry["spec"],
		"the strict LLM seam must reserve the frozen descriptor spec")
	AssertEqual("^n", StrictEntry["display_spec"])
	AssertEqual("^vk004E", StrictEntry["physical_identity"])
	AssertEqual("^vk004E", HotkeyRegistrarPhysicalIdentityOf(Strict))
	Descriptor["native_spec"] := "^q"
	Descriptor["logical_spec"] := "^q"
	Descriptor["identity"] := "^vk0051"
	AssertTrue(_HotkeyRegistrarActivate(Strict, _HKRT_NativeHotkey))
	AssertTrue(_HotkeyRegistrarSetEnabled(Strict, false, _HKRT_NativeHotkey))
	AssertTrue(_HotkeyRegistrarSetEnabled(Strict, true, _HKRT_NativeHotkey))
	AssertTrue(_HotkeyRegistrarRetire(Strict, _HKRT_NativeHotkey))
	_HKRT_AssertEvents(["^vk4E Off", "^vk4E On", "^vk4E Off", "^vk4E On",
		"^vk4E Off"],
		"the complete strict lifecycle must retain its copied descriptor spec")
	AssertTrue(HOTKEY_REGISTRAR_SPECS.Has("^vk4E"))
	AssertEqual("retired", StrictEntry["state"]["phase"])
	AssertEqual("^vk004E", StrictEntry["physical_identity"],
		"descriptor mutation must not alter copied identity metadata")
	AssertFalse(HOTKEY_REGISTRAR_SPECS.Has("^n"))
}
Test("hotkey registrar: generic specs stay textual and strict specs freeze "
	. "(hotkey-generic-textual-strict-frozen)",
	_HKRT_GenericStaysTextualAndResolvedFreezesNativeSpec)

_HKRT_LogicalAliasAdmissionIsBidirectional() {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global HOTKEY_REGISTRAR_NEXT_TOKEN
	global _HKRT_NativeBindings, _HKRT_ProbeCalls, _HKRT_Events
	Descriptor := HotkeyRegistrarResolvedNativeDescriptor("^n",
		_HKRT_LetterNResolver)
	AssertTrue(HotkeyRegistrarResolvedDescriptorIsValid(Descriptor))
	AssertEqual("^n", Descriptor["logical_spec"])
	AssertEqual("^vk4E", Descriptor["native_spec"])

	_HKRT_Reset()
	Generic := _HKRT_Reserve("Ctrl+N", _HKRT_First, "metrics:typing")
	AssertTrue(Generic != "")
	BeforeToken := HOTKEY_REGISTRAR_NEXT_TOKEN
	BeforeSpecs := HOTKEY_REGISTRAR_SPECS.Count
	BeforeNative := _HKRT_NativeBindings.Count
	BeforeProbe := _HKRT_ProbeCalls
	BeforeEvents := _HKRT_Events.Length
	AssertEqual("", _HotkeyRegistrarReserveResolvedOwned("Ctrl+N",
		_HKRT_Second, "llm:trigger", Descriptor, _HKRT_NativeHotkey,
		_HKRT_Probe),
		"a frozen alias must not bypass an existing textual reservation")
	AssertEqual(BeforeToken, HOTKEY_REGISTRAR_NEXT_TOKEN)
	AssertEqual(BeforeSpecs, HOTKEY_REGISTRAR_SPECS.Count)
	AssertEqual(BeforeNative, _HKRT_NativeBindings.Count)
	AssertEqual(BeforeProbe, _HKRT_ProbeCalls,
		"frozen-alias refusal must happen before the native probe")
	AssertEqual(BeforeEvents, _HKRT_Events.Length)
	AssertTrue(HOTKEY_REGISTRAR_BINDINGS[Generic]
		== HOTKEY_REGISTRAR_SPECS["^n"])

	_HKRT_Reset()
	Strict := _HotkeyRegistrarReserveResolvedOwned("Ctrl+N", _HKRT_First,
		"llm:trigger", Descriptor, _HKRT_NativeHotkey, _HKRT_Probe)
	AssertTrue(Strict != "")
	BeforeToken := HOTKEY_REGISTRAR_NEXT_TOKEN
	BeforeSpecs := HOTKEY_REGISTRAR_SPECS.Count
	BeforeNative := _HKRT_NativeBindings.Count
	BeforeProbe := _HKRT_ProbeCalls
	BeforeEvents := _HKRT_Events.Length
	AssertEqual("", _HKRT_Reserve("Ctrl+N", _HKRT_Second,
		"metrics:typing"),
		"a textual reservation must not bypass an existing frozen alias")
	AssertEqual(BeforeToken, HOTKEY_REGISTRAR_NEXT_TOKEN)
	AssertEqual(BeforeSpecs, HOTKEY_REGISTRAR_SPECS.Count)
	AssertEqual(BeforeNative, _HKRT_NativeBindings.Count)
	AssertEqual(BeforeProbe, _HKRT_ProbeCalls)
	AssertEqual(BeforeEvents, _HKRT_Events.Length)
	AssertTrue(HOTKEY_REGISTRAR_BINDINGS[Strict]
		== HOTKEY_REGISTRAR_SPECS["^vk4E"])
}
Test("hotkey registrar: textual and frozen logical aliases serialize "
	. "(hotkey-textual-frozen-alias-admission)",
	_HKRT_LogicalAliasAdmissionIsBidirectional)

_HKRT_ExplicitScanCodeAliasesUseTheScanCodeAxis() {
	global _HKRT_GetVkCalls, _HKRT_GetScCalls
	Port := Map("get_vk", _HKRT_ExplicitAliasGetVk,
		"get_sc", _HKRT_ExplicitAliasGetSc)
	Resolver := _HotkeyRegistrarResolveNativeKeyIdentityAtLayout.Bind(0x0409,
		Port)
	ExplicitKey := Resolver.Call("SC148")
	AssertTrue(ExplicitKey is Map)
	AssertEqual("sc", ExplicitKey["axis"],
		"an explicit SC suffix must never be reinterpreted through GetKeyVK")
	AssertEqual(0x148, ExplicitKey["code"])
	AssertEqual(0, _HKRT_GetVkCalls)
	AssertEqual(0, _HKRT_GetScCalls,
		"a numeric SC suffix already carries its complete physical identity")
	NamedKey := Resolver.Call("Up")
	AssertEqual("sc", NamedKey["axis"])
	AssertEqual(0x148, NamedKey["code"])
	AssertEqual(1, _HKRT_GetScCalls)

	ExplicitDescriptor := HotkeyRegistrarResolvedNativeDescriptor("^SC148",
		Resolver)
	NamedDescriptor := HotkeyRegistrarResolvedNativeDescriptor("^up", Resolver)
	AssertTrue(HotkeyRegistrarResolvedDescriptorIsValid(ExplicitDescriptor))
	AssertTrue(HotkeyRegistrarResolvedDescriptorIsValid(NamedDescriptor))
	AssertEqual("^sc0148", ExplicitDescriptor["identity"])
	AssertEqual("^sc0148", NamedDescriptor["identity"])
}
Test("hotkey registrar: explicit SC aliases keep the scan-code axis "
	. "(hotkey-explicit-sc-axis)",
	_HKRT_ExplicitScanCodeAliasesUseTheScanCodeAxis)

_HKRT_ResolvedDescriptorMustMatchChord() {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global HOTKEY_REGISTRAR_NEXT_TOKEN
	global _HKRT_NativeBindings, _HKRT_Events, _HKRT_ProbeCalls
	_HKRT_Reset()
	Six := HotkeyRegistrarResolvedNativeDescriptor("^6", _HKRT_DigitResolver)
	AssertTrue(HotkeyRegistrarResolvedDescriptorIsValid(Six))
	AssertEqual("^6", Six["logical_spec"])
	AssertEqual("^vk36", Six["native_spec"])
	AssertEqual("", _HotkeyRegistrarReserveResolvedOwned("Ctrl+5",
		_HKRT_First, "llm:trigger", Six, _HKRT_NativeHotkey, _HKRT_Probe),
		"a valid descriptor for a different chord must fail closed")
	AssertEqual(0, HOTKEY_REGISTRAR_NEXT_TOKEN)
	AssertEqual(0, HOTKEY_REGISTRAR_BINDINGS.Count)
	AssertEqual(0, HOTKEY_REGISTRAR_SPECS.Count)
	AssertEqual(0, _HKRT_NativeBindings.Count)
	AssertEqual(0, _HKRT_Events.Length)
	AssertEqual(0, _HKRT_ProbeCalls)
}
Test("hotkey registrar: resolved descriptor must match its chord "
	. "(hotkey-resolved-descriptor-chord-match)",
	_HKRT_ResolvedDescriptorMustMatchChord)

_HKRT_DispatchHasNoCriticalSpan() {
	Body := _DriverFuncBody("_HotkeyRegistrarDispatch")
	Assert(Body != "", "dispatcher source must be discoverable")
	Assert(InStr(Body, "Critical(") = 0,
		"dispatch must read one immutable snapshot without entering Critical")
	Assert(InStr(Body, 'Snapshot := Entry["state"]') > 0,
		"dispatch must capture authority exactly once")
	Assert(InStr(Body, "Callback.Call()") > 0,
		"the transport-neutral public callback must be invoked with zero arguments")
	Assert(InStr(Body, "Callback.Call(Args*)") = 0,
		"native AHK arguments must never leak through the public port")
}
Test("hotkey registrar: dispatch reads one snapshot without Critical "
	. "(hotkey-dispatch-no-critical)", _HKRT_DispatchHasNoCriticalSpan)

_HKRT_NativeCallsAreOutsideCriticalAndUncompensated() {
	for Name in ["_HotkeyRegistrarReserveOwned", "_HotkeyRegistrarActivate",
		"_HotkeyRegistrarRetire", "_HotkeyRegistrarSetEnabled"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " source must be discoverable")
		RestorePos := InStr(Body, "Critical(PreviousCritical)")
		NativePos := InStr(Body, Name == "_HotkeyRegistrarReserveOwned"
			? "_HotkeyRegistrarNativeExists" : "_HotkeyRegistrarInvokeAction")
		Assert(RestorePos > 0 && NativePos > RestorePos,
			Name . " must leave Critical before its first native call")
	}
	AssertEqual(1, _HKRT_CountNeedle(
		_DriverFuncBody("_HotkeyRegistrarActivate"),
		"_HotkeyRegistrarInvokeAction("),
		"activation must issue exactly one native action")
	AssertEqual(1, _HKRT_CountNeedle(
		_DriverFuncBody("_HotkeyRegistrarRetire"),
		"_HotkeyRegistrarInvokeAction("),
		"retirement must not contain compensating native calls")
	AssertEqual(1, _HKRT_CountNeedle(
		_DriverFuncBody("_HotkeyRegistrarSetEnabled"),
		"_HotkeyRegistrarInvokeAction("),
		"setEnabled must not contain compensating native calls")
}
Test("hotkey registrar: native calls stay outside Critical without compensation "
	. "(hotkey-native-exception-atomic)",
	_HKRT_NativeCallsAreOutsideCriticalAndUncompensated)

_HKRT_NativeSeamsSelectGlobalHotIf() {
	SelectorBody := _DriverFuncBody("_HotkeyRegistrarSelectGlobalContext")
	InvokeBody := _DriverFuncBody("_HotkeyRegistrarInvoke")
	ActionBody := _DriverFuncBody("_HotkeyRegistrarInvokeAction")
	ProbeBody := _DriverFuncBody("_HotkeyRegistrarNativeExists")
	for Body in [SelectorBody, InvokeBody, ActionBody, ProbeBody]
		Assert(Body != "", "every native-seam source body must be discoverable")
	Assert(InStr(SelectorBody, "HotIf()") > 0)
	Assert(InStr(InvokeBody, "_HotkeyRegistrarSelectGlobalContext") > 0)
	Assert(InStr(ActionBody, "_HotkeyRegistrarSelectGlobalContext") > 0)
	Assert(InStr(ProbeBody, "_HotkeyRegistrarSelectGlobalContext") > 0)
}
Test("hotkey registrar: every native seam selects unconditional HotIf "
	. "(hotkey-global-hotif-structural)", _HKRT_NativeSeamsSelectGlobalHotIf)

_HKRT_ChordLookupIsAtomic() {
	Body := _DriverFuncBody("HotkeyRegistrarChordOf")
	Assert(Body != "", "ChordOf source must be discoverable")
	Assert(InStr(Body, 'Critical("On")') > 0,
		"ChordOf must fence Has()+index against concurrent unbind")
	Assert(InStr(Body, 'Entry := HOTKEY_REGISTRAR_BINDINGS[handle]') > 0)
	Assert(InStr(Body, 'return HOTKEY_REGISTRAR_BINDINGS[handle]') = 0,
		"ChordOf must not perform a second preemptable map lookup")
}
Test("hotkey registrar: chord lookup snapshots atomically "
	. "(hotkey-chordof-atomic)", _HKRT_ChordLookupIsAtomic)
