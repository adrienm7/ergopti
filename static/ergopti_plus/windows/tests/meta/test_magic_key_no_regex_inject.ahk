; tests/meta/test_magic_key_no_regex_inject.ahk

; ==============================================================================
; MODULE: Magic Key No Regex Inject Meta Test
; DESCRIPTION:
; Regression guard ensuring the magic key is not injected unescaped into a
; regex character class in ShouldActivateDeadkey. A configurable magic key that
; happens to be a regex metacharacter (], \, ^, -) would silently corrupt the
; pattern and could misfire or throw.
;
; SCOPE: source introspection of modules/hotstrings.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Test implementations ===================
; ===================================================
; ===================================================

_MKRI_CheckNoRawInject() {
	; Move-resilient: locate ShouldActivateDeadkey() across the whole driver
	; source via the framework helper instead of a pinned modules path
	Body := _DriverFuncBody("ShouldActivateDeadkey")
	Assert(Body != "", "ShouldActivateDeadkey must exist in the driver source")

	; The old buggy pattern injected MK directly into a regex character class:
	;   ~= "^[^A-Za-z" . MK . "]$"
	; This is unsafe when MK contains ], \, ^, or -.
	Assert(!InStr(Body, '"^[^A-Za-z" . MK . "]$"'),
		'ShouldActivateDeadkey must not inject MK directly into a regex character class')
}

_MKRI_CheckPlainComparison() {
	Body := _DriverFuncBody("ShouldActivateDeadkey")
	Assert(Body != "", "ShouldActivateDeadkey must exist in the driver source")

	; The fix uses a plain string comparison (Ch3 != MK) instead of a character class
	Assert(InStr(Body, "Ch3 != MK") || InStr(Body, "MK != Ch3"),
		"ShouldActivateDeadkey must compare magic key with plain != instead of a regex character class")
}


Test("meta magic-key: not injected raw into regex character class",
	_MKRI_CheckNoRawInject)

Test("meta magic-key: magic key membership checked with plain string comparison",
	_MKRI_CheckPlainComparison)