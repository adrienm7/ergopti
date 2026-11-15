; platform/remap/nav_layer_save.ahk

; ==============================================================================
; MODULE: Navigation Layer Save
; DESCRIPTION:
; Saves and applies the user's layers.toml, the compiled form of the
; navigation layer the layout editor holds in a source: the text must load
; without an error on every OS (platform/remap/layers_loader.ahk), is
; published atomically, and the driver reloads so NavLayer_Init registers the
; edited layer. The macOS and Linux drivers implement the same contract
; through _shared/layouts/engine/layers/editor.lua.
;
; FEATURES & RATIONALE:
; 1. No window owns this save: the layout editor's « Apply the navigation
;    layer » (ui/layout_manager/init.ahk) calls NavLayerSave_SaveAndApply, so
;    the save outlives the navigation layer editor window it used to live in.
; 2. The save refuses any text one of the three OS loaders would reject or
;    drop, so it can never write a layers.toml another machine reads
;    differently.
; 3. Atomic write: the text is staged beside layers.toml, flushed, then moved
;    over it in one write-through rename; a refused save leaves it untouched.
; 4. A caller that read the file first (an opening source) passes it with the
;    callbacks that say whether it is still current; the file is then
;    replaced only while it still holds the bytes that caller read.
; ==============================================================================

#Requires AutoHotkey v2.0

; The largest layers.toml accepted is [limits] layer_file_bytes of the shared
; timing registry, read by NavLayerSave_Validate at call time (a global
; initializer runs before TimingsLoadShared) and by the Lua hosts.
; The error codes this save adds to the loader's.
global NAV_LAYER_SAVE_INVALID_PAYLOAD := "invalid_payload"
global NAV_LAYER_SAVE_WRITE_FAILED := "write_failed"
global NAV_LAYER_SAVE_FILE_UNREADABLE := "file_unreadable"

; Tap-hold key id (the ahk column of [tap_hold.catalog]) -> the registry code of
; that physical key. The Windows remap files name their keys by literal scan
; codes, so this is the one table that ties the two vocabularies;
; tools/test/test-layer-editor-legends.cjs holds it to the catalogue and, through
; the Linux engine's evdev codes, to the registry.
global NAV_LAYER_SAVE_TAP_HOLD_KEY_CODES := Map(
	"escape", "Escape", "tab", "Tab", "caps_lock", "CapsLock", "left_shift", "ShiftLeft",
	"left_ctrl", "ControlLeft", "win", "MetaLeft", "left_alt", "AltLeft", "space", "Space",
	"alt_gr", "AltRight", "right_ctrl", "ControlRight", "right_shift", "ShiftRight",
	"enter", "Enter", "backspace", "Backspace", "delete", "Delete"
)





; =============================
; =============================
; ======= 1/ Validation =======
; =============================
; =============================

; Loads a text on every OS and returns each distinct error once.
NavLayerSave_ErrorsOnEveryOs(Text, Ctx) {
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

NavLayerSave_Error(Code, Detail) {
	return Map("code", Code, "layer", "", "section", "", "key", "", "detail", Detail, "reason_key", "")
}

/**
 * Validates the text of a layer file before it is saved.
 * @param {Any} Text - The payload's text.
 * @param {Map} Ctx - The loader context.
 * @returns {Array} What is wrong; empty when every OS loads it cleanly.
 */
NavLayerSave_Validate(Text, Ctx) {
	global NAV_LAYER_SAVE_INVALID_PAYLOAD
	if !(Text is String)
		return [NavLayerSave_Error(NAV_LAYER_SAVE_INVALID_PAYLOAD, "the save carries no layer file text")]
	MaxBytes := TimingsGet("limits", "layer_file_bytes")
	Bytes := StrPut(Text, "UTF-8") - 1
	if (Bytes > MaxBytes)
		return [NavLayerSave_Error(NAV_LAYER_SAVE_INVALID_PAYLOAD,
			"the layer file is " . Bytes . " bytes, more than " . MaxBytes)]
	return NavLayerSave_ErrorsOnEveryOs(Text, Ctx)
}

/**
 * Validates then atomically publishes the user's layers.toml.
 * @param {Any} Text - The payload's text.
 * @param {Map} Ctx - The loader context.
 * @param {string} ConfigDir - The configuration folder.
 * @param {Object|Integer} Opening - The retained GUI source, or zero for an explicit write.
 * @param {Func|Integer} OpeningCurrent - Says whether Opening still owns its page, or zero.
 * @returns {Map} saved (Boolean), path, errors (Array).
 */
NavLayerSave_Save(Text, Ctx, ConfigDir, Opening := 0, OpeningCurrent := 0) {
	global FS_STATUS_OK, FS_STATUS_ABSENT
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return NavLayerSave_Save(Text, Ctx, ConfigDir, Opening, OpeningCurrent)
		finally Critical(InheritedCritical)
	}
	Path := KeymapLayers_UserFilePath(Ctx, ConfigDir)
	if A_IsSuspended
		return _NavLayerSave_Refused(Path, "the driver is suspended")
	Owner := _ConfigWriteLeaseTryAcquire(Path, "nav-layer-save")
	if !(Owner is Object)
		return _NavLayerSave_Refused(Path, "another configuration transaction owns publication")
	; This native guard closes admission even when pause arrives during loading,
	; validation or staging. Only the final rename uses a short Critical span.
	Admission := () => !A_IsSuspended && _ConfigWriteLeaseOwns(Owner, Path)
		&& (!(Opening is Object) || (OpeningCurrent.Call()
			&& _ConfigWriteLeaseKey(Path) == Opening.TargetKey
			&& _ConfigWriteLeaseKey(Opening.Path) == Opening.TargetKey))
	try {
		Errors := NavLayerSave_Validate(Text, Ctx)
		if (Errors.Length > 0)
			return Map("saved", false, "path", Path, "errors", Errors)
		if !Admission.Call()
			return _NavLayerSave_Refused(Path, "the configuration write is no longer admitted")
		if Opening is Object {
			Expected := Opening.Source
			if !Opening.Offered || (Expected["status"] != FS_STATUS_OK && Expected["status"] != FS_STATUS_ABSENT)
				return _NavLayerSave_Refused(Path, "the save has no admitted opening source")
			SourceAdmission := () => Admission.Call() && Opening.Source == Expected
			Result := FSWriteIfUnchangedAdmitted(Path, Text, Expected, 0, SourceAdmission)
			if !Result["committed"]
				return _NavLayerSave_Refused(Path, Result["detail"])
			PreviousCritical := Critical("On")
			try {
				if OpeningCurrent.Call() && Opening.Source == Expected
					Opening.Source := Map("status", FS_STATUS_OK, "content", Text, "detail", "")
			} finally Critical(PreviousCritical)
			return Map("saved", true, "path", Path, "errors", [])
		}
		Stage := Path . ".tmp"
		if !FSWriteDurable(Stage, Text) {
			try FSDeleteStrict(Stage)
			return _NavLayerSave_Refused(Path, "'" . Stage . "' could not be written")
		}
		if !FSConfigAtomicMoveReplace(Stage, Path, , Admission) {
			try FSDeleteStrict(Stage)
			return _NavLayerSave_Refused(Path, "'" . Path . "' could not be replaced")
		}
		return Map("saved", true, "path", Path, "errors", [])
	} finally _ConfigWriteLeaseRelease(Owner)
}

; Keep pre-publication refusal in the same envelope as native write failure.
_NavLayerSave_Refused(Path, Detail) {
	global NAV_LAYER_SAVE_WRITE_FAILED
	return Map("saved", false, "path", Path, "errors",
		[NavLayerSave_Error(NAV_LAYER_SAVE_WRITE_FAILED, Detail)])
}





; =================================
; =================================
; ======= 2/ Save and apply =======
; =================================
; =================================

/**
 * Saves a layer file, then applies it.
 * @param {Any} Text - The payload's text.
 * @param {string} SharedDir - The _shared folder.
 * @param {string} ConfigDir - The configuration folder.
 * @param {Func} ApplyFn - Applies the saved layer; returns false when refused.
 * @param {Object|Integer} Opening - The retained GUI source, or zero for an explicit write.
 * @param {Func|Integer} OpeningCurrent - Says whether Opening still owns its page, or zero.
 * @param {Func|Integer} SavedCurrent - SavedCurrent(Path, Text) says whether Opening
 *   still holds the saved text, or zero.
 * @returns {Map} saved, path, errors and, once saved, applied.
 */
NavLayerSave_SaveAndApply(Text, SharedDir, ConfigDir, ApplyFn, Opening := 0, OpeningCurrent := 0, SavedCurrent := 0) {
	global NAV_LAYER_SAVE_WRITE_FAILED
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return NavLayerSave_SaveAndApply(Text, SharedDir, ConfigDir, ApplyFn, Opening, OpeningCurrent,
			SavedCurrent)
		finally Critical(InheritedCritical)
	}
	if A_IsSuspended
		return _NavLayerSave_Refused("", "the driver is suspended")
	LoggerStart("NavLayerSave", "Saving the navigation layer…")
	if A_IsSuspended {
		LoggerError("NavLayerSave", "The navigation layer was not saved: {1}.", "the driver is suspended")
		return _NavLayerSave_Refused("", "the driver is suspended")
	}
	try {
		Ctx := KeymapLayers_LoadContext(SharedDir)
	} catch as Err {
		LoggerError("NavLayerSave", "The navigation layer was not saved: {1}.", Err.Message)
		return Map("saved", false, "errors", [NavLayerSave_Error(NAV_LAYER_SAVE_WRITE_FAILED, Err.Message)])
	}
	Result := NavLayerSave_Save(Text, Ctx, ConfigDir, Opening, OpeningCurrent)
	if !Result["saved"] {
		for Err in Result["errors"]
			LoggerWarn("NavLayerSave", "Refused: {1} ({2}.{3}.{4}) — {5}.", Err["code"], Err["layer"],
				Err["section"], Err["key"], Err["detail"])
		LoggerError("NavLayerSave", "The navigation layer was not saved to '{1}'.", Result["path"])
		return Result
	}
	LoggerSuccess("NavLayerSave", "Navigation layer saved to '{1}'; reloading to apply it.", Result["path"])
	; A reload that goes through never returns here; a refused one says why in
	; its own log and leaves the saved file for the next start.
	; The writer released its lease before Reload can acquire the terminal
	; barrier. A pause during the completion log keeps the durable save but
	; cannot authorize a fresh apply request. The exact GUI source also remains
	; necessary after a completion log retires its page or changes folders.
	; Never report that durable save as undone.
	Result["applied"] := !A_IsSuspended
		&& (!(Opening is Object) || SavedCurrent.Call(Result["path"], Text))
		&& ApplyFn.Call() ? true : false
	if !Result["applied"]
		LoggerError("NavLayerSave", "The saved navigation layer is not applied: the reload was refused.")
	return Result
}





; =================================
; =================================
; ======= 3/ Ergopti Studio =======
; =================================
; =================================

/**
 * The registry codes of the keys whose hold enters the navigation layer.
 * @param {Map} TapHoldSource - A tap-hold configuration (LoadTapHoldToml's shape).
 * @returns {Array} Codes in tap-hold id order.
 */
NavLayerSave_LayerKeys(TapHoldSource) {
	global NAV_LAYER_SAVE_TAP_HOLD_KEY_CODES, NAV_LAYER_ID
	Codes := []
	for Id, Code in NAV_LAYER_SAVE_TAP_HOLD_KEY_CODES {
		if (TapHoldHoldLayer(TapHoldSource, Id) == NAV_LAYER_ID)
			Codes.Push(Code)
	}
	return Codes
}

; The layer keys of the retained tap-hold configuration.
NavLayerSave_CurrentLayerKeys() {
	global TapHold
	return NavLayerSave_LayerKeys(MasterGateDesiredTapHold(IsSet(TapHold) ? TapHold : Map("keys", Map())))
}

/**
 * What Ergopti Studio shows for the « Navigation layer » entries: the user's
 * layers.toml, else the recommended one (an absent file binds no key today,
 * and the preset is where a layer starts), and the key whose hold enters the
 * layer.
 * @returns {Map} text (String) and hold (a registry code, or "" when no key enters it).
 */
NavLayerSave_StudioNav() {
	global _ConfigDir, _SharedDir, FS_STATUS_OK, FS_STATUS_ABSENT
	Ctx := KeymapLayers_LoadContext(_SharedDir)
	Path := KeymapLayers_UserFilePath(Ctx, _ConfigDir)
	Source := FSReadWithStatus(Path)
	if (Source["status"] == FS_STATUS_OK)
		Text := Source["content"]
	else if (Source["status"] == FS_STATUS_ABSENT)
		Text := TapHoldRecommendedLayer(_SharedDir)["text"]
	else
		throw Error("'" . Path . "' is unreadable: " . Source["detail"])
	Keys := NavLayerSave_CurrentLayerKeys()
	return Map("text", Text, "hold", Keys.Length ? Keys[1] : "")
}
