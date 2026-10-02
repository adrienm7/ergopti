; infra/start_at_login.ahk
;
; ==============================================================================
; MODULE: Per-user Login Startup
; DESCRIPTION:
; Owns one Startup-folder shortcut. Reads never create it, updates never restore
; it, and disabling removes only the shortcut targeting this exact executable.
; Windows' separate Startup Apps approval remains under the user's control.
; ==============================================================================

; Returns whether the shortcut is ours, refusing another program's collision.
StartupShortcutOwned(Link, Target) {
	if !FileExist(Link)
		return false
	FileGetShortcut(Link, &Actual, , &Args)
	if Args != "" || _StartupExecutablePath(Actual) != _StartupExecutablePath(Target)
		throw Error("Startup shortcut belongs to a different command")
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
	if Updater_IsLocalSource()
		return false
	try {
		if !StartupShortcutOwned(A_Startup . "\ErgoptiPlus.lnk", A_ScriptFullPath)
			return false
		Value := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder",
			"ErgoptiPlus.lnk", "")
		return StartupApprovalEnabled(Value)
	} catch as Err {
		LoggerError("Startup", "Startup state could not be read: {1}.", Err.Message)
		return false
	}
}

; Creates/removes only an exact owned shortcut. Injectable paths keep tests away
; from the real Startup folder, and a failure never becomes a successful toggle.
SetStartupShortcut(Enabled, Link, Target) {
	Owned := StartupShortcutOwned(Link, Target)
	if Enabled {
		if !FileExist(Target)
			throw Error("Startup executable is missing")
		if !Owned {
			SplitPath(Target, , &Directory)
			FileCreateShortcut(Target, Link, Directory, "", "Ergopti login startup")
		}
		return StartupShortcutOwned(Link, Target)
	}
	if Owned && !FSDelete(Link)
		throw Error("Startup shortcut removal failed")
	return !FileExist(Link)
}

; Menu mutation only: changing future login startup never exits the live driver.
ToggleStartAtLogin(*) {
	try {
		if Updater_IsLocalSource()
			throw Error("Automatic startup requires the installed executable")
		Enabled := StartAtLoginEnabled()
		if !Enabled {
			if !SetStartupShortcut(true, A_Startup . "\ErgoptiPlus.lnk", A_ScriptFullPath)
				throw Error("Startup shortcut creation was not confirmed")
			Value := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder",
				"ErgoptiPlus.lnk", "")
			if !StartupApprovalEnabled(Value) {
				Run("ms-settings:startupapps")
				throw Error("Windows Startup Apps requires user approval")
			}
		}
		if !SetStartupShortcut(!Enabled, A_Startup . "\ErgoptiPlus.lnk", A_ScriptFullPath)
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
