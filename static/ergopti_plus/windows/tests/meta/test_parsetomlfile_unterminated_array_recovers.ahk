; tests/meta/test_parsetomlfile_unterminated_array_recovers.ahk

; ==============================================================================
; MODULE: ParseTomlFile Unterminated-Array Recovery Meta Test
; DESCRIPTION:
; Behavioural regression for finding toml-unterminated-array-recovery (F-L05).
;
; Once a multi-line array opened (value starts with [ but has no ]), the parser's
; continuation loop only re-scanned bracket depth and never re-detected a [section]
; header. With a missing closing ], depth never returned to <= 0, so the parser
; appended the entire remainder of the file - including all later section headers -
; into one PendingVal and dropped it at EOF: every section after the unterminated
; array silently vanished (whole-file-tail config loss).
;
; The fix aborts the array (with a WARN) when a continuation line is a section header
; and re-processes that line as a header. This test writes such a file and asserts the
; trailing section survives. ParseTomlFile is in the headless include graph (lib/toml).
; ==============================================================================

#Requires AutoHotkey v2.0


_PTUA_AssertRecovers() {
	tmp := A_Temp . "\ergopti_test_unterm_array_" . A_TickCount . ".toml"
	; A multi-line array with NO closing ], followed by a later section + key.
	content := '[metrics]`nmetrics_disabled_apps = [`n  "chrome.exe",`n[later_section]`nflag = true`n'
	try FileDelete(tmp)
	FileAppend(content, tmp, "UTF-8")
	Sections := ParseTomlFile(tmp)
	try FileDelete(tmp)
	Assert(IsObject(Sections), "ParseTomlFile must return a Sections map")
	Assert(Sections.Has("later_section"),
		"ParseTomlFile must recover the section declared after an unterminated multi-line array - it must not swallow every following section (toml-unterminated-array-recovery)")
	Assert(Sections["later_section"].Has("flag"),
		"the key under the section after an unterminated array must be parsed (toml-unterminated-array-recovery)")
}
Test("toml: ParseTomlFile recovers sections after an unterminated multi-line array (toml-unterminated-array-recovery)", _PTUA_AssertRecovers)