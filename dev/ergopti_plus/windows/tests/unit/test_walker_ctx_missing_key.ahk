; tests/unit/test_walker_ctx_missing_key.ahk

; ==============================================================================
; MODULE: Walker Context Missing-Key Unit Test
; DESCRIPTION:
; Unit regression for the safe accessor helpers in keylogger_walker.ahk.
;
; Two related bugs: (1) KLW_GetMap accessed a missing key via map[k] which throws
; in AHK v2 when the key is absent; (2) KLW_GetAppCtx left optional sub-keys
; (current_burst, current_session) out of the initial context Map, so any code
; that called Has() on a brand-new context and then indexed it directly could
; crash on missing keys.
;
; The fixes: KLW_GetMap uses m.Has(k) before indexing; KLW_GetAppCtx documents
; that burst/session are intentionally absent from new contexts (their absence
; signals "no burst/session in flight"); downstream code that needs those keys
; must guard with Has().
;
; SCOPE: pure unit tests against KLW_GetMap and KLW_GetAppCtx
; (no OS hooks, file I/O, or SQLite).
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================
; ================================================
; ======= 1/ KLW_GetMap missing-key safety =======
; ================================================
; ================================================

_WCK_MissingKeyReturnsDefault() {
	m := Map("a", 1, "b", 2)
	result := KLW_GetMap(m, "missing_key")
	AssertEqual("", result,
		"KLW_GetMap must return the empty-string default when the key is absent — indexing a missing Map key throws in AHK v2")
}
Test("KLW_GetMap: missing key returns empty-string default (walker-ctx-missing-key)",
	_WCK_MissingKeyReturnsDefault)


_WCK_MissingKeyReturnsSuppliedDefault() {
	m := Map("x", 99)
	result := KLW_GetMap(m, "nope", "fallback")
	AssertEqual("fallback", result,
		"KLW_GetMap must return the caller-supplied default when the key is absent")
}
Test("KLW_GetMap: missing key returns caller-supplied default (walker-ctx-missing-key)",
	_WCK_MissingKeyReturnsSuppliedDefault)


_WCK_PresentKeyReturnsValue() {
	m := Map("sc", "SC01E")
	result := KLW_GetMap(m, "sc", "")
	AssertEqual("SC01E", result,
		"KLW_GetMap must return the stored value when the key is present")
}
Test("KLW_GetMap: present key returns its value (walker-ctx-missing-key)",
	_WCK_PresentKeyReturnsValue)


_WCK_NonMapInputReturnsDefault() {
	result := KLW_GetMap("not_a_map", "key", "safe")
	AssertEqual("safe", result,
		"KLW_GetMap must return the default when the first argument is not a Map — no throw on unexpected input type")
}
Test("KLW_GetMap: non-Map first arg returns default without throwing (walker-ctx-missing-key)",
	_WCK_NonMapInputReturnsDefault)


; =====================================================
; =====================================================
; ======= 2/ KLW_GetAppCtx initialises safely ========
; =====================================================
; =====================================================

_WCK_NewAppCtxHasRequiredKeys() {
	; Reset KLW.ctx to a clean state so this test doesn't share state
	KLW.ctx := Map()
	ctx := KLW_GetAppCtx("test_walker_ctx_missing_key_app")
	Assert(ctx is Map, "KLW_GetAppCtx must return a Map for a new app")

	; These keys must always be present in a freshly created context
	for _, k in ["p1", "p2", "p3", "p4", "p5", "p6",
				"cur_word", "word_err", "hist",
				"prev_word", "prev_sc", "recent_typing",
				"bs_run_len", "last_was_bs",
				"last_finger", "same_finger_run", "same_hand_run", "last_char"] {
		Assert(ctx.Has(k),
			"KLW_GetAppCtx: newly created context must have key '" . k . "' so walking code can read it without a Has() guard every time")
	}
}
Test("KLW_GetAppCtx: new-app context has all required keys (walker-ctx-missing-key)",
	_WCK_NewAppCtxHasRequiredKeys)


_WCK_SameAppCtxReturnedTwice() {
	KLW.ctx := Map()
	ctx1 := KLW_GetAppCtx("my_test_app")
	ctx1["p1"] := "z"
	ctx2 := KLW_GetAppCtx("my_test_app")
	AssertEqual("z", ctx2["p1"],
		"KLW_GetAppCtx must return the same Map reference on a second call for the same app — context must persist across calls")
}
Test("KLW_GetAppCtx: same context Map returned on repeated call (walker-ctx-missing-key)",
	_WCK_SameAppCtxReturnedTwice)
