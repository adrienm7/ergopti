; platform/remap/tap_hold_loader.ahk

; ==============================================================================
; MODULE: Tap-Hold Loader
; DESCRIPTION:
; Loads tap-hold configuration into a hierarchical Map. Supports an optional
; defaults overlay: when ``DefaultsFilePath`` is supplied, the shared
; ``_shared/tap_hold/defaults.toml`` is parsed first, then the user file is
; merged on top — user values win, absent user keys inherit the default. This
; means editing ``defaults.toml`` takes effect on every reload even when the
; user file exists, satisfying the cross-driver consistency goal.
;
; FEATURES & RATIONALE:
; 1. Single-pass TOML parser tailored to the tap_hold schema — supports the
;    ``[tap_hold]`` root flag and ``[tap_hold.keys.<id>]`` sections only. The
;    full TOML grammar is intentionally NOT supported here: this is a narrow
;    file format produced by the codegen pipeline. What a held layer DOES is
;    not tap-hold data: it lives in layers.toml (platform/remap/layers_loader.ahk).
; 2. Returns a hierarchical Map with the shape:
;        TapHold["keys"]["caps_lock"]["tap_action"]        = "enter"
;        TapHold["keys"]["caps_lock"]["hold_modifier"]     = "ctrl"
;        TapHold["keys"]["caps_lock"]["time_activation_seconds"] = 0.35
; 3. Runtime overlay: when DefaultsFilePath is given, defaults are loaded
;    first and user values are merged on top. Absent user keys inherit the
;    default so ``time_activation_seconds`` changes in defaults.toml take
;    effect without requiring a user-file edit.
; 4. Backward-compatible: callers that omit DefaultsFilePath behave exactly
;    as before — only the user file is parsed.
; ==============================================================================

; Default per-key tap-hold activation threshold in seconds, used when a key has
; no time_activation_seconds (e.g. a tap-only override under inherit_defaults =
; false). Single source for the former 0.2 literal that TapHoldDuration used to
; duplicate across its two return branches
global TAPHOLD_DEFAULT_ACTIVATION_SECONDS := 0.2
; Upper sanity bound for a hold threshold read from the user-editable
; tap_hold.toml. A hold longer than this is certainly a typo (a stray unit, a
; misplaced decimal point) rather than an intent, and the value is concatenated
; straight into a KeyWait timeout — so anything past it is rejected at the
; loader boundary instead of stalling a hotkey thread for minutes.
global TAPHOLD_MAX_ACTIVATION_SECONDS := 10
; The other spellings of a hold modifier (altgr, lctrl...), read here, at this
; file's include position, and never from a #HotIf: those are live before the
; auto-execute section runs, during Bundle_Init's message-pumping RunWait, and
; the hold resolvers they call must not read a file (hotif-globals-boot-safe).
global TAPHOLD_HOLD_MODIFIER_ALIASES := _TapHoldReadHoldModifierAliases()
; The one-shot Shift results, read at the first one-shot (_TapHoldOneShotTable):
; json.ahk is included after this file, so they cannot be read here.
global _TapHoldOneShotCache := ""





; =====================================
; =====================================
; ======= 1. Public entry point =======
; =====================================
; =====================================

; Read ``FilePath`` (user config) and return the hierarchical TapHold Map.
; When ``DefaultsFilePath`` is supplied the shared defaults are loaded first
; and the user file is merged on top — user values take precedence, absent
; user keys inherit the default value.
; On missing or unreadable user file the defaults (if provided) are returned
; as-is so a fresh install still gets working defaults after first boot.
LoadTapHoldToml(FilePath, DefaultsFilePath := "") {
	try LoggerDebug("TapHoldLoader", "LoadTapHoldToml start: user='{1}', defaults='{2}'.", FilePath, DefaultsFilePath)
	Result := Map("keys", Map())
	InheritDefaults := false

	; Parse the user file once into UserData. Extract inherit_defaults from
	; the result so we do not need a second pre-flight read of the same file.
	; The data is later merged on top of the defaults overlay so the final
	; order is still: defaults → user (user wins per-key).
	UserData := Map("keys", Map())
	if FileExist(FilePath)
		_TapHold_ParseFileInto(FilePath, UserData)
	else
		try LoggerDebug("TapHoldLoader", "No user tap-hold file found yet at '{1}'.", FilePath)

	if UserData.Has("inherit_defaults") {
		InheritDefaults := !!UserData["inherit_defaults"]
		; Carry the flag into the map we RETURN, not only into this local. The
		; writer gates its ``[tap_hold]`` emit on Data.Has("inherit_defaults")
		; (tap_hold_writer.ahk), and it serializes the live TapHold global — so a
		; loader that keeps the flag to itself makes the opt-out a one-way trip:
		; the next individual tray write drops the line and the following reload
		; re-merges every shipped default, undoing « Tout désactiver ».
		Result["inherit_defaults"] := InheritDefaults
	}

	try LoggerDebug("TapHoldLoader", "Parsed user tap-hold: {1} key(s), inherit_defaults={2}.",
		UserData["keys"].Count, InheritDefaults)

	; Load shared defaults first when the caller supplies the path. Missing
	; defaults file is non-fatal (logs a debug notice and continues).
	if (DefaultsFilePath != "" and InheritDefaults) {
		if FileExist(DefaultsFilePath) {
			try LoggerDebug("TapHoldLoader", "Loading tap-hold defaults from '{1}'…", DefaultsFilePath)
			_TapHold_ParseFileInto(DefaultsFilePath, Result)
		} else {
			try LoggerDebug("TapHoldLoader", "Shared defaults not found at '{1}' — skipping.", DefaultsFilePath)
		}
	} else if (DefaultsFilePath != "" and !InheritDefaults) {
		try LoggerDebug("TapHoldLoader", "Skipping shared defaults load because inherit_defaults=false in user tap-hold file.")
	}

	if !FileExist(FilePath) {
		try LoggerDebug("TapHoldLoader", "tap_hold.toml not found at '{1}' — skipping.", FilePath)
		try LoggerSuccess("TapHoldLoader", "Tap-hold config loaded ({1} key(s)) — defaults only.",
			Result["keys"].Count)
		return Result
	}
	try LoggerStart("TapHoldLoader", "Loading tap-hold config from '{1}'…", FilePath)

	; Merge user data (already parsed above) on top of defaults.
	; Per-key fields overwrite default fields individually so a user entry
	; that sets only tap_action still inherits time_activation_seconds from
	; the default for that key.
	; NOTE: must iterate field-by-field, NOT assign the whole user Map, or the
	; defaults-populated Map for that key is replaced entirely and inherited
	; fields (e.g. time_activation_seconds) are lost.
	for k, v in UserData["keys"] {
		if !Result["keys"].Has(k)
			Result["keys"][k] := Map()
		; hold_modifier / hold_layer are mutually exclusive: evict the opposite
		; field that may have come from the defaults overlay.
		if v.Has("hold_modifier") and Result["keys"][k].Has("hold_layer")
			Result["keys"][k].Delete("hold_layer")
		else if v.Has("hold_layer") and Result["keys"][k].Has("hold_modifier")
			Result["keys"][k].Delete("hold_modifier")
		for field, val in v
			Result["keys"][k][field] := val
	}

	if UserData["keys"].Has("left_ctrl") {
		try LoggerDebug("TapHoldLoader", "User override includes left_ctrl: tap_action='{1}', hold_modifier='{2}', hold_layer='{3}'.",
			UserData["keys"]["left_ctrl"].Has("tap_action") ? (UserData["keys"]["left_ctrl"]["tap_action"] == "" ? "<native>" : UserData["keys"]["left_ctrl"]["tap_action"]) : "<unset>",
			UserData["keys"]["left_ctrl"].Has("hold_modifier") ? UserData["keys"]["left_ctrl"]["hold_modifier"] : "<unset>",
			UserData["keys"]["left_ctrl"].Has("hold_layer") ? UserData["keys"]["left_ctrl"]["hold_layer"] : "<unset>")
	}
	if Result["keys"].Has("left_ctrl") {
		LCfg := Result["keys"]["left_ctrl"]
		try LoggerDebug("TapHoldLoader", "Resolved left_ctrl after merge: tap_action='{1}', hold_modifier='{2}', hold_layer='{3}', inherit_defaults={4}.",
			LCfg.Has("tap_action") ? (LCfg["tap_action"] == "" ? "<native>" : LCfg["tap_action"]) : "<unset>",
			LCfg.Has("hold_modifier") ? LCfg["hold_modifier"] : "<unset>",
			LCfg.Has("hold_layer") ? LCfg["hold_layer"] : "<unset>",
			InheritDefaults ? "true" : "false")
	}

	; Truncated-write sentinel: the user file exists yet the merged config has
	; zero keys AND the user did NOT explicitly opt out via inherit_defaults =
	; false. The only legitimate way to reach an empty keys map is the explicit
	; opt-out (« Tout desactiver »), so an empty config here most likely means a
	; crash/power loss truncated the file mid-write. Surface it loudly instead
	; of silently leaving every tap-hold disabled.
	if (Result["keys"].Count == 0 and InheritDefaults) {
		try LoggerWarn("TapHoldLoader", "tap_hold.toml at '{1}' exists but parsed to 0 key(s) without inherit_defaults=false — possible truncated/corrupt write.",
			FilePath)
	}

	; A user file that EXISTS but could not be READ is not an empty one. The
	; defaults overlay above fills ``keys`` with the shipped mappings, so the
	; truncated-write sentinel cannot fire and the map is indistinguishable from
	; a user who customised nothing. Say so at ERROR rather than asserting a load
	; that never happened — _TH_WriteTapHoldToml consults the same sentinel and
	; refuses to rewrite the file from this map.
	if TOML_UnreadableFile(FilePath) {
		try LoggerError("TapHoldLoader", "Cannot read '{1}': the tap-hold config in memory is the shipped defaults, not the user's. Writes are blocked until the file is readable again.",
			FilePath)
	} else {
		try LoggerSuccess("TapHoldLoader", "Tap-hold config loaded ({1} key(s)).",
			Result["keys"].Count)
	}
	return Result
}





; ========================================
; ========================================
; ======= 2. Internal parse helper =======
; ========================================
; ========================================

; Parse ``FilePath`` and merge its key/value pairs into ``Result`` in-place.
; Existing entries are overwritten field-by-field so a user file that only
; specifies some fields of a key still inherits the rest from a prior pass.
_TapHold_ParseFileInto(FilePath, Result) {
	; Reuse the admitted semantic reader: root dotted assignments, quoted
	; headers and inline key tables must reload the same values the writer owns.
	try Document := TOML_ParseDocument(ReadTomlFile(FilePath), &Records)
	catch as Err {
		try LoggerError("TapHoldLoader", "Cannot read the tap-hold document '{1}': {2}.", FilePath, Err.Message)
		return
	}
	if !Document.Has("tap_hold")
		return
	Root := Document["tap_hold"]
	if !(Root is Map) {
		try LoggerError("TapHoldLoader", "The tap_hold source namespace must be a table.")
		return
	}
	if Root.Has("inherit_defaults") {
		if Root["inherit_defaults"] is TOML_Bool
			Result["inherit_defaults"] := !!Root["inherit_defaults"].Value
		else
			try LoggerError("TapHoldLoader", "Field '[tap_hold].inherit_defaults' must be a TOML boolean; value rejected.")
	}
	if !Root.Has("keys")
		return
	if !(Root["keys"] is Map) {
		try LoggerError("TapHoldLoader", "The tap_hold.keys source namespace must be a table.")
		return
	}
	InvalidKeys := Map()
	for KeyId, Entry in Root["keys"] {
		if !(KeyId is String) || !RegExMatch(KeyId, "^[A-Za-z0-9_]+$")
			continue
		CurrentPath := "tap_hold.keys." . KeyId
		if !(Entry is Map) {
			try LoggerError("TapHoldLoader", "Field '[{1}]' must be a key table; key disabled.", CurrentPath)
			InvalidKeys[KeyId] := true
			continue
		}
		for Key, Typed in Entry {
			LiteralKind := _TOML_ValueKind(Typed)
			if LiteralKind == "string" && !_TapHold_FieldStringIsQuoted(Records, KeyId, Key)
				LiteralKind := "unknown"
			Value := _ConfigTomlNativeValue(Typed)
			ExpectedKind := TapHoldFieldKinds().Get(Key, "")
			; A field no tap-hold key has (an older build's, a hand edit's) is an
			; outdated entry, not a schema violation of the key: warned, ignored,
			; and the rest of the key still applies (the maintainer's
			; outdated-entry rule, as on Linux). A known field of the wrong type
			; still disables its key below (AHK-134).
			if (ExpectedKind == "") {
				ConfigOutdatedReportInFile(FilePath, CurrentPath . "." . Key,
					"no tap-hold key has this field",
					(Message, Args*) => LoggerWarn("TapHoldLoader", Message, Args*))
				continue
			}
			if (LiteralKind != ExpectedKind) {
				try LoggerError("TapHoldLoader",
					"Field '[{1}].{2}' violates tap-hold schema type '{3}'; key disabled.",
					CurrentPath, Key, ExpectedKind)
				InvalidKeys[KeyId] := true
				continue
			}
			; Every hold-layer variant tests only for a non-empty hold_layer, so any
			; other name, a typo included, would hold the navigation layer. Refuse
			; it here; the entry keeps its tap and holds nothing, stored as the
			; hold picker's own "none" (hold_modifier = ""), which also evicts a
			; default hold below: the user chose a layer, not that default.
			if (Key == "hold_layer" and Value != "" and !_TapHoldLayerIsKnown(Value)) {
				try LoggerError("TapHoldLoader",
					"Unknown hold_layer '{1}' for tap-hold key '{2}' in [tap_hold.keys.{2}]; its hold is dropped and its tap kept (expected one of {3}).",
					Value, KeyId, _TapHoldKnownLayersLabel())
				Key := "hold_modifier"
				Value := ""
			}
			if !Result["keys"].Has(KeyId) {
				Result["keys"][KeyId] := Map()
			}
			; hold_modifier and hold_layer are mutually exclusive: writing one
			; must evict the other so a defaults entry with hold_layer is not
			; left in place when the user file overrides with hold_modifier,
			; which would make IsTapHoldVariantActive match both variants.
			if (Key == "hold_modifier") and Result["keys"][KeyId].Has("hold_layer") {
				Result["keys"][KeyId].Delete("hold_layer")
			} else if (Key == "hold_layer") and Result["keys"][KeyId].Has("hold_modifier") {
				Result["keys"][KeyId].Delete("hold_modifier")
			}
			; Every hold-modifier variant tests only for a non-empty hold_modifier,
			; so a value that names no modifier armed the hold branch with nothing
			; to hold and swallowed the key, tap included. Refuse it here, as the
			; Linux loader does: the entry holds the picker's "none" and keeps its
			; tap, and the user's choice still replaces a default hold.
			if (Key == "hold_modifier" and Value != "" and !_TapHoldHoldModifierIsKnown(Value)) {
				try LoggerError("TapHoldLoader",
					"Unknown hold_modifier '{1}' for tap-hold key '{2}' in [tap_hold.keys.{2}]; its hold is dropped and its tap kept (expected ctrl, shift, alt, alt_gr or win, or an alias of the hold picker).",
					Value, KeyId)
				Value := ""
			}
			Result["keys"][KeyId][Key] := Value
			continue
		}
	}
	for KeyId, _ in InvalidKeys {
		if !Result["keys"].Has(KeyId)
			Result["keys"][KeyId] := Map()
		Result["keys"][KeyId]["enabled"] := false
	}
}
; The generic semantic reader preserves legacy bare strings for unowned data.
; Known Tap-Hold strings retain their existing quoted-literal admission policy.
_TapHold_FieldStringIsQuoted(Records, KeyId, Field) {
	Parts := ["tap_hold", "keys", KeyId, Field]
	try {
		for Record in Records {
			if Record.Path.Length > Parts.Length
				continue
			Matches := true
			for Index, Part in Record.Path {
				if !(Part == Parts[Index]) {
					Matches := false
					break
				}
			}
			if !Matches
				continue
			Raw := Record.Value is Map ? _ConfigTomlRawTree(Record.Value, Record.Raw) : Record.Raw
			loop Parts.Length - Record.Path.Length {
				if !(Raw is Map) || !Raw.Has(Parts[Record.Path.Length + A_Index])
					return false
				Raw := Raw[Parts[Record.Path.Length + A_Index]]
			}
			if !(Raw is String)
				return false
			Raw := Trim(Raw, " " . Chr(9) . Chr(13) . Chr(10))
			First := SubStr(Raw, 1, 1)
			return StrLen(Raw) >= 2 && (First == Chr(34) || First == Chr(39))
				&& SubStr(Raw, -1) == First
		}
	} catch {
		return false
	}
	return false
}






; ========================================
; ========================================
; ======= 3. Convenience accessors =======
; ========================================
; ========================================

; Whether LayerId is a hold layer the hold picker offers; the shared
; [tap_hold.hold_picker].layers list is the single source of layer ids.
_TapHoldLayerIsKnown(LayerId) {
	for _, Known in _TH_ReadHoldPickerArray("layers") {
		if (Known == LayerId)
			return true
	}
	return false
}

; The known hold layers, for a log line.
_TapHoldKnownLayersLabel() {
	Label := ""
	for _, Known in _TH_ReadHoldPickerArray("layers")
		Label .= (Label == "" ? "" : ", ") . Known
	return Label == "" ? "<none>" : Label
}

; Return true when an entry has no tap action, maps the key to itself, or names
; an action in the live gesture catalogue. The loader runs before the catalogue
; is initialized, so defer the registry check until its runtime accessors run.
TapHoldEntryHasKnownAction(Entry, KeyId) {
	global GESTURE_ACTIONS
	if !(Entry.Has("tap_action") && Entry["tap_action"] is String)
		return true
	if (Entry["tap_action"] == KeyId)
		return true
	if !IsSet(GESTURE_ACTIONS)
		return false
	return GESTURE_ACTIONS.Has(Entry["tap_action"])
}

; Return true only when ``KeyId`` exists, names a live tap action, and its
; optional schema-level ``enabled`` flag is a real enabled value. Missing means
; enabled by default, matching tap_hold.schema.json. Keep this gate shared by
; every accessor: several #HotIf expressions call the action/modifier/layer
; accessors directly instead of consulting TapHoldIsConfigured first.
TapHoldIsEnabled(TapHold, KeyId) {
	if !(TapHold.Has("keys") and TapHold["keys"].Has(KeyId))
		return false
	Entry := TapHold["keys"][KeyId]
	if !TapHoldEntryHasKnownAction(Entry, KeyId)
		return false
	if !Entry.Has("enabled")
		return true
	Enabled := Entry["enabled"]
	return Enabled is Integer && Enabled == 1
}

; Return true when the key ``KeyId`` has a configured tap_action OR hold_layer
; OR hold_modifier — i.e. when the tap-hold for this key should be armed.
TapHoldIsConfigured(TapHold, KeyId) {
	if !(TapHold.Has("keys") and TapHold["keys"].Has(KeyId)) {
		return false
	}
	Entry := TapHold["keys"][KeyId]
	return Entry.Has("tap_action") or Entry.Has("hold_layer") or Entry.Has("hold_modifier")
}

; Runtime hotkey predicate. Keep it distinct from "configured" so the menu and
; shared corpus can still report a disabled entry's stored configuration.
TapHoldIsActive(TapHold, KeyId) {
	return TapHoldIsEnabled(TapHold, KeyId)
		&& TapHoldIsConfigured(TapHold, KeyId)
}

; Return the configured tap action for ``KeyId`` (a string) or "" if
; absent. Callers compare to known action ids ("enter", "tab", "backspace"…)
; to decide which Send() to emit.
TapHoldTapAction(TapHold, KeyId) {
	if !TapHoldIsEnabled(TapHold, KeyId) {
		return ""
	}
	Entry := TapHold["keys"][KeyId]
	return Entry.Has("tap_action") ? Entry["tap_action"] : ""
}

; Return the hold-time threshold for ``KeyId`` in seconds, falling back to the
; single-sourced TAPHOLD_DEFAULT_ACTIVATION_SECONDS when the key is unconfigured
; or declares no ``time_activation_seconds``.
TapHoldDuration(TapHold, KeyId) {
	if !TapHoldIsEnabled(TapHold, KeyId) {
		return TAPHOLD_DEFAULT_ACTIVATION_SECONDS
	}
	Entry := TapHold["keys"][KeyId]
	if !Entry.Has("time_activation_seconds")
		return TAPHOLD_DEFAULT_ACTIVATION_SECONDS
	Raw := Entry["time_activation_seconds"]
	; Validate at the boundary (fail fast, copilot-instructions 5.3). This value
	; comes verbatim from the user-editable tap_hold.toml and is concatenated into
	; a KeyWait option string ("T" . value) at ~11 call sites. A non-numeric entry
	; produced "Tabc", and KeyWait then THREW on the hook thread — after
	; TapHoldSyntheticKeyDown had already armed a synthetic modifier and before its
	; release, which is what made the modifier-latch window reachable at all. The
	; throw was absorbed by the global error net, so the user only saw a tap-hold
	; that intermittently did nothing, never a config error.
	if (!IsNumber(Raw) or Raw <= 0 or Raw > TAPHOLD_MAX_ACTIVATION_SECONDS) {
		try LoggerWarn("TapHoldLoader",
			"Invalid time_activation_seconds '{1}' for tap-hold key '{2}' — falling back to {3}s.",
			Raw, KeyId, TAPHOLD_DEFAULT_ACTIVATION_SECONDS)
		return TAPHOLD_DEFAULT_ACTIVATION_SECONDS
	}
	return Raw
}

; Return the configured hold modifier for ``KeyId`` (e.g. "ctrl", "shift",
; "alt", "alt_gr") or "" if the variant doesn't activate a modifier on
; hold (e.g. plain tap-only variants like CapsLock-BackSpace or LAlt-BackSpace
; key-repeat where the held key simply repeats the tap action).
TapHoldHoldModifier(TapHold, KeyId) {
	if !TapHoldIsEnabled(TapHold, KeyId) {
		return ""
	}
	Entry := TapHold["keys"][KeyId]
	return Entry.Has("hold_modifier") ? Entry["hold_modifier"] : ""
}

; Return the configured hold layer for ``KeyId`` (e.g. "nav") or "" if
; the variant doesn't activate a remap layer on hold. Used to distinguish
; Layer-on-hold variants from modifier-on-hold variants (e.g. LAlt-BackSpace
; vs LAlt-BackSpaceLayer share tap_action "backspace" but only the latter
; arms the navigation layer).
TapHoldHoldLayer(TapHold, KeyId) {
	if !TapHoldIsEnabled(TapHold, KeyId) {
		return ""
	}
	Entry := TapHold["keys"][KeyId]
	return Entry.Has("hold_layer") ? Entry["hold_layer"] : ""
}





; ===========================================
; ===========================================
; ======= 4. Hold-modifier resolution =======
; ===========================================
; ===========================================

; AHK key name of a generic modifier token held by tap-hold key KeyId. Only the
; right-side modifier keys differ from the left-side default: they hold their
; own side, which is what lets their identity gates pass the physical key
; through. A function-local static keeps the table readable from a #HotIf that
; may be evaluated before this file's include position runs.
; @param KeyId {String} Tap-hold key id, e.g. "right_ctrl".
; @param Token {String} One of "ctrl", "shift", "alt", "win".
; @returns {String} The AHK key name to hold.
_TapHoldOwnSideModifier(KeyId, Token) {
	static OwnSide := Map(
		"right_ctrl", Map("ctrl", "RCtrl"),
		"right_shift", Map("shift", "RShift"))
	static LeftSide := Map("ctrl", "LCtrl", "shift", "LShift", "alt", "LAlt", "win", "LWin")
	if (OwnSide.Has(KeyId) && OwnSide[KeyId].Has(Token))
		return OwnSide[KeyId][Token]
	return LeftSide[Token]
}

; The other spellings of a hold modifier (altgr, lctrl...), from the two alias
; tables of [tap_hold.hold_picker] in the shared defaults. The Linux loader
; reads the same tables (_shared/lua/tap_hold/hold_options.lua): they were two
; hand-kept lists, here as case labels, that agreed only by care. Called once,
; for TAPHOLD_HOLD_MODIFIER_ALIASES; a table the file cannot give is logged
; there, once, and its spellings are refused.
; @returns {Map} "modifier_aliases" and "left_modifier_aliases", each a Map of
;          lower-case alias -> modifier id.
_TapHoldReadHoldModifierAliases() {
	global _SharedDir
	Path := _SharedDir . "\tap_hold\defaults.toml"
	Sections := ParseTomlFile(Path)
	Picker := Sections.Has("tap_hold.hold_picker") ? Sections["tap_hold.hold_picker"] : Map()
	Tables := Map()
	for Name in ["modifier_aliases", "left_modifier_aliases"] {
		Table := Picker.Has(Name) ? Picker[Name] : ""
		Aliases := Map()
		if (Table is Map) {
			for Alias, Id in Table
				Aliases[StrLower(Alias)] := Id
		} else {
			try LoggerError("TapHoldLoader", "'{1}' declares no [tap_hold.hold_picker] {2} — those spellings of a hold are refused.",
				Path, Name)
		}
		Tables[Name] := Aliases
	}
	return Tables
}

; The modifiers a hold_modifier value names. "ctrl", "Ctrl + Shift", "AltGr"
; and "lctrl" are read without regard to case, with "+" or blanks between the
; modifiers, and through the aliases of the shared hold picker.
; @param ModifierValue {String} Raw hold_modifier value.
; @param Invalid {VarRef} Receives the tokens that name no modifier.
; @returns {Array} One [Id, LeftAlias] pair per modifier: its hold-picker id,
;          and whether a left_ alias ("lctrl") named it.
_TapHoldHoldModifierParts(ModifierValue, &Invalid) {
	global TAPHOLD_HOLD_MODIFIER_ALIASES
	Invalid := []
	if !IsSet(TAPHOLD_HOLD_MODIFIER_ALIASES) {
		; Only a #HotIf evaluated before this file's include position ran gets
		; here, while TapHold is still the empty boot seed: say so, resolve none.
		try LoggerError("TapHoldLoader", "Hold modifier '{1}' read before the hold aliases were loaded.",
			ModifierValue)
		Invalid.Push(ModifierValue)
		return []
	}
	Normalized := StrReplace(Trim(String(ModifierValue)), " ", "+")
	while (InStr(Normalized, "++") > 0)
		Normalized := StrReplace(Normalized, "++", "+")
	Parts := []
	for _, Token in StrSplit(Trim(Normalized, "+"), "+") {
		Lower := StrLower(Trim(Token))
		if (Lower == "")
			continue
		if TAPHOLD_HOLD_MODIFIER_ALIASES["left_modifier_aliases"].Has(Lower) {
			Parts.Push([TAPHOLD_HOLD_MODIFIER_ALIASES["left_modifier_aliases"][Lower], true])
			continue
		}
		Id := TAPHOLD_HOLD_MODIFIER_ALIASES["modifier_aliases"].Get(Lower, Lower)
		switch Id {
			case "ctrl", "shift", "alt", "win", "alt_gr":
				Parts.Push([Id, false])
			default:
				Invalid.Push(Token)
		}
	}
	return Parts
}

; Whether a hold_modifier value names at least one modifier and nothing else.
; @param ModifierValue {String}
; @returns {Boolean}
_TapHoldHoldModifierIsKnown(ModifierValue) {
	Parts := _TapHoldHoldModifierParts(ModifierValue, &Invalid)
	return Invalid.Length == 0 && Parts.Length > 0
}

; Central hold_modifier -> AHK key-name resolver shared by every tap-holds
; module's per-key XxxHoldModKey() wrapper. Centralizing the switch means a
; typo'd hold_modifier value (e.g. "contrl") is caught and logged in exactly
; one place instead of silently degrading to an empty ModKey in 9 separate
; copies of this switch, each fed unguarded into TextPressKey. The loader
; already refuses such a value (_TapHold_ParseFileInto), since it would pass
; the #HotIf non-empty gates; this is the last line for a map built otherwise.
; A generic token ("ctrl", "shift", ...) names the key's OWN side when the
; tap-hold key is that very modifier, so right_ctrl + "ctrl" is RCtrl and the
; identity gates can pass the physical key through. Any other key keeps the
; left-side default: left_shift + "ctrl" is LCtrl, never LShift. The left_
; aliases of the shared hold picker ("lctrl", "lshift", ...) always name the
; left key.
; @param ModifierValue {String} Raw hold_modifier value, typically read via
;        TapHoldHoldModifier(TapHold, FieldLabel).
; @param FieldLabel {String} The tap-hold key id (e.g. "backspace"): selects
;        the key's own modifier side and names the tap_hold.toml row in logs.
; @returns {String|Array} An AHK key name, or array of AHK key names for
;        hold modifier combinations, or "" when ModifierValue is invalid.
ResolveHoldModifierKey(ModifierValue, FieldLabel) {
	if (Trim(String(ModifierValue)) == "") {
		return ""
	}

	Parts := _TapHoldHoldModifierParts(ModifierValue, &Invalid)
	if (Invalid.Length > 0) {
		try LoggerWarn("TapHoldLoader", "Unrecognized hold_modifier '{1}' for tap-hold key '{2}' — check tap_hold.toml for a typo; no modifier will be armed (expected one of ctrl/shift/alt/alt_gr/win).",
			ModifierValue, FieldLabel)
		return ""
	}
	if (Parts.Length == 0) {
		try LoggerWarn("TapHoldLoader", "No recognized hold_modifier in '{1}' for tap-hold key '{2}'.",
			ModifierValue, FieldLabel)
		return ""
	}
	Resolved := []
	for _, Part in Parts {
		if (Part[1] == "alt_gr")
			Resolved.Push(KS_AltGrKeyName())
		else ; A left_ alias names the left key even on right_ctrl or right_shift.
			Resolved.Push(_TapHoldOwnSideModifier(Part[2] ? "" : FieldLabel, Part[1]))
	}
	if (Resolved.Length == 1) {
		try LoggerDebug("TapHoldLoader", "Resolved hold_modifier '{1}' for tap-hold key '{2}' as '{3}'.",
			ModifierValue, FieldLabel, Resolved[1])
		return Resolved[1]
	}

	Label := ""
    for _, ResolvedModifier in Resolved {
        Label .= (Label == "" ? "" : ",") . ResolvedModifier
	}
	try LoggerDebug("TapHoldLoader", "Resolved hold_modifier '{1}' for tap-hold key '{2}' as [{3}].",
		ModifierValue, FieldLabel, Label)
	return Resolved
}




; =========================================
; =========================================
; ======= 5. One-shot Shift results =======
; =========================================
; =========================================

; What the one-shot Shift makes of the next character, read once from
; _shared/tap_hold/one_shot_shift.json, which the Linux driver reads too. The
; results were an if/else chain in one_shot_shift.ahk, so Linux had none of
; them. A file that cannot be read is logged once and the failure kept: the
; one-shot only capitalises until the next start, rather than reading the file
; again, and logging again, at every tap.
; @returns {Map} "results" -> Map(character -> result) and "magic_key_result";
;          both empty when the file cannot be read.
_TapHoldOneShotTable() {
	global _SharedDir, _TapHoldOneShotCache
	if (_TapHoldOneShotCache is Map)
		return _TapHoldOneShotCache
	Path := (IsSet(_SharedDir) ? _SharedDir : "") . "\tap_hold\one_shot_shift.json"
	try {
		Root := JsonParse(FileRead(Path, "UTF-8"))
		Results := Map()
		for Entry in Root["results"]
			Results[Entry["char"]] := Entry["result"]
		Table := Map("results", Results, "magic_key_result", Root["magic_key_result"])
	} catch as Err {
		try LoggerError("TapHoldLoader", "Cannot read the one-shot Shift results from '{1}': {2} — the one-shot only capitalises until the next start.",
			Path, Err.Message)
		Table := Map("results", Map(), "magic_key_result", "")
	}
	_TapHoldOneShotCache := Table
	return Table
}

; The result the one-shot Shift types for the character typed after it, or ""
; when it has none and the character is typed in title case.
; @param EndKey {String} The character typed after the one-shot Shift.
; @param MagicKey {String} The magic key's character.
; @returns {String}
TapHoldOneShotResult(EndKey, MagicKey) {
	Table := _TapHoldOneShotTable()
	; The magic key is the user's choice: it keeps its meaning on a character
	; the table has a result for (the old chain checked it before "," "'" " ").
	if (MagicKey != "" && EndKey == MagicKey)
		return Table["magic_key_result"]
	if Table["results"].Has(EndKey)
		return Table["results"][EndKey]
	return ""
}

; The characters that end the one-shot Shift's InputHook: every one that has a
; result, and the magic key.
; @param MagicKey {String} The magic key's character.
; @returns {String}
TapHoldOneShotEndKeys(MagicKey) {
	Keys := ""
	for Char in _TapHoldOneShotTable()["results"]
		Keys .= Char
	return Keys . MagicKey
}

/** Returns the per-key fields consumed by the tap-hold loader and preset owner. */
TapHoldFieldKinds() {
	return Map("enabled", "boolean", "time_activation_seconds", "number",
		"tap_action", "string", "hold_modifier", "string", "hold_layer", "string")
}
