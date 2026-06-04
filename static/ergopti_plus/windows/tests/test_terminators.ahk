; static/ergopti_plus/windows/tests/test_terminators.ahk

; ==============================================================================
; MODULE: Terminators Catalogue Tests
; DESCRIPTION:
; Covers the generated Terminators class (_generated/terminators.ahk) - the
; single source of truth for the word-expander catalogue, shared verbatim with
; the macOS driver through shared/domain/Terminators.spec.js - and the pure
; word-delimiter helpers in lib/hotstrings/hotstrings_config.ahk that the tray
; submenu and the config window both build on.
;
; FEATURES & RATIONALE:
; 1. Default state: guards the catalogue defaults that both drivers share
;    (space / non-breaking spaces / comma / magic key on; punctuation off).
; 2. Superset content: asserts the entries added when the two prior lists were
;    merged (ellipsis, semicolon) exist, and that ONLY closing delimiters made
;    the cut - a regression here would resurface the old duplicated lists.
; 3. Magic slot key: the slot must stay keyed "star" so the macOS registry's
;    update_trigger_char sync and the codegen's updateMagicKey keep matching.
; 4. Pure helpers: the enable / toggle / set-all string logic is tested here so
;    the menu wrappers stay thin and a logic regression fails fast in CI.
;
; Non-ASCII glyphs are spelled with Chr(0xNNNN) so a source-encoding regression
; can never silently drop them (see the AHK section of copilot-instructions).
; ==============================================================================




; ============================================================
; ============================================================
; ======= 1/ Catalogue helpers (test-local) =================
; ============================================================
; ============================================================

; True when the catalogue exposes a slot with the given key.
_TermHasKey(T, Key) {
    for D in T.all() {
        if (D.Has("key") and D["key"] == Key)
            return true
    }
    return false
}

; True when any non-separator slot owns the given character.
_TermCatalogueHasChar(T, Ch) {
    for D in T.all() {
        if (D.Has("type") and D["type"] == "separator")
            continue
        for C in D["chars"] {
            if (C == Ch)
                return true
        }
    }
    return false
}




; ============================================================
; ============================================================
; ======= 2/ Default catalogue state ========================
; ============================================================
; ============================================================

TestTerminators_Defaults() {
    T := Terminators()
    AssertTrue(T.isTerminator(" "), "space is a terminator by default")
    AssertFalse(T.isConsumed(" "), "space is not consumed")
    AssertTrue(T.isTerminator(","), "comma is a terminator by default")
    AssertFalse(T.isTerminator("."), "period is disabled by default (mirrors macOS)")
    AssertFalse(T.isTerminator("x"), "an ordinary letter is never a terminator")
}
Test("Terminators: default enabled/consumed state", TestTerminators_Defaults)

TestTerminators_MagicKeyConsumed() {
    T := Terminators()
    Star := Chr(0x2605)   ; star
    AssertTrue(T.isTerminator(Star), "magic key is a terminator by default")
    AssertTrue(T.isConsumed(Star), "magic key is consumed (swallowed, not echoed)")
}
Test("Terminators: magic key enabled and consumed", TestTerminators_MagicKeyConsumed)

TestTerminators_NonBreakingSpacesDefaultOn() {
    T := Terminators()
    AssertTrue(T.isTerminator(Chr(0x00A0)), "nbsp is a terminator by default")
    AssertTrue(T.isTerminator(Chr(0x202F)), "narrow nbsp is a terminator by default")
}
Test("Terminators: non-breaking spaces enabled by default", TestTerminators_NonBreakingSpacesDefaultOn)




; ============================================================
; ============================================================
; ======= 3/ Superset content guarantees ====================
; ============================================================
; ============================================================

TestTerminators_SupersetAdditionsPresentButOff() {
    T := Terminators()
    ; The ellipsis and semicolon slots were added when the two prior driver
    ; lists were merged into one catalogue - they MUST exist...
    AssertTrue(_TermHasKey(T, "ellipsis"),  "ellipsis slot present in the catalogue")
    AssertTrue(_TermHasKey(T, "semicolon"), "semicolon slot present in the catalogue")
    ; ...but ship disabled, like their punctuation siblings.
    AssertFalse(T.isEnabled("ellipsis"),  "ellipsis disabled by default")
    AssertFalse(T.isEnabled("semicolon"), "semicolon disabled by default")
    ; The ellipsis char resolves once the slot is enabled.
    T.setEnabled("ellipsis", true)
    AssertTrue(T.isTerminator(Chr(0x2026)), "ellipsis becomes a terminator once enabled")
}
Test("Terminators: superset additions (ellipsis, semicolon) present but off", TestTerminators_SupersetAdditionsPresentButOff)

TestTerminators_ClosingDelimitersOnly() {
    T := Terminators()
    ; Only the CLOSING delimiters end a word - the openings never do, so they
    ; must not appear anywhere in the catalogue.
    for OpenCh in ["(", "[", "{", "<"] {
        AssertFalse(_TermCatalogueHasChar(T, OpenCh),
            "opening delimiter must not be in the catalogue: " . OpenCh)
    }
    for CloseKey in ["parenright", "bracketright", "braceright", "anglebracketright"] {
        AssertTrue(_TermHasKey(T, CloseKey), "closing delimiter slot present: " . CloseKey)
    }
}
Test("Terminators: only closing delimiters are catalogued", TestTerminators_ClosingDelimitersOnly)

TestTerminators_MagicSlotKeyedStar() {
    ; The macOS registry's update_trigger_char and the codegen's updateMagicKey
    ; both target the magic slot by the key "star"; renaming it silently breaks
    ; magic-key retargeting on one driver.
    T := Terminators()
    AssertTrue(_TermHasKey(T, "star"), "magic key slot is keyed 'star'")
}
Test("Terminators: magic slot keyed 'star'", TestTerminators_MagicSlotKeyedStar)

TestTerminators_AllExposesSeparators() {
    T := Terminators()
    SepCount := 0
    for D in T.all() {
        if (D.Has("type") and D["type"] == "separator")
            SepCount += 1
    }
    AssertTrue(SepCount >= 4, "catalogue carries separator dividers for the menus")
    AssertTrue(T.all().Length > 5, "catalogue is non-trivial")
}
Test("Terminators: all() exposes separators and the full catalogue", TestTerminators_AllExposesSeparators)




; ============================================================
; ============================================================
; ======= 4/ Enable / magic-key / custom lifecycle ==========
; ============================================================
; ============================================================

TestTerminators_EnableDisable() {
    T := Terminators()
    T.setEnabled("space", false)
    AssertFalse(T.isTerminator(" "), "space disabled -> not a terminator")
    AssertFalse(T.isEnabled("space"), "isEnabled mirrors the disabled state")
    T.setEnabled("space", true)
    AssertTrue(T.isTerminator(" "), "space re-enabled -> terminator again")
}
Test("Terminators: enable/disable round-trip", TestTerminators_EnableDisable)

TestTerminators_UpdateMagicKey() {
    T := Terminators()
    Section := Chr(0x00A7)   ; section sign, stand-in new magic key
    T.updateMagicKey(Section)
    AssertTrue(T.isTerminator(Section), "new magic-key char becomes a terminator")
    AssertTrue(T.isConsumed(Section), "new magic-key char is consumed")
    AssertFalse(T.isTerminator(Chr(0x2605)), "the old star is no longer a terminator")
}
Test("Terminators: updateMagicKey retargets the star slot", TestTerminators_UpdateMagicKey)

TestTerminators_CustomLifecycle() {
    T := Terminators()
    T.addCustom("at_sign", ["@"], "@ custom", true)
    AssertTrue(T.isTerminator("@"), "custom terminator is recognised")
    AssertTrue(T.isConsumed("@"), "custom terminator honours its consumed flag")
    AssertTrue(T.isEnabled("at_sign"), "custom terminator is enabled on add")
}
Test("Terminators: addCustom registers a new slot", TestTerminators_CustomLifecycle)




; ============================================================
; ============================================================
; ======= 5/ Shared word-delimiter string helpers ===========
; ============================================================
; ============================================================

TestTerminators_BuiltinCharsExcludesSeparators() {
    Chars := HSE_TerminatorBuiltinChars()
    AssertTrue(InStr(Chars, " ") > 0, "built-in chars include space")
    AssertTrue(InStr(Chars, ",") > 0, "built-in chars include comma")
    AssertTrue(InStr(Chars, "-") > 0, "built-in chars include the dash slot")
    AssertTrue(InStr(Chars, Chr(0x2026)) > 0, "built-in chars include the ellipsis")
}
Test("Terminators: HSE_TerminatorBuiltinChars covers catalogue chars", TestTerminators_BuiltinCharsExcludesSeparators)

TestTerminators_EntryEnabledHelper() {
    AssertTrue(HSE_TerminatorEntryEnabled([","], ".,;"), "single-char entry present -> enabled")
    AssertFalse(HSE_TerminatorEntryEnabled(["!"], ".,;"), "single-char entry absent -> disabled")
    ; A multi-char entry (Entree = CR+LF) needs ALL of its chars present.
    AssertTrue(HSE_TerminatorEntryEnabled(["`r", "`n"], " `r`n."), "enter entry with both CR and LF -> enabled")
    AssertFalse(HSE_TerminatorEntryEnabled(["`r", "`n"], " `r."), "enter entry missing LF -> disabled")
    AssertFalse(HSE_TerminatorEntryEnabled([], "abc"), "empty chars -> never enabled")
}
Test("Terminators: HSE_TerminatorEntryEnabled multi-char semantics", TestTerminators_EntryEnabledHelper)

TestTerminators_ToggleStringHelper() {
    ; Absent -> added.
    R1 := HSE_TerminatorToggleString(" .", [","])
    AssertTrue(InStr(R1, ",") > 0, "toggling an absent entry adds its char")
    ; Present -> removed.
    R2 := HSE_TerminatorToggleString(" .,", [","])
    AssertFalse(InStr(R2, ",") > 0, "toggling a present entry removes its char")
    ; Multi-char entry adds/removes as a unit.
    R3 := HSE_TerminatorToggleString(" .", ["`r", "`n"])
    AssertTrue((InStr(R3, "`r") > 0) and (InStr(R3, "`n") > 0), "toggling enter adds both CR and LF")
}
Test("Terminators: HSE_TerminatorToggleString add/remove", TestTerminators_ToggleStringHelper)

TestTerminators_SetAllStringHelper() {
    ; Disable-all keeps only custom chars (here "@") and drops every built-in.
    Off := HSE_TerminatorSetAllString(" .,@", false)
    AssertTrue(InStr(Off, "@") > 0, "set-all(false) preserves custom chars")
    AssertFalse(InStr(Off, " ") > 0, "set-all(false) drops built-in space")
    AssertFalse(InStr(Off, ",") > 0, "set-all(false) drops built-in comma")
    ; Enable-all turns every built-in on while still preserving the custom char.
    On := HSE_TerminatorSetAllString("@", true)
    AssertTrue(InStr(On, " ") > 0, "set-all(true) enables space")
    AssertTrue(InStr(On, ",") > 0, "set-all(true) enables comma")
    AssertTrue(InStr(On, "@") > 0, "set-all(true) still preserves the custom char")
}
Test("Terminators: HSE_TerminatorSetAllString enable/disable", TestTerminators_SetAllStringHelper)

TestTerminators_GlobalInstance() {
    ; The shared instance the menus render must exist and carry the catalogue.
    AssertTrue(IsObject(HSE_Terminators), "HSE_Terminators global instance exists")
    AssertTrue(HSE_Terminators.all().Length > 5, "HSE_Terminators exposes the catalogue")
}
Test("Terminators: HSE_Terminators global instance is ready", TestTerminators_GlobalInstance)
