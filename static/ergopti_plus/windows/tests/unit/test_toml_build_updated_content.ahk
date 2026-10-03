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

_TBUI_UnchangedBooleanLiterals() {
	Path := _TBUI_NewPath()
	Seed := '[existing]`non = true # enabled`noff = false`nzero = 0`none = 1`n'
	Updates := [{ Section: "script", Key: "locale", Value: "fr" }]
	try {
		AssertTrue(FSWrite(Path, Seed))
		Cached := ParseTomlFile(Path)
		AssertTrue(Cached["existing"]["on"] is Integer)
		AssertEqual(1, Cached["existing"]["on"])
		AssertThrows(() => _ParseTomlFileImpl(Path, true, false, Seed, true),
			"writer mode must refuse reading native-value cache entries")
		AssertThrows(() => _ParseTomlFileImpl(Path, false, true, Seed, true),
			"writer mode must refuse publishing sentinels into the reader cache")
		Candidate := TOML_BuildUpdatedContent(Path, Updates)
		AssertEqual("ok", Candidate["status"])
		AssertEqual(Seed, FSRead(Path), "building must not publish")
		AssertTrue(TOML_BatchWrite(Path, Updates))
		for Content in [Candidate["content"], FSRead(Path)] {
			for Key, Literal in Map("on", "true", "off", "false", "zero", "0", "one", "1")
				AssertTrue(RegExMatch(Content, "m)^" . Key . " = " . Literal . "$"),
					"unrelated updates must retain the literal type of " . Key)
		}
		AssertTrue(Cached["existing"]["on"] is Integer,
			"writer-only Boolean intent must never leak into the reader cache")
		Fresh := TOML_ParseFreshFile(Path)
		AssertTrue(Fresh["existing"]["off"] is Integer)
		AssertEqual(0, Fresh["existing"]["off"])
		AssertTrue(TOML_BatchWrite(Path, [
			{ Section: "existing", Key: "on", Value: 1 },
			{ Section: "existing", Key: "off", Delete: 1 }
		]))
		Published := FSRead(Path)
		AssertTrue(RegExMatch(Published, "m)^on = 1$"),
			"an explicit numeric replacement must override preserved Boolean intent")
		AssertFalse(RegExMatch(Published, "m)^off ="),
			"a deleted Boolean must not be resurrected")
	} finally FSDelete(Path)
}
Test("toml writer: unrelated updates preserve scalar Boolean literals "
	. "(toml-write-preserve-boolean-literals)", _TBUI_UnchangedBooleanLiterals)

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


; Handwritten physical sources prove that a flat writer cannot own every valid
; document. Their expected no-op images are the sources, not generated models.
_TBUI_NamespaceLossVectors() {
	return [
		{ Id: "dotted", Source: '# retain exact spelling`n[settings]`nnested.value = 1 # owned identity`n',
			Key: "nested.value", Value: 1 },
		{ Id: "root", Source: 'future.version = "001" # unknown root`n[settings]`nowned = 1`n',
			Key: "owned", Value: 1 },
		{ Id: "table-arrays", Source: '[[future]]`nname="first"`n[[future]]`nname="second"`n[settings]`nowned=1`n',
			Key: "owned", Value: 1 }
	]
}

_TBUI_LossSensitiveBuildPreservesSource() {
	for Vector in _TBUI_NamespaceLossVectors() {
		Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . Vector.Source
		try {
			AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
			Cached := ParseTomlFile(Path)
			Candidate := TOML_BuildUpdatedContent(Path,
				[{ Section: "settings", Key: Vector.Key, Value: Vector.Value }])
			AssertEqual("ok", Candidate["status"], Vector.Id)
			Assert(StrCompare(Source, Candidate["content"], true) == 0,
				"a real no-op retains the complete loss-sensitive byte image: " . Vector.Id)
			AssertEqual(Source, Candidate["source_content"])
			AssertTrue(Cached == ParseTomlFile(Path), "detached admission never replaces the live cache")
			AssertTrue(FSUtf8ExactMatches(Path, Source))
		} finally FSDelete(Path)
	}
}
Test("toml writer admission: loss-sensitive detached no-ops retain original identities and bytes (toml-writer-document)",
	_TBUI_LossSensitiveBuildPreservesSource)

_TBUI_ChangedLossSensitiveBuildRefuses() {
	for Vector in _TBUI_NamespaceLossVectors() {
		Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . Vector.Source
		try {
			AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
			Cached := ParseTomlFile(Path)
			for Update in [{ Section: "settings", Key: Vector.Key, Value: 2 },
				{ Section: "settings", Key: Vector.Key, Delete: 1 },
				{ Section: "settings", Key: "unrelated", Value: TOML_Bool(false) }] {
				Candidate := TOML_BuildUpdatedContent(Path, [Update])
				AssertEqual("error", Candidate["status"], "no unowned namespace may disappear: " . Vector.Id)
				AssertFalse(Candidate.Has("source_content"), "no refused candidate gains publication authority")
				AssertTrue(FSUtf8ExactMatches(Path, Source))
				AssertTrue(Cached == ParseTomlFile(Path), "refusal leaves the live cache object intact")
			}
		} finally FSDelete(Path)
	}
}
Test("toml writer admission: changed dotted leaves and unowned root/table-array loss refuse before candidate authority (toml-writer-document)",
	_TBUI_ChangedLossSensitiveBuildRefuses)

_TBUI_QuotedDotRemainsRepresentable() {
	Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . '[settings]`n"nested.value" = 1 # canonical writer owns this leaf`n'
	Expected := Chr(0xFEFF) . '[settings]`n"nested.value" = 2`n'
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
		Candidate := TOML_BuildUpdatedContent(Path,
			[{ Section: "settings", Key: "nested.value", Value: 2 }])
		AssertEqual("ok", Candidate["status"])
		Assert(StrCompare(Expected, Candidate["content"], true) == 0,
			"an independently quoted literal dot keeps the existing canonical contract")
		AssertTrue(TOML_BatchWrite(Path, [{ Section: "settings", Key: "nested.value", Value: 2 }]))
		AssertTrue(FSUtf8ExactMatches(Path, Expected))
		Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertEqual(2, Document["settings"]["nested.value"])
		AssertFalse(Document["settings"].Has("nested"))
	} finally FSDelete(Path)
}
Test("toml writer admission: literal quoted dots remain writable and canonical (toml-writer-document)",
	_TBUI_QuotedDotRemainsRepresentable)

; The actual value getter is a native controlled concurrent writer. Assertions
; stay outside rendering/catching callbacks; its observations cannot be swallowed.
class _TBUI_SourceMutatingBoolean extends TOML_Bool {
	__New(Path, Content) {
		this.Path := Path
		this.Content := Content
		this.Calls := 0
		this.WriteAccepted := false
	}
	__Get(Name, Parameters) {
		if Name != "Value"
			throw PropertyError("Unexpected controlled value property")
		this.Calls += 1
		if this.Calls == 1
			this.WriteAccepted := FSWriteDurable(this.Path, this.Content) == 1
		return true
	}
}

_TBUI_ConcurrentSourceRefusesCandidate() {
	for BuildOnly in [true, false] {
		Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . '[settings]`nowned = false`n'
		Concurrent := Chr(0xFEFF) . '[settings]`nowned = false`nforeign = "concurrent authority"`n'
		try {
			AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
			Cached := ParseTomlFile(Path)
			Value := _TBUI_SourceMutatingBoolean(Path, Concurrent)
			Update := { Section: "settings", Key: "owned", Value: Value }
			if BuildOnly {
				Result := TOML_BuildUpdatedContent(Path, [Update])
				AssertEqual("error", Result["status"])
			} else
				AssertFalse(TOML_BatchWrite(Path, [Update]))
			AssertTrue(Value.Calls > 0, "the real renderer must observe the controlled native value")
			AssertTrue(Value.WriteAccepted, "the concurrent source mutation must actually reach disk")
			AssertTrue(FSUtf8ExactMatches(Path, Concurrent), "fresh source authority cannot be overwritten or called a no-op")
			Current := ParseTomlFile(Path)
			if BuildOnly {
				AssertTrue(Cached == Current, "a refused detached build does not replace the live reader cache")
				AssertFalse(Current["settings"].Has("foreign"))
			} else {
				AssertFalse(Cached == Current, "an ordinary writer retires its actually stale reader snapshot")
				AssertEqual("concurrent authority", Current["settings"]["foreign"])
			}
			AssertFalse(Cached["settings"].Has("foreign"), "retirement never mutates the prior reader object")
		} finally FSDelete(Path)
	}
}
Test("toml writer admission: actual concurrent mutation cannot gain detached or ordinary publication (toml-writer-document)",
	_TBUI_ConcurrentSourceRefusesCandidate)


_TBUI_SemanticDestinationsCannotHideEffects() {
	Path := _TBUI_NewPath()
	Source := Chr(0xFEFF) . 'future.root = 1 # old reader ignores this`n[settings]`npersonal.future.enabled = false`nowned=1`n'
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
		Unchanged := { Section: "settings.personal.future", Key: "enabled", Value: TOML_Bool(false) }
		Candidate := TOML_BuildUpdatedContent(Path, [Unchanged])
		AssertEqual("ok", Candidate["status"], "a strict semantic destination already carries the desired value")
		Assert(StrCompare(Source, Candidate["content"], true) == 0)
		AssertTrue(TOML_BatchWrite(Path, [Unchanged]))
		AssertTrue(FSUtf8ExactMatches(Path, Source))
		for Update in [{ Section: "future", Key: "root", Delete: 1 },
			{ Section: "settings.personal.future", Key: "enabled", Delete: 1 },
			{ Section: "settings.personal.future", Key: "enabled", Value: TOML_Bool(true) }] {
			AssertEqual("error", TOML_BuildUpdatedContent(Path, [Update])["status"])
			AssertFalse(TOML_BatchWrite(Path, [Update]), "an unaddressable semantic change cannot be called a flat no-op")
			AssertTrue(FSUtf8ExactMatches(Path, Source))
		}
		AssertEqual("error", TOML_BuildUpdatedContent(Path, [], ["future"])["status"],
			"replacing an ignored root namespace is a real semantic deletion")
		AssertFalse(TOML_BatchWrite(Path, [], ["future"]))
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally FSDelete(Path)
}
Test("toml writer admission: semantic no-ops do not hide ignored-root deletes or exact-subtree loss (toml-writer-document)",
	_TBUI_SemanticDestinationsCannotHideEffects)
