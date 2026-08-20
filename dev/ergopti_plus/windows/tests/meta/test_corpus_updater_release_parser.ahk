; tests/meta/test_corpus_updater_release_parser.ahk

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
; same golden vectors as the macOS Lua test so any divergence is caught.
;
; parse_asset_url is NOT tested here because the AHK _Updater_FindAssetUrl
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

; ── parse_tag vectors ────────────────────────────────────────────────────────

_URPC_ParseTag() {
	Raw := _URPC_LoadCorpus()
	Data := _URPC_ParseJson(Raw)
	for _, V in Data["vectors"] {
		if V["category"] != "parse_tag"
			continue
		Body := V["input"]["body"]
		if !(Body is String)
			Body := ""
		Result := Updater_ParseTagName(Body)
		AssertEqual(V["expected"], Result, V["id"] . ": parse_tag mismatch")
	}
}
Test("corpus:up-rp: parse_tag vectors match golden values", _URPC_ParseTag)

; ── parse_notes vectors ──────────────────────────────────────────────────────

_URPC_ParseNotes() {
	Raw := _URPC_LoadCorpus()
	Data := _URPC_ParseJson(Raw)
	for _, V in Data["vectors"] {
		if V["category"] != "parse_notes"
			continue
		Body := V["input"]["body"]
		if !(Body is String)
			Body := ""
		Result := Updater_ParseBody(Body)
		AssertEqual(V["expected"], Result, V["id"] . ": parse_notes mismatch")
	}
}
Test("corpus:up-rp: parse_notes vectors match golden values", _URPC_ParseNotes)

; ── parse_prerelease_flag vectors ────────────────────────────────────────────

_URPC_ParsePrerelease() {
	Raw := _URPC_LoadCorpus()
	Data := _URPC_ParseJson(Raw)
	for _, V in Data["vectors"] {
		if V["category"] != "parse_prerelease_flag"
			continue
		Body := V["input"]["body"]
		if !(Body is String)
			Body := ""
		Result := _Updater_ParsePrerelease(Body)
		AssertEqual(V["expected"], Result, V["id"] . ": parse_prerelease_flag mismatch")
	}
}
Test("corpus:up-rp: parse_prerelease_flag vectors match golden values", _URPC_ParsePrerelease)

; ── split_releases_array vectors ─────────────────────────────────────────────

_URPC_SplitReleases() {
	Raw := _URPC_LoadCorpus()
	Data := _URPC_ParseJson(Raw)
	for _, V in Data["vectors"] {
		if V["category"] != "split_releases_array"
			continue
		Json := V["input"]["json"]
		if !(Json is String)
			Json := ""
		Chunks := _Updater_SplitReleasesArray(Json)
		AssertEqual(V["expected_count"], Chunks.Length, V["id"] . ": split count mismatch")
	}
}
Test("corpus:up-rp: split_releases_array vectors match golden values", _URPC_SplitReleases)

; ── parse_html_url vectors ───────────────────────────────────────────────────

_URPC_ParseHtmlUrl() {
	Raw := _URPC_LoadCorpus()
	Data := _URPC_ParseJson(Raw)
	for _, V in Data["vectors"] {
		if V["category"] != "parse_html_url"
			continue
		Body := V["input"]["body"]
		if !(Body is String)
			Body := ""
		Result := _Updater_ParseHtmlUrl(Body)
		AssertEqual(V["expected"], Result, V["id"] . ": parse_html_url mismatch")
	}
}
Test("corpus:up-rp: parse_html_url vectors match golden values", _URPC_ParseHtmlUrl)

; ── parse_published_at vectors ───────────────────────────────────────────────

_URPC_ParsePublishedAt() {
	Raw := _URPC_LoadCorpus()
	Data := _URPC_ParseJson(Raw)
	for _, V in Data["vectors"] {
		if V["category"] != "parse_published_at"
			continue
		Body := V["input"]["body"]
		if !(Body is String)
			Body := ""
		Result := _Updater_ParsePublishedAt(Body)
		AssertEqual(V["expected"], Result, V["id"] . ": parse_published_at mismatch")
	}
}
Test("corpus:up-rp: parse_published_at vectors match golden values", _URPC_ParsePublishedAt)
