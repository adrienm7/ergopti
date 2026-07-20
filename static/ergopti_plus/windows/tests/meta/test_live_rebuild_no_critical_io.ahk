; tests/meta/test_live_rebuild_no_critical_io.ahk

; ==============================================================================
; MODULE: Live hotstring rebuild must not freeze the keyboard
; DESCRIPTION:
; RebuildHotstringsLive wrapped HSE_RegistryClear + RegisterAllHotstrings in
; Critical("On"). That span is ~1.3 s of registration (distances/SFBs/rolls, dynamic,
; text-expansion, emoji/symbols) PLUS _HS_RegisterPersonal's DirExist + recursive
; Loop Files + FileRead of extension TOMLs — unbounded filesystem work. Holding
; Critical across it turned "no expansions for a second" into "keyboard frozen for a
; second or more" on every tray hotstring toggle (worse on cloud-synced dirs).
;
; The Critical was redundant: HSE_RebuildInProgress already fences the matcher
; (HSE_FindMatchAtEnd returns no match while it is set), and HSE_Register /
; HSE_DisableGroup / HSE_EnableGroup take their own per-mutation Criticals. Dropping
; the outer Critical trades a keyboard freeze for pass-through (unexpanded)
; keystrokes during the rebuild window. (F33, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_LRNC_NoCriticalAcrossRegistration() {
	Body := _DriverFuncBody("RebuildHotstringsLive")
	Assert(Body != "", "RebuildHotstringsLive must exist in ui/menu/menu_rebuild.ahk")

	FencePos := InStr(Body, "HSE_RebuildInProgress := true")
	RegPos := InStr(Body, "RegisterAllHotstrings()")
	Assert(FencePos > 0 && RegPos > FencePos,
		"RebuildHotstringsLive must raise the HSE_RebuildInProgress fence before re-registering")
	Assert(InStr(Body, "Critical(") = 0,
		"RebuildHotstringsLive must NOT hold Critical across RegisterAllHotstrings — that span includes directory enumeration and TOML reads, and it froze the keyboard on every tray toggle")

	; The fence is what makes dropping Critical safe: the matcher must bail while set.
	Match := _DriverFuncBody("HSE_FindMatchAtEnd")
	Assert(Match != "", "HSE_FindMatchAtEnd must exist in lib/hotstrings/hotstring_match.ahk")
	Assert(InStr(Match, "HSE_RebuildInProgress") > 0,
		"HSE_FindMatchAtEnd must return no match while HSE_RebuildInProgress is set — that fence replaces the removed Critical, so an OnChar never sees a half-built registry")
}
Test("menu: live hotstring rebuild does not hold Critical across registration I/O",
	_LRNC_NoCriticalAcrossRegistration)
