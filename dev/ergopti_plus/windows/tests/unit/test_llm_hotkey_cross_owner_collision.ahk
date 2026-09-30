; tests/unit/test_llm_hotkey_cross_owner_collision.ahk

; ==============================================================================
; MODULE: LLM Cross-Owner Hotkey Collision Tests
; DESCRIPTION:
; Behavioural regression coverage for AHK-027. The contextual LLM hotkeys
; (Ctrl+1..9 profiles, prediction navigation) resolve every chord to one frozen
; native spec and physical identity per keyboard layout, so two spellings of
; one physical chord are one owner and a later layout switch cannot split or
; reparse a published generation.
; ==============================================================================

#Requires AutoHotkey v2.0

global _LHCC_NavHotkeyCalls := 0
global _LHCC_NavHotIfCalls := 0
global _LHCC_NavResetCalls := 0
global _LHCC_ContextualRoutingCompleted := false
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
global _LHCC_Native := Map()
global _LHCC_NativeEvents := []
global _LHCC_ProbeCalls := 0





; ====================================
; ====================================
; ======= 1/ Fake Native Owner =======
; ====================================
; ====================================

_LHCC_ResetNative() {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global HOTKEY_REGISTRAR_NEXT_TOKEN
	global _LHCC_Native, _LHCC_NativeEvents, _LHCC_ProbeCalls
	HOTKEY_REGISTRAR_BINDINGS := Map()
	HOTKEY_REGISTRAR_SPECS := Map()
	HOTKEY_REGISTRAR_NEXT_TOKEN := 0
	_LHCC_Native := Map()
	_LHCC_NativeEvents := []
	_LHCC_ProbeCalls := 0
}

; AHK Hotkey registration is exception-atomic, so every injected failure
; happens before this fake mutates a callback or an enabled state.
_LHCC_Hotkey(Name, Action := unset, Options := unset) {
	global _LHCC_Native, _LHCC_NativeEvents
	if !IsSet(Action)
		return _LHCC_Native.Has(Name)
	if IsSet(Options) {
		_LHCC_NativeEvents.Push(Name . " " . Options)
		if (Options != "Off" && Options != "On")
			throw Error("unexpected fake Hotkey registration option")
		_LHCC_Native[Name] := { callback: Action, enabled: Options = "On" }
		return true
	}
	if (Action = "Off" || Action = "On") {
		_LHCC_NativeEvents.Push(Name . " " . Action)
		if _LHCC_Native.Has(Name)
			_LHCC_Native[Name].enabled := (Action = "On")
		return true
	}
	throw Error("unexpected fake Hotkey action")
}

_LHCC_Probe(Name) {
	global _LHCC_Native, _LHCC_ProbeCalls
	_LHCC_ProbeCalls += 1
	return _LHCC_Native.Has(Name)
}

; Deliberately zero-arity: the shared registrar port hides AHK's native
; HotkeyName argument instead of requiring every consumer to accept Args*.
_LHCC_Callback() {
}

_LHCC_AssertNativeEvents(Expected, Message) {
	global _LHCC_NativeEvents
	AssertEqual(Expected.Length, _LHCC_NativeEvents.Length,
		Message . " (event count)")
	for Index, Event in Expected
		AssertEqual(Event, _LHCC_NativeEvents[Index],
			Message . " (event " . Index . ")")
}

_LHCC_FailFrozenReserve(Name, Action := unset, Options := unset) {
	global _LHCC_FrozenReserveFailure
	if _LHCC_FrozenReserveFailure && IsSet(Options) && Options == "Off"
			&& Name == "^+vk35"
		throw Error("injected frozen-spec reserve refusal")
	if !IsSet(Action)
		return _LHCC_Hotkey(Name)
	if !IsSet(Options)
		return _LHCC_Hotkey(Name, Action)
	return _LHCC_Hotkey(Name, Action, Options)
}

; The registrar tables are process-wide: each case starts empty and gives the
; suite its own tables back.
_LHCC_WithNativeRegistrar(TestFn) {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global HOTKEY_REGISTRAR_NEXT_TOKEN
	SavedBindings := HOTKEY_REGISTRAR_BINDINGS
	SavedSpecs := HOTKEY_REGISTRAR_SPECS
	SavedToken := HOTKEY_REGISTRAR_NEXT_TOKEN
	_LHCC_ResetNative()
	try return TestFn.Call()
	finally {
		HOTKEY_REGISTRAR_BINDINGS := SavedBindings
		HOTKEY_REGISTRAR_SPECS := SavedSpecs
		HOTKEY_REGISTRAR_NEXT_TOKEN := SavedToken
	}
}





; ======================================
; ======================================
; ======= 2/ Deterministic State =======
; ======================================
; ======================================

_LHCC_ResetNavBoundaryCounters() {
	global _LHCC_NavHotkeyCalls, _LHCC_NavHotIfCalls, _LHCC_NavResetCalls
	_LHCC_NavHotkeyCalls := 0
	_LHCC_NavHotIfCalls := 0
	_LHCC_NavResetCalls := 0
}

_LHCC_EventCount(Events, Expected) {
	Count := 0
	for Event in Events {
		if Event == Expected
			Count += 1
	}
	return Count
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

_LHCC_InstallReservedMenuState() {
	global _LLM_Menu, _LLM_Menu_ProfileHotkeyOwner
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavSlotPlans
	global _LLM_Menu_NavActiveSlot
	_LLM_Menu["nav_modifiers"] := "alt"
	_LLM_Menu["val_modifiers"] := "ctrl+alt"
	_LLM_Menu_ProfileHotkeyOwner := 0
	_LLM_Menu_NavHotkeysBound := []
	_LLM_Menu_NavSlotPlans := Map(1, [], 2, [])
	_LLM_Menu_NavActiveSlot := 0
}

_LHCC_WithOwnerState(TestFn) {
	global _LLM_Menu, _LLM_Menu_ProfileHotkeyOwner
	global _LLM_Menu_ProfileHotkeyFailureCount
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavSlotPlans
	global _LLM_Menu_NavActiveSlot, LLM_PROFILE_HOTKEY_LIMIT
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
		return _LHCC_WithNativeRegistrar(TestFn)
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
		_LHCC_FrozenReserveFailure := false
	}
}

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

; Up and Down resolved to one key: two navigation routes, one physical owner.
; A digit cannot collide this way any more, since the plan names every digit
; by its own digit-row key (_LLM_Menu_NavDigitRowKey).
_LHCC_NavDuplicatePhysicalKey(Key) {
	if StrLower(Key) == "down"
		return _LHCC_UsPhysicalKey("up")
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





; ====================================
; ====================================
; ======= 3/ Physical Identity =======
; ====================================
; ====================================

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
	AssertEqual("", _LLM_Menu_HotkeyPhysicalIdentity("^5", MalformedResolver),
		"malformed physical resolution must fail closed")
}
Test("[llm-hotkey-collision] policy resolves layout-dependent physical aliases",
	_LHCC_LayoutAwarePhysicalIdentities)

_LHCC_FrozenSpecsKeepBindingLayoutCore() {
	global _LLM_Menu, _LLM_Menu_ProfileHotkeyOwner
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavActiveSlot
	global _LPHT_Hotkeys, _LNHT_Hotkeys

	; A profile generation parsed under French AZERTY owns Ctrl+Shift+VK35 for
	; its textual ^5 variant. Hotkey() receives that frozen spec, so a later
	; layout switch cannot reparse ^5 into a different physical chord.
	_LHCC_InstallReservedMenuState()
	_LPHT_ResetPorts()
	ProfileBindStatus := LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
		_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset, _LPHT_Select,
		_LHCC_FrenchPhysicalKey)
	AssertTrue((ProfileBindStatus is Integer) && ProfileBindStatus == 1)
	AssertTrue(_LLM_Menu_ProfileHotkeyOwnerReady())
	ProfileFive := _LLM_Menu_ProfileHotkeyOwner["plan"][5]
	AssertEqual("^5", ProfileFive["spec"])
	AssertEqual("^+vk35", ProfileFive["native_spec"])
	AssertEqual("^+vk35", ProfileFive["native_id"])
	AssertEqual("^+vk0035", ProfileFive["physical_id"])
	AssertTrue(_LPHT_Hotkeys.Has("^+vk35"))
	AssertFalse(_LPHT_Hotkeys.Has("^5"),
		"profile Hotkey() must never reparse the logical digit after admission")

	; The navigation generation freezes too, but its digit is the digit-row
	; key: the Shift the French layout needs to type 5 is no part of the
	; validation chord, which is the key labelled 5, as on macOS and Linux
	; (llm-accept-inserts).
	_LHCC_InstallReservedMenuState()
	_LLM_Menu["val_modifiers"] := "alt"
	_LNHT_Reset()
	_LHCC_ResetNavBoundaryCounters()
	NavStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu,
		_LHCC_NavHotkey, _LHCC_NavHotIf, _LNHT_Log, _LHCC_NavReset,
		_LHCC_FrenchPhysicalKey)
	AssertTrue((NavStatus is Integer) && NavStatus == 1)
	PublishedFive := false
	for Entry in _LLM_Menu_NavHotkeysBound {
		if Entry.Get("spec", "") == "!5" {
			PublishedFive := Entry
			break
		}
	}
	AssertTrue(PublishedFive is Map)
	AssertEqual("!vk35", PublishedFive["native_spec"])
	AssertEqual("!vk35", PublishedFive["native_id"])
	AssertEqual("!vk0035", PublishedFive["physical_id"])
	AssertTrue(_LNHT_Hotkeys.Has(_LLM_Menu_NavActiveSlot . "|!vk35"))
	AssertFalse(_LNHT_Hotkeys.Has(_LLM_Menu_NavActiveSlot . "|!+vk35"),
		"the layout's Shift for the character 5 must not join the validation chord")
	AssertFalse(_LNHT_Hotkeys.Has(_LLM_Menu_NavActiveSlot . "|!5"),
		"navigation Hotkey() must receive only the frozen explicit VK spec")
	return true
}

_LHCC_FrozenSpecsKeepBindingLayout() {
	Result := _LHCC_WithOwnerState(_LHCC_FrozenSpecsKeepBindingLayoutCore)
	AssertTrue((Result is Integer) && Result == 1,
		"the frozen-spec fixture must reach every terminal assertion")
}
Test("[llm-hotkey-collision] native owners retain their registration layout",
	_LHCC_FrozenSpecsKeepBindingLayout)

_LHCC_ResolvedDescriptorsFreezeNativeOwnersCore() {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global HOTKEY_REGISTRAR_NEXT_TOKEN
	global _LHCC_Native, _LHCC_NativeEvents, _LHCC_ProbeCalls
	global _LHCC_FrozenReserveFailure
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

	_LHCC_NativeEvents := []
	TokenBefore := HOTKEY_REGISTRAR_NEXT_TOKEN
	FrozenFive := Five.Clone()
	Handle := _HotkeyRegistrarReserveResolvedOwned("Ctrl+5",
		_LHCC_Callback, "llm:descriptor", Five, _LHCC_Hotkey, _LHCC_Probe)
	AssertTrue(Handle != "")
	AssertEqual(TokenBefore + 1, HOTKEY_REGISTRAR_NEXT_TOKEN)
	AssertTrue(HOTKEY_REGISTRAR_BINDINGS.Has(Handle))
	Entry := HOTKEY_REGISTRAR_BINDINGS[Handle]
	AssertEqual("^5", Entry["display_spec"])
	AssertEqual("^+vk35", Entry["spec"])
	AssertEqual("^+vk0035", Entry["physical_identity"])
	AssertFalse(Entry.Has("resolver"),
		"published registrar owners must retain only immutable descriptor scalars")
	AssertTrue(_LHCC_Native.Has("^+vk35"))
	AssertFalse(_LHCC_Native.Has("^5"))
	Five["logical_spec"] := "^6"
	Five["native_spec"] := "^vk36"
	Five["identity"] := "^vk0036"
	Five["code"] := 0x36
	Five["implicit_modifiers"] := ""
	AssertTrue(_HotkeyRegistrarActivate(Handle, _LHCC_Hotkey))
	AssertTrue(_HotkeyRegistrarSetEnabled(Handle, false, _LHCC_Hotkey))
	AssertTrue(_HotkeyRegistrarSetEnabled(Handle, true, _LHCC_Hotkey))
	AssertTrue(_HotkeyRegistrarRetire(Handle, _LHCC_Hotkey))
	_LHCC_AssertNativeEvents(["^+vk35 Off", "^+vk35 On", "^+vk35 Off",
		"^+vk35 On", "^+vk35 Off"],
		"every native lifecycle phase must ignore mutations of the input descriptor")
	Five := FrozenFive

	_LHCC_NativeEvents := []
	_LHCC_ProbeCalls := 0
	AliasHandle := _HotkeyRegistrarReserveResolvedOwned("Ctrl+Shift+(",
		_LHCC_Callback, "llm:descriptor:alias", Alias,
		_LHCC_Hotkey, _LHCC_Probe)
	AssertTrue(AliasHandle != "")
	AssertEqual(1, _LHCC_ProbeCalls,
		"an exact frozen tombstone must still probe the alias display spelling "
		. "because a raw producer can own that textual variant")
	AssertEqual("^+vk35", HOTKEY_REGISTRAR_BINDINGS[AliasHandle]["spec"])
	AssertTrue(_HotkeyRegistrarAbort(AliasHandle))

	Tombstone := HOTKEY_REGISTRAR_SPECS["^+vk35"]
	_LHCC_FrozenReserveFailure := true
	Refused := _HotkeyRegistrarReserveResolvedOwned("Ctrl+Shift+(",
		_LHCC_Callback, "llm:descriptor:refused", Alias,
		_LHCC_FailFrozenReserve, _LHCC_Probe)
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
	NativeCountBefore := _LHCC_Native.Count
	_LHCC_NativeEvents := []
	_LHCC_ProbeCalls := 0
	for Vector in InvalidDescriptors {
		AssertEqual("", _HotkeyRegistrarReserveResolvedOwned("Ctrl+5",
			_LHCC_Callback, "llm:descriptor:invalid", Vector["value"],
			_LHCC_Hotkey, _LHCC_Probe))
	}
	AssertEqual(TokenBefore, HOTKEY_REGISTRAR_NEXT_TOKEN)
	AssertEqual(NativeCountBefore, _LHCC_Native.Count)
	AssertEqual(0, _LHCC_NativeEvents.Length)
	AssertEqual(0, _LHCC_ProbeCalls,
		"invalid descriptors must fail before claim, probe, or native mutation")
	return true
}

_LHCC_ResolvedDescriptorsFreezeNativeOwners() {
	Result := _LHCC_WithOwnerState(
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
	Result := _LHCC_WithOwnerState(
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
	; The validation chord is the digit-row key on every layout
	; (llm-accept-inserts): the French binding freezes the same Ctrl+VK35 as the
	; US one, never the Ctrl+Shift+VK35 that types 5 on AZERTY.
	FrenchStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset,
		_LHCC_FrenchPhysicalKey)
	AssertTrue((FrenchStatus is Integer) && FrenchStatus == 1)
	AssertEqual(1, _LLM_Menu_NavActiveSlot)
	AssertTrue(_LNHT_Hotkeys.Has("1|^vk35"))
	AssertFalse(_LNHT_Hotkeys.Has("1|^+vk35"))
	AssertFalse(_LNHT_Hotkeys.Has("1|^5"))
	FrenchPlan := _LLM_Menu_NavSlotPlans[1]

	UsStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset,
		_LHCC_UsPhysicalKey)
	AssertTrue((UsStatus is Integer) && UsStatus == 1)
	AssertEqual(2, _LLM_Menu_NavActiveSlot)
	AssertTrue(_LNHT_Hotkeys.Has("2|^vk35"))

	; A rebind that fails after registering the digit restores the prior
	; generation: the same exact native variant is registered again, nothing of
	; it is retired.
	_LNHT_Events := []
	_LNHT_FailSpec := "^vk35"
	_LNHT_FailAfterApply := true
	RollbackStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset,
		_LHCC_UsPhysicalKey)
	AssertTrue((RollbackStatus is Integer) && RollbackStatus == 0)
	AssertTrue(_LLM_Menu_NavSlotPlans[1] == FrenchPlan)
	AssertTrue(_LNHT_Hotkeys.Has("1|^vk35"))
	AssertFalse(_LNHT_Hotkeys.Has("1|^+vk35"))
	AssertEqual(2, _LHCC_EventCount(_LNHT_Events, "1|^vk35 On"),
		"the failed attempt and the restore must each register the exact variant once")
	AssertEqual(0, _LHCC_EventCount(_LNHT_Events, "1|^vk35 Off"))

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
	AssertEqual(0, _LHCC_EventCount(_LNHT_Events, "1|^vk35 Off"),
		"slot recycling keeps the layout-independent variant it binds again")
	AssertEqual(1, _LHCC_EventCount(_LNHT_Events, "1|^vk35 On"))
	return true
}

_LHCC_NavCleanupKeepsRegistrationLayoutFixture() {
	return _LNHT_WithFixture(_LHCC_NavCleanupKeepsRegistrationLayoutCore)
}

_LHCC_NavCleanupKeepsRegistrationLayout() {
	Result := _LHCC_WithOwnerState(
		_LHCC_NavCleanupKeepsRegistrationLayoutFixture)
	AssertTrue((Result is Integer) && Result == 1,
		"the cross-layout cleanup fixture must reach every rollback assertion")
}
Test("[llm-hotkey-collision] nav cleanup reuses exact registration-layout specs",
	_LHCC_NavCleanupKeepsRegistrationLayout)





; ====================================
; ====================================
; ======= 4/ Contextual Routes =======
; ====================================
; ====================================

_LHCC_ContextualRoutesCore() {
	global _LLM_Menu, _LLM_Menu_Loaded
	global _LPHT_SelectedProfiles, _LPHT_AppOutput
	global _LNHT_AppOutput, _LNHT_TooltipActiveIdx
	global _LHCC_ContextualRoutingCompleted
	_LHCC_ContextualRoutingCompleted := false
	_LLM_Menu["nav_modifiers"] := "alt"
	_LLM_Menu["val_modifiers"] := "alt"
	_LLM_Menu_Loaded := true

	ProfileStatus := _LPHT_ProfileBindSelectPort()
	AssertTrue((ProfileStatus is Integer) && ProfileStatus == 1)
	NavStatus := LLM_Menu_BindNavHotkeys(_LLM_Menu, _LNHT_Hotkey,
		_LNHT_HotIf, _LNHT_Log, _LNHT_ForceHotIfReset)
	AssertTrue((NavStatus is Integer) && NavStatus == 1)

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
		"an out-of-range visible nav digit must reach the app unchanged")
	_LHCC_ContextualRoutingCompleted := true
	return true
}

_LHCC_ContextualRoutesNavFixture() {
	return _LNHT_WithFixture(_LHCC_ContextualRoutesCore)
}

_LHCC_ContextualRoutes() {
	global _LHCC_ContextualRoutingCompleted
	Result := _LPHT_WithFixture(_LHCC_ContextualRoutesNavFixture)
	AssertTrue(_LHCC_ContextualRoutingCompleted,
		"the nested owner fixture must reach every terminal routing assertion")
	return Result
}
Test("[llm-hotkey-collision] contextual owners retain exact eligible routing",
	_LHCC_ContextualRoutes)

_LHCC_CrossLayoutProfileNavPriorityCore() {
	global _LLM_Menu, _LLM_Menu_Loaded, _LLM_PROFILE_HOTKEY_PRED
	global _LLM_Menu_NavActiveSlot, _LHCC_CrossLayoutPriorityCompleted
	_LHCC_CrossLayoutPriorityCompleted := false
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

_LHCC_CrossLayoutProfileNavPriority() {
	global _LHCC_CrossLayoutPriorityCompleted
	Result := _LPHT_WithFixture(_LHCC_CrossLayoutProfileNavPriorityNavFixture)
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
			"the LLM chord grammar must reject native AHK syntax " . RawText)
	}
}
Test("[llm-hotkey-collision] policy compares canonical native identities",
	_LHCC_CanonicalIdentities)
