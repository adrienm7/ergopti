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
; Kana layout passes itself through like LShift held as Shift. Which variant
; owns which press is evaluated in tests/unit/test_altgr_owner_matrix.ahk.
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
    Owner := _DriverFuncBody("_AltGrHandleHold")
    StrReplace(Owner, '"alt_gr", "SC138"', , , &Waits)
    AssertEqual(2, Waits, "both AltGr owners (modifier and layer) must wait for the physical SC138 key on every layout")
    Assert(!InStr(Src, 'KeyWait("RAlt"'), "no AltGr owner may wait for RAlt, a plain Alt on a Kana layout")
    Assert(InStr(Owner, 'TapHoldPriorKeyIsSelf("alt_gr")') > 0,
        "the AltGr tap must require its own physical prior key before dispatch")
    Assert(!InStr(Src, '_ALTGR_KANA_FIXUP && GetKeyState("SC138", "P")'),
        "no AltGr handler may bail out on a physical SC138: with one hotkey identity there is no second RAlt event to deduplicate")
}
Test("tap-holds: Kana SC138 owns configured AltGr tap exactly once (altgr-single-identity-2026-09-25)",
    _AKTE_AltGrOwnsKanaTap)

_AKTE_KanaAltGrHoldPassesThrough() {
    Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
    Identity := InStr(Src, "~*$SC138:: _AltGrHandleHold(true)")
    Assert(Identity > 0, "the Kana AltGr held as AltGr must pass the physical key through")
    AssertEqual("#HotIf AltGrOwnerPassesThrough(true)", _AKTE_GoverningHotIf(Src, Identity),
        "the pass-through variant must apply exactly when the Kana AltGr holds itself or nothing")
    Owned := InStr(Src, "*$SC138:: _AltGrHandleHold(false)")
    Assert(Owned > 0, "any other Kana AltGr hold must keep the suppressing owner")
    AssertEqual("#HotIf AltGrOwnerHolds(true)", _AKTE_GoverningHotIf(Src, Owned),
        "the suppressing variant must exclude the AltGr-as-AltGr hold")
    Body := _DriverFuncBody("_AltGrHandleHold")
    Assert(RegExMatch(Body, ",\s*Passthrough \? KS_AltGrKeyName\(\) : false\)") > 0,
        "the AltGr owner must hand its pass-through decision to TapHoldOwnImmediateModifier")
}
Test("tap-holds: the Kana AltGr held as AltGr passes itself through (altgr-single-identity-2026-09-25)",
    _AKTE_KanaAltGrHoldPassesThrough)

; The dynamic layer must retain the upstream physical identities: no RAlt
; alias beside SC138, and no Kana-only criterion that loses standard AltGr.
_AKTE_NavigationOwnsKanaEscape() {
    SharedDir := A_ScriptDir . "\..\..\_shared"
    Ctx := KeymapLayers_LoadContext(SharedDir)
    Text := '[_meta]' . Chr(10) . 'schema_version = 1' . Chr(10) . Chr(10)
        . '[layers.nav.all]' . Chr(10) . '"AltRight" = "escape"' . Chr(10)
    Result := KeymapLayers_Load("windows", Ctx, Text)
    Assert(Result["ok"], "a layer binding Escape on AltRight must resolve for Windows")
    Rows := NavLayer_BuildTable(Result["layers"][NAV_LAYER_ID], Ctx)
    Physical := 0, Combined := 0
    for Row in Rows {
        AssertEqual("send:{Escape N}", Row["action"], Row["hotkey"] . " must emit navigation Escape")
        AssertEqual(NAV_LAYER_CRITERION_LAYER, Row["criterion"], "both identities use the navigation gate")
        AssertFalse(Row["kana_guard"], "a single physical identity needs no duplicate-event guard")
        if (Row["hotkey"] == "*SC138")
            Physical += 1
        else if (Row["hotkey"] == "~SC01D & ~SC138")
            Combined += 1
        else
            Assert(false, "unexpected AltGr alias: " . Row["hotkey"])
    }
    AssertEqual(1, Physical, "Kana and standard AltGr share one physical SC138 owner")
    AssertEqual(1, Combined, "the Ctrl/AltGr combination preserves physical Ctrl")
    AssertEqual(2, Rows.Length, "no virtual RAlt alias may duplicate navigation Escape")
}
Test("tap-holds: Kana SC138 owns navigation Escape exactly once (altgr-single-identity-2026-09-25)",
    _AKTE_NavigationOwnsKanaEscape)
