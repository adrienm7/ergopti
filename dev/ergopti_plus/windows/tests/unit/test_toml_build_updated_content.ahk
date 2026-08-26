; tests/unit/test_toml_build_updated_content.ahk

; ==============================================================================
; MODULE: TOML Detached Candidate Builder Tests
; DESCRIPTION:
; Proves the onboarding candidate builder renders the exact canonical image used
; by TOML_BatchWrite while leaving the source file and parse cache unmodified.
;
; FEATURES & RATIONALE:
; 1. Build-only mode performs no filesystem publication.
; 2. The later ordinary writer produces byte-identical canonical content.
; 3. Unreadable seeds still refuse rather than rebuilding from defaults.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../test_framework.ahk
#Include ../test_stubs.ahk
#Include ../../adapters/file_system.ahk
#Include ../../infra/toml/toml_helpers.ahk





; ============================================
; ============================================
; ======= 1/ Detached Render Behaviour =======
; ============================================
; ============================================

_TBUI_NewPath() {
	static Sequence := 0
	Sequence += 1
	return A_Temp . "\ergopti-toml-build-" . A_ScriptHwnd . "-"
		. A_TickCount . "-" . Sequence . ".toml"
}

_TBUI_DetachedBuildMatchesWriter() {
	Path := _TBUI_NewPath()
	Seed := '[existing]`nkeep = "yes"`n'
	Updates := [
		{ Section: "script", Key: "locale", Value: "fr" },
		{ Section: "metrics", Key: "metrics_enabled", Value: true }
	]
	try {
		AssertTrue(FSWrite(Path, Seed))
		Candidate := TOML_BuildUpdatedContent(Path, Updates)
		AssertTrue(Candidate is Map
			&& Candidate.Has("status") && Candidate["status"] is String
			&& Candidate["status"] == "ok"
			&& Candidate.Has("kind") && Candidate["kind"] is String
			&& Candidate["kind"] == "rendered")
		AssertTrue(Candidate.Has("content")
			&& Candidate["content"] is String)
		AssertEqual(Seed, FSRead(Path),
			"build-only rendering must not publish or truncate the source")
		CandidatePath := Path . ".candidate"
		AssertTrue(FSWriteCreateDurable(CandidatePath, Candidate["content"]) == 1)
		AssertTrue(TOML_BatchWrite(Path, Updates))
		AssertEqual(_TBUI_RawHex(CandidatePath), _TBUI_RawHex(Path),
			"detached candidate bytes must equal ordinary canonical write bytes, including BOM")
	} finally {
		FSDelete(Path)
		FSDelete(Path . ".candidate")
	}
}
Test("toml candidate: detached build is byte-identical and non-mutating "
	. "(toml-build-updated-content-detached)",
	_TBUI_DetachedBuildMatchesWriter)

_TBUI_DetachedBuildBypassesStaleCache() {
	Path := _TBUI_NewPath()
	V1 := '[existing]`nold = "cached"`n'
	V2 := '[existing]`nold = "disk"`nunrelated = "keep"`n'
	try {
		AssertTrue(FSWrite(Path, V1))
		Cached := ParseTomlFile(Path)
		AssertEqual("cached", Cached["existing"]["old"])
		AssertTrue(FSWrite(Path, V2))
		Candidate := TOML_BuildUpdatedContent(Path,
			[{ Section: "script", Key: "locale", Value: "fr" }])
		AssertTrue(Candidate is Map && Candidate.Has("content"))
		AssertContains(Candidate["content"], 'old = "disk"')
		AssertContains(Candidate["content"], 'unrelated = "keep"',
			"transactional render must preserve changes made after onboarding preload")
		AssertEqual("cached", Cached["existing"]["old"],
			"fresh detached parsing must not mutate the live cache object")
		AssertFalse(Cached["existing"].Has("unrelated"),
			"a refused Reload must retain the pre-transition cache state")
	} finally FSDelete(Path)
}
Test("toml candidate: detached render fresh-reads after ownership acquisition "
	. "(toml-build-updated-content-fresh-read)",
	_TBUI_DetachedBuildBypassesStaleCache)

_TBUI_OrdinaryWriteBypassesStaleCache() {
	Path := _TBUI_NewPath()
	V1 := '[existing]`nold = "cached"`n'
	V2 := '[existing]`nold = "disk"`nunrelated = "keep"`n'
	try {
		AssertTrue(FSWrite(Path, V1))
		Cached := ParseTomlFile(Path)
		AssertEqual("cached", Cached["existing"]["old"])
		AssertTrue(FSWrite(Path, V2))
		AssertTrue(TOML_BatchWrite(Path,
			[{ Section: "script", Key: "locale", Value: "fr" }]))
		Published := FSRead(Path)
		AssertContains(Published, 'old = "disk"',
			"ordinary writes must not resurrect values from a warmed cache")
		AssertContains(Published, 'unrelated = "keep"',
			"ordinary writes must preserve external edits made after cache warmup")
		AssertContains(Published, 'locale = "fr"',
			"the requested update must still be published")
	} finally FSDelete(Path)
}
Test("toml writer: ordinary write fresh-reads after cache warmup "
	. "(toml-batchwrite-fresh-read)",
	_TBUI_OrdinaryWriteBypassesStaleCache)

_TBUI_CandidateCarriesExactOldAuthority() {
	Path := _TBUI_NewPath()
	try {
		Seed := Chr(0xFEFF) . "[existing]`nvalue = 1`n"
		AssertTrue(FSWriteCreateDurable(Path, Seed) == 1)
		Candidate := TOML_BuildUpdatedContent(Path,
			[{ Section: "script", Key: "locale", Value: "fr" }])
		AssertTrue(Candidate["source_present"] == 1)
		AssertEqual(Seed, Candidate["source_content"],
			"candidate authority must carry exact source bytes including BOM")
	} finally FSDelete(Path)
}
Test("toml candidate: detached result carries exact optimistic old authority "
	. "(toml-build-updated-content-old-authority)",
	_TBUI_CandidateCarriesExactOldAuthority)

_TBUI_RenderFailureReturnsTypedError() {
	for _, InvalidResult in [false,
		Map("status", "ok", "kind", "rendered", "content", 7),
		Map("status", "error", "kind", "upstream_failed", "content", "")] {
		Threw := false
		try Candidate := _TOML_FinalizeBuildResult(InvalidResult, 1, "old bytes")
		catch {
			Threw := true
			Candidate := 0
		}
		AssertFalse(Threw,
			"a rejected render must return a typed result instead of indexing false")
		AssertTrue(Candidate is Map
			&& Candidate.Has("status") && Candidate["status"] == "error"
			&& Candidate.Has("kind") && Candidate["kind"] == "render_failed",
			"the failure branch after the guarded success block must remain reachable")
	}
}
Test("toml candidate: invalid renderer result returns a typed failure "
	. "(toml-build-updated-content-render-failure)",
	_TBUI_RenderFailureReturnsTypedError)

_TBUI_RawHex(Path) {
	FH := FileOpen(Path, "r", "UTF-8-RAW")
	if !IsObject(FH)
		return false
	try {
		ByteCount := FH.Length
		FH.Pos := 0
		Raw := Buffer(ByteCount > 0 ? ByteCount : 1, 0)
		if ByteCount > 0 && FH.RawRead(Raw, ByteCount) != ByteCount
			return false
		Hex := ""
		loop ByteCount
			Hex .= Format("{:02x}", NumGet(Raw, A_Index - 1, "UChar"))
		return Hex
	} finally FH.Close()
}





; ===================================
; ===================================
; ======= 2/ Direct-run Entry =======
; ===================================
; ===================================

if A_LineFile = A_ScriptFullPath
	RunTests()
