; core/network/proxy_override.ahk

; ==============================================================================
; MODULE: Proxy Override Row (Windows)
; DESCRIPTION:
; Debug > proxy for downloads: the twin of the shared edit flow
; (_shared/core/network/engine/proxy_override.lua `edit`) over this driver's dialogs and
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

_ProxyOverride_Store(Value, BootSource := 0) {
	global ConfigurationFile
	Stored := ProxyOverride_Seal(Value)
	if !(Stored is String)
		return false
	Publication := _ProxyOverride_PreparePublication(Stored)
	if !Publication.usable
		return false
	Declaration := ProxyOverride_Declaration()
	Section := Declaration["section"], Key := Declaration["key"]
	if !_ProxyOverride_FeatureTargetReady(Section, Key)
		return ConfigReportPersistenceFailure("the proxy override", 0,
			"the native proxy feature state is unavailable")
	Updates := [{ Section: Section, Key: Key, Value: Stored }]
	if !IsObject(BootSource)
		return ConfigCommitUpdates(ConfigurationFile, Updates, "the proxy override", 0, 0,
			_ProxyOverride_PublishStored.Bind(Publication, Section, Key))
	Path := BootSource.Path
	Lease := _ConfigWriteLeaseTryAcquire(Path, "proxy-boot-seal")
	if !(Lease is Object)
		return _ConfigReportPathPersistenceFailure(Path, "the proxy override", 0,
			"another configuration transaction is already in progress")
	try return ConfigCommitBuilt(Path, "the proxy override",
		_ProxyOverride_BuildBootSeal.Bind(BootSource, Lease, Path, Updates, Publication, Section, Key),
		_ProxyOverride_WriteBootSource.Bind(BootSource, Lease), 0, Lease)
	finally _ConfigWriteLeaseRelease(Lease)
}

_ProxyOverride_FeatureTargetReady(Section, Key) {
	global Features
	return IsSet(Features) && Features is Map && Features.Has(Section)
		&& Features[Section] is Map && Features[Section].Has(Key) && Features[Section][Key] is String
}

; Rebase only the acknowledged leaf onto the current native Features owner.
; Its stored form, including DPAPI, is what the later full-save collector owns.
_ProxyOverride_PublishStored(Publication, Section, Key) {
	global Features
	if !_ProxyOverride_FeatureTargetReady(Section, Key)
		throw Error("The native proxy feature state was withdrawn before live publication.")
	Features[Section][Key] := Publication.config
	return _ProxyOverride_ApplyPublication(Publication)
}

; This predicate contains only retained RAM/source identity checks. The native
; writer calls it again at its own final admission boundary while leased.
_ProxyOverride_BootSourceCurrent(Source) {
	global _ProxyOverrideBootSealSource, _ProxyOverrideStored, _ProxyOverrideSealed, ConfigurationFile
	return IsObject(Source) && _ProxyOverrideBootSealSource == Source
		&& !_ProxyOverrideSealed && Source.Stored is String
		&& StrCompare(Source.Stored, _ProxyOverrideStored, true) == 0
		&& StrCompare(Source.Path, ConfigurationFile, true) == 0
}

_ProxyOverride_BootSourceOwned(Source, Lease, Path) {
	return _ConfigWriteLeaseOwns(Lease, Path) && _ProxyOverride_BootSourceCurrent(Source)
		&& StrCompare(Path, Source.Path, true) == 0
}

_ProxyOverride_BuildBootSeal(Source, Lease, Path, Updates, Publication, Section, Key) {
	if !_ProxyOverride_BootSourceOwned(Source, Lease, Path) || !_ProxyOverride_FeatureTargetReady(Section, Key)
		return 0
	; A bound custom writer carries its own exact-source/native-lease admission.
	; The gateway's default admission keeps its original issuer fence intact.
	return {updates: Updates, publish: _ProxyOverride_PublishBootSource.Bind(Source, Lease, Path, Publication, Section, Key)}
}

_ProxyOverride_PublishBootSource(Source, Lease, Path, Publication, Section, Key) {
	; ConfigCommitBuilt invokes this under its publication Critical span. A lost
	; source after durable ACK must report a partial failure, never publish stale RAM.
	if !_ProxyOverride_BootSourceOwned(Source, Lease, Path)
		throw Error("The automatic proxy sealing source was withdrawn before live publication.")
	return _ProxyOverride_PublishStored(Publication, Section, Key)
}

_ProxyOverride_WriteBootSource(Source, Lease, Path, Updates) {
	if !_ProxyOverride_BootSourceOwned(Source, Lease, Path)
		return false
	return TOML_ConfigBatchWrite(Path, Updates, [], _ProxyOverride_BootSourceOwned.Bind(Source, Lease, Path),
		Source.Content, Source.Present)
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
	global _ProxyOverrideSealed, _ProxyOverrideBootSealSource
	Source := _ProxyOverrideBootSealSource
	Choice := ProxyOverride_Current()
	if !(Choice is Map) || Choice["mode"] != "relay" || _ProxyOverrideSealed
			|| !ProxyOverride_CarriesCredentials(Choice["relay"])
		return false
	if !_ProxyOverride_BootSourceCurrent(Source)
		return false
	if _ProxyOverride_Store(Choice["relay"], Source) != true {
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
