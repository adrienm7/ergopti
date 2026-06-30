; modules/hotstrings/hotstrings_autocorrection.ahk

; ==============================================================================
; MODULE: Hotstrings — Autocorrection
; DESCRIPTION:
; Registers the autocorrection hotstring categories: typographic apostrophe,
; spelling errors, "ou" → "où" fix, multiple punctuation marks (including the
; "…" ellipsis raw-callback), suffixes_a_chaining, minus, caps, names, and
; accents. Extracted from modules/hotstrings.ahk to keep each category readable
; in isolation.
; ==============================================================================





; ===============================================================
; ==================================================================
; ======= 1/ Autocorrection categories registration function =======
; ==================================================================
; ===============================================================

; Registers all Section 3 (autocorrection) hotstrings.
; Called once by RegisterAllHotstrings() in modules/hotstrings.ahk.
_HS_RegisterAutocorrection() {
	global Features





	; ================================
	; =================================
	; ======= 3/ AUTOCORRECTION =======
	; =================================
	; ================================




	; ==========================================================================
	; ===== 3.1) Automatic conversion of apostrophe into a typographic one =====
	; ==========================================================================

	if Features["hotstrings"]["autocorrection"]["typographic_apostrophe"]["enabled"] {
		LoadHotstringsSection("autocorrection", "typographic_apostrophe", Features["hotstrings"]["autocorrection"]["typographic_apostrophe"])

		; Create all hotstrings y'a → y'a, y'b → y'b, etc.
		; This prevents false positives like writing ['key'] ➜ ['key']
		for _, Letter in StrSplit("abcdefghijklmnopqrstuvwxyz") {
			CreateCaseSensitiveHotstrings(
				"*?", "y'" . Letter, "y'" . Letter,
				Map("TimeActivationSeconds", HotstringsResolve("autocorrection", "typographic_apostrophe").Delay)
			)
		}
	}




	; ======================================
	; ===== 3.2) Errors autocorrection =====
	; ======================================

	if Features["hotstrings"]["autocorrection"]["errors"]["enabled"] {
		LoadHotstringsSection("autocorrection", "errors", Features["hotstrings"]["autocorrection"]["errors"])
	}

	if Features["hotstrings"]["autocorrection"]["ou"]["enabled"] {
		LoadHotstringsSection("autocorrection", "ou", Features["hotstrings"]["autocorrection"]["ou"])
	}

	if Features["hotstrings"]["autocorrection"]["multiple_punctuation_marks"]["enabled"] {
		LoadHotstringsSection("autocorrection", "multiple_punctuation_marks", Features["hotstrings"]["autocorrection"]["multiple_punctuation_marks"])

		; We can't use the TimeActivationSeconds here, as previous character = current character = ".".
		; Now an HSE raw-callback hotstring (no native Hotstring()): _EllipsisRawCallback
		; expands "..." → "…" only after a letter (otherwise it breaks code like the JS
		; spread « [...a, ...b] ») and returns a { Bs, Ins } effect for buffer resync.
		CreateRawCallbackHotstring("*?", "...", _EllipsisRawCallback,
			Map("Category", "autocorrection", "Section", "multiple_punctuation_marks"))
	}

	if Features["hotstrings"]["autocorrection"]["suffixes_a_chaining"]["enabled"] {
		LoadHotstringsSection("autocorrection", "suffixes_a_chaining", Features["hotstrings"]["autocorrection"]["suffixes_a_chaining"])
	}




	; =============================================
	; ===== 3.3) Add minus sign automatically =====
	; =============================================

	if Features["hotstrings"]["autocorrection"]["minus"]["enabled"] {
		LoadHotstringsSection("autocorrection", "minus", Features["hotstrings"]["autocorrection"]["minus"])
	}

	if Features["hotstrings"]["autocorrection"]["minus_apostrophe"]["enabled"] {
		LoadHotstringsSection("autocorrection", "minus_apostrophe", Features["hotstrings"]["autocorrection"]["minus_apostrophe"])
	}




	; ====================================
	; ===== 3.4) Caps autocorrection =====
	; ====================================

	if Features["hotstrings"]["autocorrection"]["caps"]["enabled"] {
		LoadHotstringsSection("autocorrection", "caps", Features["hotstrings"]["autocorrection"]["caps"])

		; For these apps, we only capitalize them when used in context of apps, and not as English words
		apps := ["excel", "teams", "word", "office"]
		prefixes := [
			"avec",
			"dans",
			"en",
			"et",
			"fichier",
			"fichiers",
			"le",
			"mon",
			"sur",
			"son",
			"ton",
		]
		for _, prefix in prefixes {
			for _, app in apps {
				from := prefix . " " . app
				to := prefix . " " . _Capitalize(app)
				CreateHotstring("", from, to)
			}
		}
	}

	if Features["hotstrings"]["autocorrection"]["names"]["enabled"] {
		LoadHotstringsSection("autocorrection", "names", Features["hotstrings"]["autocorrection"]["names"])
	}
	try BootProfile_Mark("HS sub: autocorrection registered (excl. accents)")

	if Features["hotstrings"]["autocorrection"]["accents"]["enabled"] {
		LoadHotstringsSection("autocorrection", "accents", Features["hotstrings"]["autocorrection"]["accents"])
	}
	try BootProfile_Mark("HS sub: autocorrection.accents registered")
}





; =============================================
; ==============================================
; ======= 2/ Autocorrection helper utils =======
; ==============================================
; =============================================

; Capitalizes the first character of a string. Defined at module scope so it
; is not re-created as a new closure on every RegisterAllHotstrings() call.
_Capitalize(str) {
	return StrUpper(SubStr(str, 1, 1)) . SubStr(str, 2)
}
