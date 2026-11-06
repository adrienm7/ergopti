; adapters/file_system.ahk

#Include %A_LineFile%\..\..\infra\file_read_activity.ahk
#Include %A_LineFile%\..\file_system_ports.ahk

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

; Windows path APIs, and the AHK built-ins over them, read a caller String
; only up to its first NUL code unit: "a.txt" NUL "x" names a.txt, so a refused
; delete removed that prefix file and a refused read returned its bytes. Every
; entry below admits a path through this check before any native call.
; @param Path {Any} Caller value.
; @return {Boolean} True only for a non-empty String without a NUL code unit.
FSPathIsAdmissible(Path) {
	return Path is String && Path != "" && !RegExMatch(Path, "\x00")
}

; Strict entries refuse an inadmissible path with an exception, as they do for
; every other native failure; the message never repeats the refused bytes.
_FSRequirePath(Path, Operation) {
	if !FSPathIsAdmissible(Path)
		throw ValueError(Operation . " requires a non-empty path without NUL.")
}

; Reads UTF-8 text using AHK's BOM handling and preserves native read failures.
; @param Path {String} File path.
; @return {String} Text contents; throws when the read fails.
FSReadStrict(Path) {
	_FSRequirePath(Path, "A strict read")
	return FileRead(Path, "UTF-8")
}

; Reads a file's raw bytes and preserves native read failures.
; @param Path {String} File path.
; @return {Buffer} The bytes; throws when the read fails.
FSReadBytesStrict(Path) {
	_FSRequirePath(Path, "A strict byte read")
	return FileRead(Path, "RAW")
}

; Opens an owned native file without changing flags, encoding, or failure behavior.
; @param Path {String} File path.
; @param Flags {String|Integer} Native access, sharing and translation flags.
; @param Encoding {String} Optional encoding; omission retains the native default.
; @return {File|0} Native file result; native exceptions remain visible.
FSOpenStrict(Path, Flags, Encoding := unset) {
	_FSRequirePath(Path, "A strict open")
	if IsSet(Encoding)
		return FileOpen(Path, Flags, Encoding)
	return FileOpen(Path, Flags)
}

; Reads the entire contents of a file as a UTF-8 string.
; @param Path {String} Absolute path to the file.
; @return {String|false} File contents on success, false on any error.
FSRead(Path) {
	if !FSPathIsAdmissible(Path)
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
; @param OpenFn   {Func|0} Optional deterministic open seam for tests.
; @param DeleteFn {Func|0} Optional deterministic cleanup seam for tests.
; @param WriteFn  {Func|0} Optional native write seam for tests.
; @return {Boolean} True on success, false on error.
FSWrite(Path, Content, OpenFn := 0, DeleteFn := 0, WriteFn := 0) {
	ResolvedOpen := HasMethod(OpenFn, "Call") ? OpenFn : FileOpen
	ResolvedDelete := HasMethod(DeleteFn, "Call") ? DeleteFn : FileDelete
	return _FSWriteComplete(Path, Content, ResolvedOpen, ResolvedDelete, WriteFn)
}

; Owns a write from the first successful open through either a complete close or
; deletion of the partial artifact. OpenFn/DeleteFn make the short-write boundary
; deterministic in tests without weakening the public FileSystem port.
_FSWriteComplete(Path, Content, OpenFn, DeleteFn, WriteFn := 0) {
	if !FSPathIsAdmissible(Path)
		return false
	if !(Content is String)
		Content := ""
	FH := 0
	Opened := false
	Succeeded := false
	try {
		FH := OpenFn.Call(Path, "w", "UTF-8-RAW")
		if !IsObject(FH)
			return false
		Opened := true
		if !_FSWriteUtf8Bytes(FH, Content, WriteFn)
			return false
		FH.Close()
		FH := 0
		Succeeded := true
		return true
	} catch {
		return false
	} finally {
		if IsObject(FH)
			try FH.Close()
		if Opened && !Succeeded
			try DeleteFn.Call(Path)
	}
}

; Writes a complete control artifact and flushes its handle before returning.
; Atomic protocols still validate the stage and publish it with
; FSAtomicMoveReplace; this helper only makes the stage bytes durable.
FSWriteDurable(Path, Content, OpenFn := 0, DeleteFn := 0, FlushFn := 0, WriteFn := 0) {
	ResolvedOpen := HasMethod(OpenFn, "Call") ? OpenFn : FileOpen
	ResolvedDelete := HasMethod(DeleteFn, "Call") ? DeleteFn : FileDelete
	ResolvedFlush := HasMethod(FlushFn, "Call") ? FlushFn : FSFlushFileBuffers
	return _FSWriteDurableComplete(Path, Content, ResolvedOpen, ResolvedDelete,
		ResolvedFlush, WriteFn)
}

_FSWriteDurableComplete(Path, Content, OpenFn, DeleteFn, FlushFn, WriteFn := 0) {
	if !FSPathIsAdmissible(Path)
		return false
	if !(Content is String)
		Content := ""
	FH := 0
	Opened := false
	Succeeded := false
	try {
		FH := OpenFn.Call(Path, "w", "UTF-8-RAW")
		if !IsObject(FH)
			return false
		Opened := true
		if !_FSWriteUtf8Bytes(FH, Content, WriteFn)
			return false
		if FlushFn.Call(FH) != true
			throw Error("flush failed")
		FH.Close()
		FH := 0
		Succeeded := true
		return true
	} catch {
		return false
	} finally {
		if IsObject(FH)
			try FH.Close()
		if Opened && !Succeeded
			try DeleteFn.Call(Path)
	}
}

; Creates a private UTF-8 control artifact without ever replacing an existing
; path, then flushes its bytes before reporting success. ``FileOpen(..., "w")``
; cannot express CREATE_NEW and a probe followed by a write is a TOCTOU race,
; so the transaction journal uses this Windows-only helper outside the portable
; FileSystem port. A failed partial creation is removed only when this call
; actually created it; a collision is byte-preserving.
FSWriteCreateDurable(Path, Content) {
	if !FSPathIsAdmissible(Path) or !(Content is String)
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

; Creates one new UTF-8 file through the kernel CREATE_NEW admission and
; flushes it before reporting success, so an existing path is never replaced.
; Unlike FSWriteCreateDurable, a partial file is retained on failure: deleting
; its path after the handle closed could delete a successor that took the name.
; @param Path    {String} Absolute path of the file to create.
; @param Content {String} Text to write as UTF-8 without a BOM.
; @returns {Integer|String} 1 once written, flushed and closed; "exists" when
;   the path is already taken; 0 on any other failure.
FSWriteCreateNewDurable(Path, Content) {
	if !FSPathIsAdmissible(Path) || !(Content is String)
		return 0
	static GENERIC_WRITE := 0x40000000
	static CREATE_NEW := 1
	static FILE_ATTRIBUTE_NORMAL := 0x00000080
	static FILE_FLAG_WRITE_THROUGH := 0x80000000
	static ERROR_FILE_EXISTS := 80
	static ERROR_ALREADY_EXISTS := 183
	Handle := -1
	try {
		Handle := DllCall("kernel32\CreateFileW", "Str", Path, "UInt", GENERIC_WRITE,
			"UInt", 0, "Ptr", 0, "UInt", CREATE_NEW, "UInt", FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH,
			"Ptr", 0, "Ptr")
		if Handle == -1 {
			Code := A_LastError
			return (Code == ERROR_FILE_EXISTS || Code == ERROR_ALREADY_EXISTS) ? "exists" : 0
		}
		Count := StrPut(Content, "UTF-8") - 1
		Bytes := Buffer(Count + 1, 0)
		if Count > 0
			StrPut(Content, Bytes, Count + 1, "UTF-8")
		Offset := 0
		while Offset < Count {
			Written := 0
			if !DllCall("kernel32\WriteFile", "Ptr", Handle, "Ptr", Bytes.Ptr + Offset,
				"UInt", Count - Offset, "UInt*", &Written, "Ptr", 0, "Int") || Written <= 0
				return 0
			Offset += Written
		}
		if !DllCall("kernel32\FlushFileBuffers", "Ptr", Handle, "Int")
			return 0
		if !DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int")
			return 0
		Handle := -1
		return 1
	} catch {
		return 0
	} finally {
		if Handle != -1
			try DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int")
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
	return _FSAppendComplete(Path, Content, FileOpen)
}

; Completes an append only when Windows accepts every encoded UTF-8 byte.
; Unlike an overwrite stage, a partially appended user file cannot be safely
; deleted or rolled back, so callers must receive failure and retain ownership.
_FSAppendComplete(Path, Content, OpenFn, WriteFn := 0) {
	if !FSPathIsAdmissible(Path)
		return false
	if !(Content is String)
		Content := ""
	FH := 0
	try {
		FH := OpenFn.Call(Path, "a", "UTF-8-RAW")
		if !IsObject(FH)
			return false
		if !_FSWriteUtf8Bytes(FH, Content, WriteFn)
			return false
		FH.Close()
		FH := 0
		return true
	} catch {
		return false
	} finally {
		if IsObject(FH)
			try FH.Close()
	}
}

; Only use with a newly opened UTF-8 file, before any buffered text writes.
; Both File.Write and RawWrite buffer small blocks; Close and Handle discard
; buffer-flush failures. WriteFile checks the actual OS receipt instead. Keep
; this primitive logger-free so filesystem failures cannot recurse into logging.
_FSWriteUtf8Bytes(FileObject, Content, WriteFn := 0) {
	if FileObject.Encoding != "UTF-8"
		return false
	ByteCount := StrPut(Content, "UTF-8") - 1
	if ByteCount = 0
		return true
	Utf8 := Buffer(ByteCount + 1, 0)
	StrPut(Content, Utf8, ByteCount + 1, "UTF-8")
	Written := 0
	ResolvedWrite := HasMethod(WriteFn, "Call") ? WriteFn : _FSNativeWrite
	return ResolvedWrite.Call(FileObject.Handle, Utf8, ByteCount, &Written)
		&& Written = ByteCount
}

_FSNativeWrite(Handle, Bytes, ByteCount, &Written) {
	return DllCall("WriteFile", "Ptr", Handle, "Ptr", Bytes,
		"UInt", ByteCount, "UInt*", &Written, "Ptr", 0, "Int") != 0
}

; Returns true if a file or directory exists at the given path, false otherwise.
; @param Path {String} Absolute path to test.
; @return {Boolean} True on success, false on error.
FSExists(Path) {
	if !FSPathIsAdmissible(Path)
		return false
	; FileExist returns a non-empty attribute string on match, "" on miss
	return FileExist(Path) != "" ? true : false
}

; Strict file existence for recovery protocols. Only the two Windows
; not-found statuses mean absence; access, device, or filesystem errors throw
; so recovery never mistakes "could not inspect" for "does not exist".
FSStrictExists(Path) {
	if !FSPathIsAdmissible(Path)
		throw ValueError("A strict existence probe requires a non-empty path without NUL.")
	Attributes := DllCall("kernel32\GetFileAttributesW", "Str", Path, "UInt")
	if (Attributes != 0xFFFFFFFF)
		return 1
	ErrorCode := A_LastError
	if (ErrorCode == 2 || ErrorCode == 3)
		return 0
	throw OSError(ErrorCode, A_ThisFunc,
		"GetFileAttributesW failed for '" . Path . "'.")
}

/**
 * Enumerates one directory without treating access or device failures as absence.
 * @param {String} Path - Directory path; proven optional absence yields no entries.
 * @param {Integer} Directories - True selects directories, false regular entries.
 * @returns {Array} Absolute child paths; dot entries are excluded.
 */
FSListDirectoryStrict(Path, Directories := false) {
	if !FSStrictExists(Path)
		return []
	if !DirExist(Path)
		throw ValueError("Directory enumeration requires a directory.")
	Data := Buffer(592, 0)
	Handle := DllCall("kernel32\FindFirstFileW", "Str", RTrim(Path, "\/") . "\*", "Ptr", Data, "Ptr")
	if Handle == -1 {
		ErrorCode := A_LastError
		if ErrorCode == 2
			return []
		throw OSError(ErrorCode, A_ThisFunc, "Directory enumeration could not start.")
	}
	Entries := []
	try {
		loop {
			Name := StrGet(Data.Ptr + 44, 260, "UTF-16")
			IsDirectory := (NumGet(Data, 0, "UInt") & 0x10) != 0
			if Name != "." && Name != ".." && IsDirectory == !!Directories
				Entries.Push(RTrim(Path, "\/") . "\" . Name)
			if !DllCall("kernel32\FindNextFileW", "Ptr", Handle, "Ptr", Data, "Int") {
				ErrorCode := A_LastError
				if ErrorCode != 18
					throw OSError(ErrorCode, A_ThisFunc, "Directory enumeration did not complete.")
				break
			}
		}
	} finally {
		if !DllCall("kernel32\FindClose", "Ptr", Handle, "Int")
			throw OSError(A_LastError, A_ThisFunc, "Directory enumeration handle did not close.")
	}
	return Entries
}

/** Captures an absolute lexical path without reading the target or parent. */
FSResolveAbsolutePath(Path) {
	_FSRequirePath(Path, "An absolute path capture")
	; Win32's Unicode path domain, including its terminating code unit.
	static MAX_UNICODE_PATH_UNITS := 32768
	Full := Buffer(MAX_UNICODE_PATH_UNITS * 2, 0)
	Written := DllCall("kernel32\GetFullPathNameW", "Str", Path,
		"UInt", MAX_UNICODE_PATH_UNITS, "Ptr", Full, "Ptr", 0, "UInt")
	if !Written
		throw OSError(A_LastError, A_ThisFunc)
	if Written >= MAX_UNICODE_PATH_UNITS
		throw Error("Absolute path capture did not complete")
	return StrGet(Full, Written, "UTF-16")
}

/**
 * Resolves an existing directory to an absolute long path without recasing it.
 * @param {String} Path - Existing directory without wildcard characters.
 * @returns {String} Absolute long path; volume roots keep their final separator.
 * @throws {Error|OSError} Missing directories or incomplete native resolution.
 */
FSResolveDirectoryPath(Path) {
	if !FSPathIsAdmissible(Path) || InStr(Path, "*") || InStr(Path, "?")
		throw Error("Startup working directory cannot be resolved")
	if !DirExist(Path)
		throw Error("Startup working directory does not exist")
	Size := DllCall("kernel32\GetFullPathNameW", "Str", Path, "UInt", 0, "Ptr", 0, "Ptr", 0, "UInt")
	if !Size
		throw OSError(A_LastError, A_ThisFunc)
	Full := Buffer(Size * 2)
	Written := DllCall("kernel32\GetFullPathNameW", "Str", Path, "UInt", Size,
		"Ptr", Full, "Ptr", 0, "UInt")
	if !Written || Written >= Size
		throw Error("Startup working directory resolution did not complete")
	Size := DllCall("kernel32\GetLongPathNameW", "Ptr", Full, "Ptr", 0, "UInt", 0, "UInt")
	if !Size
		throw OSError(A_LastError, A_ThisFunc)
	Long := Buffer(Size * 2)
	Written := DllCall("kernel32\GetLongPathNameW", "Ptr", Full, "Ptr", Long, "UInt", Size, "UInt")
	if !Written || Written >= Size
		throw Error("Startup working directory long-name resolution did not complete")
	Resolved := StrGet(Long)
	if RegExMatch(Resolved, "i)^[a-z]:\\$")
		return Resolved
	return RTrim(Resolved, "\")
}

; Creates one directory exclusively, without adopting existing paths or parents.
; @param Path {String} Non-empty directory path with an existing parent.
; @return {Boolean} True only after native exclusive creation succeeds.
; @throws {ValueError|OSError} Invalid paths and all native failures are explicit.
FSCreateDirectoryExclusiveStrict(Path) {
	if !FSPathIsAdmissible(Path)
		throw ValueError("Exclusive directory creation requires a non-empty path without NUL.")
	Created := DllCall("kernel32\CreateDirectoryW", "WStr", Path, "Ptr", 0, "Int")
	ErrorCode := A_LastError
	if !Created
		throw OSError(ErrorCode, A_ThisFunc, Path)
	return true
}

; Creates a directory, and its missing parents, when it does not exist.
; @param Path {String} Absolute directory path.
; @return {Boolean} True when it was created, false when it already existed.
; @throws {Error} When it cannot be created.
FSEnsureDirectoryStrict(Path) {
	if !FSPathIsAdmissible(Path)
		throw ValueError("A directory creation requires a non-empty path without NUL.")
	if DirExist(Path)
		return false
	DirCreate(Path)
	return true
}

; Writes a retained handoff into a fresh, user-private temporary directory.
; Directory and file are created relative to held handles and never adopted by
; pathname. The caller receives a path only after the actual bytes are flushed.
; Later cleanup is owned by the OS/user temporary-file lifecycle; no read receipt
; from the external handler exists and no cleanup date is guaranteed.
; @param Parent {String} Existing absolute temporary parent directory.
; @param DirectoryName {String} Fresh literal directory leaf; collisions refuse.
; @param FileName {String} Literal file leaf in the newly owned directory.
; @param Content {String} Complete UTF-8 text, without embedded NUL.
; @return {String} Retained path after private ACL verification and durable write.
; @throws {Error} On acquisition, ACL, write or flush refusal.
FSWritePrivateRetained(Parent, DirectoryName, FileName, Content) {
	if !FSPathIsAdmissible(Parent) || !(Content is String)
		throw ValueError("A private handoff requires a parent and UTF-8 text")
	Loop StrLen(Content)
		if NumGet(StrPtr(Content), (A_Index - 1) * 2, "UShort") == 0
			throw ValueError("A private handoff cannot contain NUL")
	for Name in [DirectoryName, FileName] {
		if !FSPathIsAdmissible(Name) || Name == "." || Name == ".."
				|| InStr(Name, "\") || InStr(Name, "/") || InStr(Name, ":")
			throw ValueError("A private handoff requires literal leaf names")
	}
	Token := 0, SidText := 0, Descriptor := 0
	Root := -1, Directory := -1, FileHandle := -1, Committed := false, Failure := 0
	try {
		Process := DllCall("kernel32\GetCurrentProcess", "Ptr")
		if !DllCall("advapi32\OpenProcessToken", "Ptr", Process, "UInt", 0x8, "Ptr*", &Token, "Int")
			throw OSError(A_LastError, "open user token")
		Needed := 0
		DllCall("advapi32\GetTokenInformation", "Ptr", Token, "Int", 1,
			"Ptr", 0, "UInt", 0, "UInt*", &Needed, "Int")
		if Needed < A_PtrSize
			throw OSError(A_LastError, "size token user")
		User := Buffer(Needed, 0)
		if !DllCall("advapi32\GetTokenInformation", "Ptr", Token, "Int", 1,
			"Ptr", User, "UInt", User.Size, "UInt*", &Needed, "Int")
			throw OSError(A_LastError, "read token user")
		Sid := NumGet(User, 0, "Ptr")
		if !Sid || !DllCall("advapi32\ConvertSidToStringSidW", "Ptr", Sid, "Ptr*", &SidText, "Int")
			throw OSError(A_LastError, "format token SID")
		SidString := StrGet(SidText, "UTF-16")
		Sddl := "O:" . SidString . "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;" . SidString . ")"
		if !DllCall("advapi32\ConvertStringSecurityDescriptorToSecurityDescriptorW",
			"Str", Sddl, "UInt", 1, "Ptr*", &Descriptor, "Ptr", 0, "Int")
			throw OSError(A_LastError, "build private directory security")
		; FILE_ADD_SUBDIRECTORY | FILE_TRAVERSE on the held parent; the new
		; directory denies delete sharing while its exact child is written.
		Root := _FSHoldRootFolder(Parent, 0x4 | 0x20)
		Directory := _FSNtCreateRelative(Root, DirectoryName,
			0x2 | 0x20 | 0x80 | 0x100 | 0x10000 | 0x20000,
			0x10, 0x1 | 0x2, 2, 0x1, Descriptor)
		if !_FSPrivateRetainedSecurityMatches(Directory, Sid, true)
			throw Error("the directory did not retain its private ACL")
		; Assign the same explicit DACL rather than relying on the token's
		; default owner or filesystem-specific ACE inheritance.
		FileHandle := _FSNtCreateRelative(Directory, FileName, 0xC0010000,
			0x80, 0, 2, 0x40 | 0x2, Descriptor)
		if !_FSPrivateRetainedSecurityMatches(FileHandle, Sid, true)
			throw Error("the handoff file did not retain its private ACL")
		Size := StrPut(Content, "UTF-8") - 1
		Bytes := Buffer(Size + 1, 0)
		if Size
			StrPut(Content, Bytes, Size + 1, "UTF-8")
		Offset := 0
		while Offset < Size {
			Written := 0
			if !_FSNativeWrite(FileHandle, Bytes.Ptr + Offset, Size - Offset, &Written)
					|| Written <= 0 || Written > Size - Offset
				throw OSError(A_LastError, "private handoff write")
			Offset += Written
		}
		if !DllCall("kernel32\FlushFileBuffers", "Ptr", FileHandle, "Int")
			throw OSError(A_LastError, "private handoff flush")
		Committed := true
		Result := RTrim(Parent, "\/") . "\" . DirectoryName . "\" . FileName
	} catch as Err {
		Failure := Err
	} finally {
		if FileHandle != -1 {
			if !Committed && !_FSPrivateRetainedDiscard(FileHandle) && IsObject(Failure)
				Failure.Message .= "; owned handoff file cleanup failed"
			DllCall("kernel32\CloseHandle", "Ptr", FileHandle, "Int")
		}
		if Directory != -1 {
			if !Committed && !_FSPrivateRetainedDiscard(Directory) && IsObject(Failure)
				Failure.Message .= "; owned handoff directory cleanup failed"
			DllCall("kernel32\CloseHandle", "Ptr", Directory, "Int")
		}
		if Root != -1
			DllCall("kernel32\CloseHandle", "Ptr", Root, "Int")
		if Descriptor
			DllCall("kernel32\LocalFree", "Ptr", Descriptor, "Ptr")
		if SidText
			DllCall("kernel32\LocalFree", "Ptr", SidText, "Ptr")
		if Token
			DllCall("kernel32\CloseHandle", "Ptr", Token, "Int")
	}
	if IsObject(Failure)
		throw Failure
	return Result
}

; Both directory and file ACLs must grant only user and SYSTEM.
_FSPrivateRetainedSecurityMatches(Handle, UserSid, Protected) {
	Owner := 0, Dacl := 0, Descriptor := 0
	Status := DllCall("advapi32\GetSecurityInfo", "Ptr", Handle, "Int", 1, "UInt", 5,
		"Ptr*", &Owner, "Ptr", 0, "Ptr*", &Dacl, "Ptr", 0, "Ptr*", &Descriptor, "UInt")
	try {
		if Status != 0 || !Descriptor
			return false
		if !Owner || !Dacl || !DllCall("advapi32\EqualSid", "Ptr", Owner, "Ptr", UserSid, "Int")
			return false
		Control := 0, Revision := 0
		if !DllCall("advapi32\GetSecurityDescriptorControl", "Ptr", Descriptor,
				"UShort*", &Control, "UInt*", &Revision, "Int")
				|| (Protected && !(Control & 0x1000))
			return false
		Info := Buffer(12, 0)
		if !DllCall("advapi32\GetAclInformation", "Ptr", Dacl, "Ptr", Info, "UInt", 12, "Int", 2, "Int")
				|| NumGet(Info, 0, "UInt") != 2
			return false
		SeenUser := false, SeenSystem := false
		loop 2 {
			Ace := 0
			if !DllCall("advapi32\GetAce", "Ptr", Dacl, "UInt", A_Index - 1, "Ptr*", &Ace, "Int")
					|| NumGet(Ace, 0, "UChar") != 0 || NumGet(Ace, 4, "UInt") != 0x1F01FF
				return false
			AceSid := Ace + 8
			IsUser := DllCall("advapi32\EqualSid", "Ptr", AceSid, "Ptr", UserSid, "Int") != 0
			IsSystem := DllCall("advapi32\IsWellKnownSid", "Ptr", AceSid, "Int", 22, "Int") != 0
			if !IsUser && !IsSystem
				return false
			SeenUser := SeenUser || IsUser, SeenSystem := SeenSystem || IsSystem
		}
		return SeenUser && SeenSystem
	} finally {
		if Descriptor
			DllCall("kernel32\LocalFree", "Ptr", Descriptor, "Ptr")
	}
}

; Marks only this still-owned object for deletion; no pathname is reopened.
_FSPrivateRetainedDiscard(Handle) {
	Disposition := Buffer(1, 1)
	return DllCall("kernel32\SetFileInformationByHandle", "Ptr", Handle,
		"Int", 4, "Ptr", Disposition, "UInt", 1, "Int") != 0
}

; Deletes a file. Returns true if deleted or already absent, false on error.
; @param Path {String} Absolute path to the file to delete.
; @return {Boolean} True on success, false on error.
FSDelete(Path) {
	return _FSDeleteWith(Path, _FSDeleteNativeReceipt)
}

_FSDeleteNativeReceipt(Path) {
	; One native call distinguishes successful deletion, proven absence, and every
	; other failure without a FileExist/DeleteFile race or an ambiguous probe.
	Deleted := DllCall("kernel32\DeleteFileW", "Str", Path, "Int")
	ErrorCode := A_LastError
	return Map("deleted", Deleted != 0, "error", ErrorCode)
}

_FSDeleteWith(Path, DeleteFn) {
	if !FSPathIsAdmissible(Path)
		return false
	try {
		Receipt := DeleteFn.Call(Path)
		if !(Receipt is Map)
			return false
		Deleted := Receipt.Get("deleted", false)
		if (Deleted is Integer) && Deleted == true
			return true
		ErrorCode := Receipt.Get("error", 0)
		if !(ErrorCode is Integer)
			return false
		return ErrorCode == 2 || ErrorCode == 3
	} catch {
		return false
	}
}

; Verify a stable read-only file before deleting that same object exclusively.
; The callback must return true only for an artifact owned by its caller.
; Sharing/identity failures retain the file for a later retry.
FSDeleteVerified(Path, VerifyFn) {
	if !FSPathIsAdmissible(Path)
		return false
	Handle := DllCall("kernel32\CreateFileW", "Str", Path, "UInt", 0x80000000,
		"UInt", 1, "Ptr", 0, "UInt", 3, "UInt", 0x00200000, "Ptr", 0, "Ptr")
	if Handle = -1
		return false
	try {
		Info := Buffer(52, 0)
		if !DllCall("kernel32\GetFileInformationByHandle", "Ptr", Handle, "Ptr", Info, "Int")
				|| (NumGet(Info, 0, "UInt") & 0x410)
			return false
		Before := FSHandleSnapshot(Handle)
		if !Before.Get("ok", false) || !VerifyFn.Call(Path)
			return false
	} finally DllCall("kernel32\CloseHandle", "Ptr", Handle)
	; DELETE access and no sharing prevent any new connection or replacement
	; between the identity check and marking this handle for deletion.
	Handle := DllCall("kernel32\CreateFileW", "Str", Path, "UInt", 0x80010000,
		"UInt", 0, "Ptr", 0, "UInt", 3, "UInt", 0x00200000, "Ptr", 0, "Ptr")
	if Handle = -1
		return false
	try {
		After := FSHandleSnapshot(Handle)
		if !After.Get("ok", false)
			return false
		for Key in ["volume", "index_high", "index_low", "size", "write_high", "write_low"] {
			if Before[Key] != After[Key]
				return false
		}
		; FILE_DISPOSITION_INFO contains one BOOLEAN. Closing deletes the
		; verified object, whereas DeleteFileW after closing would race a rename.
		Disposition := Buffer(1, 1)
		return DllCall("kernel32\SetFileInformationByHandle", "Ptr", Handle,
			"Int", 4, "Ptr", Disposition, "UInt", 1, "Int") != 0
	} finally DllCall("kernel32\CloseHandle", "Ptr", Handle)
}

; Acquire a persistent guard file without sharing, truncation, or inheritance.
; Windows-only protocol helper, intentionally outside the portable port map.
; @param Path {String} Guard path in an existing owned directory.
; @param Contended {Boolean} True only when a competing native owner blocked opening.
; @returns {Integer} Owned handle, or 0 when unavailable or not an ordinary file.
FSOpenExclusiveGuard(Path, &Contended := false) {
	Contended := false
	if !FSPathIsAdmissible(Path)
		throw ValueError("An exclusive guard requires a non-empty path without NUL.")
	Handle := DllCall("kernel32\CreateFileW", "Str", Path, "UInt", 0xC0000000,
		"UInt", 0, "Ptr", 0, "UInt", 4, "UInt", 0x00200080, "Ptr", 0, "Ptr")
	if Handle = -1 {
		Code := A_LastError
		Contended := Code = 32 || Code = 33 ; Sharing or byte-range lock violation.
		return 0
	}
	Info := Buffer(52, 0)
	if !DllCall("kernel32\GetFileInformationByHandle", "Ptr", Handle, "Ptr", Info, "Int")
			|| (NumGet(Info, 0, "UInt") & 0x410) {
		DllCall("kernel32\CloseHandle", "Ptr", Handle)
		return 0
	}
	return Handle
}

; Release exactly the acquired guard. Keep its pathname stable across owners.
; @param Handle {Integer} Owned guard returned by FSOpenExclusiveGuard.
; @returns {Boolean} Whether Windows released the native handle.
FSCloseExclusiveGuard(Handle) {
	return Handle && DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int") != 0
}

; Idempotent strict deletion for recovery protocols. Unlike FSDelete, this
; does not route through FileExist (whose empty result conflates absence with
; an OS probe failure). Non-absence failures are surfaced to the journal.
FSDeleteStrict(Path) {
	if !FSPathIsAdmissible(Path)
		throw ValueError("A strict delete requires a non-empty path without NUL.")
	Receipt := _FSDeleteNativeReceipt(Path)
	if Receipt["deleted"]
		return 1
	ErrorCode := Receipt["error"]
	if (ErrorCode == 2 || ErrorCode == 3)
		return 1
	throw OSError(ErrorCode, A_ThisFunc,
		"DeleteFileW failed for '" . Path . "'.")
}

; Returns the current byte length, or -1 when the path is absent/unreadable.
; Kept outside the portable port map for transactional file protocols that must
; validate an artifact without exposing AHK FileGetSize to domain modules.
FSSize(Path) {
	if !FSPathIsAdmissible(Path)
		return -1
	try return FileGetSize(Path)
	catch
		return -1
}

; Reads a small control file only when its size is inside the explicit budget.
; This prevents a malformed sidecar from turning an early-boot capability check
; into an unbounded allocation.
FSReadBounded(Path, MaxBytes) {
	if !FSPathIsAdmissible(Path)
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

; Byte-faithful verification for staged UTF-8 control/source artifacts. The
; ordinary FSRead/FileRead path consumes a physical EF BB BF prefix, so comparing
; its String to a BOM-bearing expected payload produces a deterministic false
; mismatch even though the bytes on disk are correct.
FSUtf8ExactMatches(Path, Expected) {
	if !(Expected is String)
		return false
	Observed := FSReadUtf8Exact(Path)
	return (Observed is String) and Observed == Expected
}

FSReadUtf8ExactBounded(Path, MaxBytes) {
	if !(MaxBytes is Integer) || MaxBytes <= 0
		return false
	return _FSReadUtf8ExactImpl(Path, MaxBytes, true)
}

_FSReadUtf8ExactImpl(Path, MaxBytes, Bounded) {
	if !FSPathIsAdmissible(Path)
		return false
	static GENERIC_READ := 0x80000000
	static FILE_SHARE_READ := 0x00000001
	static OPEN_EXISTING := 3
	static FILE_ATTRIBUTE_NORMAL := 0x00000080
	Handle := -1
	OpeningReturned := false
	Closed := false
	Content := false
	ReadActivity := FileReadActivityEnter(Path)
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
		OpeningReturned := true
		if Handle != -1 {
			FileReadActivityBind(ReadActivity, Handle)
			Content := _FSReadUtf8ExactHandle(Handle, MaxBytes, Bounded)
		}
	} catch {
		Content := false
	} finally {
		if Handle == -1 {
			; A returned failed opening owns no handle; a thrown acquisition stays debt.
			Closed := OpeningReturned
		} else {
			try Closed := DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int") != 0
			catch {
				Closed := false
			}
		}
		if Closed
			FileReadActivityLeave(ReadActivity)
	}
	return Closed ? Content : false
}

/** Reads and validates the original UTF-8 bytes through one retained handle. */
_FSReadUtf8ExactHandle(Handle, MaxBytes, Bounded) {
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
}

; Admit only the target's HWND-sequence scratch format after its owner exits.
; A reused HWND conservatively retains debris instead of risking an active write.
; @param FileName {String} Candidate basename from the directory enumeration.
; @param TargetName {String} Exact basename of the writer's destination.
; @returns {Boolean} Whether the recognized producer window no longer exists.
FSAtomicTempOwnerIsGone(FileName, TargetName) {
	if TargetName = "" || StrCompare(SubStr(FileName, 1, StrLen(TargetName)), TargetName, true) != 0
		return false
	Suffix := SubStr(FileName, StrLen(TargetName) + 1)
	if !RegExMatch(Suffix, "^\.([1-9]\d{0,9})-[1-9]\d{0,18}\.tmp$", &Owner)
		return false
	Hwnd := Integer(Owner[1])
	return Hwnd <= 0xFFFFFFFF && !DllCall("User32\IsWindow", "Ptr", Hwnd, "Int")
}

; Publishes a complete same-directory stage with one write-through Win32 rename.
; Failure retains Source and leaves Destination untouched.
; NativeError reports the immediate Win32 error; zero also denotes unavailable
; native information on invalid arguments or a DllCall exception.
FSAtomicMoveReplace(Source, Destination, &NativeError := 0) {
	NativeError := 0
	if !FSPathIsAdmissible(Source)
		or !FSPathIsAdmissible(Destination)
		return false
	static MOVEFILE_REPLACE_EXISTING := 0x00000001
	static MOVEFILE_WRITE_THROUGH := 0x00000008
	try {
		DllCall("kernel32\SetLastError", "UInt", 0)
		Moved := DllCall("MoveFileExW", "Str", Source, "Str", Destination,
			"UInt", MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH, "Int")
		NativeError := A_LastError
		return Moved != 0
	} catch Error {
		; No completed native receipt is available for a DllCall exception.
		NativeError := 0
		return false
	}
}

; Publishes Source only when Destination is still absent. Omitting
; MOVEFILE_REPLACE_EXISTING makes the directory-entry operation atomic and
; collision-preserving; WRITE_THROUGH makes the rename a durable boundary.
FSAtomicMoveCreate(Source, Destination) {
	if !FSPathIsAdmissible(Source)
		or !FSPathIsAdmissible(Destination)
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
        if !FSPathIsAdmissible(Source) or !FSPathIsAdmissible(Destination)
                return false
        try {
                FileMove(Source, Destination, Overwrite)
                return true
        } catch {
                return false
        }
}

/** Open a BOM-aware UTF-8 reader; native refusal reaches the identity owner. */
FSOpenReadStrict(Path) {
	_FSRequirePath(Path, "A strict reader")
	return FileOpen(Path, "r", "UTF-8")
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
	if !FSPathIsAdmissible(Path)
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
	if !FSPathIsAdmissible(Path)
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

; Move an exact file-read byte span, including overlapping carry buffers.
; @param Destination {Buffer|Integer} A writable span of at least ByteCount bytes.
; @param Source {Buffer|Integer} A readable span of at least ByteCount bytes.
; @param ByteCount {Integer} The number of bytes to move without text decoding.
FSBufferMove(Destination, Source, ByteCount) {
	DllCall("ntdll\RtlMoveMemory", "Ptr", Destination, "Ptr", Source, "UPtr", ByteCount)
}

; Reads an exact byte range together with the identity of the handle it came
; from, so a caller can prove the bytes belong to the file it expects. NUL bytes
; (an interrupted append's hole) are optionally blanked to spaces: UTF-8
; conversion stops at the first NUL. Windows-specific, outside the port map.
; @param Path {String} Absolute path to the file.
; @param Start {Integer} First byte offset.
; @param Count {Integer} Exact number of bytes to read.
; @param BlankNul {Boolean} Whether to replace every NUL byte with a space.
; @return {Map} ok, buffer, snapshot (FSHandleSnapshot), nul_bytes.
FSReadRange(Path, Start, Count, BlankNul := false) {
	if !FSPathIsAdmissible(Path)
		return Map("ok", false)
	local Buf := Buffer(Max(Count, 1), 0)
	local FH := FileOpen(Path, "r")
	if !IsObject(FH)
		return Map("ok", false)
	try {
		local Snapshot := FSHandleSnapshot(FH.Handle)
		FH.Pos := Start
		if Count > 0 && FH.RawRead(Buf, Count) != Count
			return Map("ok", false, "snapshot", Snapshot)
	} finally FH.Close()
	local Blanked := 0
	if BlankNul {
		local Cursor := Buf.Ptr
		local Stop := Buf.Ptr + Count
		while Cursor < Stop {
			local Hit := DllCall("msvcrt\memchr", "Ptr", Cursor, "Int", 0, "UPtr", Stop - Cursor, "Cdecl Ptr")
			if !Hit
				break
			NumPut("UChar", 0x20, Hit)
			Blanked += 1
			Cursor := Hit + 1
		}
	}
	return Map("ok", true, "buffer", Buf, "snapshot", Snapshot, "nul_bytes", Blanked)
}

; Copies a file byte for byte to a path that must not exist yet, then checks
; the copy reads back as its source. The configuration backup's copies.
; @param Source {String} File to copy.
; @param Destination {String} New path; an existing one is never replaced.
; @return {Boolean} True only for a complete, verified copy. Unverified output
;   is retained: its pathname may already belong to a different file.
FSCopyCreateVerified(Source, Destination) {
	if !FSPathIsAdmissible(Source) || !FSPathIsAdmissible(Destination)
		return false
	; Builtin copy/delete operations interpret patterns; this API owns literal names.
	if !DllCall("kernel32\CopyFileW", "Str", Source, "Str", Destination, "Int", true, "Int")
		return false
	; A mismatch can describe a foreign replacement, not the copy just created.
	return FSSameBytes(Source, Destination)
}

; Whether two files hold exactly the same bytes.
; @param PathA {String}
; @param PathB {String}
; @return {Boolean} False when either cannot be read.
FSSameBytes(PathA, PathB) {
	if !FSPathIsAdmissible(PathA) || !FSPathIsAdmissible(PathB)
		return false
	try {
		A := FileRead(PathA, "RAW")
		B := FileRead(PathB, "RAW")
	} catch {
		return false
	}
	if (A.Size != B.Size)
		return false
	if (A.Size == 0)
		return true
	return DllCall("ntdll\RtlCompareMemory", "Ptr", A, "Ptr", B, "UPtr", A.Size, "UPtr") == A.Size
}

global FS_RESTORE_STAGE_SUFFIX := ".ergopti-restore.tmp"
global FS_RESTORE_COPY_BLOCK := 65536
; FILE_BASIC_INFO: four 8-byte timestamps, then the attributes and padding.
global FS_BASIC_INFO_BYTES := 40
global FS_ATTRIBUTE_REPARSE_POINT := 0x400
; List, add file, add subfolder, traverse, read attributes. The rename target
; check opens the folder for writing, so read and write sharing stay granted;
; delete sharing is what stops the folder being renamed or removed.
global FS_HELD_FOLDER_ACCESS := 0x1 | 0x2 | 0x4 | 0x20 | 0x80
global FS_HELD_FOLDER_SHARE := 0x1 | 0x2

; Replaces one file below RootDir by a copy of Source, holding every object from
; the first open to the last close. CopyFileW and MoveFileExW take pathnames, so
; a same-user process could swap the stage, or a folder above it, between any
; two of them: restore then verified one file and published another. Here no
; pathname is resolved after the anchor opens: each folder is opened relative
; to its parent, the stage relative to its folder with no sharing at all, and
; the rename goes through the stage's own handle into the held folder handle.
; A folder handle denies delete sharing, so the folder cannot be renamed away.
; The stage keeps the name restore always used: an existing file of that name
; belongs to someone else and refuses the attempt untouched. A refused stage
; goes away through its own handle, never through a name.
; @param Source {String} File published with its streams and metadata.
; @param RootDir {String} Existing anchor folder; a link here is followed, since
;   the configuration folder may legitimately live behind one.
; @param Relative {String} Destination below RootDir, in "/" or "\" segments.
;   A link among the segments refuses the attempt.
; @param Detail {VarRef} Why a false return was false.
; @return {Boolean} True only when the verified stage is the destination.
FSCopyReplaceAtomic(Source, RootDir, Relative, &Detail := "") {
	Detail := ""
	if !FSPathIsAdmissible(Source) || !FSPathIsAdmissible(RootDir) || !FSPathIsAdmissible(Relative) {
		Detail := "inadmissible path"
		return false
	}
	Names := StrSplit(StrReplace(Relative, "\", "/"), "/")
	for _, Name in Names
		if Name == "" || Name == "." || Name == ".." || InStr(Name, ":") {
			Detail := "invalid relative path"
			return false
		}
	Leaf := Names.Pop()
	Folders := []
	SourceHandle := -1, StageHandle := -1, Published := false
	try {
		Folders.Push(_FSHoldRootFolder(RootDir))
		for _, Name in Names
			Folders.Push(_FSHoldChildFolder(Folders[Folders.Length], Name))
		SourceHandle := _FSOpenHeldSource(Source)
		Metadata := _FSHandleBasicInfo(SourceHandle)
		StageHandle := _FSCreateHeldStage(Folders[Folders.Length], Leaf . FS_RESTORE_STAGE_SUFFIX,
			NumGet(Metadata, 32, "UInt"))
		_FSBackupStreamsCopy(SourceHandle, StageHandle)
		_FSBackupStreamsCompare(SourceHandle, StageHandle)
		_FSApplyCopyMetadata(StageHandle, Metadata)
		if !DllCall("kernel32\FlushFileBuffers", "Ptr", StageHandle, "Int")
			throw OSError(A_LastError, "stage flush")
		_FSHeldRename(StageHandle, Folders[Folders.Length], Leaf)
		Published := true
		if !DllCall("kernel32\FlushFileBuffers", "Ptr", StageHandle, "Int")
			throw OSError(A_LastError, "published file flush")
		return true
	} catch as Err {
		Detail := (Published ? "published, but " : "") . Err.Message
		if !Published && StageHandle != -1
			Detail .= _FSDiscardHeldStage(StageHandle)
		return false
	} finally {
		if StageHandle != -1
			DllCall("kernel32\CloseHandle", "Ptr", StageHandle, "Int")
		if SourceHandle != -1
			DllCall("kernel32\CloseHandle", "Ptr", SourceHandle, "Int")
		while Folders.Length
			DllCall("kernel32\CloseHandle", "Ptr", Folders.Pop(), "Int")
	}
}

; Writes a UTF-8 replacement through a creation-time stage handle. The held
; parent and sharing-denied stage remain the same objects through write,
; flush, rename and failed-attempt cleanup; a foreign sidecar is never adopted.
; @param Path {String} Target below an existing parent directory.
; @param Content {String} Complete UTF-8 text, without a BOM.
; @param StageSuffix {String} Non-empty leaf suffix reserved by this publisher.
; @param Detail {VarRef} Native failure and any retained-stage cleanup debt.
; @param StageFn {Callable|0} Optional acquisition of the owned relative stage.
; @param BeforePublishFn {Callable|0} Preflight outside the final native span.
; @param AdmissionFn {Callable|0} Pure final authority check beside native rename.
; @param ReplaceExisting {Boolean} Whether the target may already exist.
; @param Publication {VarRef} Structured renamed/durable receipt, including partial refusal.
; @param FlushFn {Callable|0} Native flush boundary for stage and published phases.
; @return {Boolean} True only after publication, flush and handle-close acknowledgement.
FSWriteReplaceOwned(Path, Content, StageSuffix, &Detail := "", StageFn := 0,
		BeforePublishFn := 0, AdmissionFn := 0, ReplaceExisting := true,
		&Publication := 0, FlushFn := 0) {
	Detail := ""
	; This is a receipt of effects, not a parsed diagnostic. Never acknowledge
	; durability until publication, its flush and both closes have completed.
	Publication := {renamed: false, durable: false}
	if !FSPathIsAdmissible(Path) || !(Content is String) || !FSPathIsAdmissible(StageSuffix)
			|| InStr(StageSuffix, "\") || InStr(StageSuffix, "/") || InStr(StageSuffix, ":") {
		Detail := "inadmissible text publication path or stage suffix"
		return false
	}
	if !HasMethod(FlushFn, "Call") && !((FlushFn is Integer) && FlushFn == 0) {
		Detail := "owned text flush adapter is not callable"
		return false
	}
	Flush := HasMethod(FlushFn, "Call") ? FlushFn : _FSFlushOwnedText
	SplitPath(Path, &Leaf, &Parent)
	if Leaf == "" || Parent == "" || Leaf == "." || Leaf == ".." || InStr(Leaf, ":") {
		Detail := "text publication requires an existing parent and target leaf"
		return false
	}
	FolderHandle := -1, StageHandle := -1, Published := false, Succeeded := false
	try {
		FolderHandle := _FSHoldRootFolder(Parent, 0x2 | 0x20)
		CreateStage := HasMethod(StageFn, "Call") ? StageFn : _FSCreateHeldStage
		StageHandle := CreateStage.Call(FolderHandle, Leaf . StageSuffix, 0)
		ByteCount := StrPut(Content, "UTF-8") - 1
		Utf8 := Buffer(ByteCount + 1, 0)
		if ByteCount > 0
			StrPut(Content, Utf8, ByteCount + 1, "UTF-8")
		Offset := 0
		while Offset < ByteCount {
			Written := 0
			if !_FSNativeWrite(StageHandle, Utf8.Ptr + Offset, ByteCount - Offset, &Written)
					|| Written <= 0 || Written > ByteCount - Offset
				throw OSError(A_LastError, "owned text stage write")
			Offset += Written
		}
		Flushed := Flush.Call(StageHandle, "stage")
		if !(Flushed is Integer) || Flushed != 1
			throw Error("owned text stage flush was not acknowledged")
		if HasMethod(BeforePublishFn, "Call") {
			Accepted := BeforePublishFn.Call()
			if !(Accepted is Integer) || Accepted != 1
				throw Error("owned text publication preflight refused")
		} else if !((BeforePublishFn is Integer) && BeforePublishFn == 0)
			throw TypeError("owned text publication preflight is not callable")
		if (AdmissionFn is Integer) && AdmissionFn == 0
			_FSHeldRename(StageHandle, FolderHandle, Leaf, ReplaceExisting)
		else if !FSConfigHeldRename(StageHandle, FolderHandle, Leaf, ReplaceExisting, AdmissionFn)
			throw Error("owned text publication final admission refused")
		Published := true
		Publication.renamed := true
		Flushed := Flush.Call(StageHandle, "published")
		if !(Flushed is Integer) || Flushed != 1
			throw Error("published text flush was not acknowledged")
		Succeeded := true
	} catch as Err {
		if (Err is OSError) && Err.What == "owned text stage write"
			Detail := "owned text stage write (Win32 " . Err.Number . "): " . Err.Message
		else
			Detail := (Published ? "published, but " : "") . Err.Message
		if !Published && StageHandle != -1
			Detail .= _FSDiscardHeldStage(StageHandle)
	} finally {
		for Entry in [{handle: StageHandle, kind: "stage"}, {handle: FolderHandle, kind: "folder"}] {
			if Entry.handle == -1
				continue
			Closed := false
			try Closed := _FSCloseOwnedText(Entry.handle, Entry.kind)
			if !(Closed is Integer) || Closed != 1 {
				Succeeded := false
				Detail .= "; owned text " . Entry.kind . " close was not acknowledged"
			}
		}
	}
	Publication.durable := Succeeded
	return Succeeded
}

_FSFlushOwnedText(Handle, Phase) {
	return DllCall("kernel32\FlushFileBuffers", "Ptr", Handle, "Int") != 0
}

_FSCloseOwnedText(Handle, Kind) {
	return DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int") != 0
}

; Opens the anchor folder: the one pathname of a held copy.
_FSHoldRootFolder(RootDir, Access := unset) {
	static OPEN_EXISTING := 3, FILE_FLAG_BACKUP_SEMANTICS := 0x02000000, SYNCHRONIZE := 0x100000
	DesiredAccess := IsSet(Access) ? Access : FS_HELD_FOLDER_ACCESS
	Handle := DllCall("kernel32\CreateFileW", "Str", RootDir, "UInt", DesiredAccess | SYNCHRONIZE,
		"UInt", FS_HELD_FOLDER_SHARE, "Ptr", 0, "UInt", OPEN_EXISTING,
		"UInt", FILE_FLAG_BACKUP_SEMANTICS, "Ptr", 0, "Ptr")
	if Handle == -1
		throw OSError(A_LastError, "anchor folder open")
	return Handle
}

; Opens or creates one folder inside a held one and refuses a link.
_FSHoldChildFolder(Parent, Name) {
	static FILE_OPEN_IF := 3, FILE_DIRECTORY_FILE := 0x1, FILE_ATTRIBUTE_DIRECTORY := 0x10
	Handle := _FSNtCreateRelative(Parent, Name, FS_HELD_FOLDER_ACCESS, FILE_ATTRIBUTE_DIRECTORY,
		FS_HELD_FOLDER_SHARE, FILE_OPEN_IF, FILE_DIRECTORY_FILE)
	Info := Buffer(FS_BASIC_INFO_BYTES, 0)
	Readable := DllCall("kernel32\GetFileInformationByHandleEx", "Ptr", Handle, "Int", 0,
		"Ptr", Info, "UInt", Info.Size, "Int")
	NativeError := A_LastError
	if Readable && !(NumGet(Info, 32, "UInt") & FS_ATTRIBUTE_REPARSE_POINT)
		return Handle
	DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int")
	throw Readable ? Error("a folder of the path is a link") : OSError(NativeError, "folder identity")
}

; Reads share only: nothing writes, renames or deletes the source meanwhile.
_FSOpenHeldSource(Source) {
	static GENERIC_READ := 0x80000000, FILE_SHARE_READ := 1, OPEN_EXISTING := 3
	Handle := DllCall("kernel32\CreateFileW", "Str", Source, "UInt", GENERIC_READ,
		"UInt", FILE_SHARE_READ, "Ptr", 0, "UInt", OPEN_EXISTING, "UInt", 0, "Ptr", 0, "Ptr")
	if Handle == -1
		throw OSError(A_LastError, "source open")
	return Handle
}

; Creates the stage in its held folder, encrypted like its source as CopyFileW
; does. The default shares nothing; an optional READ-only observer still cannot
; write, rename or delete it. FILE_CREATE never adopts an existing name or link.
_FSCreateHeldStage(Folder, Name, SourceAttributes, Share := 0) {
	static GENERIC_READ := 0x80000000, GENERIC_WRITE := 0x40000000, DELETE := 0x10000
	static FILE_CREATE := 2, FILE_NON_DIRECTORY_FILE := 0x40, FILE_WRITE_THROUGH := 0x2
	static FILE_ATTRIBUTE_NORMAL := 0x80, FILE_ATTRIBUTE_ENCRYPTED := 0x4000
	return _FSNtCreateRelative(Folder, Name, GENERIC_READ | GENERIC_WRITE | DELETE,
		FILE_ATTRIBUTE_NORMAL | (SourceAttributes & FILE_ATTRIBUTE_ENCRYPTED), Share,
		FILE_CREATE, FILE_NON_DIRECTORY_FILE | FILE_WRITE_THROUGH)
}

; NtCreateFile on one name relative to a held handle. A reparse point is opened
; as itself, never followed; the caller decides what that means.
; @return {Integer} The new handle.
; @throws {Error} Carrying the NTSTATUS on refusal.
_FSNtCreateRelative(Root, Name, Access, Attributes, Share, Disposition, Options, SecurityDescriptor := 0) {
	static SYNCHRONIZE := 0x100000, OBJ_CASE_INSENSITIVE := 0x40
	static FILE_SYNCHRONOUS_IO_NONALERT := 0x20, FILE_OPEN_REPARSE_POINT := 0x200000
	Wide := Buffer(StrLen(Name) * 2 + 2, 0)
	StrPut(Name, Wide, "UTF-16")
	Unicode := Buffer(2 * A_PtrSize, 0)
	NumPut("UShort", Wide.Size - 2, "UShort", Wide.Size - 2, Unicode)
	NumPut("Ptr", Wide.Ptr, Unicode, A_PtrSize)
	ObjectAttributes := Buffer(6 * A_PtrSize, 0)
	NumPut("UInt", ObjectAttributes.Size, ObjectAttributes, 0)
	NumPut("Ptr", Root, ObjectAttributes, A_PtrSize)
	NumPut("Ptr", Unicode.Ptr, ObjectAttributes, 2 * A_PtrSize)
	NumPut("UInt", OBJ_CASE_INSENSITIVE, ObjectAttributes, 3 * A_PtrSize)
	NumPut("Ptr", SecurityDescriptor, ObjectAttributes, 4 * A_PtrSize)
	Io := Buffer(2 * A_PtrSize, 0)
	Status := DllCall("ntdll\NtCreateFile", "Ptr*", &Handle := 0, "UInt", Access | SYNCHRONIZE,
		"Ptr", ObjectAttributes, "Ptr", Io, "Ptr", 0, "UInt", Attributes, "UInt", Share, "UInt", Disposition,
		"UInt", Options | FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_REPARSE_POINT,
		"Ptr", 0, "UInt", 0, "UInt")
	if Status >= 0x80000000
		throw Error(Format("relative open of a held folder refused (NTSTATUS 0x{:08X})", Status))
	return Handle
}

; FILE_BASIC_INFO of a handle: four timestamps, then the attributes at 32.
_FSHandleBasicInfo(Handle) {
	Info := Buffer(FS_BASIC_INFO_BYTES, 0)
	if !DllCall("kernel32\GetFileInformationByHandleEx", "Ptr", Handle, "Int", 0,
		"Ptr", Info, "UInt", Info.Size, "Int")
		throw OSError(A_LastError, "file metadata read")
	return Info
}

; Copies what CopyFileW copies, by handle: BackupRead yields the content, the
; named streams and the extended attributes, and BackupWrite applies them. The
; security descriptor stays out: a copy inherits from its folder, as before.
_FSBackupStreamsCopy(Source, Stage) {
	Block := Buffer(FS_RESTORE_COPY_BLOCK), ReadContext := 0, WriteContext := 0
	_FSRewind(Source)
	try {
		loop {
			if !DllCall("kernel32\BackupRead", "Ptr", Source, "Ptr", Block, "UInt", Block.Size,
				"UInt*", &Got := 0, "Int", false, "Int", false, "Ptr*", &ReadContext, "Int")
				throw OSError(A_LastError, "stream read")
			if Got == 0
				return
			if !DllCall("kernel32\BackupWrite", "Ptr", Stage, "Ptr", Block, "UInt", Got,
				"UInt*", &Put := 0, "Int", false, "Int", false, "Ptr*", &WriteContext, "Int")
				throw OSError(A_LastError, "stream write")
			if Put != Got
				throw Error("short stream write")
		}
	} finally {
		_FSBackupRelease("BackupRead", Source, ReadContext)
		_FSBackupRelease("BackupWrite", Stage, WriteContext)
	}
}

; Reads both held handles back as backup streams and compares every byte. The
; two sides may split a read differently, so what one side has ahead waits.
; @throws {Error} On the first difference.
_FSBackupStreamsCompare(Source, Stage) {
	Left := Buffer(FS_RESTORE_COPY_BLOCK), Right := Buffer(FS_RESTORE_COPY_BLOCK)
	LeftContext := 0, RightContext := 0, LeftFill := 0, RightFill := 0
	_FSRewind(Source)
	_FSRewind(Stage)
	try {
		loop {
			_FSBackupReadInto(Source, Left, &LeftFill, &LeftContext)
			_FSBackupReadInto(Stage, Right, &RightFill, &RightContext)
			if LeftFill == 0 && RightFill == 0
				return
			Common := Min(LeftFill, RightFill)
			if Common == 0
				throw Error("the verified copy has a different length")
			if DllCall("ntdll\RtlCompareMemory", "Ptr", Left, "Ptr", Right, "UPtr", Common, "UPtr") != Common
				throw Error("the verified copy has different bytes")
			_FSBufferConsume(Left, &LeftFill, Common)
			_FSBufferConsume(Right, &RightFill, Common)
		}
	} finally {
		_FSBackupRelease("BackupRead", Source, LeftContext)
		_FSBackupRelease("BackupRead", Stage, RightContext)
	}
}

; Tops up one comparison buffer behind what it already holds.
_FSBackupReadInto(Handle, Block, &Fill, &Context) {
	if Fill == Block.Size
		return
	if !DllCall("kernel32\BackupRead", "Ptr", Handle, "Ptr", Block.Ptr + Fill, "UInt", Block.Size - Fill,
		"UInt*", &Got := 0, "Int", false, "Int", false, "Ptr*", &Context, "Int")
		throw OSError(A_LastError, "stream read back")
	Fill += Got
}

_FSBufferConsume(Block, &Fill, Count) {
	Fill -= Count
	if Fill
		FSBufferMove(Block, Block.Ptr + Count, Fill)
}

_FSRewind(Handle) {
	if !DllCall("kernel32\SetFilePointerEx", "Ptr", Handle, "Int64", 0, "Ptr", 0, "UInt", 0, "Int")
		throw OSError(A_LastError, "rewind")
}

; An unfinished backup context owns native memory until an abort call frees it.
_FSBackupRelease(Function, Handle, Context) {
	if Context
		DllCall("kernel32\" . Function, "Ptr", Handle, "Ptr", 0, "UInt", 0, "UInt*", &Done := 0,
			"Int", true, "Int", false, "Ptr*", &Context, "Int")
}

; Gives the stage the attributes and write time CopyFileW carries over.
_FSApplyCopyMetadata(Stage, Metadata) {
	static WRITE_TIME_OFFSET := 16, ATTRIBUTES_OFFSET := 32, FILE_ATTRIBUTE_NORMAL := 0x80
	; Read-only, hidden, system, archive and not-content-indexed.
	static CARRIED_ATTRIBUTES := 0x2027
	Info := Buffer(FS_BASIC_INFO_BYTES, 0)
	NumPut("Int64", NumGet(Metadata, WRITE_TIME_OFFSET, "Int64"), Info, WRITE_TIME_OFFSET)
	Carried := NumGet(Metadata, ATTRIBUTES_OFFSET, "UInt") & CARRIED_ATTRIBUTES
	NumPut("UInt", Carried ? Carried : FILE_ATTRIBUTE_NORMAL, Info, ATTRIBUTES_OFFSET)
	if !DllCall("kernel32\SetFileInformationByHandle", "Ptr", Stage, "Int", 0,
		"Ptr", Info, "UInt", Info.Size, "Int")
		throw OSError(A_LastError, "stage metadata")
}

; The publication: the file behind this handle takes Name in that folder handle,
; replacing what is there, so neither side is a pathname anyone could swap.
; @throws {Error} Carrying the NTSTATUS on refusal; the destination is unchanged.
_FSHeldRename(Stage, Folder, Name, ReplaceExisting := true) {
	static FileRenameInformation := 10
	NameOffset := 2 * A_PtrSize + 4
	Info := Buffer(NameOffset + StrLen(Name) * 2 + 2, 0)
	NumPut("UChar", ReplaceExisting ? 1 : 0, Info, 0)
	NumPut("Ptr", Folder, Info, A_PtrSize)
	NumPut("UInt", StrLen(Name) * 2, Info, 2 * A_PtrSize)
	StrPut(Name, Info.Ptr + NameOffset, "UTF-16")
	Io := Buffer(2 * A_PtrSize, 0)
	Status := DllCall("ntdll\NtSetInformationFile", "Ptr", Stage, "Ptr", Io, "Ptr", Info,
		"UInt", Info.Size, "UInt", FileRenameInformation, "UInt")
	if Status >= 0x80000000
		throw Error(Format("rename refused (NTSTATUS 0x{:08X})", Status))
}

; Deletes the unpublished stage through its handle: a name could be anyone's.
; A read-only attribute is cleared first since it refuses the disposition.
; @return {String} "" or the suffix telling the stage stayed on disk.
_FSDiscardHeldStage(Stage) {
	static ATTRIBUTES_OFFSET := 32, FILE_ATTRIBUTE_NORMAL := 0x80, FileDispositionInfo := 4
	Info := Buffer(FS_BASIC_INFO_BYTES, 0)
	NumPut("UInt", FILE_ATTRIBUTE_NORMAL, Info, ATTRIBUTES_OFFSET)
	Cleared := DllCall("kernel32\SetFileInformationByHandle", "Ptr", Stage, "Int", 0,
		"Ptr", Info, "UInt", Info.Size, "Int")
	Delete := Buffer(4, 0)
	NumPut("UChar", true, Delete, 0)
	if Cleared && DllCall("kernel32\SetFileInformationByHandle", "Ptr", Stage, "Int", FileDispositionInfo,
		"Ptr", Delete, "UInt", 1, "Int")
		return ""
	return Format("; the stage stayed on disk (error {})", A_LastError)
}

; Whether a path is a reparse point (a symbolic link or a junction), which a
; folder walk never follows: it can lead back up the tree.
; @param Path {String}
; @return {Boolean}
FSIsReparsePoint(Path) {
	return FSPathIsAdmissible(Path) && InStr(FileExist(Path), "L") > 0
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/unit/adapters/test_adapter_compliance.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_FILE_SYSTEM := Map(
    "read",   FSRead,
    "write",  FSWrite,
    "append", FSAppend,
    "exists", FSExists,
    "delete", FSDelete,
)


/** Configuration-only byte receipt; native opening errors never grant write authority. */
FSConfigReadUtf8Exact(Path, &NativeOpenError := 0) {
	static OriginalRead := FSReadUtf8Exact, HandleRead := _FSReadUtf8ExactHandle
	static Enter := FileReadActivityEnter, Bind := FileReadActivityBind, Leave := FileReadActivityLeave
	NativeOpenError := 0
	if OriginalRead != FSReadUtf8Exact || HandleRead != _FSReadUtf8ExactHandle
			|| Enter != FileReadActivityEnter || Bind != FileReadActivityBind || Leave != FileReadActivityLeave
		return false
	if !FSPathIsAdmissible(Path)
		return false
	static GENERIC_READ := 0x80000000
	static FILE_SHARE_READ := 0x00000001
	static OPEN_EXISTING := 3
	static FILE_ATTRIBUTE_NORMAL := 0x00000080
	Handle := -1
	OpeningReturned := false
	Closed := false
	Content := false
	for Owner in [OriginalRead, HandleRead, Enter, Bind, Leave]
		if Object.Prototype.HasOwnProp.Call(Owner, "Call")
			return false
	ReadActivity := Enter.Call(Path)
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
		OpeningReturned := true
		if Handle == -1
			NativeOpenError := A_LastError ; Capture the actual failed CreateFileW before cleanup.
		if Handle != -1 {
			if OriginalRead != FSReadUtf8Exact || HandleRead != _FSReadUtf8ExactHandle
					|| Enter != FileReadActivityEnter || Bind != FileReadActivityBind || Leave != FileReadActivityLeave
				return false
			for Owner in [OriginalRead, HandleRead, Enter, Bind, Leave]
				if Object.Prototype.HasOwnProp.Call(Owner, "Call")
					return false
			Bind.Call(ReadActivity, Handle)
			Content := HandleRead.Call(Handle, 0, false)
		}
	} catch {
		Content := false
	} finally {
		if Handle == -1 {
			; A returned failed opening owns no handle; a thrown acquisition stays debt.
			Closed := OpeningReturned
		} else {
			try Closed := DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int") != 0
			catch {
				Closed := false
			}
		}
		if Closed
			Leave.Call(ReadActivity)
	}
	return Closed ? Content : false
}

; Pure logical admission is consumed only within a configuration native span.
_FSNativeAdmissionAccepted(AdmissionFn) {
	if (AdmissionFn is Integer) && AdmissionFn == 0
		return true
	if !HasMethod(AdmissionFn, "Call")
		return false
	try {
		Accepted := AdmissionFn.Call()
		return (Accepted is Integer) && Accepted == 1
	} catch {
		return false
	}
}

/** Consumes captured unchanged-source admission within the configuration span. */
FSNativeAcknowledge(AdmissionFn := 0) {
	static Accept := _FSNativeAdmissionAccepted
	PreviousCritical := Critical("On")
	try {
		for Owner in [Accept]
			if Object.Prototype.HasOwnProp.Call(Owner, "Call")
				return false
		Accepted := Accept == _FSNativeAdmissionAccepted && Accept.Call(AdmissionFn)
		return Accepted && Accept == _FSNativeAdmissionAccepted
			&& !Object.Prototype.HasOwnProp.Call(Accept, "Call")
	}
	finally Critical(PreviousCritical)
}

/** Final pure admission immediately followed by the retained held-file rename. */
FSConfigHeldRename(Stage, Folder, Name, ReplaceExisting, AdmissionFn) {
	static Accept := _FSNativeAdmissionAccepted, Rename := _FSHeldRename
	PreviousCritical := Critical("On")
	try {
		for Owner in [Accept, Rename]
			if Object.Prototype.HasOwnProp.Call(Owner, "Call")
				return false
		if Accept != _FSNativeAdmissionAccepted || Rename != _FSHeldRename || !Accept.Call(AdmissionFn)
				|| Accept != _FSNativeAdmissionAccepted || Rename != _FSHeldRename
			return false
		for Owner in [Accept, Rename]
			if Object.Prototype.HasOwnProp.Call(Owner, "Call")
				return false
		Rename.Call(Stage, Folder, Name, ReplaceExisting)
		return true
	} finally Critical(PreviousCritical)
}

/** Configuration replacement through the retained genuine write-through producer. */
FSConfigAtomicMoveReplace(Source, Destination, &NativeError := 0, AdmissionFn := 0) {
	static Accept := _FSNativeAdmissionAccepted
	static Move := FSAtomicMoveReplace
	NativeError := 0
	PreviousCritical := Critical("On")
	try {
		for Owner in [Accept, Move]
			if Object.Prototype.HasOwnProp.Call(Owner, "Call")
				return false
		if Move != FSAtomicMoveReplace || Accept != _FSNativeAdmissionAccepted || !Accept.Call(AdmissionFn)
				|| Accept != _FSNativeAdmissionAccepted
				|| Move != FSAtomicMoveReplace {
			; No native operation ran, so no Win32 error receipt is invented.
			return false
		}
		for Owner in [Accept, Move]
			if Object.Prototype.HasOwnProp.Call(Owner, "Call")
				return false
		return Move.Call(Source, Destination, &NativeError)
	} finally Critical(PreviousCritical)
}

/** Configuration-only no-replace publication keeps the existing producer receipt. */
FSConfigAtomicMoveCreate(Source, Destination, AdmissionFn := 0) {
	static Accept := _FSNativeAdmissionAccepted
	static Move := FSAtomicMoveCreate
	PreviousCritical := Critical("On")
	try {
		for Owner in [Accept, Move]
			if Object.Prototype.HasOwnProp.Call(Owner, "Call")
				return false
		if Move != FSAtomicMoveCreate || Accept != _FSNativeAdmissionAccepted || !Accept.Call(AdmissionFn)
				|| Accept != _FSNativeAdmissionAccepted
				|| Move != FSAtomicMoveCreate
			return 0
		for Owner in [Accept, Move]
			if Object.Prototype.HasOwnProp.Call(Owner, "Call")
				return false
		return Move.Call(Source, Destination)
	} finally Critical(PreviousCritical)
}

/** Configuration-owned recovery removal retains the original strict delete receipt. */
FSConfigDeleteStrict(Path, AdmissionFn := 0) {
	static Accept := _FSNativeAdmissionAccepted
	static Delete := FSDeleteStrict, Receipt := _FSDeleteNativeReceipt
	static DeleteWith := _FSDeleteWith, Exists := FSStrictExists
	PreviousCritical := Critical("On")
	try {
		for Owner in [Accept, Delete, Receipt, DeleteWith, Exists]
			if Object.Prototype.HasOwnProp.Call(Owner, "Call")
				return false
		if Delete != FSDeleteStrict || Receipt != _FSDeleteNativeReceipt
				|| DeleteWith != _FSDeleteWith || Exists != FSStrictExists
				|| Accept != _FSNativeAdmissionAccepted || !Accept.Call(AdmissionFn)
				|| Accept != _FSNativeAdmissionAccepted
				|| Delete != FSDeleteStrict || Receipt != _FSDeleteNativeReceipt
				|| DeleteWith != _FSDeleteWith || Exists != FSStrictExists
			return 0
		for Owner in [Accept, Delete, Receipt, DeleteWith, Exists]
			if Object.Prototype.HasOwnProp.Call(Owner, "Call")
				return false
		return Delete.Call(Path)
	} finally Critical(PreviousCritical)
}


/** Publishes a strict UTF-8 control through an owned, durably written stage. */
FSWriteUtf8ReplaceStrict(Path, Text, StageFn := 0) {
	Detail := ""
	if !FSWriteReplaceOwned(Path, Text, ".tmp", &Detail, StageFn)
		throw Error("Diagnostic control publication failed: " . Detail)
}

/** Encodes the complete UTF-8 image without its additional terminator byte. */
FSUtf8Bytes(Content) {
	Size := StrPut(Content, "UTF-8") - 1
	Bytes := Buffer(Size, 0)
	Encoded := Buffer(Size + 1, 0)
	StrPut(Content, Encoded, "UTF-8")
	DllCall("RtlMoveMemory", "Ptr", Bytes.Ptr, "Ptr", Encoded.Ptr, "UPtr", Size)
	return Bytes
}





; ==================================================
; ==================================================
; ======= 2/ Classified read and publication =======
; ==================================================
; ==================================================

; The methods of _shared/lua/file_system/ports.lua. AutoHotkey has no multiple
; return, so a result is a Map: read_with_status gives content, status and
; detail, a publication gives committed and detail.
global FS_STATUS_OK := "ok"
global FS_STATUS_ABSENT := "absent"
global FS_STATUS_ERROR := "error"

; Reports one fixed failure category: never a path, never file content.
_FSReportFailure(OnError, Category) {
	if HasMethod(OnError, "Call")
		OnError.Call(Category)
	return Category
}

; Reads a classified source a publication can later be conditioned on.
; @param Path {String} File path.
; @param OnError {Func|0} Receives the fixed category of an unreadable source.
; @returns {Map} content ("" unless ok), status (FS_STATUS_*), detail.
FSReadWithStatus(Path, OnError := 0) {
	NativeOpenError := 0
	Content := FSConfigReadUtf8Exact(Path, &NativeOpenError)
	if (Content is String)
		return Map("content", Content, "status", FS_STATUS_OK, "detail", "")
	if (NativeOpenError == 2 || NativeOpenError == 3)
		return Map("content", "", "status", FS_STATUS_ABSENT, "detail", "")
	return Map("content", "", "status", FS_STATUS_ERROR,
		"detail", _FSReportFailure(OnError, "the source cannot be read"))
}

; Whether a path still holds the classified source a caller read.
_FSSourceIsUnchanged(Path, Expected) {
	Current := FSReadWithStatus(Path)
	return Current["status"] == Expected["status"]
		&& (Expected["status"] != FS_STATUS_OK || Current["content"] == Expected["content"])
}

; Retains the created same-directory stage through publication and refusal.
; Source checks are preconditions, not a kernel compare-and-swap with other writers.
_FSPublishIfUnchanged(Path, Content, Expected, OnError, AdmissionFn) {
	static StageSerial := 0
	Refuse(Category) => Map("committed", false, "detail", _FSReportFailure(OnError, Category))
	if !FSPathIsAdmissible(Path) || !(Content is String) || !(Expected is Map)
			|| !Expected.Has("status") || (Expected["status"] != FS_STATUS_ABSENT
				&& (Expected["status"] != FS_STATUS_OK || !(Expected.Get("content", 0) is String)))
		return Refuse("a publication needs a path, a string payload and a source precondition")
	; Capture relative targets before a source read or admission can yield.
	try Path := FSResolveAbsolutePath(Path)
	catch
		return Refuse("the publication target cannot be captured")
	if !_FSSourceIsUnchanged(Path, Expected)
		return Refuse("the source changed since it was read")
	Suffix := "." . A_ScriptHwnd . "-" . (++StageSerial) . ".tmp"
	; Staging and logical admission may yield or change the source. Revalidate
	; after the caller's final admission, inside the publication boundary.
	FinalAdmission := () => _FSNativeAdmissionAccepted(AdmissionFn) && _FSSourceIsUnchanged(Path, Expected)
	if FSWriteReplaceOwned(Path, Content, Suffix, &Detail, 0, 0, FinalAdmission,
			Expected["status"] == FS_STATUS_OK, &Publication)
		return Map("committed", true, "detail", "")
	; Fixed categories keep this portable diagnostic free of paths and file text.
	if Publication.renamed
		return Refuse("the publication changed the target but durability was not acknowledged")
	return Refuse("the publication was refused")
}

; Atomic replacement, refused when the file no longer matches `Expected`.
; @param Path {String} Destination.
; @param Content {String} Complete replacement text.
; @param Expected {Map} status and, for FS_STATUS_OK, content.
; @param OnError {Func|0} Receives the fixed category of a refusal.
; @returns {Map} committed, detail.
FSWriteIfUnchanged(Path, Content, Expected, OnError := 0) {
	return _FSPublishIfUnchanged(Path, Content, Expected, OnError, 0)
}

; The same publication with a final logical admission checked just before commit.
; @param Admission {Func} Returns 1 to admit; required.
; @returns {Map} committed, detail.
FSWriteIfUnchangedAdmitted(Path, Content, Expected, OnError, Admission) {
	if !HasMethod(Admission, "Call")
		return Map("committed", false, "detail", _FSReportFailure(OnError, "publication admission required"))
	return _FSPublishIfUnchanged(Path, Content, Expected, OnError, Admission)
}

; The owner's own method identities, without IO. Windows offers no optional
; capability, so the removers are 0.
; @returns {Map} owner, reader, writer, publisher, remover, admitted_remover,
;   exact_remover, delete.
FSConfigurationPorts() {
	return Map("owner", FILE_SYSTEM_OWNER, "reader", FILE_SYSTEM_OWNER["read_with_status"],
		"writer", FILE_SYSTEM_OWNER["write_if_unchanged"],
		"publisher", FILE_SYSTEM_OWNER["write_if_unchanged_admitted"],
		"remover", 0, "admitted_remover", 0, "exact_remover", 0,
		"delete", FILE_SYSTEM_OWNER["delete"])
}

; The owner the shared spec describes. ADAPTER_FILE_SYSTEM stays the five portable
; methods of FileSystem.spec.js. Checked when the file loads: a missing method or a
; half-offered capability would otherwise fail late, inside a publication.
global FILE_SYSTEM_OWNER := Map(
	"read", FSRead,
	"write", FSWrite,
	"append", FSAppend,
	"exists", FSExists,
	"delete", FSDelete,
	"read_with_status", FSReadWithStatus,
	"write_if_unchanged", FSWriteIfUnchanged,
	"write_if_unchanged_admitted", FSWriteIfUnchangedAdmitted,
	"configuration_ports", FSConfigurationPorts
)
FSPortsCheckOwner(FILE_SYSTEM_OWNER)
