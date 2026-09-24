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

; The navigation layer is a table built from layer files now
; (platform/remap/nav_layer_table.ahk): a binding on AltRight must register the
; bare SC138 under the Kana criterion, and its RAlt spellings must defer to it.
_AKTE_NavigationOwnsKanaEscape() {
    SharedDir := A_ScriptDir . "\..\..\_shared"
    Ctx := KeymapLayers_LoadContext(SharedDir)
    Result := KeymapLayers_Load("windows", Ctx, '[_meta]`nschema_version = 1`n`n[layers.nav.all]`n"AltRight" = "escape"`n')
    Assert(Result["ok"], "a layer binding Escape on AltRight must resolve for Windows")
    Kana := 0, Guarded := 0
    for Row in NavLayer_BuildTable(Result["layers"][NAV_LAYER_ID], Ctx) {
        AssertEqual("send:{Escape N}", Row["action"], Row["hotkey"] . " must emit navigation Escape")
        if (Row["hotkey"] == "SC138") {
            Kana += 1
            AssertEqual(NAV_LAYER_CRITERION_KANA, Row["criterion"],
                "the SC138 Escape handler must be gated on both navigation and Kana state")
            AssertFalse(Row["kana_guard"], "physical Kana AltGr is the handler the others defer to")
        } else if Row["kana_guard"] {
            Guarded += 1
        }
    }
    AssertEqual(1, Kana, "physical Kana AltGr must emit navigation Escape exactly once")
    AssertEqual(2, Guarded, "both RAlt spellings must defer to the physical SC138")
    Body := _DriverFuncBody("_NavLayer_KanaGuarded")
    Assert(Body != "", "_NavLayer_KanaGuarded must exist in platform/remap/nav_layer_table.ahk")
    Assert(InStr(Body, '_ALTGR_KANA_FIXUP && GetKeyState("SC138", "P")') > 0,
        "virtual RAlt navigation handler must not duplicate physical SC138 Escape")
}
Test("tap-holds: Kana SC138 owns navigation Escape exactly once (altgr-single-identity-2026-09-25)",
    _AKTE_NavigationOwnsKanaEscape)
