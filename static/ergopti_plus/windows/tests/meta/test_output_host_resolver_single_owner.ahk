; tests/meta/test_output_host_resolver_single_owner.ahk

; ==============================================================================
; MODULE: Output Host Resolver Single-Owner Guard
; DESCRIPTION:
; Prevents functional output routing from regressing to KLHook.prev_app.
; ==============================================================================

#Requires AutoHotkey v2.0

_OHRSO_Count(Haystack, Needle) {
	Count := 0
	Pos := 1
	while Pos := InStr(Haystack, Needle, true, Pos) {
		Count += 1
		Pos += StrLen(Needle)
	}
	return Count
}

_OHRSO_NoFunctionalMetricsReads() {
	Files := [
		"infra\hotstrings\hotstring_dispatch.ahk",
		"infra\hotstrings\hotstring_builder.ahk",
		"infra\hotstrings\hotstring_send.ahk",
		"modules\keymap\layout.ahk"
	]
	ResolverCalls := 0
	for RelativePath in Files {
		Src := ""
		try Src := FileRead(A_ScriptDir . "\..\" . RelativePath, "UTF-8")
		AssertTrue(Src != "", RelativePath . " must be readable")
		AssertTrue(InStr(Src, "KLHook.prev_app", true) == 0,
			RelativePath . " must not route functional output through metrics state")
		ResolverCalls += _OHRSO_Count(Src, "OutputHostResolve()")
	}
	AssertTrue(ResolverCalls >= 4,
		"all four audited functional routing sites must use the canonical resolver")
}
Test("output host: functional routing has one owner outside metrics", _OHRSO_NoFunctionalMetricsReads)
