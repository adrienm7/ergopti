; ui/tray_menu.ahk

; ==============================================================================
; MODULE: Tray Menu
; DESCRIPTION:
; Builds and manages the Windows system tray icon and right-click context menu.
;
; FEATURES & RATIONALE:
; 1. Full menu hierarchy: hotstrings, metrics, shortcuts, gestures and more.
; 2. Extracted from ErgoptiPlus.ahk to keep the boot file focused on
;    initialization and hotstring routing.
; ==============================================================================

global SubMenus := Map()

#Include menu/menu_engine.ahk
#Include menu/menu_gestures.ahk
#Include menu/menu_metrics.ahk
#Include menu/menu_layout.ahk
#Include menu/menu_hotstrings.ahk
#Include menu/menu_metrics_actions.ahk

; Runs the auto-configure — success is already indicated by the green status label in the UI,
; so only failures surface a blocking dialog (the user must know something went wrong).
GestureAutoConfigureAction() {
	Success := GestureAutoConfigureRegistry()
	if (!Success) {
		MsgBox(
			t("dialog.gestures.auto_configure_error"),
			t("dialog.gestures.auto_configure_error_title"),
			"Icon!"
		)
	}
}

; =========================
; Main menu initialization
; =========================

global MenuHotstrings := "⚡ Hotstrings"
global MenuConfigurationShortcuts := t("menu.script_control.title")
; Holds the « Suspendre » label so UpdateTrayIcon can check/uncheck the
; entry by its exact text on A_TrayMenu. Re-assigned in initMenu so future
; label tweaks (icons, hints) only need to change the menu builder.
global MenuSuspend := t("menu.global.suspend")
global MenuDebugging := t("menu.debug.title")

; Load category lists from the shared manifest instead of hard-coding them here
global _HotstringGroups        := MenuManifest_LoadHotstringGroups()
global HotstringCategories     := _HotstringGroups.all
global HotstringCategoriesStd  := _HotstringGroups.standard
global HotstringCategoriesErgopti := _HotstringGroups.ergopti

; v1 category names for the flat hotstring categories that have a 1:1
; mapping to a manifest section — each rendered as a flat list of
; toggles by InitSubMenus.
global _FLAT_HOTSTRING_V1_CATS := ["Autocorrection", "DistancesReduction",
	"SFBsReduction", "Rolls", "MagicKey"]

; v1 -> v2 category name map used by _CountEnabledForCategory
global _V1CatToV2CatMap := Map(
	"Autocorrection",     "autocorrection",
	"DistancesReduction", "distances_reduction",
	"SFBsReduction",      "sfbs_reduction",
	"Rolls",              "rolls",
	"MagicKey",           "magic_key",
)

; Per-category inverse maps (v2 snake_case id -> v1 PascalCase) so that
; _CountEnabledForCategory can resolve the TOML section name via FoldAsciiLower(v1).
global _V1CatToInverseKeyMap := Map(
	"Autocorrection",     _ManifestToLegacyAutocorrectionKeyMap,
	"DistancesReduction", _ManifestToLegacyDistancesReductionKeyMap,
	"SFBsReduction",      _ManifestToLegacySFBsReductionKeyMap,
	"Rolls",              _ManifestToLegacyRollsKeyMap,
	"MagicKey",           _ManifestToLegacyMagicKeyKeyMap,
)

; Custom render order for the ``DynamicHotstrings`` submenu — the manifest
; doesn't yet model menu order or separators, so the curated UX layout is
; pinned here as a sidecar. Each entry is either a v1 PascalCase feature id
; or "-" (separator). When the manifest grows ``menu_order`` /
; ``menu_separator`` metadata this constant can move into the codegen.
global _DYNAMIC_HOTSTRINGS_ORDER := ["DateLongFr", "DateFr", "Date",
	"PhonePrefixes", "SsnPrefixes", "IbanPrefixes", "-",
	"TextExpansionPersonalInformation"]


#Include menu/menu_submenus.ahk
#Include menu/menu_shortcuts.ahk
#Include menu/menu_taphold.ahk
#Include menu/menu_init.ahk
#Include menu/menu_actions.ahk
#Include menu/menu_rebuild.ahk
