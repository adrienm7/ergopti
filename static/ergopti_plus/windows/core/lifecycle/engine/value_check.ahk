; core/lifecycle/engine/value_check.ahk

; ==============================================================================
; MODULE: User Value Check (AHK port)
; DESCRIPTION:
; AHK port of _shared/settings/data/value_schema/value_check.js: checks one
; user-entered or stored setting value against its declaration in the shared
; value schema (generated into _generated/value_schema.ahk). It replays the
; shared value_check_vectors.json (tests/unit/core/lifecycle/engine/test_value_check_vectors.ahk),
; so Windows refuses the same stored values and typed text as macOS, Linux and
; the web pages, for the same reason.
;
; FEATURES & RATIONALE:
; 1. Three places, one rule: ValueCheckParseEntry() reads typed text,
;    ValueCheckValue() reads a loaded value, ValueCheckRequire() guards the
;    consuming boundary and throws. Callers log and localize.
; 2. AutoHotkey has no boolean type (true is the integer 1): a boolean setting
;    admits the integers 0 and 1, as the TOML loader already reads them.
; 3. A String holding digits is a wrong type at load, never a number: the
;    loader hands numbers as Integer or Float, and a string means the file
;    stored text.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\..\..\_generated\value_schema.ahk





; ================================
; ================================
; ======= 1/ Schema Lookup =======
; ================================
; ================================

/**
 * The declaration of one setting, throwing on an unknown name. A pattern key
 * may use `*` for one path segment.
 * @param {String} Key - Dotted setting path, e.g. "tap_holds.lone_modifier_tap_max_ms".
 * @param {Map} Schema - The schema; the generated one by default.
 * @returns {Map} The declaration.
 */
ValueCheckEntryFor(Key, Schema := 0) {
	Settings := (IsObject(Schema) ? Schema : ValueSchemaData())["settings"]
	if !(Key is String)
		throw TypeError("value_check: a setting key must be a string", -1)
	if Settings.Has(Key)
		return Settings[Key]
	Segments := StrSplit(Key, ".")
	for Name, Entry in Settings {
		if !InStr(Name, "*")
			continue
		Pattern := StrSplit(Name, ".")
		if Pattern.Length != Segments.Length
			continue
		Matched := true
		for Index, Part in Pattern {
			if (Part != "*" && !(Part == Segments[Index])) {
				Matched := false
				break
			}
		}
		if Matched
			return Entry
	}
	throw ValueError("value_check: the value schema declares no setting " . Key, -1)
}





; =========================
; =========================
; ======= 2/ Checks =======
; =========================
; =========================

/** A refusal carrying the declared bounds for the localized message. */
_ValueCheckRefusal(Reason, Entry) {
	Result := Map("ok", false, "reason", Reason)
	if Entry.Has("min")
		Result["min"] := Entry["min"]
	if Entry.Has("max")
		Result["max"] := Entry["max"]
	return Result
}

/** A success carrying the admitted value. */
_ValueCheckAdmitted(Value) {
	return Map("ok", true, "value", Value)
}

/** Whether a number is finite: infinity minus itself and NaN never equal 0. */
ValueCheckIsFinite(Value) {
	return (Value is Integer) || ((Value is Float) && (Value - Value == 0))
}

/** Whether Value is one of the declaration's special values. */
_ValueCheckIsSpecial(Entry, Value) {
	if !Entry.Has("special")
		return false
	for Item in Entry["special"] {
		if (Item["value"] = Value)
			return true
	}
	return false
}

/** Checks a numeric candidate. */
_ValueCheckNumber(Entry, Value) {
	if !(Value is Number)
		return _ValueCheckRefusal("wrong_type", Entry)
	if !ValueCheckIsFinite(Value)
		return _ValueCheckRefusal("not_finite", Entry)
	if _ValueCheckIsSpecial(Entry, Value)
		return _ValueCheckAdmitted(Value)
	if (Entry["type"] == "integer" && (Value is Float) && Value != Floor(Value))
		return _ValueCheckRefusal("not_integer", Entry)
	if (Entry.Has("min") && Value < Entry["min"])
		return _ValueCheckRefusal("below_minimum", Entry)
	if (Entry.Has("max") && Value > Entry["max"])
		return _ValueCheckRefusal("above_maximum", Entry)
	return _ValueCheckAdmitted(Value)
}

/**
 * Checks a value as loaded from a file or received from a host bridge.
 * @param {Map} Entry - Declaration from ValueCheckEntryFor().
 * @param {Any} Value - Candidate value.
 * @returns {Map} "ok" and "value", or "ok" false with "reason", "min", "max".
 */
ValueCheckValue(Entry, Value) {
	if !(Entry is Map) || !Entry.Has("type")
		throw ValueError("value_check: a check needs a declared type", -1)
	Kind := Entry["type"]
	switch Kind, true {
		case "integer", "decimal":
			return _ValueCheckNumber(Entry, Value)
		case "boolean":
			if ((Value is Integer) && (Value = 0 || Value = 1))
				return _ValueCheckAdmitted(Value)
			return _ValueCheckRefusal("wrong_type", Entry)
		case "enum":
			if !(Value is String)
				return _ValueCheckRefusal("wrong_type", Entry)
			for Allowed in Entry["values"] {
				if (Allowed == Value)
					return _ValueCheckAdmitted(Value)
			}
			return _ValueCheckRefusal("not_allowed", Entry)
		case "string", "path", "url":
			if !(Value is String)
				return _ValueCheckRefusal("wrong_type", Entry)
			if (Value == "" && !(Entry.Has("allow_empty") && Entry["allow_empty"]))
				return _ValueCheckRefusal("empty", Entry)
			if (Entry.Has("max_length") && _ValueCheckCharCount(Value) > Entry["max_length"])
				return _ValueCheckRefusal("too_long", Entry)
			; A lowercase http or https scheme, then no ASCII space or control
			; character, as the JS and Lua ports read a web address.
			if (Kind == "url" && !RegExMatch(Value, "^https?://[^\x{00}-\x{20}\x{7F}]+$"))
				return _ValueCheckRefusal("not_url", Entry)
			return _ValueCheckAdmitted(Value)
	}
	throw ValueError("value_check: unknown declared type " . Kind, -1)
}

/** Characters (code points), not UTF-16 units, as the JS and Lua ports count. */
_ValueCheckCharCount(Text) {
	Count := 0
	Index := 1
	Length := StrLen(Text)
	while (Index <= Length) {
		Code := Ord(SubStr(Text, Index, 2))
		Index += (Code > 0xFFFF) ? 2 : 1
		Count += 1
	}
	return Count
}

/** Rounds a bound scaled to the typed unit to the microunit (0.001 * 1000 reads 1). */
_ValueCheckScaled(Bound, Scale) {
	Value := Round(Bound * Scale * 1000000) / 1000000
	return (Value == Floor(Value)) ? Integer(Value) : Value
}

/** A refusal of typed text, its bounds given in the typed unit. */
_ValueCheckEntryRefusal(Reason, Entry) {
	Result := _ValueCheckRefusal(Reason, Entry)
	Scale := Entry.Has("entry_scale") ? Entry["entry_scale"] : 1
	if Result.Has("min")
		Result["min"] := _ValueCheckScaled(Result["min"], Scale)
	if Result.Has("max")
		Result["max"] := _ValueCheckScaled(Result["max"], Scale)
	return Result
}

/**
 * Reads what a person typed in an entry box. A declaration with entry_scale is
 * typed in another unit than it is stored (milliseconds typed, seconds stored:
 * scale 1000) and entry_type says whether the typed number may carry decimals;
 * a refusal's bounds are in the typed unit.
 * @param {Map} Entry - Declaration from ValueCheckEntryFor().
 * @param {Any} Text - Raw text of the box.
 * @returns {Map} As ValueCheckValue().
 */
ValueCheckParseEntry(Entry, Text) {
	if !(Text is String)
		return _ValueCheckEntryRefusal("wrong_type", Entry)
	Kind := Entry["type"]
	if (Kind == "string" || Kind == "path")
		return ValueCheckValue(Entry, Text)
	Trimmed := Trim(Text, " `t`r`n")
	if (Trimmed == "")
		return _ValueCheckEntryRefusal("empty", Entry)
	if (Kind == "integer" || Kind == "decimal") {
		Integral := RegExMatch(Trimmed, "^[+-]?[0-9]+$")
		if !(Integral || RegExMatch(Trimmed, "^[+-]?[0-9]+[.,][0-9]+$"))
			return _ValueCheckEntryRefusal("wrong_type", Entry)
		TypedType := Entry.Has("entry_type") ? Entry["entry_type"] : Kind
		if (TypedType == "integer" && !Integral)
			return _ValueCheckEntryRefusal("not_integer", Entry)
		; Float() keeps a long digit run finite instead of wrapping it modulo 2^64,
		; and an integral typed number is handed on as an Integer.
		Typed := Float(StrReplace(LTrim(Trimmed, "+"), ",", "."))
		if (Integral && Abs(Typed) < 2 ** 53)
			Typed := Integer(Typed)
		Scale := Entry.Has("entry_scale") ? Entry["entry_scale"] : 1
		Result := _ValueCheckNumber(Entry, Scale == 1 ? Typed : Typed / Scale)
		return Result["ok"] ? Result : _ValueCheckEntryRefusal(Result["reason"], Entry)
	}
	if (Kind == "boolean") {
		if (Trimmed == "true")
			return _ValueCheckAdmitted(true)
		if (Trimmed == "false")
			return _ValueCheckAdmitted(false)
		return _ValueCheckRefusal("wrong_type", Entry)
	}
	return ValueCheckValue(Entry, Trimmed)
}





; =====================================
; =====================================
; ======= 3/ Messages And Guard =======
; =====================================
; =====================================

/**
 * The localized message of a refusal as i18n keys with their arguments: the
 * sentence naming what is accepted, then one per special value. An argument
 * Map("key", K) is itself an i18n key to translate before it is inserted.
 * @param {Map} Entry - Declaration.
 * @param {Map} Result - A refusal from ValueCheckParseEntry() or ValueCheckValue().
 * @returns {Array} Maps with "key" and "args".
 */
ValueCheckMessageParts(Entry, Result) {
	Parts := []
	Kind := Entry["type"]
	if (Kind == "integer" || Kind == "decimal") {
		TypedType := Entry.Has("entry_type") ? Entry["entry_type"] : Kind
		Unit := Entry.Has("entry_unit") ? Entry["entry_unit"] : (Entry.Has("unit") ? Entry["unit"] : "")
		Base := "dialog.value_check.range_" . TypedType
		if (Unit != "")
			Parts.Push(Map("key", Base . "_unit",
				"args", [Result["min"], Result["max"], Map("key", "value_check.unit." . Unit)]))
		else
			Parts.Push(Map("key", Base, "args", [Result["min"], Result["max"]]))
		if Entry.Has("special") {
			Scale := Entry.Has("entry_scale") ? Entry["entry_scale"] : 1
			for Item in Entry["special"]
				Parts.Push(Map("key", "dialog.value_check.special",
					"args", [_ValueCheckScaled(Item["value"], Scale), Map("key", Item["label_key"])]))
		}
	} else if (Result["reason"] == "too_long") {
		Parts.Push(Map("key", "dialog.value_check.too_long", "args", [Entry["max_length"]]))
	} else if (Result["reason"] == "not_allowed") {
		Parts.Push(Map("key", "dialog.value_check.not_allowed", "args", []))
	} else if (Result["reason"] == "not_url") {
		Parts.Push(Map("key", "dialog.value_check.not_url", "args", []))
	} else {
		Parts.Push(Map("key", "dialog.value_check.empty", "args", []))
	}
	return Parts
}

/** Writes a bound without a trailing fraction on a whole number, as the other ports do. */
ValueCheckFormatNumber(Value) {
	if (Value is Integer)
		return String(Value)
	if (Value == Floor(Value) && Abs(Value) < 2 ** 53)
		return String(Integer(Value))
	Text := Format("{:.15g}", Value)
	return Text
}

/**
 * Translates ValueCheckMessageParts() with an i18n accessor, fills the
 * positional {1}, {2}… placeholders and joins the sentences with a space.
 * @param {Array} Parts - From ValueCheckMessageParts().
 * @param {Func} Translate - Translate(Key) returns the template of a key.
 * @returns {String}
 */
ValueCheckRenderMessage(Parts, Translate) {
	Sentences := ""
	for Part in Parts {
		Args := []
		for Arg in Part["args"] {
			if (Arg is Map)
				Args.Push(Translate(Arg["key"]))
			else if (Arg is Number)
				Args.Push(ValueCheckFormatNumber(Arg))
			else
				Args.Push(String(Arg))
		}
		Template := Translate(Part["key"])
		if !(Template is String) || Template == ""
			throw ValueError("value_check: no text for " . Part["key"], -1)
		for Position, Value in Args
			Template := StrReplace(Template, "{" . Position . "}", Value)
		Sentences .= (Sentences == "" ? "" : " ") . Template
	}
	return Sentences
}

/**
 * Replaces how a refusal is shown, for the headless test suite, where a native
 * message box would block the run. A function static, so include order cannot
 * reset it.
 * @param {Func} Presenter - Presenter(Key, Result), or 0 for the native box.
 * @returns {Func|Integer} The presenter in force after the call.
 */
ValueCheckSetRefusalPresenter(Presenter := "") {
	static Current := 0
	if !(Presenter is String)
		Current := Presenter
	return Current
}

/**
 * Shows the localized refusal of typed text: the accepted range and the special
 * values, under the shared « Invalid value » title, and logs it. Nothing is
 * written by the caller after a refusal.
 * @param {String} Key - Declaration of the shared value schema.
 * @param {Map} Result - The refusal from ValueCheckParseEntry().
 * @param {Any} Typed - What the person typed, for the log.
 */
ValueCheckShowRefusal(Key, Result, Typed := "") {
	LoggerWarn("ValueCheck", "Typed value '{1}' for {2} refused ({3}).",
		IsObject(Typed) ? Type(Typed) : Typed, Key, Result["reason"])
	Presenter := ValueCheckSetRefusalPresenter()
	if HasMethod(Presenter, "Call")
		return Presenter.Call(Key, Result)
	Text := ValueCheckRenderMessage(ValueCheckMessageParts(ValueCheckEntryFor(Key), Result), (K) => t(K))
	Ui_MsgBox(Text, t("dialog.value_check.title"), "Iconx")
}

/**
 * Guards a consuming boundary: returns the value, or throws a ValueError naming
 * the setting, the reason and the value for the caller to log.
 * @param {String} Key - Dotted setting path.
 * @param {Any} Value - Value about to reach the engine.
 * @param {Map} Schema - The schema; the generated one by default.
 * @returns {Any} The admitted value.
 */
ValueCheckRequire(Key, Value, Schema := 0) {
	Result := ValueCheckValue(ValueCheckEntryFor(Key, Schema), Value)
	if !Result["ok"]
		throw ValueError(Format("value_check: {1} refused ({2}): {3}", Key, Result["reason"],
			IsObject(Value) ? Type(Value) : String(Value)), -1)
	return Result["value"]
}
