; hotstrings/engine/catalogue/category_glyph.ahk

; ==============================================================================
; MODULE: Hotstring Category Glyph
; DESCRIPTION:
; Picks the small symbol a preview row shows beside its trigger label, and the
; i18n key that names it for a screen reader. The preview tints sit at one
; lightness, so a colour-blind reader cannot tell the categories apart by tint;
; the maintainer chose a glyph per category over a text label on 2026-11-19.
;
; The rule is _shared/hotstrings/engine/category_glyph.lua, ported here: the
; category's [_meta] `glyph` / `glyph_name_key`, else its per-category default
; (defaults.toml [glyphs] personal), else the shared default. A declared value
; that is not one visible symbol (or not a dotted i18n key) is refused, returned
; in Rejected for the caller to log, and never shown. Both ports answer
; _shared/tests/corpus/hotstrings/category_glyph_vectors.json.
; ==============================================================================

; At most two code points: one symbol, optionally followed by a variation selector.
global HOTSTRINGS_GLYPH_MAX_CODEPOINTS := 2

; The shared defaults, loaded at boot from _shared/hotstrings/data/catalogue/defaults.toml
; [glyphs] by HotstringsConfigLoadSharedDefaults(). Empty until then, so a resolve
; before the load shows no glyph rather than an invented one.
global HOTSTRINGS_DEFAULT_GLYPH := ""
global HOTSTRINGS_DEFAULT_GLYPH_NAME_KEY := ""
; Category -> { Glyph, NameKey }: the per-category defaults ("personal").
global HOTSTRINGS_CATEGORY_DEFAULT_GLYPHS := Map()

; Whether a value can be shown as a category glyph: one or two code points,
; none of them whitespace or a control character.
; @param Value {Any}
; @returns {Boolean}
HotstringCategoryGlyphIsGlyph(Value) {
	global HOTSTRINGS_GLYPH_MAX_CODEPOINTS
	if !(Value is String) || Value == ""
		return false
	Count := 0, Index := 1, Length := StrLen(Value)
	while (Index <= Length) {
		Point := Ord(SubStr(Value, Index, 2))
		if (Point >= 0xD800 && Point <= 0xDFFF)
			return false
		if (Point <= 0x20 || (Point >= 0x7F && Point <= 0xA0) || Point == 0x2028 || Point == 0x2029
				|| (Point >= 0x2000 && Point <= 0x200A) || Point == 0x3000)
			return false
		Count += 1
		if (Count > HOTSTRINGS_GLYPH_MAX_CODEPOINTS)
			return false
		Index += (Point > 0xFFFF) ? 2 : 1
	}
	return true
}

; Whether a value can name a glyph: a dotted i18n key.
; @param Value {Any}
; @returns {Boolean}
HotstringCategoryGlyphIsNameKey(Value) {
	return (Value is String) && RegExMatch(Value, "^[A-Za-z0-9_]+\.[A-Za-z0-9_.]+$") ? true : false
}

; Resolves the glyph of one category.
; @param Meta {Object} The category's [_meta]: a declared field is an own
;   property (Glyph, GlyphNameKey); an absent one is not set.
; @param CategoryGlyph {String} Per-category default glyph, "" when none.
; @param CategoryNameKey {String} Per-category default name key, "" when none.
; @param DefaultGlyph {String} Shared default glyph.
; @param DefaultNameKey {String} Shared default name key.
; @returns {Object} { Glyph, NameKey, Rejected: Map(field -> value) }
HotstringCategoryGlyphResolve(Meta, CategoryGlyph, CategoryNameKey, DefaultGlyph, DefaultNameKey) {
	Rejected := Map()
	Glyph := _HotstringCategoryGlyphPick(Meta, "Glyph", "glyph", HotstringCategoryGlyphIsGlyph,
		[CategoryGlyph, DefaultGlyph], Rejected)
	NameKey := _HotstringCategoryGlyphPick(Meta, "GlyphNameKey", "glyph_name_key", HotstringCategoryGlyphIsNameKey,
		[CategoryNameKey, DefaultNameKey], Rejected)
	return { Glyph: Glyph, NameKey: NameKey, Rejected: Rejected }
}

; The first valid rung: the declared field, then each fallback.
_HotstringCategoryGlyphPick(Meta, Prop, Field, IsValid, Fallbacks, Rejected) {
	if IsObject(Meta) && Meta.HasOwnProp(Prop) {
		Declared := Meta.%Prop%
		if IsValid.Call(Declared)
			return Declared
		Rejected[Field] := Declared
	}
	for Value in Fallbacks {
		if IsValid.Call(Value)
			return Value
	}
	return ""
}

; Logs each field a category declares and the resolver refused, so a user's
; typo is reported rather than silently replaced by the default.
; @param Category {String}
; @param Resolved {Object} A HotstringCategoryGlyphResolve answer.
HotstringCategoryGlyphLogRejected(Category, Resolved) {
	for Field, Value in Resolved.Rejected
		try LoggerWarn("HotstringsConfig",
			"Category '{1}' declares {2} = '{3}', which is not one visible symbol or not an i18n key; its preview shows the default instead.",
			HotstringCategoryLogName(Category), Field, IsObject(Value) ? Type(Value) : Value)
}
