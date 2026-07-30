; tests/unit/test_personal_info_unreadable_never_persisted.ahk

; ==============================================================================
; MODULE: Regression — an unreadable personal_info.toml is never overwritten
;         with the shipped placeholder identity
;         (personal-info-unreadable-read-not-latched)
; DESCRIPTION:
; personal_info.toml holds the user's real first and last name, e-mail, phone,
; street address, IBAN, BIC, credit-card number and social-security number. It
; is read exactly once, at boot, and the config directory is explicitly
; documented as cloud-shareable — so a sync client, an AV on-access scan, a
; backup agent or the user's own editor can hold it for the few milliseconds
; that read takes.
;
; ROOT CAUSE ENCODED: the read's catch logged and returned bare. The compiled-in
; placeholder Map ("Prénom", "FR00 0000 …", "1234 5678 9012 3456") stayed in
; memory, nothing re-read the file afterwards, and the editor renders straight
; from those globals. Opening « Informations personnelles » and clicking OK then
; serialised every key of that placeholder Map over the file. The real identity
; was gone, unrecoverably, and the save reported success.
;
; The distinction between "could not read" and "was empty" therefore has to be
; recorded at READ time and honoured by the writer — checking at write time is
; useless, because by then the transient lock has cleared. The sibling pair 200
; lines above in the same file already did exactly this; this one did not.
; ==============================================================================

#Requires AutoHotkey v2.0

; Deny-everything share mode: the reader's FileRead must genuinely fail.
global _PIU_EXCLUSIVE_LOCK_FLAGS := "r-rwd"

_PIU_IsFlagged(Path) {
	global _TomlUnreadableFiles
	return IsSet(_TomlUnreadableFiles) && _TomlUnreadableFiles.Has(Path)
}

_PIU_ClearFlag(Path) {
	global _TomlUnreadableFiles
	if (IsSet(_TomlUnreadableFiles) && _TomlUnreadableFiles.Has(Path))
		_TomlUnreadableFiles.Delete(Path)
}






; =========================================================
; =========================================================
; ======= 1/ A failed read must block the next save =======
; =========================================================
; =========================================================

_PIU_UnreadableReadBlocksTheWrite() {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	Q := Chr(34)
	LF := Chr(10)
	Path := A_Temp . "\ergopti_test_personal_info_" . A_TickCount . ".toml"
	SavedInfo := IsSet(PersonalInformation) ? PersonalInformation : Map()
	SavedLetters := IsSet(PersonalInformationLetters) ? PersonalInformationLetters : Map()
	SavedCache := IsSet(_ReadPersonalInfoTomlCache) ? _ReadPersonalInfoTomlCache : false

	try FileDelete(Path)
	FileAppend("[info]" . LF . "first_name = " . Q . "RealName" . Q . LF, Path, "UTF-8")
	Before := FileRead(Path, "UTF-8")
	_PIU_ClearFlag(Path)

	; The in-memory model is the shipped placeholder — byte-for-byte what a user
	; who never filled the form produces, which is why the writer cannot tell the
	; two apart on its own.
	PersonalInformation := Map("first_name", "Prénom")
	PersonalInformationLetters := Map()
	_ReadPersonalInfoTomlCache := false

	Lock := FileOpen(Path, _PIU_EXCLUSIVE_LOCK_FLAGS)
	Assert(IsObject(Lock),
		"the test could not take an exclusive lock — it would otherwise assert nothing")
	Threw := ""
	try {
		ReadPersonalInfoToml(Path)
	} catch as Err {
		Threw := Err.Message
	}
	Flagged := _PIU_IsFlagged(Path)
	; Release the lock BEFORE the save: that is the real sequence. The lock is
	; transient, the damage is not, and every write-time re-check would pass here.
	Lock.Close()

	WriteResult := WritePersonalInfoToml(Path)
	After := FileRead(Path, "UTF-8")

	; Now that the file is readable again, the latch must lower itself and the
	; real identity must load.
	_ReadPersonalInfoTomlCache := false
	ReadPersonalInfoToml(Path)
	StillFlagged := _PIU_IsFlagged(Path)
	Loaded := PersonalInformation.Has("first_name") ? PersonalInformation["first_name"] : ""

	try FileDelete(Path)
	_PIU_ClearFlag(Path)
	PersonalInformation := SavedInfo
	PersonalInformationLetters := SavedLetters
	_ReadPersonalInfoTomlCache := SavedCache

	Assert(Threw == "",
		"ReadPersonalInfoToml must not throw on a locked file — it runs from the boot sequence, where an exception is an aborted boot. Got: " . Threw)
	Assert(Flagged,
		"a personal_info.toml that exists but cannot be read must be flagged unreadable. The placeholder identity left in memory is byte-for-byte what a user who never filled the form produces, and WritePersonalInfoToml serialises exactly that over the file")
	Assert(!WriteResult,
		"the writer must refuse while the flag is up — otherwise one transient lock at boot plus one visit to the editor destroys the user's real name, address, IBAN, card number and social-security number")
	Assert(After == Before,
		"refusing must mean not writing: the file has to be byte-identical to what it held before the save")
	Assert(!StillFlagged,
		"a later successful read must lower the latch, or the guard would block every save for the rest of the session")
	Assert(Loaded == "RealName",
		"and that read must load the user's real data — the guard must not have cost us the read itself")
}
Test("personal info: an unreadable read blocks the next save (personal-info-unreadable-read-not-latched)",
	_PIU_UnreadableReadBlocksTheWrite)
