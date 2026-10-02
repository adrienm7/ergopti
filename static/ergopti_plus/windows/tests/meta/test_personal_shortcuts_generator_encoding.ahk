; tests/meta/test_personal_shortcuts_generator_encoding.ahk

; ==============================================================================
; MODULE: Personal shortcuts generator encoding regression test
; DESCRIPTION:
; The forwarding stub is an AHK source file parsed on the next startup. A
; BOM-less or CRLF-generated stub can silently fail the repository's source
; gate and makes future non-ASCII personal content parser-dependent. Lock both
; writers and the template to UTF-8-with-BOM plus LF-only content.
; ==============================================================================

#Requires AutoHotkey v2.0

_PSGE_Body(Name) {
    Body := _DriverFuncBody(Name)
    Assert(Body != "", Name . "() must exist")
    return Body
}

_PSGE_UsesBomAndLf() {
    EnsureBody := _PSGE_Body("EnsurePersonalShortcutsFile")
    ActionsSrc := _DriverSourceConcat()
    Q := Chr(34)

    Assert(!RegExMatch(EnsureBody, "FileAppend\([^\r\n]*" . Q . "UTF-8-RAW" . Q . "\)"),
        "EnsurePersonalShortcutsFile must never write generated AHK with UTF-8-RAW (BOM-less)")
	Assert(InStr(EnsureBody,
		'_PersonalShortcutsPublishFile(Path, Chr(0xFEFF) . Template') > 0,
		"Personal shortcuts template must be atomically published with an explicit UTF-8 BOM")
	Assert(InStr(EnsureBody,
		'Chr(0xFEFF) . DesiredStub, WriterFn, ReplaceFn, ReadFn') > 0,
		"Forwarding stub must be atomically published with an explicit UTF-8 BOM")
    Assert(!InStr(EnsureBody, "`r`n"),
        "Forwarding stub text must use LF, never CRLF")

    TemplateBody := _PSGE_Body("PersonalShortcutsTemplate")
    Assert(!InStr(TemplateBody, "`r`n"),
        "the hoisted template must use LF-only lines so first-run source matches the encoding contract")
	Assert(InStr(EnsureBody, "Template := PersonalShortcutsTemplate()") > 0,
		"cold bootstrap must use the complete hoisted template before menu globals initialize")
}

_PSGE_ReparseNeverRevealsIntermediateIcon() {
	Src := _DriverSourceConcat()
	Assert(Src != "", "driver source must be available")
	Settle := InStr(Src, 'if !EnsurePersonalShortcutsFile(ScriptInformation["PersonalAhkPath"]')
	Reveal := InStr(Src, "A_IconHidden := false")
	Assert(Settle > 0 and Reveal > Settle,
		"settle the parse-time include before icon reveal so a necessary reparse has no transient icon")
}

Test("meta personal-shortcuts: generator writes BOM + LF source", _PSGE_UsesBomAndLf)
Test("meta personal-shortcuts: intermediate reparse never reveals an icon (reload-icon-2026-10-02)",
	_PSGE_ReparseNeverRevealsIntermediateIcon)
