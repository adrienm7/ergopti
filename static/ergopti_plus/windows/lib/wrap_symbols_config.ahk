; lib/wrap_symbols_config.ahk

; ==============================================================================
; MODULE: Wrap Symbols Config
; DESCRIPTION:
; Manages the user-configurable list of symbols that wrap a text selection when
; typed. Mirrors the macOS ``menu_shortcuts.lua`` wrap_symbol_states /
; custom_wrap_symbols pattern.
;
; PERSISTENCE:
; State is saved to ``wrap_symbols.toml`` in the shared config directory
; (_ConfigDir). Format:
;
;   [disabled]
;   chars = "(,*,[,..."     ; comma-separated opening symbols that are off
;
;   [[custom]]
;   left  = "«"
;   right = "»"
;
; FEATURES & RATIONALE:
; 1. Single source of truth: WrapSymbols_GetActivePairs() is the only place
;    that merges the built-in catalogue with the disabled set and custom entries.
;    The PrefixWatcher reads this map on every keystroke so changes take effect
;    without a Reload when the symbol is already in the base catalogue.
; 2. No Reload required for toggles: _WS_ACTIVE_PAIRS is rebuilt in-process via
;    WrapSymbols_Rebuild() immediately after every menu change.
; ==============================================================================

; ----------------------------- Built-in catalogue ----------------------------
; The canonical catalogue + its grouping live in the SHARED single source of
; truth: ``static/ergopti_plus/_shared/wrap_symbols.json`` (the same file the
; macOS driver reads). It is loaded once by _WS_LoadBuiltinCatalogue() into the
; two globals below — NEVER hardcode the list or its order here.
;   _WS_BUILTIN_PAIRS  — flat array of Map("left", …, "right", …), used to build
;                        the active-pairs lookup and the disable-all set.
;   _WS_BUILTIN_GROUPS — array of Map("i18n", key, "pairs", [pairMap, …]); the
;                        tray menu renders each group as a NAMED nested sub-submenu.
global _WS_BUILTIN_PAIRS  := []
global _WS_BUILTIN_GROUPS := []

; Emergency-only fallback used when the shared JSON cannot be read/parsed. Kept
; intentionally minimal (the ASCII brackets + straight quotes) so a transient
; I/O failure still leaves basic wrapping usable; the real catalogue is the JSON.
global _WS_FALLBACK_GROUPS := [
		Map("i18n", "menu.shortcuts.wrap_group_brackets", "pairs",
				[ Map("left", "(", "right", ")"), Map("left", "[", "right", "]"),
					Map("left", "{", "right", "}"), Map("left", "<", "right", ">") ]),
		Map("i18n", "menu.shortcuts.wrap_group_quotes", "pairs",
				[ Map("left", Chr(0x22), "right", Chr(0x22)), Map("left", "'", "right", "'") ]),
]

; ----------------------------- Runtime state ---------------------------------

; Absolute path of the TOML persistence file (set by WrapSymbols_Init).
global _WS_Config_Path := ""

; Map of opening-symbol -> true for every symbol the user has disabled.
global _WS_Disabled := Map()

; Array of Map("left", …, "right", …) for user-added custom pairs.
global _WS_Custom := []

; True when an EXISTING wrap_symbols.toml could not be read at load. The two
; maps above are then empty — indistinguishable from "nothing disabled, no
; custom pairs" — so persistence must be blocked, or the first toggle writes
; that emptiness over the real file and the user's settings are gone.
global _WS_LoadFailed := false

; The live active-pairs Map: char -> Map("left", openChar, "right", closeChar).
; Rebuilt after every config change. PrefixWatcher reads this directly.
global _WS_ACTIVE_PAIRS := Map()




; ===========================================================
; ===========================================================
; ======= 1/ Public API =====================================
; ===========================================================
; ===========================================================

; Initialise the module. Must be called once at startup with the path to the
; shared config directory (the same _ConfigDir used by hotstrings_config.ahk).
; @param ConfigDir string Absolute path of the config directory (trailing \ required).
WrapSymbols_Init(ConfigDir) {
		global _WS_Config_Path, _WS_Disabled, _WS_Custom, _WS_BUILTIN_GROUPS
		_WS_Config_Path := ConfigDir . "wrap_symbols.toml"
		_WS_Disabled    := Map()
		_WS_Custom      := []
		_WS_LoadBuiltinCatalogue()
		_WS_Load()
		WrapSymbols_Rebuild()
		try LoggerInfo("WrapSymbols", "Initialized ({1} active pair(s), {2} built-in group(s), {3} disabled).",
				_WS_ACTIVE_PAIRS.Count, _WS_BUILTIN_GROUPS.Length, _WS_Disabled.Count)
}

; Load the built-in catalogue from the shared single source of truth
; (``_shared/wrap_symbols.json``). Populates _WS_BUILTIN_GROUPS (ordered groups)
; and the flattened _WS_BUILTIN_PAIRS. Falls back to _WS_FALLBACK_GROUPS on any
; read/parse failure so wrapping degrades gracefully rather than vanishing.
_WS_LoadBuiltinCatalogue() {
		global _SharedDir, _WS_BUILTIN_PAIRS, _WS_BUILTIN_GROUPS, _WS_FALLBACK_GROUPS
		_WS_BUILTIN_PAIRS  := []
		_WS_BUILTIN_GROUPS := []

		FilePath := _SharedDir . "\modules\wrap_symbols\wrap_symbols.json"
		Groups := ""
		if FileExist(FilePath) {
				Content := ""
				try Content := FileRead(FilePath, "UTF-8")
				Root := ""
				if (Content != "") {
						try Root := JsonParse(Content)
				}
				if (Root is Map and Root.Has("groups") and Root["groups"] is Array) {
						Groups := Root["groups"]
				}
		}

		if !(Groups is Array) {
				try LoggerWarn("WrapSymbols", "Shared catalogue unreadable at '{1}' — using emergency fallback.", FilePath)
				Groups := _WS_FALLBACK_GROUPS
		}

		_WS_IngestGroups(Groups)

		; A catastrophic parse that yielded nothing must still leave wrapping usable.
		if (_WS_BUILTIN_PAIRS.Length == 0) {
				_WS_BUILTIN_GROUPS := []
				_WS_IngestGroups(_WS_FALLBACK_GROUPS)
		}
		try LoggerDebug("WrapSymbols", "Built-in catalogue loaded ({1} pair(s) in {2} group(s)).",
				_WS_BUILTIN_PAIRS.Length, _WS_BUILTIN_GROUPS.Length)
}

; Convert a groups array (parsed JSON or the fallback — both share the shape
; Map("i18n", key, "pairs", [Map("left", …, "right", …), …])) into the runtime
; _WS_BUILTIN_GROUPS / _WS_BUILTIN_PAIRS structures. Skips malformed entries.
_WS_IngestGroups(Groups) {
		global _WS_BUILTIN_PAIRS, _WS_BUILTIN_GROUPS
		for Group in Groups {
				if !(Group is Map) or !Group.Has("pairs") or !(Group["pairs"] is Array)
						continue
				I18nKey := (Group.Has("i18n") and Group["i18n"] is String) ? Group["i18n"] : ""
				GroupPairs := []
				for P in Group["pairs"] {
						if !(P is Map) or !P.Has("left") or !P.Has("right")
								continue
						Pair := Map("left", P["left"], "right", P["right"])
						GroupPairs.Push(Pair)
						_WS_BUILTIN_PAIRS.Push(Pair)
				}
				if (GroupPairs.Length > 0)
						_WS_BUILTIN_GROUPS.Push(Map("i18n", I18nKey, "pairs", GroupPairs))
		}
}

; Returns the live active-pairs Map.  Called by the PrefixWatcher on each keystroke.
; Shape: Map(char -> Map("left", openChar, "right", closeChar))
; Both the opening and closing character of each asymmetric pair are registered as keys.
WrapSymbols_GetActivePairs() {
		global _WS_ACTIVE_PAIRS
		return _WS_ACTIVE_PAIRS
}

; Toggle a built-in symbol on/off by its opening character, then persist + rebuild.
WrapSymbols_Toggle(OpenChar) {
		global _WS_Disabled
		if _WS_Disabled.Has(OpenChar) {
				_WS_Disabled.Delete(OpenChar)
		} else {
				_WS_Disabled[OpenChar] := true
		}
		_WS_Save()
		WrapSymbols_Rebuild()
}

; Enable or disable a set of built-in symbols at once (one save + rebuild),
; used by the per-group « check all / uncheck all » menu actions.
; @param OpenChars Array of opening characters to update.
; @param Enable    true → enable (remove from disabled set), false → disable.
WrapSymbols_SetMany(OpenChars, Enable) {
		global _WS_Disabled
		for _, Ch in OpenChars {
				if Enable {
						if _WS_Disabled.Has(Ch)
								_WS_Disabled.Delete(Ch)
				} else {
						_WS_Disabled[Ch] := true
				}
		}
		_WS_Save()
		WrapSymbols_Rebuild()
}

; Enable all built-in symbols (clear disabled set), then persist + rebuild.
WrapSymbols_EnableAll() {
		global _WS_Disabled
		_WS_Disabled := Map()
		_WS_Save()
		WrapSymbols_Rebuild()
}

; Disable all built-in symbols, then persist + rebuild.
WrapSymbols_DisableAll() {
		global _WS_Disabled, _WS_BUILTIN_PAIRS
		_WS_Disabled := Map()
		for _, Pair in _WS_BUILTIN_PAIRS {
				_WS_Disabled[Pair["left"]] := true
		}
		_WS_Save()
		WrapSymbols_Rebuild()
}

; Reset to factory defaults (all built-ins enabled, no custom pairs), then persist.
WrapSymbols_Reset() {
		global _WS_Disabled, _WS_Custom
		_WS_Disabled := Map()
		_WS_Custom   := []
		_WS_Save()
		WrapSymbols_Rebuild()
}

; Add a custom symbol pair, then persist + rebuild.
; @param LeftChar  string Opening character.
; @param RightChar string Closing character (same as LeftChar when symmetric).
WrapSymbols_AddCustom(LeftChar, RightChar) {
		global _WS_Custom
		_WS_Custom.Push(Map("left", LeftChar, "right", RightChar))
		_WS_Save()
		WrapSymbols_Rebuild()
}

; Remove the custom pair at position Idx (1-based), then persist + rebuild.
WrapSymbols_RemoveCustom(Idx) {
		global _WS_Custom
		if (Idx >= 1 and Idx <= _WS_Custom.Length) {
				_WS_Custom.RemoveAt(Idx)
				_WS_Save()
				WrapSymbols_Rebuild()
		}
}

; Returns true if the given opening symbol is currently enabled (not disabled).
WrapSymbols_IsEnabled(OpenChar) {
		global _WS_Disabled
		return !_WS_Disabled.Has(OpenChar)
}

; Rebuild _WS_ACTIVE_PAIRS from the current state.
; Called automatically after every mutation — no Reload needed.
WrapSymbols_Rebuild() {
		global _WS_ACTIVE_PAIRS, _WS_BUILTIN_PAIRS, _WS_Disabled, _WS_Custom
		Active := Map()
		for _, Pair in _WS_BUILTIN_PAIRS {
				L := Pair["left"]
				R := Pair["right"]
				if !_WS_Disabled.Has(L) {
						Active[L] := Pair
						if (R != L) {
								Active[R] := Pair
						}
				}
		}
		for _, Pair in _WS_Custom {
				L := Pair["left"]
				R := Pair["right"]
				Active[L] := Pair
				if (R != L) {
						Active[R] := Pair
				}
		}
		_WS_ACTIVE_PAIRS := Active
		try LoggerDebug("WrapSymbols", "Rebuilt: {1} active pair(s).", Active.Count)
}




; ===========================================================
; ===========================================================
; ======= 2/ Persistence ====================================
; ===========================================================
; ===========================================================

; Parse the TOML persistence file and populate _WS_Disabled + _WS_Custom.
_WS_Load() {
		global _WS_Config_Path, _WS_Disabled, _WS_Custom, _WS_LoadFailed
		if (!FileExist(_WS_Config_Path)) {
				; A genuinely absent file is not a failure: a fresh install must still be
				; able to save. Only an existing-but-unreadable one blocks persistence.
				return
		}
		try {
				InDisabled := false
				InCustom   := false
				CurLeft    := ""
				CurRight   := ""
				loop read, _WS_Config_Path {
						Line := Trim(A_LoopReadLine, " `t")
						if (Line == "" or SubStr(Line, 1, 1) == ";") {
								continue
						}
						if (Line == "[disabled]" or Line == "[[disabled]]") {
								; Flush a pending custom entry first. This branch predates the flush
								; logic the [[custom]] and generic [ branches already perform, so a
								; [[custom]] block immediately followed by [[disabled]] silently lost
								; the user's wrap pair. It is masked today only because _WS_Save happens
								; to emit disabled blocks before custom ones — a hand-edited or
								; reordered file loses data.
								if (InCustom and CurLeft != "") {
										R := (CurRight != "") ? CurRight : CurLeft
										_WS_Custom.Push(Map("left", CurLeft, "right", R))
								}
								InDisabled := true
								InCustom   := false
								CurLeft    := ""
								CurRight   := ""
								continue
						}
						if (Line == "[[custom]]") {
								; Flush the previous custom entry when entering a new block
								if (CurLeft != "") {
										R := (CurRight != "") ? CurRight : CurLeft
										_WS_Custom.Push(Map("left", CurLeft, "right", R))
								}
								InDisabled := false
								InCustom   := true
								CurLeft    := ""
								CurRight   := ""
								continue
						}
						if (SubStr(Line, 1, 1) == "[") {
								; Flush pending custom entry on any new section
								if (InCustom and CurLeft != "") {
										R := (CurRight != "") ? CurRight : CurLeft
										_WS_Custom.Push(Map("left", CurLeft, "right", R))
										CurLeft := ""
										CurRight := ""
								}
								InDisabled := false
								InCustom   := false
								continue
						}
						if InDisabled {
								; Modern format: [[disabled]] char = "..."
								if RegExMatch(Line, '^char\s*=\s*"(.*)"', &M) {
										_WS_Disabled[_WS_UnescapeToml(M[1])] := true
								}
								; Legacy format: [disabled] chars = "a,b,c"
								else if RegExMatch(Line, '^chars\s*=\s*"(.*)"', &M) {
										for _, Ch in StrSplit(M[1], ",") {
												Trimmed := Trim(Ch, " `t")
												if (Trimmed != "") {
														_WS_Disabled[Trimmed] := true
												}
										}
								}
						} else if InCustom {
								if RegExMatch(Line, '^left\s*=\s*"(.*)"', &M) {
										CurLeft := _WS_UnescapeToml(M[1])
								} else if RegExMatch(Line, '^right\s*=\s*"(.*)"', &M) {
										CurRight := _WS_UnescapeToml(M[1])
								}
						}
				}
				; Flush the last custom block
				if (InCustom and CurLeft != "") {
						R := (CurRight != "") ? CurRight : CurLeft
						_WS_Custom.Push(Map("left", CurLeft, "right", R))
				}
				try LoggerDebug("WrapSymbols", "Loaded: {1} disabled, {2} custom.", _WS_Disabled.Count, _WS_Custom.Length)
		} catch as Err {
				; Latch the failure. The maps above are now EMPTY, and empty is exactly
				; what "the user has disabled nothing and defined no custom pair" looks
				; like — so the next toggle would serialize that emptiness over the real
				; file: every disabled built-in silently re-enabled, every custom pair
				; permanently gone. Same class as the config.toml boot read, and the same
				; cure: an unreadable file must be distinguishable from an empty one.
				_WS_LoadFailed := true
				try LoggerError("WrapSymbols", "Could not read wrap_symbols.toml: {1}. Persistence is now BLOCKED for this session so the settings in that file are not overwritten with an empty set; restart the driver once it is readable.", Err.Message)
		}
}

; Serialize current state to the TOML persistence file.
_WS_Save() {
		global _WS_Config_Path, _WS_Disabled, _WS_Custom, _WS_LoadFailed
		if (_WS_Config_Path == "") {
				return
		}
		; Refuse while the load failed: what would be written is the empty state the
		; failed read left behind, not the user's. Deliberately never cleared —
		; nothing re-reads the file in-process, so the maps stay untrustworthy until
		; the driver restarts.
		if (IsSet(_WS_LoadFailed) && _WS_LoadFailed) {
				try LoggerError("WrapSymbols", "Refusing to save wrap_symbols.toml: it could not be read at load, so the in-memory sets are empty rather than the user's. Restart the driver once the file is readable.")
				return false
		}
		try {
				Lines := "; wrap_symbols.toml — auto-generated by ErgoptiPlus`n"
				for Ch in _WS_Disabled {
						Lines .= "`n[[disabled]]`n"
						Lines .= "char = `"" . _WS_EscapeToml(Ch) . "`"`n"
				}
				for _, Pair in _WS_Custom {
						Lines .= "`n[[custom]]`n"
						Lines .= "left  = `"" . _WS_EscapeToml(Pair["left"])  . "`"`n"
						Lines .= "right = `"" . _WS_EscapeToml(Pair["right"]) . "`"`n"
				}
				; Atomic write: stage to a sibling .tmp file then rename over the target
				; so a crash between truncate and write never leaves a half-empty TOML file
				Tmp := _WS_Config_Path . ".tmp"
				try FileDelete(Tmp)
				FileAppend(Lines, Tmp, "UTF-8")
				FileMove(Tmp, _WS_Config_Path, true)
				try LoggerDebug("WrapSymbols", "Saved: {1} disabled, {2} custom.", _WS_Disabled.Count, _WS_Custom.Length)
		} catch as Err {
				try LoggerError("WrapSymbols", "Could not save wrap_symbols.toml: {1}.", Err.Message)
		}
}

; Minimal TOML string escaping for the two characters we must escape.
_WS_EscapeToml(S) {
		S := StrReplace(S, "\", "\\")
		S := StrReplace(S, Chr(0x22), "\" . Chr(0x22))
		return S
}

; Minimal TOML string unescaping — reverses _WS_EscapeToml.
; \\ must be replaced FIRST so that \" is not consumed before \\ can turn \\\"
; into the correct two-character sequence \" (backslash + quote).
_WS_UnescapeToml(S) {
		S := StrReplace(S, "\\", "\")
		S := StrReplace(S, "\" . Chr(0x22), Chr(0x22))
		return S
}
