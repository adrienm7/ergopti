; infra/start_at_login.ahk
;
; ==============================================================================
; MODULE: Per-user Login Startup
; DESCRIPTION:
; Owns one exact Startup-folder command for the source script or installed build.
; Reads never create it, updates never restore it, and disabling refuses foreign
; shortcuts. Windows' separate Startup Apps approval stays under user control.
; ==============================================================================

; Source launch requires the interpreter and exactly one quoted script argument.
StartupLaunchCommand(LocalSource, ScriptPath, InterpreterPath) {
	if !(LocalSource is Integer) || (LocalSource != 0 && LocalSource != 1)
		throw ValueError("Startup launch mode must be Boolean")
	Script := _StartupExistingFilePath(ScriptPath)
	SplitPath(Script, , &Directory)
	Directory := _StartupDirectoryPath(Directory)
	if LocalSource {
		Target := _StartupExistingFilePath(InterpreterPath)
		Arguments := '"' . Script . '"'
	} else {
		Target := Script
		Arguments := ""
	}
	return Map("target", Target, "arguments", Arguments, "directory", Directory,
		"source", LocalSource, "script", Script)
}

; Returns whether the shortcut is ours, refusing another command's collision.
StartupShortcutOwned(Link, Target, Arguments := "", Directory := "") {
	if !FileExist(Link)
		return false
	FileGetShortcut(Link, &Actual, &ActualDirectory, &ActualArguments)
	if !(ActualArguments == Arguments) || _StartupExecutablePath(Actual) != _StartupExecutablePath(Target)
		throw Error("Startup shortcut belongs to a different command")
	if Directory != "" && _StartupDirectoryPath(ActualDirectory) != _StartupDirectoryPath(Directory)
		throw Error("Startup shortcut belongs to a different working directory")
	return true
}

; The Shell expands short names and dot segments when reading a shortcut.
; Resolve both existing files identically without accepting wildcard matches.
_StartupExecutablePath(Path) {
	if InStr(Path, "*") || InStr(Path, "?")
		throw Error("Startup executable path contains a wildcard")
	loop files Path, "F"
		return StrLower(A_LoopFileFullPath)
	throw Error("Startup executable cannot be resolved")
}

; Command paths must be absolute: a relative argument belongs to the shortcut's
; working directory, which may differ from the currently running driver's cwd.
_StartupIsAbsolutePath(Path) {
	return Path is String && RegExMatch(Path,
		"i)^(?:[a-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))") > 0
}

; Validation preserves actual launch spelling; case-folding is comparison only.
_StartupExistingFilePath(Path) {
	if !_StartupIsAbsolutePath(Path) || InStr(Path, "*") || InStr(Path, "?")
		throw Error("Startup command requires an absolute file path")
	loop files Path, "F"
		return A_LoopFileFullPath
	throw Error("Startup command file cannot be resolved")
}

; Source boot uses its script directory independently of interpreter placement.
_StartupDirectoryPath(Path) {
	return FSResolveDirectoryPath(Path)
}

; An unrelated shortcut can target an application that has since been removed.
; Such a link is foreign; never infer ownership from an interpreter name alone.
_StartupShortcutTargetMatches(Actual, Expected) {
	if !_StartupIsAbsolutePath(Actual) || InStr(Actual, "*") || InStr(Actual, "?")
		return false
	Attributes := FileExist(Actual)
	if !Attributes || InStr(Attributes, "D")
		return false
	return _StartupExecutablePath(Actual) == StrLower(Expected)
}

; Interpret exactly one script argument without accepting flags or another file.
; Windows path spelling is normalized only after the argument shape is proven.
_StartupScriptArgumentMatches(Arguments, Script) {
	if RegExMatch(Arguments, '^"([^"]+)"$', &Quoted)
		Path := Quoted[1]
	else if RegExMatch(Arguments, '^[^\s"]+$')
		Path := Arguments
	else
		return false
	return _StartupShortcutTargetMatches(Path, Script)
}

; Manual source links may launch the script through its file association.
; Retain their exact filename and command instead of replacing them.
_StartupShortcutReceipt(Link, Command) {
	FileGetShortcut(Link, &Target, &Directory, &Arguments)
	if Command["source"] {
		Matches := _StartupShortcutTargetMatches(Target, Command["target"])
			&& _StartupScriptArgumentMatches(Arguments, Command["script"])
		if !Matches && Arguments == ""
			Matches := _StartupShortcutTargetMatches(Target, Command["script"])
	} else {
		Matches := Arguments == ""
			&& _StartupShortcutTargetMatches(Target, Command["target"])
	}
	if !Matches
		return false
	SplitPath(Link, &Name)
	return Map("link", Link, "name", Name, "target", _StartupExistingFilePath(Target),
		"arguments", Arguments, "directory", Directory)
}

; Complete enumeration refuses access failures. Foreign commands are not owned,
; including foreign canonical names alongside a valid manual startup command.
StartupOwnedShortcuts(Folder, Command) {
	Owned := []
	for Link in FSListDirectoryStrict(Folder) {
		SplitPath(Link, &Name, , &Extension)
		if Extension != "lnk"
			continue
		Receipt := _StartupShortcutReceipt(Link, Command)
		if IsObject(Receipt)
			Owned.Push(Receipt)
	}
	return Owned
}

; The OS approval key is the actual shortcut filename, including manual names.
_StartupReadApproval(Name) {
	return RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder",
		Name, "")
}

StartupFolderEnabled(Folder, Command, ApprovalFn := _StartupReadApproval) {
	Enabled := false
	for Receipt in StartupOwnedShortcuts(Folder, Command)
		if StartupApprovalEnabled(ApprovalFn.Call(Receipt["name"]))
			Enabled := true
	return Enabled
}

; Enabling does not duplicate manual links. Disabling checks each acquired
; command again before removing it, then verifies that no owned links remain.
SetStartupFolder(Enabled, Folder, Command) {
	Owned := StartupOwnedShortcuts(Folder, Command)
	if Enabled {
		if Owned.Length
			return true
		return SetStartupShortcut(true, Folder . "\ErgoptiPlus.lnk", Command["target"],
			Command["arguments"], Command["directory"])
	}
	for Receipt in Owned {
		if !IsObject(_StartupShortcutReceipt(Receipt["link"], Command))
			throw Error("Startup shortcut command changed before removal")
		if !SetStartupShortcut(false, Receipt["link"], Receipt["target"],
				Receipt["arguments"])
			throw Error("Startup shortcut removal was not confirmed")
	}
	return StartupOwnedShortcuts(Folder, Command).Length == 0
}

; Windows may suppress a valid shortcut in Settings > Apps > Startup. Unknown
; binary states are not guessed and this code never writes StartupApproved.
StartupApprovalEnabled(Value) {
	if Value == ""
		return true
	if !(Value is String) || !RegExMatch(Value, "i)^[0-9a-f]{24}$")
		throw Error("Invalid startup approval state")
	State := SubStr(Value, 1, 2)
	if State == "02" || State == "06"
		return true
	if State == "03" || State == "07"
		return false
	throw Error("Unknown startup approval state")
}

; Reads the effective state without changing the Startup folder or registry.
StartAtLoginEnabled(*) {
	try {
		Command := StartupLaunchCommand(Updater_IsLocalSource(), A_ScriptFullPath, A_AhkPath)
		return StartupFolderEnabled(A_Startup, Command)
	} catch as Err {
		LoggerError("Startup", "Startup state could not be read: {1}.", Err.Message)
		return false
	}
}

; Creates/removes only an exact owned shortcut. Injectable paths keep tests away
; from the real Startup folder, and a failure never becomes a successful toggle.
SetStartupShortcut(Enabled, Link, Target, Arguments := "", Directory := "") {
	Owned := StartupShortcutOwned(Link, Target, Arguments, Directory)
	if Enabled {
		Target := _StartupExistingFilePath(Target)
		if Directory == ""
			SplitPath(Target, , &Directory)
		Directory := _StartupDirectoryPath(Directory)
		if !Owned
			FileCreateShortcut(Target, Link, Directory, Arguments, "Ergopti login startup")
		return StartupShortcutOwned(Link, Target, Arguments, Directory)
	}
	if Owned && !FSDelete(Link)
		throw Error("Startup shortcut removal failed")
	return !FileExist(Link)
}

; Menu mutation only: changing future login startup never exits the live driver.
ToggleStartAtLogin(*) {
	try {
		Command := StartupLaunchCommand(Updater_IsLocalSource(), A_ScriptFullPath, A_AhkPath)
		Enabled := StartAtLoginEnabled()
		if !Enabled {
			if !SetStartupFolder(true, A_Startup, Command)
				throw Error("Startup shortcut creation was not confirmed")
			if !StartupFolderEnabled(A_Startup, Command) {
				Run("ms-settings:startupapps")
				throw Error("Windows Startup Apps requires user approval")
			}
		}
		if !SetStartupFolder(!Enabled, A_Startup, Command)
			throw Error("Startup shortcut change was not confirmed")
		if StartAtLoginEnabled() != !Enabled
			throw Error("Windows did not confirm the requested startup state")
		RebuildTrayMenu()
		return true
	} catch as Err {
		LoggerError("Startup", "Startup setting could not be changed: {1}.", Err.Message)
		Ui_MsgBox(t("dialog.start_at_login.failed"), t("menu.global.start_at_login"), "Icon!")
		return false
	}
}
