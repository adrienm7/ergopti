; modules/keymap/keylayout/layout_registry_download.ahk

; ==============================================================================
; MODULE: Layout Registry Download Custody
; DESCRIPTION:
; Creates each output exclusively and pins its native identity until the exact
; transfer retires. Read, unlink and rename use one exclusive claimed handle;
; a refused close remains owned and can be retried before request or shutdown.
; ==============================================================================

#Requires AutoHotkey v2.0

_LayoutRegistryDownloadOwners() {
	static Owners := Map()
	return Owners
}

; Retry only retired transfers; active writers keep their creation pin.
LayoutRegistry_RetireDownloads() {
	Owners := []
	WasCritical := Critical("On")
	try {
		for Owner in _LayoutRegistryDownloadOwners()
			Owners.Push(Owner)
	} finally Critical(WasCritical)
	Ready := true
	for Owner in Owners {
		if Owner.Retired {
			; The response belongs to its synchronous consumer until that callback
			; returns. Reentrant admission may only retry abandoned cleanup debt.
			if !Owner.Delivering && !Owner.Remove()
				Ready := false
		} else if HasMethod(Owner.RequestRetirement, "Call") {
			if !_LayoutRegistryRetryDownloadRequest(Owner)
				Ready := false
		}
	}
	return Ready
}

; A refused scheduling boundary must not be the last holder of a request.
; Keep one guarded exact retry until its native Abort has acknowledged retirement.
_LayoutRegistryRetryDownloadRequest(Owner) {
	WasCritical := Critical("On")
	try {
		if Owner.Removed
			return true
		if Owner.ProbingRequest
			return false
		Retry := Owner.RequestRetirement
		if !HasMethod(Retry, "Call")
			return false
		Owner.ProbingRequest := true
	} finally Critical(WasCritical)
	try Retry.Call()
	finally Owner.ProbingRequest := false
	return Owner.Removed || (Owner.Retired && Owner.Remove())
}

LayoutRegistry_PrepareShutdown() {
	Ready := LayoutRegistry_RetireDownloads()
	return Ready && _LayoutRegistryDownloadOwners().Count == 0
}

_LayoutRegistryDownloadCloseNative(Slot) {
	if !DllCall("kernel32\CloseHandle", "Ptr", Slot.Handle, "Int")
		return false
	; The native owner records the ACK before returning to any observer.
	Slot.Handle := -1
	return true
}

_LayoutRegistryDownloadDiscardNative(Owner) {
	Disposition := Buffer(1, 1)
	if !DllCall("kernel32\SetFileInformationByHandle", "Ptr", Owner.Claim.Handle,
		"Int", 4, "Ptr", Disposition, "UInt", 1, "Int")
		return false
	Owner.DispositionCommitted := true
	return true
}

_LayoutRegistryDownloadPublishNative(Owner, Destination) {
	LengthOffset := A_PtrSize == 8 ? 16 : 8
	NameOffset := LengthOffset + 4
	NameBytes := StrPut(Destination, "UTF-16") - 2
	Info := Buffer(NameOffset + NameBytes + 2, 0)
	NumPut("UChar", 1, Info, 0)
	NumPut("UInt", NameBytes, Info, LengthOffset)
	StrPut(Destination, Info.Ptr + NameOffset, NameBytes // 2 + 1, "UTF-16")
	if !DllCall("kernel32\SetFileInformationByHandle", "Ptr", Owner.Claim.Handle,
		"Int", 3, "Ptr", Info, "UInt", Info.Size, "Int")
		return false
	Owner.DispositionCommitted := true
	return true
}

class _LayoutRegistryDownload {
	__New(Path) {
		_FSRequirePath(Path, "A registry download")
		SplitPath(Path, &Name, &Directory)
		this.Path := FSResolveDirectoryPath(Directory == "" ? A_WorkingDir : Directory) . "\" . Name
		this.Pin := 0, this.Claim := 0, this.Expected := 0
		this.Retired := false, this.DispositionCommitted := false, this.Removed := false, this.Operating := true
		this.RequestRetirement := 0, this.ProbingRequest := false, this.Delivering := false
		Owners := _LayoutRegistryDownloadOwners()
		WasCritical := Critical("On")
		try Owners[this] := true
		finally Critical(WasCritical)
		try {
			; GENERIC_READ, share READ|WRITE, CREATE_NEW. The worker's
			; FileMode.Create/FileAccess.Write/FileShare.Read stays compatible,
			; while an ordinary read handle excludes delete and replacement.
			this.Pin := this._Open(0x80000000, 3, 1)
			if this.Pin.Handle == -1 {
				this.Retired := true
				if this._Close(this.Pin)
					this._Forget()
				throw Error("Cannot acquire the registry download stage " . this.Path)
			}
		} catch as Err {
			this.Retired := true
			this.Operating := false
			try {
				if !this.Remove()
					LoggerError("LayoutRegistry", "Stage acquisition retained native cleanup: {1}.", this.Path)
			} catch as CleanupError {
				LoggerError("LayoutRegistry", "Stage acquisition cleanup failed: {1}.", CleanupError.Message)
			}
			throw Err
		} finally this.Operating := false
	}

	_Open(Access, Sharing, Disposition) {
		Slot := {Handle: -1, Activity: FileReadActivityEnter(this.Path), OpeningReturned: false, Validated: false}
		; Publish before native acquisition: an interrupted opening is debt too.
		if Disposition == 1
			this.Pin := Slot
		else
			this.Claim := Slot
		Slot.Handle := DllCall("kernel32\CreateFileW", "Str", this.Path, "UInt", Access,
			"UInt", Sharing, "Ptr", 0, "UInt", Disposition, "UInt", 0x00200080, "Ptr", 0, "Ptr")
		Slot.OpeningReturned := true
		if Slot.Handle != -1
			FileReadActivityBind(Slot.Activity, Slot.Handle)
		return Slot
	}

	_Close(Slot) {
		if !IsObject(Slot)
			return true
		if Slot.Handle != -1 {
			if !_LayoutRegistryDownloadCloseNative(Slot) || Slot.Handle != -1
				return false
		}
		if !Slot.OpeningReturned
			return false
		if IsObject(Slot.Activity) {
			if !FileReadActivityLeave(Slot.Activity)
				return false
			Slot.Activity := 0
		}
		return true
	}

	_Forget() {
		Owners := _LayoutRegistryDownloadOwners()
		WasCritical := Critical("On")
		try {
			if Owners.Has(this)
				Owners.Delete(this)
			this.Removed := true
			this.RequestRetirement := 0
		} finally Critical(WasCritical)
	}

	_Claim() {
		if IsObject(this.Claim) && this.Claim.Handle != -1 && this.Claim.Validated
			return true
		if !IsObject(this.Expected) {
			if !IsObject(this.Pin) || this.Pin.Handle == -1
				return false
			CandidateSnapshot := FSHandleSnapshot(this.Pin.Handle)
			if !CandidateSnapshot.Get("ok", false)
				return false
			this.Expected := CandidateSnapshot
		}
		; Publish claim activity before releasing the pin so terminal admission
		; never sees a false idle gap between those two native handles.
		if IsObject(this.Claim) && !this._Close(this.Claim)
			return false
		Slot := {Handle: -1, Activity: FileReadActivityEnter(this.Path), OpeningReturned: true, Validated: false}
		this.Claim := Slot
		if !this._Close(this.Pin)
			return false
		Slot.OpeningReturned := false
		Slot.Handle := DllCall("kernel32\CreateFileW", "Str", this.Path, "UInt", 0x80010000,
			"UInt", 0, "Ptr", 0, "UInt", 3, "UInt", 0x00200000, "Ptr", 0, "Ptr")
		Slot.OpeningReturned := true
		if Slot.Handle == -1
			return false
		FileReadActivityBind(Slot.Activity, Slot.Handle)
		Actual := FSHandleSnapshot(Slot.Handle)
		if !Actual.Get("ok", false)
			return false
		for Key in ["volume", "index_high", "index_low", "size", "write_high", "write_low"] {
			if this.Expected[Key] != Actual[Key] {
				this._Close(Slot)
				return false
			}
		}
		Slot.Validated := true
		return true
	}

	_Begin() {
		WasCritical := Critical("On")
		try {
			if !this.Retired || this.Removed || this.Operating
				return false
			this.Operating := true
			return true
		} finally Critical(WasCritical)
	}

	ReadText(MaxBytes) {
		if !(MaxBytes is Integer) || MaxBytes <= 0
			throw ValueError("The registry output requires a positive byte bound.")
		if !this._Begin()
			throw Error("The registry output does not own a retired readable transfer.")
		try {
			if this.DispositionCommitted
				throw Error("The registry output has already committed its disposition.")
			if !this._Claim()
				return false
			if !DllCall("kernel32\SetFilePointerEx", "Ptr", this.Claim.Handle,
				"Int64", 0, "Ptr", 0, "UInt", 0, "Int")
				return false
			Text := _FSReadUtf8ExactHandle(this.Claim.Handle, MaxBytes, true)
			; Retain the old FileOpen reader's BOM handling. Publication still
			; renames the exact wire bytes rather than re-encoding this text.
			return Text is String && SubStr(Text, 1, 1) == Chr(0xFEFF) ? SubStr(Text, 2) : Text
		} finally this.Operating := false
	}

	Publish(Destination) {
		_FSRequirePath(Destination, "A registry index publication")
		SplitPath(Destination, &Name, &Directory)
		Destination := FSResolveDirectoryPath(Directory == "" ? A_WorkingDir : Directory) . "\" . Name
		if !this._Begin()
			throw Error("The registry output does not own a retired publishable transfer.")
		try {
			if this.DispositionCommitted
				throw Error("The registry output has already committed its disposition.")
			if !this._Claim()
				return false
			if !_LayoutRegistryDownloadPublishNative(this, Destination)
				return false
			if !this._Close(this.Claim)
				return false
			this._Forget()
			return true
		} finally this.Operating := false
	}

	Remove() {
		if !this._Begin()
			return this.Removed
		try {
			if !this.DispositionCommitted {
				if !this._Claim()
					return false
				if !_LayoutRegistryDownloadDiscardNative(this)
					return false
			}
			if !this._Close(this.Claim) || !this._Close(this.Pin)
				return false
			this._Forget()
			return true
		} finally this.Operating := false
	}
}
