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
    Assert(InStr(EnsureBody, 'FileAppend(Template, Path, "UTF-8")') > 0,
        "Personal shortcuts template must be created with UTF-8 BOM encoding")
    Assert(InStr(EnsureBody, 'FileAppend(DesiredStub, StubPath, "UTF-8")') > 0,
        "Forwarding stub must be created with UTF-8 BOM encoding")
    Assert(!InStr(EnsureBody, "`r`n"),
        "Forwarding stub text must use LF, never CRLF")

    TemplateStart := InStr(ActionsSrc, "global PERSONAL_SHORTCUTS_TEMPLATE")
    Assert(TemplateStart > 0,
        "menu_actions.ahk must expose the personal shortcuts template")
    TemplateBody := SubStr(ActionsSrc, TemplateStart, 4000)
    Assert(!InStr(TemplateBody, "`r`n"),
        "PERSONAL_SHORTCUTS_TEMPLATE must use LF-only lines so first-run source matches the encoding contract")
}

Test("meta personal-shortcuts: generator writes BOM + LF source", _PSGE_UsesBomAndLf)
