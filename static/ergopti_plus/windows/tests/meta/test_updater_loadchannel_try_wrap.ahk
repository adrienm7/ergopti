; tests/meta/test_updater_loadchannel_try_wrap.ahk

; ==============================================================================
; MODULE: Updater_LoadChannel Boot Try-Wrap Meta Test
; DESCRIPTION:
; Regression guard: Updater_LoadChannel() was called bare at boot in
; ErgoptiPlus.ahk, unlike its three siblings in the same boot-time block
; (Updater_LoadCheckInterval, Updater_StartBackgroundChecks,
; Updater_InitTrayNotifyHandler), all of which are try-wrapped. It reads the
; user's config.toml via IniCacheGet, which throws if a config section was
; parsed as anything other than a Map — an unguarded exception here would
; abort the entire boot sequence before hotstring registration.
;
; SCOPE: source introspection of ErgoptiPlus.ahk's boot-time call site.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =====================================================
; ======= 1/ Updater_LoadChannel is try-wrapped =======
; =====================================================
; =====================================================

_MetaCheckUpdaterLoadChannelTryWrapped() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	BootFile := WindowsDir . "\ErgoptiPlus.ahk"

	Body := ""
	try Body := FileRead(BootFile)
	Assert(Body != "", "ErgoptiPlus.ahk must be readable for the try-wrap meta-test")

	Pos := InStr(Body, "Updater_LoadChannel()")
	Assert(Pos > 0, "ErgoptiPlus.ahk must call Updater_LoadChannel() at boot")

	; The nearest preceding non-whitespace token before the call must be "try".
	Before := Trim(SubStr(Body, Max(1, Pos - 10), Pos - Max(1, Pos - 10)))
	Assert(InStr(Before, "try") > 0,
		"Updater_LoadChannel() must be try-wrapped at its boot call site, matching "
		. "Updater_LoadCheckInterval/Updater_StartBackgroundChecks/Updater_InitTrayNotifyHandler "
		. "in the same block, so a malformed config.toml cannot abort the boot sequence")
}

Test("meta boot: Updater_LoadChannel() try-wrapped at its call site", _MetaCheckUpdaterLoadChannelTryWrapped)
