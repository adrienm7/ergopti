; ui/onboarding/answers.ahk

; ==============================================================================
; MODULE: Onboarding / Answers Contract
; DESCRIPTION:
; The Windows side of the one contract between the first-run wizard page and
; its hosts, mirroring _shared/lua/onboarding_answers.lua: the generated
; catalogue (_shared/ui/_generated/onboarding_catalogue.json) names the manifest
; paths the wizard may write on Windows, and this module turns the page's
; finish payload into the rows of one atomic config.toml batch and the
; tap-hold keys to import, and a configuration back into the values a re-run
; starts from.
;
; FEATURES & RATIONALE:
; 1. No interpretation: every answer is a manifest path and a value. The host
;    never translates a question into keys of its own. A tap-hold key is the
;    one answer that is no configuration path: tap_hold.toml holds the keys, so
;    the catalogue names the key and the tap-hold writer imports its preset.
; 2. Fail-closed validation: a path outside the catalogue, a value the row
;    cannot take, a duplicate or a malformed payload refuses the whole batch
;    before anything is written.
; 3. Neutral values are deletions: ManifestSparseOperation decides, so a
;    declined feature leaves the file as empty as a fresh one.
; 4. AHK's JSON reader has no Boolean type. The catalogue generator refuses
;    numeric answers, so an Integer read from the catalogue or the payload is
;    always a Boolean here.
; ==============================================================================

; The catalogue format this module reads; the generator emits the same number.
global ONBOARDING_CATALOGUE_SCHEMA_VERSION := 1
; This driver's platform key in the catalogue.
global ONBOARDING_CATALOGUE_DRIVER := "windows"
; The catalogue index, loaded by its first use ("" until then).
global _OnboardingCatalogue := ""





; ==================================
; ==================================
; ======= 1/ Catalogue index =======
; ==================================
; ==================================

; The wizard catalogue of this driver, read once from the generated file.
; Throws when it is missing or malformed: nothing can be asked or validated.
; @returns {Map} Index from OnboardingCatalogueIndex.
OnboardingCatalogue() {
	global _OnboardingCatalogue, _SharedDir
	if (_OnboardingCatalogue is Map)
		return _OnboardingCatalogue
	Path := _SharedDir . "\ui\_generated\onboarding_catalogue.json"
	_OnboardingCatalogue := OnboardingCatalogueIndex(FileRead(Path, "UTF-8"))
	return _OnboardingCatalogue
}

; Indexes the paths the wizard may write on Windows.
; @param Text string The catalogue JSON.
; @returns {Map} "pages" (Array) and "entries" (Map path -> entry Map with
;   "kind" switch|choice|tap_hold_key|character, "default", and "value" or
;   "max_characters"; a tap_hold_key entry also names its "key" and the
;   "customised" value a configured key of the user's reads as).
OnboardingCatalogueIndex(Text) {
	global ONBOARDING_CATALOGUE_SCHEMA_VERSION, ONBOARDING_CATALOGUE_DRIVER
	Catalogue := JsonParse(Text)
	if !(Catalogue is Map) || Catalogue.Get("schema_version", "") != ONBOARDING_CATALOGUE_SCHEMA_VERSION
		throw ValueError("the onboarding catalogue has an unsupported format")
	Platforms := Catalogue.Get("platforms", "")
	Platform := (Platforms is Map) ? Platforms.Get(ONBOARDING_CATALOGUE_DRIVER, "") : ""
	if !(Platform is Map) || !(Platform.Get("pages", "") is Array)
		throw ValueError("the onboarding catalogue has no pages for " . ONBOARDING_CATALOGUE_DRIVER)
	Entries := Map()
	for Page in Platform["pages"] {
		if !(Page is Map)
			throw ValueError("the onboarding catalogue has a malformed page")
		if Page.Has("master")
			_OnboardingClaim(Entries, Page["master"], "switch")
		; The Shortcuts answer also writes the key-combinations switch, which its
		; master no longer reaches.
		if Page.Has("sub_switch")
			_OnboardingClaim(Entries, Page["sub_switch"], "switch")
		if Page.Has("magic_key")
			_OnboardingClaim(Entries, Page["magic_key"], "character")
		_OnboardingClaimGroups(Entries, Page.Get("groups", []))
	}
	return Map("pages", Platform["pages"], "entries", Entries)
}

; Claims every file gate and item of a checklist tree.
; @param Entries Map Index being built.
; @param Groups Array Catalogue groups.
_OnboardingClaimGroups(Entries, Groups) {
	if !(Groups is Array)
		throw ValueError("the onboarding catalogue has a malformed checklist")
	for Group in Groups {
		if !(Group is Map)
			throw ValueError("the onboarding catalogue has a malformed checklist group")
		if Group.Has("path")
			_OnboardingClaim(Entries, Group, "choice")
		for Item in Group.Get("items", [])
			_OnboardingClaim(Entries, Item,
				(Item is Map) && Item.Has("tap_hold_key") ? "tap_hold_key" : "choice")
		_OnboardingClaimGroups(Entries, Group.Get("groups", []))
	}
}

; Records one writable path, refusing a second row for it.
; @param Entries Map Index being built.
; @param Row Map Catalogue row.
; @param Kind string switch, choice, tap_hold_key or character.
_OnboardingClaim(Entries, Row, Kind) {
	Path := (Row is Map) ? Row.Get("path", "") : ""
	if !(Path is String) || Path == ""
		throw ValueError("the onboarding catalogue has an unnamed row")
	if Entries.Has(Path)
		throw ValueError("the onboarding catalogue writes " . Path . " twice")
	Entry := Map("kind", Kind, "default", (Kind == "switch") ? false : Row["default"])
	if (Kind == "choice" || Kind == "tap_hold_key")
		Entry["value"] := Row["value"]
	if (Kind == "tap_hold_key") {
		Key := Row["tap_hold_key"]
		Customised := Row.Get("customised_value", "")
		if !(Key is String) || Key == "" || !(Customised is String) || Customised == ""
			throw ValueError("the onboarding catalogue names a tap-hold key without an id or a customised value")
		Entry["key"] := Key
		Entry["customised"] := Customised
	}
	if (Kind == "character") {
		Limit := Row.Get("max_characters", 0)
		if !(Limit is Integer) || Limit < 1
			throw ValueError("the onboarding catalogue gives the trigger character no length limit")
		Entry["max_characters"] := Limit
	}
	Entries[Path] := Entry
}





; =================================
; =================================
; ======= 2/ Finish payload =======
; =================================
; =================================

; Turns the page's operations into configuration rows.
; @param Index Map From OnboardingCatalogueIndex.
; @param Operations any The payload's "operations" value.
; @returns {Array|String} Rows { Section, Key, Value | Delete } for the TOML
;   writer, or why the whole batch was refused.
OnboardingAnswerRows(Index, Operations) {
	Answers := _OnboardingSplitAnswers(Index, Operations)
	return (Answers is Map) ? Answers["rows"] : Answers
}

; The tap-hold keys the answers import: every checked key of the Tap-Holds
; page, in answer order, for the tap-hold writer. The whole payload is
; validated as OnboardingAnswerRows validates it.
; @param Index Map From OnboardingCatalogueIndex.
; @param Operations any The payload's "operations" value.
; @returns {Array|String} Key ids (empty when nothing is imported), or why the
;   whole batch was refused.
OnboardingTapHoldKeys(Index, Operations) {
	Answers := _OnboardingSplitAnswers(Index, Operations)
	return (Answers is Map) ? Answers["tap_hold_keys"] : Answers
}

; Validates the page's operations as a whole and splits them between their
; owners: configuration rows for the TOML writer, checked tap-hold keys for
; the tap-hold writer.
; @param Index Map From OnboardingCatalogueIndex.
; @param Operations any The payload's "operations" value.
; @returns {Map|String} "rows" and "tap_hold_keys", or why the whole batch was
;   refused.
_OnboardingSplitAnswers(Index, Operations) {
	if !(Operations is Array)
		return "the answers carry no operations"
	Rows := []
	Keys := []
	Seen := Map()
	for Position, Operation in Operations {
		if !(Operation is Map) || !Operation.Has("path") || !Operation.Has("value")
			return "operation " . Position . " is not a path and a value"
		Path := Operation["path"]
		if !(Path is String) || !Index["entries"].Has(Path)
			return "operation " . Position . " names no wizard path"
		if Seen.Has(Path)
			return Path . " is answered twice"
		Seen[Path] := true
		Entry := Index["entries"][Path]
		Why := _OnboardingAnswerRefusal(Entry, Operation["value"])
		if (Why != "")
			return Path . ": " . Why
		if (Entry["kind"] == "tap_hold_key") {
			; An unchecked key keeps whatever it has: nothing is written for it.
			if _OnboardingSameAnswer(Operation["value"], Entry["value"])
				Keys.Push(Entry["key"])
			continue
		}
		try Row := ManifestSparseOperation(Path, Operation["value"])
		catch as Err
			return Path . " is not a configuration path of this driver: " . Err.Message
		Rows.Push(Row)
	}
	return Map("rows", Rows, "tap_hold_keys", Keys)
}

; Why a value cannot be written to an entry, or "" when it can.
; @param Entry Map Catalogue entry.
; @param Value any Decoded payload value.
; @returns {String}
_OnboardingAnswerRefusal(Entry, Value) {
	Kind := Entry["kind"]
	if (Kind == "switch")
		return _OnboardingIsBoolean(Value) ? "" : "a category switch takes true or false"
	if (Kind == "choice" || Kind == "tap_hold_key") {
		if _OnboardingSameAnswer(Value, Entry["value"]) || _OnboardingSameAnswer(Value, Entry["default"])
			return ""
		return "an imported item takes its recommendation or its neutral value"
	}
	if !(Value is String) || RegExMatch(Value, "^\s*$") || RegExMatch(Value, "[\x00-\x1F\x7F]")
		return "the trigger character must be visible text"
	if (_OnboardingCharacterCount(Value) > Entry["max_characters"])
		return "the trigger character is at most " . Entry["max_characters"] . " characters"
	return ""
}

; A Boolean as AHK's JSON reader hands it back.
_OnboardingIsBoolean(Value) => (Value is Integer) && (Value == 0 || Value == 1)

; Same type and same value; strings compare case-sensitively.
_OnboardingSameAnswer(Left, Right) => Type(Left) == Type(Right) && Left == Right

; Counts code points, so a character outside the BMP (two UTF-16 units) counts
; once, as the Lua hosts count UTF-8 characters.
; @param Text string
; @returns {Integer}
_OnboardingCharacterCount(Text) {
	Count := 0
	loop StrLen(Text) {
		Unit := NumGet(StrPtr(Text), (A_Index - 1) * 2, "UShort")
		if (Unit < 0xDC00 || Unit > 0xDFFF)
			Count += 1
	}
	return Count
}





; ==================================
; ==================================
; ======= 3/ Values in force =======
; ==================================
; ==================================

; The configured value of every wizard path a parsed config.toml sets; absent
; paths are left out so the page shows their neutral value.
; @param Index Map From OnboardingCatalogueIndex.
; @param Sections Map From TOML_ParseFreshFileTyped.
; @returns {Map} Path -> value (TOML_Bool for a Boolean literal).
OnboardingCurrentValues(Index, Sections) {
	Values := Map()
	for SectionPath, Keys in Sections {
		Prefix := (SectionPath == "") ? "" : TomlConfigManifestPath(SectionPath)
		if (Prefix == "")
			continue
		for Key, Value in Keys {
			; A tap-hold key lives in tap_hold.toml, never in config.toml.
			Path := Prefix . "." . Key
			if Index["entries"].Has(Path) && Index["entries"][Path]["kind"] != "tap_hold_key"
				Values[Path] := Value
		}
	}
	return Values
}

; The wizard values of the keys a tap_hold.toml configures: a key set to its
; recommendation reads as imported, any other setting as customised, which the
; page keeps as it is and never imports over.
; @param Index Map From OnboardingCatalogueIndex.
; @param Report Map Key id -> "recommended" or "customised", from TapHoldKeyReport.
; @returns {Map} Path -> value (TOML_Bool for an imported key).
OnboardingTapHoldValues(Index, Report) {
	Values := Map()
	for Path, Entry in Index["entries"] {
		if (Entry["kind"] != "tap_hold_key") || !Report.Has(Entry["key"])
			continue
		State := Report[Entry["key"]]
		if (State == "recommended")
			Values[Path] := TOML_Bool(Entry["value"])
		else if (State == "customised")
			Values[Path] := Entry["customised"]
		else
			throw ValueError("unknown tap-hold key state " . String(State))
	}
	return Values
}

; Reads the wizard values a config.toml holds and those of the tap_hold.toml
; beside it; absent files hold none.
; @param Index Map From OnboardingCatalogueIndex.
; @param ConfigPath string
; @returns {Map|String} The values, or why a file could not be read.
OnboardingReadCurrentValues(Index, ConfigPath) {
	global _SharedDir
	try LoggerStart("Onboarding", "Reading the wizard values of {1}…", ConfigPath)
	Values := Map()
	if FileExist(ConfigPath) {
		Sections := TOML_ParseFreshFileTyped(ConfigPath, &DiscardedArrays)
		if TOML_ReadFailed(ConfigPath) || DiscardedArrays {
			try LoggerError("Onboarding", "The configuration at {1} could not be read.", ConfigPath)
			return "the configuration at " . ConfigPath . " could not be read"
		}
		Values := OnboardingCurrentValues(Index, Sections)
	}
	TapHoldPath := TapHoldConfigPathBeside(ConfigPath)
	Report := TapHoldKeyReport(TapHoldPath, _SharedDir . "\tap_hold\defaults.toml")
	if (Report is String) {
		try LoggerError("Onboarding", "The tap-hold keys at {1} could not be read: {2}.", TapHoldPath, Report)
		return Report
	}
	for Path, Value in OnboardingTapHoldValues(Index, Report)
		Values[Path] := Value
	try LoggerSuccess("Onboarding", "Read {1} wizard value(s) from {2} and its tap-hold file.",
		Values.Count, ConfigPath)
	return Values
}

; The values as the JSON object the page's initData and applyCurrentValues read.
; @param Values Map From OnboardingCurrentValues.
; @returns {String}
OnboardingValuesJson(Values) {
	Out := ""
	for Path, Value in Values {
		if (Value is TOML_Bool)
			Literal := Value.Value ? "true" : "false"
		else if (Value is String)
			Literal := JsonStringLiteral(Value)
		else if (Value is Number)
			Literal := String(Value)
		else {
			try LoggerWarn("Onboarding", "{1} holds a value the wizard cannot show; its page starts neutral.", Path)
			continue
		}
		Out .= (Out == "" ? "" : ",") . JsonStringLiteral(Path) . ":" . Literal
	}
	return "{" . Out . "}"
}
