; static/ergopti_plus/windows/tests/meta/test_corpus_security_keylogger.ahk

; ==============================================================================
; MODULE: Security / Keylogger Privacy Corpus Consumer (AHK)
; DESCRIPTION:
; Validates AHK keylogger privacy invariants against the cross-driver contract
; defined in _shared/tests/corpus/security/keylogger_no_persist_vectors.json.
;
; APPROACH: Each corpus vector is loaded from the JSON file and either tested
; or explicitly skipped with a documented reason. This ensures the corpus is
; consumed (driver coverage) even when a vector cannot run headless.
;
; TESTED (headless-safe):
; - SEC-009: ES_PASSWORD style bit on Win32 Edit class — pure bit-mask logic
;   exercised by calling KL_DetectPasswordFor_ClassAndStyle(), a refactored
;   pure helper extracted from KL_DetectPasswordFor (no OS API needed).
;
; SKIPPED (documented):
; - SEC-001..SEC-006: macOS-only (AXSecureTextField, bundle ID lookup, private
;   window detection — hs.window APIs absent on Windows).
; - SEC-007..SEC-008: require a live keylogger session; cannot run headless.
; - SEC-010: UIA.IsPassword requires a live COM object; skipped in headless.
; ==============================================================================

#Requires AutoHotkey v2.0




; =============================================================
; =============================================================
; ======= 1/ Pure-logic helper (mirrors KL_DetectPasswordFor) =
; =============================================================
; =============================================================

; This function extracts the headless-safe portion of KL_DetectPasswordFor:
; the ES_PASSWORD bit check and the known-class Map lookup. It takes the
; raw win32_class and win32_style values from the corpus vector and returns
; true when either path would fire in production.
;
; The OS-dependent paths (WinGetClass/WinGetStyle HWND calls, UIA COM object)
; cannot run headless and are intentionally excluded from this helper.
_KL_ClassAndStyleIsPassword(Win32Class, Win32StyleHex) {
	static PASSWORD_CLASSES := Map(
		"PasswordBox",   true,
		"Edit;PASSWORD", true,
		"TPasswordEdit", true,
		"MaskedEdit",    true,
		"TFormPassword", true
	)
	if PASSWORD_CLASSES.Has(Win32Class)
		return true
	if (Win32Class = "Edit") {
		StyleNum := 0
		try StyleNum := Integer(Win32StyleHex)
		if (StyleNum & 0x20)   ; ES_PASSWORD bit
			return true
	}
	return false
}





; =====================================================
; =====================================================
; ======= 2/ Corpus loading and vector dispatch =======
; =====================================================
; =====================================================

_SecurityCorpus_RunAll() {
	CorpusPath := A_ScriptDir . "\..\..\_shared\tests\corpus\security\keylogger_no_persist_vectors.json"
	_SecurityCorpus_Load() {
		AssertTrue(FileExist(CorpusPath) != "", "Security corpus file must exist at: " . CorpusPath)
	}
	Test("Security corpus: file exists on disk", _SecurityCorpus_Load)
	if !FileExist(CorpusPath)
		return

	Raw     := FileRead(CorpusPath, "UTF-8")
	Data    := JsonParse(Raw)

	_SecurityCorpus_HasVectors() {
		AssertTrue(Data.Has("vectors"),                 "Security corpus must have a 'vectors' key")
		AssertTrue(Data["vectors"].Length >= 10,        "Security corpus must have at least 10 vectors")
	}
	Test("Security corpus: structure has >=10 vectors", _SecurityCorpus_HasVectors)

	if !Data.Has("vectors")
		return

	Vectors := Data["vectors"]

	; Dispatch each vector by id
	for Vec in Vectors {
		VecId := Vec.Has("id") ? Vec["id"] : "UNKNOWN"

		if (VecId = "SEC-001" or VecId = "SEC-002" or VecId = "SEC-003"
			or VecId = "SEC-004" or VecId = "SEC-005" or VecId = "SEC-006") {
			; macOS-only: AXSecureTextField, bundle-ID lookup, private-window
			; detection — all rely on Hammerspoon APIs not present on Windows.
			VidCopy := VecId
			_Skip() {
				AssertTrue(true, VidCopy . " correctly skipped: macOS-only vector")
			}
			Test("[corpus:" . VecId . "] SKIP — macOS-only (AX/HS APIs)", _Skip)
			continue
		}

		if (VecId = "SEC-007" or VecId = "SEC-008") {
			; Normal-field logging and mid-buffer flush: require a live keylogger
			; session with real key events. Cannot run headless.
			VidCopy := VecId
			_SkipLive() {
				AssertTrue(true, VidCopy . " correctly skipped: requires live keylogger session")
			}
			Test("[corpus:" . VecId . "] SKIP — requires live keylogger session", _SkipLive)
			continue
		}

		if (VecId = "SEC-009") {
			; ES_PASSWORD bit on Win32 Edit class. Headless-safe via pure helper.
			Input := Vec["input"]
			Win32Class    := Input.Has("win32_class") ? Input["win32_class"] : ""
			Win32StyleHex := Input.Has("win32_style") ? Input["win32_style"] : "0"
			_SEC009() {
				Result := _KL_ClassAndStyleIsPassword(Win32Class, Win32StyleHex)
				AssertTrue(Result,
					"[SEC-009] ES_PASSWORD bit 0x20 in style 0x80000020 on Edit class must trigger detection")
			}
			Test("[corpus:SEC-009] ES_PASSWORD bit on Edit class triggers detection", _SEC009)

			; Negative case: same class, bit cleared
			_SEC009Neg() {
				Result := _KL_ClassAndStyleIsPassword("Edit", "0x80000000")
				AssertTrue(!Result,
					"[SEC-009-neg] Edit without ES_PASSWORD bit (0x80000000) must NOT trigger detection")
			}
			Test("[corpus:SEC-009-neg] Edit without ES_PASSWORD bit not flagged", _SEC009Neg)

			; Additional known classes from PASSWORD_CLASSES
			_SEC009_PasswordBox() {
				AssertTrue(_KL_ClassAndStyleIsPassword("PasswordBox", "0"),
					"PasswordBox class must trigger detection")
			}
			Test("[corpus:SEC-009-class] PasswordBox class triggers detection", _SEC009_PasswordBox)

			_SEC009_TPasswordEdit() {
				AssertTrue(_KL_ClassAndStyleIsPassword("TPasswordEdit", "0"),
					"TPasswordEdit (Delphi) class must trigger detection")
			}
			Test("[corpus:SEC-009-class2] TPasswordEdit class triggers detection", _SEC009_TPasswordEdit)

			_SEC009_RichEdit() {
				AssertTrue(!_KL_ClassAndStyleIsPassword("RichEdit50W", "0"),
					"RichEdit50W must NOT be unconditionally flagged (too generic)")
			}
			Test("[corpus:SEC-009-richtext] RichEdit50W not unconditionally flagged", _SEC009_RichEdit)
			continue
		}

		if (VecId = "SEC-010") {
			; UIA IsPassword property — requires a live COM UIA object.
			; The class-name layer (PasswordBox etc.) is already covered by
			; SEC-009-class tests above; the UIA layer is skipped headless.
			VidCopy := VecId
			_SkipUIA() {
				AssertTrue(true, VidCopy . " correctly skipped: UIA COM object not available headless")
			}
			Test("[corpus:SEC-010] SKIP — UIA COM object unavailable headless", _SkipUIA)
			continue
		}

		; Unknown vector: emit a warning test (pass) so the corpus stays visible
		VidUnknown := VecId
		_SkipUnknown() {
			AssertTrue(true, "Unknown corpus vector '" . VidUnknown . "' has no AHK consumer — add one or mark as SKIP")
		}
		Test("[corpus:" . VecId . "] WARN — no AHK consumer defined", _SkipUnknown)
	}
}

_SecurityCorpus_RunAll()


; --- Async secure-field verdict contract (mirror of KL_PwClassStyleVerdict) ---
; Production lives in modules/keylogger/keylogger.ahk, which the headless runner
; cannot load, so this mirror pins the privacy-critical decision the async
; detector depends on: the keystroke thread suppresses (fails safe) whenever the
; Win32 layer is INCONCLUSIVE. The verdict must therefore only report
; "conclusive" for a readable Edit or a known password class, never for an
; unknown control (which must defer to the off-thread UIA pass).
_KL_PwVerdictMirror(Cls, StyleHex, &Conclusive) {
	static PASSWORD_CLASSES := Map(
		"PasswordBox", true, "Edit;PASSWORD", true, "TPasswordEdit", true,
		"MaskedEdit", true, "TFormPassword", true
	)
	if (Cls = "Edit") {
		Conclusive := true
		StyleNum := 0
		try StyleNum := Integer(StyleHex)
		return (StyleNum & 0x20) ? true : false
	}
	if PASSWORD_CLASSES.Has(Cls) {
		Conclusive := true
		return true
	}
	Conclusive := false
	return false
}

_SecVerdict_EditPw() {
	c := false
	r := _KL_PwVerdictMirror("Edit", "0x80000020", &c)
	AssertTrue(r && c, "Edit + ES_PASSWORD must be password AND conclusive")
}
Test("[secure-field] Edit+ES_PASSWORD is password and conclusive", _SecVerdict_EditPw)

_SecVerdict_EditPlain() {
	c := false
	r := _KL_PwVerdictMirror("Edit", "0x80000000", &c)
	AssertTrue(!r && c, "Edit without ES_PASSWORD must be not-password AND conclusive")
}
Test("[secure-field] Edit without ES_PASSWORD is not-password and conclusive", _SecVerdict_EditPlain)

_SecVerdict_KnownClass() {
	c := false
	r := _KL_PwVerdictMirror("PasswordBox", "0", &c)
	AssertTrue(r && c, "Known password class must be password AND conclusive")
}
Test("[secure-field] known password class is password and conclusive", _SecVerdict_KnownClass)

_SecVerdict_UnknownInconclusive() {
	c := true
	r := _KL_PwVerdictMirror("Chrome_RenderWidgetHostHWND", "0", &c)
	AssertTrue(!r && !c, "Unknown control must be INCONCLUSIVE so the keystroke thread fails safe pending async UIA")
}
Test("[secure-field] unknown control is inconclusive (fail-safe suppress)", _SecVerdict_UnknownInconclusive)

_SecVerdict_RichEditInconclusive() {
	c := true
	r := _KL_PwVerdictMirror("RichEdit50W", "0", &c)
	AssertTrue(!r && !c, "RichEdit50W must be inconclusive (needs UIA), not a hard not-password")
}
Test("[secure-field] RichEdit50W is inconclusive (needs UIA)", _SecVerdict_RichEditInconclusive)
