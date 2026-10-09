; tests/meta/test_cle_emoji_gated.ahk

; ==============================================================================
; MODULE: cle-star Key-Emoji Ungated Registration Meta Test
; DESCRIPTION:
; Static source guard for finding cle-emoji-ungated (F-L01).
;
; modules/hotstrings.ahk had a stray top-level CreateHotstring("*", "cle"+MagicKey,
; key-emoji) that ran unconditionally, bypassing every hotstrings feature gate, the
; master category gate and the live-toggle system — so a user who disabled emoji
; text expansion still got the expansion. The exact same mapping already lives in
; the gated text_expansion_emojis section of magickey.toml (loaded via
; _RegisterEmojisSymbolsSections), so the stray line was a duplicate override and
; the fix deletes it; the emoji now honours its section toggle like every sibling.
;
; Meta-static (the line is top-level code, not in a function): scans the whole
; hotstrings.ahk source and asserts the key-emoji no longer appears there. The emoji
; is referenced as Chr(0x1F511) so the test file stays ASCII-only per the AHK
; source-encoding convention.
; ==============================================================================

#Requires AutoHotkey v2.0


_CEG_AssertNoUngatedCleEmoji() {
	; Scan the whole driver source (move-resilient) — the key emoji must appear in
	; NO file, an even stronger guarantee than checking hotstrings.ahk alone.
	Src := _DriverSourceConcat()
	Assert(InStr(Src, "RegisterAllHotstrings") > 0, "hotstrings.ahk must define RegisterAllHotstrings (sanity)")
	KeyEmoji := Chr(0x1F511)  ; the key emoji that only the stray ungated line emitted
	Assert(!InStr(Src, KeyEmoji),
		"modules/hotstrings.ahk must not contain an ungated CreateHotstring for the key emoji — the cle-star mapping is provided (and gated) by the text_expansion_emojis TOML section; the stray top-level registration that bypassed every feature gate must stay deleted (cle-emoji-ungated)")
}
Test("hotstrings: no ungated cle-star key-emoji registration (cle-emoji-ungated)", _CEG_AssertNoUngatedCleEmoji)
