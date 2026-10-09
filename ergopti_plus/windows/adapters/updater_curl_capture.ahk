; adapters/updater_curl_capture.ahk
; Native retained-handle operations for private updater capture ownership.

; A capture is allocated by the parent before a native curl child can exist.
; Retained metadata handles keep original identities allocated while allowing
; curl and the completed reader their existing sharing modes.
class _UpdaterCurlCaptureLedger {
	__New() {
		this.Path := ""
		this.Directory := 0
		this.Files := Map()
		this.Worker := 0
		this.NativeState := 0
		this.Acquiring := false
		this.ProbeCloseDebt := []
		this.Running := false
		this.Retired := false
	}
	Acquire(Parent) {
		if this.Path != "" || this.Retired || this.Acquiring
			throw Error("Curl capture has already been initialized.")
		; Cancellation may interrupt any native allocation. Publish the latch
		; first; the immutable object key retains debt before a path exists.
		this.Acquiring := true
		try {
			Parent := RTrim(Parent, "\")
			DirCreate(Parent)
			Guid := Buffer(16, 0)
			if DllCall("ole32\CoCreateGuid", "Ptr", Guid, "Int") != 0
				throw Error("Curl capture identity allocation refused.")
			Nonce := ""
			loop 16
				Nonce .= Format("{:02x}", NumGet(Guid, A_Index - 1, "UChar"))
			Candidate := Parent . "\curl." . Nonce
			if !DllCall("kernel32\CreateDirectoryW", "Str", Candidate, "Ptr", 0, "Int")
				throw OSError(A_LastError, "Curl capture directory allocation refused.")
			this.Path := Candidate
			this.Directory := Map("path", Candidate, "handle", 0, "directory", true)
			this.Directory["handle"] := this.Open(Candidate, 0, 3, true)
			if !this.Directory["handle"]
				throw OSError(A_LastError, "Curl capture directory identity refused.")
			for Name in ["artifact.bin", "headers.bin", "capability.json", "transport.conf"] {
				Path := Candidate . "\" . Name
				Handle := this.Open(Path, 0, 1, false)
				if !Handle
					throw OSError(A_LastError, "Curl capture exclusive file allocation refused.")
				this.Files[Name] := Map("path", Path, "handle", Handle, "directory", false)
				if !this.Snapshot(Handle).Get("ok", false)
					throw Error("Curl capture file identity refused.")
			}
			return this
		} catch {
			_Updater_RetireCurlCapture(this)
			throw
		} finally this.Acquiring := false
	}
	Attach(Worker) {
		if this.Retired || IsObject(this.Worker) || !IsObject(Worker)
			throw Error("Curl capture worker ownership refused.")
		this.Worker := Worker
	}
	AcquireDirectoryLease(DeleteAccess := false) {
		if !(this.Directory is Map) || !this.Directory.Get("handle", 0) || this.ProbeCloseDebt.Length
			return 0
		Original := this.Snapshot(this.Directory["handle"])
		if !Original.Get("ok", false) || !Original["directory"] || Original["delete_pending"]
			return 0
		; Excluding FILE_SHARE_DELETE fences directory rename for the whole
		; observation/removal, rather than relying on a closed identity probe.
		Lease := this.Open(this.Directory["path"], DeleteAccess ? 0x10000 : 0, 3, true, 3)
		if !Lease
			return 0
		Admitted := false
		try {
			Actual := this.Snapshot(Lease)
			Admitted := this.Same(Original, Actual) && Actual["directory"] && !Actual["delete_pending"]
			return Admitted ? Lease : 0
		} finally {
			if !Admitted
				this.CloseProbe(Lease)
		}
	}
	ValidatePaths() {
		if this.Retired || this.Acquiring || this.Files.Count != 4
			return false
		Lease := this.AcquireDirectoryLease()
		if !Lease
			return false
		try {
			for Name, Entry in this.Files {
				Original := this.Snapshot(Entry["handle"])
				Probe := this.Open(Entry["path"], 0, 3, false, 3)
				if !Probe
					return false
				try {
					Actual := this.Snapshot(Probe)
					if !this.Same(Original, Actual) || Actual["directory"] || Actual["delete_pending"] || Actual["links"] != 1
						return false
				} finally this.CloseProbe(Probe)
				if this.ProbeCloseDebt.Length
					return false
			}
			return true
		} finally {
			if !this.CloseProbe(Lease)
				throw Error("Curl capture namespace lease closure was refused.")
		}
	}
	OnNativeAdopt(State, Native) {
		if !(State is Map) || !(Native is Map) || !(Native.Get("Assigned", false))
			throw Error("Curl capture native owner was refused.")
		this.NativeState := State
	}
	ObserveBody(Worker, ExpectedSize) {
		if this.Retired || this.Worker != Worker || !IsObject(Worker)
			|| !HasMethod(Worker, "processId") || Worker.processId() <= 0
			|| !this.Files.Has("artifact.bin") || !(ExpectedSize is Integer) || ExpectedSize <= 0
			return 0
		State := this.NativeState
		if !(State is Map) || State.Get("TerminalClaimed", true) || State.Get("TreeQuiesced", true)
			|| !State.Get("ProcessHandle", 0) || !State.Get("JobHandle", 0)
			return 0
		ErrorText := ""
		if _SR_TreeProcessHasExited(State["ProcessHandle"], &ErrorText) || ErrorText != ""
			|| _SR_TreeActiveProcessCount(State["JobHandle"], &ErrorText) <= 0 || ErrorText != ""
			return 0
		Lease := this.AcquireDirectoryLease()
		if !Lease
			return 0
		try {
			Entry := this.Files["artifact.bin"]
			Original := this.Snapshot(Entry["handle"])
			Probe := this.Open(Entry["path"], 0, 3, false, 3)
			if !Probe
				return 0
			try {
				Actual := this.Snapshot(Probe)
				if !this.Same(Original, Actual) || Actual["directory"] || Actual["delete_pending"] || Actual["links"] != 1
					|| Actual["size"] <= 0 || Actual["size"] >= ExpectedSize
					return 0
				return Actual["size"]
			} finally {
				if !this.CloseProbe(Probe)
					throw Error("Curl capture observer handle closure was refused.")
			}
		} finally {
			if !this.CloseProbe(Lease)
				throw Error("Curl capture namespace lease closure was refused.")
		}
	}

	Retire() {
		if this.Retired
			return true
		if this.Running || this.Acquiring || this.ProbeCloseDebt.Length
			return false
		this.Running := true
		try {
			; This is the actual tree-owned handle, retained even after the public
			; transaction retires. A refusal cannot authorize any file deletion.
			if IsObject(this.Worker) && !this.Worker.terminate()
				return false
			if this.Directory is Map {
				Lease := this.AcquireDirectoryLease(true)
				if !Lease
					return false
				try {
					Complete := true
					for Name, Entry in this.Files
						if !this.RetireEntry(Entry)
							Complete := false
					if !Complete || this.ProbeCloseDebt.Length
						return false
					; Remove the exact admitted directory through the still-held
					; DELETE-capable lease; never release and re-resolve its name.
					Disposition := Buffer(1, 1)
					if !DllCall("kernel32\SetFileInformationByHandle", "Ptr", Lease,
						"Int", 4, "Ptr", Disposition, "UInt", 1, "Int")
						return false
					if !DllCall("kernel32\CloseHandle", "Ptr", this.Directory["handle"], "Int")
						return false
					this.Directory["handle"] := 0
					this.Directory["retired"] := true
				} finally this.CloseProbe(Lease)
			} else if this.Files.Count != 0
				return false
			if this.ProbeCloseDebt.Length
				return false
			this.Worker := 0
			this.Retired := true
			return true
		} finally this.Running := false
	}
	Open(Path, Access, Disposition, Directory, Sharing := 7) {
		Handle := DllCall("kernel32\CreateFileW", "Str", Path, "UInt", Access,
			"UInt", Sharing, "Ptr", 0, "UInt", Disposition,
			"UInt", 0x00200000 | (Directory ? 0x02000000 : 0x80), "Ptr", 0, "Ptr")
		return Handle == -1 ? 0 : Handle
	}
	Snapshot(Handle) {
		Info := Buffer(52, 0)
		if !Handle || !DllCall("kernel32\GetFileInformationByHandle", "Ptr", Handle, "Ptr", Info, "Int")
			return Map("ok", false)
		Standard := Buffer(24, 0)
		if !DllCall("kernel32\GetFileInformationByHandleEx", "Ptr", Handle, "Int", 1, "Ptr", Standard, "UInt", 24, "Int")
			return Map("ok", false)
		Attributes := NumGet(Info, 0, "UInt")
		if Attributes & 0x400
			return Map("ok", false)
		return Map("ok", true, "directory", (Attributes & 0x10) != 0,
			"delete_pending", NumGet(Standard, 20, "UChar") != 0,
			"volume", NumGet(Info, 28, "UInt"), "index_high", NumGet(Info, 44, "UInt"),
			"index_low", NumGet(Info, 48, "UInt"),
			"links", NumGet(Info, 40, "UInt"),
			"size", (NumGet(Info, 32, "UInt") << 32) | NumGet(Info, 36, "UInt"))
	}
	Same(Original, Actual) {
		if !Original.Get("ok", false) || !Actual.Get("ok", false)
			return false
		for Key in ["directory", "volume", "index_high", "index_low"]
			if Original[Key] != Actual[Key]
				return false
		return true
	}
	CloseProbe(Handle) {
		if DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int")
			return true
		; Keep the exact failed native reference as debt; an unknown close cannot
		; authorize removal or a later transaction. Never guess handle reuse.
		this.ProbeCloseDebt.Push(Handle)
		return false
	}
	RetireEntry(Entry) {
		if Entry.Get("retired", false)
			return true
		if !Entry["handle"]
			return false
		Original := this.Snapshot(Entry["handle"])
		if !Original.Get("ok", false) || Original["directory"] != Entry["directory"]
			|| (!Original["directory"] && Original["links"] != 1)
			return false
		Probe := this.Open(Entry["path"], 0x10000, 3, Entry["directory"], 3)
		NativeError := A_LastError
		if !Probe {
			if (NativeError != 2 && NativeError != 3) || !Original["delete_pending"]
				return false
		} else {
			try {
				if !this.Same(Original, this.Snapshot(Probe))
					return false
				Disposition := Buffer(1, 1)
				if !DllCall("kernel32\SetFileInformationByHandle", "Ptr", Probe,
					"Int", 4, "Ptr", Disposition, "UInt", 1, "Int")
					return false
			} finally this.CloseProbe(Probe)
			if this.ProbeCloseDebt.Length
				return false
		}
		if !DllCall("kernel32\CloseHandle", "Ptr", Entry["handle"], "Int")
			return false
		Entry["handle"] := 0
		Entry["retired"] := true
		return true
	}
}

