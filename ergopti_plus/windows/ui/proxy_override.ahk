; ui/proxy_override.ahk

; ==============================================================================
; MODULE: Proxy Override Row (Windows)
; DESCRIPTION:
; Debug > proxy for downloads: the twin of the shared edit flow
; (_shared/lua/network/proxy_override.lua `edit`) over this driver's dialogs and
; config.toml. A value that is refused is never stored; a saved one applies to the
; next download. Logs name the mode only, never a relay.
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * The menu command.
 * @returns {Boolean} Whether a value was saved.
 */
ProxyOverride_Command(*) {
	return ProxyOverride_Edit(_ProxyOverride_DefaultPorts())
}

/**
 * Runs the row over its ports.
 * @param {Map} Ports get(), set(Value), prompt(Title, Text, Initial) -> String or
 *   false on cancel, error(Title, Text), info(Title, Text).
 * @returns {Boolean} Whether a value was saved.
 */
ProxyOverride_Edit(Ports) {
	Title := t("proxy_override.title")
	Stored := Ports["get"].Call()
	Typed := Ports["prompt"].Call(Title, t("proxy_override.prompt"), Stored is String ? Stored : "")
	if !(Typed is String)
		return false
	Choice := ProxyOverride_Parse(Typed)
	if !(Choice is Map) {
		LoggerWarn("ProxyOverride", "Proxy override refused: the typed value is not a relay URL, direct or empty.")
		Ports["error"].Call(Title, t("proxy_override.invalid"))
		return false
	}
	if Ports["set"].Call(ProxyOverride_Canonical(Choice)) != true {
		LoggerError("ProxyOverride", "Proxy override not saved: the settings store refused the write.")
		Ports["error"].Call(Title, t("proxy_override.not_saved"))
		return false
	}
	LoggerInfo("ProxyOverride", "Proxy override saved: {1}.", Choice["mode"])
	Ports["info"].Call(Title, t("proxy_override.saved_" . Choice["mode"]))
	return true
}

; A value edited by hand that cannot be used: every download refuses until the row
; or the file corrects it, so the user is told at start, not at the first failure.
ProxyOverride_SayStoredRefused(*) {
	Ui_MsgBox(t("proxy_override.invalid"), t("proxy_override.title"), "Icon!")
}

; Production ports: config.toml, then the value every next child inherits.
_ProxyOverride_DefaultPorts() {
	return Map(
		"get", () => _ProxyOverrideStored,
		"set", _ProxyOverride_Store,
		"prompt", _ProxyOverride_Prompt,
		"error", (Title, Text) => Ui_MsgBox(Text, Title, "Icon!"),
		"info", (Title, Text) => Ui_MsgBox(Text, Title, "Iconi"))
}

_ProxyOverride_Store(Value) {
	global ConfigurationFile
	Stored := ProxyOverride_Seal(Value)
	if !(Stored is String)
		return false
	Declaration := ProxyOverride_Declaration()
	Updates := [{ Section: Declaration["section"], Key: Declaration["key"], Value: Stored }]
	return ConfigCommitUpdates(ConfigurationFile, Updates, "the proxy override", 0, 0,
		(*) => ProxyOverride_Publish(Stored))
}

/**
 * Schedules the sealing below: the boot calls this once it is ready, since a
 * commit replaces the configuration snapshot the boot readers hold.
 * @param ScheduleFn {Func} Test seam taking the sealing, a one-shot timer by default.
 */
ProxyOverride_ScheduleSealAtStart(ScheduleFn := 0) {
	if HasMethod(ScheduleFn, "Call")
		ScheduleFn.Call(ProxyOverride_SealStoredAtStart)
	else
		SetTimer(ProxyOverride_SealStoredAtStart, -1)
}

/**
 * Moves a password still clear in config.toml into its DPAPI envelope, once: the
 * stored form then says it is done.
 * @returns {Boolean} Whether the value was sealed now.
 */
ProxyOverride_SealStoredAtStart(*) {
	global _ProxyOverrideSealed
	Choice := ProxyOverride_Current()
	if !(Choice is Map) || Choice["mode"] != "relay" || _ProxyOverrideSealed
			|| !ProxyOverride_CarriesCredentials(Choice["relay"])
		return false
	if _ProxyOverride_Store(Choice["relay"]) != true {
		LoggerError("ProxyOverride", "The stored proxy credentials could not be sealed: they stay in the file until the next start.")
		return false
	}
	LoggerInfo("ProxyOverride", "The stored proxy credentials are sealed.")
	return true
}

_ProxyOverride_Prompt(Title, Text, Initial) {
	Box := Ui_InputBox(Text, Title, "w560 h200", Initial)
	return Box.Result == "OK" ? Box.Value : false
}
