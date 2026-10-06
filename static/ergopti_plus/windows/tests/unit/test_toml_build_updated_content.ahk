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
	Seed := '[existing]`non = true # enabled`nyes = true # affirmative`noff = false`nzero = 0`none = 1`n'
	; This handwritten complete image pins source order/comments and the new
	; section's canonical separation, independently of the production renderer.
	Expected := Chr(0xFEFF) . '[existing]`non = true # enabled`nyes = true # affirmative`noff = false`nzero = 0`none = 1`n`n`n`n`n`n[script]`nlocale = "fr"`n'
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
		for Content in [Candidate["content"], FSReadUtf8Exact(Path)] {
			AssertEqual(Expected, Content, "both candidate and publication preserve the complete unowned source image")
			for Key, Literal in Map("on", "true # enabled", "yes", "true # affirmative", "off", "false", "zero", "0", "one", "1")
				AssertTrue(RegExMatch(Content, "m)^" . Key . " = " . Literal . "$"),
					"unrelated updates must retain the literal type and original comment of " . Key)
			Typed := TOML_ParseDocument(Content)
			for Key, Value in Map("on", 1, "yes", 1, "off", 0) {
				AssertTrue(Typed["existing"][Key] is TOML_Bool, "the real document reader distinguishes Boolean " . Key . " from numbers")
				AssertEqual(Value, Typed["existing"][Key].Value)
			}
			for Key, Value in Map("zero", 0, "one", 1) {
				AssertTrue(Typed["existing"][Key] is Integer, "numeric " . Key . " must not acquire Boolean intent")
				AssertEqual(Value, Typed["existing"][Key])
			}
			AssertEqual("fr", Typed["script"]["locale"], "the actual requested update is present beside the retained source")
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





; Ordinary updates own exactly their declared assignment rows. The independent
; shared corpus retains handwritten foreign bytes instead of serializer output.
_TBUI_ForeignSourceVector(Vector) {
	Path := _TBUI_NewPath(), Source := Chr(0xFEFF) . Vector["source"]
	Updates := []
	for Row in Vector["updates"] {
		Update := { Section: Row["section"], Key: Row["key"] }
		if Row["kind"] == "delete" {
			AssertEqual(true, Row["delete"])
			Update.Delete := 1
		} else {
			AssertTrue(Row["kind"] == "boolean" || Row["kind"] == "integer")
			Update.Value := Row["kind"] == "boolean" ? TOML_Bool(Row["value"]) : Row["value"]
		}
		Updates.Push(Update)
	}
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
		Candidate := TOML_BuildUpdatedContent(Path, Updates)
		AssertEqual("ok", Candidate["status"], "the source-retaining candidate must be admitted")
		if Vector.Has("lua_admission") {
			AssertEqual("refused_unaddressable", Vector["lua_admission"],
				"the shared corpus declares the distinct existing Lua refusal boundary")
			AssertTrue(Vector.Has("lua_refusal"))
		}
		if Vector.Has("windows_canonical")
			AssertEqual(Chr(0xFEFF) . Vector["windows_canonical"], Candidate["content"],
				"a fully owned source without foreign comments keeps the canonical serializer contract")
		AssertTrue(FSUtf8ExactMatches(Path, Source), "detached preparation owns no source writes")
		AssertTrue(TOML_BatchWrite(Path, Updates), "the real ordinary writer must acknowledge publication")
		AssertTrue(FSUtf8ExactMatches(Path, Candidate["content"]),
			"detached and ordinary modes must publish the same qualified bytes")
		for Raw in Vector["retained"] {
			AssertContains(Candidate["content"], Raw,
				"unowned records retain the independent handwritten source bytes")
			AssertContains(FSReadUtf8Exact(Path), Raw,
				"publication preserves those same foreign physical records")
		}
		Document := TOML_ParseDocument(Candidate["content"])
		for Expected in Vector["owned"] {
			AssertTrue(Expected["kind"] == "boolean" || Expected["kind"] == "integer")
			Value := Expected["kind"] == "boolean" ? TOML_Bool(Expected["value"]) : Expected["value"]
			AssertTrue(TOML_SameValue(Document[Expected["section"]][Expected["key"]], Value),
				"the complete candidate must contain the independently requested owned value")
		}
	} finally FSDelete(Path)
}

_TBUI_RegisterForeignSourceVectors() {
	global _SharedDir
	Fixture := JsonParse(FileRead(_SharedDir . "\tests\corpus\config_source_preservation\vectors.json", "UTF-8"))
	for Vector in Fixture["cases"]
		Test("toml-foreign-source " . Vector["id"], _TBUI_ForeignSourceVector.Bind(Vector))
}
_TBUI_RegisterForeignSourceVectors()

_TBUI_OwnedLastWinsRetainsForeignSource() {
	Source := '# unowned source anchor`n[settings]`nknown = 0`nfuture = "keep" # retained`n'
	Updates := [
		{ Section: "settings", Key: "known", Value: 1 },
		{ Section: "settings", Key: "known", Delete: 1 },
		{ Section: "settings", Key: "known", Value: 2 },
		{ Section: "missing", Key: "absent", Delete: 1 }
	]
	Path := _TBUI_NewPath()
	try {
		AssertTrue(FSWriteCreateDurable(Path, Chr(0xFEFF) . Source) == 1)
		Candidate := TOML_BuildUpdatedContent(Path, Updates)
		AssertEqual("ok", Candidate["status"])
		AssertContains(Candidate["content"], "known = 2`n", "the last explicit row keeps its existing ownership")
		AssertContains(Candidate["content"], '# unowned source anchor`n')
		AssertContains(Candidate["content"], 'future = "keep" # retained`n')
		AssertFalse(InStr(Candidate["content"], "[missing]"), "an absent neutral deletion owns no new header")
		AssertTrue(TOML_BatchWrite(Path, Updates))
		AssertTrue(FSUtf8ExactMatches(Path, Candidate["content"]))
	} finally FSDelete(Path)
}
Test("toml physical ownership preserves last-wins and absent deletion semantics", _TBUI_OwnedLastWinsRetainsForeignSource)





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
			Key: "owned", Value: 1, Preservable: true }
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
				if Vector.HasOwnProp("Preservable") {
					AssertEqual("ok", Candidate["status"], "foreign arrays survive an independently owned sibling change")
					_TAOT_AssertFuture(Candidate["content"])
					_TAOT_AssertRequested(Candidate["content"], Update)
				} else {
					AssertEqual("error", Candidate["status"], "no unowned namespace may disappear: " . Vector.Id)
					AssertFalse(Candidate.Has("source_content"), "no refused candidate gains publication authority")
				}
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





; =======================================================
; =======================================================
; ======= 3/ Foreign Table-Array Writer Admission =======
; =======================================================
; =======================================================

_TAOT_Source() {
	return '[layout]`nenabled = true # independently owned`n'
		. '[["hotstrings"."terminators"]] # first record`nkey = "currency"`nchar = "¤"`nlabel = "Currency"`nconsume = true`nmetadata = { opaque = "keep", count = 7 }`n'
		. '[[hotstrings.terminators]] # second record`nkey = "smile"`nchar = "😀"`nlabel = "Smile"`nconsume = false`n'
		. '[private]`nvalue = "leave exactly" # untouched`n'
}

_TAOT_AssertFuture(Content) {
	Document := TOML_ParseDocument(Content)
	AssertEqual(2, Document["future"].Length, "both independent table-array records must survive")
	AssertEqual("first", Document["future"][1]["name"])
	AssertEqual("second", Document["future"][2]["name"])
	AssertContains(Content, '[[future]]`nname="first"`n[[future]]`nname="second"`n',
		"the original foreign lexical spans must remain byte-for-byte present")
}

_TAOT_AssertRequested(Content, Update) {
	Document := TOML_ParseDocument(Content), Entries := Document["settings"]
	if Update.HasOwnProp("Delete") && Update.Delete == 1
		AssertFalse(Entries.Has(Update.Key), "the independently requested deletion must take effect")
	else
		AssertTrue(TOML_SameValue(Update.Value, Entries[Update.Key]), "the requested sibling value must take effect")
}

_TAOT_DetachedAndNative() {
	Path := _TBUI_NewPath(), FixtureSource := Chr(0xFEFF) . _TAOT_Source()
	try {
		AssertTrue(FSWriteCreateDurable(Path, FixtureSource) == 1)
		Cached := ParseTomlFile(Path)
		Updates := [{ Section: "layout", Key: "enabled", Value: TOML_Bool(false) }]
		Candidate := TOML_BuildUpdatedContent(Path, Updates)
		AssertEqual("ok", Candidate["status"], "a representable sibling must not borrow the collapsed array row")
		AssertEqual(FixtureSource, Candidate["source_content"], "the complete old source still binds later publication")
		AssertTrue(FSUtf8ExactMatches(Path, FixtureSource), "detached preparation has no disk effects")
		AssertTrue(Cached == ParseTomlFile(Path), "detached preparation retains the live cached receipt")
		Document := TOML_ParseDocument(Candidate["content"])
		AssertTrue(Document["layout"]["enabled"] is TOML_Bool)
		AssertEqual(false, Document["layout"]["enabled"].Value)
		AssertEqual(2, Document["hotstrings"]["terminators"].Length)
		AssertEqual("currency", Document["hotstrings"]["terminators"][1]["key"])
		AssertEqual("¤", Document["hotstrings"]["terminators"][1]["char"])
		AssertEqual(7, Document["hotstrings"]["terminators"][1]["metadata"]["count"])
		AssertEqual("keep", Document["hotstrings"]["terminators"][1]["metadata"]["opaque"])
		AssertEqual("😀", Document["hotstrings"]["terminators"][2]["char"])
		AssertContains(Candidate["content"], SubStr(_TAOT_Source(), InStr(_TAOT_Source(), '[["hotstrings"')),
			"foreign record and private-tail spans must remain exact")
		AssertTrue(TOML_BatchWrite(Path, Updates))
		AssertTrue(FSUtf8ExactMatches(Path, Candidate["content"]), "ordinary publication equals the qualified detached image")
	} finally FSDelete(Path)
}
Test("toml-aot-sibling: actual detached and native sibling update preserves custom record generations and unknown spans", _TAOT_DetachedAndNative)

_TAOT_NestedArray() {
	Path := _TBUI_NewPath()
	FixtureSource := '[[future]] # outer first`nname="first"`n[[future.children]] # child one`nvalue="one"`n[[future.children]]`nvalue="two"`n[[future]]`nname="second"`n[settings]`nowned=1`n'
	try {
		AssertTrue(FSWriteDurable(Path, FixtureSource))
		Candidate := TOML_BuildUpdatedContent(Path, [{ Section: "settings", Key: "owned", Value: 2 }])
		AssertEqual("ok", Candidate["status"], "nested arrays stay with their exact outer row")
		Document := TOML_ParseDocument(Candidate["content"])
		AssertEqual(2, Document["future"].Length)
		AssertEqual("first", Document["future"][1]["name"])
		AssertEqual(2, Document["future"][1]["children"].Length)
		AssertEqual("one", Document["future"][1]["children"][1]["value"])
		AssertEqual("two", Document["future"][1]["children"][2]["value"])
		AssertEqual("second", Document["future"][2]["name"])
		AssertEqual(2, Document["settings"]["owned"])
		AssertContains(Candidate["content"], SubStr(FixtureSource, 1, InStr(FixtureSource, "[settings]") - 1))
	} finally FSDelete(Path)
}
Test("toml-aot-sibling: nested table arrays retain outer record identity and exact lexical spans", _TAOT_NestedArray)

_TAOT_RefusedNamespace(Updates, Prefixes := []) {
	Path := _TBUI_NewPath(), FixtureSource := Chr(0xFEFF) . _TAOT_Source()
	try {
		AssertTrue(FSWriteCreateDurable(Path, FixtureSource) == 1)
		Candidate := TOML_BuildUpdatedContent(Path, Updates, Prefixes)
		AssertEqual("error", Candidate["status"], "a foreign table array cannot lend flat write authority")
		AssertFalse(Candidate.Has("source_content"))
		AssertFalse(TOML_BatchWrite(Path, Updates, Prefixes))
		AssertTrue(FSUtf8ExactMatches(Path, FixtureSource), "refusal must precede any physical replacement")
	} finally FSDelete(Path)
}
Test("toml-aot-sibling: direct collapsed-record mutation refuses without effects", _TAOT_RefusedNamespace.Bind([{ Section: "hotstrings.terminators", Key: "char", Value: "x" }]))
Test("toml-aot-sibling: native case alias cannot acquire a foreign record", _TAOT_RefusedNamespace.Bind([{ Section: "HOTSTRINGS.TERMINATORS", Key: "char", Value: "x" }]))
Test("toml-aot-sibling: replacing the array ancestor refuses without effects", _TAOT_RefusedNamespace.Bind([], ["hotstrings"]))
Test("toml-aot-sibling: replacing an array child refuses without effects", _TAOT_RefusedNamespace.Bind([], ["hotstrings.terminators.metadata"]))

_TAOT_IgnoredRootStillRefuses() {
	Path := _TBUI_NewPath(), FixtureSource := 'root.future = "keep"`n' . _TAOT_Source()
	try {
		AssertTrue(FSWriteDurable(Path, FixtureSource))
		Candidate := TOML_BuildUpdatedContent(Path, [{ Section: "layout", Key: "enabled", Value: TOML_Bool(false) }])
		AssertEqual("error", Candidate["status"], "the AOT partition cannot excuse a second unrepresented namespace")
		AssertFalse(TOML_BatchWrite(Path, [{ Section: "layout", Key: "enabled", Value: TOML_Bool(false) }]))
		AssertTrue(FSUtf8ExactMatches(Path, FixtureSource))
	} finally FSDelete(Path)
}
Test("toml-aot-sibling: an unrelated ignored root still refuses despite preserved array records", _TAOT_IgnoredRootStillRefuses)

_TAOT_SourceRace() {
	Path := _TBUI_NewPath(), FixtureSource := Chr(0xFEFF) . _TAOT_Source()
	Foreign := FixtureSource . '# exact independent concurrent writer`n'
	try {
		AssertTrue(FSWriteCreateDurable(Path, FixtureSource) == 1)
		ConcurrentValue := _TBUI_SourceMutatingBoolean(Path, Foreign)
		Candidate := TOML_BuildUpdatedContent(Path, [{ Section: "layout", Key: "enabled", Value: ConcurrentValue }])
		AssertTrue(ConcurrentValue.Calls > 0)
		AssertTrue(ConcurrentValue.WriteAccepted)
		AssertEqual("error", Candidate["status"], "foreign-record retention cannot bypass the old-source fence")
		AssertTrue(FSUtf8ExactMatches(Path, Foreign))
	} finally FSDelete(Path)
}
Test("toml-aot-sibling: actual concurrent source mutation still wins before publication", _TAOT_SourceRace)
