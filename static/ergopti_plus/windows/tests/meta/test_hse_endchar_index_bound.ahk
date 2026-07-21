; tests/meta/test_hse_endchar_index_bound.ahk
#Requires AutoHotkey v2.0

Test_HSE_EndCharMatchUsesBoundedFullTriggerIndex() {
	MatchBody := _DriverFuncBody("HSE_FindMatchAtEnd")
	Engine := _DriverDirConcat("lib/hotstrings")
	Assert(InStr(MatchBody, "HSE_EndByTriggerCI.Has") > 0 and InStr(MatchBody, "HSE_EndByTriggerCS.Has") > 0,
		"end-char matching must probe full-trigger maps")
	Assert(InStr(MatchBody, "Min(StrLen(EffBody), HSE_MaxEndTriggerLen)") > 0,
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
