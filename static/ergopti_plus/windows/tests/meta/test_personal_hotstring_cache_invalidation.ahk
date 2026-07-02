; tests/meta/test_personal_hotstring_cache_invalidation.ahk

; ==============================================================================
; MODULE: Personal-Hotstring Cache Invalidation Meta Test
; DESCRIPTION:
; Static source guard for finding F14 (personal-hotstring-cache-never-
; invalidated).
;
; _HS_InvalidatePersonalCache() existed and did exactly what its name says
; (reset _HS_PreScanPersonalCacheLoaded / _ParseExtTomlSectionsCache /
; _HS_ExtensionsCacheLoaded) but had ZERO callers anywhere in the codebase, so
; a personal extension .toml added or edited mid-session (outside the editor)
; never refreshed the tray-menu display for the rest of the session.
;
; The fix wires the invalidator into RebuildTrayMenu() — the runtime rebuild
; path (log-level change, shortcut letter picks, hotstring live toggles,
; editor close) — right before InitSubMenus() re-scans. It is deliberately NOT
; wired into InitSubMenus() itself or into BuildTrayMenuDeferred(): the boot
; pass warms this exact cache OFF the boot Critical("On") section specifically
; so InitSubMenus()'s own (under-Critical) call to it hits only the warm cache
; (see test_deferred_menu_critical_file_io.ahk) — invalidating inside
; InitSubMenus would force the unbounded personal-folder disk walk back under
; Critical on every boot and reintroduce a keyboard-hook freeze.
; ==============================================================================

#Requires AutoHotkey v2.0




_HSC_InvalidateWiredIntoRebuild() {
	Body := _DriverFuncBody("RebuildTrayMenu")
	Assert(Body != "", "RebuildTrayMenu() declaration must exist in ui/menu/menu_rebuild.ahk")

	InvalidatePos := InStr(Body, "_HS_InvalidatePersonalCache()")
	InitPos := InStr(Body, "InitSubMenus()")
	Assert(InvalidatePos > 0,
		"RebuildTrayMenu must call _HS_InvalidatePersonalCache() so a personal extension .toml added/edited mid-session refreshes the tray menu (personal-hotstring-cache-never-invalidated)")
	Assert(InitPos > 0, "RebuildTrayMenu must call InitSubMenus()")
	Assert(InvalidatePos < InitPos,
		"the personal cache must be invalidated BEFORE InitSubMenus() re-scans it, not after (personal-hotstring-cache-never-invalidated)")
}
Test("menu: RebuildTrayMenu invalidates the personal-hotstring cache before rescanning (personal-hotstring-cache-never-invalidated)",
	_HSC_InvalidateWiredIntoRebuild)

_HSC_NotWiredIntoInitSubMenus() {
	; Guards against the "obvious but wrong" fix: invalidating inside
	; InitSubMenus() would defeat BuildTrayMenuDeferred's off-Critical cache
	; warm-up and put the unbounded personal-folder scan back under Critical
	; at boot (test_deferred_menu_critical_file_io.ahk's regression).
	Body := _DriverFuncBody("InitSubMenus")
	Assert(Body != "", "InitSubMenus() declaration must exist in ui/menu/menu_submenus.ahk")
	Assert(InStr(Body, "_HS_InvalidatePersonalCache()") == 0,
		"InitSubMenus must NOT invalidate the personal cache itself — that would force the unbounded personal-folder scan back under Critical at boot (personal-hotstring-cache-never-invalidated)")
}
Test("menu: InitSubMenus does not itself invalidate the personal-hotstring cache (personal-hotstring-cache-never-invalidated)",
	_HSC_NotWiredIntoInitSubMenus)
