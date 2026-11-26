; core/fs/adapters/sqlite_copy_on_write.ahk

; ==============================================================================
; MODULE: SQLite copy-on-write overlay
; DESCRIPTION:
; Opens a writable private view of a database file that another handle holds
; read-only, without copying it. The file is mapped copy-on-write: a page the
; overlay writes becomes private to this process, every other page is read from
; the shared file cache, and the file itself is never written. SQLite serves
; the view as an in-memory database (sqlite3_deserialize), so a worker can
; apply a ledger tail and replay its days on the reader image that every
; worker shares while nobody, the file included, can observe the change.
;
; WHY IT EXISTS:
; A worker that found new ledger bytes copied the whole image before applying
; them, because the image is shared: 6 to 20 s for a 1.1 GB image even for
; 47 KB of new data.sql (KLR_CloneCandidate). The overlay costs what the
; refresh writes, not what the image holds.
;
; INVARIANTS:
; 1. The shared file is mapped PAGE_WRITECOPY: no write can reach it, so a
;    failure mid-apply leaves it intact and its readers never see a partial
;    state. Discarding the overlay is the only rollback.
; 2. The view is followed by a committed growth area in one reserved range
;    (Windows placeholders), so the database can grow by SlackBytes. Past that
;    SQLite reports SQLITE_FULL: the refresh fails loud, it never truncates.
; 3. The mapping outlives the handle until sqlite3_close succeeds. A close
;    SQLite refuses keeps the mapping for the process lifetime rather than
;    freeing memory a zombie connection could still read.
; ==============================================================================

#Requires AutoHotkey v2.0+





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

class SQLiteCowConst {
	static FCNTL_WIN32_GET_HANDLE := 29
	static PAGE_NOACCESS := 0x01
	static PAGE_READONLY := 0x02
	static PAGE_READWRITE := 0x04
	static PAGE_WRITECOPY := 0x08
	static MEM_COMMIT := 0x1000
	static MEM_RESERVE := 0x2000
	static MEM_REPLACE_PLACEHOLDER := 0x4000
	static MEM_RESERVE_PLACEHOLDER := 0x40000
	static MEM_RELEASE := 0x8000
	static MEM_PRESERVE_PLACEHOLDER := 0x2
	; Placeholders split and views map on the allocation granularity.
	static GRANULARITY := 0x10000
}

; Mapped regions by overlay handle, released once SQLite closes the handle.
class SQLiteCowRegions {
	static ByDb := Map()
}





; ============================
; ============================
; ======= 2/ Lifecycle =======
; ============================
; ============================

; Opens a private writable overlay of the file behind SourceDb's main database.
; SourceDb stays open and unchanged; the overlay maps the very file object
; SourceDb validated, so a peer that publishes a new image at the same path in
; between cannot change what the overlay holds.
; @param SourceDb {Integer} Open handle whose main database is a file.
; @param SlackBytes {Integer} Growth the overlay accepts beyond the file size.
; @param CacheKiB {Integer} SQLite page cache bound of the overlay, in KiB.
; @returns {Integer} The overlay handle; throws when it cannot be built.
SQLite_OpenCopyOnWrite(SourceDb, SlackBytes, CacheKiB) {
	if !SourceDb
		throw ValueError("A copy-on-write overlay needs an open source database.")
	if !(SlackBytes is Integer) || SlackBytes <= 0
		throw ValueError("A copy-on-write overlay needs a positive growth allowance.")
	if !(CacheKiB is Integer) || CacheKiB <= 0
		throw ValueError("A copy-on-write overlay needs a positive page cache bound in KiB.")
	C := SQLiteCowConst
	FileHandle := 0
	MainName := SQLite_StrToUtf8("main", &MainBuf)
	Rc := DllCall(SQLiteConst.DLL . "\sqlite3_file_control", "Ptr", SourceDb, "Ptr", MainName,
		"Int", C.FCNTL_WIN32_GET_HANDLE, "Ptr*", &FileHandle, "Int")
	if Rc != SQLiteConst.OK || !FileHandle || FileHandle = -1
		throw Error("The source database has no file to map (SQLite " . Rc . ").")
	Size := 0
	if !DllCall("GetFileSizeEx", "Ptr", FileHandle, "Int64*", &Size, "Int")
		throw OSError(A_LastError, "GetFileSizeEx")
	if Size <= 0
		throw Error("The source database file is empty.")
	Gran := C.GRANULARITY
	Head := Size // Gran * Gran
	Total := Head + (Size - Head + SlackBytes + Gran - 1) // Gran * Gran
	Region := Map("base", 0, "head", Head, "total", Total, "size", Size)
	Section := 0
	Db := 0
	Owned := false
	try {
		Section := DllCall("CreateFileMappingW", "Ptr", FileHandle, "Ptr", 0, "UInt", C.PAGE_READONLY,
			"UInt", 0, "UInt", 0, "Ptr", 0, "Ptr")
		if !Section
			throw OSError(A_LastError, "CreateFileMappingW")
		Base := DllCall("kernelbase\VirtualAlloc2", "Ptr", 0, "Ptr", 0, "UPtr", Total,
			"UInt", C.MEM_RESERVE | C.MEM_RESERVE_PLACEHOLDER, "UInt", C.PAGE_NOACCESS,
			"Ptr", 0, "UInt", 0, "Ptr")
		if !Base
			throw OSError(A_LastError, "VirtualAlloc2 placeholder")
		Region["base"] := Base
		Region["placeholder"] := true
		if Head {
			if !DllCall("VirtualFree", "Ptr", Base, "UPtr", Head,
					"UInt", C.MEM_RELEASE | C.MEM_PRESERVE_PLACEHOLDER, "Int")
				throw OSError(A_LastError, "VirtualFree placeholder split")
			Region["split"] := true
			View := DllCall("kernelbase\MapViewOfFile3", "Ptr", Section, "Ptr", -1, "Ptr", Base,
				"UInt64", 0, "UPtr", Head, "UInt", C.MEM_REPLACE_PLACEHOLDER, "UInt", C.PAGE_WRITECOPY,
				"Ptr", 0, "UInt", 0, "Ptr")
			if View != Base
				throw OSError(A_LastError, "MapViewOfFile3 copy-on-write")
			Region["view"] := true
		}
		Growth := DllCall("kernelbase\VirtualAlloc2", "Ptr", 0, "Ptr", Base + Head, "UPtr", Total - Head,
			"UInt", C.MEM_RESERVE | C.MEM_COMMIT | C.MEM_REPLACE_PLACEHOLDER, "UInt", C.PAGE_READWRITE,
			"Ptr", 0, "UInt", 0, "Ptr")
		if Growth != Base + Head
			throw OSError(A_LastError, "VirtualAlloc2 growth area")
		Region["growth"] := true
		; The last partial granule cannot be mapped into its own placeholder; it
		; is read into the growth area at its own offset instead.
		if Size > Head
			_SQLiteCow_ReadAt(FileHandle, Head, Base + Head, Size - Head)
		Db := SQLite_Open(":memory:")
		if !Db
			throw Error("SQLite could not open the overlay connection.")
		Rc := DllCall(SQLiteConst.DLL . "\sqlite3_deserialize", "Ptr", Db, "Ptr", MainName,
			"Ptr", Base, "Int64", Size, "Int64", Total, "UInt", 0, "Int")
		if Rc != SQLiteConst.OK
			throw Error("SQLite refused the copy-on-write image (" . Rc . ").")
		if !SQLite_Exec(Db, "PRAGMA cache_size=-" . CacheKiB . ";")
			throw Error("The overlay page cache could not be bounded.")
		SQLiteCowRegions.ByDb[Db] := Region
		Owned := true
		return Db
	} finally {
		if Section
			DllCall("CloseHandle", "Ptr", Section)
		if !Owned {
			; Nothing the failed open built may survive it.
			if Db
				DllCall(SQLiteConst.DLL . "\sqlite3_close", "Ptr", Db, "Int")
			_SQLiteCow_Release(Region)
		}
	}
}

; @param Db {Integer} Any SQLite handle.
; @returns {Boolean} Whether Db is a live copy-on-write overlay.
SQLite_IsCopyOnWrite(Db) {
	return SQLiteCowRegions.ByDb.Has(Db)
}

; Closes an overlay and unmaps it once SQLite has let go of every page. A
; refusal leaves the handle and its mapping owned by the caller, as
; sqlite3_close does.
; @param Db {Integer} Overlay handle from SQLite_OpenCopyOnWrite.
; @returns {Integer} The sqlite3_close result.
SQLite_CloseCopyOnWrite(Db) {
	Region := SQLiteCowRegions.ByDb[Db]
	Rc := DllCall(SQLiteConst.DLL . "\sqlite3_close", "Ptr", Db, "Int")
	if Rc = SQLiteConst.OK {
		SQLiteCowRegions.ByDb.Delete(Db)
		_SQLiteCow_Release(Region)
	}
	return Rc
}

; Closes an overlay even while statements still borrow it. SQLite then keeps a
; zombie connection that may read the view until its last statement ends, so
; the mapping is left for the process lifetime instead of being freed under it.
; @param Db {Integer} Overlay handle from SQLite_OpenCopyOnWrite.
SQLite_AbandonCopyOnWrite(Db) {
	if SQLite_CloseCopyOnWrite(Db) = SQLiteConst.OK
		return
	SQLiteCowRegions.ByDb.Delete(Db)
	DllCall(SQLiteConst.DLL . "\sqlite3_close_v2", "Ptr", Db)
	try LoggerWarn("sqlite3", "A copy-on-write overlay closed with live statements; its mapping stays until exit.")
}





; ==========================
; ==========================
; ======= 3/ Helpers =======
; ==========================
; ==========================

_SQLiteCow_ReadAt(FileHandle, Offset, Dest, Count) {
	; An explicit offset leaves the handle's file pointer to SQLite.
	Overlapped := Buffer(A_PtrSize = 8 ? 32 : 20, 0)
	NumPut("UInt", Offset & 0xFFFFFFFF, Overlapped, 2 * A_PtrSize)
	NumPut("UInt", Offset >> 32, Overlapped, 2 * A_PtrSize + 4)
	Read := 0
	if !DllCall("ReadFile", "Ptr", FileHandle, "Ptr", Dest, "UInt", Count, "UInt*", &Read,
			"Ptr", Overlapped, "Int")
		throw OSError(A_LastError, "ReadFile overlay tail")
	if Read != Count
		throw Error("The overlay read " . Read . " of the last " . Count . " byte(s) of the image.")
}

_SQLiteCow_Release(Region) {
	Base := Region["base"]
	if !Base
		return
	Head := Region["head"]
	Released := true
	if Region.Get("split", false) {
		Released := Region.Get("view", false)
			? DllCall("UnmapViewOfFile", "Ptr", Base, "Int")
			: DllCall("VirtualFree", "Ptr", Base, "UPtr", 0, "UInt", SQLiteCowConst.MEM_RELEASE, "Int")
		Released := DllCall("VirtualFree", "Ptr", Base + Head, "UPtr", 0,
			"UInt", SQLiteCowConst.MEM_RELEASE, "Int") && Released
	} else
		Released := DllCall("VirtualFree", "Ptr", Base, "UPtr", 0, "UInt", SQLiteCowConst.MEM_RELEASE, "Int")
	Region["base"] := 0
	if !Released
		try LoggerError("sqlite3", "A copy-on-write overlay region could not be released ({1}).", A_LastError)
}
