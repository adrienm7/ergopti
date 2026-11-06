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

; Whether Ch is the opening value of a built-in catalogue pair. The catalogue
; spells the French guillemets with their spaces ("« "), so a built-in opening
; value is not always one character long; only custom pairs are single characters.
_WS_IsBuiltinLeft(Ch) {
	global _WS_BUILTIN_PAIRS
	if !(Ch is String) || Ch == ""
		return false
	for Pair in _WS_BUILTIN_PAIRS {
		if (Pair is Map) && Pair.Has("left") && Pair["left"] == Ch
			return true
	}
	return false
}

; Toggle a built-in symbol on/off by its opening character.
WrapSymbols_Toggle(OpenChar, WriterFn := 0, ReplaceFn := 0, DeleteFn := 0) {
	if !_WS_IsBuiltinLeft(OpenChar) {
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
		if !_WS_IsBuiltinLeft(Ch) {
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
; The saved custom pair a typed symbol belongs to, as its opening or closing
; character, or 0. The last saved pair wins, as in _WS_BuildActivePairs, so a
; layout route that carries its own delimiters can still honour a user's pair.
; @param Symbol {String} The character the key types.
WrapSymbols_CustomPairFor(Symbol) {
	global _WS_Custom
	Found := 0
	for Pair in _WS_Custom {
		if (Pair is Map) && Pair.Has("left") && Pair.Has("right")
				&& (Pair["left"] == Symbol || Pair["right"] == Symbol)
			Found := Pair
	}
	return Found
}

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
		SourceReceipt := _WS_CurrentSourceReceipt(BoundPath)
		if !IsObject(SourceReceipt) || !_FSSourceIsUnchanged(BoundPath, SourceReceipt.source) {
			try LoggerError("WrapSymbols", "The wrap-symbol source changed since load; reload before retrying.")
			return false
		}
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
			OwnerToken, BoundPath, StartEpoch, WriterFn, ReplaceFn, DeleteFn, 0, SourceReceipt)
	} finally _ConfigWriteLeaseRelease(OwnerToken)
}

; Convert one detached state into the complete TOML artifact.
_WS_SerializeCandidate(Disabled, Custom) {
	if !(Disabled is Map) || !(Custom is Array)
		return false
	Lines := "; wrap_symbols.toml — auto-generated by ErgoptiPlus`n"
	for Ch in Disabled {
		if !(Ch is String) || Ch == ""
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

; Adapt the owner's legacy semicolon comments with the canonical lexical owner.
; Its quote/container state spans multiline values, so cited semicolons never
; become comments. The returned text is read-only input, never written to disk.
_WS_CanonicalTomlSource(Content) {
	Result := "", Position := 1, Length := StrLen(Content)
	while Position <= Length {
		Start := Position
		_TOML_DocumentToken(Content, &Position, ";", &Separated)
		if !Separated {
			Result .= SubStr(Content, Start)
			break
		}
		Semicolon := Position - 1
		Result .= SubStr(Content, Start, Semicolon - Start) . "#"
		NextLine := InStr(Content, "`n", true, Position)
		End := NextLine ? NextLine + 1 : Length + 1
		Result .= SubStr(Content, Position, End - Position)
		Position := End
	}
	return Result
}

_WS_ProjectDisabled(Entry, Disabled) {
	if !(Entry is Map)
		throw ValueError("A wrap-symbol disabled entry must be a table.")
	if Entry.Has("char") {
		Character := Entry["char"]
		if !(Character is String) || Character == ""
			throw ValueError("A disabled wrap symbol must be nonempty text.")
		; Built-in spaced guillemets can contain several UTF-16 units.
		Disabled[Character] := true
	}
	if Entry.Has("chars") {
		if !(Entry["chars"] is String)
			throw ValueError("Legacy disabled wrap symbols must be comma-separated text.")
		for Character in StrSplit(Entry["chars"], ",") {
			Character := Trim(Character, " `t")
			if Character != ""
				Disabled[Character] := true
		}
	}
}

_WS_ProjectCustom(Entry, Custom) {
	if !(Entry is Map)
		throw ValueError("A custom wrap-symbol entry must be a table.")
	if !Entry.Has("left") {
		if Entry.Has("right")
			throw ValueError("A custom wrap-symbol entry has no opening symbol.")
		return
	}
	Left := Entry["left"], Right := Entry.Get("right", "")
	if !(Left is String) || !(Right is String) || Left == ""
		throw ValueError("Custom wrap symbols must be nonempty text.")
	; The legacy reader treats an absent/empty right side as a symmetric pair.
	Right := Right == "" ? Left : Right
	if StrLen(Left) != 1 || StrLen(Right) != 1
		throw ValueError("Custom wrap symbols must fit the native single-symbol domain.")
	Custom.Push(Map("left", Left, "right", Right))
}


; A receipt belongs to the two actual parsed/published objects, never a clone.
; The metadata has no backreference to its Array or Map and needs no ledger.
_WS_BindSourceReceipt(Custom, Disabled, Path, Source) {
	if !(Custom is Array) || !(Disabled is Map) || !(Source is Map)
		throw TypeError("A wrap source receipt needs a complete projection")
	Status := Source.Get("status", "")
	if (Status != "ok" && Status != "absent") || !(Source.Get("content", 0) is String)
		throw ValueError("An unreadable wrap source cannot issue write permission")
	Receipt := {custom: ObjPtr(Custom), disabled: ObjPtr(Disabled),
		path: _ConfigWriteLeaseKey(Path), source: Map("status", Status, "content", Source["content"])}
	Custom.DefineProp("_WS_SourceReceipt", {Value: Receipt})
	return Receipt
}
_WS_CurrentSourceReceipt(Path) {
	global _WS_Custom, _WS_Disabled
	if !(_WS_Custom is Array) || !(_WS_Disabled is Map)
		return 0
	if !Object.Prototype.HasOwnProp.Call(_WS_Custom, "_WS_SourceReceipt")
		return 0
	Receipt := Object.Prototype.GetOwnPropDesc.Call(_WS_Custom, "_WS_SourceReceipt").Value
	return _WS_SourceReceiptCurrent(Receipt, Path) ? Receipt : 0
}
_WS_SourceReceiptCurrent(Receipt, Path) {
	global _WS_Custom, _WS_Disabled
	if !IsObject(Receipt) || !(_WS_Custom is Array) || !(_WS_Disabled is Map)
		return false
	if !Object.Prototype.HasOwnProp.Call(_WS_Custom, "_WS_SourceReceipt")
		return false
	return Object.Prototype.GetOwnPropDesc.Call(_WS_Custom, "_WS_SourceReceipt").Value == Receipt
		&& Receipt.custom == ObjPtr(_WS_Custom) && Receipt.disabled == ObjPtr(_WS_Disabled)
		&& Receipt.path == _ConfigWriteLeaseKey(Path)
}
_WS_FinalSourceAdmission(OwnerToken, Path, Epoch, Receipt) {
	return _WS_AuthorizeCommit(OwnerToken, Path, Epoch)
		&& _WS_SourceReceiptCurrent(Receipt, Path)
}

; Parse into detached state, then publish only a complete admitted projection.
; Unknown roots retain the previous owner's ignored-root policy; malformed or
; unprojectable owned leaves latch so a later save cannot erase their data.
_WS_Load() {
	global _WS_Config_Path, _WS_Disabled, _WS_Custom, _WS_LoadFailed
	try {
		Source := FSReadWithStatus(_WS_Config_Path)
		if Source["status"] == "absent" {
			_WS_BindSourceReceipt(_WS_Custom, _WS_Disabled, _WS_Config_Path, Source)
			return
		}
		if Source["status"] != "ok"
			throw Error("The wrap source cannot be read as exact UTF-8")
		Content := Source["content"]
		; FileRead(UTF-8) previously consumed a BOM; keep that decoder boundary
		; while retaining its exact bytes in the source receipt.
		if SubStr(Content, 1, 1) == Chr(0xFEFF)
			Content := SubStr(Content, 2)
		Document := TOML_ParseDocument(_WS_CanonicalTomlSource(Content), &Records, &Physical)
		for Record in Physical
			if Record.Kind == "opaque"
				throw ValueError("The wrap-symbol source contains an uninterpreted record.")
		Disabled := Map(), Custom := []
		if Document.Has("disabled") {
			Entries := Document["disabled"]
			if Entries is Map
				_WS_ProjectDisabled(Entries, Disabled)
			else if Entries is Array {
				for Entry in Entries
					_WS_ProjectDisabled(Entry, Disabled)
			} else
				throw ValueError("The disabled wrap-symbol source has an unsupported shape.")
		}
		if Document.Has("custom") {
			if !(Document["custom"] is Array)
				throw ValueError("Custom wrap symbols require a table array.")
			for Entry in Document["custom"]
				_WS_ProjectCustom(Entry, Custom)
		}
		_WS_Disabled := Disabled, _WS_Custom := Custom
		_WS_BindSourceReceipt(Custom, Disabled, _WS_Config_Path, Source)
		try LoggerDebug("WrapSymbols", "Loaded: {1} disabled, {2} custom.", _WS_Disabled.Count, _WS_Custom.Length)
	} catch as Err {
		; Only Init may clear this latch. Never serialize an incomplete view.
		_WS_LoadFailed := true
		try LoggerError("WrapSymbols", "Could not read or interpret wrap_symbols.toml: {1}. Persistence is now BLOCKED for this session so source data cannot be overwritten by an incomplete projection; restart once the file is readable and valid.", Err.Message)
	}
}

; Serialize, stage and commit one detached state. The no-argument form remains
; for internal compatibility, but acquires the same global lease before cloning
; live state instead of bypassing the transaction gateway.
; A reader may inspect the native cutpoint, but no other writer/deleter may
; replace the stage while its original exclusive-create handle is retained.
_WS_CreateReadableHeldStage(Folder, Name, Attributes) {
	return _FSCreateHeldStage(Folder, Name, Attributes, 1) ; FILE_SHARE_READ only
}

_WS_BeforeHeldPublication(OwnerToken, BoundPath, StartEpoch, ExpectedSource, BeforeNativeFn) {
	PreviousCritical := Critical("On")
	try Authorized := _WS_AuthorizeCommit(OwnerToken, BoundPath, StartEpoch)
	finally Critical(PreviousCritical)
	if !(Authorized is Integer) || Authorized != 1
		return false
	if HasMethod(BeforeNativeFn, "Call")
		BeforeNativeFn.Call()
	else if !((BeforeNativeFn is Integer) && BeforeNativeFn == 0)
		throw TypeError("The private native cutpoint is not callable")
	; Exact source I/O precedes the pure final admission/held rename wrapper.
	; This is not a kernel compare-and-swap of another process's source edits.
	return _FSSourceIsUnchanged(BoundPath, ExpectedSource.source)
}

; A visible native replacement without its durability ACK is not unchanged.
; Fence only this still-current old projection; never poison a newer reload.
_WS_LatchUnacknowledgedPublication(ExpectedSource, BoundPath, StartEpoch) {
	global _WS_LoadFailed, _WS_StateEpoch, _WS_Config_Path
	PreviousCritical := Critical("On")
	try {
		if _WS_StateEpoch == StartEpoch && _WS_SourceReceiptCurrent(ExpectedSource, BoundPath)
				&& _ConfigWriteLeaseKey(_WS_Config_Path) == _ConfigWriteLeaseKey(BoundPath) {
			_WS_LoadFailed := true
			return true
		}
		return false
	} finally Critical(PreviousCritical)
}

_WS_Save(DisabledCandidate := unset, CustomCandidate := unset,
		ActiveCandidate := unset, OwnerToken := 0, BoundPath := unset,
		StartEpoch := unset, WriterFn := 0, ReplaceFn := 0, DeleteFn := 0, BeforeNativeFn := 0, ExpectedSource := 0) {
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
			CompatibilitySource := _WS_CurrentSourceReceipt(CompatibilityPath)
			return _WS_Save(unset, unset, unset, CompatibilityOwner,
				CompatibilityPath, _WS_StateEpoch,
				WriterFn, ReplaceFn, DeleteFn, BeforeNativeFn, CompatibilitySource)
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

	if !_WS_SourceReceiptCurrent(ExpectedSource, BoundPath)
			|| !_FSSourceIsUnchanged(BoundPath, ExpectedSource.source) {
		try LoggerError("WrapSymbols", "Refusing to reconstruct a wrap-symbol source no longer owned by this loaded projection.")
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

	try Content := _WS_SerializeCandidate(DisabledCandidate, CustomCandidate)
	catch ValueError as Err {
		try LoggerError("WrapSymbols", "Refusing to serialize a wrap-symbol candidate outside the native text domain.")
		return false
	}
	if !(Content is String) {
		try LoggerError("WrapSymbols", "Refusing to serialize malformed wrap-symbol state.")
		return false
	}
	static WriteSequence := 0
	PreviousCritical := Critical("On")
	try LocalSequence := ++WriteSequence
	finally Critical(PreviousCritical)
	StagePath := BoundPath . "." . A_ScriptHwnd . "-" . LocalSequence . ".tmp"

	NativeAdapters := (WriterFn is Integer) && WriterFn == 0
		&& (ReplaceFn is Integer) && ReplaceFn == 0
		&& (DeleteFn is Integer) && DeleteFn == 0
	if NativeAdapters {
		; Retain the exclusively created stage and its parent through the actual
		; rename and cleanup; never reopen or retire an unowned stage pathname.
		BeforePublish := _WS_BeforeHeldPublication.Bind(OwnerToken, BoundPath,
			StartEpoch, ExpectedSource, BeforeNativeFn)
		FinalAdmission := _WS_FinalSourceAdmission.Bind(OwnerToken, BoundPath, StartEpoch, ExpectedSource)
		StageSuffix := SubStr(StagePath, StrLen(BoundPath) + 1)
		if !FSWriteReplaceOwned(BoundPath, Content, StageSuffix, &StageDetail,
				_WS_CreateReadableHeldStage, BeforePublish, FinalAdmission,
				ExpectedSource.source["status"] != "absent", &Publication) {
			if Publication.renamed && !Publication.durable {
				Latched := _WS_LatchUnacknowledgedPublication(ExpectedSource, BoundPath, StartEpoch)
				PartialDetail := "the file was replaced but durable completion was not acknowledged; "
					. (Latched ? "the old live projection was fenced pending a reload. "
						: "this superseded completion no longer owns the current live state. ")
				return ConfigReportPersistenceFailure("wrap-symbol publication", 0,
					PartialDetail . StageDetail, false)
			}
			try LoggerError("WrapSymbols", "Owned wrap-symbol publication at '{1}' was refused: {2}.", BoundPath, StageDetail)
			return false
		}
	} else {
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

		; Keep source reads and staging outside Critical. Only the native wrapper
		; protects the final memory admission and its immediately following rename.
		Replaced := false
		ReplaceError := ""
		try {
			; Optional observation of the final native cutpoint, internal to this
			; helper; the public two-argument replace adapter keeps its existing ABI.
			if HasMethod(BeforeNativeFn, "Call")
				BeforeNativeFn.Call()
			else if !((BeforeNativeFn is Integer) && BeforeNativeFn == 0)
				throw TypeError("The private native cutpoint is not callable")
			; Complete the exact source read outside Critical. The immediately
			; following native wrapper rechecks only memory ownership under Critical.
			; This is not a cross-process kernel compare-and-swap of file contents.
			if !_FSSourceIsUnchanged(BoundPath, ExpectedSource.source)
				throw Error("The wrap-symbol source changed before native publication")
			FinalAdmission := _WS_FinalSourceAdmission.Bind(OwnerToken, BoundPath, StartEpoch, ExpectedSource)
			if HasMethod(ReplaceFn, "Call") {
				; Preserve the existing adapter ABI, but never grant it a stale source.
				Replaced := FinalAdmission.Call() && ReplaceFn.Call(StagePath, BoundPath)
			} else if ExpectedSource.source["status"] == "absent"
				Replaced := FSConfigAtomicMoveCreate(StagePath, BoundPath, FinalAdmission)
			else
				Replaced := FSConfigAtomicMoveReplace(StagePath, BoundPath, &NativeError, FinalAdmission)
		}
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
	}

	PublishedSource := FSReadWithStatus(BoundPath)
	if PublishedSource["status"] != "ok" || PublishedSource["content"] !== Content {
		try LoggerError("WrapSymbols", "The durable wrap-symbol source did not match its candidate; reload before retrying.")
		return false
	}

	; Only the memory projection is atomic. Disk is already durable and the
	; global owner still prevents any sibling writer or terminal transition.
	Published := false
	PublishError := ""
	PreviousCritical := Critical("On")
	try {
		try {
			; Durability is already acknowledged. A later pause cannot revoke
			; this memory projection, but a replacement source owner still can.
			if _WS_SourceReceiptCurrent(ExpectedSource, BoundPath)
					&& _ConfigWriteLeaseKey(_WS_Config_Path) == _ConfigWriteLeaseKey(BoundPath) {
				_WS_BindSourceReceipt(CustomCandidate, DisabledCandidate, BoundPath, PublishedSource)
				Published := _WS_PublishCandidate(DisabledCandidate,
					CustomCandidate, ActiveCandidate, StartEpoch)
			}
		}
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
