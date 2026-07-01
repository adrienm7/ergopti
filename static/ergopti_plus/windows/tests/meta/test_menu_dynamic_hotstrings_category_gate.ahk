; tests/meta/test_menu_dynamic_hotstrings_category_gate.ahk

; ==============================================================================
; MODULE: DynamicHotstrings Category-Gate False-Positive Meta Test (Pattern 5)
; DESCRIPTION:
; Regression guard for the "IsCategoryGated unknown-category false positive"
; finding. MenuAddItemFromManifest's greying logic checked
; IsCategoryGated(StrSplit(V1CategoryPath, ".")[1]) unconditionally as a
; second, redundant gate on top of _MasterCategoryFor's own check. For every
; category BUT DynamicHotstrings this second check is a harmless no-op
; (their sub-category IS in CategoryEnabled, since Autocorrection /
; DistancesReduction / SFBsReduction / Rolls / MagicKey each have a real,
; independent per-file gate). DynamicHotstrings is the one sub-category
; with NO independent gate -- per menu_hotstrings.ahk's own
; _HS_CategoriesDynamic comment, it "has no separate gate, so it follows
; the master directly" -- so IsCategoryGated("DynamicHotstrings") logged a
; spurious "unknown category" WARNING on every single menu build, for a
; category name that structurally can never appear in CategoryEnabled.
;
; SCOPE: source introspection of ui/menu/menu_engine.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================
; =====================================================
; ======= 1/ DynamicHotstrings is excluded ============
; =====================================================
; =====================================================

_MDHCG_CheckDynamicHotstringsExcluded() {
	Body := _DriverFuncBody("MenuAddItemFromManifest")
	Assert(Body != "", "MenuAddItemFromManifest must exist in ui/menu/menu_engine.ahk")

	Assert(InStr(Body, '"DynamicHotstrings"') > 0,
		'MenuAddItemFromManifest must special-case "DynamicHotstrings" -- it is the one hotstring sub-category with no independent CategoryEnabled entry (it follows the Hotstrings master directly)')

	MasterCheckPos := InStr(Body, "_MasterCategoryFor(V1CategoryPath)")
	Assert(MasterCheckPos > 0, "MenuAddItemFromManifest must still check IsCategoryGated(_MasterCategoryFor(V1CategoryPath))")

	ExclusionPos := InStr(Body, '"DynamicHotstrings"')
	Assert(ExclusionPos > MasterCheckPos,
		"the DynamicHotstrings exclusion must guard the SECOND (sub-category) gate check, not replace the first (master-gate) check")
}
Test("menu: MenuAddItemFromManifest excludes DynamicHotstrings from the redundant sub-category IsCategoryGated check (menu-category-gate-false-positive)",
	_MDHCG_CheckDynamicHotstringsExcluded)

_MDHCG_CheckOtherHotstringSubcategoriesStillChecked() {
	Body := _DriverFuncBody("MenuAddItemFromManifest")
	; The five real per-file sub-categories must still be gated via
	; IsCategoryGated(SubCategory) -- only DynamicHotstrings is excluded.
	Assert(InStr(Body, "IsCategoryGated(SubCategory)") > 0,
		"MenuAddItemFromManifest must still check IsCategoryGated(SubCategory) for real per-file sub-categories (Autocorrection, DistancesReduction, SFBsReduction, Rolls, MagicKey)")
}
Test("menu: MenuAddItemFromManifest still gates the five real per-file hotstring sub-categories (menu-category-gate-false-positive)",
	_MDHCG_CheckOtherHotstringSubcategoriesStillChecked)
