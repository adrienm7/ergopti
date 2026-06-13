; tests/meta/test_native_hotstrings_migrated.ahk

; ==============================================================================
; MODULE: Native-Hotstring Migration Test
; DESCRIPTION:
; Guards that the two formerly-native AHK Hotstring() registrations (the
; E-circumflex deadkey and the "..." ellipsis) stay migrated into the HSE as
; raw-callback hotstrings — for architectural coherence: a single engine, no
; native Hotstring() and thus no A_InputLevel dependency anywhere.
;
; WHY THIS MATTERS (the regression this encodes):
;   The deadkey + ellipsis were native Hotstring() calls that needed A_InputLevel 2
;   (boot-thread only), which blocked deferring / live-rebuilding them and split the
;   driver across two engines. They now go through CreateRawCallbackHotstring ->
;   _HSE_DispatchRawCallback (suppression + synthetic-marking + buffer resync). If a
;   future edit reintroduces a native Hotstring() in the registration module, the
;   single-engine invariant breaks (and the input-level hazard returns) — caught here.
;
; SCOPE: source introspection of the engine + registration modules (not loaded by
;   the headless runner).
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckNativeHotstringsMigrated() {
	SplitPath(A_ScriptDir, , &WindowsDir)

	; The HSE engine must provide the raw-callback dispatch path + the builder.
	EngineMain := ""
	try EngineMain := FileRead(WindowsDir . "\lib\hotstrings\hotstring_engine_main.ahk")
	Assert(EngineMain != "", "hotstring_engine_main.ahk must be readable")
	Assert(InStr(EngineMain, "_HSE_DispatchRawCallback"),
		"HSE must define _HSE_DispatchRawCallback (the raw-callback dispatch path)")
	Assert(InStr(EngineMain, "RawCallback"),
		"HSE_DispatchMatch must route RawCallback specs through the raw-callback path")

	Engine := ""
	try Engine := FileRead(WindowsDir . "\lib\hotstrings\hotstring_engine.ahk")
	Assert(Engine != "", "hotstring_engine.ahk must be readable")
	Assert(InStr(Engine, "CreateRawCallbackHotstring("),
		"hotstring_engine.ahk must define the CreateRawCallbackHotstring builder")

	; The registration module must use the HSE raw-callback path for the deadkey +
	; ellipsis, return their { Bs, Ins } buffer effects, and contain NO native
	; AHK-engine deadkey flag string (":*?CB0:" was unique to the old native call).
	Hs := ""
	try Hs := FileRead(WindowsDir . "\modules\hotstrings.ahk")
	Assert(Hs != "", "modules\hotstrings.ahk must be readable")
	Assert(InStr(Hs, "CreateRawCallbackHotstring("),
		"deadkey + ellipsis must register via CreateRawCallbackHotstring")
	Assert(InStr(Hs, "_EllipsisRawCallback"),
		"the ellipsis raw-callback (_EllipsisRawCallback) must exist")
	Assert(InStr(Hs, "{ Bs:"),
		"the migrated callbacks must return a { Bs, Ins } buffer effect for HSE resync")
	Assert(!InStr(Hs, ":*?CB0:"),
		"modules\hotstrings.ahk must contain no native AHK Hotstring() deadkey registration "
		. "(the ':*?CB0:' flag string) — the deadkey is now an HSE raw-callback")
}

Test("meta hotstrings: native deadkey + ellipsis migrated into the HSE",
	_MetaCheckNativeHotstringsMigrated)
