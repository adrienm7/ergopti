; infra/start_at_login.ahk
;
; ==============================================================================
; MODULE: Per-user Login Startup
; DESCRIPTION:
; Owns one exact Startup-folder command for the source script or installed build.
; Reads never create it, updates never restore it, and disabling refuses foreign
; shortcuts. Windows' separate Startup Apps approval stays under user control.
; An isolated profile (a startup smoke or a live check) never reaches the user's
; Startup folder: APPDATA is not redirected for it, so its toggle would add or
; remove the real login shortcut. It uses its profile's private folder instead.
; ==============================================================================

#Include %A_LineFile%\..\..\_generated\identifiers.ahk

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

; Both source ownership and compiled conflict observation use this one grammar.
; Extract one argument; the caller still proves its existing absolute file identity.
_StartupScriptArgumentPath(Arguments) {
	if RegExMatch(Arguments, '^"([^"]+)"$', &Quoted)
		return Quoted[1]
	if RegExMatch(Arguments, '^[^\s"]+$')
		return Arguments
	return ""
}

; Interpret exactly one script argument without accepting flags or another file.
; Windows path spelling is normalized only after the argument shape is proven.
_StartupScriptArgumentMatches(Arguments, Script) {
	Path := _StartupScriptArgumentPath(Arguments)
	return Path != "" && _StartupShortcutTargetMatches(Path, Script)
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


; Observation only: source structure and its canonical repository/version siblings
; identify a different startup command. This never grants deletion or migration.
; @param Script {String} Absolute script path from an exact native shortcut.
; @param ReadFn {Object} Bounded source reader; tests may supply inert file bytes.
; @returns {Boolean} Whether the existing source tree identifies this product.
_StartupOtherSourceIdentity(Script, ReadFn := FSReadBounded) {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	if !_StartupIsAbsolutePath(Script) || !FileExist(Script)
		return false
	SplitPath(Script, &Name, &Directory)
	if !(Name == Identifiers.App.AHK)
		return false
	; A fixed upper bound is a parser input limit, never an execution capability.
	Limit := 1048576
	Entry := ReadFn.Call(Script, Limit)
	Bundle := ReadFn.Call(Directory . "\core\lifecycle\engine\bundle.ahk", Limit)
	Defaults := ReadFn.Call(Directory . "\..\_shared\updater\data\defaults.json", Limit)
	if !(Entry is String) || !(Bundle is String) || !(Defaults is String)
		return false
	if !RegExMatch(Entry, "im)^#Requires\s+Autohotkey\s+v2\.0\+")
		|| !RegExMatch(Entry, "im)^#Include\s+infra/bundle\.ahk\s*$")
		|| !RegExMatch(Entry, "im)^#Include\s+modules/updater\.ahk\s*$")
		|| !RegExMatch(Bundle, 'm)^global BUNDLE_VERSION\s*:=\s*"__BUNDLE_VERSION__"\s*$')
		return false
	try Identity := JsonParse(Defaults)
	catch
		return false
	return Identity is Map && Identity.Has("github") && Identity["github"] is Map
		&& Identity["github"].Get("owner", "") == UPDATER_GH_OWNER
		&& Identity["github"].Get("repo", "") == UPDATER_GH_REPO
}

; A different enabled source command is a read-only conflict, never an owned link.
; Exact argument shape, source identity and actual shortcut approval all apply.
; @param Folder {String} Startup directory, injectable for private fixtures.
; @param Command {Map} Current command from the canonical launch constructor.
; @param ApprovalFn {Object} Existing native approval reader.
; @param ReadFn {Object} Bounded source reader.
; @returns {Boolean} Whether another enabled local-source command is configured.
StartupOtherSourceConfigured(Folder, Command, ApprovalFn := _StartupReadApproval, ReadFn := FSReadBounded) {
	if Command["source"]
		return false
	for Link in FSListDirectoryStrict(Folder) {
		SplitPath(Link, &Name, , &Extension)
		if Extension != "lnk"
			continue
		if IsObject(_StartupShortcutReceipt(Link, Command))
			continue
		FileGetShortcut(Link, &Target, , &Arguments)
		if Arguments == ""
			Script := Target
		else {
			Script := _StartupScriptArgumentPath(Arguments)
			if Script == ""
				continue
		}
		if !_StartupOtherSourceIdentity(Script, ReadFn)
			continue
		Other := StartupLaunchCommand(true, Script, Target)
		Receipt := _StartupShortcutReceipt(Link, Other)
		if IsObject(Receipt) && StartupApprovalEnabled(ApprovalFn.Call(Receipt["name"]))
			return true
	}
	return false
}

; The folder that stands for the user's Startup folder in an isolated profile,
; or "" for a real one. ERGOPTI_STARTUP_SMOKE_DIR already moves the paths, logs
; and configuration of a startup smoke or a live check into its scratch folder
; (core/lifecycle/engine/boot.ahk); the login shortcut follows, so the harness can read it there.
; @returns {String} Absolute path, or "" when the driver owns the real profile.
StartAtLoginPrivateFolder() {
	global _DriverStartupSmokeDir
	if !IsSet(_DriverStartupSmokeDir) || _DriverStartupSmokeDir == ""
		return ""
	return _DriverStartupSmokeDir . "\startup_private"
}

; Windows' Startup Apps approval governs the real Startup folder only: a private
; folder has none, so its state is its shortcut alone.
; @returns {String} The approval of a shortcut nothing has disabled.
_StartupPrivateApproval(*) {
	return ""
}

; Replaces the Startup folder and approval reader of an isolated profile with
; its private ones. A caller's own ports are replaced too: both name the user's
; machine state, which an isolated driver must never reach.
; @param Ports {Object} Folder (A_Startup) and Approval (_StartupReadApproval).
; @param Announce {Boolean} Creates the private folder and logs which
;   folder the writes of this call reach.
; @returns {Object} The ports to use, the given ones for a real profile.
_StartAtLoginIsolate(Ports, Announce := false) {
	if !(Ports.HasOwnProp("Folder") && Ports.HasOwnProp("Approval"))
		throw ValueError("Login startup ports are Folder and Approval")
	Folder := StartAtLoginPrivateFolder()
	if (Folder == "")
		return Ports
	if Announce {
		FSEnsureDirectoryStrict(Folder)
		LoggerInfo("Startup",
			"Isolated profile: the login startup shortcut goes to the private folder '{1}', never to the user's Startup folder.",
			Folder)
	}
	return {Folder: Folder, Approval: _StartupPrivateApproval}
}

; Reads conflict state without transferring shortcut ownership.
StartAtLoginCommandAvailable(*) {
	Command := StartupLaunchCommand(Updater_IsLocalSource(), A_ScriptFullPath, A_AhkPath)
	Startup := _StartAtLoginIsolate({Folder: A_Startup, Approval: _StartupReadApproval})
	return !StartupOtherSourceConfigured(Startup.Folder, Command, Startup.Approval)
}

; Reads the effective state without changing the Startup folder or registry.
StartAtLoginEnabled(*) {
	try {
		Command := StartupLaunchCommand(Updater_IsLocalSource(), A_ScriptFullPath, A_AhkPath)
		Startup := _StartAtLoginIsolate({Folder: A_Startup, Approval: _StartupReadApproval})
		return StartupFolderEnabled(Startup.Folder, Command, Startup.Approval)
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
	return StartAtLoginToggle()
}

; The toggle itself; the seams keep a test off the tray menu and modal dialogs.
; @param RebuildFn {Object} Tray menu rebuild, called once the state changed.
; @param NoticeFn {Object} Failure dialog, fn(Text, Title, Options).
; @returns {Boolean} Whether the requested state is confirmed.
StartAtLoginToggle(RebuildFn := RebuildTrayMenu, NoticeFn := Ui_MsgBox) {
	try {
		Command := StartupLaunchCommand(Updater_IsLocalSource(), A_ScriptFullPath, A_AhkPath)
		Startup := _StartAtLoginIsolate({Folder: A_Startup, Approval: _StartupReadApproval}, true)
		if StartupOtherSourceConfigured(Startup.Folder, Command, Startup.Approval)
			throw Error("Another startup command is configured")
		Enabled := StartAtLoginEnabled()
		if !Enabled {
			if !SetStartupFolder(true, Startup.Folder, Command)
				throw Error("Startup shortcut creation was not confirmed")
			if !StartupFolderEnabled(Startup.Folder, Command, Startup.Approval) {
				Run("ms-settings:startupapps")
				throw StartupApprovalPending("Windows Startup Apps requires user approval")
			}
		}
		if !SetStartupFolder(!Enabled, Startup.Folder, Command)
			throw Error("Startup shortcut change was not confirmed")
		if StartAtLoginEnabled() != !Enabled
			throw Error("Windows did not confirm the requested startup state")
		RebuildFn.Call()
		return true
	} catch as Err {
		_StartAtLoginReportFailure(Err, NoticeFn)
		return false
	}
}

; Startup Apps keeps the new shortcut disabled until the user allows it in the
; settings page the toggle just opened: that is a step for the user, not a failure.
class StartupApprovalPending extends Error {
}

; Tells why the toggle did not confirm the state: the approval to give in the
; opened Startup Apps page (informational, as macOS), else the failure (SAW-001).
; @param Err {Error} What stopped the toggle.
; @param NoticeFn {Object} Dialog, fn(Text, Title, Options).
_StartAtLoginReportFailure(Err, NoticeFn) {
	if Err is StartupApprovalPending {
		LoggerInfo("Startup", "Startup waits for the user's approval in Startup Apps.")
		NoticeFn.Call(t("dialog.start_at_login.approval"), t("menu.global.start_at_login"), "Iconi")
		return
	}
	LoggerError("Startup", "Startup setting could not be changed: {1}.", Err.Message)
	NoticeFn.Call(t("dialog.start_at_login.failed"), t("menu.global.start_at_login"), "Icon!")
}
