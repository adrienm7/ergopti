; tests/meta/test_hcw_patch_toml_meta_refuses_unread_file.ahk

; ==============================================================================
; MODULE: HCW personal TOML metadata transaction guard
; DESCRIPTION:
; Verifies that _HCW_PatchTomlMeta delegates its complete read-modify-publish
; lifetime to the path-owned personal TOML transaction helper. The helper must
; reject unreadable source state before publishing through the atomic writer.
;
; ROOT CAUSE ENCODED: a lease acquired after ReadTomlFile cannot protect the
; snapshot it is meant to serialize, while FileOpen(Path, "w") destroys the old
; target before any later failure can be rolled back. Keeping the read,
; unreadable-file guard and same-directory atomic publication in one shared
; helper removes both failure windows.
;
; SCOPE: this source-level delegation guard complements behavioural tests in
; test_personal_toml_io.ahk, where the shared helper is in the headless include
; graph and injected failures prove byte preservation and lease ordering.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================================
; ==========================================================
; ======= 1/ Owned transaction delegation ================
; ==========================================================
; ==========================================================

_PTMU_PatcherDelegatesWithoutDirectIo() {
	PatcherBody := _DriverFuncBody("_HCW_PatchTomlMeta")
	Assert(InStr(PatcherBody, "_PersonalTomlCommitPatch(") > 0,
		"_HCW_PatchTomlMeta must delegate the whole read-modify-publish lifetime to the path-owned helper")
	Assert(InStr(PatcherBody, "ReadTomlFile(") == 0,
		"the HCW wrapper must not read before the shared helper acquires ownership")
	Assert(InStr(PatcherBody, "FileOpen(") == 0,
		"the HCW wrapper must never truncate the durable target in place")
	Assert(InStr(PatcherBody, "_PersonalTomlWriteAtomic(") == 0,
		"only the owned transaction helper may invoke the atomic publisher")
}
Test("meta hcw-personal-meta-transaction: patcher delegates without direct file I/O",
	_PTMU_PatcherDelegatesWithoutDirectIo)

_PTMU_OwnedHelperOrdersReadGuardAndAtomicPublish() {
	Body := _DriverFuncBody("_PersonalTomlCommitPatch")
	LeasePos := InStr(Body, "_PersonalTomlWriteLeaseTryAcquire(")
	InvalidatePos := InStr(Body, "_PersonalTomlInvalidateCaches(")
	ReadPos := InStr(Body, "ReadTomlFile(")
	GuardPos := InStr(Body, "TOML_UnreadableFile")
	PublishPos := InStr(Body, "_PersonalTomlWriteAtomic(")
	Assert(LeasePos > 0, "the metadata transaction helper must acquire path ownership")
	Assert(InvalidatePos > LeasePos,
		"reader caches must be invalidated only after the transaction owns the path")
	Assert(ReadPos > InvalidatePos,
		"the durable source read must happen after ownership and cache invalidation")
	Assert(GuardPos > ReadPos,
		"the unreadable sentinel must be inspected after the read that sets it")
	Assert(PublishPos > GuardPos,
		"an unreadable source must be refused before any atomic publication attempt")
	Assert(InStr(Body, "FileOpen(") == 0,
		"the owned transaction helper must publish only through the tested atomic writer")
	Assert(RegExMatch(Body, "TOML_UnreadableFile[\s\S]{0,600}?LoggerError") > 0,
		"an unreadable source refusal must be logged as an ERROR")
	Assert(RegExMatch(Body, "TOML_UnreadableFile[\s\S]{0,600}?return false") > 0,
		"the unreadable source guard must stop the transaction")
}
Test("meta hcw-personal-meta-transaction: owned helper guards the read before publish",
	_PTMU_OwnedHelperOrdersReadGuardAndAtomicPublish)
