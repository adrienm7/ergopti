; tests/unit/test_hotstring_delimiter_scope_preservation.ahk

; ==============================================================================
; MODULE: Hotstring Delimiter Scope Preservation Tests
; DESCRIPTION:
; Exercises admitted real-file scope publication and exact compensating rollback.
; Personal delimiter strings come from stored bytes, not the live engine cache;
; malformed values refuse publication rather than losing user-owned characters.
; ==============================================================================

_HotstringsScopePersonalDelimiters() {
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	Saved := { word: _HotstringsWordDelimiters, consumed: _HotstringsConsumedDelimiters }
	Fixture := _HotstringsScopeFixture()
	Fixture.overrideSource := StrReplace(Fixture.overrideSource, 'word_delimiters = "!"',
		'word_delimiters = "/¤😀😃😀"`nconsumed_delimiters = "/¤🔒"')
	Assert(FSWriteDurable(Fixture.overrides, Fixture.overrideSource))
	; A stale live/UI snapshot must never define the admitted persistent input.
	_HotstringsWordDelimiters := "stale", _HotstringsConsumedDelimiters := "stale"
	Bundle := 0, Refusal := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed
		Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		for Mode in ["recommended", "clear"] {
			Fixture.options["stamp"] := "personal-delimiters-" . Mode
			Receipt := HotstringsScopeApply(Mode, Fixture.options)
			AssertEqual("pending", Receipt["status"])
			Overrides := TOML_ParseFreshFile(Fixture.overrides)
			AssertEqual(" `t`r`n★,;.!?:¤😀😃😀", Overrides["__global__"]["word_delimiters"],
				"both modes restore shipped defaults and retain exact admitted personal characters")
			AssertEqual("★¤🔒", Overrides["__global__"]["consumed_delimiters"],
				"a disabled custom consumed marker must not become a word delimiter")
			AssertEqual("keep", Overrides["__global__"]["unknown"])
			AssertEqual(9, Overrides["foreign"]["delay"])
			Config := TOML_ParseFreshFile(Fixture.path)
			AssertEqual("keep", Config["private"]["credential"])
			AssertEqual(true, Config["hotstrings"]["preview_ai_enabled"])
			AssertContains(FSReadUtf8Exact(Fixture.personal[1]), '"abc" = "replacement"')
			for Path in [Fixture.path, Fixture.overrides, Fixture.personal[1]]
				Assert(!_ConfigWriteLeaseTryAcquire(Path, "concurrent-delimiter-editor"))
			AssertEqual("stale", _HotstringsWordDelimiters,
				"the journal must not publish live state before replacement acknowledgement")
			Refusal.Call("native refusal after personal delimiter preparation")
			AssertEqual("refused", Receipt["status"])
			AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
			AssertEqual(Fixture.overrideSource, FSReadUtf8Exact(Fixture.overrides))
			AssertEqual(Fixture.personalSource, FSReadUtf8Exact(Fixture.personal[1]))
			AssertEqual("stale", _HotstringsConsumedDelimiters)
		}
	} finally {
		_HotstringsWordDelimiters := Saved.word
		_HotstringsConsumedDelimiters := Saved.consumed
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("hotstrings-scope: both modes preserve fresh personal delimiters and rollback all stores on refusal",
	_HotstringsScopePersonalDelimiters)

_HotstringsScopeMalformedDelimiterRefuses() {
	Fixture := _HotstringsScopeFixture()
	Fixture.overrideSource := StrReplace(Fixture.overrideSource,
		'word_delimiters = "!"', 'word_delimiters = ["¤"]')
	Assert(FSWriteDurable(Fixture.overrides, Fixture.overrideSource))
	Launches := 0
	Launch(*) {
		Launches += 1
		return false
	}
	Fixture.options["reload"] := Launch
	try {
		Receipt := HotstringsScopeApply("recommended", Fixture.options)
		AssertEqual("refused", Receipt["status"], "malformed owned values must not be guessed or erased")
		AssertEqual(0, Launches)
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		AssertEqual(Fixture.overrideSource, FSReadUtf8Exact(Fixture.overrides))
		AssertEqual(Fixture.personalSource, FSReadUtf8Exact(Fixture.personal[1]))
	} finally _ScopeOwnerCleanup(Fixture)
}
Test("hotstrings-scope: malformed stored delimiter values refuse before publication",
	_HotstringsScopeMalformedDelimiterRefuses)
