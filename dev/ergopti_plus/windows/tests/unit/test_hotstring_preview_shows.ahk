; tests/unit/test_hotstring_preview_shows.ahk

; ==============================================================================
; MODULE: Regression — the bubble shows a delayed hotstring typed without the
;         layout emulation (hotstring-preview-shows)
; DESCRIPTION:
; Maintainer report: « Sur driver AHK les tooltips hotstrings ne s'affichent
; pas. Seul le tooltip LLM fonctionne. »
;
; ROOT CAUSE ENCODED: every bundled hotstring carries an activation delay
; (LoadHotstringsSection applies HotstringsResolve().Delay: 2 s for the magic
; key, 1 s for autocorrection, 0.75 s otherwise), and the time gate of
; _HSE_PrepareDispatchDecision fails closed when LastSentCharacterKeyTime holds
; no timestamp for the trigger's previous key. Only the layout emulation wrote
; that map, so with the emulation off (the neutral layout setting since W1) or
; for a key it passes on, the preview oracle refused every row and dispatch
; refused every expansion. The ungated repeat doubling was the only bubble left,
; and the bubble never offers it (no-repeat-preview), so none showed at all.
;
; The prefix watcher now stamps every character it observes through the single
; timestamp owner before feeding the engine. These cases replay that
; observation with no emulation timestamp at all, then drive the real lookup,
; candidate collection and render request for a magic-key symbol and for an
; autocorrection, and check that the expansion itself passes the same gate.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ==============================
; ======= 1/ The fixture =======
; ==============================
; ==============================

; Isolates the engine, the preview buffer and the timestamp map. The map starts
; empty: no layout emulation typed anything, as with the neutral layout setting.
; @return The saved state, to be handed back to _HPS_Teardown.
_HPS_Setup() {
	global HSE_Suppressed, HSE_RebuildInProgress, HSE_RepeatEnabled
	global HSE_PersonalInfoCombosEnabled, LastSentCharacterKeyTime, _PrefixBuffer
	Saved := { Suppressed:    HSE_Suppressed,
	           Rebuild:       HSE_RebuildInProgress,
	           RepeatEnabled: HSE_RepeatEnabled,
	           CombosEnabled: HSE_PersonalInfoCombosEnabled,
	           Stamps:        LastSentCharacterKeyTime,
	           PrefixBuffer:  _PrefixBuffer }
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_RebuildInProgress := false
	HSE_RepeatEnabled := false
	HSE_PersonalInfoCombosEnabled := false
	HSE_FeedReset(true)
	LastSentCharacterKeyTime := Map()
	return Saved
}

; Cancels the render request a case published before any Gui is built, then
; restores the state _HPS_Setup saved.
; @param Saved The value _HPS_Setup returned.
_HPS_Teardown(Saved) {
	global HSE_Suppressed, HSE_RebuildInProgress, HSE_RepeatEnabled
	global HSE_PersonalInfoCombosEnabled, LastSentCharacterKeyTime
	TooltipHide("HotstringPreviewShowsTest", true)
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := Saved.Suppressed
	HSE_RebuildInProgress := Saved.Rebuild
	HSE_RepeatEnabled := Saved.RepeatEnabled
	HSE_PersonalInfoCombosEnabled := Saved.CombosEnabled
	LastSentCharacterKeyTime := Saved.Stamps
	_PrefixSetBuffer(Saved.PrefixBuffer)
}

; The timestamp owner the prefix watcher calls. It must load with the engine:
; the headless runner, like a driver without the emulation, never includes
; modules/keymap/layout.ahk.
; @return {Func} AppState_TouchLastSentKey.
_HPS_TimestampOwner() {
	Owner := 0
	try Owner := %"AppState_TouchLastSentKey"%
	Assert(HasMethod(Owner, "Call"),
		"AppState_TouchLastSentKey must load with the hotstring engine, not only with the layout emulation: the prefix watcher stamps every observed character through it (hotstring-preview-shows)")
	return Owner
}

; Replays what _OnPrefixChar does with each observed character before it can
; fire: stamp it through the timestamp owner, then feed the engine as physical
; input. The meta case below pins that order in _OnPrefixChar itself.
; @param Typed {String} The characters typed through the OS layout.
_HPS_ObserveTyped(Typed) {
	Owner := _HPS_TimestampOwner()
	Loop Parse, Typed {
		Owner(A_LoopField)
		HSE_FeedChar(A_LoopField, true)
	}
	_PrefixSetBuffer(Typed)
}

; Feeds the engine without any timestamp, as the watcher did before the fix.
; @param Typed {String} The characters typed through the OS layout.
_HPS_FeedUnstamped(Typed) {
	Loop Parse, Typed
		HSE_FeedChar(A_LoopField, true)
	_PrefixSetBuffer(Typed)
}

; The rows of the render request _LookupAndRender published, or [] when none.
; @return {Array}
_HPS_PendingRows() {
	global _TooltipPendingRequest
	if !IsObject(_TooltipPendingRequest)
		return []
	Items := _TooltipPendingRequest.Items
	return (Items is Array) ? Items : [Items]
}

; Registers one bundled mapping through the TOML loader's own entry point,
; with the activation delay its category resolves to in production.
; @param Flags {String} The TOML flags ("*" auto-expands, "C" strict case).
; @param Trigger {String} The trigger, magic key included.
; @param Output {String} The replacement.
; @param Delay {Number} The category's activation delay, in seconds.
; @param Category {String} The bundled category.
; @param Section {String} The bundled section.
_HPS_RegisterDelayed(Flags, Trigger, Output, Delay, Category, Section) {
	global HSE_PRIORITY_COMMON
	HSE_RegisterFromTomlFlags(true, Flags, Trigger, Output,
		Map("TimeActivationSeconds", Delay, "FinalResult", false,
			"Category", Category, "Section", Section,
			"Priority", HSE_PRIORITY_COMMON))
	Assert(HotstringsResolve(Category, Section).ShowTooltip,
		"sanity: the " . Category . " rows must be allowed in the bubble, or this case proves nothing")
}





; =========================================================================
; =========================================================================
; ======= 2/ A delayed row reaches the bubble without the emulation =======
; =========================================================================
; =========================================================================

; The magic key's symbol expansion "(v)★" = "✓" from magickey.toml, whose
; category delay is 2 s. The bubble is asked before the magic key is typed.
_HPS_MagicKeySymbolIsShown() {
	global HSE_Buffer, HSE_LastEndChar, ScriptInformation
	Saved := _HPS_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		_HPS_RegisterDelayed("*C", "(v)" . MK, Chr(0x2713), 2,
			"magickey", "text_expansion_symbols")

		_HPS_FeedUnstamped("(v)")
		AssertEqual(0, _PrefixCollectCandidates().Length,
			"sanity: without a timestamp for ')' the time gate refuses the row, which is the reported empty bubble")

		HSE_FeedReset(true)
		_HPS_ObserveTyped("(v)")
		_LookupAndRender()
		Rows := _HPS_PendingRows()
		AssertEqual(1, Rows.Length,
			"the bubble must be requested for '(v)' typed through the OS layout: the watcher's own timestamp opens the 2 s gate (hotstring-preview-shows)")
		AssertEqual(Chr(0x2713), Rows[1].Text,
			"the bubble must show the symbol the magic key will type")
		AssertEqual(MK, Rows[1].TriggerLabel,
			"the row must name the magic key as its completion")

		; The expansion itself goes through the same gate once the key is typed.
		Owner := _HPS_TimestampOwner()
		Owner(MK)
		Match := HSE_FeedChar(MK, true)
		Assert(IsObject(Match), "sanity: the magic key must complete the registered trigger")
		Assert(IsObject(_HSE_PrepareDispatchDecision(Match, HSE_Buffer, HSE_LastEndChar)),
			"the magic key must expand '(v)' typed through the OS layout, not only preview it")
	} finally {
		_HPS_Teardown(Saved)
	}
}
Test("hotstrings: a delayed magic-key row is shown without the layout emulation (hotstring-preview-shows)",
	_HPS_MagicKeySymbolIsShown)

; The autocorrection "api" = "API" from autocorrection.toml, an end-character
; trigger whose category delay is 1 s. Its row names the end character.
_HPS_AutocorrectionIsShown() {
	Saved := _HPS_Setup()
	try {
		_HPS_RegisterDelayed("", "api", "API", 1, "autocorrection", "caps")

		_HPS_FeedUnstamped("api")
		AssertEqual(0, _PrefixCollectCandidates().Length,
			"sanity: without a timestamp for 'p' the time gate refuses the autocorrection row")

		HSE_FeedReset(true)
		_HPS_ObserveTyped("api")
		_LookupAndRender()
		Rows := _HPS_PendingRows()
		AssertEqual(1, Rows.Length,
			"the bubble must be requested for an autocorrection typed through the OS layout (hotstring-preview-shows)")
		AssertEqual("API", Rows[1].Text,
			"the bubble must show the correction the end character will type")
		AssertEqual(Chr(0x21B5), Rows[1].TriggerLabel,
			"an end-character row must be labelled with the end character")
	} finally {
		_HPS_Teardown(Saved)
	}
}
Test("hotstrings: a delayed autocorrection row is shown without the layout emulation (hotstring-preview-shows)",
	_HPS_AutocorrectionIsShown)





; ================================================================
; ================================================================
; ======= 3/ The watcher stamps before it feeds the engine =======
; ================================================================
; ================================================================

; The cases above replay the observation; this pins that _OnPrefixChar performs
; it, once the focused control is verified and before the engine can fire.
_HPS_WatcherStampsBeforeFeeding() {
	OnChar := _StripFullLineComments(_DriverFuncBody("_OnPrefixChar"))
	Assert(OnChar != "", "_OnPrefixChar must exist in the driver source")
	EnsurePos := InStr(OnChar, "_PrefixEnsureInputContext()")
	StampPos := InStr(OnChar, "AppState_TouchLastSentKey(Char)")
	FeedPos := InStr(OnChar, "HSEMatch := HSE_FeedChar(Char, true)")
	Assert(StampPos > 0,
		"_OnPrefixChar must stamp every observed character: only the layout emulation stamped before, so a key typed through the OS layout failed every time gate (hotstring-preview-shows)")
	Assert(EnsurePos > 0 and EnsurePos < StampPos and StampPos < FeedPos,
		"_OnPrefixChar must stamp the character after verifying its control and before feeding the engine, like the emulation stamps before the character reaches the hook")
}
Test("meta hotstrings: the prefix watcher stamps each observed character before feeding the engine (hotstring-preview-shows)",
	_HPS_WatcherStampsBeforeFeeding)
