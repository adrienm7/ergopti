; tests/meta/test_hse_endchar_index_bound.ahk
#Requires AutoHotkey v2.0

Test_HSE_EndCharMatchUsesBoundedFullTriggerIndex() {
	MatchBody := _DriverFuncBody("HSE_FindMatchAtEnd")
	Engine := FileRead(A_ScriptDir . "\..\lib\hotstrings\hotstring_engine_main.ahk", "UTF-8")
	Assert(InStr(MatchBody, "HSE_EndByTriggerCI.Has") > 0 and InStr(MatchBody, "HSE_EndByTriggerCS.Has") > 0,
		"end-char matching must probe full-trigger maps")
	Assert(InStr(MatchBody, "Min(StrLen(EffBody), HSE_MaxEndTriggerLen)") > 0,
		"end-char probes must be bounded by maximum trigger length, not corpus size")
	Assert(InStr(MatchBody, "Buckets2 := _HSE_BucketsFor") == 0,
		"end-char matching must not scan every same-tail bucket candidate")
	Assert(InStr(Engine, "global HSE_EndByTriggerCI := Map()") > 0
		and InStr(Engine, "_HSE_RebuildEndTriggerIndex()") > 0,
		"full-trigger end index must be owned and rebuilt across live group changes")
}
Test("HSE: end-char matching probes a bounded full-trigger index", Test_HSE_EndCharMatchUsesBoundedFullTriggerIndex)
