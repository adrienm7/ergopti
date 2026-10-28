; infra/dev_source.ahk

; ==============================================================================
; MODULE: Developer Source Mode (Windows)
; DESCRIPTION:
; Answers whether this process is a developer run of a repository clone
; (tools/dev/run-windows-dev.ps1, or ErgoptiPlus.ahk double-clicked in a
; clone), and, in that run only, reloads the driver when a saved .ahk of the
; clone settles, as the macOS developer app reloads on a saved .lua.
;
; FEATURES & RATIONALE:
; 1. Launcher authority: the developer launcher sets the variable named by
;    dev_source.environment in _shared/data/identifiers.json (the one the macOS
;    and Linux developer runs use). A compiled build ignores it: its includes
;    are embedded, so a source edit cannot reach it.
; 2. Exact match: the root must name the clone this script runs from. A root
;    naming another tree is an invalid state and raises.
; 3. Double-click: without the variable, a source run derives the root from
;    its own folder and accepts it only when that root is a Git checkout of this
;    repository (.git and the shared identifiers), so a double-clicked
;    ErgoptiPlus.ahk in a clone is the same developer run; a source tree outside
;    a clone stays a plain source run.
; 4. Poll, not ReadDirectoryChangesW: a one-second timer compares the modified
;    time and size of every driver .ahk. It runs only in a developer run and
;    needs no overlapped I/O or callback thread; a change reloads only after one
;    quiet tick, so an editor's multi-file save reloads once.
; 5. Same configuration: boot.ahk reads the installed build's paths.toml in a
;    developer run, not the clone's _generated copy, so the run sees the
;    configuration folder the user chose.
; 6. The tray's Reload path: the watcher calls ReloadPreservingSuspend, which
;    keeps a pause, retires workers and hands off to the successor exactly as
;    the menu row does.
; ==============================================================================

#Requires AutoHotkey v2.0

global DEV_SOURCE_POLL_MS := 1000
; The watcher's single owner: 0 until DevSourceWatcher_Start, then a Map.
global _DevSourceWatcher := 0





; ==================================
; ==================================
; ======= 1/ Mode Resolution =======
; ==================================
; ==================================

; The developer variable's name, read from the shared identifiers.
; @param SharedDir {String} The _shared folder.
; @returns {String}
DevSource_EnvironmentName(SharedDir) {
	Data := JsonParse(FileRead(SharedDir . "\data\identifiers.json", "UTF-8"))
	Name := Data["dev_source"]["environment"]
	if (Type(Name) != "String" || Name == "")
		throw Error("identifiers.json names no dev_source.environment")
	return Name
}

; The clone root of this process and where it came from, resolved once. Raises
; when the launcher's root does not name the running script, like the macOS and
; Linux runs.
; @returns {Map} "root": the clone root, "" for an ordinary run; "origin": the
;   DevSource_RootOrigin answer.
DevSource_Resolution() {
	static Resolved := 0
	if !(Resolved is Map) {
		IsLocalSource := Updater_IsLocalSource()
		EnvValue := IsLocalSource ? EnvGet(DevSource_EnvironmentName(_SharedDir)) : ""
		Root := DevSource_ResolveRoot(EnvValue, A_ScriptDir, IsLocalSource)
		Resolved := Map("root", Root, "origin", DevSource_RootOrigin(Root, EnvValue))
	}
	return Resolved
}

; The clone root of this process.
; @returns {String} The clone root, "" for an ordinary run.
DevSource_Root() {
	return DevSource_Resolution()["root"]
}

; Where an accepted root came from, for the startup log line.
; @param Root {String} DevSource_ResolveRoot's answer.
; @param EnvValue {String} The developer variable's value ("" when unset).
; @returns {String} "", "the developer variable" or "the script location".
DevSource_RootOrigin(Root, EnvValue) {
	if (Root == "")
		return ""
	return (EnvValue != "") ? "the developer variable" : "the script location"
}

; Whether this process reads the installed build's paths.toml: an installed
; build, or a developer run that must see the user's configuration folder.
; @returns {Boolean}
DevSource_UsesInstalledPaths() {
	return !Updater_IsLocalSource() || DevSource_Root() != ""
}

; Resolves the clone root of a developer run: the developer variable when set,
; otherwise the clone the script lies in (DevSource_DeriveRoot).
; @param EnvValue {String} The developer variable's value ("" when unset).
; @param ScriptDir {String} The running script's folder.
; @param IsLocalSource {Integer} Updater_IsLocalSource(), the one source-run owner.
; @returns {String} The clone root, "" for an ordinary run.
DevSource_ResolveRoot(EnvValue, ScriptDir, IsLocalSource) {
	if !IsLocalSource
		return ""
	if (EnvValue == "")
		return DevSource_DeriveRoot(ScriptDir)
	Root := StrReplace(EnvValue, "/", "\")
	if !RegExMatch(Root, "^(?:[A-Za-z]:\\|\\\\)") || SubStr(Root, -1) == "\"
		throw ValueError("The developer root is not a plain absolute clone path: " . EnvValue)
	; A literal, not a module global: boot.ahk resolves the root before this
	; include's globals would be assigned.
	Expected := Root . "\static\ergopti_plus\windows"
	if (StrLower(StrReplace(ScriptDir, "/", "\")) != StrLower(Expected))
		throw ValueError("The developer root names the clone " . Root
			. ", but this driver runs from " . ScriptDir)
	return Root
}

; The clone root a source run lies in, or "" when the script is not the Windows
; driver of a Git checkout of this repository.
; @param ScriptDir {String} The running script's folder.
; @returns {String} The clone root, "" for a source tree outside a clone.
DevSource_DeriveRoot(ScriptDir) {
	; A literal for the same reason as DevSource_ResolveRoot's Expected.
	if !RegExMatch(StrReplace(ScriptDir, "/", "\"), "i)^(.+)\\static\\ergopti_plus\\windows$", &Match)
		return ""
	Root := Match[1]
	; .git is a folder in a clone and a file in a linked worktree.
	if (FileExist(Root . "\.git") == "")
		return ""
	; The repository's own tree, a file and not a folder of that name.
	Attributes := FileExist(Root . "\static\ergopti_plus\_shared\data\identifiers.json")
	if (Attributes == "" || InStr(Attributes, "D"))
		return ""
	return Root
}





; ======================================
; ======================================
; ======= 2/ Source Change Watch =======
; ======================================
; ======================================

; The modified time and size of every driver .ahk, without tests and generated files.
; @param DriverDir {String} The driver folder.
; @returns {Map} Path to "time|size".
DevSource_Snapshot(DriverDir) {
	Snapshot := Map()
	; A_LoopFilePath keeps DriverDir exactly as given; A_LoopFileFullPath expands
	; an 8.3 short folder (a runner's RUNNER~1 temp), which broke the prefix cut.
	Loop Files DriverDir . "\*.ahk", "FR" {
		Relative := SubStr(A_LoopFilePath, StrLen(DriverDir) + 2)
		if RegExMatch(Relative, "i)^(?:tests|_generated)\\")
			continue
		Snapshot[A_LoopFilePath] := A_LoopFileTimeModified . "|" . A_LoopFileSize
	}
	return Snapshot
}

; The first path that was added, removed or changed between two snapshots.
; @param Old {Map}
; @param New {Map}
; @returns {String} The changed path, "" when nothing changed.
DevSource_SnapshotChange(Old, New) {
	for Path, Stamp in New {
		if (!Old.Has(Path) || Old[Path] != Stamp)
			return Path
	}
	for Path in Old {
		if !New.Has(Path)
			return Path
	}
	return ""
}

; Starts the developer watcher. Raises when it already runs.
; @param DriverDir {String} The driver folder.
; @param ReloadFn {Func} Called once a change settles; ReloadPreservingSuspend in production.
; @param ArmFn {Func} Test seam for SetTimer.
DevSourceWatcher_Start(DriverDir, ReloadFn, ArmFn := SetTimer) {
	global _DevSourceWatcher
	if (_DevSourceWatcher is Map)
		throw Error("The developer source watcher is already running")
	_DevSourceWatcher := Map("dir", DriverDir, "snapshot", DevSource_Snapshot(DriverDir),
		"pending", "", "reload", ReloadFn, "arm", ArmFn)
	ArmFn(_DevSourceWatcherTick, DEV_SOURCE_POLL_MS)
	LoggerInfo("DevSource", "Developer source watcher started on {1} ({2} file(s)).",
		DriverDir, _DevSourceWatcher["snapshot"].Count)
}

; Stops the developer watcher; a no-op when it does not run.
DevSourceWatcher_Stop() {
	global _DevSourceWatcher
	if !(_DevSourceWatcher is Map)
		return
	_DevSourceWatcher["arm"](_DevSourceWatcherTick, 0)
	_DevSourceWatcher := 0
	LoggerInfo("DevSource", "Developer source watcher stopped.")
}

; One poll: a change arms the reload, the next quiet poll performs it.
_DevSourceWatcherTick() {
	global _DevSourceWatcher
	if !(_DevSourceWatcher is Map)
		return
	Snapshot := DevSource_Snapshot(_DevSourceWatcher["dir"])
	Changed := DevSource_SnapshotChange(_DevSourceWatcher["snapshot"], Snapshot)
	_DevSourceWatcher["snapshot"] := Snapshot
	if (Changed != "") {
		_DevSourceWatcher["pending"] := Changed
		return
	}
	Pending := _DevSourceWatcher["pending"]
	if (Pending == "")
		return
	_DevSourceWatcher["pending"] := ""
	LoggerInfo("DevSource", "Saved source {1} settled; reloading the driver.", Pending)
	_DevSourceWatcher["reload"]()
}
