; core/lifecycle/engine/dev_source.ahk

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
;    dev_source.environment in _shared/core/text/data/identifiers.json (the one the macOS
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
; 5. Whole-tree settle: a burst of more than dev_source_bulk_threshold distinct
;    files (a pull, a checkout, a sync) waits dev_source_bulk_settle_ms of quiet
;    across the whole tree, and no reload starts while Git rewrites the tree
;    (index.lock, a merge, cherry-pick, revert or rebase marker in the gitdir).
;    A fast-forward that moved 651 files once reloaded on the first file that
;    settled, and the successor booted from a half-updated tree. The policy is
;    the macOS and Linux one (_shared/core/lifecycle/engine/reload/gate.lua),
;    pinned by tools/test/test-reload-gate-single-source.cjs. The hold never
;    expires: it is the safe side, and a stale index.lock is reported.
; 6. Same configuration: boot.ahk reads the installed build's paths.toml in a
;    developer run, not the clone's _generated copy, so the run sees the
;    configuration folder the user chose.
; 7. The tray's Reload path: the watcher calls ReloadPreservingSuspend, which
;    keeps a pause, retires workers and hands off to the successor exactly as
;    the menu row does.
; ==============================================================================

#Requires AutoHotkey v2.0

global DEV_SOURCE_POLL_MS := 1000
; Files of the gitdir whose presence means Git is rewriting the tree: the lock
; of every index and working-tree update, the multi-step merge markers, and the
; file every rebase backend keeps in its state folder.
global DEV_SOURCE_GIT_MARKERS := ["index.lock", "MERGE_HEAD", "CHERRY_PICK_HEAD",
	"REVERT_HEAD", "rebase-merge\head-name", "rebase-apply\head-name"]
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
	Data := JsonParse(FileRead(SharedDir . "\core\text\data\identifiers.json", "UTF-8"))
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
	Attributes := FileExist(Root . "\static\ergopti_plus\_shared\core\text\data\identifiers.json")
	if (Attributes == "" || InStr(Attributes, "D"))
		return ""
	return Root
}





; The Git directory of a clone: its .git folder, or the folder a linked
; worktree's .git file points to. A launcher root may be a tree without .git,
; where no Git operation can run. A .git file that names no existing gitdir
; raises, since the watcher could not see a Git operation then.
; @param Root {String} The clone root.
; @returns {String} The gitdir, "" for a tree without .git.
DevSource_GitDir(Root) {
	DotGit := Root . "\.git"
	Attributes := FileExist(DotGit)
	if (Attributes == "")
		return ""
	if InStr(Attributes, "D")
		return DotGit
	if !RegExMatch(FileRead(DotGit, "UTF-8"), "m)^gitdir:[ \t]*(.+?)[ \t\r]*$", &Match)
		throw Error("The .git file of the developer clone names no gitdir: " . DotGit)
	GitDir := StrReplace(Match[1], "/", "\")
	if !RegExMatch(GitDir, "^(?:[A-Za-z]:\\|\\\\)")
		GitDir := Root . "\" . GitDir
	if !InStr(FileExist(GitDir), "D")
		throw Error("The gitdir of the developer clone does not exist: " . GitDir)
	return GitDir
}

; The first Git marker present in GitDir, "" while no operation runs.
; @param GitDir {String} DevSource_GitDir's answer.
; @returns {String}
DevSource_GitOperation(GitDir) {
	if (GitDir == "")
		return ""
	for Marker in DEV_SOURCE_GIT_MARKERS {
		if (FileExist(GitDir . "\" . Marker) != "")
			return Marker
	}
	return ""
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

; Every path that was added, removed or changed between two snapshots.
; @param Old {Map}
; @param New {Map}
; @returns {Array} The changed paths, empty when nothing changed.
DevSource_SnapshotChanges(Old, New) {
	Changed := []
	for Path, Stamp in New {
		if (!Old.Has(Path) || Old[Path] != Stamp)
			Changed.Push(Path)
	}
	for Path in Old {
		if !New.Has(Path)
			Changed.Push(Path)
	}
	return Changed
}

; Starts the developer watcher. Raises when it already runs.
; @param DriverDir {String} The driver folder.
; @param GitDir {String} DevSource_GitDir of the clone, "" for a tree without .git.
; @param ReloadFn {Func} Called once a change settles; ReloadPreservingSuspend in production.
; @param ArmFn {Func} Test seam for SetTimer.
; @param NowFn {Func} Test seam for the millisecond clock.
DevSourceWatcher_Start(DriverDir, GitDir, ReloadFn, ArmFn := SetTimer, NowFn := _DevSourceNow) {
	global _DevSourceWatcher
	if (_DevSourceWatcher is Map)
		throw Error("The developer source watcher is already running")
	if (GitDir != "") && !InStr(FileExist(GitDir), "D")
		throw Error("The developer source watcher needs the clone's gitdir: " . GitDir)
	_DevSourceWatcher := Map("dir", DriverDir, "git_dir", GitDir,
		"snapshot", DevSource_Snapshot(DriverDir), "burst", Map(), "last_change", 0,
		"git_hold", "", "git_hold_since", 0, "git_hold_reported", false,
		"reload", ReloadFn, "arm", ArmFn, "now", NowFn)
	ArmFn(_DevSourceWatcherTick, DEV_SOURCE_POLL_MS)
	LoggerInfo("DevSource", "Developer source watcher started on {1} ({2} file(s)); Git operations are read in {3}.",
		DriverDir, _DevSourceWatcher["snapshot"].Count, (GitDir == "") ? "no gitdir (the tree has no .git)" : GitDir)
}

_DevSourceNow() {
	return A_TickCount
}

; Stops the developer watcher; a no-op when it does not run.
DevSourceWatcher_Stop() {
	global _DevSourceWatcher
	if !(_DevSourceWatcher is Map)
		return
	_DevSourceWatcher["arm"](_DevSourceWatcherTick, 0)
	if (_DevSourceWatcher["git_hold"] != "")
		LoggerWarn("DevSource", "Developer source watcher stopped while a Git operation ({1}) held its reload.",
			_DevSourceWatcher["git_hold"])
	_DevSourceWatcher := 0
	LoggerInfo("DevSource", "Developer source watcher stopped.")
}

; One poll. A change joins the current burst; the burst reloads once the whole
; tree was quiet long enough for its size and no Git operation is under way.
_DevSourceWatcherTick() {
	global _DevSourceWatcher
	if !(_DevSourceWatcher is Map)
		return
	Watcher := _DevSourceWatcher
	Now := Watcher["now"]()
	Snapshot := DevSource_Snapshot(Watcher["dir"])
	Changed := DevSource_SnapshotChanges(Watcher["snapshot"], Snapshot)
	Watcher["snapshot"] := Snapshot
	Burst := Watcher["burst"]
	for Path in Changed
		Burst[Path] := true
	if (Changed.Length > 0) {
		Watcher["last_change"] := Now
		return
	}
	if (Burst.Count == 0)
		return
	if !_DevSourceGitSettled(Watcher, Now)
		return
	if (Burst.Count > TimingsGet("ui", "dev_source_bulk_threshold")
			&& !TickExpired(Watcher["last_change"], TimingsGet("ui", "dev_source_bulk_settle_ms"), Now))
		return
	for Path in Burst {
		First := Path
		break
	}
	Watcher["burst"] := Map()
	if (Burst.Count == 1)
		LoggerInfo("DevSource", "Saved source {1} settled; reloading the driver.", First)
	else
		LoggerInfo("DevSource", "{1} saved source files settled across the tree (first {2}); reloading the driver.",
			Burst.Count, First)
	Watcher["reload"]()
}

; Whether no Git operation holds the pending reload. The hold is paired: its
; start is logged once, and its end both logs and restarts the quiet time, since
; Git may still have been writing when the lock went away.
_DevSourceGitSettled(Watcher, Now) {
	Marker := DevSource_GitOperation(Watcher["git_dir"])
	if (Marker != "") {
		if (Watcher["git_hold"] == "") {
			Watcher["git_hold"] := Marker
			Watcher["git_hold_since"] := Now
			Watcher["git_hold_reported"] := false
			LoggerStart("DevSource", "Holding the reload while a Git operation rewrites the tree ({1})…", Marker)
		} else if !Watcher["git_hold_reported"]
				&& TickExpired(Watcher["git_hold_since"], TimingsGet("ui", "dev_source_git_hold_report_ms"), Now) {
			Watcher["git_hold_reported"] := true
			LoggerWarn("DevSource", "A Git operation has held the reload for {1} ms ({2} in {3}); a stale lock blocks it until removed.",
				Now - Watcher["git_hold_since"], Marker, Watcher["git_dir"])
		}
		return false
	}
	if (Watcher["git_hold"] == "")
		return true
	LoggerSuccess("DevSource", "The Git operation ended after {1} ms; the reload waits for the tree to settle.",
		Now - Watcher["git_hold_since"])
	Watcher["git_hold"] := ""
	; Git may have written the last files just before it released the lock.
	Watcher["last_change"] := Now
	return false
}
