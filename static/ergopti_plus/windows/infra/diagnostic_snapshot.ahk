; infra/diagnostic_snapshot.ahk

; ==============================================================================
; MODULE: Diagnostic Snapshot (Windows)
; DESCRIPTION:
; Builds the one-line environment summary the driver logs once boot completes.
; The field list and rendering rules are the cross-driver contract in
; _shared/modules/logger/diagnostic_snapshot.json; macOS and Linux render the
; same fields through _shared/lua/diagnostics/snapshot.lua.
;
; FEATURES & RATIONALE:
; 1. One line, identical field names on every driver: a user log answers "which
;    build, which OS, which layout, elevated or not, how long did boot take"
;    with the same grep whatever the platform.
; 2. No subprocess and no network: every fact is a built-in variable, a registry
;    read or a small file read, so the snapshot costs a few milliseconds after
;    "ready" and nothing on the keystroke path.
; 3. Privacy: environment facts only. The configuration path is rendered relative
;    to the profile directory ("~") so the account name stays out of shared logs.
; ==============================================================================





; ======================================
; ======================================
; ======= 1/ Contract and format =======
; ======================================
; ======================================

; Ordered field names. A function static rather than a global so the list exists
; before this file's include position runs, and pinned to the shared JSON by
; tests/unit/test_diagnostic_snapshot.ahk and the JS parity test.
; @returns {Array}
DiagSnapshot_Fields() {
	static Fields := [
		"driver", "version", "commit", "os", "os_version", "arch", "runtime",
		"elevated", "locale", "keyboard_layout", "monitors", "dpi", "display",
		"config_dir", "log_level", "features_enabled", "boot_ms"
	]
	return Fields
}

; Log tag of the snapshot line, shared with the other drivers.
; @returns {String}
DiagSnapshot_Module() {
	return "Diagnostics"
}

; Renders one value under the shared quoting rules.
; @param Value {Any} Raw value; an unset or empty value becomes "unknown".
; @returns {String}
DiagSnapshot_RenderValue(Value?) {
	if !IsSet(Value)
		return "unknown"
	Text := (Value is String) ? Value : String(Value)
	Text := StrReplace(StrReplace(StrReplace(Text, "`r", " "), "`n", " "), "`t", " ")
	Text := StrReplace(Text, '"', "'")
	if (Text == "")
		return "unknown"
	if InStr(Text, " ")
		return '"' . Text . '"'
	return Text
}

; Builds the snapshot message body from a Map of field name to raw value.
; @param Values {Map}
; @returns {String}
DiagSnapshot_Format(Values) {
	Parts := ""
	for _, Name in DiagSnapshot_Fields() {
		Rendered := (Values is Map && Values.Has(Name))
			? DiagSnapshot_RenderValue(Values[Name]) : DiagSnapshot_RenderValue()
		Parts .= (Parts == "" ? "" : " ") . Name . "=" . Rendered
	}
	return "Diagnostic snapshot (" . Parts . ")."
}

; Renders a path under the user's profile as "~\…".
; @param Path {String}
; @param Home {String}
; @returns {String}
DiagSnapshot_RedactHome(Path, Home) {
	if (Path == "" || Home == "")
		return Path
	Home := RTrim(Home, "\/")
	if (Home != "" && SubStr(Path, 1, StrLen(Home)) = Home) {
		Rest := SubStr(Path, StrLen(Home) + 1)
		if (Rest == "" || SubStr(Rest, 1, 1) == "\" || SubStr(Rest, 1, 1) == "/")
			return "~" . Rest
	}
	return Path
}





; =====================================
; =====================================
; ======= 2/ Environment probes =======
; =====================================
; =====================================

; Reads a small text file and trims it, or returns "" when it is absent.
; @param Path {String}
; @returns {String}
_DiagSnapshot_ReadTrimmed(Path) {
	if !FileExist(Path)
		return ""
	; Through the FileSystem adapter, which owns every file read outside adapters/.
	Content := FSRead(Path)
	if !(Content is String) {
		try LoggerDebug("Diagnostics", "Could not read '{1}'.", Path)
		return ""
	}
	return Trim(Content, " `t`r`n")
}

; Resolves the commit checked out in the repository containing StartDir. A
; source checkout has no build stamp, and "which commit was running" is the
; first question of every bug report, so HEAD is read directly instead of
; spawning git after boot.
; @param StartDir {String}
; @returns {String} Abbreviated commit id, or "" outside a repository.
DiagSnapshot_GitCommit(StartDir) {
	static SHORT_SHA_LENGTH := 9
	static MAX_WALK_DEPTH := 40
	Dir := RTrim(StartDir, "\/")
	GitDir := ""
	loop MAX_WALK_DEPTH {
		if (Dir == "")
			break
		if FileExist(Dir . "\.git\HEAD") {
			GitDir := Dir . "\.git"
			break
		}
		; A linked worktree's .git is a file holding a "gitdir: <path>" pointer.
		Pointer := InStr(FileExist(Dir . "\.git"), "D") ? "" : _DiagSnapshot_ReadTrimmed(Dir . "\.git")
		if RegExMatch(Pointer, "^gitdir:\s*(.+)$", &M) {
			GitDir := StrReplace(M[1], "/", "\")
			if !RegExMatch(GitDir, "^[A-Za-z]:|^\\\\")
				GitDir := Dir . "\" . GitDir
			break
		}
		Parent := RegExReplace(Dir, "[\\/][^\\/]*$")
		if (Parent == Dir)
			break
		Dir := Parent
	}
	if (GitDir == "")
		return ""
	Head := _DiagSnapshot_ReadTrimmed(GitDir . "\HEAD")
	if RegExMatch(Head, "^[0-9a-f]{40}$")
		return SubStr(Head, 1, SHORT_SHA_LENGTH)
	if !RegExMatch(Head, "^ref:\s*(\S+)$", &RefMatch)
		return ""
	Ref := RefMatch[1]
	CommonDir := GitDir
	Common := _DiagSnapshot_ReadTrimmed(GitDir . "\commondir")
	if (Common != "")
		CommonDir := RegExMatch(Common, "^[A-Za-z]:|^\\\\") ? Common : GitDir . "\" . Common
	RefPath := StrReplace(Ref, "/", "\")
	Sha := _DiagSnapshot_ReadTrimmed(GitDir . "\" . RefPath)
	if (Sha == "")
		Sha := _DiagSnapshot_ReadTrimmed(CommonDir . "\" . RefPath)
	if (Sha == "") {
		Packed := _DiagSnapshot_ReadTrimmed(CommonDir . "\packed-refs")
		if RegExMatch(Packed, "m)^([0-9a-f]{40}) \Q" . Ref . "\E$", &PackedMatch)
			Sha := PackedMatch[1]
	}
	return RegExMatch(Sha, "^[0-9a-f]{40}$") ? SubStr(Sha, 1, SHORT_SHA_LENGTH) : ""
}

; The Windows product name and build. ProductName still says "Windows 10" on
; Windows 11, whose builds start at 22000, so the name is corrected from the
; build number instead of being reported wrong.
; @returns {Map} { os, os_version }
DiagSnapshot_OsInfo() {
	static KEY := "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
	static WINDOWS_11_FIRST_BUILD := 22000
	Info := Map("os", "Windows", "os_version", A_OSVersion)
	try {
		Name := RegRead(KEY, "ProductName")
		Build := RegRead(KEY, "CurrentBuildNumber")
		Ubr := ""
		try Ubr := RegRead(KEY, "UBR")
		catch as UbrErr
			try LoggerDebug("Diagnostics", "Windows update build revision unavailable: {1}.", UbrErr.Message)
		if (IsInteger(Build) && Integer(Build) >= WINDOWS_11_FIRST_BUILD)
			Name := StrReplace(Name, "Windows 10", "Windows 11")
		Info["os"] := Name
		Info["os_version"] := Build . (Ubr != "" ? "." . Ubr : "")
	} catch as Err {
		try LoggerWarn("Diagnostics", "Windows version registry read failed: {1}.", Err.Message)
	}
	return Info
}

; Names a function further up the call stack, so a rare lifecycle request
; (reload, suspend) can say who asked without threading a reason through every
; caller. Never called on a keystroke path: building an Error walks the stack.
; @param Offset {Integer} Relative to the function calling this helper: -1 is
;   that function itself, -2 its caller.
; @returns {String} The function name, or "unknown" when the stack is shallower.
DiagCallerName(Offset) {
	try {
		What := Error("", Offset - 1).What
		return (What != "") ? What : "unknown"
	} catch as Err {
		return "unknown (" . Err.Message . ")"
	}
}

; Counts enabled/known switches in a Features tree: every leaf that is a
; boolean-like integer (0 or 1). Nested Maps are walked; strings are settings,
; not switches, and are not counted.
; @param Tree {Map}
; @returns {Map} { enabled, total }
DiagSnapshot_CountFeatures(Tree) {
	Counts := Map("enabled", 0, "total", 0)
	_DiagSnapshot_CountLeaves(Tree, Counts)
	return Counts
}

_DiagSnapshot_CountLeaves(Node, Counts) {
	if !(Node is Map)
		return
	for _, Value in Node {
		if (Value is Map) {
			_DiagSnapshot_CountLeaves(Value, Counts)
		} else if (Value is Integer && (Value == 0 || Value == 1)) {
			Counts["total"] += 1
			Counts["enabled"] += Value
		}
	}
}




; =====================================
; =====================================
; ======= 3/ Collect and emit =========
; =====================================
; =====================================

; Collects every snapshot value from the running driver.
; @param BootMs {Integer} Total boot duration.
; @returns {Map}
DiagSnapshot_Collect(BootMs) {
	global BUNDLE_COMMIT, LOGGER_MIN_LEVEL, _ConfigDir, Features
	Values := Map("driver", "windows", "display", "win32", "boot_ms", BootMs)
	Values["version"] := IsSet(Updater_CurrentVersion) ? Updater_CurrentVersion() : ""
	Values["commit"] := (IsSet(BUNDLE_COMMIT) && BUNDLE_COMMIT != "__BUNDLE_COMMIT__")
		? SubStr(BUNDLE_COMMIT, 1, 9) : DiagSnapshot_GitCommit(A_ScriptDir)
	OsInfo := DiagSnapshot_OsInfo()
	Values["os"] := OsInfo["os"]
	Values["os_version"] := OsInfo["os_version"]
	Values["arch"] := (A_Is64bitOS ? "x64" : "x86") . (A_PtrSize == 8 ? "" : " (32-bit process)")
	Values["runtime"] := "AutoHotkey " . A_AhkVersion
	Values["elevated"] := A_IsAdmin ? "true" : "false"
	Values["locale"] := IsSet(I18nGetLocale) ? I18nGetLocale() : ""
	Hkl := IsSet(KS_ResolveKeyboardLayout) ? KS_ResolveKeyboardLayout() : 0
	Values["keyboard_layout"] := Hkl ? Format("0x{:08X}", Hkl & 0xFFFFFFFF) : ""
	Values["monitors"] := MonitorGetCount()
	Values["dpi"] := A_ScreenDPI
	Values["config_dir"] := IsSet(_ConfigDir)
		? DiagSnapshot_RedactHome(_ConfigDir, EnvGet("USERPROFILE")) : ""
	Values["log_level"] := IsSet(LOGGER_MIN_LEVEL) ? LOGGER_MIN_LEVEL : ""
	if (IsSet(Features) && Features is Map) {
		Counts := DiagSnapshot_CountFeatures(Features)
		Values["features_enabled"] := Counts["enabled"] . "/" . Counts["total"]
	}
	return Values
}

; The environment half of the snapshot, logged at the very start of boot. A boot
; that dies before "ready" never logs the full snapshot, and the machine it died
; on must still be described somewhere in its log.
; @returns {String}
DiagSnapshot_EarlyLine() {
	global DriverPid
	Values := DiagSnapshot_Collect("")
	Parts := ""
	for _, Name in ["version", "commit", "os", "os_version", "arch", "runtime",
			"elevated", "keyboard_layout", "monitors", "dpi", "config_dir"]
		Parts .= " " . Name . "=" . DiagSnapshot_RenderValue(Values[Name])
	return "Boot environment (pid=" . (IsSet(DriverPid) ? DriverPid : "unknown")
		. " compiled=" . (A_IsCompiled ? "true" : "false") . Parts . ")."
}

; Collects and logs the snapshot line.
; @param BootMs {Integer}
; @returns {String} The logged message.
DiagSnapshot_Emit(BootMs) {
	Message := DiagSnapshot_Format(DiagSnapshot_Collect(BootMs))
	LoggerInfo(DiagSnapshot_Module(), "{1}", Message)
	return Message
}
