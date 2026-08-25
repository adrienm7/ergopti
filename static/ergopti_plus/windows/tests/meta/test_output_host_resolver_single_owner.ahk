; tests/meta/test_output_host_resolver_single_owner.ahk

; ==============================================================================
; MODULE: Output Host Resolver Ownership Guard
; DESCRIPTION:
; AHK-002 source contract: functional routing has one bounded foreground owner.
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

_OHRSO_NoFunctionalMetricsReaders() {
	AllSource := _DriverSourceNoComments()
	Allowed := _StripFullLineComments(
		_DriverDirConcat("modules/keylogger") . "`n"
		. _DriverDirConcat("infra/metrics"))
	AssertTrue(AllSource != "" && Allowed != "",
		"the guard must read both the full source and its nonempty allowance")
	AssertEqual(_OHRSO_Count(Allowed, "KLHook.prev_app"),
		_OHRSO_Count(AllSource, "KLHook.prev_app"),
		"KLHook.prev_app must have no functional readers outside metrics/keylogger")
}
Test("output host: metrics cache has no functional readers (ahk-002)",
	_OHRSO_NoFunctionalMetricsReaders)

_OHRSO_ResolverAndDispatchOwnBoundedReceipts() {
	MetadataBody := _DriverFuncBody("_OutputHostReadMetadata")
	TitleBody := _DriverFuncBody("_OutputHostReadTitle")
	ValidBody := _DriverFuncBody("_OutputHostValidReceipt")
	InvalidBody := _DriverFuncBody("_OutputHostInvalidReceipt")
	ResolveBody := _DriverFuncBody("OutputHostResolve")
	DispatchBody := _DriverFuncBody("HSE_DispatchMatch")
	for Body in [MetadataBody, TitleBody, ValidBody, InvalidBody,
			ResolveBody, DispatchBody]
		AssertTrue(Body != "", "every audited production function must be readable")
	AssertEqual(0, _OHRSO_Count(MetadataBody, "WinGetTitle("),
		"cached metadata must exclude mutable window titles")
	AssertTrue(InStr(TitleBody, "_WIReadTitleBounded(") > 0,
		"title routing must delegate to the bounded WindowInfo primitive")
	AssertTrue(InStr(ValidBody, '"Valid", true') > 0
		&& InStr(InvalidBody, '"Valid", false') > 0
		&& InStr(ResolveBody, '"focus_changed"') > 0,
		"the resolver must publish a typed receipt and reject mixed identities")
	AssertEqual(2, _OHRSO_Count(DispatchBody, "OutputHostResolve(true)"),
		"normal and raw dispatch must each acquire exactly one title-bearing receipt")
	AssertEqual(0, _OHRSO_Count(DispatchBody, "HostSnapshot"),
		"terminal ownership must reuse the dispatch receipt")
}
Test("output host: resolver and dispatch own one bounded receipt (ahk-002)",
	_OHRSO_ResolverAndDispatchOwnBoundedReceipts)
