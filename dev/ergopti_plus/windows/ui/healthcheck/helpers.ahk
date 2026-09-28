; ui/healthcheck/helpers.ahk

; ==============================================================================
; MODULE: Healthcheck / Collectors
; DESCRIPTION:
; The synchronous half of the diagnostics snapshot (version 2 of
; _shared/modules/diagnostics/schema.json): one collector per section, each
; returning that section's fields as a Map. The asynchronous probes (network
; and AI backend) live in ui/healthcheck/probes.ahk.
;
; FEATURES & RATIONALE:
; 1. Phase A stays in-process: registry reads, Win32 calls, memory and small
;    files. The processor used to come from a WMI ConnectServer on the AHK
;    thread, which is the thread that serves the keyboard hook: opening the
;    window could stall typing for hundreds of milliseconds.
; 2. Values are raw (bytes, seconds, booleans as 1 and 0); the shared page
;    formats them, so the three drivers show one format.
; 3. A fact that cannot be read is left out and logged; the page shows it as
;    unknown. A fabricated default would read as a measurement.
; 4. Nothing identifies a place or a device: no host name, no serial, no
;    device instance path. Open applications and device names are collected
;    only when the user ticks "Include details".
;
; Split out of the former infra/healthcheck.ahk (the module split); see
; ui/healthcheck/init.ahk for the module overview. Functions and globals are
; hoisted, so load order across the healthcheck/*.ahk files is irrelevant.
; ==============================================================================

; The WebView2 runtime's EdgeUpdate client id, under which Windows records the
; installed runtime version, machine-wide or per user
global HC_WEBVIEW2_CLIENT := "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

; GetRawInputDeviceInfo's command for the device interface path
global HC_RIDI_DEVICENAME := 0x20000007





; ==========================================
; ==========================================
; ======= 1/ Reading Without Failing =======
; ==========================================
; ==========================================

; Calls a reader and returns its value, or "" after logging why it failed.
; @param Label {String} What was read, for the log.
; @param Reader {Func} Zero-argument reader.
; @returns {Any}
_HealthCheck_Read(Label, Reader) {
	try return Reader.Call()
	catch as Err {
		LoggerWarn("Healthcheck", "Diagnostics could not read {1}: {2}.", Label, Err.Message)
		return ""
	}
}

; Stores a value in a section unless it is "" (unknown).
; @param Section {Map}
; @param Key {String}
; @param Value {Any}
_HealthCheck_Put(Section, Key, Value) {
	if !(Value is String) || (Value != "")
		Section[Key] := Value
}

; The folder part of a path.
; @param Path {String}
; @returns {String} "" when the path has no folder.
_HealthCheck_Dirname(Path) {
	if (Path == "")
		return ""
	SplitPath(Path, , &Dir)
	return Dir
}





; ========================
; ========================
; ======= 2/ Paths =======
; ========================
; ========================

; The folders and files the diagnostics page lists and opens by id.
; @param ReportSubdir {String} The schema's report.subdir.
; @returns {Map}
_HealthCheck_Paths(ReportSubdir) {
	global _ConfigDir
	Paths := Map()
	LogToday := LoggerTodayLogPath()
	LogsDir := LoggerLogsDir()
	_HealthCheck_Put(Paths, "config_dir", IsSet(_ConfigDir) ? RTrim(_ConfigDir, "\") : "")
	_HealthCheck_Put(Paths, "logs_dir", LogsDir)
	_HealthCheck_Put(Paths, "log_today", LogToday)
	_HealthCheck_Put(Paths, "errors_today", _HealthCheck_ErrorsLogPath())
	_HealthCheck_Put(Paths, "crash_dir", _HealthCheck_Read("the crash reports folder", CrashReport_Dir))
	_HealthCheck_Put(Paths, "diagnostics_dir", (LogsDir != "") ? LogsDir . "\" . ReportSubdir : "")
	_HealthCheck_Put(Paths, "app_dir", A_ScriptDir)
	return Paths
}





; ===========================
; ===========================
; ======= 3/ Versions =======
; ===========================
; ===========================

; The installed WebView2 runtime version, machine-wide or per user.
; @returns {String} "" when no runtime is registered.
_HealthCheck_WebView2Version() {
	global HC_WEBVIEW2_CLIENT
	for Key in ["HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\" . HC_WEBVIEW2_CLIENT
		, "HKLM\SOFTWARE\Microsoft\EdgeUpdate\Clients\" . HC_WEBVIEW2_CLIENT
		, "HKCU\Software\Microsoft\EdgeUpdate\Clients\" . HC_WEBVIEW2_CLIENT] {
		Version := RegRead(Key, "pv", "")
		if (Version != "" && Version != "0.0.0.0")
			return "WebView2 " . Version
	}
	return ""
}

; The versions a bug report is triaged by.
; @returns {Map}
_HealthCheck_Versions() {
	global UPDATER_CHANNEL
	Versions := Map()
	_HealthCheck_Put(Versions, "ergopti_version", _HealthCheck_Read("the ErgoptiPlus version",
		() => Updater_CurrentVersion()))
	Commit := DiagSnapshot_ResolveCommit(A_ScriptDir)
	Versions["commit"] := Commit["commit"] . " (" . Commit["source"] . ")"
	_HealthCheck_Put(Versions, "channel", IsSet(UPDATER_CHANNEL) ? UPDATER_CHANNEL : "")
	Versions["runtime"] := "AutoHotkey " . A_AhkVersion . " " . ((A_PtrSize = 8) ? "64-bit" : "32-bit")
	_HealthCheck_Put(Versions, "webview", _HealthCheck_WebView2Version())
	return Versions
}





; ====================================
; ====================================
; ======= 4/ Hardware And Load =======
; ====================================
; ====================================

; Physical and available memory, in bytes.
; @returns {Map} { total, free }
_HealthCheck_Memory() {
	MemStatus := Buffer(64, 0)
	NumPut("UInt", 64, MemStatus, 0)
	if !DllCall("GlobalMemoryStatusEx", "Ptr", MemStatus)
		throw OSError(A_LastError, -1, "GlobalMemoryStatusEx")
	return Map("total", NumGet(MemStatus, 8, "UInt64"), "free", NumGet(MemStatus, 16, "UInt64"))
}

; Every display: its resolution, the primary one's scale.
; @returns {Array}
_HealthCheck_Displays() {
	Displays := []
	Primary := MonitorGetPrimary()
	Loop MonitorGetCount() {
		MonitorGet(A_Index, &Left, &Top, &Right, &Bottom)
		Text := (Right - Left) . "×" . (Bottom - Top)
		if (A_Index = Primary)
			Text .= " @" . Round(A_ScreenDPI / 96 * 100) . "% (main)"
		Displays.Push(Text)
	}
	return Displays
}

; The hardware section.
; @returns {Map}
_HealthCheck_Hardware() {
	Hardware := Map()
	Model := _HealthCheck_Read("the machine model", () => Trim(
		RegRead("HKLM\HARDWARE\DESCRIPTION\System\BIOS", "SystemManufacturer", "") . " "
		. RegRead("HKLM\HARDWARE\DESCRIPTION\System\BIOS", "SystemProductName", "")))
	_HealthCheck_Put(Hardware, "model", Model)
	_HealthCheck_Put(Hardware, "cpu", _HealthCheck_Read("the processor", () => Trim(
		RegRead("HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString"))))
	Cores := EnvGet("NUMBER_OF_PROCESSORS")
	if IsInteger(Cores)
		Hardware["cpu_cores"] := Integer(Cores)
	Hardware["arch"] := A_Is64bitOS ? "x64" : "x86"
	Memory := _HealthCheck_Read("the memory", _HealthCheck_Memory)
	if (Memory is Map)
		Hardware["ram_total"] := Memory["total"]
	Displays := _HealthCheck_Read("the displays", _HealthCheck_Displays)
	if (Displays is Array)
		Hardware["displays"] := Displays
	return Hardware
}

; The working set of this process, in bytes.
; @returns {Integer}
; @throws {OSError} When Windows refuses the query.
_HealthCheck_ProcessMemory() {
	; PROCESS_MEMORY_COUNTERS: two DWORDs, then SIZE_T fields, the second of
	; which is the working set
	Size := 8 + 8 * A_PtrSize
	Counters := Buffer(Size, 0)
	NumPut("UInt", Size, Counters, 0)
	if !DllCall("K32GetProcessMemoryInfo", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "Ptr", Counters, "UInt", Size)
		throw OSError(A_LastError, -1, "K32GetProcessMemoryInfo")
	return NumGet(Counters, 8 + A_PtrSize, "UPtr")
}

; The Windows name of the user's locale, such as "fr-FR".
; @returns {String}
_HealthCheck_LocaleName() {
	Name := Buffer(85 * 2, 0)
	if !DllCall("GetUserDefaultLocaleName", "Ptr", Name, "Int", 85)
		throw OSError(A_LastError, -1, "GetUserDefaultLocaleName")
	return StrGet(Name, "UTF-16")
}

; The process names of the visible windows (opt-in).
; @returns {Array} Sorted, one entry per process.
_HealthCheck_RunningApps() {
	Seen := Map()
	for Info in WIGetAll() {
		if (Info["windowTitle"] != "")
			Seen[Info["appId"]] := true
	}
	Names := ""
	for Name in Seen
		Names .= (Names == "" ? "" : "`n") . Name
	Sorted := (Names == "") ? [] : StrSplit(Sort(Names, "C"), "`n")
	return Sorted
}

; The system section and its load.
; @param Detailed {Boolean} Whether the user ticked "Include details".
; @param UptimeSec {Integer}
; @returns {Map}
_HealthCheck_System(Detailed, UptimeSec) {
	System := Map()
	OsInfo := DiagSnapshot_OsInfo()
	System["os"] := Trim(OsInfo["os"] . " " . OsInfo["os_version"])
	_HealthCheck_Put(System, "locale", _HealthCheck_Read("the locale", _HealthCheck_LocaleName))
	Hkl := IsSet(KS_ResolveKeyboardLayout) ? KS_ResolveKeyboardLayout() : 0
	if Hkl
		System["keyboard_layout"] := Format("0x{:08X}", Hkl & 0xFFFFFFFF)
	Memory := _HealthCheck_Read("the memory", _HealthCheck_Memory)
	if (Memory is Map)
		System["ram_free"] := Memory["free"]
	LogsDir := _HealthCheck_Dirname(_HealthCheck_ErrorsLogPath())
	if (LogsDir != "") {
		FreeMb := _HealthCheck_Read("the free disk space", () => DriveGetSpaceFree(LogsDir))
		if IsNumber(FreeMb)
			System["disk_free"] := FreeMb * 1048576
	}
	ProcessMemory := _HealthCheck_Read("the ErgoptiPlus memory", _HealthCheck_ProcessMemory)
	if IsInteger(ProcessMemory)
		System["process_memory"] := ProcessMemory
	System["uptime"] := UptimeSec
	System["elevated"] := A_IsAdmin ? true : false
	if Detailed {
		Apps := _HealthCheck_Read("the open applications", _HealthCheck_RunningApps)
		if (Apps is Array)
			System["running_apps"] := Apps
	}
	return System
}





; =========================================
; =========================================
; ======= 5/ Input, Features And AI =======
; =========================================
; =========================================

; The keyboard state at this instant.
; @returns {Map}
_HealthCheck_Input() {
	return Map(
		"paused",    A_IsSuspended ? true : false,
		"shift",     KS_IsDown("Shift") ? true : false,
		"ctrl",      KS_IsDown("Ctrl") ? true : false,
		"alt",       KS_IsDown("LAlt") ? true : false,
		"altgr",     KS_IsDown(KS_AltGrKeyName()) ? true : false,
		"meta",      (KS_IsDown("LWin") || KS_IsDown("RWin")) ? true : false,
		; The lock state, not the key: "T" is the toggle
		"caps_lock", GetKeyState("CapsLock", "T") ? true : false)
}

; The feature switches this driver can answer, as { id, enabled } items.
; @param LlmSnapshotFn {Func|Integer} LLM owner snapshot (tests replace it).
; @param KeyloggerSnapshotFn {Func|Integer} Keylogger owner snapshot.
; @returns {Map} { items: Array }
_HealthCheck_Features(LlmSnapshotFn := 0, KeyloggerSnapshotFn := 0) {
	global Features
	Items := []
	for Id, Category in Map("hotstrings", "Hotstrings", "shortcuts", "Shortcuts", "tapholds", "TapHolds",
		"layout", "Layout")
		Items.Push(Map("id", Id, "enabled", IsCategoryGated(Category) ? true : false))
	if (IsSet(Features) && Features is Map && Features.Has("gestures") && Features["gestures"] is Map)
		Items.Push(Map("id", "gestures", "enabled", Features["gestures"].Get("enabled", false) ? true : false))
	Llm := _HealthCheck_LlmOwner(LlmSnapshotFn)
	if (Llm is Map)
		Items.Push(Map("id", "llm", "enabled", Llm["enabled"] ? true : false))
	if !HasMethod(KeyloggerSnapshotFn, "Call") && IsSet(KL_HealthSnapshot)
		KeyloggerSnapshotFn := KL_HealthSnapshot
	if HasMethod(KeyloggerSnapshotFn, "Call") {
		Owner := KeyloggerSnapshotFn.Call()
		if (Owner is Map && Owner.Has("enabled"))
			Items.Push(Map("id", "metrics", "enabled", Owner["enabled"] ? true : false))
	}
	return Map("items", Items)
}

; The published LLM menu owner snapshot, or 0 before it is loaded.
; @param SnapshotFn {Func|Integer}
; @returns {Map|Integer}
_HealthCheck_LlmOwner(SnapshotFn := 0) {
	if !HasMethod(SnapshotFn, "Call") && IsSet(LLM_Menu_HealthSnapshot)
		SnapshotFn := LLM_Menu_HealthSnapshot
	if !HasMethod(SnapshotFn, "Call")
		return 0
	Owner := SnapshotFn.Call()
	if !(Owner is Map) || !Owner.Get("available", false)
		return 0
	for Key in ["enabled", "backend", "profile_id", "model"] {
		if !Owner.Has(Key)
			throw Error("LLM health snapshot is missing '" . Key . "'.")
	}
	return Owner
}

; The AI section: the switch, the backend, the model and the profile.
; @param SnapshotFn {Func|Integer} LLM owner snapshot (tests replace it).
; @returns {Map}
_HealthCheck_Ai(SnapshotFn := 0) {
	Ai := Map()
	Owner := _HealthCheck_LlmOwner(SnapshotFn)
	if !(Owner is Map)
		return Ai
	Ai["ai_enabled"] := Owner["enabled"] ? true : false
	_HealthCheck_Put(Ai, "ai_backend", String(Owner["backend"]))
	_HealthCheck_Put(Ai, "ai_model", String(Owner["model"]))
	_HealthCheck_Put(Ai, "ai_profile", String(Owner["profile_id"]))
	return Ai
}





; ==========================
; ==========================
; ======= 6/ Devices =======
; ==========================
; ==========================

; The interface path of one raw input device.
; @param Handle {Integer}
; @returns {String}
_HealthCheck_RawInputName(Handle) {
	global HC_RIDI_DEVICENAME
	Chars := 0
	DllCall("GetRawInputDeviceInfoW", "Ptr", Handle, "UInt", HC_RIDI_DEVICENAME, "Ptr", 0, "UInt*", &Chars)
	if (Chars = 0)
		return ""
	Name := Buffer(Chars * 2, 0)
	if (DllCall("GetRawInputDeviceInfoW", "Ptr", Handle, "UInt", HC_RIDI_DEVICENAME, "Ptr", Name
		, "UInt*", &Chars, "Int") < 0)
		return ""
	return StrGet(Name, "UTF-16")
}

; The product name a HID device reports (opt-in).
; @param Path {String} The device interface path.
; @returns {String} "" when the device does not answer.
_HealthCheck_HidProductName(Path) {
	; Zero access rights: the product string needs no read or write access, so
	; nothing is opened for input
	Handle := DllCall("CreateFileW", "Str", Path, "UInt", 0, "UInt", 3, "Ptr", 0, "UInt", 3, "UInt", 0
		, "Ptr", 0, "Ptr")
	if (Handle = -1)
		return ""
	try {
		Name := Buffer(512, 0)
		if !DllCall("hid\HidD_GetProductString", "Ptr", Handle, "Ptr", Name, "UInt", Name.Size)
			return ""
		return Trim(StrGet(Name, "UTF-16"))
	} finally {
		DllCall("CloseHandle", "Ptr", Handle)
	}
}

; One device's bus, from its interface path.
; @param Path {String}
; @returns {String} "usb", "bluetooth", "internal" or "other".
_HealthCheck_DeviceBus(Path) {
	if RegExMatch(Path, "i)BTHENUM|BTHLE|\{00001124-0000-1000-8000-00805f9b34fb\}")
		return "bluetooth"
	if RegExMatch(Path, "i)VID_[0-9A-F]{4}")
		return "usb"
	if RegExMatch(Path, "i)^\\\\\?\\(ACPI|HID#(ELAN|SYNA|MSFT|CONVERTEDDEVICE))")
		return "internal"
	return "other"
}

; The keyboards and mice Windows sees: bus, kind and ids, and their names only
; when the user ticked "Include details". The interface path carries a device
; instance id, so only its vendor and product ids are kept.
; @param Detailed {Boolean}
; @returns {Map} { items: Array }
_HealthCheck_Peripherals(Detailed) {
	Size := A_PtrSize * 2
	Count := 0
	DllCall("GetRawInputDeviceList", "Ptr", 0, "UInt*", &Count, "UInt", Size)
	Items := []
	if (Count = 0)
		return Map("items", Items)
	List := Buffer(Count * Size, 0)
	Count := DllCall("GetRawInputDeviceList", "Ptr", List, "UInt*", &Count, "UInt", Size, "Int")
	if (Count < 0)
		throw OSError(A_LastError, -1, "GetRawInputDeviceList")
	Loop Count {
		Offset := (A_Index - 1) * Size
		Type := NumGet(List, Offset + A_PtrSize, "UInt")
		; 0 = mouse, 1 = keyboard; generic HID devices are neither
		if (Type > 1)
			continue
		Path := _HealthCheck_RawInputName(NumGet(List, Offset, "Ptr"))
		if (Path == "")
			continue
		Item := Map("bus", _HealthCheck_DeviceBus(Path), "kind", (Type = 1) ? "keyboard" : "mouse")
		if RegExMatch(Path, "i)VID_([0-9A-F]{4})", &Vid)
			Item["vendor_id"] := StrLower(Vid[1])
		if RegExMatch(Path, "i)PID_([0-9A-F]{4})", &Pid)
			Item["product_id"] := StrLower(Pid[1])
		if Detailed {
			Name := _HealthCheck_HidProductName(Path)
			if (Name != "")
				Item["name"] := Name
		}
		Items.Push(Item)
	}
	return Map("items", Items)
}





; ================================
; ================================
; ======= 7/ Recent Issues =======
; ================================
; ================================

; Extracts the last N WARNING and ERROR lines from the in-memory ring buffer:
; the fallback of _HealthCheck_RecentIssues when today's errors file does not
; exist yet.
_HealthCheck_RingIssues(MaxLines) {
	All    := LoggerRingBufferSnapshot()
	Issues := []
	for _, Line in All {
		if InStr(Line, "[WARNING]") or InStr(Line, "[ERROR]")
			Issues.Push(Line)
	}
	; Return only the last MaxLines entries
	if Issues.Length <= MaxLines
		return Issues
	Result := []
	Start  := Issues.Length - MaxLines + 1
	loop MaxLines {
		Result.Push(Issues[Start + A_Index - 1])
	}
	return Result
}

; Loads the recent-issue bounds shared by the three drivers.
; Read once: a file of the shared tree, not a setting, whose parse took 1.6 ms
; of phase A's 5 ms on every opening.
; @returns {Map} { tail_max_bytes, max_entries }
; @throws {ValueError} When the shared file is missing a positive integer bound.
_HealthCheck_RecentIssueLimits() {
	global _SharedDir
	static Loaded := 0
	if (Loaded is Map)
		return Loaded
	Path := _SharedDir . "\modules\diagnostics\recent_issues.json"
	Data := JsonParse(FileRead(Path, "UTF-8"))
	Limits := Map(
		"tail_max_bytes", Data.Get("errors_tail_max_bytes", 0),
		"max_entries",    Data.Get("max_entries", 0))
	for Name, Value in Limits {
		if !(Value is Integer) || Value < 1
			throw ValueError("Recent issue limit '" . Name . "' must be a positive integer in " . Path . ".")
	}
	Loaded := Limits
	return Limits
}

; Reads at most MaxBytes from the end of a file, as raw bytes decoded as UTF-8.
; @param Path {String}
; @param MaxBytes {Integer}
; @returns {Map|Integer} { chunk, at_file_start }, or 0 when the file does not exist.
_HealthCheck_ReadTail(Path, MaxBytes) {
	if !FileExist(Path)
		return 0
	; UTF-8-RAW: positions are bytes and no byte order mark is skipped, so the
	; offset below is exact and the parser sees the file as written
	File := FileOpen(Path, "r", "UTF-8-RAW")
	try {
		Size := File.Length
		Start := Max(0, Size - MaxBytes)
		File.Pos := Start
		Bytes := Buffer(Max(1, Size - Start))
		Read := File.RawRead(Bytes, Size - Start)
	} finally {
		File.Close()
	}
	return Map("chunk", _HealthCheck_DecodeTail(Bytes, Read), "at_file_start", Start == 0)
}

; Decodes tail bytes as UTF-8. A read that began inside a sequence decodes its
; first bytes to U+FFFD, on the first line the parser always drops.
; @param Bytes {Buffer}
; @param Length {Integer} Byte count.
; @returns {String}
_HealthCheck_DecodeTail(Bytes, Length) {
	return (Length > 0) ? StrGet(Bytes, Length, "UTF-8") : ""
}

; Turns the tail of an errors file into its WARNING and ERROR entries: the AHK
; copy of the shared parse_errors_tail (_shared/lua/healthcheck/snapshot.lua),
; pinned by _shared/tests/corpus/healthcheck/errors_tail_vectors.json.
; @param Chunk {String} Text read from the end of the file.
; @param AtFileStart {Boolean} True when the read began at byte 0.
; @param MaxEntries {Integer} How many of the newest entries to keep.
; @returns {Array} Entries, oldest first.
_HealthCheck_ParseErrorsTail(Chunk, AtFileStart, MaxEntries) {
	Text := Chunk
	if (AtFileStart && SubStr(Text, 1, 1) == Chr(0xFEFF))
		Text := SubStr(Text, 2)
	Text := StrReplace(StrReplace(Text, "`r`n", "`n"), "`r", "`n")
	Entries := []
	; Index of the entry continuation lines join; -1 inside an entry of another
	; level, 0 before the first entry
	Current := 0
	for Index, Line in StrSplit(Text, "`n") {
		; A read that did not start at byte 0 began inside a line
		if ((Index == 1 && !AtFileStart) || Line == "")
			continue
		if RegExMatch(Line, "^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}:\d{3} \[([A-Z]+)\] ", &Match) {
			if (Match[1] == "WARNING" || Match[1] == "ERROR") {
				Entries.Push(Line)
				Current := Entries.Length
			} else {
				Current := -1
			}
		} else if (Current > 0) {
			Entries[Current] := Entries[Current] . "`n" . Line
		}
	}
	if (Entries.Length <= MaxEntries)
		return Entries
	Newest := []
	Loop MaxEntries
		Newest.Push(Entries[Entries.Length - MaxEntries + A_Index])
	return Newest
}

; Today's errors file, as the logger names it: the one accessor the healthcheck
; reads it through, so the logs-folder owner can move it.
; @returns {String} "" before the logger has resolved its paths.
_HealthCheck_ErrorsLogPath() {
	return LoggerTodayErrorsPath()
}

; The window's recent warnings and errors: the tail of today's errors file, or
; the ring when that file does not exist yet. The ring holds every level, so at
; DEBUG a few minutes of routine lines evicted the problems the window is
; opened to show; the errors file keeps WARNING and ERROR only.
; @param ErrorsPath {String} Today's errors file ("" when the logger has none).
; @returns {Map} { entries: Array oldest first, source: "errors_file" | "ring" }
_HealthCheck_RecentIssues(ErrorsPath) {
	Limits := _HealthCheck_RecentIssueLimits()
	Tail := (ErrorsPath != "") ? _HealthCheck_ReadTail(ErrorsPath, Limits["tail_max_bytes"]) : 0
	if (Tail is Map) {
		return Map(
			"entries", _HealthCheck_ParseErrorsTail(Tail["chunk"], Tail["at_file_start"], Limits["max_entries"]),
			"source",  "errors_file")
	}
	return Map("entries", _HealthCheck_RingIssues(Limits["max_entries"]), "source", "ring")
}
