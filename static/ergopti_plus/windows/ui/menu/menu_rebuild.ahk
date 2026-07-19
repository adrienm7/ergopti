; ui/menu/menu_rebuild.ahk

; ==============================================================================
; MODULE: Tray Menu / Live Rebuild & Logging
; DESCRIPTION:
; Live hotstrings rebuild, full tray-menu rebuild and the log-level submenu (selector, label, emoji) used to change the logger verbosity at runtime.
;
; Split out of ui/tray_menu.ahk (P5 refactor). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




; Re-run the hotstring registration in-process so a section toggle takes effect
; immediately, with no script Reload. Clears the HSE engine and its buffer, then
; re-runs RegisterAllHotstrings(): it re-evaluates every Features guard and
; recomputes SpaceAroundSymbols. The Ê deadkey and "…" ellipsis are now HSE
; raw-callback hotstrings (no native Hotstring()), so they are cleared and
; re-registered here like every other section; they stay reload-only in the
; blocklist, so toggling one of them DIRECTLY still reloads (see
; hotstring_live_toggle.ahk). Finally rebuilds the preview index and tray.
RebuildHotstringsLive() {
	try LoggerStart("Menu", "Rebuilding hotstrings in-process (live toggle)…")
	try {
		try SetTimer(RegisterEmojisSymbolsDeferred, 0)
		HSE_RebuildInProgress := true
		try {
			; Wrap clear + re-register in Critical so an InputHook OnChar callback
			; cannot observe an empty or partially-populated registry mid-rebuild
			_RblCrit := Critical("On")
			try {
				HSE_RegistryClear()
				RegisterAllHotstrings()
			} finally {
				Critical(_RblCrit)
			}
		} finally {
			HSE_RebuildInProgress := false
		}
		; HardReset only after the registry is fully populated and the guard is
		; cleared; skip when a send burst is in flight (HSE_Suppressed > 0) so we
		; do not clobber a live expansion's buffer state. Pair with
		; _ResetPrefixBuffer() — every other HSE_HardReset call site (LLM_Bridge_OnAccept,
		; LLM_Engine_OnResults inline auto-type) does the same, and this was the sole
		; production call site that omitted it, leaving the tooltip preview buffer
		; desynced from the freshly rebuilt matching engine.
		if HSE_Suppressed == 0 {
			HSE_HardReset()
			_ResetPrefixBuffer()
		}
		if IsSet(HotstringPrefixWatcherRebuildIndex) {
			HotstringPrefixWatcherRebuildIndex()
		}
		RebuildTrayMenu()
		try LoggerSuccess("Menu", "Hotstrings rebuilt in-process.")
	} catch as e {
		try LoggerError("Menu", "Hotstring live rebuild failed: {1}", e.Message)
		throw e
	}
}

; Reconstructs the tray menu in place without a full process restart.
; Suitable for lightweight UI-only toggles (WPM display, color themes) that
; do not require re-parsing config or rebinding hotkeys. State-changing
; hotstring section toggles rebuild in-process via RebuildHotstringsLive; other
; state-changing toggles (layout, tap-holds, shortcuts) still call Reload().
RebuildTrayMenu() {
	global SubMenus
	; Clear the dispatch bypass Maps BEFORE deleting + repopulating the menu.
	; AHK reuses freed menu-item IDs after Menu.Delete(); a stale entry left in
	; the Maps could bind a reused ID to a different item's callback and fire
	; the WRONG action on a dropped-click retry (see menu_dispatcher.ahk).
	MenuDispatcher_Reset()
	A_TrayMenu.Delete()
	SubMenus := Map()
	; Force a fresh personal-hotstrings extension-tree scan on every explicit
	; rebuild. Without this, _HS_PreScanPersonalCacheLoaded latches true after
	; the first scan and a personal extension .toml added/edited mid-session
	; (outside the editor) never surfaces in the tray menu again
	; (personal-hotstring-cache-never-invalidated). Safe here specifically
	; because RebuildTrayMenu, unlike BuildTrayMenuDeferred's boot pass, runs
	; off the Critical path — see BuildTrayMenuDeferred's own comment on why
	; its InitSubMenus() call must keep hitting an already-warm cache instead.
	_HS_InvalidatePersonalCache()
	InitSubMenus()
	initMenu()
}

; Sets the active log level at runtime without a full script restart.
; Mutates LOGGER_MIN_LEVEL, refreshes the cached fast-path flags, and
; persists the choice under [Script] LogLevel in the user's config.toml
; so the level is restored on the next boot.
LoggerSetLevel(Level) {
	global LOGGER_MIN_LEVEL, LOGGER_SEVERITY, ConfigurationFile
	if !LOGGER_SEVERITY.Has(Level) {
		try LoggerWarn("Menu", "LoggerSetLevel: unknown level '{1}' — ignoring.", Level)
		return
	}
	LOGGER_MIN_LEVEL := Level
	_LoggerRefreshFastFlags()
	try TOML_Write(Level, ConfigurationFile, "script", "log_level")
	try LoggerInfo("Menu", "Log level set to {1}.", Level)
	RebuildTrayMenu()
}

; Returns the label shown for the log-level submenu entry, including the
; active level so the user can see the current setting without opening the submenu.
_LogLevelMenuLabel() {
	global LOGGER_MIN_LEVEL
	return t("menu.debug.log_level") . " : " . _LogLevelEmoji(LOGGER_MIN_LEVEL) . " " . LOGGER_MIN_LEVEL
}

; Build the log level submenu for the Debug entry. Returns a Menu object
; with one item per severity level (DEBUG / INFO / WARNING / ERROR),
; the currently active level pre-checked.
_BuildLogLevelMenu() {
	global LOGGER_MIN_LEVEL
	LevelMenu := Menu()
	for _, Level in ["DEBUG", "INFO", "WARNING", "ERROR"] {
		; Capture loop variable for the callback closure
		_Lvl := Level
		Label := _LogLevelEmoji(Level) . " " . Level
		RegisterMenuItem(LevelMenu, Label, ((_l) => (*) => LoggerSetLevel(_l))(Level))
		if (LOGGER_MIN_LEVEL == Level) {
			LevelMenu.Check(Label)
		}
	}
	return LevelMenu
}

_LogLevelEmoji(Level) {
	switch Level {
		case "DEBUG":   return "🐛"
		case "INFO":    return "ℹ️"
		case "WARNING": return "⚠️"
		case "ERROR":   return "❌"
		default:        return "📝"
	}
}
