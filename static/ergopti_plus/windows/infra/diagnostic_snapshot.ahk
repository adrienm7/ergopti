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
		"config_dir", "logs_dir", "log_level", "features_enabled", "boot_ms"
	]
	return Fields
}

/** Produces closed collector identity fields without paths or personal state. */
DiagSnapshot_CollectionIdentity() {
	global _SharedDir, BUNDLE_COMMIT
	if A_IsCompiled {
		if !IsSet(BUNDLE_COMMIT) || !RegExMatch(BUNDLE_COMMIT, "i)^[0-9a-f]{40}$")
			throw Error("Installed diagnostic collection requires its complete source build stamp.")
		SourceSha := StrLower(BUNDLE_COMMIT)
	} else {
		SourceSha := DiagSnapshot_GitCommit(A_ScriptDir, true)
		if SourceSha == ""
			SourceSha := "unknown"
	}
	Identity := Map("compiled", A_IsCompiled ? 1 : 0, "evidence_origin", "resident_driver", "version", Updater_CurrentVersion(),
		"source_sha", SourceSha, "architecture", A_PtrSize == 8 ? "x64" : "x86",
		"runtime", A_AhkVersion, "receiver_title", t("healthcheck.collection.start"))
	Rules := JsonParse(FSReadStrict(_SharedDir . "\modules\diagnostics\redaction.json"))
	Context := HealthCheck_RedactionContext()
	for Key in ["version", "source_sha", "architecture", "runtime", "receiver_title"] {
		if Redact_Apply(Identity[Key], Rules, Context) != Identity[Key]
			throw Error("Diagnostic technical identity failed redaction admission.")
	}
	Identity["redaction_verified"] := true
	ProcessIdentity := PLC_CurrentProcessIdentity()
	global _DriverMutexDecision, _DriverMutexHandle, _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	Identity["input_owner"] := Map("pid", ProcessIdentity["pid"],
		"created_filetime", ProcessIdentity["created_filetime"],
		"mutex", IsSet(_DriverMutexDecision) ? _DriverMutexDecision : "unavailable",
		"mutex_handle_retained", IsSet(_DriverMutexHandle) && _DriverMutexHandle != 0 ? 1 : 0,
		"dispatcher_started", HookDispatcher._started ? 1 : 0,
		"native_started", _LLM_NavEventOwnerStarted ? 1 : 0,
		"native_quarantined", _LLM_NavEventOwnerQuarantined ? 1 : 0)
	return Identity
}

/** Reads closed resident state without acquiring an input, model or capture owner. */
DiagSnapshot_ResidentObservations(Contract := 0) {
	global _SharedDir, HSE_RegistryGeneration, HSE_RuntimeDecisionGeneration, HSE_RegistryTransitionDepth, HSE_Suppressed
	global _PrefixContentGeneration, _PrefixWatcherSuppressed, _LLM_ManagedBootstrap, LLM_OLLAMA_BASE_URL
	global _OllamaIdentityPendingHandles
	if !(Contract is Map)
		Contract := JsonParse(FSReadStrict(_SharedDir . "\modules\diagnostics\collection.json"))
	Fields := Contract["resident_observation_fields"]
	Rows := []
	for Id in ["hotstrings", "ai", "capture_replay", "fifo"]
		Rows.Push(_DiagSnapshot_ResidentRow(Id, Fields[Id], Contract["resident_observation_preconditions"]))
	PreviousCritical := Critical("On")
	try {
		Row := Rows[1]
		Row["status"] := "PASS", Row["scope"] := "runtime_state", Row["reason"] := "resident_generations_observed"
		Row["values"] := Map("registry_generation", HSE_RegistryGeneration, "runtime_generation", HSE_RuntimeDecisionGeneration,
			"transition_depth", HSE_RegistryTransitionDepth, "suppression_depth", HSE_Suppressed,
			"prefix_generation", _PrefixContentGeneration, "prefix_suppression_depth", _PrefixWatcherSuppressed)
		try _DiagSnapshot_ResidentNativeReads(Rows)
		catch as Err {
			LoggerWarn("DiagnosticsCollection", "Resident native state queries failed; their observations remain incomplete.")
			for Index in [3, 4]
				Rows[Index]["status"] := "FAIL", Rows[Index]["reason"] := "native_observation_error",
					Rows[Index]["errors"] := [Map("reason", "native_observation_error")]
		}
		Flow := IsSet(_LLM_ManagedBootstrap) ? _LLM_ManagedBootstrap : 0
		Row := Rows[2]
		Row["values"]["managed_owner_present"] := IsObject(Flow) ? 1 : 0
		Row["values"]["identity_handle_debt"] := _OllamaIdentityPendingHandles.Count
		if IsObject(Flow) && !(Flow.Port is Map) && Flow.Ready && IsObject(Flow.Runtime) && Flow.Runtime.Record is Map {
			Record := Flow.Runtime.Record
			Target := Record.Get("target", 0)
			if _OllamaIdentityPendingHandles.Count {
				; A diagnostic read cannot perform another operation's debt retirement.
				Row["reason"] := "native_identity_cleanup_pending"
			} else if Target is Map && Record.Get("ready", false) && !Record.Get("cancelled", true)
					&& !Record.Get("terminal", true) && Flow.Runtime.HasOwner() && Flow.Endpoint == LLM_OLLAMA_BASE_URL {
				Started := A_TickCount
				Ready := OllamaNativeIdentityReady(Record.Get("process_receipt", 0), Target.Clone())
				Ready := Ready && _LLM_ManagedBootstrap == Flow && Flow.Runtime.Record == Record
					&& Flow.Ready && !Flow.Cancelled && Flow.Endpoint == LLM_OLLAMA_BASE_URL
				Row["status"] := Ready ? "PASS" : "FAIL", Row["scope"] := "native_readonly"
				Row["reason"] := Ready ? "native_managed_listener_identity_observed" : "native_managed_listener_identity_refused"
				Row["duration_ms"] := TickElapsed(Started), Row["values"]["live_identity"] := Ready ? 1 : 0
			}
		}
	} catch as Err {
		; The archive exports only a closed failure, never exception text or user paths.
		LoggerWarn("DiagnosticsCollection", "Resident state observation failed; functional qualification remains unavailable.")
		Row["status"] := "FAIL", Row["reason"] := "resident_observation_error"
		Row["errors"] := [Map("reason", "resident_observation_error")]
		Rows[2]["values"]["identity_handle_debt"] := _OllamaIdentityPendingHandles.Count
	} finally Critical(PreviousCritical)
	CapturedAt := PLC_CurrentFiletime()
	return Map("schema_version", Contract["resident_observation_schema_version"],
		"captured_at_filetime", CapturedAt, "rows", Rows)
}

_DiagSnapshot_ResidentRow(Id, Fields, Preconditions) {
	Values := Map()
	for Field in Fields
		Values[Field] := -1
	return Map("id", Id, "status", "UNRUN", "scope", "unexecuted", "reason", "resident_owner_unavailable",
		"duration_ms", 0, "scenario_qualified", false, "values", Values,
		"evidence_class", "automatic", "preconditions", Preconditions.Clone(), "errors", [])
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
; @param Full {Boolean} Preserve the complete id for a versioned collection manifest.
; @returns {String} Commit id, or "" outside a repository.
DiagSnapshot_GitCommit(StartDir, Full := false) {
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
		return Full ? Head : SubStr(Head, 1, SHORT_SHA_LENGTH)
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
	return RegExMatch(Sha, "^[0-9a-f]{40}$") ? (Full ? Sha : SubStr(Sha, 1, SHORT_SHA_LENGTH)) : ""
}

; The commit a compiled release was stamped with (CI replaces the placeholder in
; infra/bundle.ahk), abbreviated like every other commit in the diagnostics.
; @param Stamp {String} Raw BUNDLE_COMMIT value; defaults to the global.
; @returns {Map} { commit, error }: commit is "" when there is no valid stamp,
;   error explains a present stamp that is not a full commit id.
DiagSnapshot_BuildCommit(Stamp?) {
	global BUNDLE_COMMIT
	static SHORT_SHA_LENGTH := 9
	if !IsSet(Stamp)
		Stamp := IsSet(BUNDLE_COMMIT) ? BUNDLE_COMMIT : ""
	if (Stamp == "" || Stamp == "__BUNDLE_COMMIT__")
		return Map("commit", "", "error", "")
	if !RegExMatch(Stamp, "i)^[0-9a-f]{40}$")
		return Map("commit", "", "error", "BUNDLE_COMMIT '" . Stamp . "' is not a full commit id")
	return Map("commit", SubStr(StrLower(Stamp), 1, SHORT_SHA_LENGTH), "error", "")
}

; Resolves the commit the running driver was built from: the build stamp of a
; compiled release, else the git checkout a source run lives in, else
; "unknown" with the reason logged. The single resolver behind the snapshot,
; the healthcheck and the crash report, so the three can never disagree.
; @param StartDir {String} Directory the git lookup starts from.
; @param Stamp {String} Raw BUNDLE_COMMIT override, for tests.
; @returns {Map} { commit, source }: source is "build", "git" or "unknown".
DiagSnapshot_ResolveCommit(StartDir := A_ScriptDir, Stamp?) {
	Built := IsSet(Stamp) ? DiagSnapshot_BuildCommit(Stamp) : DiagSnapshot_BuildCommit()
	if (Built["commit"] != "")
		return Map("commit", Built["commit"], "source", "build")
	; A stamp that is present but malformed is a broken build, not a source run:
	; answering from git would hide the defect behind a plausible id.
	Reason := Built["error"]
	if (Reason == "") {
		Sha := DiagSnapshot_GitCommit(StartDir)
		if (Sha != "")
			return Map("commit", Sha, "source", "git")
		Reason := "no build stamp and '" . StartDir . "' is not inside a git checkout"
	}
	; Not the Diagnostics tag: that one is the grep key of the snapshot line.
	try LoggerWarn("BuildCommit", "Build commit unknown: {1}.", Reason)
	return Map("commit", "unknown", "source", "unknown")
}

; Corrects the registry product name from the build number. ProductName still
; says "Windows 10" on Windows 11, whose builds start at 22000. Pure, so every
; diagnostic surface (boot line, healthcheck, crash report) answers alike.
; @param Name {String} Raw ProductName registry value.
; @param Build {String} Raw CurrentBuildNumber registry value.
; @returns {String} The product name a user recognises.
DiagSnapshot_WindowsProductName(Name, Build) {
	static WINDOWS_11_FIRST_BUILD := 22000
	if (IsInteger(Build) && Integer(Build) >= WINDOWS_11_FIRST_BUILD)
		return StrReplace(Name, "Windows 10", "Windows 11")
	return Name
}

; The Windows product name and build: the single probe behind the snapshot
; line, the healthcheck window and the crash report, so the three can never
; name the same machine differently.
; @returns {Map} { os, os_version }
DiagSnapshot_OsInfo() {
	static KEY := "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
	Info := Map("os", "Windows", "os_version", A_OSVersion)
	try {
		Name := RegRead(KEY, "ProductName")
		Build := RegRead(KEY, "CurrentBuildNumber")
		Ubr := ""
		try Ubr := RegRead(KEY, "UBR")
		catch as UbrErr
			try LoggerDebug("Diagnostics", "Windows update build revision unavailable: {1}.", UbrErr.Message)
		Name := DiagSnapshot_WindowsProductName(Name, Build)
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
	global LOGGER_MIN_LEVEL, _ConfigDir, Features
	Values := Map("driver", "windows", "display", "win32", "boot_ms", BootMs)
	Values["version"] := IsSet(Updater_CurrentVersion) ? Updater_CurrentVersion() : ""
	Values["commit"] := DiagSnapshot_ResolveCommit(A_ScriptDir)["commit"]
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
	; Where this report's own logs are, from the logger's one resolver.
	Values["logs_dir"] := DiagSnapshot_RedactHome(LoggerLogsDir(), EnvGet("USERPROFILE"))
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
