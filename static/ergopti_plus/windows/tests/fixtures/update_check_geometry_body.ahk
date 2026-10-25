; tests/fixtures/update_check_geometry_body.ahk

; ==============================================================================
; MODULE: Update Check Canonical Geometry Child
; DESCRIPTION:
; Real manifest loading and real native fallback windows qualify the canonical
; geometry owner. Cache sentinels distinguish the app from another manifest row;
; malformed metadata must fail without creating a browser or a native window.
; ==============================================================================

#Requires AutoHotkey v2.0

t(Key) => Key

_UCNG_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_UCNG_Reject(AppId, ExpectedMessage) {
	Caught := false
	try WebViewHost.AppGeometry(AppId)
	catch as Err {
		Caught := true
		_UCNG_Require(Type(Err) == "ValueError", "invalid geometry must throw ValueError, never an unset dependency")
		_UCNG_Require(Err.Message == ExpectedMessage, "the invalid field must be the exact rejection cause")
	}
	_UCNG_Require(Caught, "invalid geometry cannot acquire a fallback size")
}

_UCNG_NativeWidth(Expected) {
	global _UC_Gui, _UC_Native, _UC_ResetDone, UPDATER_REQUEST_ORIGIN_MANUAL
	Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	_UCNG_Require(UpdateCheck_Begin(Request, "v1.0.0"), "the real public check must open")
	try {
		_UCNG_Require(_UC_Native && !_UC_ResetDone && IsSet(_UC_Gui), "without WebView2 the real native fallback must own its GUI")
		Rect := Buffer(16, 0)
		_UCNG_Require(DllCall("User32\GetClientRect", "Ptr", _UC_Gui.Hwnd, "Ptr", Rect, "Int"), "the actual native client rectangle must be readable")
		Width := NumGet(Rect, 8, "Int")
		_UCNG_Require(Width == Round(Expected * A_ScreenDPI / 96), "the actual visible native width must consume the current app geometry")
		_UCNG_Require(DllCall("User32\IsWindowVisible", "Ptr", _UC_Gui.Hwnd, "Int"), "the measured fallback window must be visible")
		FileAppend("RECEIPT update-check-geometry native_width=" . Width . " canonical_width=" . Expected . " dpi=" . A_ScreenDPI . "`n", "*", "UTF-8")
	} finally _UpdateCheck_CloseWindow()
}

_UCNG_Run() {
	global _SharedDir, _WebView_SharedEnv, _UC_ResetDone
	_UCNG_Require(!IsSet(WebView2), "this private child has no browser constructor")
	_UCNG_Require(WebViewHost._ManifestCache == "", "including the genuine owner must not read geometry before paths are initialized")
	Expected := JsonParse(FileRead(_SharedDir . "\ui\apps.manifest.json", "UTF-8"))["apps"]["update_check"]
	Geo := WebViewHost.AppGeometry("update_check")
	_UCNG_Require(Geo.w == Expected["width"] && Geo.h == Expected["height"] && Geo.w == 480 && Geo.h == 440,
		"the actual lazy owner must read the shipped canonical 480x440 geometry")
	_UCNG_NativeWidth(Geo.w)
	Apps := WebViewHost._ManifestCache.Clone()
	Apps["update_check"] := Map("width", 697, "height", 349)
	Apps["another_app"] := Map("width", 911, "height", 577)
	WebViewHost._ManifestCache := Apps
	Geo := WebViewHost.AppGeometry("update_check")
	_UCNG_Require(Geo.w == 697 && Geo.h == 349, "alternate owner dimensions must replace every old literal")
	Geo.w := 1
	_UCNG_Require(WebViewHost.AppGeometry("update_check").w == 697, "a returned geometry cannot mutate the cached canonical entry")
	_UCNG_NativeWidth(697)
	_UCNG_Reject("unknown_app", "Missing app geometry: unknown_app.")
	_UCNG_Reject("", "An app geometry identifier is required.")
	_UCNG_Reject(42, "An app geometry identifier is required.")
	for Entry in [Map(), Map("height", 440), Map("width", 480)] {
		WebViewHost._ManifestCache := Map("update_check", Entry)
		Missing := Entry.Has("width") ? "height" : "width"
		_UCNG_Reject("update_check", "Invalid app geometry update_check." . Missing . ".")
	}
	for Field in ["width", "height"] {
		for Value in ["440", Map(), 0, -1, 1.5] {
			Entry := Map("width", 480, "height", 440)
			Entry[Field] := Value
			WebViewHost._ManifestCache := Map("update_check", Entry)
			_UCNG_Reject("update_check", "Invalid app geometry update_check." . Field . ".")
		}
	}
	WebViewHost._ManifestCache := Map()
	_UCNG_Reject("update_check", "Missing app geometry: update_check.")
	_UCNG_Require(_UC_ResetDone && WebViewHost._Instances.Count == 0 && _WebView_SharedEnv == 0,
		"reading geometry and opening native fallbacks must never activate WebView2")
	FileAppend("PASS update-check-native-consent geometry`n", "*", "UTF-8")
}

try {
	_UCNG_Run()
	ExitApp(0)
} catch Any as Failure {
	FileAppend("FAIL update-check-geometry " . Failure.Message . " file=" . Failure.File . " line=" . Failure.Line . "`n", "*", "UTF-8")
	ExitApp(1)
}
