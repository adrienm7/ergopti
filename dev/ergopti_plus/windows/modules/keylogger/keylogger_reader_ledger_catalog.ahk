; modules/keylogger/keylogger_reader_ledger_catalog.ahk

; ==============================================================================
; MODULE: Reader Ledger Catalog
; DESCRIPTION: Distinguish a complete empty catalog from native discovery failure.
; ==============================================================================

#Requires AutoHotkey v2.0

; A transient source-access failure cannot authorize deleting a valid cache.
class KLRLedgerListingError extends OSError {
}

; An unreadable identity cannot establish that a previously valid image is stale.
class KLRLedgerSnapshotError extends Error {
}

_KLR_LedgerAttributes(Path) {
	Attributes := DllCall("Kernel32\GetFileAttributesW", "Str", Path, "UInt")
	Code := A_LastError
	if Attributes != 0xFFFFFFFF
		return Attributes
	if Code = 2 || Code = 3 ; Missing file or parent path is a real absence.
		return -1
	throw KLRLedgerListingError(Code)
}

; @param MetricsDir {String} Store prefix including its trailing separator.
; @returns {Array} Complete ledger paths preserving the supplied store prefix.
; @throws {KLRLedgerListingError} Native access, enumeration or path-type failure.
KLR_ListLedgerPaths(MetricsDir) {
	Root := MetricsDir . "by_device\"
	Attributes := _KLR_LedgerAttributes(RTrim(Root, "\/"))
	if Attributes = -1
		return []
	if !(Attributes & 0x10)
		throw KLRLedgerListingError(267) ; ERROR_DIRECTORY
	; WIN32_FIND_DATAW is 592 bytes on both supported pointer widths. The
	; native filename begins at byte 44; never substitute a canonical FullPath.
	Data := Buffer(592, 0)
	Handle := DllCall("Kernel32\FindFirstFileW", "Str", Root . "*", "Ptr", Data, "Ptr")
	Code := A_LastError
	if Handle = -1 {
		if Code = 2 ; No matching entries, rather than a failed directory read.
			return []
		throw KLRLedgerListingError(Code)
	}
	Paths := []
	try {
		loop {
			Name := StrGet(Data.Ptr + 44, "UTF-16")
			if (NumGet(Data, 0, "UInt") & 0x10) && Name != "." && Name != ".." {
				Path := Root . Name . "\data.sql"
				FileAttributes := _KLR_LedgerAttributes(Path)
				if FileAttributes != -1 {
					if FileAttributes & 0x10
						throw KLRLedgerListingError(267)
					Paths.Push(Path)
				}
			}
			if !DllCall("Kernel32\FindNextFileW", "Ptr", Handle, "Ptr", Data) {
				Code := A_LastError
				if Code != 18 ; Only ERROR_NO_MORE_FILES proves complete discovery.
					throw KLRLedgerListingError(Code)
				break
			}
		}
	} finally {
		if !DllCall("Kernel32\FindClose", "Ptr", Handle)
			throw KLRLedgerListingError(A_LastError)
	}
	return Paths
}
