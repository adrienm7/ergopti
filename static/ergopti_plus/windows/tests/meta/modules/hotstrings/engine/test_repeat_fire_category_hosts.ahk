; tests/meta/modules/hotstrings/engine/test_repeat_fire_category_hosts.ahk

; ==============================================================================
; MODULE: Repeat Fire-Category Across Output Hosts Meta Test
; DESCRIPTION:
; Static source guard for URW-002. The repeat fallback Spec carries the
; magic-key Category, and only the atomic caller used to normalise it to
; MenuCommand.REPEAT_KEY; the Notepad and terminal owners copied Spec.Category,
; so a deferred doubling coloured the live WPM widget as a magic-key correction.
; The normalisation now lives in one owner, _ResolveFireCategory, which every
; output host must call.
;
; Meta-static: the headless runner cannot complete a native Notepad or terminal
; transaction, so the source text of the three owner constructors is the contract.
; ==============================================================================

#Requires AutoHotkey v2.0

_RFC_ResolverNormalisesRepeat() {
	Body := _DriverFuncBody("_ResolveFireCategory")
	Assert(InStr(Body, "IsRepeat") > 0 and InStr(Body, "MenuCommand.REPEAT_KEY") > 0,
		"_ResolveFireCategory must map an IsRepeat Spec to MenuCommand.REPEAT_KEY")
	Assert(InStr(Body, "Category") > 0,
		"_ResolveFireCategory must keep a registered Spec's own Category (real repeat corrections stay coloured)")
}
Test("fire category: one resolver normalises repeat and keeps registered categories (URW-002)", _RFC_ResolverNormalisesRepeat)

_RFC_NoOwnerCopiesSpecCategory() {
	Dispatch := _DriverFileSource("hotstring_dispatch.ahk")
	Assert(InStr(Dispatch, "Spec.HasOwnProp(" . Chr(34) . "Category" . Chr(34) . ") ? Spec.Category") == 0,
		"a deferred owner must not copy Spec.Category directly - route it through _ResolveFireCategory")
	Assert(StrSplit(Dispatch, "_ResolveFireCategory(Spec)").Length - 1 >= 3,
		"the atomic-adjacent, Notepad and terminal owner constructors must all call _ResolveFireCategory")
}
Test("fire category: Notepad and terminal owners do not copy Spec.Category (URW-002)", _RFC_NoOwnerCopiesSpecCategory)

_RFC_AtomicCallerUsesResolver() {
	Src := _DriverFileSource("hotstring_inputhook.ahk")
	Assert(InStr(Src, "HotstringCategory := _ResolveFireCategory(HSEMatch)") > 0,
		"the synchronous caller must classify through the same resolver as the deferred owners")
}
Test("fire category: the atomic caller uses the shared resolver (URW-002)", _RFC_AtomicCallerUsesResolver)
