; ui/menu/menu_metrics_actions.ahk

; ==============================================================================
; MODULE: Tray Menu / Metrics Actions
; DESCRIPTION:
; Click-handler actions for the Metrics submenu: privacy-filter toggles, WPM widget toggles, the app-exclusion picker and the master metrics enable/disable toggle.
;
; Split out of ui/tray_menu.ahk (P5 refactor). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




; ── Filter toggles. Each persists + flips the corresponding flag and
; triggers a Reload so the menu rerenders with the new checkmark state
; (AHK Menu.Check / Uncheck cannot retro-update an entry whose label was
; built into the submenu reference; rebuilding the whole tray is cleaner
; than playing with .ToggleCheck on a stale label).
ToggleFilterPrivate(*) {
	MetricsFilters.private_browsing := !MetricsFilters.private_browsing
	MF_SaveToIni()
	Reload
}

ToggleFilterSecureField(*) {
	MetricsFilters.secure_field := !MetricsFilters.secure_field
	MF_SaveToIni()
	Reload
}

ToggleFilterSystemAuth(*) {
	MetricsFilters.system_auth := !MetricsFilters.system_auth
	MF_SaveToIni()
	Reload
}

; ── WPM toggle helpers — closures capture the menu reference and label strings
; from BuildMetricsMenu locals, so no global state is needed. ──────────────────

_ToggleWpmWidget(menu, widget_lbl, colors_lbl, graph_lbl) {
    if !WPMWidget_Toggle()
        return
	try menu.ToggleCheck(widget_lbl)
	if WPMWidget.visible {
		try menu.Enable(colors_lbl)
		try menu.Enable(graph_lbl)
	} else {
		try menu.Disable(colors_lbl)
		try menu.Disable(graph_lbl)
	}
}

_ToggleWpmWidgetColors(menu, label) {
    TargetColors := !WPMWidget.use_colors
    if !WPMWidget_SaveConfig(TargetColors)
        return
    WPMWidget.use_colors := TargetColors
    try menu.ToggleCheck(label)
}

_ToggleWpmWidgetGraph(menu, label) {
    was_visible := WPMWidget.visible
    TargetGraph := !WPMWidget.show_graph
    ; Graph and its anchor form one persisted state. Commit the reset before
    ; destroying the live surface, so a disk failure leaves the current widget
    ; fully usable and its menu checkmark unchanged.
    if !WPMWidget_SaveConfig(unset, TargetGraph, -1, -1)
        return
    ; Rebuild the widget in the new mode — compact and graph use different Gui layouts.
    if was_visible
        WPMWidget_Hide()
    WPMWidget.show_graph := TargetGraph
	; Destroy existing GUI so it is rebuilt in the correct layout on next show.
	if WPMWidget._gui {
		try WPMWidget._gui.Destroy()
		WPMWidget._gui      := false
		WPMWidget._lbl_wpm  := false
		WPMWidget._lbl_unit := false
	}
	if WPMWidget._graph_gui {
		try WPMWidget._graph_gui.Destroy()
		WPMWidget._graph_gui := false
	}
	; Reset saved position so default bottom-right is recalculated for new size.
    WpmWidget.pos_x := -1
    WpmWidget.pos_y := -1
    try menu.ToggleCheck(label)
	if was_visible
		WPMWidget_Show()
}

OpenMetricsAppPicker(*) {
	AppPicker_Show(Map(
		"title",    t("dialog.metrics.exclude_title"),
		"prompt",   t("dialog.metrics.exclude_prompt"),
		"ok_label", t("dialog.metrics.exclude_ok"),
		"initial",  MF_DisabledList(),
		"on_save",  OnMetricsAppPickerSave
	))
}

OnMetricsAppPickerSave(selected) {
	; Replace the disabled-apps map wholesale with the picker's result —
	; the user expects "what's checked = what's filtered", not "diff
	; against the previous state".
	MetricsFilters.disabled_apps := Map()
	for _, proc in selected
		MetricsFilters.disabled_apps[StrLower(proc)] := true
	MF_SaveToIni()
	Reload
}

; Flip the global keylogger feature with a warning dialog before enabling.
; Persisted via metrics_shortcuts.ini and applied on Reload (the keylogger
; can only initialise its file IO at boot, not mid-session, mirroring the
; Hammerspoon behaviour where toggling the feature triggers HS reload).
ToggleMetricsEnabled() {
	if MetricsShortcuts.enabled {
		; Disabling — no warning needed, just confirm.
		res := MsgBox(
			t("dialog.metrics.disable_confirm"),
			t("dialog.metrics.title"),
			"OKCancel Icon?"
		)
		if (res != "OK")
			return
		MetricsShortcuts.enabled := false
		MS_SaveToIni()
		Reload
		return
	}

	; Enabling — explicit warning, OK is the dangerous action. The metrics
	; folder lives under the user-resolved _ConfigDir (paths.toml override
	; honoured) so the displayed path matches reality, even when the user
	; has relocated their config.
	global _ConfigDir
	metrics_path := _ConfigDir . "metrics"
	warn := Format(t("dialog.metrics.enable_warning"), metrics_path)
	; Icon! = exclamation triangle (warning). Iconx is the red error stop
	; sign and was the wrong choice for a "you are about to enable a
	; logging feature" notice.
	res := MsgBox(warn, t("dialog.metrics.security_warning_title"), "OKCancel Icon!")
	if (res != "OK")
		return
	MetricsShortcuts.enabled := true
	MS_SaveToIni()
	Reload
}
