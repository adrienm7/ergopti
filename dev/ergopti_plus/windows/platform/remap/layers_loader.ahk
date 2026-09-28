; platform/remap/layers_loader.ahk

; ==============================================================================
; MODULE: Keymap Layers — AutoHotkey Loader
; DESCRIPTION:
; Reads a layer file — Ergopti's _shared/keymap/layers.recommended.toml or the
; user's layers.toml in the configuration folder — at run time, validates it
; against the physical-key registry (_shared/data/keycodes/physical_keys.json)
; and the layer vocabulary (_shared/keymap/layer_actions.toml), and resolves
; every binding for one OS. Nothing is generated or compiled: the driver reads
; the same data files the macOS and Linux drivers read through
; _shared/lua/keymap/layers.lua, and _shared/tests/corpus/keymap_layers/
; vectors.json holds all three loaders (and tools/lib/keymap-layers.cjs) to one
; answer.
;
; FEATURES & RATIONALE:
; 1. A strict reader for the layer-file format. The shared TOML helper is
;    deliberately lenient (it skips what it cannot read), which is right for
;    config.toml and wrong here: a skipped line in a layer file is a key that
;    silently stops working. This reader takes tables, strings, integers,
;    floats and booleans, and rejects anything else — a duplicate key or table
;    included — as toml_invalid, which is what the Lua and JS parsers answer.
;    Arrays, inline tables, dotted keys, multi-line strings, control
;    characters and integers beyond 15 digits are not part of the layer-file
;    format (layer_actions.toml, "File format"); the Lua and JS loaders check
;    the same rules before their TOML parsers run, so all three reject them.
; 2. Errors are data: each is a Map of code, layer, section, key, detail and
;    reason_key (absent parts ""), with the codes the corpus asserts. A
;    file-level problem rejects the whole file; an entry-level problem drops
;    that entry and is reported.
; 3. Shipped data fails fast: a registry or vocabulary that cannot be read, or
;    lacks a field the loader uses, throws instead of loading an empty layer.
; 4. An OS entry replaces the `all` entry for its key even when the OS entry
;    is the invalid one: a rejected override never falls back to `all`.
; ==============================================================================

#Requires AutoHotkey v2.0

global KEYMAP_LAYERS_SECTION_ALL := "all"
; Joins the parts of a TOML path in the duplicate ledger. A quoted TOML key may
; contain a dot, so the dot cannot be the separator.
global KEYMAP_LAYERS_PATH_SEPARATOR := Chr(31)
global KEYMAP_LAYERS_ID_PATTERN := "^[a-z][a-z0-9_]*$"
; Every control character but tab. A carriage return is allowed only as the
; first half of a CRLF line end, which the reader removes before this check.
global KEYMAP_LAYERS_CONTROL_PATTERN := "[\x{00}-\x{08}\x{0A}-\x{1F}\x{7F}]"
; The most digits every loader holds exactly: JS numbers are exact to 2^53,
; and Integer() wraps a longer integer round (2^64 + 1 reads as 1).
global KEYMAP_LAYERS_MAX_INTEGER_DIGITS := 15





; ==========================
; ==========================
; ======= 1/ Context =======
; ==========================
; ==========================

/**
 * Reads the shipped registry and vocabulary under the _shared root.
 * @param {string} SharedDir - Absolute path of the _shared folder.
 * @returns {Map} The loader context every other function takes.
 * @throws When either file is missing, unreadable or lacks a field the loader reads.
 */
KeymapLayers_LoadContext(SharedDir) {
	if !(SharedDir is String) || SharedDir == ""
		throw ValueError("KeymapLayers_LoadContext needs the _shared folder path.", -1)
	Root := RTrim(SharedDir, "\/")
	RegistryPath := Root . "\data\keycodes\physical_keys.json"
	; FileRead throws on a missing or locked file, which is the answer we want
	; for shipped data.
	Registry := JsonParse(FSReadStrict(RegistryPath))
	return KeymapLayers_NewContext(Registry, _KL_ReadVocabulary(Root))
}

/**
 * Where the user's layer file lives, read from the vocabulary alone. Decoding
 * the registry is the costly half of the context (about 160 ms on AutoHotkey):
 * a caller that finds no file there has nothing to resolve against it.
 * @param {string} SharedDir - Absolute path of the _shared folder.
 * @param {string} ConfigDir - The configuration folder.
 * @returns {string} The path of the user's layer file.
 * @throws When the vocabulary is missing, unreadable or names no user file.
 */
KeymapLayers_UserFilePathFromVocabulary(SharedDir, ConfigDir) {
	if !(SharedDir is String) || SharedDir == ""
		throw ValueError("KeymapLayers_UserFilePathFromVocabulary needs the _shared folder path.", -1)
	Meta := _KL_RequireSection(_KL_ReadVocabulary(RTrim(SharedDir, "\/")), "_meta")
	if !Meta.Has("user_file") || !(Meta["user_file"] is String) || Meta["user_file"] == ""
		throw Error("The layer vocabulary names no user file ([_meta].user_file).", -1)
	return RTrim(ConfigDir, "\/") . "\" . Meta["user_file"]
}

; The vocabulary's sections, as the shared TOML helper returns them; throws when
; the shipped file is missing or unreadable.
_KL_ReadVocabulary(Root) {
	VocabularyPath := Root . "\keymap\layer_actions.toml"
	if !FileExist(VocabularyPath)
		throw Error("The layer vocabulary is missing at '" . VocabularyPath . "'.", -2)
	Sections := TOML_ParseFreshFile(VocabularyPath)
	if TOML_ReadFailed(VocabularyPath)
		throw Error("The layer vocabulary at '" . VocabularyPath . "' could not be read.", -2)
	return Sections
}

/**
 * Builds the loader context from the decoded registry and the vocabulary's
 * sections (as the shared TOML helper returns them: section name -> Map).
 * @param {Map} Registry - Decoded physical_keys.json.
 * @param {Map} Sections - layer_actions.toml, section by section.
 * @returns {Map} The loader context.
 */
KeymapLayers_NewContext(Registry, Sections) {
	if !(Registry is Map) || !Registry.Has("keys") || !(Registry["keys"] is Map)
		throw Error("The physical-key registry has no keys table.", -1)
	Meta := _KL_RequireSection(Sections, "_meta")
	for Field in ["platforms", "modifier_order"] {
		if !Meta.Has(Field) || !(Meta[Field] is Array) || Meta[Field].Length == 0
			throw Error("The layer vocabulary has no [_meta]." . Field . ".", -1)
	}
	if !Meta.Has("layers_schema_version") || !(Meta["layers_schema_version"] is Integer)
			|| !Meta.Has("user_file") || !(Meta["user_file"] is String) || Meta["user_file"] == ""
		throw Error("The layer vocabulary lacks layers_schema_version or user_file.", -1)
	Primary := _KL_RequireSection(Sections, "primary_modifier")
	Handlers := _KL_RequireSection(Sections, "call_handlers")
	RepeatCount := _KL_RequireSection(Sections, "parameters.repeat_count")
	if !RepeatCount.Has("min") || !(RepeatCount["min"] is Integer) || !RepeatCount.Has("max")
			|| !(RepeatCount["max"] is Integer) || !RepeatCount.Has("platforms") || !(RepeatCount["platforms"] is Array)
		throw Error("The layer vocabulary has no usable [parameters.repeat_count].", -1)
	for Os in Meta["platforms"] {
		if !Primary.Has(Os) || !_KL_ListHas(Meta["modifier_order"], Primary[Os])
			throw Error("The layer vocabulary has no primary modifier for " . Os . ".", -1)
		if !Handlers.Has(Os) || !(Handlers[Os] is Array)
			throw Error("The layer vocabulary has no call-handler list for " . Os . ".", -1)
	}
	Actions := Map()
	Restricted := Map()
	SourceKinds := Map()
	for Name, Section in Sections {
		if (SubStr(Name, 1, 8) == "actions.")
			Actions[SubStr(Name, 9)] := Section
		else if (SubStr(Name, 1, 10) == "modifiers.")
			Restricted[SubStr(Name, 11)] := Section
		else if (SubStr(Name, 1, 13) == "source_kinds.")
			SourceKinds[SubStr(Name, 14)] := Section
	}
	if (Actions.Count == 0)
		throw Error("The layer vocabulary declares no action.", -1)
	for Modifier, Rule in Restricted {
		if !Rule.Has("platforms") || !(Rule["platforms"] is Array)
			throw Error("The layer vocabulary's [modifiers." . Modifier . "] has no platforms list.", -1)
	}
	for Kind, Rule in SourceKinds {
		if !Rule.Has("platforms") || !(Rule["platforms"] is Array)
			throw Error("The layer vocabulary's [source_kinds." . Kind . "] has no platforms list.", -1)
	}
	return Map(
		"keys", Registry["keys"],
		"platforms", Meta["platforms"],
		"modifier_order", Meta["modifier_order"],
		"schema_version", Meta["layers_schema_version"],
		"user_file", Meta["user_file"],
		"primary", Primary,
		"call_handlers", Handlers,
		"repeat_count", RepeatCount,
		"restricted_modifiers", Restricted,
		"source_kinds", SourceKinds,
		"actions", Actions
	)
}

/**
 * @param {Map} Ctx - The loader context.
 * @param {string} ConfigDir - The configuration folder.
 * @returns {string} Where the user's layer file lives.
 */
KeymapLayers_UserFilePath(Ctx, ConfigDir) {
	return RTrim(ConfigDir, "\/") . "\" . Ctx["user_file"]
}





; =======================================
; =======================================
; ======= 2/ Loading a layer file =======
; =======================================
; =======================================

/**
 * Loads a layer file for one OS.
 * @param {string} Os - windows | macos | linux.
 * @param {Map} Ctx - From KeymapLayers_LoadContext / KeymapLayers_NewContext.
 * @param {string} Text - The file content; omit it when the file is absent.
 * @returns {Map} ok (Boolean), errors (Array of error Maps), layers (layer id -> key code -> resolution Map).
 */
KeymapLayers_Load(Os, Ctx, Text?) {
	global KEYMAP_LAYERS_ID_PATTERN
	if !_KL_ListHas(Ctx["platforms"], Os)
		throw ValueError("Unknown OS '" . Os . "' for a keymap layer.", -1)
	Result := Map("ok", true, "errors", [], "layers", Map())
	if !IsSet(Text)
		return Result
	try {
		Doc := _KL_ParseToml(Text)
	} catch as Err {
		return _KL_Reject(Result, _KL_Error("toml_invalid", "", "", "", Err.Message))
	}
	if (Doc.Count == 0)
		return Result
	if !Doc.Has("_meta") || !(Doc["_meta"] is Map) || !Doc["_meta"].Has("schema_version")
		return _KL_Reject(Result, _KL_Error("schema_version_missing", "", "", "", "[_meta].schema_version is required"))
	Meta := Doc["_meta"]
	Version := Meta["schema_version"]
	if !(Version is Number) || Version != Ctx["schema_version"]
		return _KL_Reject(Result, _KL_Error("schema_version_unsupported", "", "", "",
			"schema_version " . _KL_Describe(Version) . " is not " . Ctx["schema_version"]))
	for Key in Meta {
		if (Key !== "schema_version")
			_KL_Report(Result, _KL_Error("unknown_field", "", "_meta", Key, "[_meta]." . Key . " is not a field"))
	}
	for Key in Doc {
		if (Key !== "_meta" && Key !== "layers")
			_KL_Report(Result, _KL_Error("unknown_field", "", "", Key, "top-level '" . Key . "' is not a field"))
	}
	if !Doc.Has("layers")
		return Result
	if !(Doc["layers"] is Map)
		return _KL_Reject(Result, _KL_Error("invalid_value_type", "", "", "layers", "'layers' must be a table"))
	for LayerId, Layer in Doc["layers"] {
		if !RegExMatch(LayerId, KEYMAP_LAYERS_ID_PATTERN)
			_KL_Report(Result, _KL_Error("invalid_layer_id", LayerId, "", "", "layer id '" . LayerId . "' must be snake_case"))
		else if !(Layer is Map)
			_KL_Report(Result, _KL_Error("invalid_value_type", LayerId, "", "", "a layer must be a table"))
		else
			Result["layers"][LayerId] := _KL_LoadLayer(Result, LayerId, Layer, Os, Ctx)
	}
	return Result
}

/**
 * Loads the user's layers.toml from the configuration folder. An absent file is
 * an empty layer set, never an error; an unreadable one is.
 * @returns {Map} As KeymapLayers_Load, plus path.
 */
KeymapLayers_LoadUserFile(Ctx, ConfigDir, Os := "windows") {
	Path := KeymapLayers_UserFilePath(Ctx, ConfigDir)
	if !FileExist(Path) {
		Result := KeymapLayers_Load(Os, Ctx)
	} else {
		try {
			Text := FSReadStrict(Path)
		} catch as Err {
			Result := _KL_Reject(Map("ok", true, "errors", [], "layers", Map()),
				_KL_Error("file_unreadable", "", "", "", Err.Message))
			Result["path"] := Path
			return Result
		}
		Result := KeymapLayers_Load(Os, Ctx, Text)
	}
	Result["path"] := Path
	return Result
}

; Validates the sections of one layer and resolves its effective bindings.
_KL_LoadLayer(Result, LayerId, Layer, Os, Ctx) {
	global KEYMAP_LAYERS_SECTION_ALL
	Sections := [KEYMAP_LAYERS_SECTION_ALL]
	for Platform in Ctx["platforms"]
		Sections.Push(Platform)
	Parsed := Map()
	for Section, Table in Layer {
		if !_KL_ListHas(Sections, Section) {
			_KL_Report(Result, _KL_Error("unknown_layer_section", LayerId, Section, "",
				"'" . Section . "' is not a layer section"))
			continue
		}
		if !(Table is Map) {
			_KL_Report(Result, _KL_Error("invalid_value_type", LayerId, Section, "", "a layer section must be a table"))
			continue
		}
		Parsed[Section] := Map()
		for Code, Value in Table {
			if !Ctx["keys"].Has(Code) {
				_KL_Report(Result, _KL_Error("unknown_key", LayerId, Section, Code,
					"'" . Code . "' is not in the physical-key registry"))
				continue
			}
			Binding := _KL_ParseBinding(Value, Ctx, &ErrCode, &Detail)
			if (Binding is Map)
				Parsed[Section][Code] := Binding
			else
				_KL_Report(Result, _KL_Error(ErrCode, LayerId, Section, Code, Detail))
		}
	}
	; The OS entry replaces the `all` entry for its key, even when the OS entry
	; is the invalid one: a rejected override must not quietly fall back.
	Effective := Map()
	for Section in [KEYMAP_LAYERS_SECTION_ALL, Os] {
		if !Layer.Has(Section) || !(Layer[Section] is Map)
			continue
		for Code in Layer[Section] {
			Binding := (Parsed.Has(Section) && Parsed[Section].Has(Code)) ? Parsed[Section][Code] : ""
			Effective[Code] := Map("section", Section, "binding", Binding)
		}
	}
	Out := Map()
	for Code, Entry in Effective {
		if !(Entry["binding"] is Map)
			continue
		Unavailable := _KL_SourceUnavailable(Code, Os, Ctx)
		Resolved := (Unavailable is Map) ? "" : _KL_ResolveBinding(Entry["binding"], Os, Ctx, &Unavailable)
		if (Resolved is Map)
			Out[Code] := Resolved
		else
			_KL_Report(Result, _KL_Error("unavailable_on_os", LayerId, Entry["section"], Code,
				Unavailable["detail"], Unavailable["reason_key"]))
	}
	return Out
}





; ==================================
; ==================================
; ======= 3/ Binding grammar =======
; ==================================
; ==================================

; Parses one binding value. Syntax only; availability on an OS comes later.
; Returns the binding Map, or "" with ErrCode and Detail set.
_KL_ParseBinding(Value, Ctx, &ErrCode, &Detail) {
	global KEYMAP_LAYERS_ID_PATTERN, KEYMAP_LAYERS_MAX_INTEGER_DIGITS
	ErrCode := "", Detail := ""
	if !(Value is String) {
		ErrCode := "invalid_value_type", Detail := "a binding must be a string"
		return ""
	}
	Colon := InStr(Value, ":")
	if !Colon {
		if !RegExMatch(Value, KEYMAP_LAYERS_ID_PATTERN) || !Ctx["actions"].Has(Value) {
			ErrCode := "unknown_action", Detail := "'" . Value . "' is not a layer action"
			return ""
		}
		return Map("type", "action", "id", Value)
	}
	Head := SubStr(Value, 1, Colon - 1)
	Rest := SubStr(Value, Colon + 1)
	if (Head == "repeat_count") {
		Param := Ctx["repeat_count"]
		; Integer() wraps a number beyond 64 bits round into range, so a count
		; too long to hold is refused by its length before it is converted.
		if !RegExMatch(Rest, "^[0-9]+$") || StrLen(LTrim(Rest, "0")) > KEYMAP_LAYERS_MAX_INTEGER_DIGITS
				|| Integer(Rest) < Param["min"] || Integer(Rest) > Param["max"] {
			ErrCode := "invalid_parameter"
			Detail := "repeat_count takes an integer from " . Param["min"] . " to " . Param["max"]
			return ""
		}
		return Map("type", "repeat_count", "count", Integer(Rest))
	}
	if (Head == "keystroke") {
		Chords := _KL_ParseChords(Rest, Ctx, &Problem)
		if !(Chords is Array) {
			ErrCode := "invalid_keystroke", Detail := Problem
			return ""
		}
		return Map("type", "keystroke", "chords", Chords)
	}
	ErrCode := "unknown_action", Detail := "'" . Head . ":' is not a binding form"
	return ""
}

; Parses `mod+…+Key[,mod+…+Key…]` into chords of raw modifiers, or returns ""
; with Problem set. StrSplit keeps empty fields, so "a,,b" is an empty chord.
_KL_ParseChords(Text, Ctx, &Problem) {
	Problem := ""
	Chords := []
	; StrSplit of "" is an empty Array, not one empty field: say so explicitly.
	if (Text == "") {
		Problem := "empty chord in ''"
		return ""
	}
	for Part in StrSplit(Text, ",") {
		Tokens := StrSplit(Part, "+")
		Key := Tokens.Length ? Tokens.Pop() : ""
		if (Key == "") {
			Problem := "empty chord in '" . Text . "'"
			return ""
		}
		if !Ctx["keys"].Has(Key) || Ctx["keys"][Key]["kind"] !== "key" {
			Problem := "'" . Key . "' is not a keyboard key in the physical-key registry"
			return ""
		}
		Seen := Map()
		for Modifier in Tokens {
			if (Modifier !== "primary" && !_KL_ListHas(Ctx["modifier_order"], Modifier)) {
				Problem := "unknown modifier '" . Modifier . "'"
				return ""
			}
			if Seen.Has(Modifier) {
				Problem := "modifier '" . Modifier . "' named twice"
				return ""
			}
			Seen[Modifier] := true
		}
		Chords.Push(Map("mods", Tokens, "key", Key))
	}
	return Chords
}

; Resolves raw modifiers for one OS, in modifier_order. Returns the chords, or
; "" with Unavailable set when a modifier does not exist on the OS.
_KL_ResolveChords(Chords, Os, Ctx, &Unavailable) {
	Unavailable := ""
	Out := []
	for Chord in Chords {
		Mods := Map()
		for Raw in Chord["mods"] {
			Modifier := (Raw == "primary") ? Ctx["primary"][Os] : Raw
			if Ctx["restricted_modifiers"].Has(Modifier) {
				Rule := Ctx["restricted_modifiers"][Modifier]
				if !_KL_ListHas(Rule["platforms"], Os) {
					Unavailable := Map("detail", "modifier '" . Modifier . "' does not exist on " . Os,
						"reason_key", Rule.Get("reason_key", ""))
					return ""
				}
			}
			Mods[Modifier] := true
		}
		Ordered := []
		for Modifier in Ctx["modifier_order"] {
			if Mods.Has(Modifier)
				Ordered.Push(Modifier)
		}
		Out.Push(Map("mods", Ordered, "key", Chord["key"]))
	}
	return Out
}

; Parses a vocabulary resolution (keystroke:/call:/none). Throws on shipped
; data the vocabulary gate should have rejected.
_KL_ParseResolution(Text, Os, Ctx) {
	if (Text == "none")
		return Map("kind", "none")
	if (SubStr(Text, 1, 5) == "call:") {
		Handler := SubStr(Text, 6)
		if !_KL_ListHas(Ctx["call_handlers"][Os], Handler)
			throw Error("Vocabulary resolution call:" . Handler . " is not declared for " . Os . ".", -1)
		return Map("kind", "call", "handler", Handler)
	}
	if (SubStr(Text, 1, 10) == "keystroke:") {
		Chords := _KL_ParseChords(SubStr(Text, 11), Ctx, &Problem)
		if !(Chords is Array)
			throw Error("Vocabulary resolution '" . Text . "': " . Problem, -1)
		return Map("kind", "keystroke", "chords", Chords)
	}
	throw Error("Vocabulary resolution '" . Text . "' is not keystroke:, call: or none.", -1)
}

; Says why a physical input cannot be a layer key on one OS: a Map of detail
; and reason_key, or "" when it can.
_KL_SourceUnavailable(Code, Os, Ctx) {
	Kind := Ctx["keys"][Code]["kind"]
	if !Ctx["source_kinds"].Has(Kind)
		return ""
	Rule := Ctx["source_kinds"][Kind]
	if _KL_ListHas(Rule["platforms"], Os)
		return ""
	return Map("detail", "a " . Kind . " input cannot be a layer key on " . Os,
		"reason_key", Rule.Get("reason_key", ""))
}

; Resolves one syntactically valid binding on one OS. Returns the resolution,
; or "" with Unavailable set (detail, reason_key) when it cannot run there.
_KL_ResolveBinding(Binding, Os, Ctx, &Unavailable) {
	global KEYMAP_LAYERS_SECTION_ALL
	Unavailable := ""
	if (Binding["type"] == "repeat_count") {
		Param := Ctx["repeat_count"]
		if !_KL_ListHas(Param["platforms"], Os) {
			Unavailable := Map("detail", "repeat_count does not exist on " . Os, "reason_key", Param.Get("reason_key", ""))
			return ""
		}
		return Map("kind", "repeat_count", "count", Binding["count"])
	}
	if (Binding["type"] == "keystroke") {
		Chords := _KL_ResolveChords(Binding["chords"], Os, Ctx, &Unavailable)
		if !(Chords is Array)
			return ""
		return Map("kind", "keystroke", "chords", Chords, "repeatable", false, "action", "")
	}
	Action := Ctx["actions"][Binding["id"]]
	if Action.Has(Os)
		Text := Action[Os]
	else if Action.Has(KEYMAP_LAYERS_SECTION_ALL)
		Text := Action[KEYMAP_LAYERS_SECTION_ALL]
	else {
		Unavailable := Map("detail", "action '" . Binding["id"] . "' has no resolution on " . Os,
			"reason_key", Action.Get("reason_key", ""))
		return ""
	}
	Res := _KL_ParseResolution(Text, Os, Ctx)
	if (Res["kind"] == "keystroke") {
		Chords := _KL_ResolveChords(Res["chords"], Os, Ctx, &VocabularyUnavailable)
		if !(Chords is Array)
			throw Error("Vocabulary action '" . Binding["id"] . "' uses an unavailable modifier on " . Os . ".", -1)
		Res["chords"] := Chords
	}
	; The shared TOML helper reads `true` as 1; anything else is not repeatable.
	Res["repeatable"] := (Res["kind"] !== "none") && Action.Has("repeatable") && Action["repeatable"] == true
	Res["action"] := Binding["id"]
	return Res
}





; ====================================
; ====================================
; ======= 4/ Layer-file reader =======
; ====================================
; ====================================

; Parses the layer-file subset of TOML into nested Maps. Throws a ValueError
; naming the line on anything outside the subset or on a redefinition.
_KL_ParseToml(Text) {
	global KEYMAP_LAYERS_PATH_SEPARATOR, KEYMAP_LAYERS_CONTROL_PATTERN
	if (SubStr(Text, 1, 1) == Chr(0xFEFF))
		Text := SubStr(Text, 2)
	Root := Map()
	; path -> "table" (defined by a header), "implicit" (a header's parent) or "value"
	Kinds := Map()
	Current := Root
	CurrentPath := ""
	loop parse, Text, "`n" {
		LineNo := A_Index
		Line := A_LoopField
		; A CRLF line end is one line end; any other carriage return is a
		; control character.
		if (SubStr(Line, -1) == "`r")
			Line := SubStr(Line, 1, -1)
		if RegExMatch(Line, KEYMAP_LAYERS_CONTROL_PATTERN)
			throw ValueError("line " . LineNo . ": control characters other than tab are not allowed")
		Line := Trim(Line, " `t")
		if (Line == "" || SubStr(Line, 1, 1) == "#")
			continue
		if (SubStr(Line, 1, 1) == "[") {
			if (SubStr(Line, 1, 2) == "[[")
				throw ValueError("line " . LineNo . ": arrays of tables are not part of the layer-file format")
			if !RegExMatch(Line, "^\[[ \t]*([A-Za-z0-9_-]+(?:[ \t]*\.[ \t]*[A-Za-z0-9_-]+)*)[ \t]*\][ \t]*(?:#.*)?$", &Header)
				throw ValueError("line " . LineNo . ": malformed table header")
			Segments := []
			for Segment in StrSplit(Header[1], ".")
				Segments.Push(Trim(Segment, " `t"))
			Current := _KL_OpenTable(Root, Kinds, Segments, LineNo)
			CurrentPath := ""
			for Segment in Segments
				CurrentPath .= (A_Index == 1 ? "" : KEYMAP_LAYERS_PATH_SEPARATOR) . Segment
			continue
		}
		if RegExMatch(Line, "^([A-Za-z0-9_-]+)[ \t]*=[ \t]*(.*)$", &Pair)
			Key := Pair[1]
		else if RegExMatch(Line, '^"((?:[^"\\]|\\.)*)"[ \t]*=[ \t]*(.*)$', &Pair)
			Key := _KL_UnescapeBasic(Pair[1], LineNo)
		else if RegExMatch(Line, "^'([^']*)'[ \t]*=[ \t]*(.*)$", &Pair)
			Key := Pair[1]
		else
			throw ValueError("line " . LineNo . ": expected a table header or a key = value pair")
		Value := _KL_ParseValue(Pair[2], LineNo)
		Path := (CurrentPath == "") ? Key : CurrentPath . KEYMAP_LAYERS_PATH_SEPARATOR . Key
		if Kinds.Has(Path)
			throw ValueError("line " . LineNo . ": '" . Key . "' is defined twice")
		Kinds[Path] := "value"
		Current[Key] := Value
	}
	return Root
}

; Walks or creates the tables of one header and returns the last one.
_KL_OpenTable(Root, Kinds, Segments, LineNo) {
	global KEYMAP_LAYERS_PATH_SEPARATOR
	Node := Root
	Path := ""
	for Index, Segment in Segments {
		Path .= (Index == 1 ? "" : KEYMAP_LAYERS_PATH_SEPARATOR) . Segment
		Kind := Kinds.Get(Path, "")
		if (Kind == "value")
			throw ValueError("line " . LineNo . ": '" . Segment . "' is already a value, not a table")
		if (Index == Segments.Length) {
			if (Kind == "table")
				throw ValueError("line " . LineNo . ": this table is defined twice")
			Kinds[Path] := "table"
		} else if (Kind == "") {
			Kinds[Path] := "implicit"
		}
		if !Node.Has(Segment)
			Node[Segment] := Map()
		Node := Node[Segment]
	}
	return Node
}

; Parses the value after `=`: a basic or literal string, a boolean, an integer
; or a float, with an optional trailing comment.
_KL_ParseValue(Rest, LineNo) {
	global KEYMAP_LAYERS_MAX_INTEGER_DIGITS
	if RegExMatch(Rest, '^"((?:[^"\\]|\\.)*)"[ \t]*(?:#.*)?$', &Match)
		return _KL_UnescapeBasic(Match[1], LineNo)
	if RegExMatch(Rest, "^'([^']*)'[ \t]*(?:#.*)?$", &Match)
		return Match[1]
	if RegExMatch(Rest, "^(true|false)[ \t]*(?:#.*)?$", &Match)
		return TOML_Bool(Match[1] == "true")
	; An integer is read as an integer or not at all: it never falls through
	; to the float form, whatever its length.
	if RegExMatch(Rest, "^([+-]?)(0|[1-9](?:_?[0-9])*)[ \t]*(?:#.*)?$", &Match) {
		Digits := StrReplace(Match[2], "_")
		if (StrLen(Digits) > KEYMAP_LAYERS_MAX_INTEGER_DIGITS)
			throw ValueError("line " . LineNo . ": an integer has at most " . KEYMAP_LAYERS_MAX_INTEGER_DIGITS . " digits")
		return Integer(Match[1] . Digits)
	}
	if RegExMatch(Rest, "^([+-]?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)[ \t]*(?:#.*)?$", &Match)
		return Float(Match[1])
	throw ValueError("line " . LineNo . ": unsupported value (a layer file holds strings, integers, floats and booleans)")
}

; TOML knows exactly these escapes; any other backslash sequence is invalid TOML.
_KL_UnescapeBasic(Raw, LineNo) {
	if !RegExMatch(Raw, '^(?:[^\\]|\\[btnfr"\\]|\\u[0-9A-Fa-f]{4}|\\U[0-9A-Fa-f]{8})*$')
		throw ValueError("line " . LineNo . ": invalid escape sequence in a string")
	try {
		return TOML_UnescapeBasicStringContents(Raw)
	} catch as Err {
		throw ValueError("line " . LineNo . ": " . Err.Message)
	}
}





; ======================================
; ======================================
; ======= 5/ Results and helpers =======
; ======================================
; ======================================

/**
 * The canonical text form of one resolution, shared with the Lua and JS
 * loaders: keystroke:ctrl+shift+Home, keystroke:End,Enter@repeat,
 * call:maximize_window, repeat_count:3, none.
 * @param {Map} R - A resolution.
 * @returns {string}
 */
KeymapLayers_FormatResolution(R) {
	if (R["kind"] == "none")
		return "none"
	if (R["kind"] == "repeat_count")
		return "repeat_count:" . R["count"]
	Suffix := R["repeatable"] ? "@repeat" : ""
	if (R["kind"] == "call")
		return "call:" . R["handler"] . Suffix
	Parts := ""
	for Chord in R["chords"] {
		Tokens := ""
		for Modifier in Chord["mods"]
			Tokens .= Modifier . "+"
		Parts .= (A_Index == 1 ? "" : ",") . Tokens . Chord["key"]
	}
	return "keystroke:" . Parts . Suffix
}

/**
 * The comparable identity of one error: code|layer|section|key|reason_key.
 * The detail text is for humans and is not compared.
 * @param {Map} E - An error Map.
 * @returns {string}
 */
KeymapLayers_ErrorSignature(E) {
	return E["code"] . "|" . E["layer"] . "|" . E["section"] . "|" . E["key"] . "|" . E["reason_key"]
}

_KL_Error(Code, Layer, Section, Key, Detail, ReasonKey := "") {
	return Map("code", Code, "layer", Layer, "section", Section, "key", Key,
		"detail", Detail, "reason_key", ReasonKey)
}

_KL_Report(Result, Err) {
	Result["errors"].Push(Err)
	Result["ok"] := false
}

_KL_Reject(Result, Err) {
	_KL_Report(Result, Err)
	Result["layers"] := Map()
	return Result
}

_KL_RequireSection(Sections, Name) {
	if !Sections.Has(Name) || !(Sections[Name] is Map)
		throw Error("The layer vocabulary has no [" . Name . "] section.", -1)
	return Sections[Name]
}

_KL_ListHas(List, Value) {
	for Item in List {
		if (Item == Value)
			return true
	}
	return false
}

_KL_Describe(Value) {
	if (Value is String || Value is Number)
		return String(Value)
	return Type(Value)
}
