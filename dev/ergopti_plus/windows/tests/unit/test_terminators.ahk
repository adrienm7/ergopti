; static/ergopti_plus/windows/tests/unit/test_terminators.ahk

; ==============================================================================
; MODULE: Terminators Catalogue Tests
; DESCRIPTION:
; Covers the generated Terminators class (_generated/terminators.ahk) - the
; single source of truth for the word-expander catalogue, shared verbatim with
; the macOS driver through _shared/core/domain/Terminators.spec.js - and the pure
; word-delimiter helpers in infra/hotstrings/hotstrings_config.ahk that the tray
; submenu and the config window both build on.
;
; FEATURES & RATIONALE:
; 1. Default state: guards the catalogue defaults that both drivers share —
;    the basic terminators on (whitespace + sentence punctuation + magic key),
;    every other option off.
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
_TermHasKey(Terms, Key) {
    for D in Terms.all() {
        if (D.Has("key") and D["key"] == Key)
            return true
    }
    return false
}

; True when any non-separator slot owns the given character.
_TermCatalogueHasChar(Terms, Ch) {
    for D in Terms.all() {
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
    Terms := Terminators()
    ; Basic terminators ship ON: whitespace + sentence punctuation.
    AssertTrue(Terms.isTerminator(" "),  "space is a terminator by default")
    AssertFalse(Terms.isConsumed(" "),   "space is not consumed")
    AssertTrue(Terms.isTerminator("`t"), "tab is a terminator by default")
    AssertTrue(Terms.isTerminator("`r"), "enter (CR) is a terminator by default")
    AssertTrue(Terms.isTerminator("."),  "period is a terminator by default (basic)")
    AssertTrue(Terms.isTerminator(","),  "comma is a terminator by default (basic)")
    AssertTrue(Terms.isTerminator(";"),  "semicolon is a terminator by default (basic)")
    AssertTrue(Terms.isTerminator(":"),  "colon is a terminator by default (basic)")
    AssertTrue(Terms.isTerminator("!"),  "exclamation is a terminator by default (basic)")
    AssertTrue(Terms.isTerminator("?"),  "question is a terminator by default (basic)")
    AssertFalse(Terms.isTerminator("x"), "an ordinary letter is never a terminator")
}
Test("Terminators: basic punctuation enabled by default", TestTerminators_Defaults)

TestTerminators_MagicKeyConsumed() {
    Terms := Terminators()
    Star := Chr(0x2605)   ; star
    AssertTrue(Terms.isTerminator(Star), "magic key is a terminator by default")
    AssertTrue(Terms.isConsumed(Star), "magic key is consumed (swallowed, not echoed)")
}
Test("Terminators: magic key enabled and consumed", TestTerminators_MagicKeyConsumed)

TestTerminators_OptionsOffByDefault() {
    Terms := Terminators()
    ; The catalogue offers many options, but only the basics ship on. These are
    ; available-but-off until the user toggles them in the menu.
    AssertFalse(Terms.isTerminator(Chr(0x00A0)), "nbsp is off by default (an option)")
    AssertFalse(Terms.isTerminator(Chr(0x202F)), "narrow nbsp is off by default (an option)")
    AssertFalse(Terms.isTerminator(")"),         "closing paren is off by default (an option)")
    AssertFalse(Terms.isTerminator("/"),         "slash is off by default (an option)")
    AssertFalse(Terms.isTerminator("-"),         "dash is off by default (an option)")
    AssertFalse(Terms.isEnabled("apostrophe_straight"), "straight apostrophe is off by default")
    ; ...but they exist in the catalogue and resolve once enabled.
    Terms.setEnabled("parenright", true)
    AssertTrue(Terms.isTerminator(")"), "closing paren resolves once enabled")
}
Test("Terminators: non-basic options are off by default", TestTerminators_OptionsOffByDefault)




; ============================================================
; ============================================================
; ======= 3/ Superset content guarantees ====================
; ============================================================
; ============================================================

TestTerminators_SupersetAdditionsPresent() {
    Terms := Terminators()
    ; The ellipsis and semicolon slots were added when the two prior driver
    ; lists were merged into one catalogue - they MUST exist.
    AssertTrue(_TermHasKey(Terms, "ellipsis"),  "ellipsis slot present in the catalogue")
    AssertTrue(_TermHasKey(Terms, "semicolon"), "semicolon slot present in the catalogue")
    ; Semicolon is basic punctuation -> on; ellipsis is a fancier option -> off.
    AssertTrue(Terms.isEnabled("semicolon"), "semicolon enabled by default (basic punctuation)")
    AssertFalse(Terms.isEnabled("ellipsis"), "ellipsis off by default (an option)")
    ; The ellipsis char resolves once the slot is enabled.
    Terms.setEnabled("ellipsis", true)
    AssertTrue(Terms.isTerminator(Chr(0x2026)), "ellipsis becomes a terminator once enabled")
}
Test("Terminators: superset additions (ellipsis, semicolon) present", TestTerminators_SupersetAdditionsPresent)

TestTerminators_ClosingDelimitersOnly() {
    Terms := Terminators()
    ; Only the CLOSING delimiters end a word - the openings never do, so they
    ; must not appear anywhere in the catalogue.
    for OpenCh in ["(", "[", "{", "<"] {
        AssertFalse(_TermCatalogueHasChar(Terms, OpenCh),
            "opening delimiter must not be in the catalogue: " . OpenCh)
    }
    for CloseKey in ["parenright", "bracketright", "braceright", "anglebracketright"] {
        AssertTrue(_TermHasKey(Terms, CloseKey), "closing delimiter slot present: " . CloseKey)
    }
}
Test("Terminators: only closing delimiters are catalogued", TestTerminators_ClosingDelimitersOnly)

TestTerminators_MagicSlotKeyedStar() {
    ; The macOS registry's update_trigger_char and the codegen's updateMagicKey
    ; both target the magic slot by the key "star"; renaming it silently breaks
    ; magic-key retargeting on one driver.
    Terms := Terminators()
    AssertTrue(_TermHasKey(Terms, "star"), "magic key slot is keyed 'star'")
}
Test("Terminators: magic slot keyed 'star'", TestTerminators_MagicSlotKeyedStar)

TestTerminators_AllExposesSeparators() {
    Terms := Terminators()
    SepCount := 0
    for D in Terms.all() {
        if (D.Has("type") and D["type"] == "separator")
            SepCount += 1
    }
    AssertTrue(SepCount >= 4, "catalogue carries separator dividers for the menus")
    AssertTrue(Terms.all().Length > 5, "catalogue is non-trivial")
}
Test("Terminators: all() exposes separators and the full catalogue", TestTerminators_AllExposesSeparators)




; ============================================================
; ============================================================
; ======= 4/ Enable / magic-key / custom lifecycle ==========
; ============================================================
; ============================================================

TestTerminators_EnableDisable() {
    Terms := Terminators()
    Terms.setEnabled("space", false)
    AssertFalse(Terms.isTerminator(" "), "space disabled -> not a terminator")
    AssertFalse(Terms.isEnabled("space"), "isEnabled mirrors the disabled state")
    Terms.setEnabled("space", true)
    AssertTrue(Terms.isTerminator(" "), "space re-enabled -> terminator again")
}
Test("Terminators: enable/disable round-trip", TestTerminators_EnableDisable)

TestTerminators_UpdateMagicKey() {
    Terms := Terminators()
    Section := Chr(0x00A7)   ; section sign, stand-in new magic key
    Terms.updateMagicKey(Section)
    AssertTrue(Terms.isTerminator(Section), "new magic-key char becomes a terminator")
    AssertTrue(Terms.isConsumed(Section), "new magic-key char is consumed")
    AssertFalse(Terms.isTerminator(Chr(0x2605)), "the old star is no longer a terminator")
}
Test("Terminators: updateMagicKey retargets the star slot", TestTerminators_UpdateMagicKey)

TestTerminators_CustomLifecycle() {
    Terms := Terminators()
    AssertTrue(Terms.addCustom("at_sign", ["@"], "@ custom", true),
        "addCustom reports the exact catalogue commitment")
    AssertTrue(Terms.isTerminator("@"), "custom terminator is recognised")
    AssertTrue(Terms.isConsumed("@"), "custom terminator honours its consumed flag")
    AssertTrue(Terms.isEnabled("at_sign"), "custom terminator is enabled on add")
}
Test("Terminators: addCustom registers a new slot", TestTerminators_CustomLifecycle)

TestTerminators_CustomCharCollisionRefused() {
    Terms := Terminators()
    BeforeCount := Terms.all().Length
    AssertFalse(Terms.addCustom("custom_comma", [","], "duplicate comma", true),
        "addCustom reports an exact character-collision refusal")
    AssertEqual(BeforeCount, Terms.all().Length,
        "a custom slot cannot claim a character already owned by the catalogue")
    AssertFalse(Terms.isEnabled("custom_comma"),
        "a rejected character collision must not publish an enabled slot")
    AssertFalse(Terms.isConsumed(","),
        "a rejected custom policy must not overwrite the built-in comma policy")
}
Test("Terminators: addCustom rejects character collisions", TestTerminators_CustomCharCollisionRefused)

TestTerminators_CustomCharIdentityIsCaseSensitive() {
    Terms := Terminators()
    AssertTrue(Terms.addCustom("custom_lower_a", ["a"], "lowercase a", false),
        "a lowercase custom terminator is accepted")
    AssertTrue(Terms.addCustom("custom_upper_a", ["A"], "uppercase A", false),
        "character ownership distinguishes uppercase from lowercase")
    AssertTrue(Terms.isTerminator("a"), "the lowercase character remains registered")
    AssertTrue(Terms.isTerminator("A"), "the uppercase character is independently registered")
}
Test("Terminators: custom character identity is case-sensitive", TestTerminators_CustomCharIdentityIsCaseSensitive)




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




; ============================================================
; ============================================================
; ======= 6/ Catalogue-derived defaults (basic set) =========
; ============================================================
; ============================================================

TestTerminators_DefaultWordDelimitersAreBasic() {
    ; The default word-terminator set is derived from the catalogue and must be
    ; the BASIC set: whitespace + sentence punctuation + the magic key — nothing
    ; fancier. This is the single source the AHK boot wiring reads, kept in
    ; lock-step with macOS.
    D := HSE_TerminatorDefaultWordDelimiters()
    for Ch in [" ", "`t", "`r", "`n", ".", ",", ";", ":", "!", "?", Chr(0x2605)] {
        AssertTrue(InStr(D, Ch) > 0, "default set includes a basic terminator")
    }
    ; Non-basic options must be OFF in the default set.
    for Ch in [Chr(0x00A0), Chr(0x202F), "-", "_", "=", ")", "]", "}", ">", "/", "\", Chr(0x2026), "'", '"'] {
        AssertFalse(InStr(D, Ch) > 0, "default set excludes a non-basic option")
    }
}
Test("Terminators: default word-delimiters are the basic set", TestTerminators_DefaultWordDelimitersAreBasic)

TestTerminators_DefaultConsumedIsMagicKeyOnly() {
    ; Only the magic key is consumed out of the box (matches macOS).
    C := HSE_TerminatorDefaultConsumedDelimiters()
    AssertTrue(InStr(C, Chr(0x2605)) > 0, "magic key is consumed by default")
    AssertFalse(InStr(C, " ") > 0, "space is not consumed by default")
    AssertFalse(InStr(C, ".") > 0, "period is not consumed by default")
}
Test("Terminators: default consumed set is the magic key only", TestTerminators_DefaultConsumedIsMagicKeyOnly)

TestTerminators_GlobalDefaultsMatchCatalogue() {
    ; The boot-time globals must equal the catalogue-derived defaults so AHK and
    ; macOS start from the same set (no hardcoded drift).
    AssertEqual(HSE_TerminatorDefaultWordDelimiters(), HOTSTRINGS_DEFAULT_WORD_DELIMITERS,
        "HOTSTRINGS_DEFAULT_WORD_DELIMITERS is catalogue-derived")
    AssertEqual(HSE_TerminatorDefaultConsumedDelimiters(), HOTSTRINGS_DEFAULT_CONSUMED_DELIMITERS,
        "HOTSTRINGS_DEFAULT_CONSUMED_DELIMITERS is catalogue-derived")
}
Test("Terminators: boot-time default globals are catalogue-derived", TestTerminators_GlobalDefaultsMatchCatalogue)





; ============================================================
; ============================================================
; ======= 7/ Magic key as a terminator (engine parity) =======
; ============================================================
; ============================================================

; Aligning AHK with macOS makes the magic key a consumed word terminator in
; ADDITION to its dedicated star-trigger role on Windows. These tests prove the
; two mechanisms coexist in the engine: a non-star trigger fires when the magic
; key terminates it, a star trigger still fires on the magic key, and when both
; could match the longer star trigger wins (no double fire — the engine's
; _HSE_StarTriggerCoversBody guard). Regression guard for the alignment change.

TestTerminators_MagicKeyTerminatesNonStarTrigger() {
    global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
    SavedWT := HSE_WORD_TERMINATORS
    SavedCD := HSE_CONSUMED_DELIMITERS
    Star := Chr(0x2605)
    HSE_TestReset()
    HSE_WORD_TERMINATORS    := " " . Star
    HSE_CONSUMED_DELIMITERS := Star
    HSE_Register("", "btw", () => 0)          ; regular (non-star) trigger
    HSE_FeedChar("b")
    HSE_FeedChar("t")
    AssertEqual("", HSE_FeedChar("w"), "non-star trigger does not fire on its body alone")
    Match := HSE_FeedChar(Star)
    AssertTrue(Match != "", "non-star trigger fires when the magic key terminates it")
    AssertEqual("btw", Match.Trigger)
    HSE_WORD_TERMINATORS    := SavedWT
    HSE_CONSUMED_DELIMITERS := SavedCD
}
Test("Terminators: magic key terminates a non-star trigger (macOS parity)", TestTerminators_MagicKeyTerminatesNonStarTrigger)

TestTerminators_StarTriggerStillFiresWithMagicKeyTerminator() {
    global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
    SavedWT := HSE_WORD_TERMINATORS
    SavedCD := HSE_CONSUMED_DELIMITERS
    Star := Chr(0x2605)
    HSE_TestReset()
    HSE_WORD_TERMINATORS    := " " . Star
    HSE_CONSUMED_DELIMITERS := Star
    HSE_Register("*", "gg" . Star, () => 0)   ; star trigger (magic-key mechanism)
    HSE_FeedChar("g")
    HSE_FeedChar("g")
    Match := HSE_FeedChar(Star)
    AssertTrue(Match != "", "star trigger still fires on the magic key")
    AssertEqual("gg" . Star, Match.Trigger)
    HSE_WORD_TERMINATORS    := SavedWT
    HSE_CONSUMED_DELIMITERS := SavedCD
}
Test("Terminators: star trigger still fires when the magic key is also a terminator", TestTerminators_StarTriggerStillFiresWithMagicKeyTerminator)

TestTerminators_StarTriggerWinsOverEndCharOnMagicKey() {
    global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
    SavedWT := HSE_WORD_TERMINATORS
    SavedCD := HSE_CONSUMED_DELIMITERS
    Star := Chr(0x2605)
    HSE_TestReset()
    HSE_WORD_TERMINATORS    := " " . Star
    HSE_CONSUMED_DELIMITERS := Star
    ; Both could match on "ab" + magic key: the star trigger "ab*" and the
    ; non-star "ab" with the magic key as its end char. The longer star trigger
    ; must win — no double expansion.
    HSE_Register("*", "ab" . Star, () => 0)
    HSE_Register("", "ab", () => 0)
    HSE_FeedChar("a")
    HSE_FeedChar("b")
    Match := HSE_FeedChar(Star)
    AssertTrue(Match != "", "a match fires on the magic key")
    AssertEqual("ab" . Star, Match.Trigger, "the star trigger wins over the end-char match")
    HSE_WORD_TERMINATORS    := SavedWT
    HSE_CONSUMED_DELIMITERS := SavedCD
}
Test("Terminators: star trigger wins over the end-char match on the magic key", TestTerminators_StarTriggerWinsOverEndCharOnMagicKey)
