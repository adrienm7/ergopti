; tests/meta/test_input_serialization.ahk

; ==============================================================================
; MODULE: Keystroke-Path Critical-Serialization Test
; DESCRIPTION:
; Guards that the keystroke hot path is Critical-serialized so fast typing cannot
; reorder characters, and a hotstring expansion cannot be interleaved with the
; keys typed right after the trigger.
;
; WHY THIS MATTERS (the regression this encodes):
;   Every remapped key re-emits its char via SendEvent (SendMode is "Event"
;   globally, for cascade), and A_MaxThreads is high. Without Critical, two fast
;   keys start overlapping remap threads whose SendEvents interleave in the single
;   OS input queue -> "comme" comes out "cmooe"; and a following key can splice
;   into an in-flight expansion burst -> "trigger"+"bc" -> "outpubct". The fix is
;   to make the per-key remap (_RemapEmit), the watcher fire region (_OnPrefixChar
;   before HSE_FeedChar) and the dispatch's atomic send (HSE_DispatchMatch)
;   uninterruptible via Critical, while the two Sleep-ing paths (the UIA wrap and
;   the Notepad clipboard send) stay OUT of Critical (a Sleep would yield and break
;   the guarantee). If a future edit drops any of those Critical calls, the
;   fast-typing reorder / expansion interleave silently returns: this test makes
;   that loud.
;
; SCOPE: source introspection of modules/layout.ahk, the prefix watcher and the
;   hotstring engine (timing/concurrency cannot be reproduced in the synchronous
;   headless harness, so the structural guarantee is what we pin).
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckInputSerialization() {
	SplitPath(A_ScriptDir, , &WindowsDir)

	; --- Layout remaps must serialize each per-key SendEvent via _RemapEmit ---
	LayoutFile := WindowsDir . "\modules\layout.ahk"
	Lay := ""
	try Lay := FileRead(LayoutFile)
	Assert(Lay != "", "modules\layout.ahk must be readable for the input-serialization meta-test")

	EmitPos := InStr(Lay, "_RemapEmit(SendStr")
	Assert(EmitPos > 0, "layout.ahk must define the serialized remap handler _RemapEmit(SendStr, KeyChar, *)")
	; _RemapEmit must enter Critical BEFORE its SendEvent so AHK cannot start the
	; next key's remap thread mid-send (the fast-typing reorder, "comme"->"cmooe").
	RemapKeyPos := InStr(Lay, "RemapKey(ScanCode")
	Assert(RemapKeyPos > EmitPos, "RemapKey(ScanCode ...) must follow the _RemapEmit definition")
	EmitCritPos := InStr(Lay, 'Critical("On")', , EmitPos)
	Assert(EmitCritPos > 0 and EmitCritPos < RemapKeyPos,
		"_RemapEmit must call Critical On before SendEvent so per-key sends serialize")
	; RemapKey must BIND _RemapEmit, not a bare reorder-prone SendEvent lambda.
	Assert(InStr(Lay, "_RemapEmit.Bind("),
		"RemapKey must bind _RemapEmit for its remap hotkeys")
	Assert(!InStr(Lay, '(*) => SendEvent("{Blind}"'),
		"the bare '(*) => SendEvent(...)' per-key remap must be gone -- it reorders under fast typing")

	; --- Watcher: the match -> fire -> buffer region must be Critical ---
	WatcherFile := WindowsDir . "\lib\hotstrings\hotstring_prefix_watcher.ahk"
	W := ""
	try W := FileRead(WatcherFile)
	Assert(W != "", "hotstring_prefix_watcher.ahk must be readable")

	OnCharPos := InStr(W, "_OnPrefixChar(IH, Char) {")
	Assert(OnCharPos > 0, "watcher must define _OnPrefixChar(IH, Char)")
	FeedPos := InStr(W, "HSE_FeedChar(Char)", , OnCharPos)
	Assert(FeedPos > 0, "_OnPrefixChar must call HSE_FeedChar(Char)")
	OnCharCritPos := InStr(W, 'Critical("On")', , OnCharPos)
	Assert(OnCharCritPos > 0 and OnCharCritPos < FeedPos,
		"_OnPrefixChar must enter Critical On before HSE_FeedChar so the fire + expansion burst is uninterruptible")

	; The debounced render must skip while a burst is in flight (TooltipShow pumps
	; the message loop and could otherwise straddle an expansion).
	FlushPos := InStr(W, "_PrefixRenderFlush() {")
	Assert(FlushPos > 0, "watcher must define _PrefixRenderFlush()")
	GuardPos := InStr(W, "_PrefixWatcherSuppressed or HSE_Suppressed", , FlushPos)
	LookupPos := InStr(W, "_LookupAndRender()", , FlushPos)
	Assert(GuardPos > 0 and LookupPos > 0 and GuardPos < LookupPos,
		"_PrefixRenderFlush must early-return while suppressed, before _LookupAndRender")

	; --- Dispatch: atomic burst Critical; Notepad (Sleeps) releases Critical ---
	EngineFile := WindowsDir . "\lib\hotstrings\hotstring_engine_main.ahk"
	E := ""
	try E := FileRead(EngineFile)
	Assert(E != "", "hotstring_engine_main.ahk must be readable")

	DispPos := InStr(E, "HSE_DispatchMatch(Spec, EndChar) {")
	Assert(DispPos > 0, "engine must define HSE_DispatchMatch(Spec, EndChar)")
	Assert(InStr(E, 'Critical("On")', , DispPos) > 0,
		"HSE_DispatchMatch atomic send must be wrapped in Critical On so non-OnChar callers (e.g. the Space tap-hold) serialize too")
	Assert(InStr(E, 'Critical("Off")', , DispPos) > 0,
		"HSE_DispatchMatch Notepad branch must release Critical Off -- it Sleeps (clipboard), and Critical must not span a Sleep")
}

Test("meta input: keystroke path is Critical-serialized (no fast-typing reorder / expansion interleave)",
	_MetaCheckInputSerialization)
