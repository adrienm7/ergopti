; infra/chord.ahk

; ==============================================================================
; MODULE: Chord Notation (AutoHotkey twin)
; DESCRIPTION:
; Canonical parser and formatter for keyboard chords ("Ctrl+Shift+S"), and the
; AutoHotkey half of the notation the macOS and Linux drivers read from
; _shared/lua/chord/init.lua. The two implementations exist because there is no
; shared AutoHotkey layer; they are kept honest by a single corpus,
; _shared/lua/chord/vectors.json, which both suites run.
;
; FEATURES & RATIONALE:
; 1. One canonical spelling: modifiers always appear in CHORD_MOD_ORDER, so the
;    label the Windows tray shows and the label the macOS menu shows are the same
;    string for the same chord, not two strings that happen to agree today.
; 2. Alias tolerance on input: "command", "win", "super", "meta" and "opt" all
;    name modifiers users actually type into a config file. Input is forgiving,
;    output never is.
; 3. Fail fast on nonsense: ChordParse returns ok=false plus a reason rather than
;    a half-chord. A chord that silently lost its key would reach Hotkey(), bind
;    to nothing, and report success.
; ==============================================================================





; ===================================
; ===================================
; ======= 1/ Canonical Tables =======
; ===================================
; ===================================

; Canonical modifier ordering. A formatted chord always lists modifiers in this
; order regardless of the order the caller supplied, which is what makes two
; spellings of one chord string-comparable
global CHORD_MOD_ORDER := ["cmd", "ctrl", "alt", "shift", "fn"]

; Display spelling for each canonical modifier. Deliberately language-neutral:
; these are key names, not prose, and are rendered verbatim in every locale
global CHORD_MOD_LABELS := Map("cmd", "Cmd", "ctrl", "Ctrl", "alt", "Alt", "shift", "Shift", "fn", "Fn")

; Every spelling a user or a config file may write, mapped to its canonical
; modifier. Input is forgiving because these names come from humans
global CHORD_MOD_ALIASES := Map(
	"cmd", "cmd", "command", "cmd", "meta", "cmd", "super", "cmd", "win", "cmd", "windows", "cmd",
	"ctrl", "ctrl", "control", "ctrl",
	"alt", "alt", "opt", "alt", "option", "alt",
	"shift", "shift",
	"fn", "fn", "func", "fn"
)

; The separator between a chord's parts. A constant because the parser and the
; formatter must never disagree about it
global CHORD_SEPARATOR := "+"





; =======================================
; =======================================
; ======= 2/ Parsing & Formatting =======
; =======================================
; =======================================

/**
 * Normalises a key name to its canonical internal form.
 * Single characters are upper-cased (so "s" and "S" are one key); longer names
 * are lower-cased (so "Space", "SPACE" and "space" are one key).
 * @param {String} key Raw key name.
 * @returns {String} Canonical key.
 */
ChordCanonicalKey(key) {
	if (StrLen(key) = 1) {
		return StrUpper(key)
	}
	return StrLower(key)
}

/**
 * Renders a canonical key for display.
 * Mirrors the spelling the drivers already showed before this module existed, so
 * adopting it cannot silently change a label the user has learned.
 * @param {String} key Canonical key.
 * @returns {String} Display spelling.
 */
ChordDisplayKey(key) {
	if (StrLen(key) = 1) {
		return StrUpper(key)
	}
	return StrUpper(SubStr(key, 1, 1)) . SubStr(key, 2)
}

/**
 * Builds the canonical label for a chord.
 * @param {Array} mods Modifier names, in any order, in any accepted spelling.
 * @param {String} key The primary key.
 * @returns {Map} ok=true plus label, or ok=false plus err.
 */
ChordFormat(mods, key) {
	global CHORD_MOD_ORDER, CHORD_MOD_LABELS, CHORD_MOD_ALIASES, CHORD_SEPARATOR

	if (!IsSet(key) || Type(key) != "String" || key = "") {
		return Map("ok", false, "err", "a chord must name a key")
	}
	if (!IsSet(mods) || Type(mods) != "Array") {
		return Map("ok", false, "err", "modifiers must be an array")
	}

	present := Map()
	for _, raw in mods {
		if (Type(raw) != "String") {
			return Map("ok", false, "err", "modifier names must be strings")
		}
		lowered := StrLower(raw)
		if (!CHORD_MOD_ALIASES.Has(lowered)) {
			return Map("ok", false, "err", "unknown modifier: " . raw)
		}
		present[CHORD_MOD_ALIASES[lowered]] := true
	}

	parts := []
	for _, modName in CHORD_MOD_ORDER {
		if (present.Has(modName)) {
			parts.Push(CHORD_MOD_LABELS[modName])
		}
	}
	parts.Push(ChordDisplayKey(ChordCanonicalKey(key)))

	label := ""
	for index, part in parts {
		label .= (index = 1 ? "" : CHORD_SEPARATOR) . part
	}
	return Map("ok", true, "label", label)
}

/**
 * Parses a chord string into its modifiers and key.
 * @param {String} chordString Chord string, e.g. "ctrl+shift+s" or "Cmd+Space".
 * @returns {Map} ok=true plus mods (Array) and key (String), or ok=false plus err.
 */
ChordParse(chordString) {
	global CHORD_MOD_ORDER, CHORD_MOD_ALIASES, CHORD_SEPARATOR

	if (!IsSet(chordString) || Type(chordString) != "String" || chordString = "") {
		return Map("ok", false, "err", "a chord must be a non-empty string")
	}

	tokens := []
	for _, raw in StrSplit(chordString, CHORD_SEPARATOR) {
		trimmed := Trim(raw)
		if (trimmed != "") {
			tokens.Push(trimmed)
		}
	}
	if (tokens.Length = 0) {
		return Map("ok", false, "err", "a chord must name a key")
	}

	; The last token is always the key: a chord ending in a modifier name binds to
	; nothing, and accepting "Ctrl+Shift" would let it reach Hotkey() and fail
	; there instead of here
	key := tokens.Pop()
	present := Map()
	for _, token in tokens {
		lowered := StrLower(token)
		if (!CHORD_MOD_ALIASES.Has(lowered)) {
			return Map("ok", false, "err", "unknown modifier: " . token)
		}
		present[CHORD_MOD_ALIASES[lowered]] := true
	}

	if (CHORD_MOD_ALIASES.Has(StrLower(key))) {
		return Map("ok", false, "err", "a chord must end in a key, not the modifier " . key)
	}

	mods := []
	for _, modName in CHORD_MOD_ORDER {
		if (present.Has(modName)) {
			mods.Push(modName)
		}
	}
	return Map("ok", true, "mods", mods, "key", ChordCanonicalKey(key))
}

/**
 * Re-spells a chord string in canonical form.
 * @param {String} chordString Chord string in any accepted spelling.
 * @returns {String} The canonical label, or "" when the chord is invalid.
 */
ChordCanonicalize(chordString) {
	parsed := ChordParse(chordString)
	if (!parsed["ok"]) {
		return ""
	}
	formatted := ChordFormat(parsed["mods"], parsed["key"])
	if (!formatted["ok"]) {
		return ""
	}
	return formatted["label"]
}

/**
 * Reports whether two chord strings name the same chord.
 * Invalid input is never equal to anything, including itself — an unparseable
 * chord has no identity to compare.
 * @param {String} first
 * @param {String} second
 * @returns {Boolean}
 */
ChordEquals(first, second) {
	canonicalFirst := ChordCanonicalize(first)
	canonicalSecond := ChordCanonicalize(second)
	if (canonicalFirst = "" || canonicalSecond = "") {
		return false
	}
	return canonicalFirst == canonicalSecond
}
