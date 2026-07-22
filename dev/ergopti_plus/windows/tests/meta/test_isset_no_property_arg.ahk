; tests/meta/test_isset_no_property_arg.ahk

; ==============================================================================
; MODULE: IsSet-Requires-a-Variable Meta Test
; DESCRIPTION:
; Regression guard for the WebViewHost startup crash: lib/webview_utils.ahk
; probed its manifest cache with IsSet(WebViewHost._ManifestCache), and the
; WebViewHost lifecycle probed IsSet(this.WebView) / IsSet(this.Controller).
; In AHK v2, IsSet accepts ONLY a plain variable, never a property or index
; expression -- so IsSet(obj.prop) is a LOAD-TIME error ("IsSet requires a
; variable.") that aborts the entire app the instant the file is parsed, hence
; "erreur des le demarrage". The correct probe for an unset-initialised
; property is obj.HasOwnProp("prop"), which returns false until the slot is
; assigned and false again after it is set back to unset -- exactly IsSet's
; intended semantics.
;
; The pre-existing webview meta tests never caught this because they are pure
; source-introspection (FileRead + pattern match) and never parse the file
; through the AHK interpreter, so a load-time error slips straight past them.
; This test closes that gap by scanning the ENTIRE driver source for the exact
; forbidden shape, guarding every present and future file against the whole
; class of bug -- not just the one site that bit us.
;
; SCOPE: source introspection of the whole windows/ driver tree.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================================
; ================================================================
; ======= 1/ IsSet never takes a property/index expression =======
; ================================================================
; ================================================================

; Collects every driver-source occurrence of IsSet applied to something that is
; NOT a bare variable -- a property access (IsSet(x.y)) or an index expression
; (IsSet(x[i])). Both are AHK v2 load-time errors. Returns the offending
; snippets (one per line) or "" when the source is clean. Full-line comments are
; stripped first so prose that mentions the pattern cannot trip the scan.
_INPA_CollectPropertyArgs() {
	Src := _DriverSourceNoComments()
	Offenders := ""
	Pos := 1
	; (?<!\w) so a longer identifier ending in "IsSet" (e.g. MyIsSet) is skipped;
	; then a leading identifier immediately followed by "." or "[" == not a variable.
	Needle := "(?<!\w)IsSet\(\s*[A-Za-z_]\w*\s*[.\[]"
	while (FoundPos := RegExMatch(Src, Needle, &m, Pos)) {
		Snippet := SubStr(Src, FoundPos, 48)
		Snippet := StrReplace(Snippet, "`r", "")
		Snippet := StrReplace(Snippet, "`n", " ")
		Offenders .= "  " . Trim(Snippet) . "`n"
		Advance := (m.Len > 0) ? m.Len : 1
		Pos := FoundPos + Advance
	}
	return Offenders
}

_INPA_NoPropertyArgs() {
	Offenders := _INPA_CollectPropertyArgs()
	Assert(Offenders == "",
		"IsSet() must never be applied to a property or index expression. AHK v2 IsSet accepts only a plain variable, so IsSet(obj.prop) / IsSet(arr[i]) is a LOAD-TIME error that aborts the whole app at startup. Use obj.HasOwnProp(name) instead. Offending call(s):`n" . Offenders . "(isset-requires-variable)")
}
Test("driver: IsSet() is never applied to a property/index expression (isset-requires-variable)", _INPA_NoPropertyArgs)


; The exact site that crashed: the WebViewHost manifest-cache lazy-load guard.
; Pins the fix on both axes -- (a) it must not call IsSet on the static, and
; (b) the static must use a concrete not-loaded sentinel, never ``unset`` (the
; cache is read unconditionally via ``is Map`` in _ManifestEntry, and reading an
; ``unset`` property throws PropertyError; see project-ahk-v2-static-unset-unreadable).
_INPA_ManifestCacheGuardIsSafe() {
	Src := _DriverSourceNoComments()
	Assert(InStr(Src, "class WebViewHost") > 0,
		"WebViewHost must exist in lib/webview_utils.ahk")
	Assert(!RegExMatch(Src, "IsSet\(\s*WebViewHost\."),
		"WebViewHost.TryOpen must not probe the manifest cache with IsSet(WebViewHost._ManifestCache) -- that is an AHK v2 load-time error that aborts app startup (isset-requires-variable)")
	Assert(InStr(Src, "static _ManifestCache := unset") == 0,
		"_ManifestCache must not be declared ``:= unset`` -- it is read via ``is Map`` in _ManifestEntry, and reading an unset property throws (use a concrete sentinel; project-ahk-v2-static-unset-unreadable)")
}
Test("webview_utils: manifest cache guard uses a concrete sentinel, never IsSet or unset on the static (isset-requires-variable)", _INPA_ManifestCacheGuardIsSafe)
