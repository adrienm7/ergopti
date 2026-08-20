; tests/meta/test_strict_canon_does_not_drop_stale_keys.ahk

; ==============================================================================
; MODULE: Canonical Batch Writer Ownership Meta Test
; DESCRIPTION:
; TOML_BatchWrite already renders the complete merged document in canonical
; section/key order. Calling SaveFullConfig afterward was both redundant and
; unsafe: candidate-first callers had not published their globals yet, so the
; nested full save serialized stale state over the successful targeted commit.
; This guard pins the one-writer contract and the merge/canonical primitives.
; ==============================================================================

#Requires AutoHotkey v2.0




_SCDD_BatchWriterIsCanonicalAndNonReentrant() {
	Wrapper := _DriverFuncBody("TOML_BatchWrite")
	Body := _DriverFuncBody("_TOML_BatchWriteImpl")
	Assert(Wrapper != "" && Body != "",
		"TOML_BatchWrite and its shared renderer must exist in toml_helpers.ahk")
	Assert(InStr(Wrapper,
		'_TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, "write")') > 0,
		"the public writer must route through the canonical implementation in write mode")
	Assert(InStr(Body, "Cached := ParseTomlFile(Path)") > 0
		or InStr(Body,
			'(BuildOnly ? TOML_ParseFreshFile(Path) : ParseTomlFile(Path))') > 0,
		"write mode must still obtain the complete on-disk document")
	Assert(InStr(Body, "Sections := Cached.Clone()") > 0,
		"the writer must merge updates into a detached copy of the complete on-disk document")
	Assert(InStr(Body, "SortedSections := SortArray(SortedSections)") > 0
		and InStr(Body, "SortedKeys := SortArray(SortedKeys)") > 0,
		"the one atomic write must itself render canonical section and key order")
	Assert(InStr(Body, "SaveFullConfig") = 0
		and InStr(Body, "TOML_RunStrictCanonicalization") = 0,
		"a low-level targeted write must never re-enter stale live globals through a second full save")
}
Test("toml_helpers: canonical batch writer never re-enters stale full state",
	_SCDD_BatchWriterIsCanonicalAndNonReentrant)
