; tests/unit/modules/keystats/metrics/test_metrics_reader_image_reset.ahk

; ==============================================================================
; MODULE: Metrics Reader Image Reset Tests
; DESCRIPTION:
; Regression for AHK-006 / WM-003. An explicit dashboard cache Reset must retire
; the durable reader image, otherwise the successor worker restores the very
; aggregates the user asked to forget.
; ==============================================================================

#Requires AutoHotkey v2.0

_MRIR_RetireRemovesDurableImage() {
	Root := A_Temp . "\ergopti_reader_reset_" . A_TickCount . "_" . Random(1000, 9999) . "\"
	DirCreate(Root)
	try {
		AssertTrue(KLR_CacheRetire(Root), "an absent image is already retired")
		DirCreate(KLR_CacheDir(Root))
		Path := KLR_CachePath(Root)
		FileAppend("stale-aggregates", Path, "UTF-8-RAW")
		AssertTrue(FSExists(Path))
		AssertTrue(KLR_CacheRetire(Root), "the reset must retire the durable reader image")
		AssertFalse(FSExists(Path), "the successor build must not restore the reset image")
	} finally DirDelete(Root, true)
}
Test("metrics: explicit cache reset retires the durable reader image (WM-003)", _MRIR_RetireRemovesDurableImage)

_MRIR_ClearCacheRetiresImage() {
	Src := _DriverFileSource("keystats_webview.ahk")
	Idx := InStr(Src, 'case "clear_cache":')
	Assert(Idx > 0, "clear_cache handler must exist")
	Body := SubStr(Src, Idx, 3000)
	Assert(InStr(Body, 'KLR_CacheRetire(entry["metrics_dir"])') > 0
		&& InStr(Body, "KLR_CacheRetire") < InStr(Body, "KLPF_RequestBuild"),
		"clear_cache must retire the reader image before the successor full build")
}
Test("metrics: clear_cache retires the reader image before the successor build (WM-003)", _MRIR_ClearCacheRetiresImage)
