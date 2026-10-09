; tests/meta/test_hse_endchar_index_bound.ahk
#Requires AutoHotkey v2.0

Test_HSE_EndCharMatchUsesBoundedFullTriggerIndex() {
	MatchBody := _DriverFuncBody("HSE_FindMatchAtEnd")
	Engine := _DriverDirConcat("infra/hotstrings")
	; _DriverFuncBody returns "" for an unknown name, which would make the
	; ABSENCE assertion below pass against a driver that no longer has this
	; function at all — a guard that cannot fail is worse than none.
	Assert(MatchBody != "", "HSE_FindMatchAtEnd() must exist in the driver source for this guard to mean anything")
	Assert(InStr(MatchBody, "HSE_EndByTriggerCI.Has") > 0 and InStr(MatchBody, "HSE_EndByTriggerCS.Has") > 0,
		"end-char matching must probe full-trigger maps")
	Assert(RegExMatch(MatchBody,
		"Min\(\s*StrLen\(EffBody\)\s*,\s*HSE_MaxEndTriggerLen(?:\s*,\s*HSE_MAX_BUFFER_LEN)?\s*\)") > 0,
		"end-char probes must be bounded by maximum trigger length, not corpus size")
	; _HSE_BucketsFor was deleted, so asserting its ABSENCE could never fail
	; again — the guard outlived the thing it guarded. What actually matters is
	; the invariant that helper stood for: end-char matching must not WALK the
	; same-tail registry, which is the O(n)-per-keystroke shape the bounded
	; full-trigger index replaced.
	;
	; The check is on iteration, not on mention: the function still declares
	; HSE_RegistryByLastChar in its `global` line, so asserting the identifier is
	; absent would fail against correct code. Other functions in this file build
	; and prune that registry by index, which is legitimate — only walking a
	; bucket from the per-keystroke match path is the defect.
	Assert(RegExMatch(MatchBody, "for\s+[^\r\n]*\s+in\s+HSE_RegistryByLastChar") == 0,
		"end-char matching must not iterate a same-tail registry bucket — that is the unbounded per-keystroke scan the bounded full-trigger index exists to avoid")
	Assert(InStr(Engine, "global HSE_EndByTriggerCI := Map()") > 0
		and InStr(Engine, "_HSE_RebuildEndTriggerIndex()") > 0,
		"full-trigger end index must be owned and rebuilt across live group changes")
}
Test("HSE: end-char matching probes a bounded full-trigger index", Test_HSE_EndCharMatchUsesBoundedFullTriggerIndex)

; The buffer-sized body slice belongs inside the balanced terminator block.
; Ordering alone cannot prove containment, and a supplementary terminator consumes
; two UTF-16 units. The shared mask/extractor keeps prose and quoted braces from
; impersonating syntax while retaining the original bounded-matching assertions.
_HSE_AssertBodySliceDeferredToTerminators(MatchBody) {
	Assert(MatchBody != "", "HSE_FindMatchAtEnd() must exist in the driver source")
	Code := _DriverMaskNonCode(&MatchBody)
	Assert(RegExMatch(Code, "m)^[ `t]*if\s+IsTerminator\s*\{", &Guard) > 0,
		"the trigger-body slice requires a terminator guard")
	OpenPos := InStr(Code, "{", , Guard.Pos)
	GuardBody := _DriverExtractDefinedBody(&Code, { Idx: Guard.Pos, OpenPos: OpenPos })
	Assert(GuardBody != "" && SubStr(RTrim(GuardBody, " `t`r`n"), -1) == "}", "the terminator guard must be a complete balanced block")
	SlicePattern := "SubStr\s*\(\s*HSE_Buffer\s*,\s*1\s*,\s*BufLen\s*-\s*StrLen\s*\(\s*JustTypedChar\s*\)\s*\)"
	Assert(RegExMatch(GuardBody, SlicePattern) > 0,
		"the buffer-sized slice must be INSIDE the guard and remove the actual UTF-16 terminator width")
	RegExReplace(Code, "SubStr\s*\(\s*HSE_Buffer\s*,\s*1\s*,\s*BufLen\s*-", "", &SliceCount)
	AssertEqual(1, SliceCount, "the function must not copy the trigger body again outside the terminator guard")
}
Test_HSE_BodySliceIsDeferredToTerminators() {
	_HSE_AssertBodySliceDeferredToTerminators(_DriverFuncBody("HSE_FindMatchAtEnd"))
}
Test("HSE: the trigger-body slice is only derived on terminators (perf-2026-07-21)", Test_HSE_BodySliceIsDeferredToTerminators)

Test_HSE_BodySliceGuardRejectsMalformedSources() {
	Body := _DriverFuncBody("HSE_FindMatchAtEnd")
	_HSE_AssertBodySliceDeferredToTerminators(Body)
	Slice := "BodyBuf := SubStr(HSE_Buffer, 1, BufLen - StrLen(JustTypedChar))"
	Assert(InStr(Body, Slice) > 0, "mutations require the actual body-slice statement")
	WithoutSlice := StrReplace(Body, Slice, "BodyBuf := 0")
	BeforeGuard := StrReplace(WithoutSlice, "if IsTerminator {", Slice . "`nif IsTerminator {")
	AssertThrows(_HSE_AssertBodySliceDeferredToTerminators.Bind(BeforeGuard), "a slice before the guard must fail")
	AssertThrows(_HSE_AssertBodySliceDeferredToTerminators.Bind(WithoutSlice . "`n" . Slice), "a slice after the guard must fail")
	AssertThrows(_HSE_AssertBodySliceDeferredToTerminators.Bind(Body . "`n" . Slice), "a second unguarded slice must fail")
	StaleWidth := StrReplace(Body, "BufLen - StrLen(JustTypedChar)", "BufLen - 1")
	Assert(StaleWidth != Body, "the width mutant must alter actual source")
	AssertThrows(_HSE_AssertBodySliceDeferredToTerminators.Bind(StaleWidth), "a literal one-unit terminator width must fail")
	AssertThrows(_HSE_AssertBodySliceDeferredToTerminators.Bind(""), "empty source must fail")
}
Test("HSE: terminator slice guard rejects unguarded and stale-width mutants", Test_HSE_BodySliceGuardRejectsMalformedSources)
