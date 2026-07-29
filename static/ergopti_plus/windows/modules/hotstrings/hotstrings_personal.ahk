; modules/hotstrings/hotstrings_personal.ahk

; ==============================================================================
; MODULE: Hotstrings — Personal & Extension TOML
; DESCRIPTION:
; Registers the user's personal hotstring sections from personal_hotstrings.toml,
; in forward declaration order (most-prominent section wins tie-breaks by Seq),
; then loads any extension *.toml files found in the hotstrings\ folder. Extracted
; from modules/hotstrings.ahk to keep personal-data registration in its own file.
; ==============================================================================





; ============================================================
; ============================================================
; ======= 1/ Personal hotstrings registration function =======
; ============================================================
; ============================================================

; Registers Section 6 (personal + extension TOML) hotstrings.
; Called once by RegisterAllHotstrings() in modules/hotstrings.ahk.
_HS_RegisterPersonal() {
	global Features, ScriptInformation





	; ===========================================
	; ======================================
	; ======= 6/ Personal hotstrings =======
	; ======================================
	; ===========================================

	; Load every section declared in personal_hotstrings.toml (e.g. emailshortcuts,
	; code, professionalvocabulary, autocorrection). Each section has its own
	; toggle in Features["hotstrings"]["personal"] — disabled sections are
	; skipped silently.
	;
	; Order matters: AHK fires the LAST-registered hotstring that matches, so we
	; must register longer / more-specific triggers AFTER shorter ones. Sections
	; whose triggers start with a special prefix (@, ., :, etc.) are typically
	; longer composites of plain triggers, so we load them LAST. We achieve this
	; by iterating the v2 Map in reverse — ApplyConfigToml preserves the
	; insertion order of the [hotstrings.personal.*] sections from the user's
	; config.toml, so reversing here gives "load prominent sections last".
	if Features.Has("hotstrings") and Features["hotstrings"].Has("personal") {
	    _PersonalGroup := Features["hotstrings"]["personal"]
	    ; Forward order: the user's first-declared (most prominent) section registers
	    ; FIRST. HSE breaks equal-length trigger collisions by first-registered-wins
	    ; (lowest Seq), so loading forward makes prominent sections win — the same
	    ; effective precedence the old inline #InputLevel-0 loop produced before it
	    ; was removed (it ran forward, ahead of this block, giving prominent the
	    ; lowest Seq). The previous reverse iteration here was a stale carry-over
	    ; from AHK-native "last-registered wins" semantics, which HSE does not use.
	    for _SectionKey, _SectionCfg in _PersonalGroup {
	        if !(IsObject(_SectionCfg) and _SectionCfg.Has("enabled") and _SectionCfg["enabled"]) {
	            continue
	        }
	        ; Section key is already the lowercase TOML key (mirror preserves
	        ; .TomlSection naming verbatim) — pass it through unchanged.
	        LoadHotstringsSection("personal", _SectionKey, _SectionCfg)
	    }
	}

	; Extension personal TOML files — any *.toml in the hotstrings\ folder other than
	; personal_hotstrings.toml is loaded as an extension pack (all sections enabled,
	; no per-section toggle). Sub-folders generate hierarchical category labels.
	; Shared with the preview-index rebuild (HS_EnumeratePersonalExtFiles). The two
	; used to walk the tree independently — this one recursively, the index from a
	; single hardcoded path — so every pack registered here expanded with no tooltip
	; and nothing anywhere reported the gap. One enumeration means they cannot drift
	; apart again.
	for _, Pack in HS_EnumeratePersonalExtFiles()
		LoadExtTomlFile(Pack["Path"], Pack["Label"])
	try BootProfile_Mark("HS sub: personal + extension TOML registered")
}
