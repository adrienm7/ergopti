; static/ergopti_plus/windows/tests/meta/test_corpus_tooltip_layout.ahk

; ==============================================================================
; MODULE: Tooltip Layout Corpus Consumer (AHK)
; DESCRIPTION:
; Loads the cross-driver tooltip layout corpus from
; _shared/tests/corpus/tooltip/layout_vectors.json and validates its
; structure. Also exercises _TooltipClampToScreen with real monitor bounds
; to confirm the function is reachable and produces sensible output.
;
; The full position-resolution cascade (_TooltipResolvePosition) involves
; CaretGetPos and UIA calls that cannot run headlessly — those are validated
; by the macOS Lua test against the shared pure-math clone. This test pins
; the AHK side by confirming the corpus is consumed and the clamp function
; is functional.
; ==============================================================================

#Requires AutoHotkey v2.0






; ===================================================
; ===================================================
; ======= 1/ Corpus Loading =========================
; ===================================================
; ===================================================

; THROWS when the corpus is missing. Returning "" made the consumers below skip,
; so the one event that must fail loudest — the cross-driver contract went
; missing — was the one event that produced green.
_TtLayoutCorpus_LoadCorpus() {
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\tooltip\layout_vectors.json"
	if !FileExist(Path)
		throw Error("tooltip layout corpus not found at '" . Path . "' — the shared vectors are a cross-driver contract; a missing corpus must fail this suite, never skip it")
	return JsonParse(FileRead(Path, "UTF-8"))
}






; ===================================================
; ===================================================
; ======= 2/ Corpus Structure Tests =================
; ===================================================
; ===================================================

; Named test functions (not fat-arrow lambdas): a block-body fat arrow
; (() => { ... }) is a v2.1-only construct that fails to parse under
; #Requires v2.0, and a per-vector lambda would capture the loop variable by
; reference (all lambdas would see the LAST vector). Looping inside one function
; sidesteps both, keeping per-vector diagnostics via the id in each assert.

_TtLayoutCorpus_TestHasVectors() {
	Data := _TtLayoutCorpus_LoadCorpus()
	AssertTrue(Data.Has("vectors"), "corpus must have 'vectors' key")
	AssertTrue(Data["vectors"].Length > 0, "vectors must be non-empty")
}

_TtLayoutCorpus_TestVectorFields() {
	Data := _TtLayoutCorpus_LoadCorpus()
	AssertTrue(Data.Has("vectors"), "corpus must expose a vectors array — skipping when the key is absent is how the whole field contract stopped being exercised without a single red")
	for Vec in Data["vectors"] {
		Id := Vec.Has("id") ? Vec["id"] : "unknown"
		AssertTrue(Vec.Has("anchor"), "vector '" . Id . "' missing 'anchor'")
		AssertTrue(Vec.Has("canvasSize"), "vector '" . Id . "' missing 'canvasSize'")
		AssertTrue(Vec.Has("screenFrame"), "vector '" . Id . "' missing 'screenFrame'")
		AssertTrue(Vec.Has("expected"), "vector '" . Id . "' missing 'expected'")
		Expected := Vec["expected"]
		AssertTrue(Expected.Has("x"), "vector '" . Id . "' expected missing 'x'")
		AssertTrue(Expected.Has("y"), "vector '" . Id . "' expected missing 'y'")
	}
}






; ===================================================
; ===================================================
; ======= 3/ ClampToScreen Behavioral Tests =========
; ===================================================
; ===================================================

; _TooltipClampToScreen reads the real monitor work area, so it cannot be driven
; with the corpus's synthetic screenFrame. That is why this file used to check
; the corpus's SHAPE and never compared one of its 6 golden positions.
;
; The clamp maths now lives in _TooltipClampRect, which takes the bounds as
; parameters — so section 4 below replays every vector against it. The tests here
; keep exercising the OS-reading wrapper, which is the part that cannot be
; replayed.

_TtLayout_TestClampCallable() {
	; Call the real clamp function with a small canvas at origin — should
	; stay within the real screen bounds
	Result := _TooltipClampToScreen(10, 10, 300, 80)
	AssertTrue(IsObject(Result), "_TooltipClampToScreen returns an object")
	; _TooltipClampToScreen returns an object literal { X, Y } (not a Map), so
	; existence is checked with HasOwnProp, not the Map-only Has() method.
	AssertTrue(Result.HasOwnProp("X") and Result.HasOwnProp("Y"), "returns { X, Y }")
	AssertTrue(Result.X >= 0, "X must be >= 0 (clamped to screen margin)")
	AssertTrue(Result.Y >= 0, "Y must be >= 0 (clamped to screen margin)")
	AssertTrue(Result.X < A_ScreenWidth, "X must be within screen width")
	AssertTrue(Result.Y < A_ScreenHeight, "Y must be within screen height")
}
Test("[corpus:tooltip-layout] _TooltipClampToScreen is callable", _TtLayout_TestClampCallable)

_TtLayout_TestClampNegative() {
	; Feed negative coordinates — should be clamped to the margin
	Result := _TooltipClampToScreen(-100, -100, 300, 80)
	AssertTrue(Result.X >= 0, "negative X clamped to >= margin")
	AssertTrue(Result.Y >= 0, "negative Y clamped to >= margin")
}
Test("[corpus:tooltip-layout] _TooltipClampToScreen clamps negative coordinates", _TtLayout_TestClampNegative)

; A point past the whole virtual screen lies on no monitor, so the clamp falls
; back to the primary work area; sizes and the margin are layout units scaled
; to physical pixels. A_ScreenWidth is the full primary monitor, which is not
; the frame the clamp uses on a runner whose work area differs from it.
_TtLayout_PrimaryWorkArea() {
	MonitorGetWorkArea(MonitorGetPrimary(), &L, &Top, &R, &B)
	return { L: L, T: Top, R: R, B: B }
}

_TtLayout_TestClampFarRight() {
	global _TOOLTIP_SCREEN_MARGIN
	Beyond := SysGet(76) + SysGet(78) + 1000   ; virtual screen left + width
	Result := _TooltipClampToScreen(Beyond, 100, 300, 80)
	Scale := _TooltipDpiScale()
	MaxX := _TtLayout_PrimaryWorkArea().R - Round(300 * Scale) - Round(_TOOLTIP_SCREEN_MARGIN * Scale)
	AssertEqual(MaxX, Result.X, "far-right X clamped to the work area right - canvasW - margin")
}
Test("[corpus:tooltip-layout] _TooltipClampToScreen clamps far-right coordinates", _TtLayout_TestClampFarRight)

_TtLayout_TestClampFarBottom() {
	global _TOOLTIP_SCREEN_MARGIN
	Beyond := SysGet(77) + SysGet(79) + 1000   ; virtual screen top + height
	Result := _TooltipClampToScreen(100, Beyond, 300, 80)
	Scale := _TooltipDpiScale()
	MaxY := _TtLayout_PrimaryWorkArea().B - Round(80 * Scale) - Round(_TOOLTIP_SCREEN_MARGIN * Scale)
	AssertEqual(MaxY, Result.Y, "far-bottom Y clamped to the work area bottom - canvasH - margin")
}
Test("[corpus:tooltip-layout] _TooltipClampToScreen clamps far-bottom coordinates", _TtLayout_TestClampFarBottom)

_TtLayout_TestClampConsistent() {
	R1 := _TooltipClampToScreen(100, 100, 200, 50)
	R2 := _TooltipClampToScreen(100, 100, 200, 50)
	AssertEqual(R1.X, R2.X, "same input → same X")
	AssertEqual(R1.Y, R2.Y, "same input → same Y")
}
Test("[corpus:tooltip-layout] _TooltipClampToScreen: multiple calls produce consistent results", _TtLayout_TestClampConsistent)



; Register the corpus structure tests (these run before the behavioral tests).
Test("[corpus:tooltip-layout] corpus has vectors array", _TtLayoutCorpus_TestHasVectors)
Test("[corpus:tooltip-layout] all vectors have required fields", _TtLayoutCorpus_TestVectorFields)





; ===================================================
; ===================================================
; ======= 4/ Golden positions from the corpus =======
; ===================================================
; ===================================================

; Replays every corpus vector through the pure clamp and compares the result to
; the expected {x, y} the shared JS produced.
;
; This is what "corpus test" was supposed to mean here. The file loaded the JSON,
; asserted that each vector HAD an expected x and y, and never once compared
; them — so a Windows clamp that disagreed with the shared implementation would
; have passed every assertion in this file.
;
; Only the clamp is replayed, not the full cascade: acquiring the anchor needs
; CaretGetPos and UIA, which cannot run headlessly. The vectors whose expected
; position is the unclamped anchor-derived point are therefore checked for
; idempotence — clamping a position already inside the screen must not move it,
; which is the property the cascade relies on.
_TtLayoutCorpus_GoldenClampPositions() {
	Data := _TtLayoutCorpus_LoadCorpus()
	Assert(Data.Has("vectors") && Data["vectors"].Length > 0,
		"corpus must expose vectors — a golden comparison over an empty list proves nothing")

	MARGIN := 5
	Checked := 0
	for Vec in Data["vectors"] {
		Id := Vec.Has("id") ? Vec["id"] : "?"
		Exp := Vec["expected"]
		Canvas := Vec["canvasSize"]
		Frame := Vec["screenFrame"]

		L := Frame["x"]
		Top := Frame["y"]
		R := Frame["x"] + Frame["w"]
		B := Frame["y"] + Frame["h"]

		; The expected position is what the shared implementation resolved AND
		; clamped. Clamping it again must be a no-op: the shared clamp is
		; idempotent, and if the AHK formula or margin differed from it, the
		; second pass would move the point.
		Out := _TooltipClampRect(Exp["x"], Exp["y"], Canvas["w"], Canvas["h"], L, Top, R, B, MARGIN)
		AssertEqual(Exp["x"], Out.X,
			"vector '" . Id . "': re-clamping the expected X moved it. The shared clamp is idempotent, "
			. "so a different result means the Windows formula or margin disagrees with the corpus")
		AssertEqual(Exp["y"], Out.Y,
			"vector '" . Id . "': re-clamping the expected Y moved it — same divergence, vertical axis")
		Checked += 1
	}

	Assert(Checked >= 6,
		"expected at least the 6 shipped layout vectors, compared " . Checked
		. " — a shrinking corpus silently reduces this to a formality")
}
Test("[corpus:tooltip-layout] every golden position survives a re-clamp", _TtLayoutCorpus_GoldenClampPositions)


; A position OUTSIDE the corpus screen must be pulled back to the margin, with
; the corpus's own frame supplying the bounds. Without this, the test above
; would pass on a clamp that did nothing at all.
_TtLayoutCorpus_ClampActuallyClamps() {
	Data := _TtLayoutCorpus_LoadCorpus()
	Vec := Data["vectors"][1]
	Frame := Vec["screenFrame"]
	Canvas := Vec["canvasSize"]
	MARGIN := 5

	L := Frame["x"], Top := Frame["y"]
	R := Frame["x"] + Frame["w"], B := Frame["y"] + Frame["h"]

	FarRight := _TooltipClampRect(R + 500, Top + 100, Canvas["w"], Canvas["h"], L, Top, R, B, MARGIN)
	AssertEqual(R - Canvas["w"] - MARGIN, FarRight.X,
		"a tooltip past the right edge must be pulled back to (right - width - margin)")

	FarUp := _TooltipClampRect(L + 100, Top - 500, Canvas["w"], Canvas["h"], L, Top, R, B, MARGIN)
	AssertEqual(Top + MARGIN, FarUp.Y,
		"a tooltip above the top edge must be pushed down to (top + margin)")
}
Test("[corpus:tooltip-layout] the clamp actually clamps (not an identity function)", _TtLayoutCorpus_ClampActuallyClamps)
