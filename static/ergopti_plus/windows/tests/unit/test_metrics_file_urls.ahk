; tests/unit/test_metrics_file_urls.ahk

; ==============================================================================
; MODULE: Metrics File URL Tests
; DESCRIPTION: Local path characters must remain data across URL boundaries.
; ==============================================================================

#Requires AutoHotkey v2.0

_MFU_Range(View, Lines, Unhandled, Failure) {
	Path := _CTU_NewPath() . " #50%25 &+ café.json"
	KLWV.windows := Map("typing", Map("epoch", 51, "webview", View))
	try {
		AssertTrue(FSWrite(Path, "{}"))
		AssertTrue(KLWV_OnRangeBuildTerminal("typing", 51, 42, "ok", Path))
		AssertTrue(RegExMatch(View.Scripts[1], "^fetch\((.*?)\)\.then", &Match))
		Url := KL_JsonDecode(Match[1])
		AssertContains(Url, "%20%2350%2525%20%26%2B%20caf%C3%A9.json",
			"reserved filename characters must not become URL syntax")
		AssertEqual("file:///" . StrReplace(Path, "\", "/"), UriDecode(Url))
	} finally FSDelete(Path)
}
Test("metrics URLs: range stage preserves reserved path characters (metrics-file-urls)",
	_WVSO_WithFixture.Bind(_MFU_Range))

_MFU_Edge(Which) {
	global _SharedDir
	_KLRDC_EnsureSharedDir()
	Saved := _SharedDir
	try {
		_SharedDir := A_Temp . "\assets #50%25 &+ café"
		Url := KLUI_ResolveAssetUrl(Which, A_Temp . "\metrics")
		Parts := StrSplit(Url, "#prefetch=")
		AssertEqual(2, Parts.Length)
		AssertContains(Parts[1], "assets%20%2350%2525%20%26%2B%20caf%C3%A9/",
			"the asset path must not become the page fragment")
		AssertEqual("file:///" . StrReplace(_SharedDir, "\", "/")
			. "/ui/metrics_" . Which . "/index.html", UriDecode(Parts[1]))
		AssertContains(Parts[2], "file%3A%2F%2F%2F",
			"the nested file URL must be encoded as one search-parameter value")
		AssertEqual("file:///" . StrReplace(KLPF_PrefetchPath(Which, A_Temp . "\metrics"), "\", "/"),
			UriDecode(UriDecode(Parts[2])))
	} finally _SharedDir := Saved
}
for Which in ["typing", "apps"]
	Test("metrics URLs: " . Which . " Edge asset and sidecar boundaries (metrics-file-urls)",
		_MFU_Edge.Bind(Which))

_MFU_Path(Path, Expected) {
	AssertEqual(Expected, FilePathToUrl(Path))
}
_MFU_RegisterPaths() {
	for Index, Fixture in [
		["D:\metrics\plain.json", "file:///D:/metrics/plain.json"],
		["D:\metrics\%23.json", "file:///D:/metrics/%2523.json"],
		["D:\metrics\# &+.json", "file:///D:/metrics/%23%20%26%2B.json"],
		["D:\metrics\café.json", "file:///D:/metrics/caf%C3%A9.json"],
		["\\server\share\# &+.json", "file://server/share/%23%20%26%2B.json"]
	] {
		Test("metrics URLs: exact file URL case " . Index . " (metrics-file-urls)",
			_MFU_Path.Bind(Fixture[1], Fixture[2]))
	}
}
_MFU_RegisterPaths()
