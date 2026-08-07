; ui/menu/menu_metrics.ahk

; ==============================================================================
; MODULE: Tray Menu / Metrics Submenu
; DESCRIPTION:
; Builds the Metrics category submenu: typing/app tracking entries, privacy filters, app exclusion and the WPM widget options.
;
; Split out of ui/tray_menu.ahk (the module split). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




; Canonical state-key getters for the ``disabled_when`` resolver (MG-1) —
; maps the manifest's driver-neutral keys to the concrete AHK state reads
; they proxy. Shared by every dynamic handler below so the dependency graph
; (which item greys out on which toggle) lives once in menu_manifest.json
; instead of being re-derived per handler.
global _MET_STATE_GETTERS := Map(
	"keylogger_enabled",       () => MetricsShortcuts.enabled,
	"wpm_widget_visible",      () => WPMWidget.visible,
	; Read by the manifest's checked_when predicates, so the checkmark state is
	; declared beside the row rather than restated in each handler.
	"metrics_filter_private",  () => MetricsFilters.private_browsing,
	"metrics_filter_secure",   () => MetricsFilters.secure_field,
	"metrics_filter_sysauth",  () => MetricsFilters.system_auth,
)

; Build the « 📊 Métriques » submenu. The caller publishes the completed tree
; to the tray, so expensive renderer work never runs after the live root has
; been cleared. The parent
; entry doubles as an ON/OFF toggle for the global keylogger feature: the
; checkmark reflects MetricsShortcuts.enabled, and clicking it triggers
; ToggleMetricsEnabled() with a confirmation dialog before turning ON.
;
; When the feature is OFF, the sub-items remain visible (so the user can
; still see what the menu looks like) but are disabled — no dashboard can
; open, no shortcut binding takes effect.
BuildMetricsMenu() {
	global A_TrayMenu, _MET_STATE_GETTERS

	; Dynamic handlers — each populates the MetricsMenu in place, resolving
	; its own grey-out state from the manifest's disabled_when predicate.

	DynHandlers := Map(
		"shortcut_typing",    (M, C) => _MET_ShortcutTyping(M, C, _MET_STATE_GETTERS),
		"shortcut_apps",      (M, C) => _MET_ShortcutApps(M, C, _MET_STATE_GETTERS),
		"exclude_apps",       (M, C) => _MET_ExcludeApps(M, C, _MET_STATE_GETTERS),
		"wpm_widget",         (M, C) => _MET_WpmWidget(M, C, _MET_STATE_GETTERS),
		"widget_colors",      (M, C) => _MET_WpmWidgetColors(M, C, _MET_STATE_GETTERS),
		"include_realtime",   (M, C) => _MET_WpmWidgetGraph(M, C, _MET_STATE_GETTERS),
		"reset_wpm_position", (M, C) => _MET_WpmWidgetReset(M, C, _MET_STATE_GETTERS),
		"encryption",         (M, C) => _MET_Encryption(M, C, _MET_STATE_GETTERS),
	)

	; The three privacy filters left DynHandlers on 2026-08-06: their manifest
	; rows are `type = "check"`, so the renderer builds them from the
	; declaration and this file supplies only the behaviour. One row shape for
	; three drivers, which is what the manifest was for.
	; show_typing and show_apps left DynHandlers on 2026-08-07: their manifest
	; rows are `command` now, so the renderer builds the label and applies the
	; greying from the declaration and this driver supplies only the click.
	Commands := Map(
		"filter_private",  ToggleFilterPrivate,
		"filter_secure",   ToggleFilterSecureField,
		"filter_sysauth",  ToggleFilterSystemAuth,
		"show_typing",     KLUI_ToggleTyping,
		"show_apps",       KLUI_ToggleApps,
	)

	MetricsMenu := MenuRenderer_Build("metrics_menu", "Metrics", DynHandlers, "", "", Commands, _MET_STATE_GETTERS)
	; Metrics toggle uses a dedicated fn (confirm/security-warning dialogs +
	; MetricsShortcuts.enabled + MS_SaveToIni) rather than the generic
	; ToggleCategoryAllFeatures used by manifest-only menus — same pattern
	; Gestures uses (see BuildGesturesMenu / AddCategoryToggleItem). The
	; manifest's metrics_menu toggle entry carries platforms:["hs"] so the
	; generic renderer never double-renders this row on AHK.
	AddCategoryToggleItem(MetricsMenu,
		t("menu.metrics.on"), t("menu.metrics.off"),
		MetricsShortcuts.enabled, (*) => ToggleMetricsEnabled())
	return MetricsMenu
}

; Dynamic handler: Typing shortcut picker (label with ZWS to avoid duplicate key clash).
_MET_ShortcutTyping(M, _Cat, Getters) {
	Label := t(MenuRenderer_I18nDynamic("metrics_menu", "shortcut_typing")) . MS_GetDisplayLabel("typing")
	RegisterMenuItem(M, Label, (*) => MS_PromptShortcut("typing", KLUI_ToggleTyping))
	if MenuRenderer_ResolveDisabledWhen("metrics_menu", "shortcut_typing", Getters)
		M.Disable(Label)
}

; Dynamic handler: Apps shortcut picker (ZWS differentiates from typing sc label).
_MET_ShortcutApps(M, _Cat, Getters) {
	Label := t(MenuRenderer_I18nDynamic("metrics_menu", "shortcut_apps")) . MS_GetDisplayLabel("apps") . Chr(0x200B)
	RegisterMenuItem(M, Label, (*) => MS_PromptShortcut("apps", KLUI_ToggleApps))
	if MenuRenderer_ResolveDisabledWhen("metrics_menu", "shortcut_apps", Getters)
		M.Disable(Label)
}




; Dynamic handler: At-rest encryption toggle.
_MET_Encryption(M, _Cat, Getters) {
	Label := t("menu.metrics.encrypt_toggle")
	RegisterMenuItem(M, Label, ToggleAtRestEncryption)
	if KL_Enc_IsEnabled()
		M.Check(Label)
	if MenuRenderer_ResolveDisabledWhen("metrics_menu", "encryption", Getters)
		M.Disable(Label)
}

; Dynamic handler: App exclusion — label reflects current count.
_MET_ExcludeApps(M, _Cat, Getters) {
	n := MF_DisabledCount()
	Label := (n > 0)
		? StrReplace(StrReplace(t("menu.metrics.disabled_in_label"), "%d", n), "%s", (n > 1 ? "s" : ""))
		: t("menu.metrics.exclude_apps")
	RegisterMenuItem(M, Label, OpenMetricsAppPicker)
	if MenuRenderer_ResolveDisabledWhen("metrics_menu", "exclude_apps", Getters)
		M.Disable(Label)
}

; Dynamic handler: WPM floating widget toggle.
_MET_WpmWidget(M, _Cat, Getters) {
	Label := t("menu.metrics.show_wpm_widget")
	ColorsLabel := t("menu.metrics.colors_by_source")
	GraphLabel  := t("menu.metrics.include_realtime")
	RegisterMenuItem(M, Label, (*) => _ToggleWpmWidget(M, Label, ColorsLabel, GraphLabel))
	if WPMWidget.visible
		M.Check(Label)
	if MenuRenderer_ResolveDisabledWhen("metrics_menu", "wpm_widget", Getters)
		M.Disable(Label)
}

; Dynamic handler: Widget colors-by-source sub-option.
_MET_WpmWidgetColors(M, _Cat, Getters) {
	Label := t("menu.metrics.colors_by_source")
	RegisterMenuItem(M, Label, (*) => _ToggleWpmWidgetColors(M, Label))
	if WPMWidget.visible && WPMWidget.use_colors
		M.Check(Label)
	if MenuRenderer_ResolveDisabledWhen("metrics_menu", "widget_colors", Getters)
		M.Disable(Label)
}

; Dynamic handler: Include realtime graph sub-option.
_MET_WpmWidgetGraph(M, _Cat, Getters) {
	Label := t("menu.metrics.include_realtime")
	RegisterMenuItem(M, Label, (*) => _ToggleWpmWidgetGraph(M, Label))
	if WPMWidget.visible && WPMWidget.show_graph
		M.Check(Label)
	if MenuRenderer_ResolveDisabledWhen("metrics_menu", "include_realtime", Getters)
		M.Disable(Label)
}

; Dynamic handler: Reset WPM widget position.
_MET_WpmWidgetReset(M, _Cat, Getters) {
	Label := t("menu.metrics.reset_wpm_position")
	RegisterMenuItem(M, Label, (*) => WPMWidget_ResetPosition())
	if MenuRenderer_ResolveDisabledWhen("metrics_menu", "reset_wpm_position", Getters)
		M.Disable(Label)
}

; ── Layout dynamic handlers ────────────────────────────────────────────────────
