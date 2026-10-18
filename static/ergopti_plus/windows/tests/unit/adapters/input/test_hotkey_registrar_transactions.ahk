; tests/unit/adapters/input/test_hotkey_registrar_transactions.ahk

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
