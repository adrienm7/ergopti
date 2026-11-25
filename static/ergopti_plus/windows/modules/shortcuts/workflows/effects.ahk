; modules/shortcuts/workflows/effects.ahk

; ==============================================================================
; MODULE: User Workflow Effects and Owner (Windows)
; DESCRIPTION:
; The Windows half of _shared/shortcuts/engine/workflows/effects.lua and of
; the macOS and Linux modules/shortcuts/workflows.lua: each effect of the
; interpreter becomes one call of a Windows port (keys and text through the
; send-input owner, open through the shell, the window manager, the
; clipboard, the pointer, the gesture executor, the notifier, cmd.exe), and
; one owner per driver, built on first use, answers the run_workflow action,
; the binding editors, Escape and the pause.
;
; FEATURES & RATIONALE:
; 1. A missing capability is named, never skipped: without a screen port the
;    screen steps answer screen_service_missing, a port that says no answers
;    step_failed. The screen port is WorkflowScreen (screen.ahk) over the screen
;    vision service: the front window, embedded PNGs written as private
;    template files, OCR with the shared text match, the interactive region.
; 2. A shell step runs `cmd.exe /d /s /c` with the run_command line, through
;    the run_command owner (UserActionHiddenShell), which alone launches a
;    user's shell: the command reaches the inner cmd.exe by
;    delayed expansion of a private variable, and the workflow variables are
;    ERGOPTI_VAR_<name> environment variables, never command text.
; 3. Every OS call goes through an existing adapter (timers, files, windows,
;    pointer, clipboard, notifier, process runner), so this module adds no
;    direct OS call to the purity ledger.
; 4. Explicit initialization ownership: WorkflowsInit builds the owner once;
;    a second call with other ports raises; WorkflowsStop releases it.
; ==============================================================================

#Requires AutoHotkey v2.0

; The effects that need the screen services (capture, OCR, matching).
global WORKFLOW_SCREEN_OPS := Map("wait_for", true, "capture", true, "ocr", true, "click_target", true)

; The ports every driver supplies (effects.lua REQUIRED_PORTS).
global WORKFLOW_REQUIRED_EFFECT_PORTS := ["send_shortcut", "type_text", "after", "open", "focus_app",
	"clipboard_get", "clipboard_set", "mouse_move", "mouse_click", "run_action", "notify", "shell", "app_front"]

; The virtual key of Escape, as the keyboard hook reports it.
global WORKFLOW_ESCAPE_VK := 0x1B

; The environment of a shell step: each variable under its prefixed name,
; ERGOPTI_VAR_<name> (effects.lua ENV_PREFIX).
WorkflowEnvironment(Variables) {
	Env := Map()
	for Name, Value in Variables
		Env["ERGOPTI_VAR_" . Name] := String(Value)
	return Env
}





; ===================================
; ===================================
; ======= 1/ Effect performer =======
; ===================================
; ===================================

/**
 * Turns each effect of the interpreter into one call of the driver's ports.
 * Every port answers through a Done callable: Done(true[, Value]) is a
 * success, Done(false[, Reason]) a refusal.
 */
class WorkflowEffects {
	/**
	 * @param {Map} Ports The WORKFLOW_REQUIRED_EFFECT_PORTS callables, and
	 *   optionally "screen", an object (WorkflowScreen) whose wait_for,
	 *   capture, ocr, click_target and visible methods take (Effect,
	 *   Done(Result Map), Workflow) and return a cancel callable.
	 */
	__New(Ports) {
		global WORKFLOW_REQUIRED_EFFECT_PORTS
		_WorkflowRequirePorts(Ports, WORKFLOW_REQUIRED_EFFECT_PORTS, "Workflow effects")
		this.Ports := Ports
		this.Cancels := Map()
	}

	Keep(Effect, Cancel) {
		if HasMethod(Cancel, "Call")
			this.Cancels[Effect] := Cancel
	}

	Finish(Effect, Done, Result) {
		if this.Cancels.Has(Effect)
			this.Cancels.Delete(Effect)
		Done.Call(Result)
	}

	; A Done for the ports that answer ok or a refusal.
	Plain(Effect, Done) {
		return (Ok, Reason := "") => this.Finish(Effect, Done,
			Ok ? Map("ok", true) : Map("ok", false, "reason", Reason != "" ? Reason : "step_failed"))
	}

	; A Done for the ports that answer a value.
	Valued(Effect, Done) {
		return (Ok, Value := "") => this.Finish(Effect, Done,
			Ok ? Map("ok", true, "value", Value) : Map("ok", false, "reason", Value != "" ? Value : "step_failed"))
	}

	/**
	 * Performs one effect of the interpreter.
	 * @param {Map} Effect
	 * @param {Func} Done Done(Map "ok", "value", "reason"), called once.
	 * @param {Map} Workflow The running workflow.
	 */
	Perform(Effect, Done, Workflow := 0) {
		global WORKFLOW_SCREEN_OPS
		Op := Effect["op"]
		Ports := this.Ports
		if WORKFLOW_SCREEN_OPS.Has(Op) || (Op == "probe" && Effect["condition"]["type"] == "visible") {
			Name := Op == "probe" ? "visible" : Op
			Screen := Ports.Get("screen", 0)
			if !IsObject(Screen) || !HasMethod(Screen, Name)
				return this.Finish(Effect, Done, Map("ok", false, "reason", "screen_service_missing"))
			return this.Keep(Effect, Screen.%Name%(Effect, (Result) => this.Finish(Effect, Done, Result), Workflow))
		}
		switch Op, true {
			case "send_keys":
				return Ports["send_shortcut"].Call(Effect["combo"], this.Plain(Effect, Done))
			case "type_text":
				return Ports["type_text"].Call(Effect["text"], this.Plain(Effect, Done))
			case "wait":
				return this.Keep(Effect, Ports["after"].Call(Effect["duration_ms"],
					() => this.Finish(Effect, Done, Map("ok", true))))
			case "open":
				return Ports["open"].Call(Effect["target_kind"], Effect["value"], this.Plain(Effect, Done))
			case "focus_app":
				return Ports["focus_app"].Call(Effect["app"], this.Plain(Effect, Done))
			case "clipboard_get":
				return Ports["clipboard_get"].Call(this.Valued(Effect, Done))
			case "clipboard_set":
				return Ports["clipboard_set"].Call(Effect["text"], this.Plain(Effect, Done))
			case "mouse_move":
				return Ports["mouse_move"].Call(Effect["x"], Effect["y"], this.Plain(Effect, Done))
			case "mouse_click":
				return Ports["mouse_click"].Call(Effect["x"], Effect["y"], Effect.Get("button", "left"),
					Effect.Get("count", 1), this.Plain(Effect, Done))
			case "run_action":
				return Ports["run_action"].Call(Effect["action"], this.Plain(Effect, Done))
			case "notify":
				return Ports["notify"].Call(Effect["text"], this.Plain(Effect, Done))
			case "shell":
				return this.Keep(Effect, Ports["shell"].Call(Effect["command"], WorkflowEnvironment(Effect["environment"]),
					Effect["deadline_ms"], this.Valued(Effect, Done)))
			case "probe":
				return this.Probe(Effect, Done)
		}
		throw ValueError("No workflow performer for effect " . Op . ".", -1)
	}

	Probe(Effect, Done) {
		Condition := Effect["condition"]
		if Condition["type"] == "app_front"
			return this.Ports["app_front"].Call(Condition["app"], (Ok, Front := false) => this.Finish(Effect, Done,
				Ok ? Map("ok", true, "value", Front ? true : false) : Map("ok", false, "reason", "step_failed")))
		if Condition["type"] == "matches" && Condition["source"] == "clipboard"
			return this.Ports["clipboard_get"].Call((Ok, Text := "") => this.Finish(Effect, Done,
				Ok ? Map("ok", true, "value", WorkflowMatches(Text, Condition))
					: Map("ok", false, "reason", Text != "" ? Text : "step_failed")))
		throw ValueError("No workflow probe for condition " . Condition["type"] . ".", -1)
	}

	; Stops a pending effect (a wait, a shell child, a screen scan).
	Cancel(Effect) {
		Cancel := this.Cancels.Get(Effect, 0)
		if this.Cancels.Has(Effect)
			this.Cancels.Delete(Effect)
		if HasMethod(Cancel, "Call")
			Cancel.Call()
	}
}




; ===================================
; ===================================
; ======= 2/ Windows ports ==========
; ===================================
; ===================================

; A timer: Fn runs once after Ms; the answer cancels it.
_WorkflowAfter(Ms, Fn) {
	Bound := () => Fn.Call()
	TimerArmOneShotMs(Bound, Max(1, Ms))
	return () => TimerSetCallback(Bound, 0)
}

_WorkflowSendShortcut(Combo, Done) {
	Parsed := SendKeysParseShortcut(Combo)
	Done.Call((Parsed is Map) && SendKeysEmit("shortcut", Parsed) ? true : false)
}

_WorkflowTypeText(Text, Done) {
	Done.Call(SendFinalResult(Text, true, true) ? true : false)
}

; An app, a link or a file opened by the shell, as the Run dialog would.
_WorkflowOpen(Kind, Value, Done) {
	global WORKFLOW_LOG
	if Kind == "file" && !FSExists(Value) {
		LoggerWarn(WORKFLOW_LOG, "A workflow open step names a file that does not exist.")
		return Done.Call(false)
	}
	try {
		SystemControl().Launch(Value)
	} catch as Err {
		LoggerWarn(WORKFLOW_LOG, "A workflow open step was refused by the shell ({1}).", Type(Err))
		return Done.Call(false)
	}
	Done.Call(true)
}

; The process name a step names an application by: Code or code.exe.
_WorkflowProcessName(App) {
	return RegExMatch(App, "i)\.exe$") ? App : App . ".exe"
}

_WorkflowFocusApp(App, Done) {
	global WORKFLOW_LOG
	Spec := "ahk_exe " . _WorkflowProcessName(App)
	if !WMExists(Spec) {
		LoggerWarn(WORKFLOW_LOG, "A workflow focus step names an application with no open window.")
		return Done.Call(false)
	}
	Done.Call(WMActivate(Spec))
}

; Whether the active window belongs to App: its process name equals or holds it.
_WorkflowAppFront(App, Done) {
	Front := StrLower(WMGetFocused()["process"])
	Wanted := StrLower(App)
	Done.Call(true, Front != "" && (Front == _WorkflowProcessName(Wanted) || InStr(Front, Wanted, true) > 0))
}

_WorkflowClipboardGet(Done) {
	Done.Call(true, CB_Read())
}

_WorkflowClipboardSet(Text, Done) {
	Done.Call(CB_Write(Text) ? true : false)
}

; Coordinates are physical pixels of the virtual screen, as the mouse adapter sets them.
_WorkflowMouseMove(X, Y, Done) {
	MCSetPos(X, Y)
	Done.Call(true)
}

_WorkflowMouseClick(X, Y, Button, Count, Done) {
	global WORKFLOW_LOG
	MCSetPos(X, Y)
	try Click(Button . " " . Count)
	catch as Err {
		LoggerWarn(WORKFLOW_LOG, "A workflow click was refused ({1}).", Type(Err))
		return Done.Call(false)
	}
	Done.Call(true)
}

; A parameterless Ergopti action through the gesture executor; a parameterised
; one has no value a step can give and is refused.
_WorkflowRunAction(Action, Done) {
	global GESTURE_ACTIONS, WORKFLOW_LOG
	if !GESTURE_ACTIONS.Has(Action) || GestureActionParameterSpec(Action) != "" {
		LoggerWarn(WORKFLOW_LOG, "A workflow step names '{1}', which is no parameterless action here.", Action)
		return Done.Call(false)
	}
	GestureInvokeAction(Action)
	Done.Call(true)
}

_WorkflowNotify(Text, Done) {
	Done.Call(NotifierSend(Text, Map("level", "info")) ? true : false)
}

; A shell step: the run_command line under a private environment, its stdout
; read back once it exits. @returns {Func} The cancel of the running child.
_WorkflowShell(Command, Env, DeadlineMs, Done) {
	global USER_COMMAND_VARIABLE, USER_COMMAND_OUT_VARIABLE, USER_COMMAND_ERR_VARIABLE, WORKFLOW_LOG
	static Counter := 0
	Counter += 1
	Stem := A_Temp . "\ergopti_workflow_shell_" . ProcessExist() . "_" . Counter
	State := { Done: Done, Out: Stem . ".out", Err: Stem . ".err", Over: false, Handle: 0 }
	Variables := Map(USER_COMMAND_VARIABLE, UserActionCommandLine(Command),
		USER_COMMAND_OUT_VARIABLE, State.Out, USER_COMMAND_ERR_VARIABLE, State.Err)
	for Name, Value in Env
		Variables[Name] := Value
	try {
		State.Handle := UserActionHiddenShell(ShellRunner_BuildEnvironment(Variables), _WorkflowShellDone.Bind(State))
		Started := State.Handle.start()
	} catch as Err {
		LoggerError(WORKFLOW_LOG, "The command of a workflow shell step could not start ({1}).", Type(Err))
		Started := false
	}
	if !(Started is Integer) || Started != 1 {
		_WorkflowShellSettle(State, false, "step_failed")
		return 0
	}
	LoggerInfo(WORKFLOW_LOG, "The command of a workflow shell step started.")
	return _WorkflowShellCancel.Bind(State)
}

_WorkflowShellDone(State, ExitCode := unset, *) {
	global WORKFLOW_LOG
	if State.Over
		return true
	if !IsSet(ExitCode) || ExitCode != 0 {
		LoggerWarn(WORKFLOW_LOG, "The command of a workflow shell step exited with code {1}.", IsSet(ExitCode) ? ExitCode : "?")
		_WorkflowShellSettle(State, false, "step_failed")
		return true
	}
	Text := FSSize(State.Out) > TimingsGet("limits", "user_action_output_bytes") ? false : UserActionReadCapture(State.Out)
	if !(Text is String) {
		LoggerWarn(WORKFLOW_LOG, "The output of a workflow shell step is too large or not UTF-8.")
		_WorkflowShellSettle(State, false, "step_failed")
		return true
	}
	_WorkflowShellSettle(State, true, RTrim(StrReplace(Text, "`r`n", "`n"), "`r`n"))
	return true
}

; Ends a shell step once: its captures are removed, then its Done is told.
_WorkflowShellSettle(State, Ok, Value) {
	global WORKFLOW_LOG
	if State.Over
		return
	State.Over := true
	for Path in [State.Out, State.Err]
		if FSExists(Path) && !FSDelete(Path)
			LoggerWarn(WORKFLOW_LOG, "A capture of a workflow shell step could not be deleted.")
	State.Done.Call(Ok, Value)
}

; The deadline or an abort: the child tree is killed and its answer ignored.
_WorkflowShellCancel(State) {
	global WORKFLOW_LOG
	if State.Over
		return
	State.Over := true
	try State.Handle.terminate()
	catch as Err
		LoggerWarn(WORKFLOW_LOG, "A workflow shell step could not be stopped ({1}).", Type(Err))
	for Path in [State.Out, State.Err]
		if FSExists(Path) && !FSDelete(Path)
			LoggerWarn(WORKFLOW_LOG, "A capture of a workflow shell step could not be deleted.")
}

; The real Windows ports; WorkflowsInit replaces any of them (tests).
_WorkflowDefaultEffectPorts() {
	return Map("send_shortcut", _WorkflowSendShortcut, "type_text", _WorkflowTypeText, "after", _WorkflowAfter,
		"open", _WorkflowOpen, "focus_app", _WorkflowFocusApp, "clipboard_get", _WorkflowClipboardGet,
		"clipboard_set", _WorkflowClipboardSet, "mouse_move", _WorkflowMouseMove, "mouse_click", _WorkflowMouseClick,
		"run_action", _WorkflowRunAction, "notify", _WorkflowNotify, "shell", _WorkflowShell,
		"app_front", _WorkflowAppFront)
}

; The screen vision service, started once by its owner (AutoClickVision).
_WorkflowVisionReady() {
	AutoClickVision()
	return true
}

; The front window, as the auto-clicker scans it.
_WorkflowWindowImage(Done) {
	Hwnd := WIGetForegroundHwnd()
	if !Hwnd
		return Done.Call(0, "no_foreground_window")
	_WorkflowVisionReady()
	ScreenVisionCaptureWindow(Hwnd, Done)
}

; full: the primary monitor; window: the front window; region: the overlay the
; « Capture → texte » action draws (RegionSelect).
_WorkflowCapture(Mode, Done) {
	AsCapture := (Image, Reason := "") => IsObject(Image) ? Done.Call(Map("image", Image)) : Done.Call(0, Reason)
	if Mode == "window"
		return _WorkflowWindowImage(AsCapture)
	_WorkflowVisionReady()
	if Mode == "full" {
		Bounds := MCGetMonitorBounds(1)
		return ScreenVisionCaptureRegion(Map("x", Bounds["left"], "y", Bounds["top"],
			"width", Bounds["right"] - Bounds["left"], "height", Bounds["bottom"] - Bounds["top"]), AsCapture)
	}
	if !RegionSelect((Rect, Reason := "") => IsObject(Rect) ? ScreenVisionCaptureRegion(Rect, AsCapture)
			: Done.Call(0, "capture_refused"))
		Done.Call(0, "capture_refused")
}

; An embedded PNG as a template: a private file in the service's cache folder,
; written once per image.
_WorkflowTemplate(Bytes, Key, Done) {
	global WORKFLOW_LOG
	static Paths := Map(), Count := 0
	Digest := CryptoSha256Bytes(Bytes)
	if !Paths.Has(Digest) {
		_WorkflowVisionReady()
		Count += 1
		try {
			Path := ScreenVisionCacheDir() . "\workflow_template_" . Count . ".png"
			FSWriteBytesStrict(Path, Bytes)
		} catch as Err {
			LoggerWarn(WORKFLOW_LOG, "A workflow image could not be written as a template ({1}).", Type(Err))
			return Done.Call(0, "template_unreadable")
		}
		Paths[Digest] := Path
	}
	Done.Call(Map("path", Paths[Digest]))
}

_WorkflowMatch(Image, Templates, Done) {
	ScreenVisionMatch(Image, Templates, WorkflowsModule.Matcher, Done)
}

; A target search reads sparse text; an ocr step reads a block.
_WorkflowRecognize(Capture, Done) {
	Options := Map("layout", Capture.Get("layout", "block"))
	if Capture.Has("image")
		return ScreenVisionRecognizeText(Capture["image"], Options, Done)
	ScreenVisionRecognizeFile(Capture["path"], Options, Done)
}

; The service writes every capture to a PNG file: its path is the step's value.
_WorkflowSave(Capture, Done) {
	Done.Call(Capture.Has("path") ? Capture["path"] : Capture["image"]["source"])
}

_WorkflowClickPoint(Frame, Scale, Hit) {
	AutoClickClickPoint(Frame["x"], Frame["y"], Scale,
		{ X: Hit["x"], Y: Hit["y"], Width: Hit["width"], Height: Hit["height"] }, &X, &Y)
	return [X, Y]
}

; The Windows vision ports of the screen steps.
_WorkflowVisionPorts() {
	return Map("window_image", _WorkflowWindowImage, "capture", _WorkflowCapture, "template", _WorkflowTemplate,
		"match", _WorkflowMatch, "recognize", _WorkflowRecognize, "save", _WorkflowSave,
		"click", (X, Y, Button, Done) => _WorkflowMouseClick(X, Y, Button, 1, Done),
		"click_point", _WorkflowClickPoint, "find_text", ScreenVisionFindText, "after", _WorkflowAfter,
		"now_ms", () => A_TickCount)
}

; The config-folder file ports: an absent file reads as 0, any other failure raises.
_WorkflowDefaultStorePorts() {
	return Map("path", _WorkflowConfigPath, "read", _WorkflowReadConfigFile, "write", _WorkflowWriteConfigFile)
}

; @returns {String} The absolute path of a file of the config folder.
_WorkflowConfigPath(Name) {
	global _ConfigDir
	return RTrim(_ConfigDir, "\") . "\" . Name
}

_WorkflowReadConfigFile(Path) {
	if !FSStrictExists(Path)
		return 0
	return FSReadStrict(Path)
}

; A complete sibling stage, then one write-through rename over the file.
_WorkflowWriteConfigFile(Path, Text) {
	Stage := Path . ".partial"
	if !FSWriteDurable(Stage, Text)
		throw OSError("The workflow file stage could not be written: " . Stage, -1)
	if !FSAtomicMoveReplace(Stage, Path, &NativeError) {
		FSDelete(Stage)
		throw OSError("The workflow file could not be replaced (" . NativeError . "): " . Path, -1)
	}
}

; Escape while a workflow runs, as the keyboard hook reports a physical key.
_WorkflowWatchEscape(Callback) {
	HookDispatcher.Register(HookDispatcherConst.EVT_KB_DOWN, Callback)
}




; ===================================
; ===================================
; ======= 3/ Driver owner ===========
; ===================================
; ===================================

class WorkflowsModule {
	static Owner := 0
	static Given := 0
	static Catalogue := 0
	static Matcher := 0
}

; The registry deadlines steps.json names, and the wait-for poll interval.
WorkflowRegistryTimeouts() {
	Timeouts := Map()
	for Key in ["step_timeout_ms", "screen_step_timeout_ms", "shell_timeout_ms", "wait_max_ms", "wait_for_poll_ms"]
		Timeouts[Key] := TimingsGet("workflows", Key)
	return Timeouts
}

; The decoded steps.json, read once; a missing or malformed file is a broken install.
WorkflowCatalogue() {
	global _SharedDir
	if IsObject(WorkflowsModule.Catalogue)
		return WorkflowsModule.Catalogue
	WorkflowsModule.Catalogue := JsonParse(FSReadStrict(_SharedDir . "\" . WorkflowCataloguePath()))
	return WorkflowsModule.Catalogue
}

/**
 * Builds the owner once from the Windows ports.
 * @param {Map} Overrides Replacements: "effects", "store" (Maps of ports
 *   merged over the real ones), "translate", "notify", "watch_escape",
 *   "timeouts" (tests). A second call with other overrides raises.
 * @returns {WorkflowOwner}
 */
WorkflowsInit(Overrides := 0) {
	global WORKFLOW_LOG, _SharedDir
	if IsObject(WorkflowsModule.Owner) {
		if IsObject(Overrides) && Overrides != WorkflowsModule.Given
			throw Error("The workflow owner is already initialized with other ports.", -1)
		return WorkflowsModule.Owner
	}
	Given := (Overrides is Map) ? Overrides : Map()
	EffectPorts := _WorkflowDefaultEffectPorts()
	for Name, Port in Given.Get("effects", Map())
		EffectPorts[Name] := Port
	StorePorts := _WorkflowDefaultStorePorts()
	for Name, Port in Given.Get("store", Map())
		StorePorts[Name] := Port
	Timeouts := Given.Get("timeouts", 0)
	if !(Timeouts is Map)
		Timeouts := WorkflowRegistryTimeouts()
	StorePorts["catalogue"] := WorkflowCatalogue()
	if !Given.Get("effects", Map()).Has("screen") {
		WorkflowsModule.Matcher := JsonParse(FSReadStrict(_SharedDir . "\shortcuts\data\auto_click_defaults.json"))
		EffectPorts["screen"] := WorkflowScreen(_WorkflowVisionPorts(), Map("catalogue", StorePorts["catalogue"],
			"poll_ms", Timeouts["wait_for_poll_ms"], "text_max_distance", WorkflowsModule.Matcher["text_max_distance"],
			"threshold", WorkflowsModule.Matcher["threshold"]))
	}
	StorePorts["timings"] := Map("wait_max_ms", Timeouts["wait_max_ms"])
	WorkflowsModule.Owner := WorkflowOwner(Map("store", StorePorts, "effects", WorkflowEffects(EffectPorts),
		"after", EffectPorts["after"], "timeouts", Timeouts,
		"translate", Given.Get("translate", (Key) => t(Key)),
		"notify", Given.Get("notify", _WorkflowNotice)))
	WorkflowsModule.Given := IsObject(Overrides) ? Overrides : 0
	Given.Get("watch_escape", _WorkflowWatchEscape).Call(_WorkflowOnKeyDown)
	LoggerInfo(WORKFLOW_LOG, "Workflow owner initialized.")
	return WorkflowsModule.Owner
}

; An error notice of the owner; one the notifier refuses is logged.
_WorkflowNotice(Text) {
	global WORKFLOW_LOG
	if !NotifierSend(Text, Map("level", "error"))
		LoggerWarn(WORKFLOW_LOG, "A workflow notice could not be shown.")
}

; The keyboard hook's key-down: Escape stops every run, the key still reaches
; the application.
_WorkflowOnKeyDown(InputHookObj, Vk, Sc) {
	global WORKFLOW_ESCAPE_VK
	if Vk == WORKFLOW_ESCAPE_VK && IsObject(WorkflowsModule.Owner) && WorkflowsModule.Owner.IsRunning()
		TimerArmOneShotMs(WorkflowsOnEscape, 1)
}

; Escape while a workflow runs. @returns {Boolean} Whether a run was stopped.
WorkflowsOnEscape(*) {
	if !IsObject(WorkflowsModule.Owner) || !WorkflowsModule.Owner.IsRunning()
		return false
	return WorkflowsModule.Owner.AbortAll() > 0
}

; Stops every running workflow (the pause). @returns {Integer} How many.
WorkflowsAbortAll() {
	if !IsObject(WorkflowsModule.Owner)
		return 0
	return WorkflowsModule.Owner.AbortAll()
}

; The run_workflow action: a decoded parameter Map("id"). @returns {Boolean} Started.
WorkflowsRun(Fields) {
	return WorkflowsInit().RunAction(Fields)
}

; The binding editors' choices Maps ("value", "label"), or 0 after a notice.
WorkflowsChoices() {
	return WorkflowsInit().Choices()
}

; Stops every run and releases the owner (driver shutdown, tests).
WorkflowsStop() {
	if !IsObject(WorkflowsModule.Owner)
		return
	WorkflowsModule.Owner.Stop()
	WorkflowsModule.Owner := 0
	WorkflowsModule.Given := 0
}

; @returns {Boolean} Whether a stored run_workflow value names a workflow id.
WorkflowParameterIsValid(Value) {
	return WorkflowIsId(Value)
}

/**
 * Runs the action of a hotstring action entry once its edit has landed
 * (hotstrings/engine/matcher/action_entry.ahk), as the macOS and Linux
 * action_runner.lua do: a workflow through the workflow owner, any other
 * parameterless action through the gesture executor. The matcher calls it on
 * the next timer turn.
 * @param {Map} Fields "action", and "workflow" for run_workflow.
 * @param {Map} Ports Replacements of "run_workflow", "execute" and "parameter_spec" (tests).
 * @returns {Boolean} Ran.
 */
WorkflowsRunEntryAction(Fields, Ports := 0) {
	global WORKFLOW_LOG
	Given := (Ports is Map) ? Ports : Map()
	Executors := Map("run_workflow", Given.Get("run_workflow", WorkflowsRun),
		"execute", Given.Get("execute", (Action) => GestureInvokeAction(Action)),
		"parameter_spec", Given.Get("parameter_spec", GestureActionParameterSpec))
	Refusal := ""
	Ran := HSE_ActionEntryDispatch(Fields, Executors, &Refusal)
	if !Ran
		LoggerWarn(WORKFLOW_LOG, "The action '{1}' of a hotstring did not run: {2}.", Fields["action"],
			Refusal != "" ? Refusal : "refused")
	return Ran
}

/**
 * The run_workflow gesture action: runs the workflow the binding stores, on the
 * next timer turn, so its keys never reach the application under the hotkey's
 * held modifiers.
 * @param {String} BindingId
 * @returns {Boolean} Whether a run was scheduled.
 */
WorkflowsRunBinding(BindingId := "") {
	global WORKFLOW_LOG
	Value := GestureGetActionParameter(BindingId, "run_workflow")
	if !WorkflowParameterIsValid(Value) {
		LoggerWarn(WORKFLOW_LOG, "run_workflow ignored for binding '{1}': no valid workflow is stored.", BindingId)
		return false
	}
	TimerArmOneShotMs(() => WorkflowsRun(Map("id", Value)), 1)
	return true
}
