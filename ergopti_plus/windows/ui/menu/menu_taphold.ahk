; ui/menu/menu_taphold.ahk

; ==============================================================================
; MODULE: Tray Menu / Tap-Hold Submenu
; DESCRIPTION:
; Builds the Tap-Hold category: per-key tap and hold pickers, reset/disable-all actions and the closure factory classes that bind a key id to a menu callback.
;
; Split out of ui/tray_menu.ahk (the module split). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




; Build the TapHolds submenu — one entry per physical key, each with a
; tap row and a hold row that both open the shared action picker (the same
; window as the gesture and shortcut pickers), as on macOS and Linux.
;
; Render shape:
;
;   ☰ Tap-Hold
;     ↳ ✓ Activer les tap-holds        [the TapHolds master gate]
;     ↳ ---
;     ↳ ↺ Restaurer les valeurs conseillées
;     ↳ ✕ Tout effacer (comportement du système)
;     ↳ ---
;     ↳ — Main gauche — Tap / Hold —   [manifest header]
;     ↳ Tab  :  Alt-Tab / Alt          [checkmark when configured]
;       ↳ Rien (désactiver)
;       ↳ ---
;       ↳ Tap  → "Alt-Tab"             [opens modal action picker GUI]
;       ↳ Hold → "Alt"                 [opens the action picker on the hold options]
;     ↳ …                              [down to Space]
;     ↳ ---
;     ↳ — Main droite — Tap / Hold —   [manifest header]
;     ↳ AltGr  :  Tab / AltGr
;     ↳ …
;
; Which key goes under which hand is the shared key catalogue's
; ([tap_hold.catalog], read by TapHoldKeyDefs); the headers and the separator
; between the hands are the manifest's.
;
; Tap picker: full GESTURE_ACTIONS list in the searchable modal GUI (ShowActionPicker).
; Hold picker: the same window on the hold options of _TH_HoldOptions (the
; modifiers, their combinations and the nav layer; its « none » row clears it).
; Both pickers persist immediately via WriteTapHoldTap / TapHoldSetHold and
; reload the script to refresh the menu; a refused hold keeps its picker open.
_BuildTapHoldsSubmenu() {
	Commands := _TH_ScopeCommands()
	Getters := Map("tapholds_enabled", () => IsCategoryGated("TapHolds"))
	ListProviders := Map(
		"tap_hold_keys_left", (*) => _TH_KeyRows("left"),
		"tap_hold_keys_right", (*) => _TH_KeyRows("right"))
	return MenuRenderer_Build("tap_holds_menu", "TapHolds", "", "", ListProviders, Commands, Getters)
}

; List provider: one row per configurable key of one hand.
;
; Row DATA since 2026-08-07. The tree is two levels — the key, then its
; disable / tap / hold / delay rows, the tap and the hold opening the shared
; action picker — and none of it mutates a live menu: every action writes the
; user's tap_hold.toml and reloads the script, which rebuilds the tray.
; @param Hand {String} "left" or "right".
_TH_KeyRows(Hand) {
	global TapHold
	Rows := []
	for _, KeyDef in TapHoldKeyDefsOfHand(Hand) {
		KeyId    := KeyDef["id"]
		KeyLabel := t(KeyDef["i18n"])
		TapLbl   := TapHoldCurrentTapLabel(KeyId)
		HoldLbl  := TapHoldCurrentHoldLabel(KeyId)

		IsConfigured := IsSet(TapHold) and TapHoldIsConfigured(MasterGateDesiredTapHold(TapHold), KeyId)

		NoneLabel  := t("tap_hold.tap.none")
		NoneHold   := t("tap_hold.hold.none")
		ComboLabel := (TapLbl == NoneLabel and HoldLbl == NoneHold)
			? "—"
			: (TapLbl . "  /  " . HoldLbl)
		ParentLabel := KeyLabel . "  :  " . ComboLabel

		DelayCaption := Round(TapHoldDuration(MasterGateDesiredTapHold(TapHold), KeyId) * 1000) . " ms"
		KeyRows := MenuRenderer_TemplateRows("tap_hold_key_rows",
			Map("tap_hold_key_native", _TH_MakeDisableFn(KeyId),
				"tap_hold_key_tap", _TH_MakeTapPickerFn(KeyId, KeyLabel, TapLbl),
				"tap_hold_key_hold_action", _TH_MakeHoldPickerFn(KeyId, KeyLabel),
				"tap_hold_key_delay", _TH_MakeDelayPickerFn(KeyId)),
			Map("tap_hold_key_configured", ((Value) => Value).Bind(IsConfigured),
				"tap_hold_key_tap_caption", ((Value) => Value).Bind(TapLbl),
				"tap_hold_key_hold_caption", ((Value) => Value).Bind(HoldLbl),
				"tap_hold_key_delay_caption", ((Value) => Value).Bind(DelayCaption)),
			Map())
		if !(KeyRows is Array)
			continue
		Rows.Push(Map(
			"label",   ParentLabel,
			"checked", IsConfigured,
			"items",   KeyRows))
	}
	return Rows
}

; Return the "none" hold option map (first entry in _TH_HoldOptions).
_TH_NoneHoldOpt() {
	global _TH_HoldOptions
	return _TH_HoldOptions[1]
}

; ---- Global tap-hold actions --------------------------------------------------

; Reset all configured keys back to factory defaults by deleting the user
; tap_hold.toml (the loader will fall back to defaults.toml on next reload).
_TH_ResetAllToDefaults(*) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_ResetTapHoldConfig()
		finally Critical(InheritedCritical)
	}
	return _TH_ResetTapHoldConfig()
}

; Delete the exact admitted target, then release its owner before Reload tries
; to acquire the process-wide terminal transition. Optional adapters make every
; refusal and path race deterministic in the behavioural suite.
_TH_ResetTapHoldConfig(DeleteFn := 0, AuthorizeFn := 0, ReloadFn := 0) {
	global TapHold
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_ResetTapHoldConfig(DeleteFn, AuthorizeFn, ReloadFn)
		finally Critical(InheritedCritical)
	}
	for Adapter in [DeleteFn, AuthorizeFn, ReloadFn] {
		if !((Adapter is Integer) && Adapter == 0)
				&& !HasMethod(Adapter, "Call") {
			try LoggerError("TapHoldMenu", "Refusing reset with an invalid transaction adapter.")
			return false
		}
	}
	if !(TapHold is Map) {
		try LoggerError("TapHoldMenu", "Cannot reset tap-holds before live state is initialized.")
		return false
	}
	BoundPath := _TH_TapHoldConfigPath()
	if !(BoundPath is String) || BoundPath == "" {
		try LoggerError("TapHoldMenu", "Cannot reset tap-holds before the target path is initialized.")
		return false
	}
	OwnerToken := _ConfigWriteLeaseTryAcquire(BoundPath, "tap-hold-reset")
	if !(OwnerToken is Object) {
		try LoggerError("TapHoldMenu",
			"Cannot reset tap-holds: another configuration transaction is in progress.")
		return false
	}
	try LoggerInfo("TapHoldMenu",
		"Resetting all tap-hold overrides from defaults (script='{1}', pid={2}).",
		A_ScriptName, DriverPid)
	StartState := TapHold
	Authorized := false
	AuthorizeError := ""
	Deleted := false
	DeleteError := ""
	Released := false
	try {
		PreviousCritical := Critical("On")
		try {
			try Authorized := _TH_AuthorizeTapHoldCommit(OwnerToken,
				BoundPath, StartState, AuthorizeFn)
			catch as Err {
				Authorized := false
				AuthorizeError := Err.Message
			}
			Authorized := (Authorized is Integer) && Authorized == 1
		} finally Critical(PreviousCritical)
		if Authorized {
			try Deleted := HasMethod(DeleteFn, "Call")
				? DeleteFn.Call(BoundPath) : FSDeleteStrict(BoundPath)
			catch as Err {
				Deleted := false
				DeleteError := Err.Message
			}
			Deleted := (Deleted is Integer) && Deleted == 1
		}
	} finally {
		Released := _ConfigWriteLeaseRelease(OwnerToken)
	}
	if !(Released is Integer) || Released != 1 {
		try LoggerError("TapHoldMenu",
			"The tap-hold reset owner could not be released; Reload was not requested.")
		return false
	}
	if !Authorized {
		if (AuthorizeError != "") {
			try LoggerError("TapHoldMenu",
				"Authorization before deleting '{1}' failed: {2}. Reset was not applied.",
				BoundPath, AuthorizeError)
		} else {
			try LoggerError("TapHoldMenu",
				"Authorization before deleting '{1}' was refused. Reset was not applied.",
				BoundPath)
		}
		return false
	}
	if !Deleted {
		if (DeleteError != "") {
			try LoggerError("TapHoldMenu",
				"Could not delete '{1}': {2}. Reload was not requested.",
				BoundPath, DeleteError)
		} else {
			try LoggerError("TapHoldMenu",
				"Could not delete '{1}': the delete adapter refused it. Reload was not requested.",
				BoundPath)
		}
		return false
	}
	Reloaded := false
	ReloadError := ""
	try Reloaded := HasMethod(ReloadFn, "Call")
		? ReloadFn.Call("reset_defaults", "")
		: _TH_ReloadTapHoldMenu("reset_defaults", "")
	catch as Err {
		Reloaded := false
		ReloadError := Err.Message
	}
	if !(Reloaded is Integer) || Reloaded != 1 {
		if (ReloadError != "") {
			try LoggerError("TapHoldMenu",
				"Tap-hold defaults were reset, but Reload failed: {1}.",
				ReloadError)
		} else {
			try LoggerError("TapHoldMenu",
				"Tap-hold defaults were reset, but Reload was refused.")
		}
		return false
	}
	return 1
}

; Clear every configured key so all physical keys revert to their native OS
; behaviour (no tap remapping, no hold remapping).
_TH_DisableAll(*) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_DisableAll()
		finally Critical(InheritedCritical)
	}
	try LoggerInfo("TapHoldMenu", "Disabling all tap-hold mappings (script='{1}', pid={2}).", A_ScriptName, DriverPid)
	if !IsSet(_TH_WriteTapHoldDisabled) {
		try LoggerError("TapHoldMenu", "Disable-all unavailable: tap-hold writer is not loaded.")
		return false
	}
	if !_TH_WriteTapHoldDisabled()
		return false
	return _TH_ReloadTapHoldMenu("disable_all", "")
}

; ---- Callback classes ---------------------------------------------------------
; AHK v2 fat-arrow closures cannot contain multiple statements. These classes
; capture (KeyId, HoldOpt) by value and expose a Call() method bound via
; ObjBindMethod so AHK's Menu.Add() receives a valid callable.

class _TH_DisableFnObj {
	KeyId := ""
	Call(Args*) {
		InheritedCritical := A_IsCritical
		if InheritedCritical {
			Critical("Off")
			try return this.Call(Args*)
			finally Critical(InheritedCritical)
		}
		try LoggerInfo("TapHoldMenu", "Menu disable action requested for key '{1}' (pid={2}).", this.KeyId, DriverPid)
		if !WriteTapHoldNative(this.KeyId)
			return false
		return _TH_ReloadTapHoldMenu("key_disable", this.KeyId)
	}
}

class _TH_TapPickerFnObj {
	KeyId     := ""
	KeyLabel  := ""
	Call(*) {
		global TapHold
		; Current tap action at call time (not at menu-build time).
		; "" means native (unconfigured) — pass as-is; ShowNative:=true adds the entry.
		Current := IsSet(TapHold) ? TapHoldTapAction(TapHold, this.KeyId) : ""
		try LoggerDebug("TapHoldMenu", "Opening tap picker for '{1}' (current='{2}').", this.KeyId, (Current == "" ? "<native>" : Current))
		Title := t("tap_hold.picker.title_prefix") . this.KeyLabel
		_KeyId := this.KeyId
		ShowActionPicker(Title, Current, (Id) => _TH_ApplyTap(_KeyId, Id), true,
			GestureBindingId("tap_hold", _KeyId))
	}
}

class _TH_DelayPickerFnObj {
	KeyId := ""
	PromptFn := 0
	SetterFn := 0
	ReloadFn := 0
	Call(*) {
		return _TH_PromptKeyDelay(this.KeyId, this.PromptFn, this.SetterFn, this.ReloadFn)
	}
}

class _TH_HoldPickerFnObj {
	KeyId    := ""
	KeyLabel := ""
	Call(*) {
		return _TH_OpenHoldPicker(this.KeyId, this.KeyLabel)
	}
}

; Open the shared action picker on a key's hold: the hold options, the current
; one marked, the window titled « Hold action — <key> ». A pick is written
; while the picker is open; the script reloads once it has closed.
; @param KeyId {String} The key.
; @param KeyLabel {String} Its translated name, for the title.
; @param OpenFn {Func} Replaces ShowActionPicker in tests.
; @param SetHoldFn {Func} Replaces TapHoldSetHold in tests.
; @param ReloadFn {Func} Replaces the reload in tests.
; @returns {Any} What the picker returns.
_TH_OpenHoldPicker(KeyId, KeyLabel, OpenFn := 0, SetHoldFn := 0, ReloadFn := 0) {
	Current := TapHoldCurrentHoldPickId(KeyId)
	try LoggerDebug("TapHoldMenu", "Opening hold picker for '{1}' (current='{2}').", KeyId, Current)
	Slot := Map("items", TapHoldHoldPickerItems(),
		"after_close", _TH_AfterHoldPick.Bind(KeyId, ReloadFn))
	Open := HasMethod(OpenFn, "Call") ? OpenFn : ShowActionPicker
	return Open.Call(t("tap_hold.picker.hold_title_prefix") . KeyLabel, Current,
		_TH_CommitHoldPick.Bind(KeyId, SetHoldFn), false, "", Slot)
}

; Write a hold picked in the picker. The write goes through the owner that
; brings the navigation layer along with a key that enters it: the
; configuration folder is handed over here, by the tray alone.
; @param KeyId {String} The key.
; @param SetHoldFn {Func} Replaces TapHoldSetHold in tests; 0 in production.
; @param PickId {String} The picked id ("none" clears the hold).
; @returns {Integer|Boolean} 1 when written, false to keep the picker open.
_TH_CommitHoldPick(KeyId, SetHoldFn, PickId) {
	global _ConfigDir
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_CommitHoldPick(KeyId, SetHoldFn, PickId)
		finally Critical(InheritedCritical)
	}
	HoldOpt := TapHoldHoldOptionForPick(PickId)
	if !(HoldOpt is Map) {
		try LoggerError("TapHoldMenu", "The hold of '{1}' does not offer the picked action '{2}'.",
			KeyId, (PickId is String) ? PickId : Type(PickId))
		return false
	}
	try LoggerInfo("TapHoldMenu", "Hold picker selection for '{1}': kind='{2}', id='{3}' (pid={4}).",
		KeyId, HoldOpt["kind"], HoldOpt["id"], DriverPid)
	Written := HasMethod(SetHoldFn, "Call") ? SetHoldFn.Call(KeyId, HoldOpt, _ConfigDir)
		: TapHoldSetHold(KeyId, HoldOpt, _ConfigDir)
	return ((Written is Integer) && Written == 1) ? 1 : false
}

; Reload once the hold picker has closed on a written hold.
_TH_AfterHoldPick(KeyId, ReloadFn, *) {
	return HasMethod(ReloadFn, "Call") ? ReloadFn.Call("hold_set", KeyId)
		: _TH_ReloadTapHoldMenu("hold_set", KeyId)
}

; Build a bound callback that clears both tap and hold for a key.
_TH_MakeDisableFn(KeyId) {
	obj := _TH_DisableFnObj()
	obj.KeyId := KeyId
	return ObjBindMethod(obj, "Call")
}

; Build a bound callback that opens the action picker modal for the tap slot.
_TH_MakeTapPickerFn(KeyId, KeyLabel, TapLbl) {
	obj := _TH_TapPickerFnObj()
	obj.KeyId    := KeyId
	obj.KeyLabel := KeyLabel
	return ObjBindMethod(obj, "Call")
}

; Build a bound callback that opens the action picker modal for the hold slot.
_TH_MakeHoldPickerFn(KeyId, KeyLabel) {
	obj := _TH_HoldPickerFnObj()
	obj.KeyId    := KeyId
	obj.KeyLabel := KeyLabel
	return ObjBindMethod(obj, "Call")
}

/**
 * Captures the physical key while discarding native menu callback arguments.
 * @param {String} KeyId Shared physical-key identifier.
 * @returns {BoundFunc} Per-key prompt command.
 */
_TH_MakeDelayPickerFn(KeyId, PromptFn := 0, SetterFn := 0, ReloadFn := 0) {
	obj := _TH_DelayPickerFnObj()
	obj.KeyId := KeyId
	obj.PromptFn := PromptFn
	obj.SetterFn := SetterFn
	obj.ReloadFn := ReloadFn
	return ObjBindMethod(obj, "Call")
}

/**
 * Prompts for milliseconds, publishes through the native owner, then reloads once.
 * @param {String} KeyId Shared physical-key identifier.
 * @returns {Integer|Boolean} Strict1 after publication and reload, otherwise false.
 */
_TH_PromptKeyDelay(KeyId, PromptFn := 0, SetterFn := 0, ReloadFn := 0) {
	global TapHold
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_PromptKeyDelay(KeyId, PromptFn, SetterFn, ReloadFn)
		finally Critical(InheritedCritical)
	}
	for Adapter in [PromptFn, SetterFn, ReloadFn] {
		if !((Adapter is Integer) && Adapter == 0) && !HasMethod(Adapter, "Call")
			return false
	}
	if !(KeyId is String) || !(TapHold is Map)
		return false
	if !_TH_DurationKeyKnown(KeyId)
		return false
	StartState := TapHold
	StartPath := _TH_TapHoldConfigPath()
	if !(StartPath is String) || StartPath == ""
		return false
	SourceWitness := _TH_CaptureDurationContext(Map("path", StartPath), KeyId)
	PhysicalSource := _TH_CaptureDurationSource(StartPath)
	if !(SourceWitness is Map) || !(PhysicalSource is Map)
		return false
	SourceWitness["source_present"] := PhysicalSource["source_present"]
	SourceWitness["source_content"] := PhysicalSource["source_content"]
	if !_TH_DurationSourceMatches(SourceWitness, StartPath)
		return false
	CurrentMs := Round(TapHoldDuration(MasterGateDesiredTapHold(StartState), KeyId) * 1000)
	Prompt := StrReplace(t("menu.tapholds.key_tap_delay_dialog_prompt_current"), "%d", CurrentMs)
	Title := t("menu.tapholds.key_tap_delay_dialog_title")
	try {
		Answer := HasMethod(PromptFn, "Call") ? PromptFn.Call(Prompt, Title, "w340 h160", CurrentMs)
			: Ui_InputBox(Prompt, Title, "w340 h160", CurrentMs)
		if !(Answer is Object) || Answer.Result != "OK" || !(Answer.Value is String)
			return false
		Raw := Trim(Answer.Value, " `t")
		if !IsNumber(Raw)
			return false
		Ms := Raw + 0
		if !_TH_DurationValueValid(Ms / 1000)
			return false
		Ms := Round(Ms)
		if Ms <= 0
			return false
	} catch as Err {
		try LoggerError("TapHoldMenu", "The per-key delay prompt was refused: {1}.", Err.Message)
		return false
	}
	if !_TH_DurationSourceMatches(SourceWitness, _TH_TapHoldConfigPath()) {
		try LoggerWarn("TapHoldMenu", "The per-key delay source changed while its prompt was open.")
		return false
	}
	try Published := HasMethod(SetterFn, "Call") ? SetterFn.Call(KeyId, Ms / 1000, SourceWitness)
		: WriteTapHoldDuration(KeyId, Ms / 1000, 0, 0, 0, 0, SourceWitness)
	catch as Err {
		try LoggerError("TapHoldMenu", "The per-key delay could not be saved: {1}.", Err.Message)
		return false
	}
	if !(Published is Integer) || Published != 1
		return false
	; A persistence callback cannot acknowledge a different key or parent and
	; then send Reload to that successor configuration.
	if !_TH_DurationReceiptMatches(SourceWitness, _TH_TapHoldConfigPath(), KeyId, Ms / 1000)
		return false
	try Reloaded := HasMethod(ReloadFn, "Call") ? ReloadFn.Call("delay_set", KeyId)
		: _TH_ReloadTapHoldMenu("delay_set", KeyId)
	catch as Err {
		try LoggerError("TapHoldMenu", "Reload after the per-key delay failed: {1}.", Err.Message)
		return false
	}
	return (Reloaded is Integer) && Reloaded == 1 ? 1 : false
}

; Apply a tap action chosen from the modal picker.
; ActionId="" (from the "Natif" sentinel) clears the slot so the key passes through natively.
; ActionId="none" sets the absorb no-op action.
_TH_ApplyTap(KeyId, ActionId) {
	global TapHold
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_ApplyTap(KeyId, ActionId)
		finally Critical(InheritedCritical)
	}
	Current := IsSet(TapHold) ? TapHoldTapAction(TapHold, KeyId) : "<not_ready>"
	try LoggerInfo("TapHoldMenu", "ApplyTap key='{1}' current='{2}' -> '{3}' (pid={4}).", KeyId,
		(Current == "" ? "<native>" : Current), (ActionId == "" ? "<native>" : ActionId), DriverPid)
	if !GestureEnsureActionParameter(GestureBindingId("tap_hold", KeyId), ActionId)
		return false
	if !WriteTapHoldTap(KeyId, ActionId)
		return false
	return _TH_ReloadTapHoldMenu("tap_set", KeyId)
}

; Shared reload helper — keeps menu-triggered updates observable in debug logs.
; We use it everywhere to avoid silent hot-reload with no trace when
; diagnosing "second-instance" reports from users.
_TH_ReloadTapHoldMenu(Reason, KeyId := "") {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_ReloadTapHoldMenu(Reason, KeyId)
		finally Critical(InheritedCritical)
	}
	try LoggerInfo("TapHoldMenu", "Reloading script after '{1}' on key '{2}' (pid={3}, script={4}).",
		Reason, KeyId, DriverPid, A_ScriptName)
	Reloaded := false
	ReloadError := ""
	try Reloaded := ReloadPreservingSuspend()
	catch as Err {
		Reloaded := false
		ReloadError := Err.Message
	}
	if !(Reloaded is Integer) || Reloaded != 1 {
		if (ReloadError != "") {
			try LoggerError("TapHoldMenu",
				"Reload after tap-hold action '{1}' failed: {2}.",
				Reason, ReloadError)
		} else {
			try LoggerError("TapHoldMenu",
				"Reload after tap-hold action '{1}' was refused.", Reason)
		}
		return false
	}
	return 1
}

; The first group's restore and clear (the same scope_restore / scope_clear
; ids as every settings menu) reach one compensated two-file owner. The tray's
; restore also creates the configuration folder's layers.toml from the
; recommended layer when it has none; injected options name their own.
_TH_ScopeCommands(Options := unset) {
	global _ConfigDir
	OwnedOptions := IsSet(Options) ? Options : Map("layers_config_dir", _ConfigDir)
	return Map(
		"tapholds_toggle", MenuRenderer_CategoryGateCommand("TapHolds"),
		"scope_restore", (*) => TapHoldScopeApply("recommended", OwnedOptions),
		"scope_clear", (*) => TapHoldScopeApply("clear", OwnedOptions),
		"edit_nav_layer", LayerEditor_Open)
}
