; adapters/file_publication.ahk

; Windows-only publication receipts for a staged binary file. Copying into an
; exclusive destination sibling supports another source volume; renaming that
; same handle exposes a complete file without adopting or replacing any path.

; Returns published + the stable identity receipt, or false + no receipt.
; The original stage stays with its worker for the existing final cleanup.
FSPublishCreateOwned(Source, Destination) {
	static Nonce := 0
	Receipt := Map("published", false, "snapshot", 0)
	Reader := 0, Writer := -1, Renamed := false, WriterClosed := false
	try {
		Reader := FSOpenStrict(Source, "r-wd", "UTF-8-RAW")
		if !IsObject(Reader)
			return Receipt
		Reader.Pos := 0
		SplitPath(Destination, &Name, &Directory)
		if Name == ""
			return Receipt
		Directory := FSResolveDirectoryPath(Directory == "" ? A_WorkingDir : Directory)
		Final := Directory . "\" . Name
		WasCritical := Critical("On")
		try Sibling := Final . ".ergopti-stage." . DllCall("kernel32\GetCurrentProcessId", "UInt") . "." . ++Nonce
		finally Critical(WasCritical)
		; READ | WRITE | DELETE, no sharing, CREATE_NEW. The handle owns both
		; the byte writes and any pre-publication cleanup, even on failure.
		Writer := DllCall("kernel32\CreateFileW", "Str", Sibling, "UInt", 0xC0010000,
			"UInt", 0, "Ptr", 0, "UInt", 1, "UInt", 0x80, "Ptr", 0, "Ptr")
		if Writer == -1
			return Receipt
		Bytes := Buffer(65536), ExpectedSize := Reader.Length, Copied := 0
		while Copied < ExpectedSize {
			Read := Reader.RawRead(Bytes, Min(Bytes.Size, ExpectedSize - Copied))
			Written := 0
			if Read <= 0 || !_FSNativeWrite(Writer, Bytes, Read, &Written) || Written != Read
				return Receipt
			Copied += Read
		}
		if !DllCall("kernel32\FlushFileBuffers", "Ptr", Writer, "Int")
			return Receipt
		Created := FSHandleSnapshot(Writer)
		if !Created.Get("ok", false) || Created["size"] != ExpectedSize
			return Receipt
		if !_FSRenameOwnedHandleCreate(Writer, Final)
			return Receipt
		Renamed := true
	} catch {
		return Receipt
	} finally {
		if Writer != -1 {
			if !Renamed
				_FSDeleteOwnedHandle(Writer)
			try WriterClosed := DllCall("kernel32\CloseHandle", "Ptr", Writer, "Int") != 0
		}
		if IsObject(Reader)
			Reader.Close()
	}
	if !WriterClosed
		return Receipt
	; LastWriteTime is final only after all writer handles close. Reopen under
	; a write/delete exclusion and match the created identity before taking the
	; stable full snapshot. A replacement between close and reopen is refused.
	Reader := 0
	try {
		Reader := FSOpenStrict(Final, "r-wd", "UTF-8-RAW")
		if !IsObject(Reader)
			return Receipt
		Observed := FSHandleSnapshot(Reader.Handle)
		if !Observed.Get("ok", false)
			return Receipt
		for Key in ["volume", "index_high", "index_low", "size"]
			if Created[Key] != Observed[Key]
				return Receipt
		Receipt["published"] := true
		Receipt["snapshot"] := Observed
	} catch {
		return Receipt
	} finally {
		if IsObject(Reader)
			Reader.Close()
	}
	return Receipt
}

_FSDeleteOwnedHandle(Handle) {
	Disposition := Buffer(1, 1)
	try return DllCall("kernel32\SetFileInformationByHandle", "Ptr", Handle,
		"Int", 4, "Ptr", Disposition, "UInt", 1, "Int") != 0
	catch
		return false
}

; FILE_RENAME_INFO: BOOLEAN + aligned HANDLE + DWORD byte length + UTF-16 name.
; RootDirectory is null and ReplaceIfExists is false in the zeroed structure.
_FSRenameOwnedHandleCreate(Handle, Destination) {
	LengthOffset := A_PtrSize == 8 ? 16 : 8
	NameOffset := LengthOffset + 4
	NameBytes := StrPut(Destination, "UTF-16") - 2
	Info := Buffer(NameOffset + NameBytes + 2, 0)
	NumPut("UInt", NameBytes, Info, LengthOffset)
	StrPut(Destination, Info.Ptr + NameOffset, NameBytes // 2 + 1, "UTF-16")
	return DllCall("kernel32\SetFileInformationByHandle", "Ptr", Handle,
		"Int", 3, "Ptr", Info, "UInt", Info.Size, "Int") != 0
}
