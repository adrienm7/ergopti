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
; is functional (P0-G.5).
; ==============================================================================

#Requires AutoHotkey v2.0






; ===================================================
; ===================================================
; ======= 1/ Corpus Loading =========================
; ===================================================
; ===================================================

_TtLayoutCorpus_LoadCorpus() {
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\tooltip\layout_vectors.json"
	if !FileExist(Path) {
		return ""
	}
	Raw := FileRead(Path, "UTF-8")
	return JsonParse(Raw)
}






; ===================================================
; ===================================================
; ======= 2/ Corpus Structure Tests =================
; ===================================================
; ===================================================

_TtLayoutCorpus_RegisterStructureTests() {
	Data := _TtLayoutCorpus_LoadCorpus()
	if (Data = "") {
		Test("[corpus:tooltip-layout] corpus file exists", () => AssertTrue(false,
			"Corpus file not found at _shared/tests/corpus/tooltip/layout_vectors.json"))
		return
	}

	Test("[corpus:tooltip-layout] corpus has vectors array", () =>
	{
		AssertTrue(Data.Has("vectors"), "corpus must have 'vectors' key")
		AssertTrue(Data["vectors"].Length > 0, "vectors must be non-empty")
	})

	for Vec in Data["vectors"] {
		Id := Vec.Has("id") ? Vec["id"] : "unknown"
		Test("[corpus:tooltip-layout:" . Id . "] vector has required fields", () =>
		{
			AssertTrue(Vec.Has("anchor"), "vector '" . Id . "' missing 'anchor'")
			AssertTrue(Vec.Has("canvasSize"), "vector '" . Id . "' missing 'canvasSize'")
			AssertTrue(Vec.Has("screenFrame"), "vector '" . Id . "' missing 'screenFrame'")
			AssertTrue(Vec.Has("expected"), "vector '" . Id . "' missing 'expected'")
			Exp := Vec["expected"]
			AssertTrue(Exp.Has("x"), "vector '" . Id . "' expected missing 'x'")
			AssertTrue(Exp.Has("y"), "vector '" . Id . "' expected missing 'y'")
		})
	}
}






; ===================================================
; ===================================================
; ======= 3/ ClampToScreen Behavioral Tests =========
; ===================================================
; ===================================================

; _TooltipClampToScreen uses real monitor bounds via MonitorGetWorkArea,
; so we cannot mock a synthetic 1920x1080 screen. Instead we verify the
; function is reachable and produces clamped output within the real screen.

Test("[corpus:tooltip-layout] _TooltipClampToScreen is callable", () =>
{
	; Call the real clamp function with a small canvas at origin — should
	; stay within the real screen bounds
	Result := _TooltipClampToScreen(10, 10, 300, 80)
	AssertTrue(IsObject(Result), "_TooltipClampToScreen returns an object")
	AssertTrue(Result.Has("X") and Result.Has("Y"), "returns { X, Y }")
	AssertTrue(Result.X >= 0, "X must be >= 0 (clamped to screen margin)")
	AssertTrue(Result.Y >= 0, "Y must be >= 0 (clamped to screen margin)")
	AssertTrue(Result.X < A_ScreenWidth, "X must be within screen width")
	AssertTrue(Result.Y < A_ScreenHeight, "Y must be within screen height")
})

Test("[corpus:tooltip-layout] _TooltipClampToScreen clamps negative coordinates", () =>
{
	; Feed negative coordinates — should be clamped to the margin
	Result := _TooltipClampToScreen(-100, -100, 300, 80)
	AssertTrue(Result.X >= 0, "negative X clamped to >= margin")
	AssertTrue(Result.Y >= 0, "negative Y clamped to >= margin")
})

Test("[corpus:tooltip-layout] _TooltipClampToScreen clamps far-right coordinates", () =>
{
	; Feed coordinates far to the right — should be clamped
	Result := _TooltipClampToScreen(A_ScreenWidth + 1000, 100, 300, 80)
	MaxX := A_ScreenWidth - 300 - 5  ; width - canvasW - margin
	AssertTrue(Result.X <= MaxX, "far-right X clamped to <= screen width - canvasW - margin")
})

Test("[corpus:tooltip-layout] _TooltipClampToScreen clamps far-bottom coordinates", () =>
{
	Result := _TooltipClampToScreen(100, A_ScreenHeight + 1000, 300, 80)
	MaxY := A_ScreenHeight - 80 - 5  ; height - canvasH - margin
	AssertTrue(Result.Y <= MaxY, "far-bottom Y clamped to <= screen height - canvasH - margin")
})

Test("[corpus:tooltip-layout] _TooltipClampToScreen: multiple calls produce consistent results", () =>
{
	R1 := _TooltipClampToScreen(100, 100, 200, 50)
	R2 := _TooltipClampToScreen(100, 100, 200, 50)
	AssertEqual(R1.X, R2.X, "same input → same X")
	AssertEqual(R1.Y, R2.Y, "same input → same Y")
})



; Register the corpus structure tests (these must run first so corpus
; vectors are enumerated before the behavioral tests).
_TtLayoutCorpus_RegisterStructureTests()
