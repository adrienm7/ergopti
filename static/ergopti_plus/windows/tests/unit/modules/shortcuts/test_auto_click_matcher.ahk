; tests/unit/modules/shortcuts/test_auto_click_matcher.ahk

; ==============================================================================
; MODULE: Auto-Click Matcher and Policy (Windows ports)
; DESCRIPTION:
; Replays _shared/tests/corpus/keep_awake/auto_click_match_vectors.json and
; auto_click_policy_vectors.json, which the macOS and Linux suites replay
; through _shared/shortcuts/engine/auto_click_*.lua, through the AutoHotkey
; ports modules/shortcuts/auto_click_matcher.ahk and auto_click_policy.ahk.
;
; ROOT CAUSE ENCODED:
; The auto-clicker clicks a button found by a tolerance. A Windows port that
; rounded, scaled or ranked candidates differently would find another button,
; or the same one at another tolerance, than macOS and Linux; one that skipped
; a refusal would click outside the allowed apps.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================
; ============================================
; ======= 1/ Corpus scenes ===================
; ============================================
; ============================================

; @returns {Map} One decoded corpus under _shared/tests/corpus/keep_awake.
_TACM_Corpus(Name) {
	global _SharedDir
	AssertTrue(IsSet(_SharedDir), "the harness must expose _SharedDir")
	Path := _SharedDir . "\tests\corpus\keep_awake\" . Name
	AssertTrue(FileExist(Path) != "", "the corpus must exist at " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

_TACM_Clamp(V) {
	return V < 0 ? 0 : (V > 255 ? 255 : V)
}

; A template image from its character rows.
_TACM_Template(Corpus, Name) {
	Rows := []
	for Text in Corpus["templates"][Name] {
		Row := []
		for Char in StrSplit(Text)
			Row.Push(Corpus["palette"][Char])
		Rows.Push(Row)
	}
	return AutoClickFromRows(Rows)
}

; Adds the corpus noise (Park-Miller) to an image in place.
_TACM_Noise(Image, Noise) {
	if !IsObject(Noise) || Noise["amplitude"] = 0
		return
	State := Noise["seed"], Span := 2 * Noise["amplitude"] + 1
	Loop Image.Width * Image.Height {
		State := Mod(State * 16807, 2147483647)
		Image.Pixels[A_Index] := _TACM_Clamp(Image.Pixels[A_Index] + Mod(State, Span) - Noise["amplitude"])
	}
}

; A scene image from its recipe.
_TACM_Scene(Corpus, Scene) {
	Pixels := []
	Loop Scene["width"] * Scene["height"]
		Pixels.Push(Scene["background"])
	Image := { Width: Scene["width"], Height: Scene["height"], Pixels: Pixels }
	_TACM_Noise(Image, Scene["noise"])
	for Paste in Scene["pastes"] {
		Tpl := AutoClickScale(_TACM_Template(Corpus, Paste["template"]), Paste["scale"])
		Y := 0
		while Y < Tpl.Height {
			X := 0
			while X < Tpl.Width {
				Image.Pixels[(Paste["y"] + Y) * Scene["width"] + Paste["x"] + X + 1] :=
					_TACM_Clamp(Tpl.Pixels[Y * Tpl.Width + X + 1] + Paste["delta"])
				X += 1
			}
			Y += 1
		}
	}
	_TACM_Noise(Image, Scene.Has("overlay_noise") ? Scene["overlay_noise"] : "")
	return Image
}

_TACM_Options(Corpus, Threshold := "") {
	Options := Map()
	for Key, Value in Corpus["options"]
		Options[Key] := Value
	if Threshold != ""
		Options["threshold"] := Threshold
	return Options
}




; ============================================
; ============================================
; ======= 2/ Matcher vectors =================
; ============================================
; ============================================

; One vector per call, so the assertions read parameters, not loop variables.
_TACM_MatchVector(Corpus, Vector) {
	Image := _TACM_Scene(Corpus, Vector["scene"])
	Template := AutoClickScale(_TACM_Template(Corpus, Vector["template"]),
		Vector.Has("template_scale") ? Vector["template_scale"] : 1)
	Match := AutoClickFind(Image, Template, _TACM_Options(Corpus, Vector.Has("threshold") ? Vector["threshold"] : ""),
		&Reason)
	Expect := Vector["expect"]
	if Expect == JSON_NULL {
		AssertFalse(IsObject(Match), Vector["id"] . " must not match")
	} else {
		AssertTrue(IsObject(Match), Vector["id"] . " must match")
		AssertEqual(Expect["x"], Match.X, Vector["id"] . " x")
		AssertEqual(Expect["y"], Match.Y, Vector["id"] . " y")
		AssertEqual(Expect["width"], Match.Width, Vector["id"] . " width")
		AssertEqual(Expect["height"], Match.Height, Vector["id"] . " height")
		AssertEqual(Expect["scale"], Match.Scale, Vector["id"] . " scale")
	}
	if Vector.Has("reason")
		AssertEqual(Vector["reason"], Reason, Vector["id"] . " reason")
	if Vector.Has("score_near") {
		Best := AutoClickFind(Image, Template, _TACM_Options(Corpus, 0.01))
		AssertTrue(Abs(Best.Score - Vector["score_near"]) < 1e-6, Vector["id"] . " score " . Best.Score)
	}
}

_TACM_MatchVectors() {
	Corpus := _TACM_Corpus("auto_click_match_vectors.json")
	Checked := 0
	for Vector in Corpus["vectors"] {
		_TACM_MatchVector(Corpus, Vector)
		Checked += 1
	}
	AssertTrue(Checked >= 9, "expected the matcher vectors, found " . Checked)
}
Test("auto-click matcher: the port replays every corpus scene (auto-click-vectors)", _TACM_MatchVectors)

_TACM_TemplateAndClickPoint() {
	Corpus := _TACM_Corpus("auto_click_match_vectors.json")
	AssertEqual("template_uniform", AutoClickCheckTemplate(_TACM_Template(Corpus, "flat")), "a flat template")
	AssertEqual("", AutoClickCheckTemplate(_TACM_Template(Corpus, "button")), "the button template")
	AutoClickClickPoint(100, 50, 2, { X: 50, Y: 30, Width: 48, Height: 24 }, &X, &Y)
	AssertEqual(137, X, "click x")
	AssertEqual(71, Y, "click y")
	AssertEqual(105, AutoClickGray(255, 0, 255), "BT.601 gray of magenta, rounded as the shared module")
	AssertThrows(() => AutoClickScale(_TACM_Template(Corpus, "button"), 3), "a scale that is no power of two")
}
Test("auto-click matcher: a flat template is refused and a match is clicked at its centre (auto-click-vectors)",
	_TACM_TemplateAndClickPoint)




; ============================================
; ============================================
; ======= 3/ Policy vectors ==================
; ============================================
; ============================================

_TACM_PolicyVector(Corpus, Vector) {
	State := Map()
	for Key, Value in Corpus["base"]
		State[Key] := Value
	for Key, Value in Vector["state"]
		State[Key] := Value
	Removed := []
	for Key, Value in State {
		if Value == JSON_NULL
			Removed.Push(Key)
	}
	for Key in Removed
		State.Delete(Key)
	Click := AutoClickMayClick(State, &Reason)
	AssertEqual(Vector["click"], Click ? 1 : 0, Vector["id"] . " click")
	AssertEqual(Vector["reason"], Reason, Vector["id"] . " reason")
	Known := false
	for Word in AutoClickReasons() {
		if Word == Reason
			Known := true
	}
	AssertTrue(Known, Vector["id"] . " reason is in the vocabulary")
}

_TACM_PolicyVectors() {
	Corpus := _TACM_Corpus("auto_click_policy_vectors.json")
	Checked := 0
	for Vector in Corpus["vectors"] {
		_TACM_PolicyVector(Corpus, Vector)
		Checked += 1
	}
	AssertTrue(Checked >= 14, "expected the policy vectors, found " . Checked)
}
Test("auto-click policy: the port decides every corpus state (auto-click-vectors)", _TACM_PolicyVectors)
