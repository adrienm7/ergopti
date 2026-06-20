; ui/menu/menu_metrics.ahk

; ==============================================================================
; MODULE: Tray Menu / Metrics Submenu
; DESCRIPTION:
; Builds the Metrics category submenu: typing/app tracking entries, privacy filters, app exclusion and the WPM widget options.
;
; Split out of ui/tray_menu.ahk (P5 refactor). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




; Build the « 📊 Métriques » submenu and attach it to the tray. The parent
; entry doubles as an ON/OFF toggle for the global keylogger feature: the
; checkmark reflects MetricsShortcuts.enabled, and clicking it triggers
; ToggleMetricsEnabled() with a confirmation dialog before turning ON.
;
; When the feature is OFF, the sub-items remain visible (so the user can
; still see what the menu looks like) but are disabled — no dashboard can
; open, no shortcut binding takes effect.
BuildMetricsMenu() {
	global A_TrayMenu
	enabled := MetricsShortcuts.enabled

	; Dynamic handlers — each populates the MetricsMenu in place.
	; Closures over ``enabled`` and the label locals below capture the state
	; at build time, matching the previous per-item Disable() calls.

	DynHandlers := Map(
		"show_typing",        (M, C) => _MET_ShowTyping(M, C),
		"shortcut_typing",    (M, C) => _MET_ShortcutTyping(M, C),
		"show_apps",          (M, C) => _MET_ShowApps(M, C),
		"shortcut_apps",      (M, C) => _MET_ShortcutApps(M, C),
		"filter_private",     (M, C) => _MET_FilterPrivate(M, C),
		"filter_secure",      (M, C) => _MET_FilterSecure(M, C),
		"filter_sysauth",     (M, C) => _MET_FilterSysauth(M, C),
		"exclude_apps",       (M, C) => _MET_ExcludeApps(M, C),
		"wpm_widget",         (M, C) => _MET_WpmWidget(M, C),
		"widget_colors",      (M, C) => _MET_WpmWidgetColors(M, C),
		"include_realtime",   (M, C) => _MET_WpmWidgetGraph(M, C),
		"reset_wpm_position", (M, C) => _MET_WpmWidgetReset(M, C),
	)

	MetricsMenu := MenuRenderer_Build("metrics_menu", "Metrics", DynHandlers)
	A_TrayMenu.Add(t("menu.metrics.title"), MetricsMenu)
}

; Dynamic handler: Show Typing button.
_MET_ShowTyping(M, _Cat) {
	Label := t("menu.metrics.show_typing")
	RegisterMenuItem(M, Label, (*) => KLUI_ToggleTyping())
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Typing shortcut picker (label with ZWS to avoid duplicate key clash).
_MET_ShortcutTyping(M, _Cat) {
	Label := t("menu.metrics.shortcut_prefix") . MS_GetDisplayLabel("typing")
	RegisterMenuItem(M, Label, (*) => MS_PromptShortcut("typing", KLUI_ToggleTyping))
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Show Apps button.
_MET_ShowApps(M, _Cat) {
	Label := t("menu.metrics.show_apps")
	RegisterMenuItem(M, Label, (*) => KLUI_ToggleApps())
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Apps shortcut picker (ZWS differentiates from typing sc label).
_MET_ShortcutApps(M, _Cat) {
	Label := t("menu.metrics.shortcut_prefix") . MS_GetDisplayLabel("apps") . Chr(0x200B)
	RegisterMenuItem(M, Label, (*) => MS_PromptShortcut("apps", KLUI_ToggleApps))
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Filter private browsing toggle.
_MET_FilterPrivate(M, _Cat) {
	Label := t("menu.metrics.filter_private")
	RegisterMenuItem(M, Label, ToggleFilterPrivate)
	if MetricsFilters.private_browsing
		M.Check(Label)
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Filter secure field toggle.
_MET_FilterSecure(M, _Cat) {
	Label := t("menu.metrics.filter_secure")
	RegisterMenuItem(M, Label, ToggleFilterSecureField)
	if MetricsFilters.secure_field
		M.Check(Label)
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Filter system auth toggle.
_MET_FilterSysauth(M, _Cat) {
	Label := t("menu.metrics.filter_sysauth")
	RegisterMenuItem(M, Label, ToggleFilterSystemAuth)
	if MetricsFilters.system_auth
		M.Check(Label)
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: App exclusion — label reflects current count.
_MET_ExcludeApps(M, _Cat) {
	n := MF_DisabledCount()
	Label := (n > 0)
		? StrReplace(StrReplace(t("menu.metrics.disabled_in_label"), "%d", n), "%s", (n > 1 ? "s" : ""))
		: t("menu.metrics.exclude_apps")
	RegisterMenuItem(M, Label, OpenMetricsAppPicker)
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: WPM floating widget toggle.
_MET_WpmWidget(M, _Cat) {
	Label := t("menu.metrics.show_wpm_widget")
	ColorsLabel := t("menu.metrics.colors_by_source")
	GraphLabel  := t("menu.metrics.include_realtime")
	RegisterMenuItem(M, Label, (*) => _ToggleWpmWidget(M, Label, ColorsLabel, GraphLabel))
	if WPMWidget.visible
		M.Check(Label)
	if !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Widget colors-by-source sub-option.
_MET_WpmWidgetColors(M, _Cat) {
	Label := t("menu.metrics.colors_by_source")
	RegisterMenuItem(M, Label, (*) => _ToggleWpmWidgetColors(M, Label))
	if WPMWidget.visible && WPMWidget.use_colors
		M.Check(Label)
	if !WPMWidget.visible or !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Include realtime graph sub-option.
_MET_WpmWidgetGraph(M, _Cat) {
	Label := t("menu.metrics.include_realtime")
	RegisterMenuItem(M, Label, (*) => _ToggleWpmWidgetGraph(M, Label))
	if WPMWidget.visible && WPMWidget.show_graph
		M.Check(Label)
	if !WPMWidget.visible or !MetricsShortcuts.enabled
		M.Disable(Label)
}

; Dynamic handler: Reset WPM widget position.
_MET_WpmWidgetReset(M, _Cat) {
	Label := t("menu.metrics.reset_wpm_position")
	RegisterMenuItem(M, Label, (*) => WPMWidget_ResetPosition())
	if !WPMWidget.visible or !MetricsShortcuts.enabled
		M.Disable(Label)
}

; ── Layout dynamic handlers ────────────────────────────────────────────────────

