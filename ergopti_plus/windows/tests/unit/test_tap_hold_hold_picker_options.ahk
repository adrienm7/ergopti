; tests/unit/test_tap_hold_hold_picker_options.ahk

; ==============================================================================
; MODULE: Every option of the hold picker is the hold the key gets
; DESCRIPTION:
; The maintainer's rule of 2026-10-01: whatever option the hold picker offers
; (one modifier, every combination of them, the layer, none) is the hold the
; key has after the pick, on a key that held another one before. Each option
; is written through the production writer, read back by the production
; loader as the next start reads it, resolved by the production resolver and
; held by the production owner with its key adapters captured: the keys the
; owner presses are the option's, and nothing else.
; ==============================================================================

#Requires AutoHotkey v2.0

; The key names an option's modifiers are pressed as on a key that is not
; itself a modifier: the left key of each, AltGr as the layout names it.
_THPO_ExpectedKeys(OptionId) {
	static Left := Map("ctrl", "LCtrl", "shift", "LShift", "alt", "LAlt", "win", "LWin")
	Keys := []
	for Token in StrSplit(OptionId, "+")
		Keys.Push(Token == "alt_gr" ? KS_AltGrKeyName() : Left[Token])
	return Keys
}

_THPO_Flat(Value) {
	Text := ""
	for Name in (Value is Array ? Value : [Value])
		Text .= (Text == "" ? "" : ",") . Name
	return Text
}

_THPO_EveryOptionOwned(TargetPath) {
	global TapHold, _SharedDir, _THGT_Writes
	Defaults := _SharedDir . "\tap_hold\defaults.toml"
	Options := TapHoldHoldOptions()
	Kinds := Map("none", 0, "modifier", 0, "layer", 0)
	for HoldOpt in Options {
		Label := HoldOpt["kind"] . ":" . HoldOpt["id"]
		; The key held Shift before the pick, as the maintainer's Space did.
		TapHold := Map("keys", Map("space", Map("hold_modifier", "shift")), "inherit_defaults", true)
		_THGT_ResetRecords()
		Result := WriteTapHoldHold("space", HoldOpt, _THGT_Writer, _THGT_Replace, _THGT_Delete, _THGT_Authorize)
		Assert((Result is Integer) && Result == 1, Label . " must be written")
		Ticked := 0
		for Other in Options {
			if IsTapHoldHoldActive("space", Other) {
				Ticked += 1
				AssertEqual(Label, Other["kind"] . ":" . Other["id"], "the picker ticks the option picked")
			}
		}
		AssertEqual(1, Ticked, Label . " is the only ticked option")

		; What the next start reads: the staged bytes through the loader, on a
		; path the loader has never cached.
		NextBoot := A_Temp . "\ergopti_thpo_" . A_ScriptHwnd . "_" . A_Index . ".toml"
		Assert(FSWriteDurable(NextBoot, _THGT_Writes[1]["content"]))
		try {
			Loaded := LoadTapHoldToml(NextBoot, Defaults)
		} finally FSDeleteStrict(NextBoot)
		Modifier := TapHoldHoldModifier(Loaded, "space")
		Layer := TapHoldHoldLayer(Loaded, "space")
		Kinds[HoldOpt["kind"]] += 1
		if (HoldOpt["kind"] == "layer") {
			AssertEqual(HoldOpt["id"], Layer, Label . " holds its layer")
			AssertEqual("", Modifier, Label . " keeps no modifier of the previous hold")
			continue
		}
		AssertEqual("", Layer, Label . " holds no layer")
		if (HoldOpt["kind"] == "none") {
			AssertEqual("", Modifier, "the native option holds nothing, and no default leaks back")
			AssertEqual("", ResolveHoldModifierKey(Modifier, "space"))
			continue
		}
		AssertEqual(HoldOpt["id"], Modifier, Label . " is read back as picked")
		Expected := _THPO_Flat(_THPO_ExpectedKeys(HoldOpt["id"]))
		Resolved := ResolveHoldModifierKey(Modifier, "space")
		AssertEqual(Expected, _THPO_Flat(Resolved), Label . " resolves to its own keys")

		; The owner presses exactly those keys while the key is down, then lifts them.
		Pressed := [], Lifted := []
		Down(ModKey) {
			Pressed.Push(_THPO_Flat(ModKey))
			return true
		}
		Up(ModKey) {
			Lifted.Push(_THPO_Flat(ModKey))
			return true
		}
		Held := TapHoldOwnImmediateModifier("space", "SC039", Resolved, 0.2,
			(*) => true, (*) => false, (*) => 0, Down, Up, (*) => "", false, (*) => false)
		Assert(Held["activated"], Label . " is held")
		AssertEqual(Expected, _THPO_Flat(Pressed), Label . " presses its own keys and no other")
		AssertEqual(Expected, _THPO_Flat(Lifted), Label . " lifts what it pressed")
	}
	Assert(Kinds["none"] == 1 && Kinds["layer"] >= 1, "the picker offers the native option and the layer")
	Assert(Kinds["modifier"] >= 31, "the picker offers every combination of the five modifiers, got " . Kinds["modifier"])
}

_THPO_EveryOption() {
	return _THGT_WithFixture(_THPO_EveryOptionOwned)
}
Test("tap-hold picker: every hold option is the hold the key gets, after Shift (hold-picker-every-option-2026-10-01)",
	_THPO_EveryOption)
