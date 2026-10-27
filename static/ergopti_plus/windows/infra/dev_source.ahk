; infra/dev_source.ahk

; ==============================================================================
; MODULE: Developer Source Mode (Windows)
; DESCRIPTION:
; Answers whether this process is a developer run of a repository clone
; (tools/dev/run-windows-dev.ps1), and, in that run only, reloads the driver
; when a saved .ahk of the clone settles, as the macOS developer app reloads
; on a saved .lua.
;
; FEATURES & RATIONALE:
; 1. Launcher authority: only the developer launcher sets the variable named by
;    dev_source.environment in _shared/data/identifiers.json (the one the macOS
;    and Linux developer runs use). A compiled build ignores it: its includes
;    are embedded, so a source edit cannot reach it.
; 2. Exact match: the root must name the clone this script runs from. A root
;    naming another tree is an invalid state and raises.
; 3. Poll, not ReadDirectoryChangesW: a one-second timer compares the modified
;    time and size of every driver .ahk. It runs only in a developer run and
;    needs no overlapped I/O or callback thread; a change reloads only after one
;    quiet tick, so an editor's multi-file save reloads once.
; 4. Same configuration: boot.ahk reads the installed build's paths.toml in a
;    developer run, not the clone's _generated copy, so the run sees the
;    configuration folder the user chose.
; 5. The tray's Reload path: the watcher calls ReloadPreservingSuspend, which
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

; The clone root of this process, resolved once. Raises when the launcher's
; root does not name the running script, like the macOS and Linux runs.
; @returns {String} The clone root, "" for an ordinary run.
DevSource_Root() {
	static Resolved := 0
	if !(Resolved is Map) {
		Root := Updater_IsLocalSource() ? DevSource_ResolveRoot(
			EnvGet(DevSource_EnvironmentName(_SharedDir)), A_ScriptDir, true) : ""
		Resolved := Map("root", Root)
	}
	return Resolved["root"]
}

; Whether this process reads the installed build's paths.toml: an installed
; build, or a developer run that must see the user's configuration folder.
; @returns {Boolean}
DevSource_UsesInstalledPaths() {
	return !Updater_IsLocalSource() || DevSource_Root() != ""
}

; Resolves the clone root of a developer run.
; @param EnvValue {String} The developer variable's value ("" when unset).
; @param ScriptDir {String} The running script's folder.
; @param IsLocalSource {Integer} Updater_IsLocalSource(), the one source-run owner.
; @returns {String} The clone root, "" for an ordinary run.
DevSource_ResolveRoot(EnvValue, ScriptDir, IsLocalSource) {
	if (EnvValue == "" || !IsLocalSource)
		return ""
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
	Loop Files DriverDir . "\*.ahk", "FR" {
		Relative := SubStr(A_LoopFileFullPath, StrLen(DriverDir) + 2)
		if RegExMatch(Relative, "i)^(?:tests|_generated)\\")
			continue
		Snapshot[A_LoopFileFullPath] := A_LoopFileTimeModified . "|" . A_LoopFileSize
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
