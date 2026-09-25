; tests/meta/test_altgr_kana_taphold_entry.ahk

; ==============================================================================
; MODULE: Kana SC138 AltGr tap-hold entry regression test
; DESCRIPTION:
; On Kana-style layouts the physical AltGr key is scan code SC138 on a virtual
; key other than VK_RMENU. Every standalone AltGr hotkey is one SC138 identity
; whose standard and Kana variants are mutually exclusive: a separate "RAlt::"
; identity on the same scan code silenced every SC138 hotkey whenever its own
; #HotIf was false, so the Kana AltGr tap-hold and the navigation Escape never
; fired (altgr-single-identity-2026-09-25). The AltGr key held as AltGr on a
; Kana layout passes itself through like LShift held as Shift.
; ==============================================================================

#Requires AutoHotkey v2.0

; Text of the #HotIf line that governs the declaration found at Pos.
_AKTE_GoverningHotIf(Src, Pos) {
    HotIfPos := 0
    ScanAt := 1
    while (Found := InStr(Src, "#HotIf", , ScanAt)) && (Found < Pos) {
        HotIfPos := Found
        ScanAt := Found + 1
    }
    if !HotIfPos
        return ""
    return SubStr(Src, HotIfPos, InStr(Src, "`n", , HotIfPos) - HotIfPos)
}

_AKTE_AltGrOwnsKanaTap() {
    Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
    Assert(Src != "", "the tap-hold remap sources must be readable")
    Assert(InStr(Src, 'KeyWait("SC138"') > 0 && !InStr(Src, 'KeyWait("RAlt"'),
        "the AltGr tap must wait for the physical SC138 key on every layout")
    Assert(InStr(Src, 'TapHoldPriorKeyIsSelf("alt_gr")') > 0,
        "the AltGr tap must require its own physical prior key before dispatch")
    Assert(!InStr(Src, '_ALTGR_KANA_FIXUP && GetKeyState("SC138", "P")'),
        "no AltGr handler may bail out on a physical SC138: with one hotkey identity there is no second RAlt event to deduplicate")

    ; Both tap-only variants exist and are exclusive on the Kana flag.
    StandardTap := InStr(Src, "SC01D & ~SC138::")
    Assert(StandardTap > 0, "the standard AltGr tap-only variant must exist")
    Assert(InStr(_AKTE_GoverningHotIf(Src, StandardTap), "not _ALTGR_KANA_FIXUP") > 0,
        "the standard AltGr tap-only variant must be excluded on Kana-style layouts")
    KanaTap := RegExMatch(Src, '#HotIf _ALTGR_KANA_FIXUP and [^\r\n]*TapHoldHoldModifier\(TapHold, "alt_gr"\) == ""[^\r\n]*\R\s*SC138:: \{')
    Assert(KanaTap > 0, "the Kana AltGr tap-only variant must be the plain SC138 hotkey")
}
Test("tap-holds: Kana SC138 owns configured AltGr tap exactly once (altgr-single-identity-2026-09-25)",
    _AKTE_AltGrOwnsKanaTap)

_AKTE_KanaAltGrHoldPassesThrough() {
    Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
    Identity := InStr(Src, "~*$SC138:: _AltGrKanaHandleHold(true)")
    Assert(Identity > 0, "the Kana AltGr held as AltGr must pass the physical key through")
    Assert(InStr(_AKTE_GoverningHotIf(Src, Identity), "_AltGrHoldModKey() == KS_AltGrKeyName()") > 0,
        "the pass-through variant must apply exactly when the hold is the layout's own AltGr")
    Owned := InStr(Src, "*$SC138:: _AltGrKanaHandleHold(false)")
    Assert(Owned > 0, "any other Kana AltGr hold must keep the suppressing owner")
    Assert(InStr(_AKTE_GoverningHotIf(Src, Owned), "_AltGrHoldModKey() != KS_AltGrKeyName()") > 0,
        "the suppressing variant must exclude the AltGr-as-AltGr hold")
    Body := _DriverFuncBody("_AltGrKanaHandleHold")
    Assert(Body != "", "_AltGrKanaHandleHold must exist")
    Assert(RegExMatch(Body, ",\s*PhysicalModifierPassthrough\)") > 0,
        "the Kana AltGr owner must hand its pass-through decision to TapHoldOwnImmediateModifier")
}
Test("tap-holds: the Kana AltGr held as AltGr passes itself through (altgr-single-identity-2026-09-25)",
    _AKTE_KanaAltGrHoldPassesThrough)

_AKTE_NavigationOwnsKanaEscape() {
    Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
    Q := Chr(34)
    Label := RegExMatch(Src, "SC01D & ~SC138::[^\r\n]*\R\s*SC138::[^\r\n]*\R\{\R\s*ActionLayer\(" . Q . "\{Escape ")
    Assert(Label > 0, "the navigation layer must emit Escape from one SC138 AltGr variant")
    Assert(_AKTE_GoverningHotIf(Src, Label) = "#HotIf LayerEnabled",
        "the navigation Escape must apply on every layout, Kana-style ones included")
    Assert(!InStr(Src, "#HotIf LayerEnabled and _ALTGR_KANA_FIXUP"),
        "a separate Kana navigation variant would duplicate the one SC138 Escape")
}
Test("tap-holds: Kana SC138 owns navigation Escape exactly once (altgr-single-identity-2026-09-25)",
    _AKTE_NavigationOwnsKanaEscape)
