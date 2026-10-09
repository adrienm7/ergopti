; tests/meta/test_menu_manifest_one_decoder.ahk

; ==============================================================================
; MODULE: Menu Manifest Single Decoder Meta Test
; DESCRIPTION:
; Regression guard for menu-manifest-decoded-once-per-menu-layer.
;
; The shared menu_manifest.json is 12.5 KB and a single decode of it benches at
; ~44 ms with the driver's own JSON parser. The menu layer used to decode it
; three separate times on the boot path, each behind its own cache:
;   1. _MM_GetManifestRoot        (infra/menu_manifest.ahk, the shared accessor)
;   2. MenuManifest_LoadHotstringGroups, with a private FileRead + JsonParse
;   3. _MR_GetManifestRoot        (infra/manifest_menu.ahk, a second full cache)
; Same bytes, same immutable result, ~88 ms of pure duplicate work per boot.
;
; ROOT CAUSE ENCODED: exactly one function in the menu layer may name and decode
; the manifest file; every other consumer resolves through it. The owner set is
; DERIVED by walking each occurrence of the manifest path back to its enclosing
; function, so a fourth private decode fails here instead of quietly reappearing.
;
; _MG_LoadSubCategories (infra/master_gates.ahk) is the one documented exception:
; its non-memoized re-read is a deliberate fail-fast contract -- an invalid
; canonical manifest must throw on EVERY call -- pinned by
; tests/unit/test_master_gates.ahk, and it runs per live category toggle, never
; on the boot path.
; ==============================================================================

#Requires AutoHotkey v2.0

; Functions allowed to name and open the shared menu manifest themselves.
_MM1D_ALLOWED_OWNERS := Map(
	"_MM_GetManifestRoot",  "the single shared accessor, cached for the process lifetime",
	"_MG_LoadSubCategories", "deliberate fail-fast non-memoization, pinned by tests/unit/test_master_gates.ahk",
)





; ==============================================================
; ==============================================================
; ======= 1/ Only the allowed owners open the manifest =========
; ==============================================================
; ==============================================================

; Returns the name of the top-level driver function enclosing character offset
; ``Offset`` in ``Src``, or "" when the offset sits outside any function.
_MM1D_EnclosingFunction(Src, Offset) {
	Name := ""
	Pos := 1
	while (Found := RegExMatch(Src, "m)^(\w+)\([^\r\n]*\)\s*\{", &M, Pos)) {
		if (Found > Offset)
			break
		Name := M[1]
		Pos := Found + StrLen(M[0])
	}
	return Name
}

_MM1D_OnlyOneMenuLayerDecoder() {
	global _MM1D_ALLOWED_OWNERS
	Src    := _DriverSourceNoComments()
	Needle := "\modules\menu\menu_manifest.json"

	Owners := Map()
	Pos := 1
	while (Found := InStr(Src, Needle, , Pos)) {
		Owner := _MM1D_EnclosingFunction(Src, Found)
		Assert(Owner != "",
			"every reference to the shared menu manifest path must sit inside a named function so "
			. "this guard can attribute it")
		Owners[Owner] := true
		Pos := Found + 1
	}

	Assert(Owners.Count >= 1,
		"the manifest path must still be referenced somewhere in the driver -- a scan that found "
		. "nothing would make this test vacuous")

	for Owner in Owners {
		Assert(_MM1D_ALLOWED_OWNERS.Has(Owner),
			"'" . Owner . "' opens the shared menu_manifest.json itself. One decode of the 12.5 KB "
			. "file benches at ~44 ms and its parsed root is immutable for the process lifetime, so "
			. "every consumer must resolve through _MM_GetManifestRoot() instead of paying for its "
			. "own copy (menu-manifest-decoded-once-per-menu-layer)")
	}
}
Test("menu_manifest: only the shared accessor decodes the manifest (menu-manifest-decoded-once-per-menu-layer)",
	_MM1D_OnlyOneMenuLayerDecoder)





; ====================================================================
; ====================================================================
; ======= 2/ The renderer's accessor is a delegate, not a copy =======
; ====================================================================
; ====================================================================

_MM1D_RendererAccessorDelegates() {
	Body := _DriverFuncBody("_MR_GetManifestRoot")
	Assert(Body != "", "_MR_GetManifestRoot must exist in the driver source")
	Assert(InStr(Body, "_MM_GetManifestRoot") > 0,
		"_MR_GetManifestRoot must resolve the manifest through the shared accessor")
	Assert(!InStr(Body, "FileRead(") and !InStr(Body, "JsonParse("),
		"_MR_GetManifestRoot must not read or decode the manifest itself -- it used to keep a second "
		. "independent cache of the identical file, a full extra ~44 ms decode on the boot path")

	; A second cache global is the shape the duplicate decode came in, so its
	; absence is the property, not a spelling: the renderer must hold no
	; manifest cache of its own for a stale copy to diverge from.
	Src := _DriverSourceNoComments()
	Assert(InStr(Src, "_MR_MANIFEST_CACHE") == 0,
		"the menu renderer must hold no private manifest cache -- one parsed root, one owner "
		. "(menu-manifest-decoded-once-per-menu-layer)")
}
Test("menu_manifest: the renderer accessor delegates instead of caching a copy (menu-manifest-decoded-once-per-menu-layer)",
	_MM1D_RendererAccessorDelegates)
