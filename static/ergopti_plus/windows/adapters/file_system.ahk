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
