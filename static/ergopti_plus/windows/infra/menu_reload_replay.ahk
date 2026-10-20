; infra/menu_reload_replay.ahk

; ==============================================================================
; MODULE: Menu Reload Replay
; DESCRIPTION:
; Carries tray commands that land while a reload is pending into the successor.
; From the launch of the successor to this instance's exit, the terminal barrier
; owns every configuration path, so a command run here could only be refused
; (`terminal_barrier_busy`, one error toast per click, the click lost). Such a
; command is held instead and identified by its canonical action when declared, with its labels
; retained for diagnostics and undeclared rows. When OnExit accepts the reload, the held rows are published once beside
; the configuration locator; the successor consumes that file once at startup
; and its startup owner replays each row against its own published tray after
; input readiness. A reload refused later lets the held commands run here.
; ==============================================================================

#Requires AutoHotkey v2.0

global MENU_RELOAD_REPLAY_FILENAME := "menu_reload_replay.json"
global MENU_RELOAD_REPLAY_SCHEMA := "ergopti.menu_reload_replay.v2"
global MENU_RELOAD_REPLAY_MENU_PROPERTY := "__ErgoptiReplayMenuIdentity"

; Held rows in click order, keyed by an increasing integer.
global _MenuReloadReplayHeld := Map()
global _MenuReloadReplayNextKey := 0
global _MenuReloadReplayPublished := false
global _MenuReloadReplayConsumed := false
; Canonical action keys belong to one registration token, never a recyclable ID.
global _MenuReloadReplayIdentities := Map()

; Test seam: the Menu standing for the tray root; 0 means A_TrayMenu.
global _MenuReloadReplayRoot := 0





; ==========================================
; ==========================================
; ======= 1/ Holding in the instance =======
; ==========================================
; ==========================================

/**
 * Decides whether a menu command waits for the pending reload's successor.
 * @param {Integer} HeldKey The key a previous look returned, 0 for a new command.
 * @param {Object|Integer} Registration The command's native item identity, or 0.
 * @param {Array|Integer} RefusedPath The retained path after a refused reload, or 0.
 * @returns {Integer} 0 to run the command here, a positive key to look again
 *     later, -1 when the command was already handed to the successor.
 */
MenuReloadReplay_Hold(HeldKey, Registration, &RefusedPath := unset) {
	global _MenuReloadReplayHeld, _MenuReloadReplayNextKey, _MenuReloadReplayPublished
	global MENU_STARTUP_MAX_PENDING
	RefusedPath := 0
	if !(HeldKey is Integer) || HeldKey < 0
		throw TypeError("A held menu command key must be a nonnegative integer.")
	Active := ReloadTerminalHandoffActive()
	if HeldKey {
		if !_MenuReloadReplayHeld.Has(HeldKey) {
			if _MenuReloadReplayPublished
				return -1
			throw Error("A held menu command lost its reload hand-off entry.")
		}
		if Active
			return HeldKey
		Path := _MenuReloadReplayHeld[HeldKey]
		_MenuReloadReplayHeld.Delete(HeldKey)
		RefusedPath := Path
		try LoggerInfo("MenuDispatcher", "The reload ended without a successor; the held menu command '{1}' resolves against the current tray.",
			MenuReloadReplay_Describe(Path))
		return 0
	}
	if !Active
		return 0
	if _MenuReloadReplayPublished {
		try LoggerWarn("MenuDispatcher", "Menu command refused: the reload successor already received the held commands.")
		return -1
	}
	if !IsObject(Registration) {
		try LoggerWarn("MenuDispatcher", "A menu command without a native registration cannot wait for the reload successor; it runs and reports its own refusal.")
		return 0
	}
	if _MenuReloadReplayHeld.Count >= MENU_STARTUP_MAX_PENDING {
		try LoggerError("MenuDispatcher", "{1} menu commands already wait for the reload successor; this one runs and reports its own refusal.",
			_MenuReloadReplayHeld.Count)
		return 0
	}
	try Path := MenuReloadReplay_PathOf(Registration.ItemId)
	catch as Err {
		try LoggerError("MenuDispatcher", "The tray could not be read to hand a menu command to the reload successor: {1}; it runs and reports its own refusal.",
			Err.Message)
		return 0
	}
	if !(Path is Array) {
		try LoggerError("MenuDispatcher", "Menu item {1} is not reachable from the tray, so it cannot wait for the reload successor; it runs and reports its own refusal.",
			Registration.ItemId)
		return 0
	}
	_MenuReloadReplayNextKey += 1
	_MenuReloadReplayHeld[_MenuReloadReplayNextKey] := Path
	try LoggerInfo("MenuDispatcher", "Menu command '{1}' waits for the reload successor; {2} held.",
		MenuReloadReplay_Describe(Path), _MenuReloadReplayHeld.Count)
	return _MenuReloadReplayNextKey
}

/** Withdraws a held command whose next look could not be scheduled. */
MenuReloadReplay_Release(HeldKey) {
	global _MenuReloadReplayHeld
	if _MenuReloadReplayHeld.Has(HeldKey)
		_MenuReloadReplayHeld.Delete(HeldKey)
}

/** Number of commands currently waiting for the reload successor. */
MenuReloadReplay_HeldCount() {
	global _MenuReloadReplayHeld
	return _MenuReloadReplayHeld.Count
}

/** Joins a row path for the log. */
MenuReloadReplay_Describe(Path) {
	Text := ""
	for Label in Path
		Text .= (Text == "" ? "" : " > ") . Label
	return Text
}





; ====================================
; ====================================
; ======= 2/ Tray row identity =======
; ====================================
; ====================================

/** Attaches declared parent identity to its actual Menu lifetime, not its handle. */
MenuReloadReplay_SetMenuIdentity(NativeMenu, Identity) {
	global MENU_RELOAD_REPLAY_MENU_PROPERTY
	if !(NativeMenu is Menu) || !(Identity is String) || Identity == ""
		throw TypeError("A declared replay parent requires a native menu and its identity.")
	Object.Prototype.DefineProp.Call(NativeMenu, MENU_RELOAD_REPLAY_MENU_PROPERTY, {Value: Identity})
}

_MenuReloadReplayContextPart(Sub, Label) {
	global MENU_RELOAD_REPLAY_MENU_PROPERTY
	NativeMenu := MenuFromHandle(Sub)
	if NativeMenu is Menu && Object.Prototype.HasOwnProp.Call(NativeMenu, MENU_RELOAD_REPLAY_MENU_PROPERTY) {
		Descriptor := Object.Prototype.GetOwnPropDesc.Call(NativeMenu, MENU_RELOAD_REPLAY_MENU_PROPERTY)
		if Descriptor.HasOwnProp("Value") && Descriptor.Value is String && Descriptor.Value != ""
			return "I" . Descriptor.Value
	}
	return "L" . Label
}

/** Keeps the renderer's canonical action separate from its visible caption. */
MenuReloadReplay_RegisterIdentity(ItemId, Token, Identity) {
	global _MenuReloadReplayIdentities
	if !(Identity is String)
		throw TypeError("A menu replay identity must be a String.")
	MenuReloadReplay_ForgetIdentity(ItemId)
	if Identity != ""
		_MenuReloadReplayIdentities[ItemId] := {Token: Token, Identity: Identity}
}

MenuReloadReplay_ForgetIdentity(ItemId) {
	global _MenuReloadReplayIdentities
	if _MenuReloadReplayIdentities.Has(ItemId)
		_MenuReloadReplayIdentities.Delete(ItemId)
}

MenuReloadReplay_ClearIdentities() {
	global _MenuReloadReplayIdentities
	_MenuReloadReplayIdentities := Map()
}

_MenuReloadReplayIdentityOf(ItemId) {
	global _MenuReloadReplayIdentities, _MenuDispatchTokens
	if !_MenuReloadReplayIdentities.Has(ItemId) || !_MenuDispatchTokens.Has(ItemId)
		return ""
	Entry := _MenuReloadReplayIdentities[ItemId]
	return Entry.Token == _MenuDispatchTokens[ItemId] ? Entry.Identity : ""
}

_MenuReloadReplayRootMenu() {
	global _MenuReloadReplayRoot
	return _MenuReloadReplayRoot is Menu ? _MenuReloadReplayRoot : A_TrayMenu
}

/**
 * Returns the labels from the tray root to a registered item.
 * @param {Integer} ItemId The native command identifier.
 * @returns {Array|Boolean} The labels, or false when no row carries the item.
 */
MenuReloadReplay_PathOf(ItemId) {
	if !(ItemId is Integer) || ItemId <= 0
		throw TypeError("A menu row path requires a positive native item identifier.")
	Path := [], Context := []
	if !_MenuReloadReplayFind(_MenuReloadReplayRootMenu().Handle, ItemId, Path, Context, Map())
		return false
	Identity := _MenuReloadReplayIdentityOf(ItemId)
	if Identity != "" {
		Path.ReplayIdentity := Identity
		Path.ReplayContext := Context
	}
	return Path
}

_MenuReloadReplayFind(Handle, ItemId, Path, Context, Seen) {
	if Seen.Has(Handle)
		return false
	Seen[Handle] := true
	Count := _MenuReloadReplayCount(Handle)
	Loop Count {
		Position := A_Index - 1
		Sub := TrayMenuSubmenuHandle(Handle, Position)
		if Sub {
			Label := _MenuReloadReplayLabel(Handle, Position)
			if Label == ""
				continue
			Path.Push(Label)
			Context.Push(_MenuReloadReplayContextPart(Sub, Label))
			if _MenuReloadReplayFind(Sub, ItemId, Path, Context, Seen)
				return true
			Path.Pop(), Context.Pop()
			continue
		}
		if TrayMenuHandleItemId(Handle, Position) != ItemId
			continue
		Label := _MenuReloadReplayLabel(Handle, Position)
		if Label == ""
			return false
		Path.Push(Label)
		return true
	}
	return false
}

/**
 * Finds the one row a path names in the live tray, completing deferred leaves.
 * @param {Array} Path Labels from the tray root.
 * @returns {Object|Boolean} ItemId, Handle, 1-based Position and Label, or false
 *     when a level has no row or more than one row with that label.
 */
MenuReloadReplay_Resolve(Path) {
	global _MenuPopulationPublished
	_MenuReloadReplayRequirePath(Path)
	if !Path.HasOwnProp("ReplayIdentity")
		return _MenuReloadReplayResolveLabels(Path)
	Identity := Path.ReplayIdentity
	if IsSet(_MenuPopulationPublished) && _MenuPopulationPublished is MenuPopulation
		_MenuPopulationPublished.CompleteReplayIdentity(Identity)
	Matches := []
	_MenuReloadReplayFindIdentity(_MenuReloadReplayRootMenu().Handle, Identity, Path.ReplayContext, [], Matches, Map())
	if Matches.Length == 1
		return Matches[1]
	; Context is part of identity even when only one matching declaration
	; survived. Otherwise a removed file's command could target another file.
	return false
}

_MenuReloadReplayFindIdentity(Handle, Identity, WantedContext, Context, Matches, Seen) {
	if Seen.Has(Handle)
		return
	Seen[Handle] := true
	try {
		Loop _MenuReloadReplayCount(Handle) {
			Position := A_Index - 1
			Flags := DllCall("GetMenuState", "Ptr", Handle, "UInt", Position, "UInt", 0x400, "UInt")
			if Flags == 0xFFFFFFFF
				throw OSError(A_LastError, A_ThisFunc, "The replay row's current state could not be read.")
			if Flags & 0x3
				continue
			Sub := DllCall("GetSubMenu", "ptr", Handle, "int", Position, "ptr")
			if Sub {
				Context.Push(_MenuReloadReplayContextPart(Sub, _MenuReloadReplayLabel(Handle, Position)))
				_MenuReloadReplayFindIdentity(Sub, Identity, WantedContext, Context, Matches, Seen)
				Context.Pop()
				continue
			}
			ItemId := DllCall("GetMenuItemID", "ptr", Handle, "int", Position, "uint")
			if _MenuReloadReplayIdentityOf(ItemId) == Identity && _MenuReloadReplayContextMatches(Context, WantedContext)
				Matches.Push({ItemId: ItemId, Handle: Handle, Position: Position + 1,
					Label: _MenuReloadReplayLabel(Handle, Position)})
		}
	} finally Seen.Delete(Handle)
}

_MenuReloadReplayContextMatches(Left, Right) {
	if Left.Length != Right.Length
		return false
	for Index, Part in Left {
		if !(Part == Right[Index])
			return false
	}
	return true
}

_MenuReloadReplayResolveLabels(Path) {
	global _MenuPopulationPublished
	Handle := _MenuReloadReplayRootMenu().Handle
	for Index, Wanted in Path {
		Last := Index == Path.Length
		if IsSet(_MenuPopulationPublished) && _MenuPopulationPublished is MenuPopulation
			_MenuPopulationPublished.Complete(Handle, "reload replay")
		Matches := 0
		FoundPosition := -1
		Loop _MenuReloadReplayCount(Handle) {
			Position := A_Index - 1
			if _MenuReloadReplayLabel(Handle, Position) != Wanted
				continue
			Flags := DllCall("GetMenuState", "Ptr", Handle, "UInt", Position, "UInt", 0x400, "UInt")
			if Flags == 0xFFFFFFFF
				throw OSError(A_LastError, A_ThisFunc, "The replay row's current state could not be read.")
			if Flags & 0x3
				continue
			Sub := TrayMenuSubmenuHandle(Handle, Position)
			if Last ? !Sub : Sub {
				Matches += 1
				FoundPosition := Position
			}
		}
		if Matches != 1
			return false
		if !Last {
			Handle := TrayMenuSubmenuHandle(Handle, FoundPosition)
			continue
		}
		ItemId := TrayMenuHandleItemId(Handle, FoundPosition)
		if !ItemId || ItemId == 0xFFFFFFFF
			return false
		return {ItemId: ItemId, Handle: Handle, Position: FoundPosition + 1, Label: Wanted}
	}
	return false
}

_MenuReloadReplayCount(Handle) {
	Count := TrayMenuHandleItemCount(Handle)
	if Count < 0
		throw OSError(A_LastError, A_ThisFunc, "GetMenuItemCount failed for a tray menu.")
	return Count
}

_MenuReloadReplayLabel(Handle, Position) {
	return TrayMenuHandleItemCaption(Handle, Position)
}

_MenuReloadReplayRequirePath(Path) {
	if !(Path is Array) || Path.Length == 0
		throw ValueError("A menu row path must be a non-empty array of labels.")
	for Label in Path {
		if !(Label is String) || Label == ""
			throw ValueError("A menu row path holds only non-empty labels.")
	}
	if Path.HasOwnProp("ReplayIdentity") {
		if !(Path.ReplayIdentity is String) || Path.ReplayIdentity == "" || !Path.HasOwnProp("ReplayContext")
				|| !(Path.ReplayContext is Array) || Path.ReplayContext.Length != Path.Length - 1
			throw ValueError("A canonical menu replay identity requires its exact parent context.")
		for Part in Path.ReplayContext {
			if !(Part is String) || Part == ""
				throw ValueError("A canonical replay context must hold nonempty String parts.")
		}
	}
}





; ========================================
; ========================================
; ======= 3/ Publication at OnExit =======
; ========================================
; ========================================

/** Absolute path of the hand-off file, beside the stable configuration locator. */
MenuReloadReplay_FilePath() {
	global _PathsFile, MENU_RELOAD_REPLAY_FILENAME
	if !IsSet(_PathsFile) || !(_PathsFile is String) || _PathsFile == ""
		throw Error("The menu reload hand-off requires the configuration locator.")
	return SuspendHandoffMarkerPath(_PathsFile, MENU_RELOAD_REPLAY_FILENAME)
}

/**
 * Publishes the held commands, then still-retained startup selections, once.
 * Called from OnExit after every refusal gate accepted a reload.
 * @param {String} FilePath Test seam; the locator's hand-off file by default.
 * @returns {Boolean} True when nothing was held or the file was published.
 */
MenuReloadReplay_Publish(FilePath := "") {
	global _MenuReloadReplayHeld, _MenuReloadReplayPublished, _MenuStartupCommands
	global MENU_STARTUP_MAX_PENDING
	PreviousCritical := Critical("On")
	try {
		if _MenuReloadReplayPublished
			throw Error("Menu commands were already handed to the reload successor.")
		Paths := []
		if IsSet(_MenuStartupCommands) && _MenuStartupCommands is MenuStartupCommands
			Paths := _MenuStartupCommands.TakeForReload()
		for Key, Path in _MenuReloadReplayHeld
			Paths.Push(Path)
		_MenuReloadReplayHeld := Map()
		_MenuReloadReplayPublished := true
	} finally Critical(PreviousCritical)
	if Paths.Length == 0
		return true
	if Paths.Length > MENU_STARTUP_MAX_PENDING {
		try LoggerError("MenuDispatcher", "{1} menu commands wait for the reload successor; only the first {2} are handed over.",
			Paths.Length, MENU_STARTUP_MAX_PENDING)
		Paths.RemoveAt(MENU_STARTUP_MAX_PENDING + 1, Paths.Length - MENU_STARTUP_MAX_PENDING)
	}
	if FilePath == ""
		FilePath := MenuReloadReplay_FilePath()
	StagePath := FilePath . ".stage"
	try LoggerStart("MenuDispatcher", "Handing {1} menu command(s) to the reload successor…", Paths.Length)
	try {
		if !FSWriteDurable(StagePath, _MenuReloadReplayEncode(Paths))
			throw Error("the staged file could not be written")
		if !FSAtomicMoveReplace(StagePath, FilePath, &NativeError)
			throw OSError(NativeError, A_ThisFunc, "the staged file could not be published")
	} catch as Err {
		try FSDeleteStrict(StagePath)
		catch as CleanupErr
			try LoggerError("MenuDispatcher", "The staged menu hand-off '{1}' could not be removed: {2}.", StagePath, CleanupErr.Message)
		try LoggerError("MenuDispatcher", "The menu commands could not be handed to the reload successor: {1}.", Err.Message)
		return false
	}
	try LoggerSuccess("MenuDispatcher", "{1} menu command(s) handed to the reload successor.", Paths.Length)
	return true
}

_MenuReloadReplayEncode(Paths) {
	global MENU_RELOAD_REPLAY_SCHEMA
	Commands := ""
	for Path in Paths {
		_MenuReloadReplayRequirePath(Path)
		Labels := ""
		for Label in Path
			Labels .= (Labels == "" ? "" : ",") . JsonStringLiteral(Label)
		Encoded := "[" . Labels . "]"
		if Path.HasOwnProp("ReplayIdentity") {
			Context := ""
			for Part in Path.ReplayContext
				Context .= (Context == "" ? "" : ",") . JsonStringLiteral(Part)
			Encoded := '{"labels":' . Encoded . ',"identity":' . JsonStringLiteral(Path.ReplayIdentity)
				. ',"context":[' . Context . ']}'
		}
		Commands .= (Commands == "" ? "" : ",") . Encoded
	}
	return '{"schema":' . JsonStringLiteral(MENU_RELOAD_REPLAY_SCHEMA)
		. ',"commands":[' . Commands . ']}' . "`n"
}





; ===============================================
; ===============================================
; ======= 4/ Consumption in the successor =======
; ===============================================
; ===============================================

/**
 * Consumes the hand-off file once at startup. The file is deleted before its
 * rows are accepted, so a later boot can never replay them a second time.
 * @param {String} FilePath Test seam; the locator's hand-off file by default.
 * @param {Func} NotifyFn Test seam for the lost-command notice.
 * @returns {Array} Row paths to retain until input readiness.
 */
MenuReloadReplay_Consume(FilePath := "", NotifyFn := 0) {
	global _MenuReloadReplayConsumed
	if _MenuReloadReplayConsumed
		throw Error("The menu reload hand-off was already consumed by this instance.")
	_MenuReloadReplayConsumed := true
	if FilePath == ""
		FilePath := MenuReloadReplay_FilePath()
	; A stage never crossed the accepted reload: it carries no intent.
	StagePath := FilePath . ".stage"
	try {
		if FSStrictExists(StagePath) {
			FSDeleteStrict(StagePath)
			try LoggerWarn("MenuDispatcher", "An unpublished menu hand-off stage from an interrupted exit was discarded.")
		}
		Present := FSStrictExists(FilePath)
	} catch as Err {
		; Startup goes on without the replay; the user is told the clicks were lost.
		try LoggerError("MenuDispatcher", "The menu hand-off '{1}' could not be probed: {2}; nothing is replayed.", FilePath, Err.Message)
		_MenuReloadReplayNotifyLost(NotifyFn)
		return []
	}
	if !Present
		return []
	try LoggerStart("MenuDispatcher", "Reading the menu commands handed over by the previous instance…")
	Text := FSRead(FilePath)
	try FSDeleteStrict(FilePath)
	catch as Err {
		try LoggerError("MenuDispatcher", "The menu hand-off '{1}' could not be consumed: {2}; nothing is replayed.", FilePath, Err.Message)
		_MenuReloadReplayNotifyLost(NotifyFn)
		return []
	}
	try Paths := _MenuReloadReplayDecode(Text)
	catch as Err {
		try LoggerError("MenuDispatcher", "The menu hand-off from the previous instance is invalid: {1}; nothing is replayed.", Err.Message)
		_MenuReloadReplayNotifyLost(NotifyFn)
		return []
	}
	try LoggerSuccess("MenuDispatcher", "{1} menu command(s) from the previous instance wait for input readiness.", Paths.Length)
	return Paths
}

_MenuReloadReplayDecode(Text) {
	global MENU_RELOAD_REPLAY_SCHEMA, MENU_STARTUP_MAX_PENDING
	if !(Text is String)
		throw ValueError("the file could not be read")
	Document := JsonParse(Text)
	if !(Document is Map) || Document.Count != 2 || !Document.Has("schema") || !Document.Has("commands")
		throw ValueError("the document must hold exactly a schema and its commands")
	if !(Document["schema"] is String) || Document["schema"] != MENU_RELOAD_REPLAY_SCHEMA
		throw ValueError("unknown schema")
	Commands := Document["commands"]
	if !(Commands is Array) || Commands.Length == 0 || Commands.Length > MENU_STARTUP_MAX_PENDING
		throw ValueError("the command list must hold 1 to " . MENU_STARTUP_MAX_PENDING . " rows")
	Paths := []
	for Command in Commands {
		if Command is Map {
			if Command.Count != 3 || !Command.Has("labels") || !Command.Has("identity") || !Command.Has("context")
					|| !(Command["identity"] is String) || Command["identity"] == ""
				throw ValueError("a canonical command requires labels and its nonempty identity")
			Path := Command["labels"]
			_MenuReloadReplayRequirePath(Path)
			Path.ReplayIdentity := Command["identity"]
			Path.ReplayContext := Command["context"]
		} else
			Path := Command
		_MenuReloadReplayRequirePath(Path)
		Paths.Push(Path)
	}
	return Paths
}

/**
 * Replays one handed-over row against the live tray, through the normal
 * dispatch with the row's current registration and native arguments.
 * @param {Array} Path Labels from the tray root.
 * @param {Func} NotifyFn Test seam for the lost-command notice.
 */
MenuReloadReplay_Run(Path, NotifyFn := 0) {
	global _MenuDispatchCallbacks, _MenuDispatchTokens
	Describe := MenuReloadReplay_Describe(Path)
	try Target := MenuReloadReplay_Resolve(Path)
	catch as Err {
		try LoggerError("MenuDispatcher", "The tray could not be read to replay '{1}' from before the reload: {2}.", Describe, Err.Message)
		_MenuReloadReplayNotifyLost(NotifyFn)
		return false
	}
	if !IsObject(Target) || !_MenuDispatchCallbacks.Has(Target.ItemId)
			|| !_MenuDispatchTokens.Has(Target.ItemId) {
		try LoggerError("MenuDispatcher", "Menu command '{1}' from before the reload matches no single row of this menu; it was not replayed.", Describe)
		_MenuReloadReplayNotifyLost(NotifyFn)
		return false
	}
	try LoggerInfo("MenuDispatcher", "Menu command '{1}' from before the reload replays.", Describe)
	return MenuCommandRun(_MenuDispatchCallbacks[Target.ItemId],
		[Target.Label, Target.Position, MenuFromHandle(Target.Handle)], 0, 0, 0,
		{ItemId: Target.ItemId, Token: _MenuDispatchTokens[Target.ItemId]})
}

_MenuReloadReplayNotifyLost(NotifyFn) {
	Message := t("menu.reload_replay.lost")
	Options := Map("title", t("menu.reload_replay.lost_title"), "level", "error")
	if HasMethod(NotifyFn, "Call")
		NotifyFn.Call(Message, Options)
	else
		try NotifierSend(Message, Options)
}
