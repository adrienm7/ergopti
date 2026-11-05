; tests/unit/adapters/uia/test_secure_field_native_style_cache.ahk

; Explicit native-detector and UIA-schedule ports distinguish an inconclusive
; native read from an exact cached provider verdict. No native failure is claimed.
_SFSC_Inconclusive(Self, Hwnd, &Conclusive) {
	Conclusive := false
	return false
}
_SFSC_ObserveSchedule(Calls, Self, Hwnd, Generation) {
	Calls.Probes += 1
	Calls.Hwnd := Hwnd, Calls.Generation := Generation
	return true
}
_SFSC_Sequence(NativeReceipt, State, Schedule, Focus) {
	global SFD_FIELD_CACHE
	Control := State.Focus["control"]
	Generation := SFD_FIELD_CACHE["focus_generation"]
	Element := NativeReceipt ? "hwnd:" . Control : "fixture:exact-uia-runtime-id"
	SFD_CommitFieldVerdict(Control, false, Generation, Element)
	Secure := true
	AssertTrue(SFD_TryGetCachedVerdict(Control, Generation, Element, &Secure))
	AssertFalse(Secure, "the exact starting receipt is a valid negative cache entry")
	Calls := {Probes: 0, Hwnd: 0, Generation: 0}
	Actual := true
	Read() {
		Actual := SFD_IsSecureField(Control)
	}
	_WithSchedule() {
		_AAG_WithFn(SFD_ScheduleUiaProbe, _SFSC_ObserveSchedule.Bind(Calls), Read)
	}
	_AAG_WithFn(SFD_DetectNative, _SFSC_Inconclusive, _WithSchedule)
	AssertEqual(NativeReceipt, Actual,
		"an inconclusive read must refuse an old native negative but preserve the exact UIA negative")
	AssertEqual(NativeReceipt ? 1 : 0, Calls.Probes)
	if NativeReceipt {
		AssertEqual(Control, Calls.Hwnd)
		AssertEqual(Generation, Calls.Generation)
		AssertTrue(SFD_FIELD_CACHE["secure"], "a failed native refresh leaves an unknown secure verdict")
	} else {
		AssertEqual(Element, SFD_FIELD_CACHE["current_element_id"], "cache reuse must preserve its exact provider identity")
		AssertFalse(SFD_FIELD_CACHE["secure"])
	}
}
for _SFSC_Native in [true, false]
	Test("Secure-field native style cache: native_receipt=" . _SFSC_Native . " keeps the correct fallback (secure-field-native-style-cache)",
		_PCA_WithObserverFixture.Bind(_SFSC_Sequence.Bind(_SFSC_Native)))
