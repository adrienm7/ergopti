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





; =======================================================
; =======================================================
; ======= 4/ Foreign Inline Writer Prerequisite ========
; =======================================================
; =======================================================

_HTRI_Source() {
	return 'hotstrings = { terminators = [{ key = "currency", char = "¤", label = "Currency", consume = false, metadata = { tag = "retain" } }], terminator_states.currency = true, unknown = { nested = ["a,b", "{keep}", { child = "x=y" }], exact = "a # b" } } # parent comment`n[layout]`nenabled=true`n'
}

_HTRI_AssertForeign(InlineContent) {
	AssertContains(InlineContent, ' unknown = { nested = ["a,b", "{keep}", { child = "x=y" }], exact = "a # b" } ',
		"the complete unrelated inline member must remain lexically exact")
	AssertContains(InlineContent, '} # parent comment`n', "the outer closure and comment remain exact")
	AssertEqual("a,b", TOML_ParseDocument(InlineContent)["hotstrings"]["unknown"]["nested"][1])
}


_HTRI_CanonicalSibling(InlineLeaf) {
	InlinePath := _TBUI_NewPath(), InlineFixtureSource := _HTRI_Source()
	try {
		AssertTrue(FSWriteCreateDurable(InlinePath, InlineFixtureSource) == 1)
		InlineUpdates := InlineLeaf ? [{ Section: "hotstrings", Key: "custom_pref", Value: "new" }]
			: [{ Section: "layout", Key: "enabled", Value: TOML_Bool(false) }]
		Prepared := TOML_BuildUpdatedContent(InlinePath, InlineUpdates)
		AssertEqual("ok", Prepared["status"], "a qualified inline partition must admit the requested sibling")
		AssertEqual(InlineFixtureSource, Prepared["source_content"], "the exact old source binds admission")
		AssertTrue(FSUtf8ExactMatches(InlinePath, InlineFixtureSource), "detached preparation has no publication effects")
		_HTRI_AssertForeign(Prepared["content"])
		PreparedDocument := TOML_ParseDocument(Prepared["content"])
		AssertEqual("retain", PreparedDocument["hotstrings"]["terminators"][1]["metadata"]["tag"])
		AssertContains(Prepared["content"], ' terminators = [{ key = "currency", char = "¤", label = "Currency", consume = false, metadata = { tag = "retain" } }]')
		if InlineLeaf
			AssertEqual("new", PreparedDocument["hotstrings"]["custom_pref"])
		else
			AssertEqual(false, PreparedDocument["layout"]["enabled"].Value)
		AssertTrue(TOML_BatchWrite(InlinePath, InlineUpdates))
		AssertTrue(FSUtf8ExactMatches(InlinePath, Prepared["content"]), "actual native publication equals the independently qualified detached image")
	} finally FSDelete(InlinePath)
}
Test("terminator-inline: actual canonical and native sibling save retains a handwritten inline record parent", _HTRI_CanonicalSibling.Bind(false))
Test("terminator-inline: actual native scalar sibling edit does not borrow record or foreign member authority", _HTRI_CanonicalSibling.Bind(true))

_HTRI_ProtectedRefusal(InlineUpdates, InlinePrefixes := []) {
	InlinePath := _TBUI_NewPath(), InlineFixtureSource := _HTRI_Source()
	try {
		AssertTrue(FSWriteCreateDurable(InlinePath, InlineFixtureSource) == 1)
		AssertEqual("error", TOML_BuildUpdatedContent(InlinePath, InlineUpdates, InlinePrefixes)["status"],
			"a protected record parent must refuse ordinary replacement authority")
		AssertFalse(TOML_BatchWrite(InlinePath, InlineUpdates, InlinePrefixes))
		AssertTrue(FSUtf8ExactMatches(InlinePath, InlineFixtureSource), "refusal retains the complete actual source")
	} finally FSDelete(InlinePath)
}
Test("terminator-inline: the canonical writer cannot replace records with a collapsed flat leaf", _HTRI_ProtectedRefusal.Bind([{ Section: "hotstrings", Key: "terminators", Value: [] }]))
Test("terminator-inline: a native case alias cannot acquire the closed parent", _HTRI_ProtectedRefusal.Bind([{ Section: "HOTSTRINGS", Key: "custom_pref", Value: "new" }]))
Test("terminator-inline: namespace replacement cannot delete unknown parent members", _HTRI_ProtectedRefusal.Bind([], ["hotstrings"]))





; =============================================================
; =============================================================
; ======= 10/ Typed Custom Terminator Records ==================
; =============================================================
; =============================================================

_HTR_Source() {
	return '[private]`ncredential = "keep"`n'
		. '[["hotstrings"."terminators"]] # owned table array`nkey = "currency"`nchar = "¤"`nlabel = "Currency"`nconsume = true`nmetadata = { future = "keep", count = 7 }`n'
		. '[[hotstrings.terminators]]`nkey = "smile"`nchar = "😀"`nlabel = "Smile"`nconsume = false`n'
		. '[[foreign.rows]]`nvalue = "never alter" # foreign comment`n'
}

_HTR_WithRuntime(Body) {
	global _HotstringsTerminatorRecords, _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Saved := { Owner: _HotstringsTerminatorRecords, Word: _HotstringsWordDelimiters,
		Consumed: _HotstringsConsumedDelimiters, EngineWord: HSE_WORD_TERMINATORS,
		EngineConsumed: HSE_CONSUMED_DELIMITERS }
	try {
		_HotstringsTerminatorRecords := 0
		_HotstringsWordDelimiters := "!", _HotstringsConsumedDelimiters := "!"
		return Body.Call()
	} finally {
		_HotstringsTerminatorRecords := Saved.Owner
		_HotstringsWordDelimiters := Saved.Word
		_HotstringsConsumedDelimiters := Saved.Consumed
		HSE_WORD_TERMINATORS := Saved.EngineWord
		HSE_CONSUMED_DELIMITERS := Saved.EngineConsumed
	}
}

_HTR_BootProjectionBody() {
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	AssertEqual(true, HotstringsTerminatorRecordsInit(_HTR_Source()))
	AssertEqual("!¤😀", HotstringsGetWordDelimiters(), "the actual consumer must publish both admitted scalars")
	AssertEqual("!¤", HotstringsGetConsumedDelimiters(), "only the independently consumed record joins the consumed set")
	AssertEqual("!", _HotstringsWordDelimiters, "record loading must preserve the historical word preference")
	AssertEqual("!", _HotstringsConsumedDelimiters, "record loading must preserve the historical consumed preference")
}
_HTR_BootProjection() {
	_HTR_WithRuntime(_HTR_BootProjectionBody)
}
Test("terminator-records: actual boot consumer projects AOT and Unicode without changing string controls", _HTR_BootProjection)

_HTR_InlineRecords() {
	InlineRecordSource := 'hotstrings.terminators = [{ key = "upper", char = "A", label = "Upper", consume = false }, { key = "lower", char = "a", label = "Lower", consume = true }]`n'
	Resolved := HotstringsTerminatorRecordsResolve(TOML_ParseDocument(InlineRecordSource))
	AssertEqual(2, Resolved.Records.Length, "case-sensitive scalar identity must match the shared catalogue")
	AssertEqual("A", Resolved.Records[1].Char)
	AssertEqual("a", Resolved.Records[2].Char)
	AssertEqual(0, Resolved.Rejected.Length)
}
Test("terminator-records: actual typed inline list preserves case-sensitive scalar identities", _HTR_InlineRecords)

_HTR_InvalidRecords() {
	InvalidRecordSource := 'hotstrings.terminators = ['
		. '{ key = "space", char = "¤", label = "Builtin", consume = false },'
		. '{ key = "two", char = "xy", label = "Two", consume = false },'
		. '{ key = "integer", char = "¤", label = "Integer", consume = 1 },'
		. '{ key = "duplicate_char", char = " ", label = "Space", consume = false },'
		. '{ key = "good", char = "¤", label = "Good", consume = true },'
		. '{ key = "good", char = "😀", label = "Duplicate", consume = false }]`n'
	Resolved := HotstringsTerminatorRecordsResolve(TOML_ParseDocument(InvalidRecordSource))
	AssertEqual(1, Resolved.Records.Length)
	AssertEqual("good", Resolved.Records[1].Key)
	AssertEqual(5, Resolved.Rejected.Length)
	for RejectedOrdinal, Reason in ["key_collision", "invalid_character", "invalid_consume", "character_collision", "key_collision"]
		AssertEqual(Reason, Resolved.Rejected[RejectedOrdinal]["reason"], "each independently invalid row must retain its refusal reason")
}
Test("terminator-records: actual reader quarantines invalid rows and retains the independent valid row", _HTR_InvalidRecords)

_HTR_InvalidScalar() {
	for InvalidScalar in ["", "ab", Chr(0xD800), Chr(0xDC00), Chr(0xD800) . "a", 0, []]
		AssertEqual(false, HotstringsTerminatorRecordCharacter(InvalidScalar))
	AssertEqual(true, HotstringsTerminatorRecordCharacter("😀"))
	AssertEqual(true, HotstringsTerminatorRecordCharacter("¤"))
}
Test("terminator-records: one exact scalar rejects truncated surrogate and malformed inputs", _HTR_InvalidScalar)

_HTR_DuplicateInitBody() {
	HotstringsTerminatorRecordsInit(_HTR_Source())
	AssertThrows(HotstringsTerminatorRecordsInit.Bind(""), "a second initializer cannot replace a live boot owner")
	AssertEqual("!¤😀", HotstringsGetWordDelimiters())
}
_HTR_DuplicateInit() {
	_HTR_WithRuntime(_HTR_DuplicateInitBody)
}
Test("terminator-records: explicit initialization rejects a second source owner", _HTR_DuplicateInit)

_HTR_Upsert() {
	Record := Map("key", "currency", "char", "§", "label", "Updated", "consume", TOML_Bool(false))
	Plan := HotstringsTerminatorRecordPlan(_HTR_Source(), Map("mode", "upsert", "record", Record))
	Document := TOML_ParseDocument(Plan.Content)
	AssertEqual("§", Document["hotstrings"]["terminators"][1]["char"])
	AssertEqual("keep", Document["hotstrings"]["terminators"][1]["metadata"]["future"])
	AssertEqual(7, Document["hotstrings"]["terminators"][1]["metadata"]["count"])
	AssertContains(Plan.Content, '[[foreign.rows]]`nvalue = "never alter" # foreign comment`n')
	AssertContains(Plan.Content, '[private]`ncredential = "keep"`n')
	AssertEqual(2, Plan.Settings.Records.Length)
}
Test("terminator-records: editing an actual AOT record preserves unknown metadata and foreign spans", _HTR_Upsert)

_HTR_SiblingCollision() {
	Record := Map("key", "currency", "char", "😀", "label", "Collision", "consume", TOML_Bool(false))
	AssertThrows(HotstringsTerminatorRecordPlan.Bind(_HTR_Source(),
		Map("mode", "upsert", "record", Record)), "an earlier row must not steal an admitted later sibling scalar")
}
Test("terminator-records: an upsert cannot silently quarantine a later admitted sibling", _HTR_SiblingCollision)

_HTR_Remove() {
	RemovalSource := _HTR_Source() . '[[hotstrings.terminators]]`nkey = "old_bad"`nchar = "zz"`nlabel = "Keep quarantined"`nconsume = false`nunknown = "retain"`n'
	Plan := HotstringsTerminatorRecordPlan(RemovalSource, Map("mode", "remove", "key", "currency"))
	Document := TOML_ParseDocument(Plan.Content)
	AssertEqual(2, Document["hotstrings"]["terminators"].Length)
	AssertEqual("smile", Document["hotstrings"]["terminators"][1]["key"])
	AssertEqual("retain", Document["hotstrings"]["terminators"][2]["unknown"])
	AssertEqual(1, Plan.Settings.Records.Length)
	AssertEqual("never alter", Document["foreign"]["rows"][1]["value"])
}
Test("terminator-records: removing one admitted record retains quarantined rows and foreign tables", _HTR_Remove)

_HTR_StateBody() {
	global _HotstringsTerminatorRecords, _HotstringsWordDelimiters
	Plan := HotstringsTerminatorRecordPlan(_HTR_Source(), Map("mode", "state", "key", "currency", "enabled", false))
	_HotstringsTerminatorRecords := Plan.Settings
	_HotstringsWordDelimiters := "!¤"
	AssertEqual("!😀", HotstringsGetWordDelimiters(), "a disabled record owns its scalar even in the older string")
	AssertEqual("!", HotstringsGetConsumedDelimiters())
	AssertEqual("!¤", _HotstringsWordDelimiters, "effective record projection must not rewrite historical preferences")
	AssertThrows(HotstringsTerminatorRecordPlan.Bind(_HTR_Source(),
		Map("mode", "state", "key", "currency", "enabled", "false")))
}
_HTR_State() {
	_HTR_WithRuntime(_HTR_StateBody)
}
Test("terminator-records: exact record state projection and typed edit preserve legacy strings", _HTR_State)

_HTR_ParentInlineEdit() {
	ParentFixtureSource := 'hotstrings = { terminators = [{ key = "one", char = "¤", label = "One", consume = false }], unknown = "keep" }`n'
	AssertEqual(1, HotstringsTerminatorRecordsResolve(TOML_ParseDocument(ParentFixtureSource)).Records.Length)
	ParentEdited := HotstringsTerminatorRecordPlan(ParentFixtureSource, Map("mode", "remove", "key", "one"))
	AssertEqual(0, TOML_ParseDocument(ParentEdited.Content)["hotstrings"]["terminators"].Length)
	AssertEqual("keep", TOML_ParseDocument(ParentEdited.Content)["hotstrings"]["unknown"])
	AssertContains(ParentEdited.Content, ' unknown = "keep" }`n', "an inline edit preserves the exact unrelated member and closure")
}
Test("terminator-records: actual inline parent removal preserves the independent foreign member", _HTR_ParentInlineEdit)

_HTR_Operation() {
	return Map("mode", "upsert", "record", Map("key", "section", "char", "§",
		"label", "Section", "consume", TOML_Bool(false)))
}

_HTR_WalLifecycle(Refuse) {
	Fixture := _ScopeOwnerFixture()
	Assert(FSWriteDurable(Fixture.path, _HTR_Source()))
	Bundle := 0, OnSuccess := 0, OnRefused := 0, Calls := 0
	Launch(Success, Borrowed, Refused) {
		Bundle := Borrowed, OnSuccess := Success, OnRefused := Refused
		Calls += 1
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		Receipt := HotstringsTerminatorRecordsEdit(_HTR_Operation(), Fixture.options)
		AssertEqual(1, Calls, "actual durable publication must reach the reload admission")
		AssertEqual("pending", Receipt["status"], "durable write is not a runtime acknowledgement")
		AssertEqual(3, TOML_ParseDocument(FSReadUtf8Exact(Fixture.path))["hotstrings"]["terminators"].Length)
		Assert(!_ConfigWriteLeaseTryAcquire(Fixture.path, "intruder"), "reload owns the configuration barrier")
		if Refuse {
			OnRefused.Call("controlled refusal")
			AssertEqual("refused", Receipt["status"])
			AssertEqual(_HTR_Source(), FSReadUtf8Exact(Fixture.path), "the genuine rollback must restore all original bytes")
			Receipt := HotstringsTerminatorRecordsEdit(_HTR_Operation(), Fixture.options)
			AssertEqual("pending", Receipt["status"], "settled refusal permits one new admitted retry")
			OnRefused.Call("controlled second refusal")
			AssertEqual(_HTR_Source(), FSReadUtf8Exact(Fixture.path))
		} else {
			OnSuccess.Call()
			AssertEqual("committed", Receipt["status"], "only the actual replacement callback acknowledges runtime completion")
		}
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("terminator-records: genuine WAL commit retains pending ownership until reload ACK", _HTR_WalLifecycle.Bind(false))
Test("terminator-records: genuine refused reload rolls back exact bytes and permits an admitted retry", _HTR_WalLifecycle.Bind(true))

_HTR_ForeignSource() {
	Fixture := _ScopeOwnerFixture()
	Assert(FSWriteDurable(Fixture.path, _HTR_Source()))
	Port := ConfigTransitionProductionPort(), NativeHash := Port["hash"]
	Changed := false, Foreign := _HTR_Source() . '# independently changed source`n'
	Hash(Content) {
		Digest := NativeHash.Call(Content)
		if !Changed && Content == _HTR_Source() {
			Changed := true
			Assert(FSWriteDurable(Fixture.path, Foreign))
		}
		return Digest
	}
	Port["hash"] := Hash
	Fixture.options["port"] := Port
	Bundle := 0, OnRefused := 0, Launches := 0
	Launch(Success, Borrowed, Refused) {
		Launches += 1, Bundle := Borrowed, OnRefused := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		Receipt := HotstringsTerminatorRecordsEdit(_HTR_Operation(), Fixture.options)
		AssertEqual(0, Launches, "a stale exact-source intent must refuse before reload admission")
		Assert(Changed, "the actual native hash boundary must exercise the source race")
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Foreign, FSReadUtf8Exact(Fixture.path), "a foreign source wins before any replacement")
	} finally {
		if HasMethod(OnRefused, "Call")
			OnRefused.Call("controlled cleanup")
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("terminator-records: an independently changed source refuses the actual conditional WAL candidate", _HTR_ForeignSource)

_HTR_TerminalBarrier() {
	Fixture := _ScopeOwnerFixture()
	Bundle := _ConfigWriteTerminalTryAcquire([Fixture.path])
	Assert(Bundle is Object)
	try {
		Receipt := HotstringsTerminatorRecordsEdit(_HTR_Operation(), Fixture.options)
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		Assert(_ConfigWriteLeaseSelectOwner(Bundle, Fixture.path) is Object,
			"the refused record editor must preserve the independently held lifecycle owner")
	} finally {
		_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("terminator-records: a genuine foreign terminal barrier refuses before candidate effects", _HTR_TerminalBarrier)

_HTR_ForeignOwnership() {
	OwnerFeatures := Map(), BeforeCount := OwnerFeatures.Count
	for ForeignMemberKey in ["terminators", "terminator_states"] {
		AssertEqual("", TomlConfigUnknownKind(OwnerFeatures, "hotstrings", ForeignMemberKey, &ForeignMemberOwner))
		AssertEqual("TerminatorRecords", ForeignMemberOwner, "record leaves must not become cleanup candidates")
	}
	AssertEqual(BeforeCount, OwnerFeatures.Count, "foreign ownership admission cannot manufacture a Features namespace")
}
Test("terminator-records: loader and cleanup recognize the actual foreign record owner", _HTR_ForeignOwnership)






; =============================================================
; =============================================================
; ======= 11/ Fresh Custom Terminator Record Intent ============
; =============================================================
; =============================================================

_HTRA_Source(Kind) {
	if Kind == "authored"
		return 'hotstrings = { terminators = [{ key="custom_A4", char="§", label="Authored", consume=true, metadata={opaque="keep",count=7} }], terminator_states={custom_A4=false, future=true}, unknown={nested="retain"} } # retain parent comment`n[foreign]`nkeep="exact" # retain foreign comment`n'
	return '[hotstrings]`nterminators=[]`nterminator_states={custom_A4=false, future=true}`n[foreign]`nkeep="exact" # retain foreign comment`n'
}

_HTRA_MenuAddCollisionBody(Kind) {
	global _HotstringsTerminatorRecords
	AddFixture := _ScopeOwnerFixture()
	AddSource := _HTRA_Source(Kind)
	AddBundle := 0, AddAcknowledge := 0, AddRefused := 0, AddLaunches := 0
	AddLaunch(Acknowledge, Borrowed, Refused) {
		AddBundle := Borrowed, AddAcknowledge := Acknowledge, AddRefused := Refused
		AddLaunches += 1
		return true
	}
	AddFixture.options["reload"] := AddLaunch
	try {
		AssertTrue(FSWriteDurable(AddFixture.path, AddSource))
		HotstringsTerminatorRecordsInit(AddSource)
		PriorAddOwner := _HotstringsTerminatorRecords
		PriorAddDocument := TOML_ParseDocument(AddSource)
		AddReceipt := _HS_DelimAddRecordCommit("¤", 0, AddFixture.options)
		AssertEqual(1, AddLaunches, "the actual Add owner must reach real conditional WAL reload admission")
		AssertEqual("pending", AddReceipt["status"], "durable Add is not a runtime acknowledgment")
		AssertEqual(PriorAddOwner, _HotstringsTerminatorRecords, "pending Add must not replace the live consumer")
		AddBytes := FSReadUtf8Exact(AddFixture.path)
		AddDocument := TOML_ParseDocument(AddBytes)
		AssertEqual(Kind == "authored" ? 2 : 1, AddDocument["hotstrings"]["terminators"].Length,
			"native Add must append without overwriting an independently authored key")
		AddedDefinition := AddDocument["hotstrings"]["terminators"][Kind == "authored" ? 2 : 1]
		AssertEqual("custom_A4_1", AddedDefinition["key"], "both record and future-state occupation require a fresh exact key")
		AssertEqual("¤", AddedDefinition["char"])
		AssertEqual(false, AddedDefinition["consume"].Value)
		if Kind == "authored" {
			AssertTrue(TOML_SameValue(PriorAddDocument["hotstrings"]["terminators"][1],
				AddDocument["hotstrings"]["terminators"][1]), "every original record field and unknown metadata must survive")
			AssertTrue(TOML_SameValue(PriorAddDocument["hotstrings"]["unknown"],
				AddDocument["hotstrings"]["unknown"]), "the unrelated inline parent owner must survive")
		}
		for PriorStateKey, PriorStateValue in PriorAddDocument["hotstrings"]["terminator_states"]
			AssertTrue(TOML_SameValue(PriorStateValue, AddDocument["hotstrings"]["terminator_states"][PriorStateKey]),
				"fresh Add must preserve every existing state owner")
		AssertEqual(true, AddDocument["hotstrings"]["terminator_states"]["custom_A4_1"].Value,
			"the new Add intent must explicitly enable only its fresh key")
		AssertEqual(false, AddDocument["hotstrings"]["terminator_states"]["custom_A4"].Value)
		AssertContains(AddBytes, '[foreign]`nkeep="exact" # retain foreign comment`n')
		AddedSettings := HotstringsTerminatorRecordsResolve(AddDocument)
		AssertEqual(Kind == "authored" ? 2 : 1, AddedSettings.Records.Length)
		AssertEqual(true, AddedSettings.Records[AddedSettings.Records.Length].Enabled,
			"a future false state must not silently disable the newly added scalar")
		AssertTrue(HasMethod(AddAcknowledge, "Call"))
		AssertTrue(AddAcknowledge.Call(), "the actual retained callback must acknowledge the owned transaction")
		AssertEqual("committed", AddReceipt["status"])
		AssertEqual(PriorAddOwner, _HotstringsTerminatorRecords,
			"the modeled replacement acknowledgment is not a fake local boot")
	} finally {
		if HasMethod(AddRefused, "Call")
			AddRefused.Call("controlled Add fixture cleanup")
		if AddBundle is Object
			_ConfigWriteTerminalRelease(AddBundle)
		_ScopeOwnerCleanup(AddFixture)
	}
}

_HTRA_MenuAddCollision(Kind) {
	_HTR_WithRuntime(_HTRA_MenuAddCollisionBody.Bind(Kind))
}
Test("terminator-add: actual native Add preserves an authored generated-key record through WAL acknowledgment",
	_HTRA_MenuAddCollision.Bind("authored"))
Test("terminator-add: actual native Add reserves a future false state and explicitly enables its fresh key",
	_HTRA_MenuAddCollision.Bind("future-state"))

_HTRA_FiniteAllocationAndQuarantinedKeys() {
	AllocationSource := 'hotstrings = { terminators = [{key="custom_A4",char="§",label="Valid",consume=false},{key="custom_A4_1",char="bad",label="Quarantined",consume=false,unknown="keep"}], terminator_states={custom_A4_2=false, opaque="keep"}, foreign="unchanged" }`n'
	AddedAllocation := HotstringsTerminatorRecordPlan(AllocationSource, Map("mode", "add", "record",
		Map("key", "custom_A4", "char", "¤", "label", "Independent currency", "consume", TOML_Bool(false))))
	AllocationBefore := TOML_ParseDocument(AllocationSource)
	AllocationAfter := TOML_ParseDocument(AddedAllocation.Content)
	AssertEqual(3, AllocationAfter["hotstrings"]["terminators"].Length)
	AssertEqual("custom_A4_3", AllocationAfter["hotstrings"]["terminators"][3]["key"],
		"quarantined raw keys and future states both reserve their exact identity")
	loop 2
		AssertTrue(TOML_SameValue(AllocationBefore["hotstrings"]["terminators"][A_Index],
			AllocationAfter["hotstrings"]["terminators"][A_Index]))
	AssertEqual("keep", AllocationAfter["hotstrings"]["terminator_states"]["opaque"])
	AssertEqual("unchanged", AllocationAfter["hotstrings"]["foreign"])
	AssertEqual(true, AllocationAfter["hotstrings"]["terminator_states"]["custom_A4_3"].Value)
	HoleSource := 'hotstrings = { terminators = [], terminator_states={custom_A4=false,custom_A4_2=false} }`n'
	HolePlan := HotstringsTerminatorRecordPlan(HoleSource, Map("mode", "add", "record",
		Map("key", "custom_A4", "char", "¤", "label", "Independent currency", "consume", TOML_Bool(false))))
	AssertEqual("custom_A4_1", TOML_ParseDocument(HolePlan.Content)["hotstrings"]["terminators"][1]["key"],
		"cardinality bounds the search but must not skip an independently free earlier key")
}
Test("terminator-add: finite actual allocation reserves quarantined keys and future states without skipping a free hole",
	_HTRA_FiniteAllocationAndQuarantinedKeys)

_HTRA_MalformedStatesRefuse() {
	MalformedAddSource := 'hotstrings = { terminators = [], terminator_states="opaque" }`n'
	AssertThrows(HotstringsTerminatorRecordPlan.Bind(MalformedAddSource, Map("mode", "add", "record",
		Map("key", "custom_A4", "char", "¤", "label", "Independent currency", "consume", TOML_Bool(false)))),
		"Add must not replace an unaddressable existing state owner")
	AssertEqual('hotstrings = { terminators = [], terminator_states="opaque" }`n', MalformedAddSource)
}
Test("terminator-add: an unaddressable existing state owner refuses the new Add intent",
	_HTRA_MalformedStatesRefuse)





; ==============================================================
; ==============================================================
; ======= 12/ Canonical Record Scalar Precedence ================
; ==============================================================
; ==============================================================

_HTRP_CanonicalPrecedence(LegacyWord, LegacyConsumed, RecordSource, ExpectedWord, ExpectedConsumed) {
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	_HotstringsWordDelimiters := LegacyWord
	_HotstringsConsumedDelimiters := LegacyConsumed
	AssertEqual(true, HotstringsTerminatorRecordsInit(RecordSource))
	AssertEqual(ExpectedWord, HotstringsGetWordDelimiters(), "the canonical record owns only its exact scalar")
	AssertEqual(ExpectedConsumed, HotstringsGetConsumedDelimiters(), "canonical consumption is independent of legacy string membership")
	AssertEqual(ExpectedWord, HSE_WORD_TERMINATORS, "the real boot consumer must publish the independently expected word string")
	AssertEqual(ExpectedConsumed, HSE_CONSUMED_DELIMITERS, "the real boot consumer must publish the independently expected consumed string")
	AssertEqual(LegacyWord, _HotstringsWordDelimiters, "canonical activation must not migrate saved legacy word bytes")
	AssertEqual(LegacyConsumed, _HotstringsConsumedDelimiters, "canonical activation must not migrate saved legacy consumed bytes")
}

_HTRP_WithPrecedence(LegacyWord, LegacyConsumed, RecordSource, ExpectedWord, ExpectedConsumed) {
	return _HTR_WithRuntime(_HTRP_CanonicalPrecedence.Bind(LegacyWord, LegacyConsumed,
		RecordSource, ExpectedWord, ExpectedConsumed))
}

Test("terminator-precedence: explicit disabled record removes only its scalar from both legacy sets",
	_HTRP_WithPrecedence.Bind("!¤", "!¤",
		'[[hotstrings.terminators]]`nkey = "currency"`nchar = "¤"`nlabel = "Currency"`nconsume = true`n[hotstrings.terminator_states]`ncurrency = false`n', "!", "!"))
Test("terminator-precedence: admitted active consumed record joins both sets absent from legacy strings",
	_HTRP_WithPrecedence.Bind("!", "!",
		'[[hotstrings.terminators]]`nkey = "currency"`nchar = "¤"`nlabel = "Currency"`nconsume = true`n', "!¤", "!¤"))
Test("terminator-precedence: explicit consume false removes legacy consumption without disabling the record",
	_HTRP_WithPrecedence.Bind("!¤", "!¤",
		'[[hotstrings.terminators]]`nkey = "currency"`nchar = "¤"`nlabel = "Currency"`nconsume = false`n', "!¤", "!"))
Test("terminator-precedence: a complete disabled emoji scalar preserves unrelated legacy punctuation",
	_HTRP_WithPrecedence.Bind("!?😀", "!😀",
		'[[hotstrings.terminators]]`nkey = "smile"`nchar = "😀"`nlabel = "Smile"`nconsume = false`n[hotstrings.terminator_states]`nsmile = false`n', "!?", "!"))





; =============================================================
; =============================================================
; ======= 13/ Admitted Bootstrap and Modal Removal =============
; =============================================================
; =============================================================

_HTRB_WithBoot(Body) {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries, _ConfigBootReadFailed
	Saved := { Rejected: _ConfigBootRejectedOverrides, Outdated: _ConfigBootOutdatedEntries,
		ReadFailed: _ConfigBootReadFailed }
	try {
		_ConfigBootRejectedOverrides := 0, _ConfigBootOutdatedEntries := Map(), _ConfigBootReadFailed := false
		return _HTR_WithRuntime(Body)
	} finally {
		_ConfigBootRejectedOverrides := Saved.Rejected
		_ConfigBootOutdatedEntries := Saved.Outdated
		_ConfigBootReadFailed := Saved.ReadFailed
	}
}

_HTRB_AdmittedGeneration() {
	Fixture := _ScopeOwnerFixture()
	try {
		Assert(FSWriteDurable(Fixture.path, _HTR_Source()))
		BootSnapshot := 0
		ApplyBootConfigToml(Map(), Fixture.path, &BootSnapshot)
		Assert(BootSnapshot is Object, "the actual loader must publish its admitted image")
		AssertEqual(_HTR_Source(), BootSnapshot.Source)
		Assert(FSWriteDurable(Fixture.path, 'hotstrings = [unterminated`n'))
		AssertTrue(HotstringsTerminatorRecordsInitBoot(BootSnapshot),
			"the consumer must not borrow a later refused source generation")
		AssertEqual("!¤😀", HotstringsGetWordDelimiters())
		AssertEqual("!¤", HotstringsGetConsumedDelimiters())
	} finally _ScopeOwnerCleanup(Fixture)
}
Test("terminator-boot: real loader receipt retains the admitted generation after the source changes",
	_HTRB_WithBoot.Bind(_HTRB_AdmittedGeneration))

_HTRB_RefusedGeneration(ReadRefusal) {
	global _HotstringsTerminatorRecords, _ConfigBootRejectedOverrides, _ConfigBootReadFailed
	Fixture := _ScopeOwnerFixture()
	try {
		InvalidSource := 'hotstrings = [unterminated`n'
		Assert(FSWriteDurable(Fixture.path, InvalidSource))
		BootSnapshot := { Source: "foreign preexisting output" }
		RejectedPath := ReadRefusal ? Fixture.directory : Fixture.path
		AssertEqual(-1, ApplyBootConfigToml(Map(), RejectedPath, &BootSnapshot))
		AssertEqual(0, BootSnapshot, "the real refusal must clear an earlier output receipt")
		AssertFalse(HotstringsTerminatorRecordsInitBoot(BootSnapshot))
		AssertEqual(0, _HotstringsTerminatorRecords, "no empty record initialization may hide a refused load")
		AssertEqual("!", HotstringsGetWordDelimiters())
		AssertTrue(ReadRefusal ? _ConfigBootReadFailed : _ConfigBootRejectedOverrides > 0)
		AssertEqual(InvalidSource, FSReadUtf8Exact(Fixture.path), "refusal cannot migrate or erase source bytes")
	} finally _ScopeOwnerCleanup(Fixture)
}
Test("terminator-boot: semantic refusal preserves source protection without publishing an empty owner",
	_HTRB_WithBoot.Bind(_HTRB_RefusedGeneration.Bind(false)))
Test("terminator-boot: native reader refusal remains protected without a second source read",
	_HTRB_WithBoot.Bind(_HTRB_RefusedGeneration.Bind(true)))

_HTRB_RemoveAfterModal(PauseAfterConfirmation) {
	return _HTR_WithRuntime(_HTRB_RemoveAfterModalBody.Bind(PauseAfterConfirmation))
}

_HTRB_RemoveAfterModalBody(PauseAfterConfirmation) {
	global _HotstringsTerminatorRecords
	Fixture := _ScopeOwnerFixture(), PriorSuspend := A_IsSuspended
	Calls := 0, Acquisitions := 0, Success := 0, Bundle := 0
	Confirm(*) {
		Calls += 1
		if PauseAfterConfirmation
			Suspend(true)
		return "Yes"
	}
	RefuseAcquisition(*) {
		Acquisitions += 1
		return 0
	}
	Launch(Acknowledged, Borrowed, Refused) {
		Success := Acknowledged, Bundle := Borrowed
		return true
	}
	Fixture.options["confirm"] := Confirm
	Fixture.options["reload"] := Launch
	if PauseAfterConfirmation
		Fixture.options["acquire"] := RefuseAcquisition
	try {
		Suspend(false)
		Assert(FSWriteDurable(Fixture.path, _HTR_Source()))
		HotstringsTerminatorRecordsInit(_HTR_Source())
		Admission := HotstringsTerminatorRecordCapture(_HotstringsTerminatorRecords.Records[1])
		Outcome := _HS_DelimRemoveRecord(Admission, Fixture.options)
		AssertEqual(1, Calls, "the real removal helper must receive the confirmation")
		if PauseAfterConfirmation {
			AssertEqual(false, Outcome, "a pause during confirmation revokes admission")
			AssertEqual(0, Acquisitions, "paused confirmation must not acquire transaction ownership")
			AssertEqual(_HTR_Source(), FSReadUtf8Exact(Fixture.path))
		} else {
			Assert(Outcome is Map)
			AssertEqual("pending", Outcome["status"], "publication still requires the runtime ACK")
			AssertEqual("smile", TOML_ParseDocument(FSReadUtf8Exact(Fixture.path))["hotstrings"]["terminators"][1]["key"])
			Success.Call()
			AssertEqual("committed", Outcome["status"])
		}
	} finally {
		Suspend(PriorSuspend)
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("terminator-remove: a real post-confirmation pause refuses before acquiring any transaction",
	_HTRB_RemoveAfterModal.Bind(true))
Test("terminator-remove: an admitted confirmation removes only its record and still requires runtime ACK",
	_HTRB_RemoveAfterModal.Bind(false))


; =============================================================
; =============================================================
; ======= 14/ Displayed Record Admission =======================
; =============================================================
; =============================================================

_HTRD_WithDisplayed(Body) {
	return _HTR_WithRuntime(Body)
}

_HTRD_SourceReplacement(Mode) {
	global _HotstringsTerminatorRecords
	Original := _HTR_Source()
	HotstringsTerminatorRecordsInit(Original)
	Admission := HotstringsTerminatorRecordCapture(_HotstringsTerminatorRecords.Records[1])
	Replacement := StrReplace(StrReplace(Original, 'char = "¤"', 'char = "§"', true),
		'label = "Currency"', 'label = "Replacement"', true)
	AssertEqual("§", HotstringsTerminatorRecordsResolve(TOML_ParseDocument(Replacement)).Records[1].Char)
	Operation := Map("mode", Mode, "key", Admission.Key, "enabled", false, "admission", Admission)
	AssertThrows(HotstringsTerminatorRecordPlan.Bind(Replacement, Operation),
		"a key match cannot authorize an operation on the independently replaced source")
	AssertEqual(Original, Admission.Source)
	AssertTrue(HotstringsTerminatorRecordCurrent(Admission), "external bytes do not retire the runtime owner")
}
Test("terminator-admission: remove refuses replacement under the same displayed key",
	_HTRD_WithDisplayed.Bind(_HTRD_SourceReplacement.Bind("remove")))
Test("terminator-admission: state refuses replacement under the same displayed key",
	_HTRD_WithDisplayed.Bind(_HTRD_SourceReplacement.Bind("state")))

_HTRD_UnchangedSource() {
	global _HotstringsTerminatorRecords
	Original := _HTR_Source()
	HotstringsTerminatorRecordsInit(Original)
	Admission := HotstringsTerminatorRecordCapture(_HotstringsTerminatorRecords.Records[1])
	Removed := HotstringsTerminatorRecordPlan(Original,
		Map("mode", "remove", "key", Admission.Key, "admission", Admission))
	AssertEqual("smile", Removed.Settings.Records[1].Key)
	State := HotstringsTerminatorRecordPlan(Original,
		Map("mode", "state", "key", Admission.Key, "enabled", false, "admission", Admission))
	AssertFalse(State.Settings.Records[1].Enabled)
	AssertTrue(HotstringsTerminatorRecordCurrent(Admission))
}
Test("terminator-admission: unchanged displayed source admits detached remove and state plans",
	_HTRD_WithDisplayed.Bind(_HTRD_UnchangedSource))

_HTRD_RetiredOwner() {
	global _HotstringsTerminatorRecords
	HotstringsTerminatorRecordsInit(_HTR_Source())
	Admission := HotstringsTerminatorRecordCapture(_HotstringsTerminatorRecords.Records[1])
	_HotstringsTerminatorRecords := 0
	HotstringsTerminatorRecordsInit(_HTR_Source())
	AssertFalse(HotstringsTerminatorRecordCurrent(Admission), "equal source cannot borrow a new runtime owner")
	AssertThrows(HotstringsTerminatorRecordPlan.Bind(_HTR_Source(),
		Map("mode", "remove", "key", Admission.Key, "admission", Admission)))
}
Test("terminator-admission: equal bytes cannot replace the captured runtime owner identity",
	_HTRD_WithDisplayed.Bind(_HTRD_RetiredOwner))


_HTR_RootOwnerImage() {
	for Prefix in ["", Chr(0xFEFF)] {
		Source := Prefix . '_meta.schema_version = 7`nroot_owner = { keep = "exact", nested = { n = 9 } }`n' . _HTR_Source()
		Before := TOML_ParseDocument(Source)
		Plan := HotstringsTerminatorRecordPlan(Source, Map("mode", "upsert", "record",
			Map("key", "section", "char", "§", "label", "Section", "consume", TOML_Bool(false))))
		After := TOML_ParseDocument(Plan.Content)
		AssertTrue(TOML_SameValue(Before["_meta"], After["_meta"]), "root schema metadata remains outside the new hotstrings parent")
		AssertTrue(TOML_SameValue(Before["root_owner"], After["root_owner"]), "an independent root owner retains every typed leaf")
		AssertTrue(TOML_SameValue(Before["private"], After["private"]))
		AssertTrue(TOML_SameValue(Before["foreign"], After["foreign"]))
		AssertEqual(3, After["hotstrings"]["terminators"].Length)
		AssertEqual(Prefix == "" ? false : true, SubStr(Plan.Content, 1, 1) == Chr(0xFEFF))
	}
	Minimal := '[[hotstrings.terminators]]`nkey = "currency"`nchar = "¤"`nlabel = "Currency"`nconsume = true'
	for Source in [Minimal, Minimal . '`n# retained final trivia'] {
		Removed := HotstringsTerminatorRecordPlan(Source, Map("mode", "remove", "key", "currency"))
		AssertEqual(0, TOML_ParseDocument(Removed.Content)["hotstrings"]["terminators"].Length,
			"an empty retained image still admits one explicit empty parent")
		if InStr(Source, "# retained final trivia")
			AssertContains(Removed.Content, "# retained final trivia", "retained trivia is not discarded by parent insertion")
	}
	RootOnly := 'root_owner = { keep = "exact" }'
	RootPlan := HotstringsTerminatorRecordPlan(RootOnly, Map("mode", "upsert", "record",
		Map("key", "section", "char", "§", "label", "Section", "consume", TOML_Bool(false))))
	RootAfter := TOML_ParseDocument(RootPlan.Content)
	AssertTrue(TOML_SameValue(TOML_ParseDocument(RootOnly)["root_owner"], RootAfter["root_owner"]),
		"a root-only image without a terminal newline retains its independent owner")
	AssertEqual(1, RootAfter["hotstrings"]["terminators"].Length)

}
Test("terminator-records: a new parent preserves independent root owners and BOM", _HTR_RootOwnerImage)
