; tests/meta/ui/healthcheck/test_healthcheck_report_durable_route.ahk

; ==============================================================================
; MODULE: Diagnostics Attachment Durable Route Guard
; DESCRIPTION:
; Authenticates the actual default attachment writer and strict completion
; branch. Native fault tests separately exercise its real write/flush ports.
; ==============================================================================

#Requires AutoHotkey v2.0

_HCRDM_Durable(Body) {
	Resolve := InStr(Body, 'ResolvedWriter := HasMethod(WriterFn, "Call") ? WriterFn : FSWriteDurable')
	if !Resolve
		return false
	Write := InStr(Body, 'Written := ResolvedWriter.Call(Path, Text)', true, Resolve)
	if !Write
		return false
	Guard := InStr(Body, 'if !(Written is Integer) || Written != 1', true, Write)
	if !Guard
		return false
	Refuse := InStr(Body, 'throw Error("The complete diagnostics attachment could not be written.")', true, Guard)
	if !Refuse
		return false
	ReturnAt := InStr(Body, 'return Path', true, Refuse)
	return Resolve > 0 && Write > Resolve && Guard > Write && Refuse > Guard && ReturnAt > Refuse
}

_HCRDM_ActualRoute() {
	Body := _StripFullLineComments(_DriverFuncBody("_HCReport_Save"))
	Effects := _StripFullLineComments(_DriverFuncBody("_HCReport_Effects"))
	Save := _StripFullLineComments(_DriverFuncBody("_HCReport_SaveAndReveal"))
	Report := _StripFullLineComments(_DriverFuncBody("_HCReport_Report"))
	AssertTrue(Body != "" && Effects != "" && Save != "" && Report != "", "all actual attachment effect owners must exist")
	AssertTrue(RegExMatch(Effects, '"save",\s+_HCReport_Save\b') > 0, "the default save effect reaches this actual writer")
	SaveAt := InStr(Save, 'Path := Effects["save"].Call(')
	AssertTrue(SaveAt > 0 && InStr(Save, 'Effects["reveal"].Call(Path)') > SaveAt,
		"a failed actual save cannot reach Explorer")
	AttachAt := InStr(Report, 'Path := _HCReport_SaveAndReveal(')
	AssertTrue(AttachAt > 0 && InStr(Report, 'Effects["open_url"].Call(Url)') > AttachAt,
		"the real report route opens its browser after attachment completion")
	AssertTrue(_HCRDM_Durable(Body), "the actual attachment default requires complete UTF-8 bytes and flush")
	AssertFalse(_HCRDM_Durable(""), "a missing writer is refused without an invalid search offset")
	AssertFalse(_HCRDM_Durable('ResolvedWriter := HasMethod(WriterFn, "Call") ? WriterFn : FSWriteDurable'),
		"a truncated route is refused before its dependent search")
	for Mutation in [
		['ResolvedWriter := HasMethod(WriterFn, "Call") ? WriterFn : FSWriteDurable', 'ResolvedWriter := HasMethod(WriterFn, "Call") ? WriterFn : FSWrite'],
		['Written := ResolvedWriter.Call(Path, Text)', 'Ignored := ResolvedWriter.Call(Path, Text)'],
		['if !(Written is Integer) || Written != 1', 'if !Written'],
		['throw Error("The complete diagnostics attachment could not be written.")', 'return Path']] {
		Changed := StrReplace(Body, Mutation[1], Mutation[2], true, &Count)
		AssertEqual(1, Count, "each mutation withdraws one actual native completion fact")
		AssertTrue(Changed != Body, "stale mutations cannot qualify a regression guard")
		AssertFalse(_HCRDM_Durable(Changed), "buffer acceptance or discarded receipts cannot publish a report path")
	}
}
Test("Diagnostics attachment: actual effect route requires a strict durable receipt (healthcheck-report-durable-route)", _HCRDM_ActualRoute)
