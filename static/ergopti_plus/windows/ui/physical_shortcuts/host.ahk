; ui/physical_shortcuts/host.ahk

; ==============================================================================
; MODULE: Physical Shortcut Editor Host (Windows)
; DESCRIPTION:
; The WebView2 host of the shared page _shared/ui/physical_shortcuts/, its
; configuration scope and the menu port, as macOS and Linux build them. The
; editor is WebView only (maintainer decision of 2026-11-11, no native form).
;
; FEATURES & RATIONALE:
; 1. Delivery stays refused: PhysicalShortcutDeliveryAvailable answers false
;    until the maintainer qualifies a physical key bound to an action on real
;    hardware (maintainer decision of 2026-11-11). The menu port then keeps the
;    editor closed, captures no scope, and the row names
;    physical_shortcuts.delivery_unqualified.
; 2. GUI readiness, delivery and the scope's own refusal are three separate
;    answers, each read live, as on the other drivers.
; ==============================================================================




; =================================================
; =================================================
; ======= 1/ Delivery capability ==================
; =================================================
; =================================================

/**
 * The production answer to whether Windows can deliver an action bound to a
 * physical key. Windows has no qualified physical delivery owner (source,
 * collision and output custody): it answers false until the maintainer turns
 * it on after the hardware qualification.
 * @returns {Integer} 0.
 */
PhysicalShortcutDeliveryAvailable() {
	return false
}

/**
 * Accepts only a strict capability acknowledgement. Port of
 * physical_availability.lua ready.
 * @param {Func} Query A capability getter; no GUI or configuration work.
 * @returns {Integer} 1 only when the getter answered exactly true.
 */
PhysicalAvailabilityReady(Query) {
	if !HasMethod(Query, "Call")
		return false
	try Answer := Query.Call()
	catch as Err {
		LoggerError("PhysicalShortcuts", "The physical delivery getter failed: {1}.", Err.Message)
		return false
	}
	return (Answer is Integer) && Answer == 1
}

/**
 * Whether scope rows need physical delivery before publication: an active
 * mapping or one of its parameters. A removal needs none.
 * @param {Array} Rows Scope rows ({ Section, Key, Value } or Delete).
 * @returns {Integer}
 */
PhysicalAvailabilityRequiresDelivery(Rows) {
	Binding := GestureBindingId("keyboard", PhysicalSlots.PREFIX)
	for Row in Rows {
		if Row.HasOwnProp("Delete") && Row.Delete
			continue
		if Row.Section == ConfigKey.SHORTCUTS_KEYBOARD && PhysicalSlots.IsNamespace(Row.Key) && Row.Value != "none"
			return true
		if Row.Section == "action_parameters" && SubStr(Row.Key, 1, StrLen(Binding)) == Binding
			return true
	}
	return false
}




; =================================================
; =================================================
; ======= 2/ Configuration scope ==================
; =================================================
; =================================================

; Reads config.toml as the scope's source: absent is an empty document.
_PhysicalShortcutsReadSource(Path) {
	if !FileExist(Path)
		return Map("status", "absent", "content", "")
	return Map("status", "ok", "content", FSReadUtf8Exact(Path))
}

; The shared scoped publication: backup, one conditional write, then reload.
_PhysicalShortcutsPublishRows(Path, Rows) {
	Receipt := ConfigScopeCommitOperations("shortcuts", "physical_edit", () => Rows, Map("path", Path))
	return (Receipt is Map) && (Receipt["status"] == "pending" || Receipt["status"] == "committed")
}

; Whether the WebView2 runtime and its loader are here to host the page.
_PhysicalShortcutsWebViewReady() {
	global _VendorDir
	return IsSet(WebView2) && IsSet(_VendorDir) && FileExist(_VendorDir . "\64bit\WebView2Loader.dll") ? true : false
}

/**
 * The editor's view of config.toml: the physical slots of shortcuts.keyboard
 * and the action parameters, bound to the exact bytes they were read from.
 * Every edit passes the delivery refusal, the collision owner and the source
 * check before the shared scoped publication.
 */
class PhysicalShortcutsScope {
	/**
	 * @param {Map} Options "path", the model, and test ports "read",
	 *   "delivery", "collisions" and "publish".
	 */
	__New(Options := unset) {
		global ConfigurationFile
		this.Options := IsSet(Options) ? Options : Map()
		this.Path := this.Options.Get("path", IsSet(ConfigurationFile) ? ConfigurationFile : "")
		this.Model := this.Options.Has("model") ? this.Options["model"] : PhysicalSlots.Load()
		this.Read := this.Options.Get("read", _PhysicalShortcutsReadSource)
		this.Delivery := this.Options.Get("delivery", PhysicalShortcutDeliveryAvailable)
		; Windows has no collision owner yet (Linux: physical_collisions); a
		; mapping is refused until one is qualified.
		this.Collisions := this.Options.Get("collisions", 0)
		this.Publish := this.Options.Get("publish", _PhysicalShortcutsPublishRows)
	}

	/**
	 * Keeps GUI readiness separate from native physical delivery.
	 * @returns {Integer}
	 */
	PhysicalDeliveryAvailable() {
		return PhysicalAvailabilityReady(this.Delivery)
	}

	/**
	 * Captures the physical assignments and parameters from one exact read.
	 * @returns {Map} Map("inventory", …, "receipt", …), or Map("reason", …).
	 */
	CaptureEditorInventory() {
		if (this.Path == "")
			return Map("reason", "unavailable")
		try Source := this.Read.Call(this.Path)
		catch as Err {
			LoggerError("PhysicalShortcuts", "The configuration could not be read: {1}.", Err.Message)
			return Map("reason", "unavailable")
		}
		if !(Source is Map) || !(Source.Get("status", "") == "ok" || Source.Get("status", "") == "absent")
			return Map("reason", "unavailable")
		try Document := TOML_ParseDocument(Source["content"])
		catch as Err {
			LoggerWarn("PhysicalShortcuts", "The configuration does not parse: {1}.", Err.Message)
			return Map("reason", "source_changed")
		}
		Assignments := Map(), Parameters := Map()
		Assignments.CaseSense := "On", Parameters.CaseSense := "On"
		Shortcuts := Document.Get("shortcuts", 0)
		Section := (Shortcuts is Map) ? Shortcuts.Get("keyboard", 0) : 0
		if (Section is Map) {
			for Slot, Action in Section {
				if !PhysicalSlots.IsNamespace(Slot)
					continue
				if !this.Model.Owns(Slot) || !(Action is String) || !GestureActionIsAssignable(Action)
					return Map("reason", "source_changed")
				Assignments[Slot] := Action
			}
		}
		Stored := Document.Get("action_parameters", 0)
		if (Stored is Map) {
			for Key, Value in Stored
				Parameters[Key] := Value
		}
		Receipt := { Path: this.Path, Status: Source["status"], Content: Source["content"] }
		if !this.EditorSourceCurrent(Receipt)
			return Map("reason", "source_changed")
		return Map("inventory", Map("assignments", Assignments, "parameters", Parameters), "receipt", Receipt)
	}

	/**
	 * Whether config.toml still holds the exact bytes a receipt was read from.
	 * @param {Object} Receipt From CaptureEditorInventory.
	 * @returns {Integer}
	 */
	EditorSourceCurrent(Receipt) {
		if !IsObject(Receipt) || !Receipt.HasOwnProp("Path") || Receipt.Path != this.Path
			return false
		try Source := this.Read.Call(this.Path)
		catch as Err {
			LoggerError("PhysicalShortcuts", "The configuration could not be read again: {1}.", Err.Message)
			return false
		}
		return (Source is Map) && Source.Get("status", "") == Receipt.Status && Source.Get("content", "") == Receipt.Content
	}

	/**
	 * Publishes planner rows after every refusal had its say.
	 * @param {Array} Rows Scope rows from PhysicalEntriesPlan.
	 * @param {Object} Receipt The source the rows were planned on.
	 * @returns {Map} Map("committed", 0/1, "reason", …).
	 */
	Edit(Rows, Receipt) {
		if !(Rows is Array) || Rows.Length == 0
			return Map("committed", false, "reason", "save_failed")
		if PhysicalAvailabilityRequiresDelivery(Rows) {
			; The strict capability refusal comes before any other owner is asked.
			if !this.PhysicalDeliveryAvailable()
				return Map("committed", false, "reason", "unavailable")
			if !HasMethod(this.Collisions, "Call")
				return Map("committed", false, "reason", "unavailable")
			try Free := this.Collisions.Call(Rows)
			catch as Err {
				LoggerError("PhysicalShortcuts", "The collision check failed: {1}.", Err.Message)
				return Map("committed", false, "reason", "unavailable")
			}
			if (Free != true)
				return Map("committed", false, "reason", Free == "source_changed" ? "source_changed" : "collision")
			if !this.PhysicalDeliveryAvailable()
				return Map("committed", false, "reason", "unavailable")
		}
		if !this.EditorSourceCurrent(Receipt)
			return Map("committed", false, "reason", "source_changed")
		LoggerStart("PhysicalShortcuts", "Physical shortcut edit started ({1} rows).", Rows.Length)
		try Published := this.Publish.Call(this.Path, Rows)
		catch as Err {
			LoggerError("PhysicalShortcuts", "Physical shortcut edit failed: {1}.", Err.Message)
			return Map("committed", false, "reason", "save_failed")
		}
		if (Published != true) {
			LoggerError("PhysicalShortcuts", "Physical shortcut edit refused by the scoped publication.")
			return Map("committed", false, "reason", "save_failed")
		}
		LoggerSuccess("PhysicalShortcuts", "Physical shortcut edit completed.")
		return Map("committed", true)
	}
}




; =================================================
; =================================================
; ======= 3/ WebView2 host ========================
; =================================================
; =================================================

; The native page: its WebViewHost lifetime retires the shared protocol.
class PhysicalShortcutsWindow extends WebViewHost {
	Protocol := 0
	NativeClosing := false

	; The page's close request: the protocol has retired the session already.
	_NativeClose() {
		this.NativeClosing := true
		this.Close()
		return true
	}

	Close() {
		if !this.NativeClosing && IsObject(this.Protocol)
			this.Protocol.Retire()
		this.NativeClosing := true
		super.Close()
		if (PhysicalShortcutsHost.Current == this)
			PhysicalShortcutsHost.Current := 0
	}
}

/**
 * The editor host the menu port asks: GUI readiness, delivery, scope
 * admission and the opening of one shared page.
 */
class PhysicalShortcutsHost {
	; The editor page id every driver names, from _shared/modules/shortcuts/physical_shortcuts.json.
	static APP_ID => PhysicalShortcutsShared()["app_id"]
	static Current := 0
	; GUI readiness, replaceable by a test exactly as Linux replaces its
	; webview manager; delivery always reads the production getter.
	static NativeProbe := _PhysicalShortcutsWebViewReady

	/**
	 * @returns {Integer} 1 when the WebView2 host can open a page.
	 */
	static NativeAvailable() {
		try return PhysicalShortcutsHost.NativeProbe.Call() == true
		catch as Err {
			LoggerError("PhysicalShortcuts", "The WebView2 readiness probe failed: {1}.", Err.Message)
			return false
		}
	}

	/**
	 * Reads the production delivery capability without a scope or a window.
	 * @returns {Integer}
	 */
	static PhysicalDeliveryAvailable() {
		return PhysicalAvailabilityReady(PhysicalShortcutDeliveryAvailable)
	}

	/**
	 * Checks the actual scope owner before a window opens.
	 * @param {Object} Scope A PhysicalShortcutsScope.
	 * @returns {Integer}
	 */
	static Available(Scope) {
		if !IsObject(Scope)
			return false
		for Name in ["CaptureEditorInventory", "EditorSourceCurrent", "Edit", "PhysicalDeliveryAvailable"] {
			if !HasMethod(Scope, Name)
				return false
		}
		return Scope.PhysicalDeliveryAvailable() == true && PhysicalShortcutsHost.NativeAvailable()
	}

	/**
	 * Opens one shared page over the admitted scope.
	 * @param {Map} Options "scope" and the live "is_paused" getter.
	 * @returns {Integer} 1 when the page is up.
	 */
	static Open(Options) {
		if !(Options is Map) || !HasMethod(Options.Get("is_paused", 0), "Call")
				|| Options["is_paused"].Call() != 0 || !PhysicalShortcutsHost.Available(Options.Get("scope", 0))
			return false
		Existing := PhysicalShortcutsHost.Current
		if IsObject(Existing) && !Existing.ResetDone {
			Existing.Close()
			if (PhysicalShortcutsHost.Current != 0)
				return false
		}
		Scope := Options["scope"]
		Model := Scope.Model
		Positions := []
		for Code in Model.Candidates()
			Positions.Push(Map("code", Code, "available", PHYSICAL_JSON_TRUE))
		WebViewHost._LoadManifest()
		Host := PhysicalShortcutsWindow()
		Host.AppId := PhysicalShortcutsHost.APP_ID
		PageCurrent() => PhysicalShortcutsHost.Current == Host && !Host.ResetDone && !Host.CloseRequested
			&& Options["is_paused"].Call() == 0
		SendPage(Name, Packet) {
			if !PageCurrent()
				return false
			Host.Eval(Name . "(" . PhysicalJsonEncode(Packet) . ")")
			return PageCurrent()
		}
		Host.Protocol := PhysicalEditorWindow(Map(
			"model", Model, "actions", PhysicalEntriesActions(), "positions", Positions,
			"page_current", PageCurrent, "send", SendPage, "translate", (Key) => t(Key),
			"close", () => Host._NativeClose(),
			"capture", () => Scope.CaptureEditorInventory(),
			"current", (Receipt) => Scope.EditorSourceCurrent(Receipt),
			"commit", (Rows, Receipt) => Scope.Edit(Rows, Receipt),
			"label", (Action) => GestureActionDisplayLabel(Action),
			"picker", (Binding, Action, Confirm) => PhysicalShortcutsHost._Picker(Binding, Action, Confirm, SendPage),
			"position_available", () => KHPositionCaptureAvailable() == 1,
			"capture_position", (Guard, Receive) => KHCapturePosition(Guard, Receive),
			"cancel_position", (Token) => KHCancelPosition(Token) == 1))
		Host.Opts := Map("OnMessage", (MessageHost, Payload) => MessageHost.Protocol.Receive(Payload))
		PhysicalShortcutsHost.Current := Host
		LoggerStart("PhysicalShortcuts", "Opening the physical shortcut editor.")
		try Built := Host._Build()
		catch as Err {
			LoggerError("PhysicalShortcuts", "The physical shortcut editor could not be created: {1}.", Err.Message)
			Built := false
		}
		if !Built {
			Host.Close()
			; The menu port tells this refusal once (window_unavailable).
			LoggerError("PhysicalShortcuts", "The WebView2 host of the physical shortcut editor did not open.")
			return false
		}
		Host.Gui.OnEvent("Escape", (*) => Host.Close())
		LoggerSuccess("PhysicalShortcuts", "The physical shortcut editor is open.")
		return true
	}

	; The shared action picker, then the action's own parameter prompt; the
	; choice is a draft until the page saves it.
	static _Picker(Binding, Action, Confirm, SendPage) {
		OnPick(Selected) {
			if (GestureActionParameterSpec(Selected) == "") {
				Accepted := Confirm.Call(Selected)
			} else {
				Candidate := GesturePromptActionParameter(Binding, Selected)
				; Dismissing the parameter prompt is an ordinary cancellation.
				if !(Candidate is Map)
					return false
				Accepted := Candidate.Get("has_value", false) ? Confirm.Call(Selected, Candidate["value"]) : Confirm.Call(Selected)
			}
			if (Accepted != true)
				SendPage.Call("refused", "save_failed")
			return Accepted == true ? 1 : 0
		}
		ShowActionPicker(t("physical_shortcuts.window_title"), Action, OnPick, false, Binding)
		return true
	}
}




; =================================================
; =================================================
; ======= 4/ Menu port ============================
; =================================================
; =================================================

/**
 * Binds the editor command to native readiness and the retained scope. Port
 * of physical_editor_menu.lua. Options (Map): "scope", "host", "paused" and
 * "refused" functions.
 */
class PhysicalEditorMenu {
	Busy := false

	__New(Options) {
		for Name in ["scope", "host", "paused", "refused"] {
			if !(Options is Map) || !HasMethod(Options.Get(Name, 0), "Call")
				throw ValueError("The physical editor menu port is incomplete.", -1, Name)
		}
		this.Options := Options
	}

	_Inspect() {
		if this.Options["paused"].Call() != 0
			return 0
		Host := this.Options["host"].Call()
		for Name in ["NativeAvailable", "Open", "PhysicalDeliveryAvailable", "Available"] {
			if !IsObject(Host) || !HasMethod(Host, Name)
				return 0
		}
		if Host.PhysicalDeliveryAvailable() != true || Host.NativeAvailable() != true
				|| this.Options["paused"].Call() != 0
			return 0
		return Host
	}

	/**
	 * The disabled_when getter of the editor row.
	 * @returns {Integer}
	 */
	Ready() {
		if this.Busy
			return false
		this.Busy := true
		try return IsObject(this._Inspect())
		catch as Err {
			LoggerError("PhysicalShortcuts", "The editor readiness check failed: {1}.", Err.Message)
			return false
		} finally this.Busy := false
	}

	/**
	 * The editor command: refuses once, captures no scope while refused.
	 * @returns {Integer} 1 when the editor opened.
	 */
	Open(*) {
		if this.Busy
			return false
		this.Busy := true
		Accepted := false
		try {
			Host := this._Inspect()
			if IsObject(Host) {
				Scope := this.Options["scope"].Call()
				if Host.Available(Scope) == true && this.Options["paused"].Call() == 0
					Accepted := Host.Open(Map("scope", Scope, "is_paused", this.Options["paused"])) == true
			}
		} catch as Err
			LoggerError("PhysicalShortcuts", "The editor could not open: {1}.", Err.Message)
		this.Busy := false
		if !Accepted {
			this.Options["refused"].Call()
			return false
		}
		return true
	}
}

/**
 * The production menu port of the Shortcuts submenu's editor row.
 * @returns {PhysicalEditorMenu}
 */
PhysicalShortcutsMenuPort() {
	static Port := PhysicalEditorMenu(Map(
		"paused", () => A_IsSuspended ? 1 : 0,
		"scope", () => PhysicalShortcutsScope(),
		"host", () => PhysicalShortcutsHost,
		"refused", () => Ui_MsgBox(t("physical_shortcuts.window_unavailable"), t("physical_shortcuts.window_title"), "Icon!")))
	return Port
}

/**
 * The editor row's getters: its readiness and the cause it names when greyed.
 * @param {PhysicalEditorMenu} Port The menu port; the production one by default.
 * @returns {Map}
 */
PhysicalShortcutsMenuGetters(Port := 0) {
	Owner := IsObject(Port) ? Port : PhysicalShortcutsMenuPort()
	return Map(
		"physical_shortcuts_editor_ready", () => Owner.Ready(),
		; The editor's honest cause while physical delivery is unqualified.
		"physical_shortcuts_delivery_unqualified", () => PhysicalShortcutsHost.PhysicalDeliveryAvailable() ? false : true)
}
