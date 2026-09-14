; adapters/webview_profiles.ahk

; ==============================================================================
; MODULE: WebView Profile Ownership
; DESCRIPTION: Retire private browser profiles only after confirmed process-tree exit.
; ==============================================================================

#Requires AutoHotkey v2.0

global _WebView_ProfileOwners := Map()

WebView_NewProfilePath(Prefix) {
	global _WebView_ProfileOwners
	if !RegExMatch(Prefix, "^ergopti_[a-z0-9_]+_$")
		throw ValueError("Invalid private browser profile prefix.")
	Guid := Buffer(16)
	if DllCall("ole32\CoCreateGuid", "Ptr", Guid, "Int") != 0
		throw Error("Cannot allocate a private browser profile identity.")
	Text := Buffer(78)
	if !DllCall("ole32\StringFromGUID2", "Ptr", Guid, "Ptr", Text, "Int", 39)
		throw Error("Cannot encode a private browser profile identity.")
	Path := A_Temp . "\" . Prefix . DllCall("GetCurrentProcessId") . "_" . Trim(StrGet(Text), "{}")
	if FileExist(Path) || FileExist(Path . ".retired")
		throw Error("Private browser profile destination already exists.")
	_WebView_ProfileOwners[Path] := Map("path", Path, "exited", false, "retired", false,
		"subscription", 0, "pid", 0, "attempts", 0, "queued", false)
	return Path
}

WebView_WatchProfile(Path, Core) {
	global _WebView_ProfileOwners
	Owner := _WebView_ProfileOwners[Path]
	if Owner["pid"] || Owner["exited"] || Owner["retired"]
		throw Error("Private browser profile observation is already initialized.")
	Owner["pid"] := Core.BrowserProcessId
	if !IsInteger(Owner["pid"]) || Owner["pid"] < 1 || Owner["pid"] > 0xFFFFFFFF
		throw ValueError("Private browser profile requires a valid browser identity.")
	; Vendor subscription tokens borrow the COM pointer; keep its environment alive.
	Owner["environment"] := Core.Environment
	Owner["subscription"] := Owner["environment"].BrowserProcessExited(_WebView_ProfileExited.Bind(Owner))
}

; Failed browser creation may have started native processes without returning a
; controller. Release bookkeeping but preserve the unproven on-disk profile.
WebView_AbandonProfile(Path) {
	global _WebView_ProfileOwners
	if !_WebView_ProfileOwners.Has(Path)
		return false
	Owner := _WebView_ProfileOwners[Path]
	if Owner["exited"] || IsObject(Owner["subscription"])
		return WebView_RetireProfile(Path)
	_WebView_ProfileOwners.Delete(Path)
	try LoggerWarn("WebView", "Unconfirmed browser profile was retained after failed initialization.")
	return true
}

_WebView_ProfileExited(Owner, Sender, Args) {
	if Args.BrowserProcessId != Owner["pid"]
		return
	Owner["exited"] := true
	if Owner["retired"]
		_WebView_QueueProfileCleanup(Owner)
}

WebView_RetireProfile(Path) {
	global _WebView_ProfileOwners
	if !_WebView_ProfileOwners.Has(Path)
		return false
	Owner := _WebView_ProfileOwners[Path]
	Owner["retired"] := true
	if Owner["exited"]
		_WebView_QueueProfileCleanup(Owner)
	return true
}

; Edge's owned-job terminal callback is emitted only after ActiveProcesses=0.
WebView_ConfirmProfileExit(Path) {
	global _WebView_ProfileOwners
	if !_WebView_ProfileOwners.Has(Path)
		return false
	Owner := _WebView_ProfileOwners[Path]
	Owner["exited"] := true
	return WebView_RetireProfile(Path)
}

_WebView_QueueProfileCleanup(Owner) {
	if Owner["queued"] || Owner.Get("cleaning", false)
		return
	Owner["queued"] := true
	try SetTimer(_WebView_CleanupProfile.Bind(Owner), -1)
	catch as Err {
		Owner["queued"] := false
		throw Err
	}
}

_WebView_CleanupProfile(Owner) {
	global _WebView_ProfileOwners
	Owner["queued"] := false
	Path := Owner["path"]
	if !Owner["exited"] || !Owner["retired"] || _WebView_ProfileOwners.Get(Path, 0) !== Owner
		return
	if Owner.Get("cleaning", false)
		return
	Owner["cleaning"] := true
	try _WebView_CleanupProfileAttempt(Owner)
	finally
		Owner["cleaning"] := false
}

_WebView_CleanupProfileAttempt(Owner) {
	global _WebView_ProfileOwners
	Path := Owner["path"]
	; Release the subscription outside its COM callback, after exit was observed.
	try {
		Owner["subscription"] := 0
		if Owner.Has("environment")
			Owner.Delete("environment")
		if !FileExist(Path . ".retired")
			FileAppend("ergopti-profile-retired-v1", Path . ".retired", "UTF-8-RAW")
		_WebView_DeleteRetiredProfile(Path)
		_WebView_ProfileOwners.Delete(Path)
	} catch {
		Owner["attempts"] += 1
		if Owner["attempts"] < 4 {
			Owner["queued"] := true
			SetTimer(_WebView_CleanupProfile.Bind(Owner), -1000)
		} else {
			_WebView_ProfileOwners.Delete(Path)
			try LoggerWarn("WebView", "Private browser profile cleanup failed after retries.")
		}
	}
}

_WebView_DeleteRetiredProfile(Path) {
	if FileRead(Path . ".retired", "UTF-8") != "ergopti-profile-retired-v1"
		throw Error("Private browser profile retirement receipt is invalid.")
	if InStr(FileExist(Path), "L")
		throw Error("Private browser profile must not be a reparse point.")
	if DirExist(Path)
		DirDelete(Path, true)
	FileDelete(Path . ".retired")
}

WebView_SweepStaleProfiles(Prefix) {
	global _WebView_ProfileOwners
	if !RegExMatch(Prefix, "^ergopti_[a-z0-9_]+_$")
		throw ValueError("Invalid private browser profile prefix.")
	; A prefix, age or file lock cannot prove a browser has exited. Only a receipt
	; published after exact termination authorizes recovery of a failed cleanup.
	Loop Files A_Temp . "\" . Prefix . "*.retired", "F" {
		if InStr(A_LoopFileAttrib, "L")
			continue
		Suffix := SubStr(A_LoopFileName, StrLen(Prefix) + 1)
		if !RegExMatch(Suffix, "^([1-9]\d{0,9})_[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\.retired$", &Match)
			continue
		if Integer(Match[1]) > 0xFFFFFFFF
			continue
		Path := SubStr(A_LoopFileFullPath, 1, -8)
		if _WebView_ProfileOwners.Has(Path)
			continue
		try _WebView_DeleteRetiredProfile(Path)
		catch
			try LoggerWarn("WebView", "Retired browser profile cleanup remains pending.")
	}
}
