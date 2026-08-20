; static/ergopti_plus/windows/tests/meta/test_chord_notation.ahk

; ==============================================================================
; MODULE: Chord Notation Corpus Consumer (AHK)
; DESCRIPTION:
; Runs the shared chord corpus (_shared/lua/chord/vectors.json) against the
; AutoHotkey notation twin in infra/chord.ahk. The macOS driver runs the SAME file
; against the shared Lua core (macos/tests/unit/meta/test_chord_notation.lua),
; which is the only thing that makes "one notation, two implementations" a fact
; rather than an intention: a chord that canonicalises differently on the two
; drivers means one config file produces two different bindings.
;
; CONTRACT:
; 1. Every "canonicalize" vector maps its input to exactly the expected label.
; 2. Every "rejects" vector is refused — an empty label, never a half-chord that
;    would reach Hotkey(), bind nothing, and report success.
; 3. Every "equals" vector compares as recorded, in both operand orders.
; 4. The native translation stays the OS-specific half: it lives in the adapter,
;    and the cases below pin the two spellings AutoHotkey needs but no other
;    driver does (brace-wrapped names and upper-case scan codes).
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================
; ================================
; ======= 1/ Corpus Loader =======
; ================================
; ================================

_Chord_RunAll() {
	CorpusPath := A_ScriptDir . "\..\..\_shared\lua\chord\vectors.json"

	_Chord_FileExists() {
		AssertTrue(FileExist(CorpusPath) != "", "chord corpus must exist at: " . CorpusPath)
	}
	Test("chord corpus: file exists", _Chord_FileExists)

	if !FileExist(CorpusPath)
		return

	Data := JsonParse(FileRead(CorpusPath, "UTF-8"))

	_Chord_Sections() {
		; A corpus that lost a section would let this whole file pass while
		; testing a third of the notation
		for _, Section in ["canonicalize", "rejects", "equals"] {
			AssertTrue(Data.Has(Section), "chord corpus must hold the '" . Section . "' section")
			AssertTrue(Data[Section].Length > 0, "chord corpus section '" . Section . "' is empty")
		}
	}
	Test("chord corpus: all three sections present and non-empty", _Chord_Sections)

	if !Data.Has("canonicalize") || !Data.Has("rejects") || !Data.Has("equals")
		return




	; ===================================
	; ===================================
	; ======= 2/ Canonicalisation =======
	; ===================================
	; ===================================

	; A fat-arrow default parameter would capture the loop variable by reference, so
	; every case would run against whichever vector the loop finished on. Building
	; each closure inside its own call gives it its own V
	_Chord_MakeCanonical(V) {
		_Run() {
			AssertEqual(ChordCanonicalize(V["input"]), V["expect"],
				"canonical spelling of '" . V["input"] . "'")
		}
		return _Run
	}
	for _, Vector in Data["canonicalize"] {
		Test("chord canonicalize: " . Vector["id"], _Chord_MakeCanonical(Vector))
	}

	_Chord_Idempotent() {
		; A canonical label that re-canonicalises to something else would mean the
		; format is not a fixed point, so a value round-tripped through config.toml
		; would drift a little further on every save
		for _, V in Data["canonicalize"] {
			AssertEqual(ChordCanonicalize(V["expect"]), V["expect"],
				"re-canonicalising '" . V["expect"] . "' changed it")
		}
	}
	Test("chord canonicalize: canonicalisation is idempotent across the corpus", _Chord_Idempotent)




	; ============================
	; ============================
	; ======= 3/ Rejection =======
	; ============================
	; ============================

	_Chord_MakeReject(V) {
		_Run() {
			AssertEqual(ChordCanonicalize(V["input"]), "",
				"'" . V["input"] . "' must be refused, not canonicalised")
			Parsed := ChordParse(V["input"])
			AssertTrue(!Parsed["ok"], "'" . V["input"] . "' must not parse")
			AssertTrue(StrLen(Parsed["err"]) > 0,
				"a refusal must carry a reason the caller can log")
		}
		return _Run
	}
	for _, Vector in Data["rejects"] {
		Test("chord reject: " . Vector["id"], _Chord_MakeReject(Vector))
	}




	; ===========================
	; ===========================
	; ======= 4/ Equality =======
	; ===========================
	; ===========================

	_Chord_MakeEqual(V) {
		_Run() {
			AssertEqual(ChordEquals(V["a"], V["b"]), V["expect"],
				"equality of '" . V["a"] . "' and '" . V["b"] . "'")
			AssertEqual(ChordEquals(V["b"], V["a"]), V["expect"],
				"swapping the operands changed the answer")
		}
		return _Run
	}
	for _, Vector in Data["equals"] {
		Test("chord equals: " . Vector["id"], _Chord_MakeEqual(Vector))
	}
}

_Chord_RunAll()





; =====================================
; =====================================
; ======= 5/ Native Translation =======
; =====================================
; =====================================

_ChordNative_RunAll() {
	; These live here and not in the shared corpus because they are the half that
	; is SUPPOSED to differ per driver. Pinning them stops a "simplification" from
	; letting a canonical key name reach Hotkey() raw, which binds nothing silently

	_ChordNative_Modifiers() {
		AssertEqual(HotkeyRegistrarNativeSpec(["ctrl", "shift"], "S"), "^+s",
			"Ctrl+Shift+S must translate to the AutoHotkey spec")
		AssertEqual(HotkeyRegistrarNativeSpec(["cmd"], "E"), "#e",
			"the canonical cmd modifier is the Windows key on this driver")
		AssertEqual(HotkeyRegistrarNativeSpec(["alt"], "1"), "!1",
			"Alt+1 must translate to the AutoHotkey spec")
	}
	Test("chord native: modifiers map to AutoHotkey prefixes", _ChordNative_Modifiers)

	_ChordNative_NamedKeys() {
		Cases := Map(
			"space", "^space",
			"return", "^enter",
			"enter", "^enter",
			"tab", "^tab",
			"escape", "^escape",
			"backspace", "^backspace",
			"delete", "^delete")
		for KeyName, ExpectedSpec in Cases {
			AssertEqual(ExpectedSpec, HotkeyRegistrarNativeSpec(["ctrl"], KeyName),
				"Hotkey names must use bare syntax for '" . KeyName . "'")
		}
	}
	Test("chord native: every named key uses Hotkey syntax, not Send syntax "
		. "(hotkey-native-named-key-syntax)", _ChordNative_NamedKeys)

	_ChordNative_ScanCodes() {
		AssertEqual(HotkeyRegistrarNativeSpec(["cmd"], "sc029"), "#SC029",
			"the notation core lower-cases multi-character keys; AutoHotkey wants scan codes upper")
	}
	Test("chord native: scan codes are upper-cased", _ChordNative_ScanCodes)

	_ChordNative_UnsupportedModifier() {
		AssertEqual(HotkeyRegistrarNativeSpec(["fn"], "S"), "",
			"Windows exposes no Fn modifier — the spec must be refused, not silently dropped")
	}
	Test("chord native: a modifier Windows lacks is refused", _ChordNative_UnsupportedModifier)

	_ChordNative_SlotChords() {
		; The slot ids are our own vocabulary; this is where they meet the notation
		AssertEqual(_KeyboardSlotChord("ctrl_shift_v"), "Ctrl+Shift+V", "ctrl_shift_v")
		AssertEqual(_KeyboardSlotChord("ctrl_b"), "Ctrl+B", "ctrl_b")
		AssertEqual(_KeyboardSlotChord("win_e"), "Cmd+E", "win_e maps onto the canonical cmd modifier")
		AssertEqual(_KeyboardSlotChord("alt_space"), "Alt+Space", "alt_space")
		AssertEqual(_KeyboardSlotChord("win_period"), "Cmd+.", "win_period names a character, not a word")
		AssertEqual(_KeyboardSlotChord("win_comma"), "Cmd+,", "win_comma names a character, not a word")
		AssertEqual(_KeyboardSlotChord("win_enter"), "Cmd+Return", "win_enter names the Return key")
		AssertEqual(_KeyboardSlotChord("win_sc029"), "Cmd+Sc029", "win_sc029 keeps the scan code as the key")
		AssertEqual(_KeyboardSlotChord("nomodifier_x"), "",
			"a slot with no recognised modifier must be refused — binding its bare "
			. "suffix would steal a plain letter from every application")
	}
	Test("chord native: slot ids resolve to canonical chords", _ChordNative_SlotChords)

	_ChordNative_RoundTrip() {
		; The end-to-end path the boot loop actually walks: slot id → chord → spec.
		; Pinned against the specs the driver emitted before the notation existed,
		; so adopting it cannot silently rebind a user's shortcut
		Cases := Map("ctrl_shift_v", "^+v", "ctrl_b", "^b", "win_x", "#x", "alt_1", "!1", "win_sc029", "#SC029")
		for Slot, ExpectedSpec in Cases {
			Chord := _KeyboardSlotChord(Slot)
			Parsed := ChordParse(Chord)
			AssertTrue(Parsed["ok"], "slot '" . Slot . "' must produce a parseable chord, got '" . Chord . "'")
			AssertEqual(HotkeyRegistrarNativeSpec(Parsed["mods"], Parsed["key"]), ExpectedSpec,
				"slot '" . Slot . "' must still reach the OS as '" . ExpectedSpec . "'")
		}
	}
	Test("chord native: slot id → chord → spec matches the pre-notation specs", _ChordNative_RoundTrip)
}

_ChordNative_RunAll()
