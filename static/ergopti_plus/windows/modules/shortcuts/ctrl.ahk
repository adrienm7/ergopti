; modules/shortcuts/ctrl.ahk

; ==============================================================================
; MODULE: Shortcuts — Ctrl Combos
; DESCRIPTION:
; Ctrl-layer shortcuts: Save/CtrlJ swap, Microsoft Bold fix, and
; PasteWithoutFormatting.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================
; =================================
; ======= 3/ CTRL SHORTCUTS =======
; =================================
; =================================

if Features["shortcuts"]["microsoft_bold"] {
		; Makes it possible to use the standard shortcuts instead of their translation in Microsoft apps
		AddShortcut(
				"^", "b",
				(*) => MicrosoftApps() ? SendFinalResult("^g") : SendFinalResult("^b")
		)
}

if Features["shortcuts"]["paste_without_formatting"] {
		; Ctrl + Shift + V -- paste plain text everywhere except Excel, which keeps
		; its native paste-special behaviour (re-assigning the standard combo there
		; would break the user's expected workflow).
		AddShortcut("^+", "v", PasteWithoutFormatting)

		; Deferred clipboard restore for PasteWithoutFormatting. Runs on a negative-delay
		; SetTimer so the synthetic ^v has already consumed the coerced text before the
		; user's original (possibly non-text) clipboard is put back.
		_PasteWithoutFormattingRestore(OldClip, OwnedSequence, OwnerToken) {
				return CB_RestorePlainSnapshotEventually(OldClip, OwnedSequence,
						OwnerToken, "paste_without_formatting")
		}

		PasteWithoutFormatting(*) {
				OwnerToken := CB_TryBeginPasteTransaction("paste_without_formatting")
				if !OwnerToken {
						try LoggerWarn("shortcuts", "Plain paste refused while another clipboard transaction is active.")
						return
				}
				RestoreTimerArmed := false
				try {
						if WinActive("ahk_exe EXCEL.EXE") {
								SendFinalResult("^+v")
								return
						}
						; Keep non-text formats intact and use the application's native paste.
						if CB_Read() == "" {
								SendFinalResult("^v")
								return
						}
						; Admission precedes every read, including an empty temporary clear owned
						; by another selection or paste. Only this owner may snapshot and coerce.
						Captured := 0
						if !CB_SavePlainSnapshot(OwnerToken, &Captured) {
								try LoggerWarn("shortcuts", "PasteWithoutFormatting: clipboard snapshot is unavailable or changed; using native paste.")
								SendFinalResult("^v")
								return
						}
						OldClip := Captured["saved"]
						PlainText := CB_Read()
						; Saving all formats can yield to a new non-text copy. Paste it intact.
						if PlainText == "" {
								SendFinalResult("^v")
								return
						}
						OwnedSequence := 0
						try {
								if !CB_WritePlainSnapshot(Captured, PlainText, &OwnedSequence)
										throw Error("clipboard write failed")
								if !OwnedSequence
										throw Error("clipboard sequence unavailable")
								SendFinalResult("^v")
								SetTimer(_PasteWithoutFormattingRestore.Bind(OldClip, OwnedSequence, OwnerToken), -SEND_INSTANT_PASTE_DELAY_MS)
								RestoreTimerArmed := true
						} catch as Err {
								if OwnedSequence
									try CB_RestorePlainSnapshotEventually(OldClip, OwnedSequence,
										OwnerToken, "paste_without_formatting_rollback")
								try LoggerError("shortcuts", "PasteWithoutFormatting clipboard rollback retained: {1}.", Err.Message)
						}
				} finally {
						; A deferred restore or retry debt retains the exact owner until settled.
						if !RestoreTimerArmed and !CB_HasRestoreDebtForOwner(OwnerToken)
								CB_EndOwnedTransaction(OwnerToken)
				}
		}
}
