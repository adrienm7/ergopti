; modules/keymap/layout.ahk

; ==============================================================================
; MODULE: Layout
; DESCRIPTION:
; Defines all physical key remappings for the Ergopti keyboard layout.
; Covers the base layer, Shift, CapsLock, AltGr/ShiftAltGr, and Control
; variants, as well as all dead-key mapping tables.
; ==============================================================================





; =======================================
; =======================================
; ======= 1/ DEAD KEY DEFINITIONS =======
; =======================================
; =======================================

; TODO : if KbdEdit is upgraded, some "NEW" Unicode characters will become available
; This AutoHotkey script has all the characters, and the KbdEdit file has some missing ones
; For example, there is no 🄋 character yet in KbdEdit, but it is already available in this emulation

global DeadkeyMappingCircumflex := Map(
	" ", "^", "^", "^",
	"¨", "/", "_", "\",
	"'", "⚠",
	",", "➜",
	".", "•",
	"/", "⁄",
	"0", "🄋", ; NEW
	"1", "➀",
	"2", "➁",
	"3", "➂",
	"4", "➃",
	"5", "➄",
	"6", "➅",
	"7", "➆",
	"8", "➇",
	"9", "➈",
	":", "▶",
	";", "↪",
	"a", "â", "A", "Â",
	"b", "ó", "B", "Ó",
	"c", "ç", "C", "Ç",
	"d", "★", "D", "☆",
	"e", "ê", "E", "Ê",
	"f", "⚐", "F", "⚑",
	"g", "ĝ", "G", "Ĝ",
	"h", "ĥ", "H", "Ĥ",
	"i", "î", "I", "Î",
	"j", "j", "J", "J",
	"★", "j", 
	"k", "☺", "K", "☻",
	"l", "†", "L", "‡",
	"m", "✅", "M", "☑",
	"n", "ñ", "N", "Ñ",
	"o", "ô", "O", "Ô",
	"p", "¶", "P", "⁂",
	"q", "☒", "Q", "☐",
	"r", "º", "R", "°",
	"s", "ß", "S", "ẞ",
	"t", "!", "T", "¡",
	"u", "û", "U", "Û",
	"v", "✓", "V", "✔",
	"w", "ù", "W", "Ù",
	"x", "✕", "X", "✖",
	"y", "ŷ", "Y", "Ŷ",
	"z", "ẑ", "Z", "Ẑ",
	"à", "æ", "À", "Æ",
	"è", "í", "È", "Í",
	"é", "œ", "É", "Œ",
	"ê", "á", "Ê", "Á",
)

global DeadkeyMappingDiaresis := Map(
	" ", "¨", "¨", "¨",
	"0", "🄌", ; NEW
	"1", "➊",
	"2", "➋",
	"3", "➌",
	"4", "➍",
	"5", "➎",
	"6", "➏",
	"7", "➐",
	"8", "➑",
	"9", "➒",
	"a", "ä", "A", "Ä",
	"c", "©", "C", "©",
	"e", "ë", "E", "Ë",
	"h", "ḧ", "H", "Ḧ",
	"i", "ï", "I", "Ï",
	; ¨+n → narrow no-break space (U+202F) — mnemonic: N for Narrow nbsp
	"n", Chr(0x202F), "N", Chr(0x202F),
	"o", "ö", "O", "Ö",
	"r", "®", "R", "®",
	; ¨+s → no-break space (U+00A0) — mnemonic: S for Space (insécable)
	"s", Chr(0x00A0), "S", Chr(0x00A0),
	"t", "™", "T", "™",
	"u", "ü", "U", "Ü",
	"w", "ẅ", "W", "Ẅ",
	"x", "ẍ", "X", "Ẍ",
	"y", "ÿ", "Y", "Ÿ",
)

global DeadkeyMappingSuperscript := Map(
	" ", "ᵉ",
	"(", "⁽", ")", "⁾",
	"+", "⁺",
	",", "ᶿ",
	"-", "⁻",
	".", "ᵝ",
	"/", "̸",
	"0", "⁰",
	"1", "¹",
	"2", "²",
	"3", "³",
	"4", "⁴",
	"5", "⁵",
	"6", "⁶",
	"7", "⁷",
	"8", "⁸",
	"9", "⁹",
	"=", "⁼",
	"a", "ᵃ", "A", "ᴬ",
	"b", "ᵇ", "B", "ᴮ",
	"c", "ᶜ", "C", "ꟲ",
	"d", "ᵈ", "D", "ᴰ",
	"e", "ᵉ", "E", "ᴱ",
	"f", "ᶠ", "F", "ꟳ",
	"g", "ᶢ", "G", "ᴳ",
	"h", "ʰ", "H", "ᴴ",
	"i", "ⁱ", "I", "ᴵ",
	"j", "ʲ", "J", "ᴶ",
	"k", "ᵏ", "K", "ᴷ",
	"l", "ˡ", "L", "ᴸ",
	"m", "ᵐ", "M", "ᴹ",
	"n", "ⁿ", "N", "ᴺ",
	"o", "ᵒ", "O", "ᴼ",
	"p", "ᵖ", "P", "ᴾ",
	"q", "𐞥", "Q", "ꟴ", ; 𐞥 is NEW
	"r", "ʳ", "R", "ᴿ",
	"s", "ˢ", "S", "", ; There is no superscript capital s yet in Unicode
	"t", "ᵗ", "T", "ᵀ",
	"u", "ᵘ", "U", "ᵁ",
	"v", "ᵛ", "V", "ⱽ",
	"w", "ʷ", "W", "ᵂ",
	"x", "ˣ", "X", "", ; There is no superscript capital x yet in Unicode
	"y", "ʸ", "Y", "", ; There is no superscript capital y yet in Unicode
	"z", "ᶻ", "Z", "", ; There is no superscript capital z yet in Unicode
	"[", "˹", "]", "˺",
	"à", "ᵡ", "À", "", ; There is no superscript capital ᵡ yet in Unicode
	"æ", "𐞃", "Æ", "ᴭ", ; 𐞃 is NEW
	"è", "ᵞ", "È", "", ; There is no superscript capital ᵞ yet in Unicode
	"é", "ᵟ", "É", "", ; There is no superscript capital ᵟ yet in Unicode
	"ê", "ᵠ", "Ê", "", ; There is no superscript capital ᵠ yet in Unicode
	"œ", "ꟹ", "Œ", "", ; There is no superscript capital œ yet in Unicode
)

global DeadkeyMappingSubscript := Map(
	" ", "ᵢ",
	"(", "₍", ")", "₎",
	"+", "₊", "-", "₋",
	"/", "̸",
	"0", "₀",
	"1", "₁",
	"2", "₂",
	"3", "₃",
	"4", "₄",
	"5", "₅",
	"6", "₆",
	"7", "₇",
	"8", "₈",
	"9", "₉",
	"=", "₌",
	"a", "ₐ", "A", "ᴀ",
	"b", "ᵦ", "B", "ʙ", ; ᵦ, not real subscript b
	"c", "", "C", "ᴄ", ; There is no subscript c yet in Unicode
	"d", "", "D", "ᴅ", ; There is no subscript d yet in Unicode
	"e", "ₑ", "E", "ᴇ", ; There is no subscript f yet in Unicode
	"f", "", "F", "ꜰ",
	"g", "ᵧ", "G", "ɢ", ; ᵧ, not real subscript g
	"h", "ₕ", "H", "ʜ",
	"i", "ᵢ", "I", "ɪ",
	"j", "ⱼ", "J", "ᴊ",
	"k", "ₖ", "K", "ᴋ",
	"l", "ₗ", "L", "ʟ",
	"m", "ₘ", "M", "ᴍ",
	"n", "ₙ", "N", "ɴ",
	"o", "ₒ", "O", "ᴏ",
	"p", "ᵨ", "P", "ₚ",
	"q", "", "Q", "ꞯ", ; There is no subscript q yet in Unicode
	"r", "ᵣ", "R", "ʀ",
	"s", "ₛ", "S", "ꜱ",
	"t", "ₜ", "T", "ᴛ",
	"u", "ᵤ", "U", "ᴜ",
	"v", "ᵥ", "V", "ᴠ",
	"w", "", "W", "ᴡ", ; There is no subscript w yet in Unicode
	"x", "ₓ", "X", "ᵪ", ; There is no subscript capital x yet in Unicode, we use subscript capital chi instead
	"y", "ᵧ", "Y", "ʏ", ; There is no subscript y yet in Unicode, we use subscript gamma instead
	"z", "", "Z", "ᴢ", ; There is no subscript z yet in Unicode
	"[", "˻", "]", "˼",
	"æ", "", "Æ", "ᴁ", ; There is no subscript æ yet in Unicode
	"è", "ᵧ", "È", "", ; There is no subscript capital ᵧ yet in Unicode
	"ê", "ᵩ", "Ê", "", ; There is no subscript capital ᵩ yet in Unicode
	"œ", "", "Œ", "ɶ", ; There is no subscript œ yet in Unicode
)

global DeadkeyMappingGreek := Map(
	" ", "µ",
	"'", "ς",
	"-", "Μ",
	"_", "Ω", ; Attention, Ohm symbol and not capital Omega
	"a", "α", "A", "Α",
	"b", "β", "B", "Β",
	"c", "ψ", "C", "Ψ",
	"d", "δ", "D", "Δ",
	"e", "ε", "E", "Ε",
	"f", "φ", "F", "Φ",
	"g", "γ", "G", "Γ",
	"h", "η", "H", "Η",
	"i", "ι", "I", "Ι",
	"j", "ξ", "J", "Ξ",
	"k", "κ", "K", "Κ",
	"l", "λ", "L", "Λ",
	"m", "μ", "M", "Μ",
	"n", "ν", "N", "Ν",
	"o", "ο", "O", "Ο",
	"p", "π", "P", "Π",
	"q", "χ", "Q", "Χ",
	"r", "ρ", "R", "Ρ",
	"s", "σ", "S", "Σ",
	"t", "τ", "T", "Τ",
	"u", "θ", "U", "Θ",
	"v", "ν", "V", "Ν",
	"w", "ω", "W", "Ω",
	"x", "ξ", "X", "Ξ",
	"y", "υ", "Y", "Υ",
	"z", "ζ", "Z", "Ζ",
	"é", "η", "É", "Η",
	"ê", "ϕ", "Ê", "", ; Alternative phi character
)

global DeadkeyMappingR := Map(
	" ", "ℝ",
	"'", "ℜ",
	"(", "⟦", ")", "⟧",
	"[", "⟦", "]", "⟧",
	"<", "⟪", ">", "⟫",
	"«", "⟪", "»", "⟫",
	"b", "", "B", "ℬ",
	"c", "", "C", "ℂ",
	"e", "", "E", "⅀",
	"f", "", "F", "ℱ",
	"g", "ℊ", "G", "ℊ",
	"h", "", "H", "ℋ",
	"j", "", "J", "ℐ",
	"l", "ℓ", "L", "ℒ",
	"m", "", "M", "ℳ",
	"n", "", "N", "ℕ",
	"p", "", "P", "ℙ",
	"q", "", "Q", "ℚ",
	"r", "", "R", "ℝ",
	"s", "", "S", "⅀",
	"t", "", "T", "ℭ",
	"u", "", "U", "ℿ",
	"x", "", "X", "ℛ",
	"z", "", "Z", "ℨ",
)

global DeadkeyMappingCurrency := Map(
	" ", "¤",
	"$", "£",
	"&", "৳",
	"'", "£",
	"-", "£",
	"_", "€",
	'``', "₰",
	"a", "؋", "A", "₳",
	"b", "₿", "B", "฿",
	"c", "¢", "C", "₵",
	"d", "₫", "D", "₯",
	"e", "€", "E", "₠",
	"f", "ƒ", "F", "₣",
	"g", "₲", "G", "₲",
	"h", "₴", "H", "₴",
	"i", "﷼", "I", "៛",
	"k", "₭", "K", "₭",
	"l", "₺", "L", "₤",
	"m", "₥", "M", "ℳ",
	"n", "₦", "N", "₦",
	"o", "௹", "O", "૱",
	"p", "₱", "P", "₧",
	"r", "₽", "R", "₹",
	"s", "₪", "S", "₷",
	"t", "₸", "T", "₮",
	"u", "元", "U", "圓",
	"w", "₩", "W", "₩",
	"y", "¥", "Y", "円",
)





; ============================
; ============================
; ======= 2/ UTILITIES =======
; ============================
; ============================

global InDeadKeySequence := false
global _DeadKeyInputHook := ""

DeadKey(Mapping) {
	global InDeadKeySequence
	; "Pause = tout eteint" invariant: a live InputHook bypasses native Suspend,
	; so guard the dead-key state machine here. Without this, a dead-key keypress
	; that slips through while the driver is paused would still arm the InputHook
	; and capture/remap the user's next physical key (deadkey-inputhook-no-timeout-no-suspend-guard).
	if A_IsSuspended
		return
	InDeadKeySequence := true
	try {
		; Callers dispatch dead keys from inside Critical("On") (LayerDispatch's
		; SerializeSymbols path, AltGrShiftDispatch's unconditional wrap) so their
		; own SendEvent-based emits serialize against neighbouring remapped keys.
		; ih.Wait() below is a blocking, message-pumping wait with up to a 2s
		; timeout ("L1 T2") -- running THAT under Critical stalls the ENTIRE AHK
		; message pump (every hotkey/timer in the process) for up to 2 seconds on
		; every CapsLock dead-key press, not just this key
		; (deadkey-wait-under-critical-stalls-pump). Release Critical for the wait
		; and restore whatever the caller had in a finally, so the final emit
		; below still serializes exactly as the caller intended.
		_AtCrit := Critical("Off")
		try {
			ih := InputHook(
				"L1 T2",
				"{F1}{F2}{F3}{F4}{F5}{F6}{F7}{F8}{F9}{F10}{F11}{F12}{Left}{Right}{Up}{Down}{Home}{End}{PgUp}{PgDn}{Ins}{Numlock}{PrintScreen}{Pause}{Enter}{BackSpace}{Delete}"
			)
			global _DeadKeyInputHook := ih
			try {
				ih.Start()
				ih.Wait()
			} finally {
				try ih.Stop()
				_DeadKeyInputHook := ""
			}
		} finally {
			Critical(_AtCrit)
		}
		; A live InputHook bypasses native Suspend, so a pause can land DURING Wait().
		; If the driver was paused mid-sequence, emit nothing — « pause = tout eteint »
		; (deadkey-inputhook-post-wait-suspend-leak). The finally still resets the flag.
		if A_IsSuspended
			return
		if (ih.EndReason = "Timeout") {
			if Mapping.Has(" ")
				SendNewResult(Mapping[" "])
			return
		}
		PressedKey := ih.Input
		if Mapping.Has(PressedKey) {
			SendNewResult(Mapping[PressedKey])
		} else {
			; Standard OS behaviour: emit the dead-key base char (mapped to " ")
			; then the untransformed key, so ¨ + q produces ¨q, not just q.
			if Mapping.Has(" ")
				SendNewResult(Mapping[" "])
			SendNewResult(PressedKey)
		}
		; Re-send EndKeys (Enter, BackSpace, Delete) consumed by the InputHook.
		; Without the "V" option the hook swallows them; the user's newline,
		; delete or erase would disappear silently after a dead-key sequence.
		if (ih.EndReason = "EndKey")
			Send("{" . ih.EndKey . "}")
	} finally {
		InDeadKeySequence := false
	}
}

UpdateLastSentCharacter(Character) {
	; Ring-buffer push is O(1) and does not reallocate past boot — see
	; ``_LSCPush`` in infra/hotstring_engine.ahk.
	_LSCPush(Character)
	AppState_TouchLastSentKey(Character)
}

; Single write path for timestamp tracking. Pruning keeps the map size bounded
; so it never grows unboundedly across a long session.
AppState_TouchLastSentKey(Character) {
	global LastSentCharacterKeyTime, LAST_SENT_KEY_TIME_MAX_AGE_MS, LAST_SENT_KEY_TIME_PRUNE_AT
	LastSentCharacterKeyTime[Character] := A_TickCount
	if LastSentCharacterKeyTime.Count > LAST_SENT_KEY_TIME_PRUNE_AT {
		Now := A_TickCount
		for k, ts in LastSentCharacterKeyTime.Clone() {
			if TickExpired(ts, LAST_SENT_KEY_TIME_MAX_AGE_MS, Now)
				LastSentCharacterKeyTime.Delete(k)
		}
	}
}

; Serialized remap emit — the callback every remapped key fires. SendMode is
; "Event" globally (cascade relies on it), so each key re-sends its char via a
; NON-atomic, interruptible SendEvent. Without serialization two fast keys can
; start overlapping remap threads (A_MaxThreads is high; #MaxThreadsPerHotkey only
; blocks re-entry of the SAME key) whose SendEvent injections interleave in the
; single OS input queue and emit out of order (e.g. "comme" -> "cmooe"), and can
; likewise splice into an in-flight hotstring expansion. Critical("On") makes this
; callback uninterruptible, so AHK cannot start the NEXT key's remap (nor the
; render/suppress timers, nor the watcher OnChar) until this SendEvent has fully
; drained — restoring strict per-key ordering. Same SendEvent semantics
; (``{Blind}`` / AltGr / modifiers unchanged); only ordering is enforced. There is
; NO Sleep on this path, so Critical's guarantee holds (a Sleep would yield it).
; Profiled because this is the FIRST stage of every remapped keystroke and the
; only one that had no segment at all: an "OnChar" line that looked slow could
; equally have been a slow SendEvent that had already finished before OnChar
; started, and nothing in the log distinguished the two. Two QPC reads, and the
; WARNING path only runs above the 5 ms floor. LoggerWarn queues the line rather
; than writing it, so the Critical section below never performs file I/O.
_RemapEmit(SendStr, KeyChar, *) {
	_hpEmit := HotPath_Now()
	Critical("On")
	SendEvent(SendStr)
	if _EmitReachedScreen()
		UpdateLastSentCharacter(KeyChar)
	HotPath_LogIfSlow("RemapEmit", _hpEmit, KeyChar)
}

; False while a dead-key InputHook is armed. That hook runs with VisibleText at
; its default (off), so it CONSUMES the character an emit just produced — the
; character never reaches the screen, and DeadKey emits the composed result
; instead once the hook stops.
;
; Measured, not assumed: a probe registered a hotkey exactly like the remap
; hotkeys (InputLevel 2), armed an InputHook with DeadKey's own "L1 T2" shape,
; and injected one key. The hotkey FIRED, the hook captured the character the
; hotkey had emitted, and the focused edit control received nothing.
;
; Advancing the ring here therefore recorded a character the user never saw, and
; DeadKey then pushed the composed character as well — two entries for one
; visible character. Everything downstream that reads the ring as "what is on
; screen" was consequently off by one during and just after a composition: the
; roll handlers, the quote/hashtag guards and the time-gated hotstring lookups.
;
; This is the same rule SendNewResult already applies when its send throws — a
; character that did not reach the application must not advance the ring. The
; check is on the HOOK, not on InDeadKeySequence: DeadKey clears the hook before
; emitting its own result but leaves the sequence flag set until afterwards, so
; gating on the flag would suppress the push for the one character that IS
; visible.
; FOUR hooks share this shape, not one. The dead-key hook was the one the
; original probe used, but _OneShotShiftInputHook and _SpaceHoldInputHook are
; both armed "L1" with VisibleText off and consume the character an emit just
; produced in exactly the same way. Tap RCtrl for a one-shot shift and type "a":
; the ring recorded "a" (dead-key hook empty, so the old check passed), the armed
; OSS hook ate that "a", and OneShotShift emitted and recorded "A" — two ring
; entries for one visible capital.
;
; The magic-key editor is suppressive too: its ``InputHook("L1 I")`` captures
; one remapped output for the editor instead of letting it reach the application.
;
; Enumerated as a list rather than a chain of ors so another suppressive hook
; is a one-line addition next to its siblings, and so the regression test can
; require every _*InputHook global in the driver to appear here.
global _EMIT_SUPPRESSING_HOOKS := [
	"_DeadKeyInputHook", "_OneShotShiftInputHook", "_SpaceHoldInputHook",
	"_MagicKeyEditorInputHook"
]

; Capture hooks that deliberately do NOT suppress, listed so every hook in the
; driver is accounted for in exactly one of the two sets and a new one cannot
; quietly default to "harmless". The prefix watcher is armed "V L0 I1": the V
; makes its text VISIBLE, so it observes the keystream instead of eating it, and
; a character it sees still reaches the application. Adding it to the set above
; would suppress every ring push for the entire life of the driver.
global _EMIT_NONSUPPRESSING_HOOKS := ["_PrefixInputHook"]

_EmitReachedScreen() {
	global _EMIT_SUPPRESSING_HOOKS
	for HookName in _EMIT_SUPPRESSING_HOOKS {
		; Read through the global namespace: these hooks live in four different
		; modules and only one of them is this file's own.
		if !IsSet(%HookName%)
			continue
		if (%HookName% != "")
			return false
	}
	return true
}

; Win + remapped-L locks the workstation. Locking is a focus-destroying,
; context-unknown event (like a mouse click or Ctrl+V), so it must reset the
; hotstring feed and prefix buffer — otherwise the pre-lock word context would
; still abut the cursor after unlock and mis-/non-fire the first word typed
; (win-l-lock-no-watcher-reset). No character is emitted (the OS lock screen
; eats the key), so we intentionally do NOT push 'l' into the last-sent ring.
; Critical("On") routes this through the same serialised emit contract as
; _RemapEmit so it cannot reorder relative to a neighbouring remap, and the two
; statements are explicit lines so a refactor cannot silently drop one
; (lock-workstation-lambda-implicit-concat).
_LockWorkstationEmit(*) {
	Critical("On")
	DllCall("LockWorkStation")
	; IsPhysical=true. Locking is a real, user-initiated event, but the default
	; false makes HSE_FeedReset a NO-OP whenever HSE_Suppressed is non-zero —
	; that is, whenever Win+L lands inside the ~60 ms post-expansion suppress
	; window, which is exactly when a lock is most likely to follow a burst of
	; typing. The preview was wiped unconditionally on the line below, so the
	; two buffers ended up disagreeing across the lock: stale left-context
	; survived unlock and the first expansion afterwards backspaced into
	; unrelated text. Every other genuinely-physical reset site passes true for
	; the same reason.
	HSE_FeedReset(false, true)
	if IsSet(_ResetPrefixBuffer)
		_ResetPrefixBuffer()
}

RemapKey(ScanCode, Character, AlternativeCharacter := "") {
	global RemappedList
	InputLevel := "I2"

	Hotkey(
		"*" ScanCode,
		_RemapEmit.Bind("{Blind}" Character, Character),
		InputLevel
	)

	RemappedList[Character] := ScanCode
	if AlternativeCharacter != "" {
		Hotkey(
			ScanCode,
			_RemapEmit.Bind("{Text}" . AlternativeCharacter, AlternativeCharacter),
			InputLevel
		)
	}

	; In theory, * and {Blind} should be sufficient, but it isn't the case when we define custom hotkeys in next sections
	; For example, a new hotkey for ^b leads to ^t giving ^b in QWERTY
	; The same happens for Win shortcuts, where we can get the shortcut on the QWERTY layer and not emulated Ergopti layer
	Hotkey(
		"^" ScanCode,
		_RemapEmit.Bind("^" Character, Character),
		InputLevel
	)
	Hotkey(
		"!" ScanCode,
		_RemapEmit.Bind("!" Character, Character),
		"I3" ; Needs to be higher to keep the Alt shortcuts
	)
	if Character == "l" {
		; Solves a bug of # + remapped letter L not triggering the Lock shortcup
		Hotkey(
			"#" ScanCode,
			_LockWorkstationEmit,
			InputLevel
		)
	} else {
		Hotkey(
			"#" ScanCode,
			_RemapEmit.Bind("#" Character, Character),
			InputLevel
		)
	}
}

; Per-process UIA selection result caches.
; Avoids repeated synchronous COM round-trips on the keyboard thread for
; every wrap-symbol keystroke (uia-selection-query-on-hot-path /
; uia-selection-blocks-keyboard-thread).
;
; _UIA_NO_TP_CACHE: when IsTextPatternAvailable returns false for a process,
; cache the miss so subsequent symbol keystrokes skip UIA.GetFocusedElement()
; entirely for _UIA_NO_TP_TTL_MS.  Covers apps (games, custom win32 controls)
; that never expose TextPattern — previously those paid the full COM cost on
; every wrap-eligible keystroke.
global _UIA_NO_TP_CACHE := Map()  ; ProcessName → expiry tick (no TextPattern)

; 30 s: generous re-probe window; reset automatically when the active app changes.
_UIA_NO_TP_TTL_MS     := 30000
; Returns the currently selected text via UIA TextPattern, or "" when:
; - UIA is unavailable
; - the focused element does not support TextPattern
; - nothing is selected (degenerate/empty range)
; - the selection is all blank lines (caller usually wants to skip wrapping)
; - we are in an Electron app (VSCode etc.) where UIA TextPattern is unreliable
;
; A selection is a short-lived capability, not plain text.  Bind it to the
; foreground window and capture time, then consume it once; otherwise a poll
; can wrap text after focus/selection already changed.
global _UIA_SelectionCache := 0
global UIA_SELECTION_MAX_AGE_MS := 750
global _UIA_SelectionPollTimer := unset
; Never start a COM/UIA round-trip while the user is actively typing. The timer
; shares AHK's only message thread with the keyboard hook; a probe is useful
; only after a selection gesture has settled, not between successive keys.
global UIA_SELECTION_IDLE_REQUIRED_MS := 250
; A provider that exhausts the killable worker deadline is not retried on every
; idle tick. The focus/input gates still release immediately for another app.
global _UIA_WORKER_BACKOFF_CACHE := Map()

; Inputs of the last probe. A selection cannot appear unless the FOCUS moved or
; the user touched the input stream, so a probe whose inputs are identical to the
; previous one can only produce the previous answer. Skipping those removed the
; bulk of the round trips on an idle machine (~80 % of ticks exceeded the 5 ms
; hot-path threshold before this gate). 0 means "no probe yet".
global _UIA_LastProbeHwnd := 0
global _UIA_LastProbeIdleEpoch := 0

_UIA_CurrentInputEpoch() {
	return KS_GetPhysicalInputEpoch()
}

_UIA_CurrentSelectionContext(ProcName := "") {
	Hwnd := WIGetForegroundHwnd()
	Control := WIGetFocusedControlToken()
	if !Hwnd || !Control
		return 0
	return Map(
		"Hwnd", Hwnd,
		"Control", Control,
		"InputEpoch", _UIA_CurrentInputEpoch(),
		"ProcName", ProcName
	)
}

_UIA_OnSelectionWorkerTerminal(Status, Context, Result) {
	global _UIA_SelectionCache, _UIA_NO_TP_CACHE, _UIA_NO_TP_TTL_MS
	global _UIA_WORKER_BACKOFF_CACHE, UIASW_DEADLINE_MS
	LogKind := ""
	LogDetail := ""
	; Validate text before entering Critical so even a maximum-sized provider
	; result cannot extend the input-ownership transaction with a regex scan.
	PublishableText := ""
	if (Status = "ok" && Result is Map) {
		CandidateText := Result.Get("Text", "")
		if CandidateText != "" && !RegExMatch(CandidateText, "^(\r\n|\r|\n)+$")
			PublishableText := CandidateText
	} else if (Status = "failed") {
		LogDetail := (Result is Map)
			? Result.Get("Error", Result.Get("Text", "unknown worker failure"))
			: "unknown worker failure"
	}

	; A keyboard/InputHook callback can interrupt an OnMessage callback. Context
	; validation and cache publication therefore form one short transaction:
	; otherwise a physical character can clear the old cache after the live check,
	; then this callback resumes and republishes a selection from the old epoch.
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		if A_IsSuspended {
			_UIA_SelectionCache := 0
		} else if (Status = "timeout") {
			_UIA_WORKER_BACKOFF_CACHE[Context["ProcName"]] := {
				Tick: A_TickCount,
				DurationMs: _UIA_NO_TP_TTL_MS
			}
			_UIA_SelectionCache := 0
			LogKind := "timeout"
		} else if (Status = "failed") {
			_UIA_SelectionCache := 0
			LogKind := "failed"
		} else if (Status = "canceled") {
			_UIA_SelectionCache := 0
		} else {
			Live := _UIA_CurrentSelectionContext(Context["ProcName"])
			if !(Live is Map) || !(Result is Map)
				|| !UIASW_ContextMatches(Context, Result, Live) {
				_UIA_SelectionCache := 0
			} else if (Status = "no_text_pattern") {
				_UIA_NO_TP_CACHE[Context["ProcName"]] := {
					Tick: A_TickCount,
					DurationMs: _UIA_NO_TP_TTL_MS
				}
				_UIA_SelectionCache := 0
			} else if (Status != "ok" || PublishableText = "") {
				_UIA_SelectionCache := 0
			} else {
				_UIA_SelectionCache := {
					Text: PublishableText,
					Hwnd: Context["Hwnd"],
					Control: Context["Control"],
					InputEpoch: Context["InputEpoch"],
					CapturedAt: A_TickCount,
					Consumed: false
				}
			}
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}

	; File/log sinks never run inside the keyboard-ownership transaction.
	if (LogKind = "timeout") {
		try LoggerWarn("Layout", "UIA selection worker exceeded its {1} ms deadline; the provider is backed off for this process.", UIASW_DEADLINE_MS)
	} else if (LogKind = "failed") {
		try LoggerWarn("Layout", "UIA selection worker failed: {1}", LogDetail)
	}
}

; The repeating tick performs only cheap state gates and one PostMessage. Every
; UIA/COM hop lives in the disposable worker process; its 60 ms owner timer can
; terminate a call already in progress instead of checking a budget after it.
_UIA_SelectionPollTick() {
	global _UIA_SelectionCache, _UIA_NO_TP_CACHE, _UIA_NO_TP_TTL_MS
	global _UIA_WORKER_BACKOFF_CACHE, UIA_SELECTION_IDLE_REQUIRED_MS
	global _DriverBootPhase
	global _UIA_LastProbeHwnd, _UIA_LastProbeIdleEpoch
	; No UIA/COM work before the driver is ready. This timer is armed at include
	; position, so without this gate it fires several times during the multi-second
	; RegisterAllHotstrings boot phase — each tick doing out-of-proc STA COM round-trips
	; that pump messages and preempt the auto-execute registration thread (the
	; no-timers-armed-mid-boot policy). It also keeps the Features read below out of the
	; pre-ready window, where a Map-shape drift would throw into the fatal error net.
	; Fails CLOSED on an unset phase. The previous form passed through when
	; _DriverBootPhase was unset, which is the opposite of the guarantee the
	; comment above states. Not reachable in production — ErgoptiPlus.ahk seeds
	; the phase before any include — but the polarity should match the claim.
	if (!IsSet(_DriverBootPhase) || _DriverBootPhase != "ready")
		return
    ; SetTimer bypasses native Suspend. Retire an in-flight worker as well as
    ; clearing its cache; otherwise the detached process continues during pause.
	if A_IsSuspended {
		_UIA_SelectionCache := 0
		UIASW_Stop("canceled")
		return
	}
    ; The ONLY consumer of the cache is WrapTextIfSelected, gated on this flag.
    ; When the wrap feature is off, skip the COM round-trip entirely so non-users
    ; never pay the per-tick cost or the large-selection keyboard-thread stall
    ; risk (uia-poll-bypasses-suspend).
    if (!Features.Has("shortcuts") || !Features["shortcuts"].Has("wrap_text_if_selected") || !Features["shortcuts"]["wrap_text_if_selected"]) {
		_UIA_SelectionCache := 0
        return
    }
    ; Do not clear an existing short-lived snapshot here: a wrapping symbol can
    ; be the very next physical key after the selection gesture. We simply skip
    ; starting new COM work until the input stream has been quiet long enough.
    if (A_TimeIdlePhysical < UIA_SELECTION_IDLE_REQUIRED_MS)
        return
	; Nothing can have changed since the last probe unless the FOCUS moved or the
    ; user touched the input stream, and a selection cannot appear without one of
    ; those. So once a probe has answered "no selection" for this window, repeating
    ; it every 500 ms on an idle machine buys nothing and costs a cross-process COM
    ; round trip on the thread that dispatches keystrokes. Measured over one
    ; 31-minute session before this gate: 2993 round trips exceeded 5 ms, mean
    ; 14.3 ms, worst 301.0 ms — past Windows' ~300 ms LowLevelHooksTimeout, where
    ; the keystroke is delivered WITHOUT the hook's verdict.
    ;
    ; The skip is released by either signal, so correctness is preserved: making a
    ; selection IS physical input, which resets A_TimeIdlePhysical and therefore
    ; the epoch below. It only suppresses probes whose inputs are provably
    ; identical to the previous one.
	ActiveHwnd := WIGetForegroundHwnd()
    ; A_TimeIdlePhysical counts DOWN from the last input, so the moment of that
    ; input is what identifies the input stream's state, not the idle time itself.
	IdleEpoch := _UIA_CurrentInputEpoch()
	if (_UIA_LastProbeHwnd == ActiveHwnd and _UIA_LastProbeIdleEpoch == IdleEpoch
		and !IsObject(_UIA_SelectionCache))
		return
	ProcName := ""
	try ProcName := (IsSet(KLHook) and KLHook.HasOwnProp("prev_app")) ? KLHook.prev_app : WinGetProcessName("A")
	if (ProcName == "" or ProcName == "Code.exe") {
		_UIA_SelectionCache := 0
		return
	}
	Now := A_TickCount
	for Cache in [_UIA_NO_TP_CACHE, _UIA_WORKER_BACKOFF_CACHE] {
		if !Cache.Has(ProcName)
			continue
		Entry := Cache[ProcName]
		if !TickExpired(Entry.Tick, Entry.DurationMs, Now) {
			_UIA_SelectionCache := 0
			return
		}
		Cache.Delete(ProcName)
	}
	Context := _UIA_CurrentSelectionContext(ProcName)
	if !(Context is Map) {
		_UIA_SelectionCache := 0
		return
	}
	; Focus or physical input may change between the first idle check and the
	; context snapshot. Do not post a request for that split generation.
	if Context["Hwnd"] != ActiveHwnd || Context["InputEpoch"] != IdleEpoch
		|| A_TimeIdlePhysical < UIA_SELECTION_IDLE_REQUIRED_MS
		return

	_HpPoll := HotPath_Now()
	try {
		if !UIASW_IsReady() {
			UIASW_Start()
			return
		}
		if UIASW_Request(Context, _UIA_OnSelectionWorkerTerminal) {
			_UIA_LastProbeHwnd := ActiveHwnd
			_UIA_LastProbeIdleEpoch := IdleEpoch
		}
	} catch as Err {
		_UIA_SelectionCache := 0
		try LoggerWarn("Layout", "UIA selection worker dispatch failed: {1}", Err.Message)
	} finally {
		HotPath_LogIfSlow("UIA.SelectionPoll", _HpPoll, "")
	}
}

; Start the background selection poll.
_UIA_StartSelectionPoll() {
    global _UIA_SelectionPollTimer
    if IsSet(_UIA_SelectionPollTimer)
        return
    _UIA_SelectionPollTimer := _UIA_SelectionPollTick.Bind()
    SetTimer(_UIA_SelectionPollTimer, 500)
}
_UIA_StartSelectionPoll()

; Returns a current, single-use cached UIA selection. Non-blocking
; (uia-selection-blocks-keyboard-thread). A stale/focus-mismatched snapshot is
; discarded before it can erase and wrap unrelated text.
GetUIASelection() {
	global _UIA_SelectionCache, UIA_SELECTION_MAX_AGE_MS
	Snapshot := _UIA_SelectionCache
	if !IsObject(Snapshot)
		return ""
	if !(Snapshot.HasOwnProp("Text") and Snapshot.HasOwnProp("Hwnd")
		and Snapshot.HasOwnProp("Control") and Snapshot.HasOwnProp("InputEpoch")
		and Snapshot.HasOwnProp("CapturedAt") and Snapshot.HasOwnProp("Consumed")) {
		_UIA_SelectionCache := 0
		return ""
	}
	Elapsed := TickElapsed(Snapshot.CapturedAt)
	if Snapshot.Consumed || Snapshot.Hwnd != WIGetForegroundHwnd()
		|| Snapshot.Control != WIGetFocusedControlToken()
		|| Elapsed > UIA_SELECTION_MAX_AGE_MS {
		_UIA_SelectionCache := 0
		return ""
	}
	Snapshot.Consumed := true
	return Snapshot.Text
}

WrapTextIfSelected(Symbol, LeftSymbol, RightSymbol) {
	; Two gates must pass before a selection is wrapped:
	;   1. The master feature flag (Raccourcis > « encadrer la sélection »).
	;   2. The per-symbol enable/disable state set from the wrap-symbols menu.
	; The opening char (LeftSymbol) is the canonical key in the disabled set, so a
	; disabled asymmetric pair (e.g. « ‹ … › ») stops wrapping from BOTH its opening
	; and closing keys. Symbols absent from the catalogue (^, -) are not user-
	; configurable and therefore always wrap — WrapSymbols_IsEnabled returns true
	; for any char that was never disabled.
	; .Has() guarded like its two siblings (hotstring_inputhook.ahk and the read
	; at the top of this file). ManifestBuildFeaturesMap seeds every declared
	; path, but it returns an empty Map when the manifest fails to load, and a
	; raw read here would throw on the keystroke thread.
	WrapEnabled := Features.Has("shortcuts")
		and Features["shortcuts"].Has("wrap_text_if_selected")
		and Features["shortcuts"]["wrap_text_if_selected"]
	if (WrapEnabled and WrapSymbols_IsEnabled(LeftSymbol)) {
		; Critical is RELEASED across the selection probe and the clipboard
		; round-trip, then restored.
		;
		; This function is reached from AltGrShiftDispatch, which wraps every
		; callback in Critical("On") — and 24 of the 34 ALTGR_BASE_ROWS entries
		; plus SHIFT_SYMBOLS["SC039"] are binds of this function. CB_SaveAll() is
		; ClipboardAll(): a synchronous, unbounded, all-formats snapshot. With a
		; screenshot bitmap, large HTML/RTF or a file list on the clipboard — or
		; another process holding it open — that blocks well past
		; LowLevelHooksTimeout, at which point Windows silently DROPS every key
		; typed during the window.
		;
		; Nothing here depends on holding Critical: SendInstant takes its
		; atomicity from SendInput, which the OS batches as one injection, not
		; from the caller's Critical. This is the same release-and-restore idiom
		; DeadKey uses around its InputHook wait.
		_WrapCrit := Critical("Off")
		try {
			Selection := GetUIASelection()
			if (Selection != "") {
				; Send all the text instantly and without triggering hotstrings while
				; typing it. SendInstant returns false when its clipboard path fails
				; (another process holds the clipboard open mid-transaction) and emits
				; nothing — so degrade to the bare symbol instead of swallowing the
				; keystroke entirely (the selection is untouched in the app since ^v
				; never fired, exactly like the no-selection path below).
				; SendNewResult records the character it sent, under the same
				; reached-the-screen gate as every other emit. Recording here too
				; pushed it twice and shifted every GetLastSentCharacterAt(-N)
				; lookup by one. SendInstant, in contrast, does NOT record — so
				; the explicit push belongs only to its success branch.
				if !SendInstant(LeftSymbol Selection RightSymbol)
					SendNewResult(Symbol)
				else
					UpdateLastSentCharacter(Symbol)
				return
			}
		} finally {
			Critical(_WrapCrit)
		}
	}
	; SendEvent({Text}) doesn't work everywhere, for example in Google Sheets.
	; No UpdateLastSentCharacter after it: SendNewResult already records the
	; character it sent, and doing it again here pushed one visible character
	; into the ring twice.
	SendNewResult(Symbol)
}





; =============================
; =============================
; ======= 3/ BASE LAYER =======
; =============================
; =============================


; Returns true when digit keys 1-0 require Shift on the active OS keyboard
; layout (e.g. AZERTY, bépo). Uses VkKeyScanExW to probe the virtual-key
; binding for the character "1": a non-zero Shift bit in the high byte
; confirms that the OS layout places digits behind Shift.
_OsLayoutDigitsAreShifted() {
	HKL := GetForegroundKeyboardLayout()
	if (HKL = 0) {
		return false
	}
	; VkKeyScanExW returns a WORD: low byte = VK code, high byte = modifier
	; flags (bit 0 = Shift, bit 1 = Ctrl, bit 2 = Alt). A high byte of 1
	; means Shift is required to produce the character "1".
	Result := DllCall("VkKeyScanExW", "WStr", "1", "Ptr", HKL, "Short")
	HighByte := (Result >> 8) & 0xFF
	return (HighByte & 0x01) != 0
}

#HotIf IsSet(Features) and Features["layout"]["direct_access_digits"]
; We need to use SendEvent for symbols, otherwise it may trigger and lock AltGr. This issue happens on AZERTY at least.
; For digits, it is better to remap with sending the down event instead of using the RemapKey function.
; Otherwise, there is a problem of digit password boxes that skips to the n+2 box instead of n+2 because two down key events are sent by key
; One example is on the password box of https://github.com/login/device where they implemented an AutoShift in the boxes

; === Number row ===
; All digit-row emitters route their SendEvent through Critical("On") so they
; share the SAME atomicity contract as _RemapEmit. SendMode is "Event" (globally
; interruptible), so a non-Critical digit handler could start its SendEvent while
; a neighbouring remapped letter's SendEvent is still draining the OS input queue,
; re-introducing the out-of-order emission Critical was added to prevent — only
; with the digit as the unprotected boundary (remap-emit-critical-uneven). There
; is no Sleep on these paths, so Critical's guarantee holds.
SC029:: _DigitShiftSend("$")
SC002:: _DigitRowDown("1")
SC002 Up:: _DigitRowUp("1")
SC003:: _DigitRowDown("2")
SC003 Up:: _DigitRowUp("2")
SC004:: _DigitRowDown("3")
SC004 Up:: _DigitRowUp("3")
SC005:: _DigitRowDown("4")
SC005 Up:: _DigitRowUp("4")
SC006:: _DigitRowDown("5")
SC006 Up:: _DigitRowUp("5")
SC007:: _DigitRowDown("6")
SC007 Up:: _DigitRowUp("6")
SC008:: _DigitRowDown("7")
SC008 Up:: _DigitRowUp("7")
SC009:: _DigitRowDown("8")
SC009 Up:: _DigitRowUp("8")
SC00A:: _DigitRowDown("9")
SC00A Up:: _DigitRowUp("9")
SC00B:: _DigitRowDown("0")
SC00B Up:: _DigitRowUp("0")
SC00C:: _DigitShiftSend("%")
SC00D:: _DigitShiftSend("=")
#HotIf

; Serialised digit-row emit. Critical("On") makes the SendEvent uninterruptible
; so it cannot interleave with a neighbouring remapped letter's emit in the
; single OS input queue (remap-emit-critical-uneven). Down and Up are split so
; the key's auto-repeat / release timing is preserved exactly as before.
_DigitRowDown(Digit, *) {
	Critical("On")
	SendEvent("{" Digit " Down}")
	; Same rule as _RemapEmit and _DigitShiftSend ten lines below, which this
	; sibling was left out of: an armed suppressing hook eats this character, so
	; it must not be recorded as having reached the screen.
	if _EmitReachedScreen()
		UpdateLastSentCharacter(Digit)
}
_DigitRowUp(Digit, *) {
	Critical("On")
	SendEvent("{" Digit " Up}")
}

; On OS layouts where digits are behind Shift (e.g. AZERTY, bépo), swap
; the layers: Shift+digit-key produces the OS native symbol (passthrough),
; while the unshifted key already sends the digit via the block above.
; SC029, SC00C, SC00D (outside the 1-0 run) are intentionally left alone.
if Features["layout"]["direct_access_digits"] and _OsLayoutDigitsAreShifted() {
	; VK codes for digits 1–0 (0x31–0x39 then 0x30) paired with scancodes SC002–SC00B.
	; ToUnicodeEx does not work on KbdEdit/custom layouts (returns the digit, not the
	; shifted symbol). GetKeyName("vkXXscYYY") queries the active layout correctly
	; and returns a single-character string for printable keys — we use that instead.
	_DIGIT_VK_SC := [
		[0x31, 0x02], [0x32, 0x03], [0x33, 0x04], [0x34, 0x05], [0x35, 0x06],
		[0x36, 0x07], [0x37, 0x08], [0x38, 0x09], [0x39, 0x0A], [0x30, 0x0B]
	]
	for _, Pair in _DIGIT_VK_SC {
		VK := Pair[1]
		SC := Pair[2]
		; GetKeyName with the "vkXXscYYY" form queries whatever character the
		; active layout assigns to this VK+SC combination under Shift.
		Symbol := GetKeyName("vk" . Format("{:02X}", VK) . "sc" . Format("{:03X}", SC))
		; Only bind when we got exactly one printable character back — a longer
		; string means Windows returned a key name ("F1", "Enter"…) which would
		; mean the layout does not assign a printable symbol here.
		if (StrLen(Symbol) = 1) {
			; {Text} sends the Unicode character directly, bypassing the AHK
			; keyboard hook — so the SC002–SC00B digit remaps never fire again.
			Hotkey("+" Format("SC{:03X}", SC), _DigitShiftSend.Bind(Symbol), "I2")
		}
	}
}

; Top-level helper for the shifted-symbol send — must be at module scope so
; AHK v2 hoists it before the if-block above executes.
_DigitShiftSend(Symbol, *) {
	; Critical("On") so this shifted-symbol emit shares the one atomicity
	; contract with _RemapEmit / _DigitRowDown and cannot interleave with a
	; neighbouring remap's SendEvent (remap-emit-critical-uneven).
	Critical("On")
	; SendEvent {Text} bypasses the keyboard hook and sends the Unicode
	; character directly, so the SC002–SC00B digit remaps never interfere.
	SendEvent("{Text}" . Symbol)
	; Same rule as _RemapEmit: an armed dead-key hook eats this character, so it
	; must not be recorded as having reached the screen.
	if _EmitReachedScreen()
		UpdateLastSentCharacter(Symbol)
}

; Cannot be HotIf because the remapping is done with Hotkey function and cannot be undone afterwards.
; The character mapping itself lives in modules/keymap/layout/layout_ergopti.ahk so the
; keylogger heatmap can read the same source of truth without drifting.
if Features["layout"]["ergopti_base"] {
	for sc_int, entry in ErgoptiBaseMapping() {
		sc_str := Format("SC{:03X}", sc_int)
		if (entry is String) {
			RemapKey(sc_str, entry)
		} else if IsObject(entry) {
			alt := entry.HasOwnProp("alt") ? entry.alt : ""
			RemapKey(sc_str, entry.c, alt)
		}
	}
	; Dead keys (¨ and ^) — their behaviour goes through DeadKey()
	; rather than RemapKey, so they stay inline next to their state
	; machine. Their *positions* are still listed in
	; ErgoptiBaseLabels() so the heatmap can label them.
	Hotkey("SC01B", _DeadKeyDispatch.Bind("¨", DeadkeyMappingDiaresis), "I2")
	Hotkey("SC02B", _DeadKeyDispatch.Bind("^", DeadkeyMappingCircumflex), "I2")
}

; Base-layer dead-key entry point. The chained-sequence branch emits, so it has
; to serialize like every other emit in this file — otherwise a neighbouring
; remapped key's SendEvent can interleave with it in the OS input queue and the
; two characters come out transposed.
;
; The identical lambdas on the CapsLock layer already run under Critical, via
; LayerDispatch's SerializeSymbols path — this base-layer pair was registered
; with a raw Hotkey() and got none. Same callback, protected on one layer and
; not the other, which is the shape of the invariant-applied-per-site bug this
; codebase keeps hitting.
;
; Wrapping the DeadKey branch too is deliberate and matches the CapsLock path:
; DeadKey releases Critical around its blocking InputHook wait and restores the
; caller's level in a finally, so the composed emit that follows serializes
; exactly as intended while the wait itself never stalls the message pump.
_DeadKeyDispatch(BareChar, Mapping, *) {
	_AtCrit := Critical("On")
	try {
		if InDeadKeySequence
			SendNewResult(BareChar)
		else
			DeadKey(Mapping)
	} finally {
		Critical(_AtCrit)
	}
}

if Features["hotstrings"]["magic_key"]["replace"]["enabled"] {
	MagicSrcScan := ScriptInformation["MagicKeySourceScan"]
	MagicSrcChar := ScriptInformation["MagicKeySourceChar"]
	RemapKey(MagicSrcScan, MagicSrcChar, ScriptInformation["MagicKey"])
	if Features["layout"]["ctrl_magic_save"] {
		; InputLevel 3 overrides the Ctrl+source-scan → "^★" binding
		; that RemapKey installs at InputLevel 2, routing to Ctrl+S instead.
		Hotkey("^" . MagicSrcScan, (*) => SendFinalResult("^s"), "I3")
	}
}

; Win + ★ opens the personal TOML hotstring editor.
; Registered at InputLevel 3 so it overrides the # + source-scan → "#<char>" binding
; that RemapKey installs at InputLevel 2 for the layout remapping.
; Feature-gated like every neighbouring registration: without the #HotIf this stole an
; OS Win+<key> combo even with every Ergopti feature disabled, so "all features off"
; did not mean "no keyboard interception". The criterion is re-evaluated per press, so
; a tray toggle applies without a reload.
HotIf((*) => Features["hotstrings"]["magic_key"]["replace"]["enabled"])
Hotkey("#" . ScriptInformation["MagicKeySourceScan"], (*) => OpenPersonalEditor(), "I3")
HotIf()





; ==============================
; ==============================
; ======= 4/ SHIFT LAYER =======
; ==============================
; ==============================

; Shift layer — bindings registered table-driven via modules/keymap/layout/layout_shift_caps.ahk.
RegisterShiftLayer()





; =================================
; =================================
; ======= 5/ CAPSLOCK LAYER =======
; =================================
; =================================

GetCapsLockCondition() {
	return GetKeyState("CapsLock", "T") and not LayerEnabled
}

; CapsLock layer — bindings registered table-driven via modules/keymap/layout/layout_shift_caps.ahk.
RegisterCapsLockLayer()





; ==============================================
; ==============================================
; ======= 6/ ALTGR AND SHIFT+ALTGR LAYER =======
; ==============================================
; ==============================================

; The AltGr roll for SC012 (= / Œ / %) is registered dynamically via
; _RegisterRollsAltGrHotkeys() below. Static ``SC138 & SC012::`` would have AHK
; promote SC138 to a prefix key at parse time, which silently breaks native
; AltGr/Kana behaviour during the first-run onboarding wizard.
; AltGr roll pure-emit serialization: the roll SendEvents share the per-key Critical
; contract (remap-emit-critical-uneven / HIGH-01) so a fast follow-up key cannot
; interleave its remap SendEvent and reorder output. WrapTextIfSelected does NOT
; stay out of Critical — AltGrShiftDispatch wraps every AltGr callback, and most
; base-row entries bind it — so it releases Critical itself around its clipboard
; round-trip. The old note here claimed the exemption came from a Sleep; there is
; no Sleep any more, but ClipboardAll() blocks just as effectively.
; The Record parameter is gone. SendNewResult already records the last character
; of what it sent, so every caller that also passed Record pushed the SAME
; character into the ring twice — and its two call sites passed exactly
; SubStr(Text, -1). A doubled entry shifts every GetLastSentCharacterAt(-N)
; lookup by one, which is what the roll handlers, the quote/hashtag guards and
; the time-gated hotstring lookups all read.
_RollEmitCritical(Text) {
	_AtCrit := Critical("On")
	try {
		SendNewResult(Text)
	} finally {
		Critical(_AtCrit)
	}
}
; Serialized like AltGrShiftDispatch, which wraps EVERY base-row AltGr callback
; in Critical("On"). These two roll handlers are the exception: they are
; registered straight onto Hotkey() by _RegisterRollsAltGrHotkeys, so they never
; passed through that dispatcher. The result was one callback with two different
; concurrency contracts — WrapTextIfSelected and SendNewResult ran serialized
; when reached from a base row and bare when reached from a roll, and the bare
; path's SendEvent could interleave with a neighbouring remapped key's emit in
; the single OS input queue and reorder the output.
;
; Nesting is safe and intentional: _RollEmitCritical takes its own Critical, and
; WrapTextIfSelected releases and restores Critical itself around its clipboard
; round-trip, which is precisely why it must be entered with a known state.
_RollChevronEqualHandler(*) {
	_AtCrit := Critical("On")
	try {
		if GetKeyState("Shift", "P") {
			Features["layout"]["ergopti_plus"] ? _RollEmitCritical(" %") : _RollEmitCritical("Œ")
		} else {
			AddRollEqual()
		}
	} finally {
		Critical(_AtCrit)
	}
}
AddRollEqual() {
	LastSentCharacter := GetLastSentCharacterAt(-1)
	if (
		LastSentCharacter == "<" or LastSentCharacter == ">")
	and A_TimeSincePriorHotkey < (HotstringsResolve("rolls", "chevron_equal").Delay * 1000
	) {
		_RollEmitCritical("=")
	} else if Features["layout"]["ergopti_plus"] {
		WrapTextIfSelected("%", "%", "%")
	} else {
		_RollEmitCritical("œ")
	}
}

; The AltGr roll for SC017 (# / " / %) is also registered dynamically — same
; rationale as the SC012 block above.
; Same contract as _RollChevronEqualHandler above — its sibling registration,
; and the second of the only two AltGr callbacks that bypass AltGrShiftDispatch.
_RollHashtagQuoteHandler(*) {
	_AtCrit := Critical("On")
	try {
		if GetKeyState("Shift", "P") {
			_RollEmitCritical("%")
		} else {
			HashtagOrQuote()
		}
	} finally {
		Critical(_AtCrit)
	}
}
HashtagOrQuote() {
	LastSentCharacter := GetLastSentCharacterAt(-1)
	; The "(" / "[" → quote conversion is the paren_quote / bracket_quote roll
	; ("(#" → "(\"" and "[#" → "[\""). Gate each on ITS OWN feature flag so the menu
	; toggles for those rolls actually disable it — read live, so the toggle applies
	; with no Reload. (The SC017 hotkey itself is gated by hashtag_quote, the # roll
	; master; this adds the per-bracket granularity the menu items advertise.)
	_QuoteSection := (LastSentCharacter == "(") ? "paren_quote"
		: (LastSentCharacter == "[") ? "bracket_quote"
		: ""
	if (_QuoteSection != ""
		and A_TimeSincePriorHotkey < (HotstringsResolve("rolls", "hashtag_quote").Delay * 1000)
		and Features["hotstrings"]["rolls"].Has(_QuoteSection)
		and Features["hotstrings"]["rolls"][_QuoteSection]["enabled"]) {
		_RollEmitCritical('"')
	} else {
		WrapTextIfSelected("#", "#", "#")
	}
}

; Dynamic registration of the two AltGr rolls. Called immediately so the
; behaviour matches the previous static blocks, but kept as a function so
; the onboarding wizard can defer it (the wizard temporarily blocks it by
; registering its hotkeys AFTER Onboarding_Run() to keep SC138 native during
; first-run setup).
_RegisterRollsAltGrHotkeys() {
	HotIf((*) => Features["hotstrings"]["rolls"]["chevron_equal"]["enabled"] and IsRealAltGrPress())
	Hotkey("SC138 & SC012", _RollChevronEqualHandler, "I2")
	HotIf((*) => Features["hotstrings"]["rolls"]["hashtag_quote"]["enabled"] and IsRealAltGrPress())
	Hotkey("SC138 & SC017", _RollHashtagQuoteHandler, "I2")
	HotIf()
}

; ─────────────────────────────────────────────────────────────────────────────
; AltGr layer (ErgoptiPlus overrides + ErgoptiAltGr Number row + base rows).
; The original ~390 lines of repetitive ``SC138 & SCxxx::`` blocks are now
; defined as data in modules/keymap/layout/layout_altgr.ahk and registered here through a
; single dispatcher. Registration order matters: AHK fires the
; "most-recently-defined variant" whose #HotIf criterion is true. The AltGr
; layer is registered FIRST, then the two rolls (SC138 & SC012 chevron_equal,
; SC138 & SC017 hashtag_quote) LAST, so the roll variant wins the shared chord.
; The roll handlers already replicate the exact base-row/override fallback
; (AddRollEqual: "%" wrap under ergopti_plus else "œ"; HashtagOrQuote: "#" wrap),
; so registering them last makes the roll feature live without changing the
; non-roll output. Previously the rolls were registered FIRST, so the base rows
; shadowed them and the rolls were silently dead (altgr-rolls-dead-precedence).
; ─────────────────────────────────────────────────────────────────────────────
RegisterAltGrLayer()
_RegisterRollsAltGrHotkeys()





; ================================
; ================================
; ======= 7/ CONTROL LAYER =======
; ================================
; ================================

#HotIf IsSet(Features) and Features["layout"]["ergopti_base"]
^SC02F:: SendFinalResult("^v") ; Correct issue where Win + V paste doesn't work
*^SC00C:: SendFinalResult("^{NumpadSub}") ; Zoom out with Ctrl + %
*^SC00D:: SendFinalResult("^{NumpadAdd}") ; Zoom in with Ctrl + $
#HotIf

; In Microsoft apps like Word or Excel, we can't use Numpad + to zoom
#HotIf IsSet(Features) and Features["layout"]["ergopti_base"] and MicrosoftApps()
*^SC00C:: SendFinalResult("^{WheelDown}") ; Zoom out with (Shift +) Ctrl + %
*^SC00D:: SendFinalResult("^{WheelUp}") ; Zoom in with (Shift +) Ctrl + $
#HotIf
