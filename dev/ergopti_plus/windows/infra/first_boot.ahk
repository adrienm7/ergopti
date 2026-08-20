; infra/first_boot.ahk

; ==============================================================================
; MODULE: First-Boot Configuration Bootstrap
; DESCRIPTION:
; On the very first launch (no user config files in _ConfigDir), copies the
; v2 config template and the shared tap-hold defaults into place so the driver
; always boots with a valid configuration. After the initial copy, the user
; owns the files and edits them freely — the bootstrap is a one-shot.
;
; FEATURES & RATIONALE:
; 1. Idempotent: each target file is only written when absent. Re-runs are
;    no-ops, so the function is safe to call on every boot.
; 2. Logged: every action (skipped, started, succeeded, failed) is recorded
;    through the standard Logger pairs (start/success, debug, error). A
;    missing template at boot is surfaced as an ERROR rather than a silent
;    fallback — running ``npm run build:manifest`` is part of the install
;    workflow and must not be skipped.
; 3. Driver-local scope: this module bootstraps only the AHK-side files
;    (``<_ConfigDir>/autohotkey/config.toml`` and ``<_ConfigDir>/autohotkey/tap_hold.toml``).
;    The universal files at the root of ``<_ConfigDir>`` (personal_info,
;    hotstrings_config) are handled separately.
; 4. Shared tap-hold source: ``tap_hold.toml`` is seeded from the cross-driver
;    ``_shared/tap_hold/defaults.toml`` directly — no generated copy in
;    ``_generated/`` is needed.
; ==============================================================================





; =====================================
; =====================================
; ======= 1. Public entry point =======
; =====================================
; =====================================

; Ensure both driver-local user config files exist. Safe to call on every boot;
; behaves as a no-op when the files are already present.
EnsureUserConfigsExist() {
	global _DriverDir, _ConfigDir, _SharedDir
	UserAhkDir      := _ConfigDir . "autohotkey"
	UserConfigPath  := UserAhkDir . "\config.toml"
	UserTapHoldPath := UserAhkDir . "\tap_hold.toml"
	TplConfigPath   := _DriverDir . "\_generated\config_template.toml"
	; Point at the cross-driver tap-hold defaults in _shared — both drivers seed
	; their per-driver tap_hold config from this single canonical template.
	TplTapHoldPath  := _SharedDir . "\tap_hold\defaults.toml"

	; Ensure the destination folder exists. DirCreate is recursive by default
	; in AHK v2 and a no-op when the directory already exists.
	try DirCreate(UserAhkDir)

	_FirstBoot_CopyIfMissing(TplConfigPath,  UserConfigPath,  "config.toml")
	_FirstBoot_CopyIfMissing(TplTapHoldPath, UserTapHoldPath, "tap_hold.toml")
}





; ===================================
; ===================================
; ======= 2. Internal helpers =======
; ===================================
; ===================================

; Copy ``SrcPath`` to ``DstPath`` only when ``DstPath`` does not exist. The
; ``Label`` argument is the human-readable file name used in log messages.
_FirstBoot_CopyIfMissing(SrcPath, DstPath, Label) {
	if FileExist(DstPath) {
		try LoggerDebug("FirstBoot", "User {1} already present — skipping bootstrap.", Label)
		return
	}
	if !FileExist(SrcPath) {
		; A missing config_template is a build-pipeline failure: ``npm run build:manifest``
		; must be run after editing ``_shared/modules/features/manifest.toml``. The driver
		; cannot synthesize a default v2 config on its own.
		try LoggerError("FirstBoot",
			"Template '{1}' not found at '{2}' — cannot bootstrap user config. "
			"Run ``npm run build:manifest`` and reload.", Label, SrcPath)
		return
	}
	try LoggerStart("FirstBoot", "Bootstrapping user {1} from template…", Label)
	try {
		FileCopy(SrcPath, DstPath)
		try LoggerSuccess("FirstBoot", "Wrote {1} to '{2}'.", Label, DstPath)
	} catch as e {
		try LoggerError("FirstBoot", "Failed to copy {1} template: {2}.", Label, e.Message)
	}
}
