; tests/support/filesystem_write_lock.ahk

; ==============================================================================
; MODULE: Native Filesystem Write Lock Fixture
; DESCRIPTION:
; A second real handle holds a shared byte-range lock that denies writes while
; allowing reads. This exposes text-buffer acceptance without mocking File.Write.
; ==============================================================================

#Requires AutoHotkey v2.0

class _FSWL_Lock {
	__New() {
		this.Handle := -1
		this.Overlap := Buffer(A_PtrSize = 8 ? 32 : 20, 0)
		this.Acquired := false
	}

	Open(Path, Mode, Encoding) {
		File := FileOpen(Path, Mode, Encoding)
		try {
			this.Handle := DllCall("CreateFileW", "Str", Path, "UInt", 0x80000000,
				"UInt", 7, "Ptr", 0, "UInt", 3, "UInt", 128, "Ptr", 0, "Ptr")
			if this.Handle = -1
				throw OSError()
			this.Acquired := DllCall("LockFileEx", "Ptr", this.Handle, "UInt", 1,
				"UInt", 0, "UInt", 8192, "UInt", 0, "Ptr", this.Overlap, "Int") != 0
			if !this.Acquired
				throw OSError()
			return File
		} catch as Err {
			File.Close()
			throw Err
		}
	}

	Release() {
		if this.Handle = -1
			return
		try {
			if this.Acquired && !DllCall("UnlockFileEx", "Ptr", this.Handle,
				"UInt", 0, "UInt", 8192, "UInt", 0, "Ptr", this.Overlap, "Int")
				throw OSError()
		} finally {
			Handle := this.Handle
			this.Handle := -1
			if !DllCall("CloseHandle", "Ptr", Handle, "Int")
				throw OSError()
		}
	}
}

_FSWL_Path() {
	static Serial := 0
	Serial += 1
	Path := A_Temp . "\ergopti_native_write_" . A_ScriptHwnd . "_" . Serial . ".tmp"
	if FileExist(Path)
		throw Error("Native write fixture path already exists.")
	return Path
}
