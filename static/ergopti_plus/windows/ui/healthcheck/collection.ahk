; ui/healthcheck/collection.ahk

; ==============================================================================
; MODULE: Bounded Windows Diagnostic Collection
; DESCRIPTION:
; Retains one local collection owner across Diagnostics close/reopen. An owned
; PowerShell Job emits technical receipts and an archive without developer tools.
; Guided physical input stays in an explicit synthetic Edit; only equality and
; named modifier transitions are retained, never arbitrary text or keystrokes.
; ==============================================================================

#Requires AutoHotkey v2.0

global _HC_Collection := 0
global _HC_CollectionCreating := false

/** Starts a new session only after the previous native task has retired. */
HealthCheck_CollectWindows() {
	global _HC_Collection, _HC_CollectionCreating
	PreviousCritical := Critical("On")
	try {
		if _HC_CollectionCreating || (IsObject(_HC_Collection) && !_HC_Collection.Terminal)
			return false
		_HC_CollectionCreating := true
	} finally Critical(PreviousCritical)
	try _HC_Collection := DiagnosticCollectionWindows()
	finally _HC_CollectionCreating := false
	return _HC_Collection.Start()
}

/** Retains control/cleanup ownership independently of a WebView epoch. */
class DiagnosticCollectionWindows {
	__New() {
		global _SharedDir, _VendorDir
		this.ContractPath := _SharedDir . "\modules\diagnostics\collection.json"
		if FileGetSize(this.ContractPath) > 262144
			throw Error("Diagnostic collection contract exceeded its bound.")
		this.Contract := JsonParse(FileRead(this.ContractPath, "UTF-8"))
		if this.Contract.Get("schema_version", 0) != 1
			throw Error("Unsupported diagnostic collection contract.")
		this.Worker := _VendorDir . "\ergopti_diagnostics.ps1"
		Id := Buffer(16, 0)
		if DllCall("Ole32\CoCreateGuid", "Ptr", Id, "Int") != 0
			throw Error("Diagnostic session identity allocation failed.")
		Hex := ""
		loop Id.Size
			Hex .= Format("{:02x}", NumGet(Id, A_Index - 1, "UChar"))
		this.Id := "ergopti-diagnostic-" . Hex
		LocalData := EnvGet("LOCALAPPDATA")
		if LocalData == ""
			throw Error("Local diagnostic output directory is unavailable.")
		this.Directory := LocalData . "\ergopti_plus\diagnostics\" . this.Id
		this.Archive := this.Directory . ".zip"
		this.Terminal := false
		this.Cancelled := false
		this.Gui := 0
		this.Result := Map("schema_version", 1, "session_id", this.Id, "phase", "collecting", "completed", 0,
			"total", this.Contract["checks"].Length, "owner_pending", true)
		this.CollectionTimer := ObjBindMethod(this, "Tick")
		this.Started := A_TickCount
		this.Task := 0
		this.CancelTick := 0
		this.ProgressFault := false
		this.ExitCallback := ObjBindMethod(this, "Exit")
		this.ExitArmed := false
	}

	Start() {
		global _VendorDir
		LoggerTrace("DiagnosticsCollection", "Starting bounded local diagnostic collection.")
		try {
			; This refusal must precede the central handler's irreversible driver teardown.
			OnExit(this.ExitCallback, -1)
			this.ExitArmed := true
			DirCreate(this.Directory)
			Identity := DiagSnapshot_CollectionIdentity()
			Identity["schema_version"] := 1
			Identity["contract_path"] := this.ContractPath
			Identity["components"] := [Map("id", "driver", "path", A_ScriptFullPath), Map("id", "runtime", "path", A_AhkPath),
				Map("id", "native_owner", "path", _VendorDir . "\ergopti_nav_owner.dll"),
				Map("id", "native_manifest", "path", _VendorDir . "\ergopti_nav_owner.manifest.json"),
				Map("id", "collector", "path", this.Worker), Map("id", "contract", "path", this.ContractPath)]
			this.Write("request.json", Identity)
			this.Task := ShellRunner_SpawnTreeOwned(A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe",
				["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", this.Worker,
				"-SessionDirectory", this.Directory], ObjBindMethod(this, "Completed"), , , this.Contract["max_output_bytes"], true, true)
			if !this.Task.start()
				throw Error("Diagnostic worker launch refused.")
			SetTimer(this.CollectionTimer, 100)
			this.Publish()
			return true
		} catch as Err {
			this.Result["phase"] := "failed"
			this.Result["archive_created"] := false
			if IsObject(this.Task) && !this.Terminal {
				this.Cancel()
				SetTimer(this.CollectionTimer, 100)
			} else if !this.Terminal {
				this.Terminal := true
				this.Result["owner_pending"] := false
				this.DisarmExit()
				LoggerDone("DiagnosticsCollection", "Diagnostic collection launch failed before worker ownership.")
			}
			LoggerError("DiagnosticsCollection", "Diagnostic worker could not start.")
			this.Publish()
			return false
		}
	}

	Write(Name, Value) {
		Text := _HC_ValueToJson(Value)
		if StrPut(Text, "UTF-8") - 1 > this.Contract["max_output_bytes"]
			throw Error("Diagnostic control payload exceeded its contract.")
		Path := this.Directory . "\" . Name
		File := FileOpen(Path . ".tmp", "w", "UTF-8-RAW")
		try File.Write(Text . "`n")
		finally File.Close()
		FileMove(Path . ".tmp", Path, true)
	}

	Tick(*) {
		if this.Terminal
			return
		if TickElapsed(this.Started) >= this.Contract["deadline_ms"] || A_IsSuspended
			this.Cancel()
		if this.Terminal
			return
		if this.CancelTick && TickElapsed(this.CancelTick) >= this.Contract["retirement_grace_ms"] {
			; This worker never captures input: its exact Job may retire blocked UIA/filesystem calls.
			if !this.Task.requestTerminate() {
				this.Result["phase"] := "cleanup_pending"
				this.Publish()
			}
		}
		if this.Terminal
			return
		Path := this.Directory . "\progress.json"
		if FileExist(Path) {
			try {
				if FileGetSize(Path) > this.Contract["max_output_bytes"]
					throw Error("Diagnostic progress payload exceeded its contract.")
				Value := JsonParse(FileRead(Path, "UTF-8"))
				if !(Value is Map) || Value.Get("session_id", "") != this.Id || Value.Get("schema_version", 0) != 1
					throw Error("Foreign diagnostic progress refused.")
				this.AcceptProgress(Value)
				this.Publish()
			} catch as Err {
				if !this.ProgressFault {
					this.ProgressFault := true
					this.Result["phase"] := "failed"
					this.Result["reason"] := "invalid_progress"
					LoggerError("DiagnosticsCollection", "Diagnostic progress was refused; cancelling the retained worker.")
					this.Cancel()
					this.Publish()
				}
			}
		}
		this.ObserveModifiers()
	}

	/** Refuses cross-session, duplicate or fabricated success progress. */
	Contains(Values, Expected) {
		for Value in Values
			if Value == Expected
				return true
		return false
	}

	AcceptProgress(Value) {
		if this.Terminal
			return false
		if !(Value is Map) || Value.Get("session_id", "") !== this.Id || !(Value.Get("schema_version", 0) is Integer)
			|| Value.Get("schema_version", 0) != 1
			throw Error("Foreign diagnostic progress refused.")
		if !this.Contains(["collecting", "guided", "failed", "completed"], Value.Get("phase", ""))
			throw Error("Invalid diagnostic progress phase.")
		Rows := Value.Get("results", 0)
		if !(Rows is Array) || !(Value.Get("completed", -1) is Integer) || Value["completed"] != Rows.Length
			|| !(Value.Get("total", 0) is Integer) || Value.Get("total", 0) != this.Contract["checks"].Length || Rows.Length > Value["total"]
			throw Error("Invalid diagnostic progress census.")
		Seen := Map()
		for Row in Rows {
			if !(Row is Map) || !this.Contains(this.Contract["checks"], Row.Get("id", "")) || Seen.Has(Row["id"])
				|| !this.Contains(this.Contract["statuses"], Row.Get("status", ""))
				|| !this.Contains(this.Contract["evidence_classes"], Row.Get("evidence_class", ""))
				|| (Row["status"] == "PASS" && Row["evidence_class"] == "unexecuted")
				throw Error("Invalid diagnostic progress result.")
			Seen[Row["id"]] := true
		}
		Projected := Value.Clone()
		Projected["owner_pending"] := true
		Projected["archive_created"] := false
		Projected["folder_available"] := false
		if Projected["phase"] == "completed"
			Projected["phase"] := "retiring"
		if !this.ProgressFault
			this.Result := Projected
		return true
	}

	Cancel() {
		if !this.Cancelled
			this.CancelTick := A_TickCount
		this.Cancelled := true
		try {
			if !this.Terminal && DirExist(this.Directory) && !FileExist(this.Directory . "\cancel")
				this.Write("cancel", Map("session_id", this.Id, "cancellation_requested", true))
		} catch as Err {
			if !this.Result.Get("cancel_control_failed", false)
				LoggerError("DiagnosticsCollection", "Diagnostic cancellation control could not be written; exact worker retirement remains owned.")
			this.Result["cancel_control_failed"] := true
			this.Result["phase"] := "cleanup_pending"
		} finally this.CloseGuided()
		return true
	}

	Completed(ExitCode, Stdout, Stderr) {
		if this.Terminal
			return false
		this.Terminal := true
		this.DisarmExit()
		SetTimer(this.CollectionTimer, 0)
		this.CloseGuided()
		Committed := false
		if Stdout != "" {
			try {
				Ack := JsonParse(Stdout)
				Committed := Ack is Map && Ack.Count == 5 && (Ack.Get("schema_version", 0) is Integer) && Ack.Get("schema_version", 0) == 1
					&& Ack.Get("session_id", "") == this.Id && (Ack.Get("archive_committed", false) is Integer)
					&& Ack.Get("archive_committed", false) == true
					&& (Ack.Get("bytes", 0) is Integer) && Ack.Get("bytes", 0) > 0
					&& Ack.Get("bytes", 0) <= this.Contract["max_archive_bytes"] && RegExMatch(Ack.Get("sha256", ""), "^[0-9a-f]{64}$")
					&& FileExist(this.Archive) && FileGetSize(this.Archive) == Ack["bytes"]
				if Committed
					Committed := CryptoSha256Bytes(FileRead(this.Archive, "RAW")) == Ack["sha256"]
				if Committed
					this.ArchiveDigest := Ack["sha256"]
			} catch as Err {
				LoggerWarn("DiagnosticsCollection", "Diagnostic archive acknowledgement was refused.")
			}
		}
		this.Result["phase"] := ExitCode == 0 && Committed && !this.ProgressFault ? "completed" : "failed"
		this.Result["archive_created"] := Committed
		this.Result["owner_pending"] := false
		this.Result["worker_tree_retired"] := true
		this.Result["folder_available"] := !!DirExist(this.Directory)
		Path := this.Directory . "\archive-error.json"
		if FileExist(Path) {
			try {
				if FileGetSize(Path) > this.Contract["max_output_bytes"]
					throw Error("Diagnostic archive error exceeded its bound.")
				Failure := JsonParse(FileRead(Path, "UTF-8"))
				if Failure is Map && Failure.Get("session_id", "") == this.Id && Failure.Get("reason", "") == "archive_creation_failed"
					this.Result["partial_retained"] := Failure.Get("partial_retained", false) == true
			} catch as Err {
				LoggerWarn("DiagnosticsCollection", "Diagnostic archive error receipt was refused.")
			}
		}
		LoggerDone("DiagnosticsCollection", "Local diagnostic collection retired (exit={1}, archive={2}).", ExitCode, Committed ? 1 : 0)
		this.Publish()
		return true
	}

	/** Retires only this input-free Job before the central shutdown handler runs. */
	Exit(Reason, Code) {
		if this.Terminal
			return 0
		try {
			this.Cancel()
			if IsObject(this.Task) && !this.Task.requestTerminate() {
				LoggerError("DiagnosticsCollection", "Diagnostic worker retirement refused application exit.")
				return 1
			}
			if DirExist(this.Directory)
				this.Write("host-exit.json", Map("schema_version", 1, "session_id", this.Id,
					"status", "SKIP", "reason", "application_exit", "tree_retired", true,
					"archive_acknowledged", this.Result.Get("archive_created", false)))
			return 0
		} catch as Err {
			LoggerError("DiagnosticsCollection", "Diagnostic exit cancellation could not be acknowledged.")
			return 1
		}
	}

	DisarmExit() {
		if this.ExitArmed {
			OnExit(this.ExitCallback, 0)
			this.ExitArmed := false
		}
	}

	Publish() {
		global _HC_WindowEpoch, _HC_Gui
		_HC_Send(_HC_WindowEpoch, _HC_ValueToJson(Map("type", "collection", "collection", this.Result)))
		if IsSet(_HC_Gui) && _HC_Gui.HasProp("NativeCollection") && WMHandleExists(_HC_Gui.Hwnd)
			_HC_NativeCollectionUpdate(_HC_Gui)
	}

	OpenFolder() {
		if !this.Terminal
			return false
		if !this.Result.Get("archive_created", false) {
			if !this.Result.Get("folder_available", false) || !DirExist(this.Directory)
				return false
			Run('explorer.exe "' . this.Directory . '"')
			return true
		}
		if !FileExist(this.Archive)
			return false
		if FileGetSize(this.Archive) > this.Contract["max_archive_bytes"]
				|| CryptoSha256Bytes(FileRead(this.Archive, "RAW")) != this.ArchiveDigest {
			LoggerError("DiagnosticsCollection", "Diagnostic archive changed after committed collection.")
			return false
		}
		Run('explorer.exe /select,"' . this.Archive . '"')
		return true
	}

	SkipGuided() {
		if this.Terminal || this.Cancelled
			return false
		this.Write("physical.json", Map("session_id", this.Id, "physical_text", "SKIP", "physical_display", "SKIP"))
		this.CloseGuided()
		return true
	}

	Guided() {
		if this.Terminal || this.Cancelled || IsObject(this.Gui) || this.Result.Get("phase", "") != "guided"
			return false
		G := Gui_Create("", t("healthcheck.collection.start"))
		G.AddText("w560", t("healthcheck.collection.guide") . "`n`n" . this.Contract["fixture"])
		this.Editor := G.AddEdit("w560 r3")
		this.Visual := G.AddCheckbox("w560", t("healthcheck.collection.visual"))
		this.Holds := Map("Ctrl", 0, "Shift", 0)
		G.AddButton("w180", t("common.ok")).OnEvent("Click", ObjBindMethod(this, "SubmitGuided"))
		G.AddButton("x+12 w180", t("common.cancel")).OnEvent("Click", (*) => this.SkipGuided())
		G.OnEvent("Close", (*) => this.SkipGuided())
		G.OnEvent("Escape", (*) => this.SkipGuided())
		this.Gui := G
		G.Show()
		this.Editor.Focus()
		return true
	}

	ObserveModifiers() {
		if !IsObject(this.Gui) || WinExist("A") != this.Gui.Hwnd || this.Gui.FocusedCtrl != this.Editor
			return
		for Key, State in this.Holds {
			Held := GetKeyState(Key, "P")
			if State == 0 && Held
				this.Holds[Key] := 1
			else if State == 1 && !Held
				this.Holds[Key] := 2
		}
	}

	SubmitGuided(*) {
		if !IsObject(this.Gui) || this.Cancelled || this.Terminal
			return false
		Matches := this.Editor.Value == this.Contract["fixture"]
		Modifiers := this.Holds["Ctrl"] == 2 && this.Holds["Shift"] == 2
		this.Write("physical.json", Map("session_id", this.Id,
			"physical_text", Matches && Modifiers ? "PASS" : "FAIL",
			"physical_display", this.Visual.Value ? "PASS" : "SKIP"))
		this.CloseGuided()
		return true
	}

	CloseGuided() {
		if IsObject(this.Gui) {
			this.Gui.Destroy()
			this.Gui := 0
		}
	}
}
