; ui/physical_shortcuts/editor.ahk

; ==============================================================================
; MODULE: Physical Shortcut Editor Session And Window Protocol
; DESCRIPTION:
; Ports of _shared/lua/shortcuts/physical_entries.lua, physical_editor.lua and
; physical_editor_window.lua for the Windows WebView2 host. The session keeps
; the exact native source the page shows; a picker choice is only a draft, and
; the native scope owns every publication. The page's JSON is never evidence.
; ==============================================================================




; ===================================
; ===================================
; ======= 1/ JSON packets ===========
; ===================================
; ===================================

; A JSON boolean: AutoHotkey's true is the integer 1, which the page's strict
; `=== true` would read as a number.
class PhysicalJsonBool {
	__New(Value) {
		this.Value := Value ? true : false
	}
}

global PHYSICAL_JSON_TRUE := PhysicalJsonBool(true)
global PHYSICAL_JSON_FALSE := PhysicalJsonBool(false)

/**
 * Encodes one packet built from Map, Array, String, Number and PhysicalJsonBool.
 * @param {Any} Value
 * @returns {String} JSON text.
 */
PhysicalJsonEncode(Value) {
	if Value is PhysicalJsonBool
		return Value.Value ? "true" : "false"
	if (Value is Integer) || (Value is Float)
		return String(Value)
	if Value is String
		return JsonStringLiteral(Value)
	if Value is Array {
		Out := ""
		for Item in Value
			Out .= (Out == "" ? "" : ",") . PhysicalJsonEncode(Item)
		return "[" . Out . "]"
	}
	if Value is Map {
		Out := ""
		for Key, Item in Value
			Out .= (Out == "" ? "" : ",") . JsonStringLiteral(Key) . ":" . PhysicalJsonEncode(Item)
		return "{" . Out . "}"
	}
	throw TypeError("A physical shortcut packet holds an unsupported value.", -1, Type(Value))
}

; The modifier set of a slot as the page reads it: every name, a JSON boolean.
_PhysicalModsPacket(ModSet) {
	Packet := Map()
	for Name in PhysicalSlots.MODIFIER_ORDER
		Packet[Name] := ModSet.Has(Name) ? PHYSICAL_JSON_TRUE : PHYSICAL_JSON_FALSE
	return Packet
}

; Accepts only a Map whose every key the closed field set names.
_PhysicalClosed(Value, Fields) {
	if !(Value is Map)
		return false
	for Field in Value {
		if !Fields.Has(Field)
			return false
	}
	return true
}

_PhysicalRequestId(Value) {
	return (Value is Integer) && Value >= 1
}




; =======================================
; =======================================
; ======= 2/ Entry planner ==============
; =======================================
; =======================================

/**
 * Plans Add/Edit/Remove against a detached acknowledged inventory. Port of
 * physical_entries.lua; the action catalogue is the Windows gesture catalogue.
 * @param {PhysicalSlots} Model
 * @param {Map} Request operation, slot, action?, parameter?, previous_slot?
 * @param {Map} Inventory Map("assignments", slot → action, "parameters", key → value).
 * @param {Map} Actions is_assignable, parameter_spec, validate_parameter ports.
 * @returns {Array|Integer} Scope rows, or 0 on a closed refusal.
 */
PhysicalEntriesPlan(Model, Request, Inventory, Actions) {
	static Fields := Map("operation", 1, "slot", 1, "action", 1, "parameter", 1, "previous_slot", 1)
	if !_PhysicalClosed(Request, Fields) || !(Inventory is Map)
			|| !(Inventory.Get("assignments", 0) is Map) || !(Inventory.Get("parameters", 0) is Map)
		return 0
	Assignments := Inventory["assignments"]
	Operation := Request.Get("operation", ""), Slot := Request.Get("slot", "")
	if !(Operation == "add" || Operation == "edit" || Operation == "remove") || !Model.Owns(Slot)
		return 0
	Previous := Request.Get("previous_slot", Slot)
	if !Model.Owns(Previous) || (Operation != "edit" && Request.Has("previous_slot"))
		return 0
	if (Operation == "add" && Assignments.Has(Slot))
			|| (Operation != "add" && !Assignments.Has(Previous))
			|| (Operation == "edit" && Previous !== Slot && Assignments.Has(Slot))
		return 0
	if (Operation == "remove" && (Request.Has("action") || Request.Has("parameter")))
		return 0
	Rows := []
	RemoveEntry(Id) {
		Rows.Push({ Section: ConfigKey.SHORTCUTS_KEYBOARD, Key: Id, Delete: true })
		Binding := GestureBindingId("keyboard", Id) . "__"
		Keys := ""
		for Key in Inventory["parameters"] {
			if (SubStr(Key, 1, StrLen(Binding)) == Binding)
					&& (Actions["parameter_spec"].Call(SubStr(Key, StrLen(Binding) + 1)) != "")
				Keys .= (Keys == "" ? "" : "`n") . Key
		}
		if (Keys != "") {
			for Key in StrSplit(Sort(Keys, "C"), "`n")
				Rows.Push({ Section: "action_parameters", Key: Key, Delete: true })
		}
	}
	if (Operation == "remove") {
		RemoveEntry(Slot)
		return Rows
	}
	Action := Request.Get("action", "")
	if !(Action is String) || Actions["is_assignable"].Call(Action) != true
		return 0
	Spec := Actions["parameter_spec"].Call(Action)
	if (Spec != "") {
		Parameter := Request.Get("parameter", 0)
		if !(Parameter is String) || Actions["validate_parameter"].Call(Action, Parameter) != true
			return 0
	} else if Request.Has("parameter")
		return 0
	if (Operation == "edit" && Previous !== Slot)
		RemoveEntry(Previous)
	Rows.Push({ Section: ConfigKey.SHORTCUTS_KEYBOARD, Key: Slot, Value: Action })
	if (Spec != "")
		Rows.Push({ Section: "action_parameters",
			Key: GestureActionParameterKey(GestureBindingId("keyboard", Slot), Action), Value: Parameter })
	return Rows
}

/**
 * The live Windows action catalogue the planner validates against.
 * @returns {Map}
 */
PhysicalEntriesActions() {
	return Map(
		"is_assignable", (Action) => GestureActionIsAssignable(Action) ? true : false,
		"parameter_spec", (Action) => GestureActionParameterSpec(Action),
		"validate_parameter", (Action, Value) => GestureValidateActionParameter(Action, Value) ? true : false)
}




; ======================================
; ======================================
; ======= 3/ Editor session ============
; ======================================
; ======================================

/**
 * One page-owned session over native source and publication ports. Port of
 * physical_editor.lua. Ports (Map): model, actions, capture, current, commit,
 * picker, label, emit, positions, and the optional capture_position,
 * cancel_position, position_available, emit_position.
 */
class PhysicalEditorSession {
	Alive := true
	Busy := false
	Generation := 0
	Serial := 0
	Inventory := 0
	Source := 0
	Draft := 0
	Position := 0

	__New(Ports) {
		for Name in ["model", "actions", "capture", "current", "commit", "picker", "label", "emit"] {
			if !Ports.Has(Name)
				throw ValueError("The physical editor port is incomplete.", -1, Name)
		}
		this.Ports := Ports
		this.Model := Ports["model"]
	}

	; The displayed source is still the one this session captured.
	_Current() {
		if !this.Alive || !IsObject(this.Source)
			return false
		Expected := this.Source, Epoch := this.Generation
		try Accepted := this.Ports["current"].Call(Expected)
		catch
			return false
		return Accepted == true && this.Alive && this.Source == Expected && this.Generation == Epoch
	}

	; Captures a coherent canonical snapshot; refusal names its reason.
	_Capture(&Reason := "") {
		try Captured := this.Ports["capture"].Call()
		catch {
			Reason := "window_unavailable"
			return false
		}
		if !(Captured is Map) || !(Captured.Get("inventory", 0) is Map) || !IsObject(Captured.Get("receipt", 0)) {
			Reason := (Captured is Map) && Captured.Get("reason", "") == "source_changed" ? "source_changed" : "window_unavailable"
			return false
		}
		this.Inventory := Captured["inventory"], this.Source := Captured["receipt"]
		return this._Current()
	}

	_Records() {
		Ordered := ""
		for Slot in this.Inventory["assignments"]
			Ordered .= (Ordered == "" ? "" : "`n") . Slot
		Result := []
		if (Ordered == "")
			return Result
		for Slot in StrSplit(Sort(Ordered, "C"), "`n") {
			Descriptor := this.Model.Parse(Slot)
			Action := this.Inventory["assignments"][Slot]
			if (Descriptor is Map) && (Action is String)
				Result.Push(Map("slot", Slot, "code", Descriptor["code"], "mods", _PhysicalModsPacket(Descriptor["mods"]),
					"action", Action, "label", this.Ports["label"].Call(Action)))
		}
		return Result
	}

	/**
	 * Opens from a coherent canonical snapshot, never browser state.
	 * @returns {Map|Integer} The init packet, or 0 with Reason set.
	 */
	Open(&Reason := "") {
		if !this.Alive || this.Busy || IsObject(this.Source) {
			Reason := "window_unavailable"
			return 0
		}
		this.Busy := true
		try {
			if !this._Capture(&Reason) {
				if (Reason == "")
					Reason := "source_changed"
				return 0
			}
			Entries := this._Records()
			if !this._Current() {
				Reason := "window_unavailable"
				return 0
			}
			Capture := this.Ports.Has("capture_position") && this.Ports.Has("cancel_position")
				&& this.Ports.Has("position_available") && this.Ports.Has("emit_position")
				&& this.Ports["position_available"].Call() == true && this._Current()
			return Map("entries", Entries, "positions", this.Ports["positions"],
				"capture", Capture ? PHYSICAL_JSON_TRUE : PHYSICAL_JSON_FALSE)
		} catch {
			Reason := "window_unavailable"
			return 0
		} finally this.Busy := false
	}

	/**
	 * Cancels an observation without changing the configured key or draft.
	 * @returns {Integer} 1 when the exact native request acknowledged.
	 */
	CancelPosition() {
		Record := this.Position
		if !IsObject(Record)
			return true
		Record.Cancelled := true
		if !IsObject(Record.Token) || Record.Retiring
			return false
		Record.Retiring := true
		try Retired := Record.Cancel.Call(Record.Token)
		catch
			Retired := false
		Record.Retiring := false
		if (Retired != true)
			return false
		if (this.Position == Record)
			this.Position := 0
		return true
	}

	/**
	 * Requests detached position facts from the native observation owner.
	 * @param {Map} Request Page-local request_id only; browser keys are not evidence.
	 * @returns {Integer} 1 when enrolled.
	 */
	CapturePosition(Request) {
		if this.Busy
			return false
		this.Busy := true
		try {
			if !this._Current() || !_PhysicalClosed(Request, Map("request_id", 1))
					|| !_PhysicalRequestId(Request.Get("request_id", 0))
					|| !this.Ports.Has("capture_position") || !this.Ports.Has("cancel_position")
					|| !this.Ports.Has("emit_position")
				return false
			if this.CancelPosition() != true
				return false
			Record := { Source: this.Source, Epoch: this.Generation, RequestId: Request["request_id"],
				Cancel: this.Ports["cancel_position"], Token: 0, Cancelled: false, Retiring: false, Completed: false }
			this.Position := Record
			Owned() => this.Position == Record && !Record.Cancelled && this.Source == Record.Source
				&& this.Generation == Record.Epoch
			Exact() => Owned() && this._Current() && Owned()
			Receive(Facts) {
				if this.Busy || Record.Completed || !IsObject(Record.Token)
					return false
				this.Busy := true
				try {
					if !Exact() || !_PhysicalClosed(Facts, Map("native_code", 1, "mods", 1))
						return false
					Code := this.Model.CodeFor(Facts.Get("native_code", ""))
					Slot := Code != "" ? this.Model.Encode(Code, Facts.Get("mods", 0)) : ""
					Descriptor := Slot != "" ? this.Model.Parse(Slot) : 0
					if !(Descriptor is Map) || !Exact()
						return false
					Packet := Map("action", "captured", "request_id", Record.RequestId,
						"code", Descriptor["code"], "mods", _PhysicalModsPacket(Descriptor["mods"]))
					return this.Ports["emit_position"].Call(Packet) == true && Exact()
				} catch
					return false
				finally {
					; A native request observes at most one primary key.
					Record.Completed := true
					this.Busy := false
				}
			}
			try Token := this.Ports["capture_position"].Call(Exact, Receive)
			catch
				Token := 0
			if !IsObject(Token) {
				if (this.Position == Record)
					this.Position := 0
				return false
			}
			Record.Token := Token
			if !Exact() {
				this.CancelPosition()
				return false
			}
			return true
		} finally this.Busy := false
	}

	/**
	 * Opens the existing action picker without publishing its result.
	 * @param {Map} Request code, mods, request_id and the optional previous_slot.
	 * @returns {Integer} 1 when the picker opened.
	 */
	Choose(Request) {
		if this.Busy
			return false
		this.Busy := true
		try {
			if this.CancelPosition() != true || !this._Current()
					|| !_PhysicalClosed(Request, Map("code", 1, "mods", 1, "previous_slot", 1, "request_id", 1))
					|| !_PhysicalRequestId(Request.Get("request_id", 0))
				return false
			Slot := this.Model.Encode(Request.Get("code", ""), Request.Get("mods", 0))
			Previous := Request.Get("previous_slot", "")
			if (Slot == "") || (Request.Has("previous_slot")
					&& (!this.Model.Owns(Previous) || !this.Inventory["assignments"].Has(Previous)))
				return false
			this.Serial += 1, this.Generation += 1
			Token := this.Serial, Epoch := this.Generation
			this.Draft := 0
			Owner := Previous != "" ? Previous : Slot
			Action := this.Inventory["assignments"].Get(Owner, "none")
			Confirm(Selected, Parameter := unset) {
				if this.Busy
					return false
				this.Busy := true
				try {
					if (this.Generation != Epoch) || !this._Current()
						return false
					Plan := Map("operation", Previous != "" ? "edit" : "add", "slot", Slot, "action", Selected)
					if (Previous != "")
						Plan["previous_slot"] := Previous
					if IsSet(Parameter)
						Plan["parameter"] := Parameter
					if !(PhysicalEntriesPlan(this.Model, Plan, this.Inventory, this.Ports["actions"]) is Array)
							|| this.Generation != Epoch || !this._Current()
						return false
					Packet := Map("action", "selected", "token", Token, "request_id", Request["request_id"],
						"label", this.Ports["label"].Call(Selected))
					if this.Ports["emit"].Call(Packet) != true || !this._Current() || this.Generation != Epoch
						return false
					Plan.Delete("operation")
					this.Draft := { Token: Token, Epoch: Epoch, Plan: Plan }
					return true
				} catch
					return false
				finally this.Busy := false
			}
			Opened := this.Ports["picker"].Call(GestureBindingId("keyboard", Owner), Action, Confirm)
			return Opened == true && this.Alive && this.Generation == Epoch
		} catch
			return false
		finally this.Busy := false
	}

	_Publish(Plan) {
		Rows := PhysicalEntriesPlan(this.Model, Plan, this.Inventory, this.Ports["actions"])
		if !(Rows is Array) || !this._Current()
			return Map("committed", PHYSICAL_JSON_FALSE, "reason", "source_changed")
		Receipt := this.Source, Epoch := this.Generation
		try Answer := this.Ports["commit"].Call(Rows, Receipt)
		catch
			Answer := 0
		if !(Answer is Map) || Answer.Get("committed", false) != true {
			Reason := (Answer is Map) ? Answer.Get("reason", "") : ""
			if !(Reason == "source_changed" || Reason == "collision" || Reason == "unavailable")
				Reason := "save_failed"
			return Map("committed", PHYSICAL_JSON_FALSE, "reason", Reason)
		}
		; Durable success is truthful even when its refreshed display is refused.
		this.Draft := 0, this.Inventory := 0, this.Source := 0
		this.Generation += 1
		try {
			if this.Alive && this.Generation == Epoch + 1 && this._Capture() {
				Entries := this._Records()
				if this._Current() && this.Generation == Epoch + 1
					return Map("committed", PHYSICAL_JSON_TRUE, "refreshed", PHYSICAL_JSON_TRUE, "entries", Entries)
			}
		} catch as Err
			LoggerWarn("PhysicalShortcuts", "The saved shortcuts could not be shown again: {1}.", Err.Message)
		return Map("committed", PHYSICAL_JSON_TRUE, "refreshed", PHYSICAL_JSON_FALSE)
	}

	/**
	 * Publishes only the exact acknowledged picker draft.
	 * @param {Integer} Token Opaque page-session draft identity.
	 * @returns {Map} Publication and refreshed display receipts.
	 */
	Save(Token) {
		if this.Busy
			return Map("committed", PHYSICAL_JSON_FALSE, "reason", "source_changed")
		this.Busy := true
		try {
			Draft := this.Draft
			if !this._Current() || !IsObject(Draft) || Token !== Draft.Token || Draft.Epoch != this.Generation
				return Map("committed", PHYSICAL_JSON_FALSE, "reason", "source_changed")
			Plan := Draft.Plan.Clone()
			Plan["operation"] := Plan.Has("previous_slot") ? "edit" : "add"
			return this._Publish(Plan)
		} catch
			return Map("committed", PHYSICAL_JSON_FALSE, "reason", "save_failed")
		finally this.Busy := false
	}

	/**
	 * Removes one displayed entry and only its recognized binding parameters.
	 * @param {String} Slot Exact canonical displayed identity.
	 * @returns {Map} Publication acknowledgement.
	 */
	Remove(Slot) {
		if this.Busy
			return Map("committed", PHYSICAL_JSON_FALSE, "reason", "source_changed")
		this.Busy := true
		try {
			if !this._Current() || !(Slot is String) || !this.Inventory["assignments"].Has(Slot)
				return Map("committed", PHYSICAL_JSON_FALSE, "reason", "source_changed")
			return this._Publish(Map("operation", "remove", "slot", Slot))
		} catch
			return Map("committed", PHYSICAL_JSON_FALSE, "reason", "save_failed")
		finally this.Busy := false
	}

	/**
	 * Retires drafts without touching native configuration or foreign windows.
	 * @returns {Integer} 1 when the observation retired.
	 */
	Close() {
		this.Alive := false, this.Draft := 0
		if this.CancelPosition() != true
			return false
		this.Generation += 1
		return true
	}
}




; ======================================
; ======================================
; ======= 4/ Window protocol ===========
; ======================================
; ======================================

/**
 * Keeps one exact native page attached to a session. Port of
 * physical_editor_window.lua. Ports (Map): the session's, plus page_current,
 * send(name, packet), close and translate.
 */
class PhysicalEditorWindow {
	static LABELS := Map(
		"title", "physical_shortcuts.window_title", "position-label", "physical_shortcuts.position",
		"manual-hint", "physical_shortcuts.manual_hint", "capture", "physical_shortcuts.capture",
		"capture-reason", "physical_shortcuts.capture_unavailable", "empty", "physical_shortcuts.empty",
		"edit", "physical_shortcuts.edit", "modifier-label", "ui_typing.tab_modifiers",
		"choose", "dialog.action_picker.label", "add", "button.add", "remove", "button.remove",
		"save", "button.save", "cancel", "button.cancel", "close", "button.close", "saved", "common.saved",
		"source_changed", "physical_shortcuts.source_changed", "save_failed", "physical_shortcuts.save_failed",
		"saved_reopen", "physical_shortcuts.saved_reopen", "collision", "physical_shortcuts.collision",
		"unavailable", "physical_shortcuts.position_unavailable",
		"window_unavailable", "physical_shortcuts.window_unavailable")
	static FIELDS := Map(
		"ready", Map("action", 1), "choose", Map("action", 1, "request", 1),
		"capture_position", Map("action", 1, "request", 1), "cancel_position", Map("action", 1),
		"save", Map("action", 1, "token", 1), "remove", Map("action", 1, "slot", 1), "close", Map("action", 1))

	ReadyDone := false
	Busy := false
	Retired := false
	CloseRequested := false
	EditorClosed := false
	EditorRetiring := false
	NativeClosed := false

	/**
	 * Names every modifier and position the page shows from the shared key
	 * name table, in the user's language: the page shows no id or W3C code.
	 * @param {Map} Packet The init packet: its positions and entries.
	 * @param {Func} Translate Takes a locale key, returns its text.
	 * @returns {Map} Map("modifiers", id → name, "positions", code → name).
	 */
	static Names(Packet, Translate) {
		Modifiers := Map(), Positions := Map()
		for Name in PhysicalSlots.MODIFIER_ORDER
			Modifiers[Name] := KeyNameLabel(Name, Translate)
		for List in [Packet["positions"], Packet["entries"]] {
			for Record in List
				Positions[Record["code"]] := KeyNamePhysicalLabel(Record["code"], Translate)
		}
		return Map("modifiers", Modifiers, "positions", Positions)
	}

	__New(Ports) {
		for Name in ["page_current", "send", "close", "translate"] {
			if !Ports.Has(Name)
				throw ValueError("The physical window port is incomplete.", -1, Name)
		}
		this.Ports := Ports
		SessionPorts := Ports.Clone()
		SessionPorts["current"] := (Receipt) => this._PageCurrent() && Ports["current"].Call(Receipt) == true
			&& this._PageCurrent()
		SessionPorts["emit"] := (Packet) => this._PageCurrent() && Ports["send"].Call("selected", Packet) == true
		SessionPorts["emit_position"] := (Packet) => this._PageCurrent()
			&& Ports["send"].Call("captured", Packet) == true && this._PageCurrent()
		this.Session := PhysicalEditorSession(SessionPorts)
	}

	_PageCurrent() {
		return !this.Retired && this.Ports["page_current"].Call() == true
	}

	_RetireEditor() {
		if this.EditorClosed
			return true
		if this.EditorRetiring
			return false
		this.EditorRetiring := true
		try Acknowledged := this.Session.Close()
		catch
			Acknowledged := false
		this.EditorRetiring := false
		if (Acknowledged == true)
			this.EditorClosed := true
		return this.EditorClosed
	}

	_Send(Name, Packet) {
		return this.Ports["send"].Call(Name, Packet) == true
	}

	; The page's view of the init packet: its strings, the names, read-only on refusal.
	_InitPacket() {
		Reason := ""
		try Packet := this.Session.Open(&Reason)
		catch
			Packet := 0
		if !(Packet is Map)
			Packet := Map("entries", [], "positions", [], "capture", PHYSICAL_JSON_FALSE, "readonly", PHYSICAL_JSON_TRUE,
				"reason", Reason == "source_changed" ? "source_changed" : "window_unavailable")
		try Names := PhysicalEditorWindow.Names(Packet, this.Ports["translate"])
		catch {
			Packet := Map("entries", [], "positions", [], "capture", PHYSICAL_JSON_FALSE, "readonly", PHYSICAL_JSON_TRUE,
				"reason", "window_unavailable")
			Names := PhysicalEditorWindow.Names(Packet, this.Ports["translate"])
		}
		Packet["names"] := Names
		Strings := Map()
		for Key, LocaleKey in PhysicalEditorWindow.LABELS
			Strings[Key] := this.Ports["translate"].Call(LocaleKey)
		Packet["strings"] := Strings
		return Packet
	}

	/**
	 * Routes one closed page operation to its exact native session.
	 * @param {Map} Message The decoded page message.
	 * @returns {Integer} 1 when handled.
	 */
	Receive(Message) {
		if this.Busy || !(Message is Map)
			return false
		Action := Message.Get("action", "")
		if !(Action is String) || !PhysicalEditorWindow.FIELDS.Has(Action)
				|| !_PhysicalClosed(Message, PhysicalEditorWindow.FIELDS[Action])
			return false
		if (Action == "close")
			return this.Close()
		if !this._PageCurrent()
			return false
		if (Action == "ready") {
			if this.ReadyDone
				return false
			this.Busy := true
			try Packet := this._InitPacket()
			finally this.Busy := false
			if !this._PageCurrent()
				return false
			this.ReadyDone := this._Send("init", Packet)
			return this.ReadyDone
		}
		if !this.ReadyDone
			return false
		if (Action == "cancel_position")
			return this.Session.CancelPosition()
		if (Action == "capture_position") {
			Enrolled := this.Session.CapturePosition(Message.Get("request", 0))
			if (Enrolled != true)
				this._Send("refused", "unavailable")
			return Enrolled == true
		}
		if (Action == "choose") {
			Opened := this.Session.Choose(Message.Get("request", 0))
			if (Opened != true)
				this._Send("refused", "save_failed")
			return Opened == true
		}
		this.Busy := true
		try Result := Action == "save" ? this.Session.Save(Message.Get("token", 0)) : this.Session.Remove(Message.Get("slot", 0))
		catch
			Result := Map("committed", PHYSICAL_JSON_FALSE, "reason", "save_failed")
		finally this.Busy := false
		if !this._PageCurrent()
			return false
		return this._Send("result", Result)
	}

	/**
	 * Closes only after the observation and the native page acknowledge.
	 * @returns {Integer} 1 when both owners retired.
	 */
	Close() {
		if this.Busy || this.NativeClosed
			return false
		this.Busy := true
		try {
			if !this.CloseRequested && (!this._PageCurrent() || this.Retired)
				return false
			this.CloseRequested := true, this.Retired := true
			if this._RetireEditor() != true
				return false
			try Acknowledged := this.Ports["close"].Call()
			catch
				Acknowledged := false
			if (Acknowledged == true)
				this.NativeClosed := true
			return this.NativeClosed
		} finally this.Busy := false
	}

	/**
	 * Revokes the page and retires its observation; not a native close receipt.
	 * @returns {Integer} 1 when the editor retirement acknowledged.
	 */
	Retire() {
		this.Retired := true
		return this._RetireEditor()
	}
}
