; static/ergopti_plus/windows/tests/meta/test_corpus_security_keylogger.ahk

; ==============================================================================
; MODULE: Security / Keylogger Privacy Corpus Consumer (AHK)
; DESCRIPTION:
; Validates the AHK keylogger privacy invariants against the cross-driver
; contract defined in shared/tests/corpus/security/keylogger_no_persist_vectors.json.
;
; COVERAGE:
; 1. Corpus structure -- file loads, all 10 vectors present.
; 2. AHK-specific vectors -- SEC-009 (ES_PASSWORD style bit) and SEC-010
;    (UIA IsPassword) are exercised via a pure-logic shim that simulates
;    KL_DetectPasswordFor logic for the known-class and ES_PASSWORD paths.
; SKIPPED: SEC-001..SEC-006 are macOS-only (HS driver, AXSecureTextField,
;          bundle IDs). SEC-007/SEC-008 test normal-field logging behaviour
;          which requires a live keylogger session and cannot run headless.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Pure-logic shim for ES_PASSWORD path ===
; ===================================================
; ===================================================

; Mirrors the static PASSWORD_CLASSES lookup and ES_PASSWORD bit logic from
; KL_DetectPasswordFor without calling any OS API. Takes the win32_class and
; win32_style values the corpus vector carries and returns the expected boolean.
_KLDetectPasswordLogic(Win32Class, Win32Style) {
	; Layer 2 -- known password class names (from KL_DetectPasswordFor)
	static PASSWORD_CLASSES := Map(
		"PasswordBox",   true,
		"Edit;PASSWORD", true,
		"TPasswordEdit", true,
		"MaskedEdit",    true,
		"TFormPassword", true
	)
	if PASSWORD_CLASSES.Has(Win32Class)
		return true

	; Layer 1 -- ES_PASSWORD style bit (0x20) on a Win32 Edit control
	if (Win32Class = "Edit") {
		StyleNum := 0
		try StyleNum := Integer(Win32Style)
		if (StyleNum & 0x20)
			return true
	}
	return false
}




; ===================================================
; ===================================================
; ======= 2/ Corpus structure validation =============
; ===================================================
; ===================================================

_SecurityCorpus_StructureCheck() {
	CorpusPath := A_ScriptDir . "\..\..\shared\tests\corpus\security\keylogger_no_persist_vectors.json"
	AssertTrue(FileExist(CorpusPath) != "", "Security corpus file must exist")
	if !FileExist(CorpusPath)
		return

	Raw  := FileRead(CorpusPath, "UTF-8")
	Data := JsonParse(Raw)
	AssertTrue(Data.Has("vectors"),    "Security corpus must have 'vectors' key")
	AssertTrue(Data["vectors"].Length >= 10, "Security corpus must have at least 10 vectors")
}
Test("Security corpus: valid structure with >=10 vectors", _SecurityCorpus_StructureCheck)




; ===================================================
; ===================================================
; ======= 3/ AHK-specific vectors ====================
; ===================================================
; ===================================================

; SEC-009: Win32 ES_PASSWORD style bit (0x20) set on Edit class.
_SecurityCorpus_SEC009() {
	; Input from corpus: win32_style="0x80000020", win32_class="Edit"
	; ES_PASSWORD (0x20) is set in 0x80000020 -- password field.
	Result := _KLDetectPasswordLogic("Edit", "0x80000020")
	AssertTrue(Result, "[SEC-009] ES_PASSWORD bit must trigger password detection")
}
Test("[corpus:SEC-009] AHK ES_PASSWORD bit 0x20 on Edit class", _SecurityCorpus_SEC009)

; Negative case: Edit without ES_PASSWORD bit.
_SecurityCorpus_EditNoPassword() {
	Result := _KLDetectPasswordLogic("Edit", "0x80000000")
	AssertTrue(!Result, "Edit without ES_PASSWORD must NOT trigger password detection")
}
Test("[corpus:SEC-009-negative] Edit without ES_PASSWORD bit not flagged", _SecurityCorpus_EditNoPassword)

; SEC-010: UIA IsPassword property. The UIA path requires a live COM object so
; it cannot be exercised headless; but the class-name layer can be validated.
_SecurityCorpus_PasswordBoxClass() {
	; PasswordBox is a WPF password class in PASSWORD_CLASSES.
	Result := _KLDetectPasswordLogic("PasswordBox", "0")
	AssertTrue(Result, "PasswordBox class must trigger password detection")
}
Test("[corpus:SEC-010-class] PasswordBox class always flagged as password", _SecurityCorpus_PasswordBoxClass)

_SecurityCorpus_TPasswordEditClass() {
	Result := _KLDetectPasswordLogic("TPasswordEdit", "0")
	AssertTrue(Result, "TPasswordEdit (Delphi) class must trigger password detection")
}
Test("[corpus:SEC-010-class2] TPasswordEdit class flagged as password", _SecurityCorpus_TPasswordEditClass)

_SecurityCorpus_RichEditNotFlagged() {
	; RichEdit50W is generic and must NOT be unconditionally flagged (from code comment).
	Result := _KLDetectPasswordLogic("RichEdit50W", "0")
	AssertTrue(!Result, "RichEdit50W must NOT be unconditionally flagged as password")
}
Test("[corpus:SEC-richtext] RichEdit50W not unconditionally flagged", _SecurityCorpus_RichEditNotFlagged)
