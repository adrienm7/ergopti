; static/drivers/autohotkey/tests/test_config.ahk

; ==============================================================================
; MODULE: Configuration Helpers Tests
; DESCRIPTION:
; Covers the INI-cache parser and accessors lifted into lib/ini_helpers.ahk.
; ==============================================================================




; ==========================
; ParseIniFile
; ==========================
TestCfg_MissingFile() {
	Result := ParseIniFile(A_ScriptDir . "\does_not_exist.ini")
	AssertEqual("Map", Type(Result))
	AssertEqual(0, Result.Count)
}
Test("ParseIniFile: missing file returns empty Map", TestCfg_MissingFile)

TestCfg_ParseSections() {
	TmpPath := A_ScriptDir . "\test_ini_parse.ini"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	FileAppend("[Section1]`r`nkey1=value1`r`nkey2=value2`r`n[Section2]`r`nkey3=value3`r`n",
		TmpPath, "UTF-8")
	Cache := ParseIniFile(TmpPath)
	AssertTrue(Cache.Has("Section1"))
	AssertTrue(Cache.Has("Section2"))
	AssertEqual("value1", Cache["Section1"]["key1"])
	AssertEqual("value2", Cache["Section1"]["key2"])
	AssertEqual("value3", Cache["Section2"]["key3"])
	FileDelete(TmpPath)
}
Test("ParseIniFile: parses sections and key/value pairs", TestCfg_ParseSections)

TestCfg_IgnoresMalformed() {
	TmpPath := A_ScriptDir . "\test_ini_noeq.ini"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	FileAppend("[S]`r`nbroken-line-without-eq`r`nkey=ok`r`n", TmpPath, "UTF-8")
	Cache := ParseIniFile(TmpPath)
	AssertEqual(1, Cache["S"].Count)
	AssertEqual("ok", Cache["S"]["key"])
	FileDelete(TmpPath)
}
Test("ParseIniFile: ignores lines without an equals sign", TestCfg_IgnoresMalformed)

TestCfg_TrimsKey() {
	TmpPath := A_ScriptDir . "\test_ini_trim.ini"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	FileAppend("[S]`r`n  key  =value`r`n", TmpPath, "UTF-8")
	Cache := ParseIniFile(TmpPath)
	AssertTrue(Cache["S"].Has("key"))
	AssertEqual("value", Cache["S"]["key"])
	FileDelete(TmpPath)
}
Test("ParseIniFile: trims whitespace around the key", TestCfg_TrimsKey)




; ==========================
; IniCacheGet
; ==========================
TestCfg_GetMissingSection() {
	C := Map()
	AssertEqual("default", IniCacheGet(C, "MissingSection", "key", "default"))
}
Test("IniCacheGet: returns the default when the section is missing",
	TestCfg_GetMissingSection)

TestCfg_GetMissingKey() {
	C := Map("S", Map("other", "value"))
	AssertEqual("default", IniCacheGet(C, "S", "missing", "default"))
}
Test("IniCacheGet: returns the default when the key is missing", TestCfg_GetMissingKey)

TestCfg_GetFound() {
	C := Map("S", Map("key", "found"))
	AssertEqual("found", IniCacheGet(C, "S", "key", "default"))
}
Test("IniCacheGet: returns the value when found", TestCfg_GetFound)

TestCfg_GetSentinel() {
	C := Map()
	AssertEqual("_", IniCacheGet(C, "S", "k"))
}
Test("IniCacheGet: default sentinel '_' is the documented marker", TestCfg_GetSentinel)




; ==========================
; ResolveConfigPath
; ==========================
TestCfg_ResolveEmpty() {
	AssertEqual("/default", ResolveConfigPath("", "/default"))
}
Test("ResolveConfigPath: empty value falls back to default", TestCfg_ResolveEmpty)

TestCfg_ResolveSentinel() {
	AssertEqual("/default", ResolveConfigPath("_", "/default"))
}
Test("ResolveConfigPath: underscore sentinel falls back to default",
	TestCfg_ResolveSentinel)

TestCfg_ResolveTrim() {
	AssertEqual("/configured", ResolveConfigPath("  /configured  ", "/default"))
}
Test("ResolveConfigPath: trims surrounding whitespace", TestCfg_ResolveTrim)

TestCfg_ResolvePass() {
	AssertEqual("C:\path", ResolveConfigPath("C:\path", "/default"))
}
Test("ResolveConfigPath: real value passes through unchanged", TestCfg_ResolvePass)




; ==========================
; ParseIniFile — additional cases
; ==========================
TestCfg_EmptyFile() {
	TmpPath := A_ScriptDir . "\test_ini_empty.ini"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	FileAppend("", TmpPath, "UTF-8")
	Result := ParseIniFile(TmpPath)
	AssertEqual(0, Result.Count)
	FileDelete(TmpPath)
}
Test("ParseIniFile: empty file returns empty Map", TestCfg_EmptyFile)

TestCfg_CommentsIgnored() {
	TmpPath := A_ScriptDir . "\test_ini_comments.ini"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	FileAppend("[S]`r`n; this is a comment`r`nkey=value`r`n", TmpPath, "UTF-8")
	Cache := ParseIniFile(TmpPath)
	AssertTrue(Cache.Has("S"))
	; Only "key" should be in the section — the comment line has no "="
	; and the line is not a section header, so it's skipped as malformed
	AssertEqual(1, Cache["S"].Count)
	AssertEqual("value", Cache["S"]["key"])
	FileDelete(TmpPath)
}
Test("ParseIniFile: comment lines (no =) are treated as malformed and skipped",
	TestCfg_CommentsIgnored)

TestCfg_MultipleValuesPerSection() {
	TmpPath := A_ScriptDir . "\test_ini_multi.ini"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	FileAppend("[S]`r`na=1`r`nb=2`r`nc=3`r`n", TmpPath, "UTF-8")
	Cache := ParseIniFile(TmpPath)
	AssertEqual(3, Cache["S"].Count)
	AssertEqual("1", Cache["S"]["a"])
	AssertEqual("2", Cache["S"]["b"])
	AssertEqual("3", Cache["S"]["c"])
	FileDelete(TmpPath)
}
Test("ParseIniFile: reads multiple keys in a single section",
	TestCfg_MultipleValuesPerSection)

TestCfg_ValueWithEqualsSign() {
	TmpPath := A_ScriptDir . "\test_ini_eq.ini"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	; Value itself contains an equals sign — split on the FIRST = only
	FileAppend("[S]`r`nformula=a=b+c`r`n", TmpPath, "UTF-8")
	Cache := ParseIniFile(TmpPath)
	AssertEqual("a=b+c", Cache["S"]["formula"])
	FileDelete(TmpPath)
}
Test("ParseIniFile: value containing '=' is preserved (split on first = only)",
	TestCfg_ValueWithEqualsSign)




; ==========================
; IniCacheGet — type coercion
; ==========================
TestCfg_GetNumericValue() {
	C := Map("S", Map("n", "42"))
	; IniCacheGet returns strings; the caller must coerce if needed
	AssertEqual("42", IniCacheGet(C, "S", "n", "0"))
}
Test("IniCacheGet: numeric values are returned as strings", TestCfg_GetNumericValue)

TestCfg_GetEmptyValue() {
	C := Map("S", Map("k", ""))
	AssertEqual("", IniCacheGet(C, "S", "k", "default"))
}
Test("IniCacheGet: empty string value is returned as-is (not the default)",
	TestCfg_GetEmptyValue)




; ==========================
; ResolveConfigPath — whitespace-only
; ==========================
TestCfg_ResolveWhitespaceOnly() {
	; A string consisting only of spaces/tabs should fall back to default
	AssertEqual("/default", ResolveConfigPath("   ", "/default"))
}
Test("ResolveConfigPath: whitespace-only string falls back to default after trim",
	TestCfg_ResolveWhitespaceOnly)
