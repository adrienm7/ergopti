; modules/hotstrings/hotstrings_helpers.ahk

; ==============================================================================
; MODULE: Hotstrings — Module-Scope Helpers
; DESCRIPTION:
; Module-scope (non-function-body) declarations for the hotstrings orchestrator:
; deferred-registration constants and functions, the emoji/symbol and text-expansion
; sub-register helpers, and the deadkey / ellipsis raw-callback helpers. These are
; defined at module scope so they can be called from any context (timers, live
; rebuilds, callbacks) without being tied to a specific function's lifetime.
; ==============================================================================





; ==========================================================
; ==========================================================
; ======= 1/ Deferred emoji / symbol registration ==========
; ==========================================================
; ==========================================================

; Retained for compatibility with live-rebuild callers. Boot no longer uses a
; deferred emoji/symbol pass: ready is published only once all advertised triggers
; and the preview index are available.
global HS_DEFERRED_REGISTRATION_DELAY_MS := 1500

; Delay (ms) before warming the prefix-watcher PREVIEW index off the boot path.
; text_expansion now registers ON the critical path (it is the most-used feature),
; so no heavy registration is deferred here — only the preview index is (re)built a
; short moment after "ready" so tooltips appear quickly without paying the index
; build on time-to-ready. The emoji/symbol pass rebuilds it again once those load.
global HS_PREFIX_INDEX_WARM_DELAY_MS := 300

; Registers the heavy magic-key emoji + symbol sections into the HSE. Shared by
; the boot deferred pass and the live rebuild so the two code paths never diverge.
_RegisterEmojisSymbolsSections() {
	global Features
	if Features["hotstrings"]["magic_key"]["text_expansion_emojis"]["enabled"] {
		LoadHotstringsSection("magickey", "text_expansion_emojis", Features["hotstrings"]["magic_key"]["text_expansion_emojis"])
	}
	if Features["hotstrings"]["magic_key"]["text_expansion_symbols"]["enabled"] {
		LoadHotstringsSection("magickey", "text_expansion_symbols", Features["hotstrings"]["magic_key"]["text_expansion_symbols"])
	}
	if Features["hotstrings"]["magic_key"]["text_expansion_symbols_typst"]["enabled"] {
		LoadHotstringsSection("magickey", "text_expansion_symbols_typst", Features["hotstrings"]["magic_key"]["text_expansion_symbols_typst"],
			Map("OnlyText", False))
	}
}

; Compatibility path for a live rebuild that deliberately queues registration.
; Boot registers these sections synchronously before ready.
RegisterEmojisSymbolsDeferred() {
	global HSE_RegistryByGroup
	if (IsSet(HSE_RegistryByGroup) and (HSE_RegistryByGroup.Has("emojis.emojis") or HSE_RegistryByGroup.Has("magickey.text_expansion_emojis")))
		return
	try {
		; Isolated wall-clock for the HSE registration alone. The BootProfile delta
		; below folds in the 1.5 s SetTimer delay AND interleaving with the other
		; deferred boot tasks (warm-up rebuild, Ollama probe, LLM bridge), so it
		; massively overstates the true cost — this line shows the real registration time.
		_emojiStart := A_TickCount
		_RegisterEmojisSymbolsSections()
		try LoggerInfo("Hotstrings", "Emoji/symbol HSE sections registered in {1} ms.", TickElapsed(_emojiStart))
		; Build the prefix-watcher PREVIEW index ONCE, here, at the end of the deferred
		; pass. This is the single index build (the earlier warm-up SetTimer was removed):
		; by now HotstringsResolve is memoised for every section — including the emoji/
		; symbol ones just registered above — and the boot has settled, so this rebuild is
		; reliably ~220 ms instead of the erratic 250 ms–6 s the warm-up saw under boot
		; contention. The index is built from the in-memory cache + Features, so it covers
		; every category in one pass (pinned by test_prefix_watcher_deferred).
		try HotstringPrefixWatcherRebuildIndex()
		try BootProfile_Mark("Emoji/symbol hotstrings registered (deferred)")
		try LoggerInfo("Hotstrings", "Deferred emoji/symbol registration complete.")
	} catch as e {
		try LoggerError("Hotstrings", "Deferred emoji/symbol registration failed: {1}", e.Message)
	}
}

; Registers the magic-key text-expansion sections into the HSE. Shared by the boot
; deferred pass and the live rebuild so the two code paths never diverge (mirrors
; _RegisterEmojisSymbolsSections for the emoji/symbol categories).
_RegisterTextExpansionSections() {
	global Features
	if Features["hotstrings"]["magic_key"]["text_expansion"]["enabled"] {
		LoadHotstringsSection("magickey", "text_expansion", Features["hotstrings"]["magic_key"]["text_expansion"])
	}
	if Features["hotstrings"]["magic_key"]["text_expansion_auto"]["enabled"] {
		LoadHotstringsSection("magickey", "text_expansion_auto", Features["hotstrings"]["magic_key"]["text_expansion_auto"])
	}
}





; =================================================
; =================================================
; ======= 2/ Deadkey helpers (module scope) =======
; =================================================
; =================================================

; These helpers are defined at module scope (not nested inside RegisterAllHotstrings)
; so the hotstring callbacks they register never close over the wrapper's locals:
; the activation delay flows in as the explicit Delay parameter. This keeps the
; registration re-runnable without rebuilding closures on every pass.
CreateDeadkeyHotstring(MapKey, MappedValue, Delay) {
	; The deadkey only activates at the start of a new word (symbols aren't put in
	; words); this corrects « même » giving « mê⁂e ». Registered as an HSE
	; raw-callback hotstring (no native Hotstring(), so no A_InputLevel dependency):
	; the callback inspects context and conditionally expands.
	Combination := "ê" . MapKey
	CreateRawCallbackHotstring(
		"*?C", Combination,
		(EndChar := "", PrepareOnly := false) =>
			ShouldActivateDeadkey(Combination, MappedValue, Delay, PrepareOnly),
		Map("TimeActivationSeconds", Delay, "Category", "distancesreduction", "Section", "dead_key_e_circumflex")
	)
}

; Returns the { Ok, Bs, Ins } transaction _HSE_DispatchRawCallback resyncs from: when
; the deadkey fires it has back-spaced 2 chars (the "ê" + the key) and sent
; MappedValue, so the net buffer change is { Bs: 2, Ins: MappedValue }; when it
; declines or the atomic send fails it returns Ok:false with no buffer effect.
ShouldActivateDeadkey(Combination, MappedValue, Delay, PrepareOnly := false) {
	if not IsTimeActivationExpired(GetLastSentCharacterAt(-2), Delay) {
		; We only activate the deadkey if it is the start of a new word, as symbols aren't put in words
		; This condition corrects problems such as writing "même" that give "mê⁂e"
		; We could simply have removed the "?" flag in the Hotstring definition, but we want to get the symbols also if we are typing numbers.
		; For example to write 01/02 by using the / on the deadkey.
		MK := (IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey")) ? ScriptInformation["MagicKey"] : "★"
		Ch3 := GetLastSentCharacterAt(-3)
		; Non-regex membership check to avoid injecting the magic key into a character class —
		; a configurable key like ] or \ would break the pattern if embedded directly.
		if (Ch3 != "" and !RegExMatch(Ch3, "^[A-Za-z]$") and Ch3 != MK) { ; Everything except a letter or the configured magic key
			; Character at -1 is the key in the deadkey, character at -2 is "ê", character at -3 is character before using the deadkey
			if PrepareOnly
				return { Prepared: true, Ok: true, Bs: 2, Ins: MappedValue }
			if SendNewResult("{BackSpace 2}{Text}" . MappedValue, false)
				return { Ok: true, Bs: 2, Ins: MappedValue }
			return { Ok: false, Bs: 0, Ins: "" }
		} else if (GetLastSentCharacterAt(-3) ~= "^[nN]$" and GetLastSentCharacterAt(-1) == "c") { ; Special case of the º symbol
			if PrepareOnly
				return { Prepared: true, Ok: true, Bs: 2, Ins: MappedValue }
			if SendNewResult("{BackSpace 2}{Text}" . MappedValue, false)
				return { Ok: true, Bs: 2, Ins: MappedValue }
			return { Ok: false, Bs: 0, Ins: "" }
		}
	}
	return { Prepared: PrepareOnly, Ok: false, Bs: 0, Ins: "" }
}

; Ellipsis raw-callback: "..." → "…", but only after a letter (otherwise it would
; break code like the JS spread « [...a, ...b] »). Returns the { Ok, Bs, Ins }
; transaction for HSE resync (back-spaces the 3 dots, inserts "…"). Ok stays false
; unless the single output burst completed successfully.
_EllipsisRawCallback(EndChar := "", PrepareOnly := false) {
	if (GetLastSentCharacterAt(-4) ~= "^[A-Za-z]$") {
		if PrepareOnly
			return { Prepared: true, Ok: true, Bs: 3, Ins: "…" }
		if SendNewResult("{BackSpace 3}…", False)
			return { Ok: true, Bs: 3, Ins: "…" }
		return { Ok: false, Bs: 0, Ins: "" }
	}
	return { Prepared: PrepareOnly, Ok: false, Bs: 0, Ins: "" }
}
