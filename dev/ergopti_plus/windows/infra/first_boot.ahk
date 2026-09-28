; infra/first_boot.ahk

; ==============================================================================
; MODULE: First-Boot Configuration Bootstrap
; DESCRIPTION:
; Prepares the driver-local configuration directory while preserving absent
; files as neutral configuration. Recommendations are imported only by an
; explicit scoped restore; a first boot never materializes a preset.
;
; FEATURES & RATIONALE:
; 1. Neutral absence: no file is copied or rewritten automatically.
; 2. Idempotent directory creation keeps later atomic saves available.
; 3. Creation failures stop initialization with a paired error log.
; ==============================================================================





; =====================================
; =====================================
; ======= 1. Public entry point =======
; =====================================
; =====================================

; Prepare storage for explicit user edits without creating configuration files.
EnsureUserConfigsExist() {
	global _ConfigDir
	UserAhkDir := _ConfigDir . "autohotkey"
	; Absence is the neutral configuration. A first launch prepares storage but
	; never imports recommendations or freezes neutral values as explicit choices.
	if DirExist(UserAhkDir)
		return true
	try LoggerStart("FirstBoot", "Preparing user configuration directory…")
	try {
		DirCreate(UserAhkDir)
		try LoggerSuccess("FirstBoot", "User configuration directory is ready.")
		return true
	} catch as Err {
		try LoggerError("FirstBoot", "User configuration directory creation failed: {1}.", Err.Message)
		throw Err
	}
}
