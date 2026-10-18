; tests/unit/adapters/input/test_hotkey_registrar_aliases.ahk

; ==============================================================================
; MODULE: Hotkey Registrar Owners, Aliases and Native Seams
; DESCRIPTION:
; Active and foreign owners are never clobbered, textual and frozen specs
; and their logical and scan-code aliases share one exact owner, and
; native calls select an unconditional HotIf outside Critical.
; ==============================================================================

#Requires AutoHotkey v2.0





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
