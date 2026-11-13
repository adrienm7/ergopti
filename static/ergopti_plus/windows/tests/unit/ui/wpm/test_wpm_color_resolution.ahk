; tests/unit/ui/wpm/test_wpm_color_resolution.ahk

; ==============================================================================
; MODULE: WPM Widget Colour Resolution
; DESCRIPTION:
; Runs _WPMWidget_ReadTomlColor. The WPM tick asks for a colour every ~100 ms, so
; the fallback file read is memoized, while a colour the user changes in the
; config window must still reach the widget (wpm-color-cache): the resolver is
; asked first on every call, its answer is never memoized, and a memoized
; fallback from early init cannot shadow it later.
; ==============================================================================

#Requires AutoHotkey v2.0

; A category of this run alone: the fallback cache lives for the whole process.
_WCR_Category() {
	static Serial := 0
	Serial += 1
	return "wpmcolortest" . A_TickCount . Serial
}

; A resolver failing as in early init: a bad record makes the resolver throw, and
; the reader's own try falls back to the file.
_WCR_BreakResolver(Category) {
	global _HotstringsOverrides
	_HotstringsOverrides[Category] := "not an override record"
	HotstringsResolveBumpGen()
}

_WCR_SetColor(Category, Color) {
	global _HotstringsOverrides
	Entry := _HotstringsNewOverrideEntry()
	Entry.Color := Color
	_HotstringsOverrides[Category] := Entry
	HotstringsResolveBumpGen()
}

_WCR_WithCategory(Body) {
	global _HotstringsOverrides, _SharedDir, GLOBAL_DEFAULT_COLOR
	Category := _WCR_Category()
	SavedShared := _SharedDir
	Root := A_Temp . "\" . Category
	DirCreate(Root . "\hotstrings\data\catalogue")
	File := Root . "\hotstrings\data\catalogue\" . Category . ".toml"
	; The path owner reads the language packs here, and the logger its redaction rules.
	DirCreate(Root . "\diagnostics\data")
	FileCopy(SavedShared . "\hotstrings\data\catalogue\_index.toml", Root . "\hotstrings\data\catalogue\_index.toml")
	FileCopy(SavedShared . "\diagnostics\data\redaction.json", Root . "\diagnostics\data\redaction.json")
	try {
		_SharedDir := Root
		Body.Call(Category, File)
	} finally {
		_SharedDir := SavedShared
		_HotstringsOverrides.Delete(Category)
		HotstringsResolveBumpGen()
		DirDelete(Root, true)
	}
}

_WCR_Write(File, Color) {
	if FileExist(File)
		FileDelete(File)
	FileAppend('[_meta]`ncolor = "' . Color . '"`n', File, "UTF-8-RAW")
}

; A colour changed in the config window reaches the very next read.
_WCR_ResolverAnswersEveryCall() {
	_WCR_WithCategory(_Body)
	_Body(Category, File) {
		_WCR_SetColor(Category, "AA0001")
		AssertEqual("AA0001", _WPMWidget_ReadTomlColor(Category))
		_WCR_SetColor(Category, "AA0002")
		AssertEqual("AA0002", _WPMWidget_ReadTomlColor(Category), "the resolver's answer is never memoized")
	}
}
Test("WPM widget: a changed colour reaches the next read (wpm-color-cache)", _WCR_ResolverAnswersEveryCall)

; The bug: the first answer from the fallback was memoized above the resolver, so
; the resolver was skipped for that category for the life of the process.
_WCR_FallbackCannotShadowTheResolver() {
	_WCR_WithCategory(_Body)
	_Body(Category, File) {
		_WCR_Write(File, "BB0001")
		_WCR_BreakResolver(Category)
		AssertEqual("BB0001", _WPMWidget_ReadTomlColor(Category), "early init serves the file")
		_WCR_SetColor(Category, "BB0002")
		AssertEqual("BB0002", _WPMWidget_ReadTomlColor(Category), "a memoized fallback cannot shadow the resolver")
	}
}
Test("WPM widget: a memoized fallback never shadows the resolver (wpm-color-cache)", _WCR_FallbackCannotShadowTheResolver)

; The tick must not read the file again: a changed file proves no second read.
_WCR_FallbackReadsTheFileOnce() {
	_WCR_WithCategory(_Body)
	_Body(Category, File) {
		_WCR_Write(File, "CC0001")
		_WCR_BreakResolver(Category)
		AssertEqual("CC0001", _WPMWidget_ReadTomlColor(Category))
		_WCR_Write(File, "CC0002")
		AssertEqual("CC0001", _WPMWidget_ReadTomlColor(Category), "a cache hit reads no file")
	}
}
Test("WPM widget: the fallback reads its file once (wpm-color-cache)", _WCR_FallbackReadsTheFileOnce)

; A category with no file is remembered as such, so the tick does not probe the disk.
_WCR_MissingFileIsMemoized() {
	_WCR_WithCategory(_Body)
	_Body(Category, File) {
		_WCR_BreakResolver(Category)
		AssertEqual("", _WPMWidget_ReadTomlColor(Category))
		_WCR_Write(File, "DD0001")
		AssertEqual("", _WPMWidget_ReadTomlColor(Category), "a miss is memoized too")
	}
}
Test("WPM widget: a missing file is memoized (wpm-color-cache)", _WCR_MissingFileIsMemoized)
