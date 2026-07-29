; tests/meta/test_menu_manifest_single_decode.ahk

; ==============================================================================
; MODULE: Menu-Manifest Single-Decode Guard Meta Test
; DESCRIPTION:
; Static source guard for menu-manifest-decoded-three-times-per-rebuild.
;
; lib/menu_manifest.ahk exposes several loaders that each derive one slice of
; the shared menu_manifest.json. Three of them - the debug menu, the top-level
; tail and the global actions - are reached from _MI_AppendTail on every single
; initMenu(), and initMenu() calls MenuManifest_InvalidateCache() first, which
; zeroes their derived caches. Each loader then did its own
; FileRead(UTF-8) + JsonParse of the SAME 12.7 KB file: three cold decodes per
; tray rebuild, benched at 36-42 ms each. That is the "tail
; (global_actions...debug): +78 ms" line in the boot profile, and every tray
; toggle - a hotstring section, a wrap symbol, a delimiter - pays it again.
;
; The derived structures carry only ids and platform filters. No localised text,
; no runtime state. So there was never anything per-rebuild about them, and the
; decode was pure waste.
;
; THE FIX (the contract this test pins): one parsed root, cached for the process
; lifetime behind _MM_GetManifestRoot(), and NOT cleared by
; MenuManifest_InvalidateCache(). The loaders derive from that root and never
; touch the disk themselves.
;
; The class of loaders is derived from driver source, so a new sibling loader
; inherits the guarantee instead of quietly reintroducing a fourth decode.
; ==============================================================================

#Requires AutoHotkey v2.0

; MenuManifest_LoadHotstringGroups is deliberately exempt. It runs exactly once,
; at load time (ui/tray_menu.ahk seeds _HotstringGroups from it), so it never
; pays a per-rebuild decode, and its four traced fallback branches are pinned
; line by line by tests/meta/test_menu_manifest_lifecycle_pair.ahk - moving its
; read into the shared accessor would move those branches out of its body.
_MMSD_EXEMPT := Map("MenuManifest_LoadHotstringGroups", true)





; ===========================================================
; ===========================================================
; ======= 1/ No loader re-reads or re-parses the file =======
; ===========================================================
; ===========================================================

_MMSD_LoadersReuseTheParsedRoot() {
	global _MMSD_EXEMPT
	Src := _DriverSourceNoComments()
	Names := Map()
	Pos := 1
	while (Found := RegExMatch(Src, "m)^(MenuManifest_Load\w+)\([^\r\n]*\)\s*\{", &M, Pos)) {
		if !_MMSD_EXEMPT.Has(M[1])
			Names[M[1]] := true
		Pos := Found + StrLen(M[0])
	}
	Assert(Names.Count >= 3,
		"the manifest-loader class must be derived from driver source and hold at least the three "
		. "per-rebuild loaders (debug menu, top-level tail, global actions) - an empty class would "
		. "make this test vacuous")

	for Name in Names {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must be defined in lib/menu_manifest.ahk")
		Assert(InStr(Body, "_MM_GetManifestRoot(") > 0,
			Name . " must derive from the shared parsed manifest root")
		Assert(InStr(Body, "JsonParse(") == 0,
			Name . " must not decode menu_manifest.json itself - a decode of the 12.7 KB manifest "
			. "benches at 36-42 ms and initMenu() invalidates this loader's cache on every tray "
			. "rebuild, so a private decode is paid again on every single toggle "
			. "(menu-manifest-decoded-three-times-per-rebuild)")
		Assert(InStr(Body, "FileRead(") == 0,
			Name . " must not read menu_manifest.json from disk itself - see the decode cost above")
	}
}
Test("menu_manifest: no per-rebuild loader re-reads the manifest (menu-manifest-decoded-three-times-per-rebuild)",
	_MMSD_LoadersReuseTheParsedRoot)





; ======================================================
; ======================================================
; ======= 2/ The shared root is genuinely cached =======
; ======================================================
; ======================================================

; A shared accessor that re-decodes on every call would satisfy section 1 while
; costing exactly as much as before, so the cache itself is the guarantee.
_MMSD_SharedRootIsCachedAcrossRebuilds() {
	Body := _DriverFuncBody("_MM_GetManifestRoot")
	Assert(Body != "", "_MM_GetManifestRoot must be defined in lib/menu_manifest.ahk")

	CachePos := InStr(Body, "if (_MM_MANIFEST_ROOT_CACHE != false)")
	ReadPos  := InStr(Body, "FileRead(")
	Assert(CachePos > 0 and ReadPos > CachePos,
		"_MM_GetManifestRoot must return the cached root before touching the disk")
	Assert(InStr(Body, "_MM_MANIFEST_ROOT_CACHE := Root") > 0,
		"_MM_GetManifestRoot must store the parsed root so the next caller is free")

	Invalidate := _DriverFuncBody("MenuManifest_InvalidateCache")
	Assert(Invalidate != "", "MenuManifest_InvalidateCache must be defined in lib/menu_manifest.ahk")
	Assert(InStr(Invalidate, "_MM_MANIFEST_ROOT_CACHE") == 0,
		"MenuManifest_InvalidateCache must NOT clear the parsed root. initMenu() calls it at the top "
		. "of every tray rebuild, so clearing the root there puts the whole decode cost straight back "
		. "- and there is nothing to invalidate: the derived structures carry only ids and platform "
		. "filters, and the manifest ships inside the driver bundle")
}
Test("menu_manifest: the parsed root survives a tray rebuild (menu-manifest-decoded-three-times-per-rebuild)",
	_MMSD_SharedRootIsCachedAcrossRebuilds)
