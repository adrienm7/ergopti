; hotstrings/engine/catalogue/helpers.ahk

; ==============================================================================
; MODULE: Hotstrings — Module-Scope Helpers
; DESCRIPTION:
; Module-scope (non-function-body) declarations for the hotstrings orchestrator:
; deferred-registration constants and functions, the emoji/symbol and text-expansion
; sub-register helpers, and the deadkey / ellipsis raw-callback helpers. These are
; defined at module scope so they can be called from any context (timers, live
; rebuilds, callbacks) without being tied to a specific function's lifetime.
; ==============================================================================

#Include %A_LineFile%\..\..\..\..\_generated\config_keys.ahk





; ==========================================================
; ==========================================================
; ======= 1/ Deferred emoji / symbol registration ==========
; ==========================================================
; ==========================================================

; The magic-key emoji and symbol sections in their registration order, with the
; options each loads with: the single list the inline load and the deferred boot
; load both walk.
; @return {Array} [Category, Section, FeatureNode, ExtraOptions] per section.
_EmojisSymbolsSections() {
	global Features
	return [
		["french_magickey", "text_expansion_emojis", Features["hotstrings"]["french_magickey"]["text_expansion_emojis"], Map()],
		["magickey", "text_expansion_symbols", Features["hotstrings"][ConfigLeaf.MAGIC_KEY]["text_expansion_symbols"], Map()],
		["magickey", "text_expansion_symbols_typst", Features["hotstrings"][ConfigLeaf.MAGIC_KEY]["text_expansion_symbols_typst"],
			Map("OnlyText", False)]
	]
}

; Registers the heavy magic-key emoji + symbol sections into the HSE at once: a
; live rebuild, and a boot whose sections the cache does not all serve.
_RegisterEmojisSymbolsSections() {
	for Entry in _EmojisSymbolsSections() {
		if Entry[3]["enabled"]
			LoadHotstringsSection(Entry[1], Entry[2], Entry[3], Entry[4])
	}
}

; The boot load of the emoji and symbol sections (about 1,600 rows and 400
; ms on a maintainer-sized setup): their sequence block is reserved here, at the
; position they hold inline, and their rows register after ready in slices
; (HSE_DeferredRegistrationStart), so the collision tie-break is the inline one.
; A section the bundled cache does not serve (a layout-bound file) is read from
; disk, which a slice under Critical must not do: then all load here.
RegisterEmojisSymbolsDeferred() {
	Steps := []
	for Entry in _EmojisSymbolsSections() {
		if !Entry[3]["enabled"]
			continue
		Step := HotstringsSectionCachedRows(Entry[1], Entry[2], Entry[3], Entry[4])
		if !Step {
			LoggerInfo("Hotstrings", "Section [{1}.{2}] is not served by the cache: the emoji and symbol sections load before ready.",
				HotstringCategoryLogName(Entry[1]), Entry[2])
			_RegisterEmojisSymbolsSections()
			return false
		}
		Steps.Push(Step)
	}
	if Steps.Length
		HSE_DeferRegistration("Emoji/symbol hotstrings", Steps)
	return true
}

; Registers the magic-key text-expansion sections into the HSE. Shared by the boot
; deferred pass and the live rebuild so the two code paths never diverge (mirrors
; _RegisterEmojisSymbolsSections for the emoji/symbol categories).
_RegisterTextExpansionSections() {
	global Features
	if Features["hotstrings"]["french_magickey"]["text_expansion"]["enabled"] {
		LoadHotstringsSection("french_magickey", "text_expansion", Features["hotstrings"]["french_magickey"]["text_expansion"])
	}
	if Features["hotstrings"]["french_magickey"]["text_expansion_auto"]["enabled"] {
		LoadHotstringsSection("french_magickey", "text_expansion_auto", Features["hotstrings"]["french_magickey"]["text_expansion_auto"])
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
		Map("TimeActivationSeconds", Delay, "Category", "distancesreduction", "Section", "dead_key_e_circumflex",
			"SupportsPreparation", true)
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
			if SendNewResult("{BackSpace 2}{Text}" . MappedValue, false, true, true)
				return { Ok: true, Bs: 2, Ins: MappedValue }
			return { Ok: false, Bs: 0, Ins: "" }
		} else if (GetLastSentCharacterAt(-3) ~= "^[nN]$" and GetLastSentCharacterAt(-1) == "c") { ; Special case of the º symbol
			if PrepareOnly
				return { Prepared: true, Ok: true, Bs: 2, Ins: MappedValue }
			if SendNewResult("{BackSpace 2}{Text}" . MappedValue, false, true, true)
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
		if SendNewResult("{BackSpace 3}…", False, True, True)
			return { Ok: true, Bs: 3, Ins: "…" }
		return { Ok: false, Bs: 0, Ins: "" }
	}
	return { Prepared: PrepareOnly, Ok: false, Bs: 0, Ins: "" }
}
