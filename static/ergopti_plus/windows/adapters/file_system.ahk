; adapters/file_system.ahk

; ==============================================================================
; MODULE: FileSystem Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the FileSystem port contract defined in
; static/ergopti_plus/_shared/core/ports/FileSystem.spec.js. Wraps AHK v2's
; FileRead, FileOpen, FileExist, and FileDelete built-ins behind the five
; canonical functions (FSRead, FSWrite, FSAppend, FSExists, FSDelete) so
; domain modules perform file I/O without coupling to AHK-specific APIs.
;
; NAMING CONVENTION:
; Port method → AHK name mapping:
;   read(path)           → FSRead(Path)
;   write(path, content) → FSWrite(Path, Content)
;   append(path, content)→ FSAppend(Path, Content)
;   exists(path)         → FSExists(Path)
;   delete(path)         → FSDelete(Path)
;
; ENCODING:
; AHK v2 FileRead and FileOpen default to UTF-8 when the file has a BOM.
; FSRead and FSWrite explicitly pass the "UTF-8" encoding flag to FileOpen
; so all operations are UTF-8 regardless of the system ANSI code page.
; ==============================================================================




; =======================================================
; =======================================================
; ======= 1/ Adapter Methods ============================
; =======================================================
; =======================================================

; Reads the entire contents of a file as a UTF-8 string.
; @param Path {String} Absolute path to the file.
; @return {String|false} File contents on success, false on any error.
FSRead(Path) {
	if !(Path is String) or Path = ""
		return false
	try {
		local FH := FileOpen(Path, "r", "UTF-8-RAW")
		if !IsObject(FH)
			return false
		local Content := FH.Read()
		FH.Close()
		return Content
	} catch {
		return false
	}
}

; Writes content to a file, overwriting any existing content.
; Creates the file if it does not exist.
; @param Path    {String} Absolute path to the file.
; @param Content {String} UTF-8 content to write.
; @return {Boolean} True on success, false on error.
FSWrite(Path, Content) {
	if !(Path is String) or Path = ""
		return false
	if !(Content is String)
		Content := ""
	try {
		local FH := FileOpen(Path, "w", "UTF-8-RAW")
		if !IsObject(FH)
			return false
		FH.Write(Content)
		FH.Close()
		return true
	} catch {
		return false
	}
}

; Writes a complete control artifact and flushes its handle before returning.
; Atomic protocols still validate the stage and publish it with
; FSAtomicMoveReplace; this helper only makes the stage bytes durable.
FSWriteDurable(Path, Content) {
	if !(Path is String) or Path = ""
		return false
	if !(Content is String)
		Content := ""
	FH := 0
	try {
		FH := FileOpen(Path, "w", "UTF-8-RAW")
		if !IsObject(FH)
			return false
		FH.Write(Content)
		return FSFlushFileBuffers(FH)
	} catch {
		return false
	} finally {
		if IsObject(FH)
			try FH.Close()
	}
}

; Creates a private UTF-8 control artifact without ever replacing an existing
; path, then flushes its bytes before reporting success. ``FileOpen(..., "w")``
; cannot express CREATE_NEW and a probe followed by a write is a TOCTOU race,
; so the transaction journal uses this Windows-only helper outside the portable
; FileSystem port. A failed partial creation is removed only when this call
; actually created it; a collision is byte-preserving.
FSWriteCreateDurable(Path, Content) {
	if !(Path is String) or Path = "" or !(Content is String)
		return 0
	static GENERIC_WRITE := 0x40000000
	static CREATE_NEW := 1
	static FILE_ATTRIBUTE_NORMAL := 0x00000080
	static FILE_FLAG_WRITE_THROUGH := 0x80000000
	Handle := -1
	Created := false
	Succeeded := false
	try {
		Handle := DllCall("kernel32\CreateFileW",
			"Str", Path,
			"UInt", GENERIC_WRITE,
			"UInt", 0,
			"Ptr", 0,
			"UInt", CREATE_NEW,
			"UInt", FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH,
			"Ptr", 0,
			"Ptr")
		if (Handle == -1)
			return 0
		Created := true
		ByteCount := StrPut(Content, "UTF-8") - 1
		Utf8 := Buffer(ByteCount + 1, 0)
		if (ByteCount > 0)
			StrPut(Content, Utf8, ByteCount + 1, "UTF-8")
		Offset := 0
		while (Offset < ByteCount) {
			Written := 0
			if !DllCall("kernel32\WriteFile",
					"Ptr", Handle,
					"Ptr", Utf8.Ptr + Offset,
					"UInt", ByteCount - Offset,
					"UInt*", &Written,
					"Ptr", 0,
					"Int") or Written <= 0
				return 0
			Offset += Written
		}
		if !DllCall("kernel32\FlushFileBuffers", "Ptr", Handle, "Int")
			return 0
		Succeeded := true
		return 1
	} catch {
		return 0
	} finally {
		if (Handle != -1)
			try DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int")
		if Created && !Succeeded
			try DllCall("kernel32\DeleteFileW", "Str", Path, "Int")
	}
}

; Flushes one already-open writable file handle to stable storage. Callers use
; this before an atomic rename when the rename itself is a durable protocol
; boundary. The File object owns and closes the handle; this adapter only asks
; Windows to persist its buffered bytes.
FSFlushFileBuffers(FileObject) {
	if !IsObject(FileObject)
		return false
	try return DllCall("FlushFileBuffers", "Ptr", FileObject.Handle,
		"Int") != 0
	catch
		return false
}

; Appends content to a file, creating it if it does not exist.
; @param Path    {String} Absolute path to the file.
; @param Content {String} UTF-8 content to append.
; @return {Boolean} True on success, false on error.
FSAppend(Path, Content) {
	if !(Path is String) or Path = ""
		return false
	if !(Content is String)
		Content := ""
	try {
		local FH := FileOpen(Path, "a", "UTF-8-RAW")
		if !IsObject(FH)
			return false
		FH.Write(Content)
		FH.Close()
		return true
	} catch {
		return false
	}
}

; Returns true if a file or directory exists at the given path, false otherwise.
; @param Path {String} Absolute path to test.
; @return {Boolean} True on success, false on error.
FSExists(Path) {
	if !(Path is String) or Path = ""
		return false
	; FileExist returns a non-empty attribute string on match, "" on miss
	return FileExist(Path) != "" ? true : false
}

; Strict file existence for recovery protocols. Only the two Windows
; not-found statuses mean absence; access, device, or filesystem errors throw
; so recovery never mistakes "could not inspect" for "does not exist".
FSStrictExists(Path) {
	if !(Path is String) or Path = ""
		throw ValueError("A strict existence probe requires a non-empty path.")
	Attributes := DllCall("kernel32\GetFileAttributesW", "Str", Path, "UInt")
	if (Attributes != 0xFFFFFFFF)
		return 1
	ErrorCode := A_LastError
	if (ErrorCode == 2 || ErrorCode == 3)
		return 0
	throw OSError(ErrorCode, A_ThisFunc,
		"GetFileAttributesW failed for '" . Path . "'.")
}

; Deletes a file. Returns true if deleted or already absent, false on error.
; @param Path {String} Absolute path to the file to delete.
; @return {Boolean} True on success, false on error.
FSDelete(Path) {
	if !(Path is String) or Path = ""
		return false
	; Already absent — contract says this is a no-op success
	if !FSExists(Path)
		return true
	try {
		FileDelete(Path)
		return true
	} catch {
		return false
	}
}

; Idempotent strict deletion for recovery protocols. Unlike FSDelete, this
; does not route through FileExist (whose empty result conflates absence with
; an OS probe failure). Non-absence failures are surfaced to the journal.
FSDeleteStrict(Path) {
	if !(Path is String) or Path = ""
		throw ValueError("A strict delete requires a non-empty path.")
	if DllCall("kernel32\DeleteFileW", "Str", Path, "Int")
		return 1
	ErrorCode := A_LastError
	if (ErrorCode == 2 || ErrorCode == 3)
		return 1
	throw OSError(ErrorCode, A_ThisFunc,
		"DeleteFileW failed for '" . Path . "'.")
}

; Returns the current byte length, or -1 when the path is absent/unreadable.
; Kept outside the portable port map for transactional file protocols that must
; validate an artifact without exposing AHK FileGetSize to domain modules.
FSSize(Path) {
	if !(Path is String) or Path = ""
		return -1
	try return FileGetSize(Path)
	catch
		return -1
}

; Reads a small control file only when its size is inside the explicit budget.
; This prevents a malformed sidecar from turning an early-boot capability check
; into an unbounded allocation.
FSReadBounded(Path, MaxBytes) {
	if !(Path is String) or Path = ""
		or !IsNumber(MaxBytes) or MaxBytes <= 0
		return false
	FH := 0
	try {
		FH := FileOpen(Path, "r", "UTF-8-RAW")
		if !IsObject(FH) or FH.Length > MaxBytes
			return false
		; Never issue an unbounded Read after the size probe. The same open handle
		; may grow concurrently; one extra character detects overflow while the
		; UTF-8 byte check preserves the contract for multibyte text.
		Content := FH.Read(MaxBytes + 1)
		if (FH.Pos < FH.Length
			or StrPut(Content, "UTF-8") - 1 > MaxBytes)
			return false
		return Content
	} catch {
		return false
	} finally {
		if IsObject(FH)
			try FH.Close()
	}
}

; Reads a transition target through Win32 without FileOpen's BOM skip. The WAL
; hashes exact UTF-8 byte images, so a leading EF BB BF must survive as U+FEFF
; and malformed/non-canonical UTF-8 must be refused rather than normalized to
; replacement characters. FILE_SHARE_READ excludes concurrent writers while
; the snapshot handle is open.
FSReadUtf8Exact(Path) {
	return _FSReadUtf8ExactImpl(Path, 0, false)
}

FSReadUtf8ExactBounded(Path, MaxBytes) {
	if !(MaxBytes is Integer) || MaxBytes <= 0
		return false
	return _FSReadUtf8ExactImpl(Path, MaxBytes, true)
}

_FSReadUtf8ExactImpl(Path, MaxBytes, Bounded) {
	if !(Path is String) || Path == ""
		return false
	static GENERIC_READ := 0x80000000
	static FILE_SHARE_READ := 0x00000001
	static OPEN_EXISTING := 3
	static FILE_ATTRIBUTE_NORMAL := 0x00000080
	Handle := -1
	try {
		Handle := DllCall("kernel32\CreateFileW",
			"Str", Path,
			"UInt", GENERIC_READ,
			"UInt", FILE_SHARE_READ,
			"Ptr", 0,
			"UInt", OPEN_EXISTING,
			"UInt", FILE_ATTRIBUTE_NORMAL,
			"Ptr", 0,
			"Ptr")
		if Handle == -1
			return false
		ByteCount := 0
		if !DllCall("kernel32\GetFileSizeEx", "Ptr", Handle,
				"Int64*", &ByteCount, "Int")
			return false
		if ByteCount < 0 || ByteCount > 0x7FFFFFFF
			return false
		if Bounded && ByteCount > MaxBytes
			return false
		Raw := Buffer(ByteCount > 0 ? ByteCount : 1, 0)
		Offset := 0
		while Offset < ByteCount {
			Chunk := Min(ByteCount - Offset, 0x7FFFF000)
			ReadCount := 0
			if !DllCall("kernel32\ReadFile",
					"Ptr", Handle,
					"Ptr", Raw.Ptr + Offset,
					"UInt", Chunk,
					"UInt*", &ReadCount,
					"Ptr", 0,
					"Int") || ReadCount <= 0
				return false
			Offset += ReadCount
		}
		FinalSize := 0
		if !DllCall("kernel32\GetFileSizeEx", "Ptr", Handle,
				"Int64*", &FinalSize, "Int") || FinalSize != ByteCount
			return false
		if ByteCount == 0
			return ""
		Content := StrGet(Raw.Ptr, ByteCount, "UTF-8")
		CanonicalCount := StrPut(Content, "UTF-8") - 1
		if CanonicalCount != ByteCount
			return false
		Canonical := Buffer(CanonicalCount + 1, 0)
		StrPut(Content, Canonical, CanonicalCount + 1, "UTF-8")
		MatchingBytes := DllCall("ntdll\RtlCompareMemory",
			"Ptr", Raw, "Ptr", Canonical, "UPtr", ByteCount, "UPtr")
		return MatchingBytes == ByteCount ? Content : false
	} catch {
		return false
	} finally {
		if Handle != -1
			try DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int")
	}
}

; Publishes a complete same-directory stage with one write-through Win32 rename.
; Failure retains Source and leaves Destination untouched.
FSAtomicMoveReplace(Source, Destination) {
	if !(Source is String) or Source = ""
		or !(Destination is String) or Destination = ""
		return false
	static MOVEFILE_REPLACE_EXISTING := 0x00000001
	static MOVEFILE_WRITE_THROUGH := 0x00000008
	try return DllCall("MoveFileExW", "Str", Source, "Str", Destination,
		"UInt", MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
		"Int") != 0
	catch
		return false
}

; Publishes Source only when Destination is still absent. Omitting
; MOVEFILE_REPLACE_EXISTING makes the directory-entry operation atomic and
; collision-preserving; WRITE_THROUGH makes the rename a durable boundary.
FSAtomicMoveCreate(Source, Destination) {
	if !(Source is String) or Source = ""
		or !(Destination is String) or Destination = ""
		return 0
	static MOVEFILE_WRITE_THROUGH := 0x00000008
	try return DllCall("kernel32\MoveFileExW", "Str", Source,
		"Str", Destination, "UInt", MOVEFILE_WRITE_THROUGH, "Int") ? 1 : 0
	catch
		return 0
}

; Atomically replaces Destination with Source when both are on the same volume.
; Kept in the adapter so domain modules never call FileMove directly.
FSMove(Source, Destination, Overwrite := false) {
        if !(Source is String) or Source = "" or !(Destination is String) or Destination = ""
                return false
        try {
                FileMove(Source, Destination, Overwrite)
                return true
        } catch {
                return false
        }
}

; Opens a file for STREAMED reading and hands the handle back.
; FSRead loads a whole file; the at-rest migration walks data.sql, which can be
; hundreds of megabytes, and would have to hold all of it in memory to rewrite
; two columns of a few statements. The handle is UTF-8-RAW so a byte-exact
; passthrough is possible: the byte-order mark, if any, arrives as content and
; leaves as content instead of being stripped on one side and re-added on the
; other.
; @param Path {String} Absolute path to the file.
; @return {Object|String} An AHK file object, or "" on any error.
FSOpenRead(Path) {
	if !(Path is String) or Path = ""
		return ""
	try {
		local FH := FileOpen(Path, "r", "UTF-8-RAW")
		return IsObject(FH) ? FH : ""
	} catch {
		return ""
	}
}

; Opens a file for STREAMED writing, truncating any existing content.
; Counterpart of FSOpenRead; see its note on UTF-8-RAW.
; @param Path {String} Absolute path to the file.
; @return {Object|String} An AHK file object, or "" on any error.
FSOpenWrite(Path) {
	if !(Path is String) or Path = ""
		return ""
	try {
		local FH := FileOpen(Path, "w", "UTF-8-RAW")
		return IsObject(FH) ? FH : ""
	} catch {
		return ""
	}
}

; Returns stable identity, size and write-time metadata for an already-open file
; handle. This Windows-specific helper deliberately stays outside the canonical
; ADAPTER_FILE_SYSTEM port map; it is an implementation boundary used by the
; metrics reader to distinguish append, in-place repair and file replacement.
FSHandleSnapshot(FileHandle) {
	if !FileHandle
		return Map("ok", false)
	try {
		; BY_HANDLE_FILE_INFORMATION is a fixed 52-byte DWORD structure.
		static INFO_BYTES := 52
		local Info := Buffer(INFO_BYTES, 0)
		if !DllCall("kernel32\GetFileInformationByHandle",
			"Ptr", FileHandle,
			"Ptr", Info.Ptr,
			"Int")
			return Map("ok", false)
		return Map(
			"ok", true,
			"write_low", NumGet(Info, 20, "UInt"),
			"write_high", NumGet(Info, 24, "UInt"),
			"volume", NumGet(Info, 28, "UInt"),
			"size", (NumGet(Info, 32, "UInt") << 32)
				| NumGet(Info, 36, "UInt"),
			"index_high", NumGet(Info, 44, "UInt"),
			"index_low", NumGet(Info, 48, "UInt")
		)
	} catch {
		return Map("ok", false)
	}
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_FILE_SYSTEM := Map(
    "read",   FSRead,
    "write",  FSWrite,
    "append", FSAppend,
    "exists", FSExists,
    "delete", FSDelete,
)
