; tests/support/receiving_profile.ahk

; ==============================================================================
; MODULE: Native Receiving Profile
; DESCRIPTION:
; The receiving scenarios of the recovery and flow audits (tests named
; "phys-w-receiving") run real Windows effects: folder renames refused by an
; ACL, transition journals, executable swaps, DPAPI, the Registry, the
; clipboard. tools/test/run-windows-receiving-scenarios.ps1 starts the runner
; with LOCALAPPDATA, APPDATA, USERPROFILE, TEMP and TMP inside one fresh temp
; profile; these helpers refuse to run a case anywhere else, so no scenario can
; reach the signed-in user's own folders.
; ==============================================================================

#Requires AutoHotkey v2.0

; The leaf the receiving runner gives its profile folder.
global RECEIVING_PROFILE_LEAF_PATTERN := "^ergopti-receiving-[0-9a-f]{32}$"
; The marker every receiving test name carries, which the runner selects.
global RECEIVING_TEST_SLUG := "phys-w-receiving"

; The isolated profile folder of this run; throws when the runner did not
; start this process inside one.
; @returns {String} Absolute profile folder, without a trailing backslash.
ReceivingProfileRoot() {
	global RECEIVING_PROFILE_LEAF_PATTERN
	Root := RTrim(EnvGet("ERGOPTI_RECEIVING_PROFILE"), "\")
	if (Root == "")
		throw Error("Receiving scenarios run only through tools/test/run-windows-receiving-scenarios.ps1.")
	SplitPath(Root, &Leaf)
	if !RegExMatch(Leaf, RECEIVING_PROFILE_LEAF_PATTERN) || !InStr(FileExist(Root), "D")
		throw Error("The receiving profile '" . Root . "' is not a folder the runner created.")
	Expected := Map("LOCALAPPDATA", Root . "\Local", "APPDATA", Root . "\Roaming",
		"USERPROFILE", Root . "\Home", "TEMP", Root . "\Temp", "TMP", Root . "\Temp")
	for Name, Path in Expected {
		if (RTrim(EnvGet(Name), "\") != Path)
			throw Error(Name . " is not inside the receiving profile: '" . EnvGet(Name) . "'.")
	}
	if (RTrim(A_Temp, "\") != Root . "\Temp")
		throw Error("A_Temp is not inside the receiving profile: '" . A_Temp . "'.")
	return Root
}

; A fresh empty folder below the profile's Temp folder.
; @param Label {String} Name part that says which case owns the folder.
; @returns {String} Absolute folder path.
ReceivingScratchDir(Label) {
	Root := ReceivingProfileRoot()
	Dir := Root . "\Temp\" . Label . "-" . DllCall("GetCurrentProcessId", "UInt") . "-" . A_TickCount
	if FileExist(Dir)
		throw Error("Receiving scratch folder already exists: " . Dir)
	DirCreate(Dir)
	return Dir
}

; Runs icacls on a folder of the receiving profile, never on anything else.
; @param Path {String} Folder below the receiving profile.
; @param Arguments {String} icacls arguments after the path.
ReceivingIcacls(Path, Arguments) {
	Root := ReceivingProfileRoot()
	if (SubStr(Path, 1, StrLen(Root) + 1) != Root . "\") || !InStr(FileExist(Path), "D")
		throw Error("icacls is refused outside the receiving profile: " . Path)
	ExitCode := RunWait('icacls "' . Path . '" ' . Arguments, , "Hide")
	if (ExitCode != 0)
		throw Error("icacls " . Arguments . " exited with " . ExitCode . " on " . Path)
}
