; tests/meta/test_altgr_kana_taphold_entry.ahk

; ==============================================================================
; MODULE: Kana SC138 AltGr tap-hold entry regression test
; DESCRIPTION:
; On Kana/IME layouts the physical AltGr key has scan code SC138. It must own
; both the configured tap action and navigation Escape, while a virtual RAlt
; alias must not duplicate the same physical transition.
; ==============================================================================

#Requires AutoHotkey v2.0

_AKTE_AltGrOwnsKanaTap() {
    Src := _DriverDirConcat("platform/remap")
    Assert(InStr(Src, '#HotIf _ALTGR_KANA_FIXUP and not LayerEnabled') > 0,
        "altgr.ahk must register a Kana-only SC138 tap-hold context")
    Assert(InStr(Src, "SC138::") > 0 && InStr(Src, 'KeyWait("SC138"') > 0,
        "Kana physical AltGr must wait for SC138 itself, not RAlt")
    Assert(InStr(Src, 'A_PriorKey == "SC138"') > 0,
        "Kana SC138 tap must require its own physical prior key before dispatch")
    Assert(InStr(Src, '_ALTGR_KANA_FIXUP && GetKeyState("SC138", "P")') > 0,
        "virtual RAlt handler must defer to SC138 when the physical Kana key is down")
}

Test("tap-holds: Kana SC138 owns configured AltGr tap exactly once", _AKTE_AltGrOwnsKanaTap)

_AKTE_NavigationOwnsKanaEscape() {
    Src := _DriverDirConcat("platform/remap")
    Q := Chr(34)
    Assert(InStr(Src, "#HotIf LayerEnabled and _ALTGR_KANA_FIXUP") > 0,
        "nav_layer.ahk must gate the SC138 Escape handler on both navigation and Kana state")
    Assert(InStr(Src, "SC138::") > 0 && InStr(Src, "ActionLayer(" . Q . "{Escape ") > 0,
        "physical Kana AltGr must emit navigation Escape")
    Assert(InStr(Src, '_ALTGR_KANA_FIXUP && GetKeyState("SC138", "P")') > 0,
        "virtual RAlt navigation handler must not duplicate physical SC138 Escape")
}

Test("tap-holds: Kana SC138 owns navigation Escape exactly once", _AKTE_NavigationOwnsKanaEscape)
