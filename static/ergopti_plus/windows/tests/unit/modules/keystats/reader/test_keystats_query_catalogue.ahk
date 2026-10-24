; tests/unit/modules/keystats/reader/test_keystats_query_catalogue.ahk

; ==============================================================================
; MODULE: Keystats Named-Query Catalogue Tests (Windows)
; DESCRIPTION:
; The manifest reader renders eleven of its statements from the shared query
; catalogue (_shared/data/db/queries.sql), compiled into
; _generated/keystats_queries.ahk: the statements macOS and Linux run too.
;
; FEATURES & RATIONALE:
; 1. Results, not text: the realistic fixture the JS catalogue test runs is
;    loaded into the real SQLite DLL, and every rendered query must return the
;    expected rows recorded in query_results.json. Rows whose text holds a NUL
;    byte are removed first, because how a binding reads such text is a
;    property of the binding, not of the query.
; 2. The renderer refuses an unknown name and a wrong parameter set.
; 3. Each reader function renders its query by name instead of retyping it.
; ==============================================================================

; The catalogue queries the Windows manifest reader renders, by reader function.
_KLQCat_ReaderQueries() {
	return Map(
		"KLR__SumAppDay", "manifest.app_day",
		"KLR__SumBuckets", "manifest.buckets",
		"KLR__SumBurst", "manifest.burst",
		"KLR__SumSession", "manifest.session",
		"KLR__SumCharsClass", "manifest.chars_class",
		"KLR__SumErrors", "manifest.errors",
		"KLR__SumLayouts", "manifest.layouts",
		"KLR__SumKcHold", "manifest.kc_hold",
		"KLR__SumTitles", "manifest.titles",
		"KLR__SumHourly", "manifest.hourly",
		"KLR__SumHourlyMin5", "manifest.hourly_min5")
}

; One comparable line per row: keys in Map order, numbers at a fixed precision
; (SQLite returns 300.0 where JSON says 300), SQL NULL and JSON null alike.
_KLQCat_Canonical(Row) {
	Text := ""
	for Key, Value in Row {
		if (Value == JSON_NULL)
			Value := ""
		Text .= Key . "=" . ((Value != "" && IsNumber(Value)) ? Format("{:.6f}", Value) : "s:" . Value) . Chr(1)
	}
	return Text
}

_KLQCat_HasNul(Row) {
	for Key, Value in Row
		if (Value is String) && InStr(Value, Chr(0))
			return true
	return false
}

_KLQCat_FixtureReturnsCatalogueRows() {
	global _SharedDir
	db := SQLite_Open(":memory:")
	AssertTrue(db != 0, "the catalogue fixture must open an in-memory DB")
	try {
		AssertTrue(KLR_LoadSchema(db), "the fixture uses the canonical production schema")
		AssertTrue(SQLite_Exec(db, FSReadStrict(_SharedDir . "\tests\corpus\keystats\query_fixture.sql")),
			"the shared fixture loads")
		Strip := ""
		for Table, Columns in Map("agg_app_day", ["app", "category"], "agg_app_day_buckets", ["app"],
				"agg_app_day_burst", ["app"], "agg_app_day_session", ["app"],
				"agg_app_day_chars_class", ["app"], "agg_app_day_errors", ["app"],
				"agg_app_day_layouts", ["app", "layout"], "agg_app_day_kc_hold", ["app"],
				"agg_app_day_titles", ["app", "title"], "agg_app_day_hourly", ["app"],
				"agg_app_day_hourly_min5", ["app"]) {
			for Column in Columns
				Strip .= "DELETE FROM " . Table . " WHERE instr(CAST(" . Column . " AS BLOB), x'00') > 0;"
		}
		AssertTrue(SQLite_Exec(db, Strip), "NUL-bearing rows are removed")
		Expected := JsonParse(FSReadStrict(_SharedDir . "\tests\corpus\keystats\query_results.json"))
		for Fn, Name in _KLQCat_ReaderQueries() {
			for Filter, Where in Expected["filters"] {
				Got := Map()
				for Row in SQLite_Query(db, KeystatsQuery(Name, Map("where", Where))) {
					Key := _KLQCat_Canonical(Row)
					Got[Key] := Got.Get(Key, 0) + 1
				}
				Want := Map()
				for Row in Expected["queries"][Name][Filter]["cli_json"] {
					if _KLQCat_HasNul(Row)
						continue
					Key := _KLQCat_Canonical(Row)
					Want[Key] := Want.Get(Key, 0) + 1
				}
				AssertTrue(Want.Count > 0, Name . " " . Filter . " must compare at least one row")
				AssertEqual(Want.Count, Got.Count, Name . " " . Filter . ": distinct rows")
				for Key, Count in Want
					AssertEqual(Count, Got.Get(Key, 0), Name . " " . Filter . ": " . StrReplace(Key, Chr(1), " "))
			}
		}
	} finally {
		SQLite_Close(db)
	}
}
Test("Keystats query catalogue: the fixture returns the expected rows (keystats-query-catalogue)",
	_KLQCat_FixtureReturnsCatalogueRows)

_KLQCat_RendererRefusals() {
	Cases := [
		["manifest.unknown", Map("where", "")],
		["manifest.app_day", Map()],
		["manifest.app_day", Map("where", 1)],
		["manifest.app_day", Map("where", "", "extra", "")]]
	for Case in Cases {
		Refused := false
		try KeystatsQuery(Case[1], Case[2])
		catch ValueError
			Refused := true
		AssertTrue(Refused, "KeystatsQuery must refuse case " . A_Index . " rather than render other SQL")
	}
	Sql := KeystatsQuery("manifest.titles", Map("where", " WHERE app = '%1 {{where}}'"))
	AssertTrue(InStr(Sql, " WHERE app = '%1 {{where}}' GROUP BY") > 0, "the filter is spliced verbatim")
}
Test("Keystats query catalogue: the renderer refuses misuse (keystats-query-catalogue)",
	_KLQCat_RendererRefusals)

_KLQCat_ReaderRendersByName() {
	for Fn, Name in _KLQCat_ReaderQueries() {
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . " must be locatable")
		Assert(InStr(Body, 'KLR_ManifestSql("' . Name . '"') > 0, Fn . " must render " . Name . " by name")
		Assert(InStr(Body, "SELECT ") == 0, Fn . " must not retype the catalogue SQL")
	}
}
Test("Keystats query catalogue: the manifest reader renders by name (keystats-query-catalogue)",
	_KLQCat_ReaderRendersByName)
