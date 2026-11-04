; tests/meta/corpus/test_corpus_updater_release_parser.ahk

; ==============================================================================
; MODULE: Updater Release Parser Corpus Consumer (Windows / AHK)
; DESCRIPTION:
; Loads the cross-driver GitHub release JSON parser corpus from
; _shared/tests/corpus/updater/release_parser_vectors.json and replays each
; vector through the AHK updater parser functions (Updater_ParseTagName,
; Updater_ParseBody, _Updater_ParsePrerelease, _Updater_SplitReleasesArray),
; then asserts the output matches the expected golden values.
;
; The AHK driver cannot require Lua modules, so its parser functions in
; modules/updater/core.ahk are hand-maintained. This test pins them against the
; same golden vectors as the macOS and Linux Lua tests so any divergence is
; caught. The contract_* vectors carry the shared Lua metadata contract: each
; field is the selected release object's own, decoded once by the strict JSON
; owner, and a release list splits into exact raw spans of root objects only.
;
; parse_asset_url is NOT tested here because the AHK _Updater_FindAsset
; uses a structurally different algorithm (finds the "assets" array first,
; then walks within it) — the shared Lua module walks all {} pairs. Both
; produce the same result for valid GitHub JSON, but a direct vector
; comparison would test different algorithms, not parser parity.
; ==============================================================================

#Requires AutoHotkey v2.0

; ── Corpus path resolution ──────────────────────────────────────────────────
_URPC_LoadCorpus() {
	global _SharedDir
	if !IsSet(_SharedDir)
		return ""
	Path := _SharedDir . "\tests\corpus\updater\release_parser_vectors.json"
	if !FileExist(Path)
		return ""
	return FileRead(Path, "UTF-8")
}

_URPC_ParseJson(Raw) {
	if Raw = ""
		return ""
	try return JsonParse(Raw)
	catch
		return ""
}

; ── Corpus integrity ─────────────────────────────────────────────────────────

_URPC_Integrity() {
	Raw := _URPC_LoadCorpus()
	AssertTrue(Raw != "", "corpus file must be readable")
	Data := _URPC_ParseJson(Raw)
	AssertTrue(Data != "", "corpus JSON must be parseable")
	AssertTrue(Data.Has("vectors"), "corpus must have a vectors array")
	AssertTrue(Data["vectors"].Length > 0, "corpus must have at least one vector")
	for _, V in Data["vectors"] {
		AssertTrue(V.Has("id") && V["id"] != "", "vector missing id")
		AssertTrue(V.Has("category"), "vector missing category")
	}
}
Test("corpus:up-rp: corpus file is readable and every vector has required fields", _URPC_Integrity)

; Replays every vector of one category before failing, so a red run names
; each divergent vector instead of only the first.
_URPC_Replay(Category, Parse) {
	Data := _URPC_ParseJson(_URPC_LoadCorpus())
	AssertTrue(Data is Map, "corpus JSON must be parseable")
	Failures := [], Count := 0
	for _, V in Data["vectors"] {
		if V["category"] != Category
			continue
		Count += 1
		Input := V["input"].Has("json") ? V["input"]["json"] : V["input"]["body"]
		if !(Input is String)
			Input := ""
		try _URPC_CheckVector(Category, V, Parse.Call(Input))
		catch as Err
			Failures.Push(Err.Message)
	}
	AssertTrue(Count > 0, Category . ": the corpus must hold vectors of this category")
	Report := ""
	for Message in Failures
		Report .= (Report == "" ? "" : " | ") . Message
	AssertEqual(0, Failures.Length, Failures.Length . " of " . Count . " " . Category . " vectors diverge: " . Report)
}

_URPC_CheckVector(Category, V, Result) {
	if Category != "split_releases_array" {
		AssertEqual(V["expected"], Result, V["id"] . ": " . Category . " mismatch")
		return
	}
	AssertEqual(V["expected_count"], Result.Length, V["id"] . ": split count mismatch")
	; Exact raw spans and publication order, where the vector pins them.
	if V.Has("expected_spans") {
		for Index, Span in V["expected_spans"]
			AssertEqual(Span, Result[Index], V["id"] . ": split span " . Index . " must keep its exact raw bytes")
	}
}

Test("corpus:up-rp: parse_tag vectors match golden values", _URPC_Replay.Bind("parse_tag", Updater_ParseTagName))
Test("corpus:up-rp: parse_notes vectors match golden values", _URPC_Replay.Bind("parse_notes", Updater_ParseBody))
Test("corpus:up-rp: parse_prerelease_flag vectors match golden values",
	_URPC_Replay.Bind("parse_prerelease_flag", _Updater_ParsePrerelease))
Test("corpus:up-rp: split_releases_array vectors match golden values",
	_URPC_Replay.Bind("split_releases_array", _Updater_SplitReleasesArray))
Test("corpus:up-rp: parse_html_url vectors match golden values", _URPC_Replay.Bind("parse_html_url", _Updater_ParseHtmlUrl))
Test("corpus:up-rp: parse_published_at vectors match golden values",
	_URPC_Replay.Bind("parse_published_at", _Updater_ParsePublishedAt))
