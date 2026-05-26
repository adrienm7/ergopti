; adapters/file_system.ahk

; ==============================================================================
; MODULE: FileSystem Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the FileSystem port contract defined in
; static/drivers/_shared/ports/FileSystem.spec.js. Wraps AHK v2's
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
; @return {String|0} File contents on success, 0 on any error.
FSRead(Path) {
	if !(Path is String) or Path = ""
		return 0
	try {
		local Content := ""
		FileRead(Content, "UTF-8:" . Path)
		return Content
	} catch {
		return 0
	}
}

; Writes content to a file, overwriting any existing content.
; Creates the file if it does not exist.
; @param Path    {String} Absolute path to the file.
; @param Content {String} UTF-8 content to write.
; @return {Integer} 1 on success, 0 on any error.
FSWrite(Path, Content) {
	if !(Path is String) or Path = ""
		return 0
	if !(Content is String)
		Content := ""
	try {
		local FH := FileOpen(Path, "w", "UTF-8")
		if !IsObject(FH)
			return 0
		FH.Write(Content)
		FH.Close()
		return 1
	} catch {
		return 0
	}
}

; Appends content to a file, creating it if it does not exist.
; @param Path    {String} Absolute path to the file.
; @param Content {String} UTF-8 content to append.
; @return {Integer} 1 on success, 0 on any error.
FSAppend(Path, Content) {
	if !(Path is String) or Path = ""
		return 0
	if !(Content is String)
		Content := ""
	try {
		local FH := FileOpen(Path, "a", "UTF-8")
		if !IsObject(FH)
			return 0
		FH.Write(Content)
		FH.Close()
		return 1
	} catch {
		return 0
	}
}

; Returns 1 if a file or directory exists at the given path, 0 otherwise.
; @param Path {String} Absolute path to test.
; @return {Integer} 1 if exists, 0 otherwise.
FSExists(Path) {
	if !(Path is String) or Path = ""
		return 0
	; FileExist returns a non-empty attribute string on match, "" on miss
	return FileExist(Path) != "" ? 1 : 0
}

; Deletes a file. Returns 1 if deleted or already absent, 0 on error.
; @param Path {String} Absolute path to the file to delete.
; @return {Integer} 1 on success or file-not-found, 0 on any other error.
FSDelete(Path) {
	if !(Path is String) or Path = ""
		return 0
	; Already absent — contract says this is a no-op success
	if !FSExists(Path)
		return 1
	try {
		FileDelete(Path)
		return 1
	} catch {
		return 0
	}
}
