; ui/menu/menu_metrics.ahk

; ==============================================================================
; MODULE: Tray Menu / Metrics Submenu
; DESCRIPTION:
; Builds the Metrics category submenu: typing/app tracking entries, privacy filters, app exclusion and the WPM widget options.
;
; Split out of menu/ui/tray_menu.ahk (the module split). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================

#Include %A_LineFile%\..\..\..\_generated\config_keys.ahk




; Canonical state-key getters for the ``disabled_when`` resolver (MG-1) —
; maps the manifest's driver-neutral keys to the concrete AHK state reads
; they proxy. Shared by every dynamic handler below so the dependency graph
; (which item greys out on which toggle) lives once in menu_manifest.json
; instead of being re-derived per handler.
global _MET_STATE_GETTERS := Map(
	"keystats_enabled",       () => MetricsShortcuts.enabled,
	; The notification-area readout (wpm_tray_readout.ahk), the macOS menu bar
	; and Linux tray readout's counterpart.
	"metrics_menubar_wpm",     () => WPMTrayReadout.running,
	"metrics_menubar_colors",  () => WPMTrayReadout.use_colors,
	ConfigLeaf.WPM_MENUBAR_VISIBLE,     () => WPMTrayReadout.running,
	ConfigLeaf.WPM_WIDGET_VISIBLE,      () => WPMWidget.visible,
	"metrics_widget_colors",   () => WPMWidget.use_colors,
	"metrics_widget_graph",    () => WPMWidget.show_graph,
	; Read by the manifest's checked_when predicates, so the checkmark state is
	; declared beside the row rather than restated in each handler.
	"metrics_filter_private",  () => MetricsFilters.private_browsing,
	"metrics_filter_secure",   () => MetricsFilters.secure_field,
	"metrics_filter_sysauth",  () => MetricsFilters.system_auth,
	; The encryption row became `check` on 2026-08-07, so its tick is read here
	; instead of being set by a handler.
	"metrics_encrypt_enabled", () => KL_Enc_IsEnabled(),
	; The user's pause from the Metrics menu, ticked from the pause state itself.
	"metrics_suspended",       () => KL_IsCollectionSuspended(),
)

; Build the « 📊 Métriques » submenu. The caller publishes the completed tree
; to the tray, so expensive renderer work never runs after the live root has
; been cleared. Its first row is the category switch for the global keystats
; feature: ticked from MetricsShortcuts.enabled, and clicking it runs
; ToggleMetricsEnabled() with a confirmation dialog before turning ON. The
; parent entry carries the same tick but cannot be clicked: a Win32 item that
; opens a submenu sends no command.
;
; When the feature is OFF, the sub-items remain visible (so the user can
; still see what the menu looks like) but are disabled — no dashboard can
; open, no shortcut binding takes effect.
BuildMetricsMenu() {
	global A_TrayMenu, _MET_STATE_GETTERS

	; The shared declaration owns labels, checks and disabled predicates.
	; This driver supplies native state reads and committed click effects.
	DynHandlers := Map()
	Commands := _MET_ScopeCommands()
	for Id, Handler in Map(
		MenuCommand.METRICS_TOGGLE,  (*) => ToggleMetricsEnabled(),
		MenuCommand.WPM_MENUBAR,     (*) => _ToggleWpmTrayReadout(),
		MenuCommand.MENUBAR_COLORS,  (*) => _ToggleWpmTrayReadoutColors(),
		MenuCommand.WPM_WIDGET,      (*) => _ToggleWpmWidget(),
		MenuCommand.WIDGET_COLORS,   (*) => _ToggleWpmWidgetColors(),
		MenuCommand.INCLUDE_REALTIME, (*) => _ToggleWpmWidgetGraph(),
		MenuCommand.FILTER_PRIVATE,  ToggleFilterPrivate,
		MenuCommand.FILTER_SECURE,   ToggleFilterSecureField,
		MenuCommand.FILTER_SYSAUTH,  ToggleFilterSystemAuth,
		"encryption",         ToggleAtRestEncryption,
		MenuCommand.RESET_WPM_POSITION, (*) => WPMWidget_ResetPosition(),
		MenuCommand.SHOW_TYPING,     KLUI_ToggleTyping,
		MenuCommand.SHOW_APPS,       KLUI_ToggleApps,
		MenuCommand.METRICS_SUSPEND, (*) => ToggleMetricsCollectionPause(),
		MenuCommand.METRICS_RESET_SESSION, (*) => ResetMetricsSession(),
	)
		Commands[Id] := Handler

	; Only the app-exclusion count requires a computed label.
	ListProviders := Map(
		"exclude_apps", (*) => _MET_ExcludeAppsRows(_MET_STATE_GETTERS)
	)

	return MenuRenderer_Build("metrics_menu", "Metrics", DynHandlers, "", ListProviders, Commands, _MET_STATE_GETTERS)
}

; The Metrics menu's pause row. Pausing stores the text already typed, then stops
; recording until the row is ticked off or the driver reloads; the tick is
; repainted from the pause state itself.
ToggleMetricsCollectionPause(SuspendFn := 0, ResumeFn := 0, RebuildFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return ToggleMetricsCollectionPause(SuspendFn, ResumeFn, RebuildFn)
		finally Critical(InheritedCritical)
	}
	if KL_IsCollectionSuspended()
		HasMethod(ResumeFn, "Call") ? ResumeFn.Call() : KL_ResumeCollection()
	else
		HasMethod(SuspendFn, "Call") ? SuspendFn.Call() : KL_SuspendCollection()
	return _MET_RebuildWidgetMenu(RebuildFn)
}

; The Metrics menu's session-reset row: ends the typing session, stores what is
; pending, and restarts the live figures. Stored history is untouched.
ResetMetricsSession(ResetFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return ResetMetricsSession(ResetFn)
		finally Critical(InheritedCritical)
	}
	return HasMethod(ResetFn, "Call") ? ResetFn.Call() : KL_ResetSession()
}

; List provider: App exclusion — label reflects current count.
_MET_ExcludeAppsRows(Getters) {
	n := MF_DisabledCount()
	return [Map(
		"label", (n > 0)
			? StrReplace(StrReplace(t("menu.metrics.disabled_in_label"), "%d", n), "%s", (n > 1 ? "s" : ""))
			: t("menu.metrics.exclude_apps"),
		"disabled", MenuRenderer_ResolveDisabledWhen("metrics_menu", "exclude_apps", Getters),
		"action",   OpenMetricsAppPicker)]
}

; Consent is excluded from recommendations by the shared scope declaration.
; The restore alone: the maintainer retired the Metrics clear on 2026-09-30.
; The Configuration clear still composes the metrics settings.
_MET_ScopeCommands(Options := unset) {
	Commands := ConfigScopeMenuCommands("metrics", Map(), IsSet(Options) ? Options : Map())
	Commands.Delete(MenuCommand.SCOPE_CLEAR)
	return Commands
}
