; modules/keystats/keystats_app_category_store.ahk

; ==============================================================================
; MODULE: App Category Store Codec
; DESCRIPTION:
; Reads and writes the document macOS and Linux share through
; _shared/lua/keystats/app_category_store.lua: { schema, version, apps } holding
; one { type, score } record per application, or the flat map of records it upgrades.
; A flat string entry is refused (see KLAppCatFlatFormError), and a member the
; codec does not know is dropped at the next save, as the shared codec does.
; ==============================================================================

; A store written in the old Windows form: refused, kept untouched, never migrated.
; The loader tells it apart from damage because the driver can classify without it.
class KLAppCatFlatFormError extends ValueError {
}

_KL_AppCat_JsonSource(Content) {
	return SubStr(Content, 1, 1) == Chr(0xFEFF) ? SubStr(Content, 2) : Content
}

_KL_AppCat_ScoreValid(Score) {
	return (Score is Integer || Score is Float)
		&& Score >= KLAppCatConst.MIN_SCORE && Score <= KLAppCatConst.MAX_SCORE
}

_KL_AppCat_LabelValid(Label) {
	return Label is String && Trim(Label, " `t`r`n") != ""
}

; The parser remains authoritative; original spans distinguish true from 1.
_KL_AppCat_DecodeStore(Content, Path := "") {
	Source := _KL_AppCat_JsonSource(Content)
	Document := JsonParse(Source)
	if !(Document is Map)
		throw TypeError("App categories require a JSON object.")
	Members := JsonObjectMemberSpans(Source)
	; Without this exact marker every member is an application, so an application
	; named "schema" stays a record, as in the shared codec.
	Versioned := Document.Has("schema") && Document["schema"] == KLAppCatConst.STORE_SCHEMA
	if Versioned {
		if !Document.Has("version") || !(Document["version"] is Integer)
			|| Document["version"] != KLAppCatConst.STORE_VERSION
			|| Trim(Members["version"]["text"]) != String(KLAppCatConst.STORE_VERSION)
			throw ValueError("Unsupported app category store version.")
		if !Document.Has("apps") || !(Document["apps"] is Map)
			throw TypeError("App category records require an apps object.")
		Apps := Document["apps"]
		AppMembers := JsonObjectMemberSpans(Source, ["apps"])
	} else {
		Apps := Document
		AppMembers := Members
	}
	Categories := Map(), OriginalKeys := Map()
	for Key, Value in Apps {
		if !(Key is String) || Key == ""
			throw TypeError("An app category key must be a nonempty process name.")
		CanonicalKey := StrLower(Key)
		if Categories.Has(CanonicalKey)
			throw ValueError("App category entries require distinct case-insensitive process names.")
		if Value is String
			throw KLAppCatFlatFormError("The entry of '" . Key . "' is a flat string, not a { type, score } record.")
		if !(Value is Map)
			throw TypeError("Invalid app category entry or unknown store schema.")
		Fields := JsonObjectMemberSpans(AppMembers[Key]["text"])
		if !Value.Has("type") || !_KL_AppCat_LabelValid(Value["type"])
			|| !Value.Has("score") || !_KL_AppCat_ScoreValid(Value["score"])
			|| !RegExMatch(Trim(Fields["score"]["text"]), "^[-0-9]")
			throw ValueError("An app category entry requires a label and a finite score between -2 and 2.")
		Categories[CanonicalKey] := Map("type", Value["type"], "score", Value["score"])
		OriginalKeys[CanonicalKey] := Key
	}
	return Map("path", Path, "source", Content, "versioned", Versioned, "refused", false,
		"categories", Categories, "original_keys", OriginalKeys)
}

; The admitted model of a store refused for its flat form: it holds no entry, and
; its mark stops every save until a reload admits the replaced file.
_KL_AppCat_RefusedModel(Content, Path) {
	return Map("path", Path, "source", Content, "versioned", false, "refused", true,
		"categories", Map(), "original_keys", Map())
}

_KL_AppCat_StoreRefused() {
	Model := KLAppCat.store_model
	return Model is Map && Model["refused"]
}

_KL_AppCat_RecordLabel(Value) {
	return Value["type"]
}

; The record of an application the user never edited.
_KL_AppCat_NewRecord(Label) {
	return Map("type", Label, "score", KLAppCatConst.UNEDITED_SCORE)
}

; What the driver ships for one application when the store holds nothing for it.
_KL_AppCat_ShippedLabel(Key) {
	return KLAppCatConst.DEFAULTS.Get(Key, KLAppCatConst.DISCOVERED_LABEL)
}

/**
 * Assigns a category and score to one application of a candidate map.
 * @param {Map} Categories Candidate map, keyed by lower-case process name.
 * @param {String} App Process name.
 * @param {String} Category Nonblank category text.
 * @param {Number} Score Score in the shared interval.
 * @throws {ValueError} An invalid edit, leaving the map unchanged.
 */
_KL_AppCat_SetRecord(Categories, App, Category, Score) {
	if !(App is String) || App == "" || !_KL_AppCat_LabelValid(Category) || !_KL_AppCat_ScoreValid(Score)
		throw ValueError("An app category edit requires a name, a label and a score in range.")
	Categories[StrLower(App)] := Map("type", Category, "score", Score)
}

/**
 * Renames a category on every application holding it.
 * @param {Map} Categories Candidate map.
 * @param {String} Old Category text to replace, compared exactly.
 * @param {String} New Nonblank replacement.
 * @returns {Integer} Applications changed.
 * @throws {ValueError} A blank new name, leaving the map unchanged.
 */
_KL_AppCat_RenameCategory(Categories, Old, New) {
	if !_KL_AppCat_LabelValid(New)
		throw ValueError("The new category must be a nonblank string.")
	Holders := []
	for Key, Value in Categories
		if _KL_AppCat_RecordLabel(Value) == Old
			Holders.Push(Key)
	for Key in Holders
		Categories[Key] := Map("type", New, "score", Categories[Key]["score"])
	return Holders.Length
}

/**
 * Adds the applications an older store held, keeping every entry already present:
 * an edit made after the upgrade is newer than what is imported.
 * @param {Map} Categories Candidate map.
 * @param {Map} Imported Process name to a { type, score } record.
 * @returns {Integer} Entries added.
 * @throws {ValueError} One invalid entry refuses them all, leaving the map unchanged.
 */
_KL_AppCat_ImportMissing(Categories, Imported) {
	for App, Record in Imported {
		if !(App is String) || App == "" || !(Record is Map) || !Record.Has("type") || !Record.Has("score")
			|| !_KL_AppCat_LabelValid(Record["type"]) || !_KL_AppCat_ScoreValid(Record["score"])
			throw ValueError("An imported app category requires a name, a label and a score in range.")
	}
	Added := 0
	for App, Record in Imported {
		Key := StrLower(App)
		if !Categories.Has(Key) {
			Categories[Key] := Map("type", Record["type"], "score", Record["score"])
			Added += 1
		}
	}
	return Added
}

_KL_AppCat_RenderRecord(Value) {
	return "{" . JsonStringLiteral("type") . ":" . JsonStringLiteral(Value["type"])
		. "," . JsonStringLiteral("score") . ":" . String(Value["score"]) . "}"
}

_KL_AppCat_RenderStore(Categories, Model := 0) {
	Keys := [], Parts := []
	for Key, Value in Categories
		Keys.Push(Key)
	for Key in KL_SortArray(Keys) {
		Name := Model is Map ? Model["original_keys"].Get(Key, Key) : Key
		Parts.Push(JsonStringLiteral(Name) . ":" . _KL_AppCat_RenderRecord(Categories[Key]))
	}
	Apps := "{" . KL_JoinArray(Parts, ",") . "}"
	return "{" . JsonStringLiteral("schema") . ":" . JsonStringLiteral(KLAppCatConst.STORE_SCHEMA)
		. "," . JsonStringLiteral("version") . ":" . String(KLAppCatConst.STORE_VERSION)
		. "," . JsonStringLiteral("apps") . ":" . Apps . "}"
}

; Only an edit overrides already persisted history. The first-run file and the
; discoveries hold records too, but one still equal to what the driver ships says
; nothing about the past: the events keep classifying that application.
_KL_AppCat_ProjectStore(Model, Apps) {
	Out := Map()
	for App in Apps {
		Key := StrLower(App)
		Value := Model["categories"].Get(Key, "")
		if !(Value is Map)
			continue
		if Value["score"] == KLAppCatConst.UNEDITED_SCORE && Value["type"] == _KL_AppCat_ShippedLabel(Key)
			continue
		Out[App] := Map("type", Value["type"], "score", Value["score"])
	}
	return Out
}

_KL_AppCat_OwnerModel(Owner) {
	Model := Owner["model"]
	return Model is Map && Model["path"] == Owner["path"] ? Model : 0
}

; Public mutations replace records rather than editing them in place. Identity
; therefore compares the detached runtime snapshot without serializing metadata.
_KL_AppCat_MapsEqual(Left, Right) {
	if Left.Count != Right.Count
		return false
	for Key, Value in Left
		if !Right.Has(Key) || Type(Value) != Type(Right[Key]) || !(Value == Right[Key])
			return false
	return true
}

; Get is the only public producer of unpersisted entries: non-default processes
; absent from the admitted file enter as an unedited discovery until their deferred save.
_KL_AppCat_IsDiscovery(Key, Value, Model) {
	return Value["type"] == KLAppCatConst.DISCOVERED_LABEL && Value["score"] == KLAppCatConst.UNEDITED_SCORE
		&& !KLAppCatConst.DEFAULTS.Has(Key) && (!(Model is Map) || !Model["categories"].Has(Key))
}
