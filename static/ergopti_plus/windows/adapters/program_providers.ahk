; adapters/program_providers.ahk

; ==============================================================================
; MODULE: Native Program Provider Inventory
; DESCRIPTION:
; Bounded Win32 enumeration and PATH resolution. No WMI registry inventory,
; shell expansion, process launch or user-script reads occur during discovery.
; Exact native handles survive refused close and block successor acquisition.
; ==============================================================================

#Include ../../_shared/modules/actions/program_providers.ahk

/** Native inventory lifetime, separate from the owned program execution Job. */
class ProgramProvidersNative {
	__New(RouteFn := 0, PathFn := 0) {
		this.RouteFn := HasMethod(RouteFn, "Call") ? RouteFn : ProgramProviders_ConfigRoute
		this.PathFn := HasMethod(PathFn, "Call") ? PathFn : (*) => EnvGet("PATH")
		this.Debts := []
		this.Busy := false
	}

	Ports() {
		return Map("route", this.RouteFn, "identity", this.Identity.Bind(this),
			"list", this.List.Bind(this), "interpreter", this.Interpreter.Bind(this),
			"retire", this.Retire.Bind(this))
	}

	Retire() {
		if this.Busy
			return false
		this.Busy := true
		try {
			Index := this.Debts.Length
			while Index > 0 {
				Debt := this.Debts[Index]
				if Debt["kind"] == "directory"
					Closed := DllCall("kernel32\FindClose", "Ptr", Debt["handle"], "Int")
				else
					Closed := DllCall("kernel32\CloseHandle", "Ptr", Debt["handle"], "Int")
				if Closed != 0
					this.Debts.RemoveAt(Index)
				Index--
			}
			return this.Debts.Length == 0
		} finally this.Busy := false
	}

	Identity(Path) {
		if !ProgramProviderAbsolute(Path) || !this.Retire()
			throw Error("Program identity unavailable.")
		this.Busy := true
		try {
			; OPEN_REPARSE_POINT excludes final symlinks/app-execution aliases. A
			; directory handle never traverses its children. Parent components remain
			; a cooperative pathname boundary, not an atomic full-route lease.
			PreviousCritical := Critical("On")
			try {
				Handle := DllCall("kernel32\CreateFileW", "Str", Path, "UInt", 0,
					"UInt", 7, "Ptr", 0, "UInt", 3, "UInt", 0x02200000, "Ptr", 0, "Ptr")
				ErrorCode := A_LastError
				if Handle != -1
					this.Debts.Push(Map("kind", "file", "handle", Handle))
			} finally Critical(PreviousCritical)
			if Handle == -1 {
				if ErrorCode == 2 || ErrorCode == 3
					return Map("kind", "missing", "token", "missing")
				throw Error("Program identity unavailable.")
			}
			Info := Buffer(52, 0)
			if !DllCall("kernel32\GetFileInformationByHandle", "Ptr", Handle, "Ptr", Info, "Int")
				throw Error("Program metadata unavailable.")
			Attributes := NumGet(Info, 0, "UInt")
			Kind := Attributes & 0x400 ? "other" : Attributes & 0x10 ? "directory" : "file"
			; Physical file index plus metadata detects rename replacement and normal
			; in-place mutation. It does not claim atomic snapshot-to-execution CAS.
			Token := ""
			for Offset in [0, 4, 8, 20, 24, 28, 32, 36, 44, 48]
				Token .= NumGet(Info, Offset, "UInt") . ":"
			Readable := false, Executable := false
			if Kind == "file" {
				Readable := this._Readable(Path, Info)
				SplitPath(Path, , , &Extension)
				BinaryKind := 0
				if StrLower(Extension) == "exe"
					Executable := DllCall("kernel32\GetBinaryTypeW", "Str", Path, "UInt*", &BinaryKind, "Int")
						&& (BinaryKind == 0 || BinaryKind == 6)
				Readable := this._Readable(Path, Info) && Readable
				After := Buffer(52, 0)
				if !DllCall("kernel32\GetFileInformationByHandle", "Ptr", Handle, "Ptr", After, "Int")
					throw Error("Program metadata unavailable.")
				for Offset in [0, 4, 8, 20, 24, 28, 32, 36, 44, 48]
					if NumGet(Info, Offset, "UInt") != NumGet(After, Offset, "UInt")
						throw Error("Program metadata changed.")
			}
			return Map("kind", Kind, "token", Token, "readable", !!Readable, "executable", !!Executable)
		} finally {
			this.Busy := false
			if !this.Retire()
				throw Error("Program metadata handle retirement refused.")
		}
	}

	_Readable(Path, Expected) {
		; Metadata remains owned while a separate read-access probe is acquired.
		PreviousCritical := Critical("On")
		try {
			Probe := DllCall("kernel32\CreateFileW", "Str", Path, "UInt", 0x80000000,
				"UInt", 7, "Ptr", 0, "UInt", 3, "UInt", 0x00200000, "Ptr", 0, "Ptr")
			ErrorCode := A_LastError
			if Probe != -1
				this.Debts.Push(Map("kind", "file", "handle", Probe))
		} finally Critical(PreviousCritical)
		if Probe == -1 {
			if ErrorCode == 5
				return false
			throw Error("Program read eligibility unavailable.")
		}
		Observed := Buffer(52, 0)
		if !DllCall("kernel32\GetFileInformationByHandle", "Ptr", Probe, "Ptr", Observed, "Int")
			throw Error("Program read probe metadata unavailable.")
		for Offset in [0, 4, 8, 20, 24, 28, 32, 36, 44, 48]
			if NumGet(Expected, Offset, "UInt") != NumGet(Observed, Offset, "UInt")
				throw Error("Program read probe identity changed.")
		return true
	}

	List(Path, Limit) {
		if !ProgramProviderAbsolute(Path) || !this.Retire()
			throw Error("Program directory unavailable.")
		this.Busy := true
		try {
			Data := Buffer(592, 0)
			PreviousCritical := Critical("On")
			try {
				Handle := DllCall("kernel32\FindFirstFileW", "Str", RTrim(Path, "\/") . "\*", "Ptr", Data, "Ptr")
				ErrorCode := A_LastError
				if Handle != -1
					this.Debts.Push(Map("kind", "directory", "handle", Handle))
			} finally Critical(PreviousCritical)
			if Handle == -1 {
				if ErrorCode == 2
					return Map("names", [], "truncated", false)
				throw Error("Program directory enumeration unavailable.")
			}
			Names := [], Truncated := false
			loop {
				Name := StrGet(Data.Ptr + 44, 260, "UTF-16")
				if Name != "." && Name != ".." {
					if Names.Length == Limit {
						Truncated := true
						break
					}
					Names.Push(Name)
				}
				if !DllCall("kernel32\FindNextFileW", "Ptr", Handle, "Ptr", Data, "Int") {
					if A_LastError != 18
						throw Error("Program directory enumeration refused.")
					break
				}
			}
			return Map("names", Names, "truncated", Truncated)
		} finally {
			this.Busy := false
			if !this.Retire()
				throw Error("Program directory handle retirement refused.")
		}
	}

	Interpreter(Commands, ProviderId) {
		PathValue := this.PathFn.Call()
		if !ProgramProviderClean(PathValue) || StrPut(PathValue, "UTF-8") - 1 > ProgramProviderSession.MAX_PATH_BYTES
			throw Error("Program interpreter PATH unavailable.")
		Directories := []
		for Directory in StrSplit(PathValue, ";") {
			; Ignore relative/empty entries: Windows must never search the process's
			; CWD or expand arbitrary environment/shell expressions.
			if ProgramProviderAbsolute(Directory) {
				if Directories.Length == ProgramProviderSession.MAX_PATH_DIRECTORIES
					throw Error("Program interpreter PATH exceeds its bound.")
				Directories.Push(RTrim(Directory, "\/"))
			}
		}
		for Command in Commands {
			for Directory in Directories {
				Requested := Directory . "\" . Command
				Info := this.Identity(Requested)
				if Info["kind"] == "file" && Info["executable"]
					return Map("executable", Requested, "token", Info["token"])
			}

		}
		; A compiled ErgoptiPlus executable is not an AHK interpreter. A real
		; interpreted runtime is admitted only by native regular-image identity.
		if !A_IsCompiled && ProviderId == "autohotkey" {
			Info := this.Identity(A_AhkPath)
			if Info["kind"] == "file" && Info["executable"]
				return Map("executable", A_AhkPath, "token", Info["token"])
		}
		return false
	}
}

ProgramProviders_ConfigRoute() {
	global _ConfigDir
	return IsSet(_ConfigDir) && ProgramProviderAbsolute(_ConfigDir) ? RTrim(_ConfigDir, "\/") . "\scripts" : false
}

ProgramProviders_Create() {
	global _SharedDir
	if !IsSet(_SharedDir)
		return false
	Raw := FSReadUtf8ExactBounded(_SharedDir . "\modules\actions\program_providers.json", ProgramProviderSession.MAX_CATALOGUE_BYTES)
	if !(Raw is String)
		return false
	return ProgramProviderSession(Raw, ProgramProvidersNative().Ports())
}
