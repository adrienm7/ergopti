; ui/layer_editor/init.ahk

; ==============================================================================
; MODULE: Navigation Layer Editor (Windows host)
; DESCRIPTION:
; Shows the shared navigation layer editor (_shared/ui/layer_editor) in a
; WebView2 window through the manifest-driven WebViewHost factory, answers its
; "ready" with the user's layers.toml, and saves what it sends: the text must
; load without an error on every OS (platform/remap/layers_loader.ahk), is
; published atomically, and the driver reloads so NavLayer_Init registers the
; edited layer. The macOS and Linux hosts implement the same contract through
; _shared/lua/keymap/layer_editor.lua.
;
; FEATURES & RATIONALE:
; 1. The page offers only what exists on Windows; the host still refuses any
;    text one of the three OS loaders would reject or drop, so the editor can
;    never write a layers.toml another machine reads differently.
; 2. Atomic write: the text is staged beside layers.toml, flushed, then moved
;    over it in one write-through rename; a refused save leaves it untouched.
; 3. The layer is registered once per process (nav_layer_table.ahk), so a saved
;    layer applies through the pause-preserving reload every setting uses.
; ==============================================================================

#Requires AutoHotkey v2.0

; The shared page's id in _shared/ui/apps.manifest.json.
global LAYER_EDITOR_APP_ID := "layer_editor"
global LAYER_EDITOR_OS := "windows"
; The largest layers.toml the editor accepts, in UTF-8 bytes; the Lua hosts'
; MAX_TEXT_BYTES (_shared/lua/keymap/layer_editor.lua), pinned by the suite.
global LAYER_EDITOR_MAX_TEXT_BYTES := 65536
; The error codes this host adds to the loader's.
global LAYER_EDITOR_INVALID_PAYLOAD := "invalid_payload"
global LAYER_EDITOR_WRITE_FAILED := "write_failed"
global LAYER_EDITOR_FILE_UNREADABLE := "file_unreadable"





; =============================
; =============================
; ======= 1/ Validation =======
; =============================
; =============================

; Loads a text on every OS and returns each distinct error once.
_LayerEditor_ErrorsOnEveryOs(Text, Ctx) {
	Errors := []
	Seen := Map()
	for Os in Ctx["platforms"] {
		for Err in KeymapLayers_Load(Os, Ctx, Text)["errors"] {
			Signature := KeymapLayers_ErrorSignature(Err)
			if Seen.Has(Signature)
				continue
			Seen[Signature] := true
			Errors.Push(Err)
		}
	}
	return Errors
}

_LayerEditor_Error(Code, Detail) {
	return Map("code", Code, "layer", "", "section", "", "key", "", "detail", Detail, "reason_key", "")
}

/**
 * Validates the text of a layer file the page asks to save.
 * @param {Any} Text - The payload's text.
 * @param {Map} Ctx - The loader context.
 * @returns {Array} What is wrong; empty when every OS loads it cleanly.
 */
LayerEditor_Validate(Text, Ctx) {
	global LAYER_EDITOR_MAX_TEXT_BYTES, LAYER_EDITOR_INVALID_PAYLOAD
	if !(Text is String)
		return [_LayerEditor_Error(LAYER_EDITOR_INVALID_PAYLOAD, "the save carries no layer file text")]
	Bytes := StrPut(Text, "UTF-8") - 1
	if (Bytes > LAYER_EDITOR_MAX_TEXT_BYTES)
		return [_LayerEditor_Error(LAYER_EDITOR_INVALID_PAYLOAD,
			"the layer file is " . Bytes . " bytes, more than " . LAYER_EDITOR_MAX_TEXT_BYTES)]
	return _LayerEditor_ErrorsOnEveryOs(Text, Ctx)
}

/**
 * Validates then atomically publishes the user's layers.toml.
 * @param {Any} Text - The payload's text.
 * @param {Map} Ctx - The loader context.
 * @param {string} ConfigDir - The configuration folder.
 * @returns {Map} saved (Boolean), path, errors (Array).
 */
LayerEditor_Save(Text, Ctx, ConfigDir) {
	global LAYER_EDITOR_WRITE_FAILED
	Path := KeymapLayers_UserFilePath(Ctx, ConfigDir)
	Errors := LayerEditor_Validate(Text, Ctx)
	if (Errors.Length > 0)
		return Map("saved", false, "path", Path, "errors", Errors)
	Stage := Path . ".tmp"
	if !FSWriteDurable(Stage, Text) {
		try FSDeleteStrict(Stage)
		return Map("saved", false, "path", Path, "errors",
			[_LayerEditor_Error(LAYER_EDITOR_WRITE_FAILED, "'" . Stage . "' could not be written")])
	}
	if !FSAtomicMoveReplace(Stage, Path) {
		try FSDeleteStrict(Stage)
		return Map("saved", false, "path", Path, "errors",
			[_LayerEditor_Error(LAYER_EDITOR_WRITE_FAILED, "'" . Path . "' could not be replaced")])
	}
	return Map("saved", true, "path", Path, "errors", [])
}





; =======================================
; =======================================
; ======= 2/ Messages to the page =======
; =======================================
; =======================================

; One error Map as a JSON object.
_LayerEditor_ErrorJson(Err) {
	Parts := []
	for Field in ["code", "layer", "section", "key", "detail", "reason_key"] {
		if Err.Has(Field) && Err[Field] != ""
			Parts.Push(JsonStringLiteral(Field) . ":" . JsonStringLiteral(String(Err[Field])))
	}
	Out := "{"
	for Index, Part in Parts
		Out .= (Index == 1 ? "" : ",") . Part
	return Out . "}"
}

_LayerEditor_ErrorsJson(Errors) {
	Out := "["
	for Index, Err in Errors
		Out .= (Index == 1 ? "" : ",") . _LayerEditor_ErrorJson(Err)
	return Out . "]"
}

/**
 * The page's init() call: the OS, the file's path and text, and every problem
 * any OS's loader finds in it.
 * @param {Map} Ctx - The loader context.
 * @param {string} ConfigDir - The configuration folder.
 * @returns {string} JavaScript to evaluate in the page.
 */
LayerEditor_InitJs(Ctx, ConfigDir) {
	global LAYER_EDITOR_OS, LAYER_EDITOR_FILE_UNREADABLE
	Path := KeymapLayers_UserFilePath(Ctx, ConfigDir)
	TextJson := "null"
	Errors := []
	if FileExist(Path) {
		try {
			Text := FSReadStrict(Path)
			TextJson := JsonStringLiteral(Text)
			Errors := _LayerEditor_ErrorsOnEveryOs(Text, Ctx)
		} catch as Err {
			Errors := [_LayerEditor_Error(LAYER_EDITOR_FILE_UNREADABLE, Err.Message)]
		}
	}
	return "if(window.init)window.init({"
		. '"os":' . JsonStringLiteral(LAYER_EDITOR_OS)
		. ',"path":' . JsonStringLiteral(Path)
		. ',"text":' . TextJson
		. ',"errors":' . _LayerEditor_ErrorsJson(Errors) . "})"
}

/**
 * The page's saveResult() call.
 * @param {Map} Result - From LayerEditor_Save, plus applied when it was saved.
 * @returns {string} JavaScript to evaluate in the page.
 */
LayerEditor_SaveResultJs(Result) {
	Applied := Result.Has("applied") ? (Result["applied"] ? "true" : "false") : "false"
	return "if(window.saveResult)window.saveResult({"
		. '"saved":' . (Result["saved"] ? "true" : "false")
		. ',"applied":' . Applied
		. ',"errors":' . _LayerEditor_ErrorsJson(Result["errors"]) . "})"
}





; =============================
; =============================
; ======= 3/ The window =======
; =============================
; =============================

/**
 * Opens the editor, or brings the open one to the front.
 * @returns {Boolean} Whether the window is shown.
 */
LayerEditor_Open(*) {
	global LAYER_EDITOR_APP_ID
	Host := WebViewHost.TryOpen(LAYER_EDITOR_APP_ID, Map(
		"Title", t("layer_editor.window_title"),
		"OnReady", _LayerEditor_OnReady,
		"OnMessage", _LayerEditor_OnMessage))
	if !Host {
		LoggerError("LayerEditor", "The layer editor could not open: WebView2 is unavailable.")
		return false
	}
	return true
}

_LayerEditor_OnReady(Host) {
	global _SharedDir, _ConfigDir
	try {
		Host.Eval(LayerEditor_InitJs(KeymapLayers_LoadContext(_SharedDir), _ConfigDir))
	} catch as Err {
		LoggerError("LayerEditor", "The layer data could not be read: {1}.", Err.Message)
	}
}

/**
 * Handles one message of the page.
 * @param {WebViewHost} Host - The window.
 * @param {Map} Payload - The parsed message.
 * @param {Func} ApplyFn - Applies a saved layer; the pause-preserving reload outside tests.
 */
_LayerEditor_OnMessage(Host, Payload, ApplyFn := ReloadPreservingSuspend) {
	global _SharedDir, _ConfigDir, JSON_NULL
	Action := Payload.Has("action") ? Payload["action"] : ""
	if (Action == "cancel") {
		Host.Close()
		return
	}
	if (Action != "save") {
		LoggerWarn("LayerEditor", "Ignored the unknown layer editor action '{1}'.",
			(Action is String) ? Action : Type(Action))
		return
	}
	Host.Eval(LayerEditor_SaveResultJs(LayerEditor_SaveAndApply(
		Payload.Has("text") ? Payload["text"] : JSON_NULL, _SharedDir, _ConfigDir, ApplyFn)))
}

/**
 * Saves a layer file the page sent, then applies it.
 * @param {Any} Text - The payload's text.
 * @param {string} SharedDir - The _shared folder.
 * @param {string} ConfigDir - The configuration folder.
 * @param {Func} ApplyFn - Applies the saved layer; returns false when refused.
 * @returns {Map} saved, path, errors and, once saved, applied.
 */
LayerEditor_SaveAndApply(Text, SharedDir, ConfigDir, ApplyFn) {
	global LAYER_EDITOR_WRITE_FAILED
	LoggerStart("LayerEditor", "Saving the navigation layer…")
	try {
		Ctx := KeymapLayers_LoadContext(SharedDir)
	} catch as Err {
		LoggerError("LayerEditor", "The navigation layer was not saved: {1}.", Err.Message)
		return Map("saved", false, "errors", [_LayerEditor_Error(LAYER_EDITOR_WRITE_FAILED, Err.Message)])
	}
	Result := LayerEditor_Save(Text, Ctx, ConfigDir)
	if !Result["saved"] {
		for Err in Result["errors"]
			LoggerWarn("LayerEditor", "Refused: {1} ({2}.{3}.{4}) — {5}.", Err["code"], Err["layer"],
				Err["section"], Err["key"], Err["detail"])
		LoggerError("LayerEditor", "The navigation layer was not saved to '{1}'.", Result["path"])
		return Result
	}
	LoggerSuccess("LayerEditor", "Navigation layer saved to '{1}'; reloading to apply it.", Result["path"])
	; A reload that goes through never returns here; a refused one says why in
	; its own log and leaves the saved file for the next start.
	Result["applied"] := ApplyFn.Call() ? true : false
	if !Result["applied"]
		LoggerError("LayerEditor", "The saved navigation layer is not applied: the reload was refused.")
	return Result
}
