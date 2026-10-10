; infra/tray_bootstrap.ahk

; ==============================================================================
; MODULE: Safe Cold-Start Tray Bootstrap
; DESCRIPTION:
; Publishes native lifecycle commands before the icon is exposed. First-run
; setup keeps an inert bootstrap under its own wizard owner. The tray-root
; coordinator replaces either root atomically after initialization. Definitions
; only, so startup boundaries and unit tests can use the same ownership.
; ==============================================================================

#Requires AutoHotkey v2.0

; Generated shared authority is compiled before the first cold publication.
; This surface never claims admission of the mutable live manifest root.
#Include ../../_shared/modules/menu/startup_tray_projection.ahk

_TrayBootstrapNoOp(*) {
	return 0
}

/** Publishes real native lifecycle rows before exposing the tray icon. */
_InstallNativeStartupTray(RequestFn, MenuObj := 0, RegisterFn := 0) {
	if !HasMethod(RequestFn, "Call")
		throw TypeError("Native startup tray requires a command owner")
	if !IsObject(MenuObj)
		MenuObj := A_TrayMenu
	Register := HasMethod(RegisterFn, "Call") ? RegisterFn : RegisterMenuItem
	; Locale cache misses may read disk; finish them before atomic publication.
	Commands := Map(
		"suspend", MenuStartupSafeCommand(RequestFn.Bind("suspend")),
		"reload", MenuStartupSafeCommand(RequestFn.Bind("reload")),
		"quit", MenuStartupSafeCommand(RequestFn.Bind("quit")))
	Rows := _TrayBootstrapProjectedRows("commands", Commands)
	PreviousCritical := Critical("On")
	try {
		MenuDispatcher_BeginReplacement()
		MenuObj.Delete()
		for Row in Rows {
			if Register.Call(MenuObj, Row.Label, Row.Callback) != 1
				throw Error("Native startup command registration failed: " . Row.Id)
		}
		if !HasMethod(RegisterFn, "Call")
			MenuDispatcher_PruneMenu(MenuObj)
		return true
	} finally Critical(PreviousCritical)
}

_InstallSafeBootstrapTray(Label := unset, MenuObj := 0) {
	Status := _TrayBootstrapProjectedRows("inert", Map())[1]
	if !IsSet(Label)
		Label := Status.Label
	if !(Label is String) or Label == ""
		throw ValueError("tray bootstrap label must be a non-empty string")
	if !IsObject(MenuObj)
		MenuObj := A_TrayMenu
	PreviousCritical := Critical("On")
	try {
		; Own retirement and replacement in one uninterruptible AHK transaction.
		; A caller-side Delete followed by this helper left a real click/timer seam
		; in which Windows could display an empty root.
		MenuObj.Delete()
		MenuObj.Add(Label, _TrayBootstrapNoOp)
		MenuObj.Disable(Label)
		return true
	} finally Critical(PreviousCritical)
}

/** Projects immutable shared startup data into the original native callback ABI. */
_TrayBootstrapProjectedRows(Surface, Commands) {
	global _I18nLocale
	Authority := SharedStartupTrayProjection(_I18nLocale)
	if !(Authority is Map) || Authority.Count != 5
		|| Authority.Get("authority", "") != "compiled-startup"
		|| !RegExMatch(Authority.Get("source_sha256", ""), "^[0-9a-f]{64}$")
		|| Type(Authority.Get("locale", 0)) != "String"
		|| !(Commands is Map) || !Authority.Has(Surface)
		throw Error("Immutable shared startup authority is unavailable")
	Source := Authority[Surface]
	CommandSurface := Surface == "commands"
	if (!CommandSurface && Surface != "inert") || !(Source is Array)
		|| Source.Length != (CommandSurface ? Commands.Count : 1)
		throw Error("The complete shared startup surface is unavailable")
	Prepared := [], SeenIds := Map(), SeenCommands := Map(), SeenLabels := Map()
	for Row in Source {
		if !(Row is Map) || Row.Count != 6
			|| Row.Get("type", "") != (CommandSurface ? "command" : "label")
			|| Type(Row.Get("id", 0)) != "String" || Row["id"] == ""
			|| SeenIds.Has(Row["id"])
			|| Type(Row.Get("label", 0)) != "String" || Row["label"] == ""
			|| RegExMatch(Row["label"], "[\x00-\x1f\x7f]") || SeenLabels.Has(Row["label"])
			|| Type(Row.Get("section", 0)) != "String" || Row["section"] == ""
			|| Type(Row.Get("source_id", 0)) != "String" || Row["source_id"] == ""
			throw Error("Invalid immutable startup record")
		SeenIds[Row["id"]] := true, SeenLabels[Row["label"]] := true
		if CommandSurface {
			CommandId := Row.Get("command", "")
			if Type(CommandId) != "String" || !Commands.Has(CommandId)
				|| SeenCommands.Has(CommandId) || !(Commands[CommandId] is MenuStartupSafeCommand)
				throw Error("Shared startup command has no unique native capability owner")
			SeenCommands[CommandId] := true
			Prepared.Push({Id: CommandId, Label: Row["label"], Callback: Commands[CommandId]})
		} else {
			if Row.Get("command", 0) != ""
				throw Error("An inert startup record cannot acquire command authority")
			Prepared.Push({Label: Row["label"]})
		}
	}
	return Prepared
}
