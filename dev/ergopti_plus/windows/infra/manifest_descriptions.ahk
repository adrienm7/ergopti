; infra/manifest_descriptions.ahk

; ==============================================================================
; MODULE: Manifest Descriptions
; DESCRIPTION:
; Resolves the localised label of a feature declared in the manifest
; (``static/ergopti_plus/_shared/modules/features/manifest.toml``) by trying its
; ``description_key`` against the current i18n locale, then falling back
; through a derived chain of legacy keys when the canonical key is not in the
; locale JSON yet. The output is the string the tray menu should display,
; with the ``★`` placeholder substituted for the user's configured MagicKey.
;
; FEATURES & RATIONALE:
; 1. The manifest's ``description_key`` (e.g. ``menu.layout.ergopti_base``)
;    aims to be a single canonical i18n key. Many of those keys do not yet
;    exist in the locale JSON files, which use the legacy folded form
;    (``layout.ergoptibase``). This module bridges both formats so the menu
;    builder can read from the manifest without first migrating every
;    locale JSON entry.
; 2. Resolution order (first match wins):
;      a. Direct ``t(description_key)`` lookup.
;      b. Strip the ``menu.`` prefix; try again.
;      c. Same as (b) with underscores removed from each segment.
;      d. Same as (b) but with the ``hotstrings.`` segment dropped (hotstring
;         category entries live at ``<category>.<entry>`` in the JSON).
;      e. (d) with underscores removed.
;      f. Return the raw last segment of the path as a last-resort fallback.
; 3. ``★`` substitution happens after resolution so any locale value that
;    embeds the magic-key placeholder renders the user's actual character.
; ==============================================================================





; ========================================================
; ========================================================
; ======= 1/ Resolve description by manifest entry =======
; ========================================================
; ========================================================

; Resolve the localised label for a manifest entry (a Map carrying
; ``description_key`` and ``path``). Returns a string ready for the menu.
; ``MenuLabelFromManifestEntry``     -- preferred entry point.
MenuLabelFromManifestEntry(Entry) {
		if !IsObject(Entry) {
				return ""
		}
		DescKey := Entry.Has("description_key") ? Entry["description_key"] : ""
		Path    := Entry.Has("path")            ? Entry["path"]            : ""
		return MenuLabelFromDescriptionKey(DescKey, Path)
}

; Resolve a localised label given the manifest ``description_key`` and the
; canonical v2 ``path``. Either argument can be empty — when none of the
; derived candidate keys resolves, the function returns the last segment of the
; path (or the key itself as a last-resort sentinel).
MenuLabelFromDescriptionKey(DescKey, Path := "") {
		Label := TryMenuLabelFromDescriptionKey(DescKey, Path)
		if (Label != "") {
				return Label
		}
		; Last-resort fallback: the v2 path's tail segment, or the raw key.
		if (Path != "") {
				Parts := StrSplit(Path, ".")
				return Parts[Parts.Length]
		}
		return DescKey
}

; Try to resolve a localised label and return "" when no candidate key
; matches an entry in the active i18n locale. Used by callers that want to
; chain to a different fallback source (e.g. Features.Description for
; user-defined personal hotstring sections) rather than show the raw key.
TryMenuLabelFromManifestEntry(Entry) {
		if !IsObject(Entry) {
				return ""
		}
		DescKey := Entry.Has("description_key") ? Entry["description_key"] : ""
		Path    := Entry.Has("path")            ? Entry["path"]            : ""
		return TryMenuLabelFromDescriptionKey(DescKey, Path)
}

TryMenuLabelFromDescriptionKey(DescKey, Path := "") {
		global ScriptInformation

		Candidates := _MenuLabelCandidateKeys(DescKey, Path)
		Label := ""
		for Cand in Candidates {
				if (Cand == "") {
						continue
				}
				; I18nLookup, never t(): a miss here is this loop's normal control flow,
				; and t() reports a miss as a user-visible defect. Probing through the
				; warning accessor made every label emit several false alarms — 281 of the
				; 282 warned keys in a boot were this loop talking about itself, and they
				; buried the one genuine miss (i18n-probe-warns-about-itself).
				Resolved := I18nLookup(Cand)
				if (Resolved != "") {
						Label := Resolved
						break
				}
		}

		if (Label != "" and IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey")) {
				Label := StrReplace(Label, "★", ScriptInformation["MagicKey"])
		}
		return Label
}





; ==========================================
; ==========================================
; ======= 2/ Candidate key generator =======
; ==========================================
; ==========================================

; Build the ordered list of i18n keys to try, derived from the manifest
; description_key and the canonical v2 path. The legacy locale JSON files use a
; folded convention:
;   manifest:   ``menu.layout.ergopti_base``
;   locale:     ``layout.ergoptibase``
; so the candidate chain produces the manifest key, the v2 path, and the v2 path
; with each segment's underscores removed; the first hit wins. Folding the v2 id
; (``ergopti_base`` -> ``ergoptibase``) yields the same string the old v1
; PascalCase id folded to, so a separate v1-derived candidate is unnecessary.
_MenuLabelCandidateKeys(DescKey, Path) {
		Out := []
		if (DescKey != "") {
				Out.Push(DescKey)
		}

		; ``menu.X.Y`` -> ``X.Y``
		if (StrLen(DescKey) > 5 and SubStr(DescKey, 1, 5) == "menu.") {
				NoMenu := SubStr(DescKey, 6)
				Out.Push(NoMenu)
				Out.Push(_StripUnderscores(NoMenu))
				; ``hotstrings.X.Y`` -> ``X.Y``
				if (StrLen(NoMenu) > 11 and SubStr(NoMenu, 1, 11) == "hotstrings.") {
						NoHs := SubStr(NoMenu, 12)
						Out.Push(NoHs)
						Out.Push(_StripUnderscores(NoHs))
				}
		}

		; Same transformations starting from the v2 path (for entries whose
		; description_key is missing or non-canonical).
		if (Path != "" and Path != DescKey) {
				Out.Push(Path)
				Trimmed := Path
				; ``hotstrings.X.Y`` -> ``X.Y``.
				if (StrLen(Trimmed) > 11 and SubStr(Trimmed, 1, 11) == "hotstrings.") {
						Trimmed := SubStr(Trimmed, 12)
						Out.Push(Trimmed)
				}
				Out.Push(_StripUnderscores(Trimmed))
		}

		; The dynamic-hotstrings category folds to "dynamichotstrings" in the locale
		; (the menu category name), whereas the manifest path/description_key use the
		; short "dynamic" segment. The transformations above only strip underscores,
		; so they never bridge "dynamic" -> "dynamichotstrings" and every dynamic
		; section would fall back to its raw id. Emit the folded category key
		; explicitly: hotstrings.dynamic.text_expansion_personal_information ->
		; dynamichotstrings.textexpansionpersonalinformation.
		Combined := (DescKey != "") ? DescKey : Path
		DynPos := InStr(Combined, ".dynamic.")
		if (DynPos) {
				Section := SubStr(Combined, DynPos + StrLen(".dynamic."))
				if (Section != "") {
						Out.Push("dynamichotstrings." . Section)
						Out.Push("dynamichotstrings." . _StripUnderscores(Section))
				}
		}

		return Out
}

; Remove underscores from every segment of a dotted key while keeping the
; dots in place. ``layout.ergopti_base`` -> ``layout.ergoptibase``.
_StripUnderscores(Key) {
		return StrReplace(Key, "_", "")
}
