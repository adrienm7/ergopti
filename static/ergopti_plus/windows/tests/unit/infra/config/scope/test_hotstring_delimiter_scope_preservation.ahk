; tests/unit/infra/config/scope/test_hotstring_delimiter_scope_preservation.ahk

; ==============================================================================
; MODULE: Hotstring Delimiter Scope Preservation Tests
; DESCRIPTION:
; Exercises admitted real-file scope publication and exact compensating rollback.
; The shipped delimiters are config.toml leaves (state and consumption): both
; modes delete exactly those, and the user's own records, their states and
; unknown entries are kept as stored.
; ==============================================================================

_HSDP_Has(Config, Section, Key) {
	return Config.Has(Section) && Config[Section].Has(Key)
}

_HotstringsScopeShippedDelimiters() {
	Suffix := '[hotstrings.terminator_states]`nspace = false`nslash = true`ncustom_x = false`nretired = true`n'
		. '[hotstrings.terminator_consume]`ncomma = true`nstar = false`ncustom_x = true`n'
		. '[[hotstrings.terminators]]`nkey = "custom_x"`nchar = "¤"`nlabel = "X"`nconsume = true`n'
	Fixture := _HotstringsScopeFixture(1, Suffix)
	Bundle := 0, Refusal := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed
		Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		for Mode in ["recommended", "clear"] {
			Fixture.options["stamp"] := "shipped-delimiters-" . Mode
			Receipt := HotstringsScopeApply(Mode, Fixture.options)
			AssertEqual("pending", Receipt["status"])
			Config := TOML_ParseFreshFileTyped(Fixture.path)
			AssertFalse(_HSDP_Has(Config, "hotstrings.terminator_states", "space"), "a shipped state is deleted")
			AssertFalse(_HSDP_Has(Config, "hotstrings.terminator_states", "slash"), "a shipped state is deleted")
			AssertFalse(_HSDP_Has(Config, "hotstrings.terminator_consume", "comma"), "a shipped consumption is deleted")
			AssertFalse(_HSDP_Has(Config, "hotstrings.terminator_consume", "star"), "a shipped consumption is deleted")
			AssertEqual(false, Config["hotstrings.terminator_states"]["custom_x"].Value, "a personal state is user data")
			AssertEqual(true, Config["hotstrings.terminator_states"]["retired"].Value, "cleanup still owns the outdated entry")
			AssertEqual(true, Config["hotstrings.terminator_consume"]["custom_x"].Value, "a personal entry keeps its consume leaf")
			AssertContains(FSReadUtf8Exact(Fixture.path), 'key = "custom_x"', "the personal record is kept")
			AssertEqual("keep", Config["private"]["credential"])
			for Path in [Fixture.path, Fixture.overrides, Fixture.personal[1]]
				Assert(!_ConfigWriteLeaseTryAcquire(Path, "concurrent-delimiter-editor"))
			Refusal.Call("native refusal after delimiter preparation")
			AssertEqual("refused", Receipt["status"])
			AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path), "a refusal restores the exact bytes")
			AssertEqual(Fixture.overrideSource, FSReadUtf8Exact(Fixture.overrides))
			AssertEqual(Fixture.personalSource, FSReadUtf8Exact(Fixture.personal[1]))
		}
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("hotstrings-scope: both modes reset the shipped delimiters, keep personal ones and rollback on refusal",
	_HotstringsScopeShippedDelimiters)

_HotstringsScopeDelimiterRowsList() {
	Fixture := _ScopeOwnerFixture('[hotstrings]`nunknown = "keep"`n'
		. '[hotstrings.terminator_states]`nzzz = true`nslash = true`nspace = false`ncustom_x = false`n'
		. '[hotstrings.terminator_consume]`nstar = false`nunknown_key = true`n')
	try {
		Rows := _HotstringsScopeDelimiterRows(Fixture.path)
		Seen := []
		for Row in Rows {
			AssertEqual(1, Row.Delete, "every row deletes")
			Seen.Push(Row.Section . "/" . Row.Key)
		}
		; AssertEqual compares by identity, which two distinct Arrays never share.
		AssertEqual("hotstrings.terminator_states/slash,hotstrings.terminator_states/space,"
			. "hotstrings.terminator_consume/star", ArrayJoin(Seen, ","),
			"only the shipped keys, states first, each table in key order")
		AssertEqual(0, _HotstringsScopeDelimiterRows(Fixture.directory . "\absent.toml").Length,
			"no configuration holds no leaf")
	} finally _ScopeOwnerCleanup(Fixture)
}
Test("hotstrings-scope: the delimiter rows list only the shipped leaves a configuration holds",
	_HotstringsScopeDelimiterRowsList)
