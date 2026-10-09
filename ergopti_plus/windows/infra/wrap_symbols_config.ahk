; infra/wrap_symbols_config.ahk

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
; 1. Single source of truth: _WS_BuildActivePairs() is the only place that
;    merges the built-in catalogue with the disabled set and custom entries.
;    The PrefixWatcher reads the published map on every keystroke so changes
;    take effect without a Reload when the symbol is in the base catalogue.
; 2. No Reload required for toggles: one detached projection is published only
;    after its complete TOML candidate has been durably replaced.
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

; Monotonic identity of the complete live wrap-symbol projection. A yielded
; stage write captures this value and must still see it immediately before the
; atomic replace, otherwise a re-init or sibling state replacement won the race.
global _WS_StateEpoch := 0

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
	global _WS_ACTIVE_PAIRS, _WS_LoadFailed, _WS_StateEpoch
	if !(ConfigDir is String) || ConfigDir == "" {
		try LoggerError("WrapSymbols", "Cannot initialize wrap symbols without a configuration directory.")
		return false
	}

	; Invalidate a transaction that yielded before this re-initialization. The
	; load-failed latch belongs to one load attempt, so only init may clear it.
	PreviousCritical := Critical("On")
	try {
		_WS_StateEpoch += 1
		_WS_Config_Path := ConfigDir . "wrap_symbols.toml"
		_WS_Disabled := Map()
		_WS_Custom := []
		_WS_LoadFailed := false
	} finally Critical(PreviousCritical)

	_WS_LoadBuiltinCatalogue()
	_WS_Load()
	CandidateActive := _WS_BuildActivePairs(_WS_Disabled, _WS_Custom)
	if !(CandidateActive is Map) {
		try LoggerError("WrapSymbols", "Cannot initialize wrap symbols: the loaded state is malformed.")
		return false
	}
	PreviousCritical := Critical("On")
	try {
		_WS_ACTIVE_PAIRS := CandidateActive
		_WS_StateEpoch += 1
	} finally Critical(PreviousCritical)
	try LoggerInfo("WrapSymbols", "Initialized ({1} active pair(s), {2} built-in group(s), {3} disabled).",
		_WS_ACTIVE_PAIRS.Count, _WS_BUILTIN_GROUPS.Length, _WS_Disabled.Count)
	return 1
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

; Toggle a built-in symbol on/off by its opening character.
WrapSymbols_Toggle(OpenChar, WriterFn := 0, ReplaceFn := 0, DeleteFn := 0) {
	if !(OpenChar is String) || StrLen(OpenChar) != 1 {
		try LoggerError("WrapSymbols", "Refusing to toggle an invalid opening symbol.")
		return false
	}
	return _WS_CommitCandidate(_WS_BuildToggleCandidate.Bind(OpenChar),
		WriterFn, ReplaceFn, DeleteFn)
}

; Enable or disable a set of built-in symbols at once (one save + rebuild),
; used by the per-group « check all / uncheck all » menu actions.
; @param OpenChars Array of opening characters to update.
; @param Enable    true → enable (remove from disabled set), false → disable.
WrapSymbols_SetMany(OpenChars, Enable, WriterFn := 0, ReplaceFn := 0,
		DeleteFn := 0) {
	if !(OpenChars is Array) || !(Enable is Integer)
			|| (Enable != 0 && Enable != 1) {
		try LoggerError("WrapSymbols", "Refusing a malformed multi-symbol update.")
		return false
	}
	for Ch in OpenChars {
		if !(Ch is String) || StrLen(Ch) != 1 {
			try LoggerError("WrapSymbols", "Refusing a multi-symbol update containing an invalid symbol.")
			return false
		}
	}
	return _WS_CommitCandidate(_WS_BuildManyCandidate.Bind(OpenChars, Enable),
		WriterFn, ReplaceFn, DeleteFn)
}

; Enable all built-in symbols, then persist the detached candidate.
WrapSymbols_EnableAll(WriterFn := 0, ReplaceFn := 0, DeleteFn := 0) {
	return _WS_CommitCandidate(_WS_BuildEnableAllCandidate,
		WriterFn, ReplaceFn, DeleteFn)
}

; Disable all built-in symbols, then persist the detached candidate.
WrapSymbols_DisableAll(WriterFn := 0, ReplaceFn := 0, DeleteFn := 0) {
	return _WS_CommitCandidate(_WS_BuildDisableAllCandidate,
		WriterFn, ReplaceFn, DeleteFn)
}

; Reset to factory defaults only when the loaded state is trustworthy.
WrapSymbols_Reset(WriterFn := 0, ReplaceFn := 0, DeleteFn := 0) {
	return _WS_CommitCandidate(_WS_BuildResetCandidate,
		WriterFn, ReplaceFn, DeleteFn)
}

; Add a custom symbol pair, then persist + rebuild.
; @param LeftChar  string Opening character.
; @param RightChar string Closing character (same as LeftChar when symmetric).
WrapSymbols_AddCustom(LeftChar, RightChar, WriterFn := 0, ReplaceFn := 0,
		DeleteFn := 0) {
	if !(LeftChar is String) || !(RightChar is String)
			|| StrLen(LeftChar) != 1 || StrLen(RightChar) != 1 {
		try LoggerError("WrapSymbols", "Refusing to add a malformed custom symbol pair.")
		return false
	}
	return _WS_CommitCandidate(
		_WS_BuildAddCustomCandidate.Bind(LeftChar, RightChar),
		WriterFn, ReplaceFn, DeleteFn)
}

; Remove the custom pair at position Idx (1-based), then persist + rebuild.
WrapSymbols_RemoveCustom(Idx, WriterFn := 0, ReplaceFn := 0, DeleteFn := 0) {
	if !(Idx is Integer) || Idx < 1 {
		try LoggerError("WrapSymbols", "Refusing to remove a custom symbol at an invalid index.")
		return false
	}
	return _WS_CommitCandidate(_WS_BuildRemoveCustomCandidate.Bind(Idx),
		WriterFn, ReplaceFn, DeleteFn)
}

; Returns true if the given opening symbol is currently enabled (not disabled).
WrapSymbols_IsEnabled(OpenChar) {
		global _WS_Disabled
		return !_WS_Disabled.Has(OpenChar)
}

; Build an unpublished active-pairs projection from detached candidates.
_WS_BuildActivePairs(Disabled, Custom) {
	global _WS_BUILTIN_PAIRS
	if !(Disabled is Map) || !(Custom is Array)
		return false
	Active := Map()
	for Pair in _WS_BUILTIN_PAIRS {
		if !(Pair is Map) || !Pair.Has("left") || !Pair.Has("right")
			return false
		L := Pair["left"]
		R := Pair["right"]
		if !(L is String) || !(R is String)
			return false
		if !Disabled.Has(L) {
			Active[L] := Pair
			if (R != L)
				Active[R] := Pair
		}
	}
	for Pair in Custom {
		if !(Pair is Map) || !Pair.Has("left") || !Pair.Has("right")
			return false
		L := Pair["left"]
		R := Pair["right"]
		if !(L is String) || !(R is String)
			return false
		Active[L] := Pair
		if (R != L)
			Active[R] := Pair
	}
	return Active
}

; Deep-clone custom pair Maps so no unpublished object aliases live state.
_WS_CloneCustom(Custom) {
	if !(Custom is Array)
		return false
	Candidate := []
	for Pair in Custom {
		if !(Pair is Map) || !Pair.Has("left") || !Pair.Has("right")
			return false
		LeftChar := Pair["left"]
		RightChar := Pair["right"]
		if !(LeftChar is String) || !(RightChar is String)
			return false
		Candidate.Push(Map("left", LeftChar, "right", RightChar))
	}
	return Candidate
}

_WS_BuildToggleCandidate(OpenChar, Disabled, Custom) {
	if Disabled.Has(OpenChar)
		Disabled.Delete(OpenChar)
	else
		Disabled[OpenChar] := true
	return 1
}

_WS_BuildManyCandidate(OpenChars, Enable, Disabled, Custom) {
	for Ch in OpenChars {
		if Enable {
			if Disabled.Has(Ch)
				Disabled.Delete(Ch)
		} else
			Disabled[Ch] := true
	}
	return 1
}

_WS_BuildEnableAllCandidate(Disabled, Custom) {
	Disabled.Clear()
	return 1
}

_WS_BuildDisableAllCandidate(Disabled, Custom) {
	global _WS_BUILTIN_PAIRS
	Disabled.Clear()
	for Pair in _WS_BUILTIN_PAIRS {
		if !(Pair is Map) || !Pair.Has("left")
			return false
		Disabled[Pair["left"]] := true
	}
	return 1
}

_WS_BuildResetCandidate(Disabled, Custom) {
	Disabled.Clear()
	Custom.Length := 0
	return 1
}

_WS_BuildAddCustomCandidate(LeftChar, RightChar, Disabled, Custom) {
	Custom.Push(Map("left", LeftChar, "right", RightChar))
	return 1
}

_WS_BuildRemoveCustomCandidate(Idx, Disabled, Custom) {
	if Idx > Custom.Length {
		try LoggerError("WrapSymbols", "Refusing to remove a custom symbol beyond the current list.")
		return false
	}
	Custom.RemoveAt(Idx)
	return 1
}

; Own the wrap-symbol store before reading live state. BuildFn mutates only the
; detached clones; _WS_Save publishes them only after the final durable rename.
_WS_CommitCandidate(BuildFn, WriterFn := 0, ReplaceFn := 0, DeleteFn := 0) {
	global _WS_Config_Path, _WS_Disabled, _WS_Custom, _WS_LoadFailed
	global _WS_StateEpoch
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		; The global write owner, not a caller-level Critical span, serializes
		; this transaction. Defuse inherited Critical before any staging,
		; filesystem replacement, cleanup or logging can run.
		Critical("Off")
		try return _WS_CommitCandidate(BuildFn, WriterFn, ReplaceFn, DeleteFn)
		finally Critical(InheritedCritical)
	}
	if !HasMethod(BuildFn, "Call") {
		try LoggerError("WrapSymbols", "Refusing a wrap-symbol update with a non-callable candidate builder.")
		return false
	}
	BoundPath := _WS_Config_Path
	if !(BoundPath is String) || BoundPath == "" {
		try LoggerError("WrapSymbols", "Refusing to save wrap symbols before initialization provided a target path.")
		return false
	}
	OwnerToken := _ConfigWriteLeaseTryAcquire(BoundPath, "wrap-symbols")
	if !(OwnerToken is Object) {
		try LoggerError("WrapSymbols", "Refusing to save wrap symbols: another configuration transaction is in progress.")
		return false
	}
	try {
		if A_IsSuspended {
			try LoggerError("WrapSymbols", "Refusing to save wrap symbols while the driver is suspended.")
			return false
		}
		if !_ConfigWriteLeaseOwns(OwnerToken, BoundPath)
				|| _ConfigWriteLeaseKey(_WS_Config_Path)
					!= _ConfigWriteLeaseKey(BoundPath) {
			try LoggerError("WrapSymbols", "Refusing to save wrap symbols through a stale target owner.")
			return false
		}
		if _WS_LoadFailed {
			try LoggerError("WrapSymbols", "Refusing to save wrap_symbols.toml: it could not be read at load, so the live state is untrustworthy. Restart the driver once the file is readable.")
			return false
		}
		if !(_WS_Disabled is Map) || !(_WS_Custom is Array) {
			try LoggerError("WrapSymbols", "Refusing to save malformed live wrap-symbol state.")
			return false
		}

		StartEpoch := _WS_StateEpoch
		CandidateDisabled := _WS_Disabled.Clone()
		CandidateCustom := _WS_CloneCustom(_WS_Custom)
		if !(CandidateCustom is Array) {
			try LoggerError("WrapSymbols", "Refusing to save malformed custom wrap-symbol state.")
			return false
		}
		BuildStatus := false
		try BuildStatus := BuildFn.Call(CandidateDisabled, CandidateCustom)
		catch as Err {
			try LoggerError("WrapSymbols", "Building a wrap-symbol candidate failed: {1}.", Err.Message)
			return false
		}
		if !(BuildStatus is Integer) || BuildStatus != 1 {
			try LoggerError("WrapSymbols", "The wrap-symbol candidate builder refused the update.")
			return false
		}
		CandidateActive := _WS_BuildActivePairs(CandidateDisabled, CandidateCustom)
		if !(CandidateActive is Map) {
			try LoggerError("WrapSymbols", "Refusing to save a malformed wrap-symbol candidate.")
			return false
		}
		return _WS_Save(CandidateDisabled, CandidateCustom, CandidateActive,
			OwnerToken, BoundPath, StartEpoch, WriterFn, ReplaceFn, DeleteFn)
	} finally _ConfigWriteLeaseRelease(OwnerToken)
}

; Convert one detached state into the complete TOML artifact.
_WS_SerializeCandidate(Disabled, Custom) {
	if !(Disabled is Map) || !(Custom is Array)
		return false
	Lines := "; wrap_symbols.toml — auto-generated by ErgoptiPlus`n"
	for Ch in Disabled {
		if !(Ch is String) || StrLen(Ch) != 1
			return false
		Lines .= "`n[[disabled]]`n"
		Lines .= "char = `"" . _WS_EscapeToml(Ch) . "`"`n"
	}
	for Pair in Custom {
		if !(Pair is Map) || !Pair.Has("left") || !Pair.Has("right")
			return false
		LeftChar := Pair["left"]
		RightChar := Pair["right"]
		if !(LeftChar is String) || !(RightChar is String)
				|| StrLen(LeftChar) != 1 || StrLen(RightChar) != 1
			return false
		Lines .= "`n[[custom]]`n"
		Lines .= "left  = `"" . _WS_EscapeToml(LeftChar) . "`"`n"
		Lines .= "right = `"" . _WS_EscapeToml(RightChar) . "`"`n"
	}
	return Lines
}

; A rejected stage is private and disposable. A cleanup failure is reported so
; a residue never masquerades as a successfully published transaction.
_WS_CleanupStage(StagePath, DeleteFn := 0) {
	if !HasMethod(DeleteFn, "Call") && !FileExist(StagePath)
		return 1
	Deleted := false
	try {
		if HasMethod(DeleteFn, "Call")
			Deleted := DeleteFn.Call(StagePath)
		else {
			FileDelete(StagePath)
			Deleted := 1
		}
	} catch as Err {
		try LoggerError("WrapSymbols", "Could not remove rejected staging file '{1}': {2}.",
			StagePath, Err.Message)
		return false
	}
	if !(Deleted is Integer) || Deleted != 1 {
		try LoggerError("WrapSymbols", "Could not remove rejected staging file '{1}': the delete adapter refused it.", StagePath)
		return false
	}
	return 1
}

; Re-check every revocable fact after the complete stage exists. In particular,
; Suspend can land while the writer yields, and re-init changes both path and
; epoch without participating in this store's write lease.
_WS_AuthorizeCommit(OwnerToken, BoundPath, StartEpoch) {
	global _WS_Config_Path, _WS_LoadFailed, _WS_StateEpoch
	if A_IsSuspended || _WS_LoadFailed
		return false
	if !_ConfigWriteLeaseOwns(OwnerToken, BoundPath)
		return false
	if _ConfigWriteLeaseKey(_WS_Config_Path) != _ConfigWriteLeaseKey(BoundPath)
		return false
	if _WS_StateEpoch != StartEpoch
		return false
	return 1
}

; Publish the three live structures as one memory-only projection. The caller
; invokes this in the same tiny Critical span as the durable rename.
_WS_PublishCandidate(Disabled, Custom, Active, StartEpoch) {
	global _WS_Disabled, _WS_Custom, _WS_ACTIVE_PAIRS, _WS_StateEpoch
	if !(Disabled is Map) || !(Custom is Array) || !(Active is Map)
		return false
	if _WS_StateEpoch != StartEpoch
		return false
	_WS_Disabled := Disabled
	_WS_Custom := Custom
	_WS_ACTIVE_PAIRS := Active
	_WS_StateEpoch += 1
	return 1
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

; Serialize, stage and commit one detached state. The no-argument form remains
; for internal compatibility, but acquires the same global lease before cloning
; live state instead of bypassing the transaction gateway.
_WS_Save(DisabledCandidate := unset, CustomCandidate := unset,
		ActiveCandidate := unset, OwnerToken := 0, BoundPath := unset,
		StartEpoch := unset, WriterFn := 0, ReplaceFn := 0, DeleteFn := 0) {
	global _WS_Config_Path, _WS_Disabled, _WS_Custom, _WS_LoadFailed
	global _WS_StateEpoch
	BorrowedOwner := OwnerToken is Object
	if !BorrowedOwner {
		CompatibilityPath := _WS_Config_Path
		if !(CompatibilityPath is String) || CompatibilityPath == "" {
			try LoggerError("WrapSymbols", "Refusing to save wrap symbols before initialization provided a target path.")
			return false
		}
		CompatibilityOwner := _ConfigWriteLeaseTryAcquire(
			CompatibilityPath, "wrap-symbols-compatibility")
		if !(CompatibilityOwner is Object) {
			try LoggerError("WrapSymbols", "Refusing to save wrap symbols: another configuration transaction is in progress.")
			return false
		}
		try {
			return _WS_Save(unset, unset, unset, CompatibilityOwner,
				CompatibilityPath, _WS_StateEpoch,
				WriterFn, ReplaceFn, DeleteFn)
		} finally _ConfigWriteLeaseRelease(CompatibilityOwner)
	}

	if !IsSet(BoundPath) || !(BoundPath is String) || BoundPath == ""
			|| !IsSet(StartEpoch) || !(StartEpoch is Integer) {
		try LoggerError("WrapSymbols", "Refusing a wrap-symbol save with an incomplete transaction identity.")
		return false
	}
	if !_ConfigWriteLeaseOwns(OwnerToken, BoundPath)
			|| _ConfigWriteLeaseKey(_WS_Config_Path)
				!= _ConfigWriteLeaseKey(BoundPath) {
		try LoggerError("WrapSymbols", "Refusing a wrap-symbol save through a stale target owner.")
		return false
	}
	if A_IsSuspended {
		try LoggerError("WrapSymbols", "Refusing to save wrap symbols while the driver is suspended.")
		return false
	}
	if _WS_LoadFailed {
		try LoggerError("WrapSymbols", "Refusing to save wrap_symbols.toml: it could not be read at load, so the live state is untrustworthy. Restart the driver once the file is readable.")
		return false
	}

	HasDetachedCandidate := IsSet(DisabledCandidate)
		&& IsSet(CustomCandidate) && IsSet(ActiveCandidate)
	if !HasDetachedCandidate {
		if IsSet(DisabledCandidate) || IsSet(CustomCandidate)
				|| IsSet(ActiveCandidate) {
			try LoggerError("WrapSymbols", "Refusing an incomplete detached wrap-symbol candidate.")
			return false
		}
		if !(_WS_Disabled is Map) || !(_WS_Custom is Array) {
			try LoggerError("WrapSymbols", "Refusing to save malformed live wrap-symbol state.")
			return false
		}
		DisabledCandidate := _WS_Disabled.Clone()
		CustomCandidate := _WS_CloneCustom(_WS_Custom)
		ActiveCandidate := _WS_BuildActivePairs(
			DisabledCandidate, CustomCandidate)
	}
	if !(DisabledCandidate is Map) || !(CustomCandidate is Array)
			|| !(ActiveCandidate is Map) {
		try LoggerError("WrapSymbols", "Refusing a malformed detached wrap-symbol candidate.")
		return false
	}
	if !((WriterFn is Integer) && WriterFn == 0)
			&& !HasMethod(WriterFn, "Call") {
		try LoggerError("WrapSymbols", "Refusing a wrap-symbol save with a non-callable stage writer.")
		return false
	}
	if !((ReplaceFn is Integer) && ReplaceFn == 0)
			&& !HasMethod(ReplaceFn, "Call") {
		try LoggerError("WrapSymbols", "Refusing a wrap-symbol save with a non-callable replace adapter.")
		return false
	}
	if !((DeleteFn is Integer) && DeleteFn == 0)
			&& !HasMethod(DeleteFn, "Call") {
		try LoggerError("WrapSymbols", "Refusing a wrap-symbol save with a non-callable cleanup adapter.")
		return false
	}

	Content := _WS_SerializeCandidate(DisabledCandidate, CustomCandidate)
	if !(Content is String) {
		try LoggerError("WrapSymbols", "Refusing to serialize malformed wrap-symbol state.")
		return false
	}
	static WriteSequence := 0
	PreviousCritical := Critical("On")
	try LocalSequence := ++WriteSequence
	finally Critical(PreviousCritical)
	StagePath := BoundPath . "." . A_ScriptHwnd . "-" . LocalSequence . ".tmp"

	Written := false
	WriteError := ""
	try Written := HasMethod(WriterFn, "Call")
		? WriterFn.Call(StagePath, Content) : FSWriteDurable(StagePath, Content)
	catch as Err {
		Written := false
		WriteError := Err.Message
	}
	Written := (Written is Integer) && Written == 1
	if !Written {
		if (WriteError != "") {
			try LoggerError("WrapSymbols", "Writing staging file for '{1}' failed: {2}. The previous contents are intact.", BoundPath, WriteError)
		} else {
			try LoggerError("WrapSymbols", "Writing staging file for '{1}' was refused. The previous contents are intact.", BoundPath)
		}
		_WS_CleanupStage(StagePath, DeleteFn)
		return false
	}

	Authorized := false
	PreviousCritical := Critical("On")
	try {
		Authorized := _WS_AuthorizeCommit(OwnerToken, BoundPath, StartEpoch)
		Authorized := (Authorized is Integer) && Authorized == 1
	} finally Critical(PreviousCritical)

	if !Authorized {
		try LoggerError("WrapSymbols", "Authorization before publishing '{1}' was refused. The previous contents are intact.", BoundPath)
		_WS_CleanupStage(StagePath, DeleteFn)
		return false
	}

	; Atomic replacement can block in filesystem filters or antivirus code.
	; Keep the exact global owner, but never keep Critical, across this OS call.
	Replaced := false
	ReplaceError := ""
	try Replaced := HasMethod(ReplaceFn, "Call")
		? ReplaceFn.Call(StagePath, BoundPath)
		: FSAtomicMoveReplace(StagePath, BoundPath)
	catch as Err {
		Replaced := false
		ReplaceError := Err.Message
	}
	Replaced := (Replaced is Integer) && Replaced == 1
	if !Replaced {
		if (ReplaceError != "") {
			try LoggerError("WrapSymbols", "Atomic replacement of '{1}' failed: {2}. The previous contents are intact.", BoundPath, ReplaceError)
		} else {
			try LoggerError("WrapSymbols", "Atomic replacement of '{1}' was refused. The previous contents are intact.", BoundPath)
		}
		_WS_CleanupStage(StagePath, DeleteFn)
		return false
	}

	; Only the memory projection is atomic. Disk is already durable and the
	; global owner still prevents any sibling writer or terminal transition.
	Published := false
	PublishError := ""
	PreviousCritical := Critical("On")
	try {
		try Published := _WS_PublishCandidate(DisabledCandidate,
			CustomCandidate, ActiveCandidate, StartEpoch)
		catch as Err {
			Published := false
			PublishError := Err.Message
		}
		Published := (Published is Integer) && Published == 1
	} finally Critical(PreviousCritical)
	if !Published {
		if (PublishError != "") {
			try LoggerError("WrapSymbols", "Wrap-symbol state became durable at '{1}', but live publication failed: {2}. Reload is required.", BoundPath, PublishError)
		} else {
			try LoggerError("WrapSymbols", "Wrap-symbol state became durable at '{1}', but live publication was refused. Reload is required.", BoundPath)
		}
		return false
	}

	try LoggerDebug("WrapSymbols", "Saved and published: {1} disabled, {2} custom.",
		DisabledCandidate.Count, CustomCandidate.Length)
	return 1
}

; Escapes custom symbols through the complete shared TOML basic-string codec.
_WS_EscapeToml(S) {
		return TOML_EscapeBasicStringContents(S)
}

; Reverses _WS_EscapeToml through the same complete shared codec.
_WS_UnescapeToml(S) {
		return TOML_UnescapeBasicStringContents(S)
}
