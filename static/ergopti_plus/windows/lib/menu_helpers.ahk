; lib/menu_helpers.ahk

; ==============================================================================
; MODULE: Tray-Menu & Personal-Editor Build Helpers
; DESCRIPTION:
; Support functions consumed by the tray-menu build and the personal
; hotstrings editor submenu: section counting, ext-TOML section parsing,
; number formatting, and the small closures that wire menu items to their
; handlers. Pure helpers — no boot-time side effects.
; ==============================================================================




; ==================================
; ==================================
; ======= 1/ Helpers ===============
; ==================================
; ==================================

; Count the exact number of hotstrings that will be generated for a DynamicHotstrings
; section — mirrors the same threshold logic used in hotstrings.ahk section 5.
; This must stay in sync with the registration code whenever prefix rules change.
; Uses a global cache to avoid redundant calculations during menu build.
CountDynamicSection(SectionName) {
		global PersonalInformation, _TomlCountCache
		CacheKey := "dynamic|" . StrLower(SectionName)
		if _TomlCountCache.Has(CacheKey)
				return _TomlCountCache[CacheKey]

		Phone := PersonalInformation["phone_number"]
		FPhone := PersonalInformation["phone_number_clean"]
		Ssn := PersonalInformation["social_security_number"]
		Iban := PersonalInformation["iban"]
		SsnRaw := StrReplace(Ssn, " ", "")
		IbanRaw := StrReplace(Iban, " ", "")

		Count := 0
		switch SectionName {
				case "DateFr", "DateLongFr", "Date", "date_fr", "date_long_fr", "date":
						Count := 1
				case "PhonePrefixes", "phone_prefixes":
						N := 0
						if StrLen(Phone) >= 2
								N += 2  ; phone[1:2]+★ and +33+phone[1:2]
						if StrLen(Phone) >= 4
								N += 2  ; phone[1:4] and +33+phone[2:4]
						if StrLen(Phone) >= 6
								N += 1  ; phone[2:5]
						if StrLen(FPhone) >= 5
								N += 1  ; fphone[1:5]
						Count := N
				case "SsnPrefixes", "ssn_prefixes":
						; No-space + spaced triggers — both fire when ssn_raw has >= 5 digits
						Count := StrLen(SsnRaw) >= 5 ? 2 : 0
				case "IbanPrefixes", "iban_prefixes":
						; 6 raw chars (no-space) and 7-char spaced trigger if iban_raw has >= 6 chars
						Count := StrLen(IbanRaw) >= 6 ? 2 : 0
				case "TextExpansionPersonalInformation", "text_expansion_personal_information":
						N := 0
						for Key, Val in PersonalInformation {
								if (Val != "")
										N++
						}
						Count := N
		}
		_TomlCountCache[CacheKey] := Count
		return Count
}
_MakeOpenSectionFn(SecName) {
		return (*) => OpenPersonalEditor(SecName)
}
; DisambiguatedLabels is the Map built by _HS_BuildDisambiguatedSectionLabels —
; Check/Uncheck must target the SAME (possibly-suffixed) label the menu was
; actually built with, or a duplicate description would resolve to the wrong
; item (duplicate-personal-section-desc-menu-mistarget).
_SetPersonalDefaultSection(SecName, PersonalMenu, TomlData, DefaultSectionMenu, DisambiguatedLabels) {
		global _PrevDefaultLabel
		_EditorPrefSet("DefaultSection", SecName)
		DefaultSectionMenu.Uncheck(t("menu.hotstrings.default_none"))
		for _, SN in TomlData["sections_order"] {
				if (SN == "-")
						continue
				if !TomlData["sections"].Has(SN)
						continue
				try DefaultSectionMenu.Uncheck(DisambiguatedLabels[SN])
		}
		if (SecName == "") {
				DefaultSectionMenu.Check(t("menu.hotstrings.default_none"))
		} else if (TomlData["sections"].Has(SecName)) {
				DefaultSectionMenu.Check(DisambiguatedLabels[SecName])
		}
		NewLabel := (SecName == "") ? t("menu.hotstrings.default_none")
				: (DisambiguatedLabels.Has(SecName) ? DisambiguatedLabels[SecName] : SecName)
		try PersonalMenu.Rename(t("menu.hotstrings.default_category_prefix") . _PrevDefaultLabel,
				t("menu.hotstrings.default_category_prefix") . NewLabel)
		_PrevDefaultLabel := NewLabel
}
_MakeSetDefaultSectionFn(SecName, PersonalMenu, TomlData, DefaultSectionMenu, DisambiguatedLabels) {
		return (*) => _SetPersonalDefaultSection(SecName, PersonalMenu, TomlData, DefaultSectionMenu, DisambiguatedLabels)
}
_TogglePersonalCloseOnAdd(PersonalMenu) {
		Label  := t("menu.hotstrings.close_on_add")
		NewVal := (_EditorPrefGet("close_on_add", "1") == "1") ? "0" : "1"
		_EditorPrefSet("close_on_add", NewVal)
		if (NewVal == "1") {
				PersonalMenu.Check(Label)
		} else {
				PersonalMenu.Uncheck(Label)
		}
}
_MakeOpenFileFn(FilePath) {
		return (*) => Run(FilePath)
}
_ParseExtTomlSections(FilePath) {
		global _ParseExtTomlSectionsCache
		if _ParseExtTomlSectionsCache.Has(FilePath)
				return _ParseExtTomlSectionsCache[FilePath]
		Result := []
		if !FileExist(FilePath) {
				_ParseExtTomlSectionsCache[FilePath] := Result
				return Result
		}
		Content := ReadTomlFile(FilePath)
		Q := Chr(34)
		SectionDescs := Map()
		SectionOrder := []
		InMetaSections := false
		loop parse, Content, "`n", "`r" {
				Trimmed := Trim(A_LoopField, " `t")
				if RegExMatch(Trimmed, "^\[([^\[\]]+)\]$", &HM) {
						InMetaSections := (Trim(HM[1]) == "_meta.sections")
						continue
				}
				if (SubStr(Trimmed, 1, 2) == "[[") {
						InMetaSections := false
						continue
				}
				if !InMetaSections
						continue
				if RegExMatch(Trimmed, '^([A-Za-z0-9_]+)\s*=\s*"((?:[^"\\]|\\.)*)"', &KM) {
						SectionKey := StrLower(KM[1])
						SectionDescs[SectionKey] := KM[2]
						SectionOrder.Push(SectionKey)
				}
		}
		SectionCounts := Map()
		CurSec := ""
		loop parse, Content, "`n", "`r" {
				Trimmed := Trim(A_LoopField, " `t")
				if RegExMatch(Trimmed, "^\[+([^\[\]]+)\]+$", &SecM) {
						CurSec := StrLower(Trim(SecM[1]))
						if (CurSec == "_meta" or CurSec == "_meta.sections") {
								CurSec := ""
						} else if !SectionCounts.Has(CurSec) {
								SectionCounts[CurSec] := 0
						}
						continue
				}
				if (CurSec != "" and Trimmed != "" and SubStr(Trimmed, 1, 1) != "#") {
						if RegExMatch(Trimmed, '^(?:"[^"]+"|[A-Za-z0-9_.-]+)\s*=') {
								SectionCounts[CurSec] := SectionCounts.Get(CurSec, 0) + 1
						}
				}
		}
		Seen := Map()
		for _, SecKey in SectionOrder {
				Seen[SecKey] := true
				Result.Push(Map("description", SectionDescs.Get(SecKey, SecKey), "count", SectionCounts.Get(SecKey, 0)))
		}
		OtherSections := []
		for SecKey, Count in SectionCounts {
				if !Seen.Has(SecKey)
						OtherSections.Push(SecKey)
		}
		_HS_BubbleSort(OtherSections)
		for _, SecKey in OtherSections {
				Result.Push(Map("description", SecKey, "count", SectionCounts[SecKey]))
		}
		_ParseExtTomlSectionsCache[FilePath] := Result
		return Result
}
_HS_BubbleSort(Array) {
	n := Array.Length
	if (n < 2)
		return
	Loop n - 1 {
		i := A_Index
		Loop n - i {
			j := A_Index
			if (StrCompare(Array[j], Array[j + 1], false) > 0) {
				Tmp := Array[j]
				Array[j] := Array[j + 1]
				Array[j + 1] := Tmp
			}
		}
	}
}
FmtCount(N) {
		global _FmtCountCache
		if _FmtCountCache.Has(N)
				return _FmtCountCache[N]
		S := String(Round(N))
		Result := ""
		Len := StrLen(S)
		loop Len {
				i := A_Index
				Result := SubStr(S, Len - i + 1, 1) . Result
				if (Mod(i, 3) == 0 and i < Len)
						Result := " " . Result
		}
		_FmtCountCache[N] := Result
		return Result
}
NoAction(*) {
}
MenuSectionTitle(Text) {
		return "— " . Text . " —"
}

; Build a Map(SecName -> disambiguated description) for the personal-hotstrings
; section list. AHK's Menu.Check/Uncheck resolves a name to the FIRST menu item
; carrying it, so two user-typed sections sharing the same description made
; toggling/selecting the SECOND section silently paint the checkmark on the
; FIRST (duplicate-personal-section-desc-menu-mistarget). Only the 2nd+
; occurrence of a given description gets a numeric " #N" suffix, so the common
; (unique) case renders identically to before, and every label built from the
; result is guaranteed unique — no i18n string needed since the disambiguator
; is a bare digit.
; @param TomlData {Map} Parsed personal_hotstrings.toml (ReadPersonalToml shape).
; @returns {Map} SecName -> disambiguated description string.
_HS_BuildDisambiguatedSectionLabels(TomlData) {
		Seen := Map()
		Out := Map()
		for _, SecName in TomlData["sections_order"] {
				if (SecName == "-" or !TomlData["sections"].Has(SecName))
						continue
				Desc := TomlData["sections"][SecName]["description"]
				Seen[Desc] := (Seen.Has(Desc) ? Seen[Desc] : 0) + 1
				Out[SecName] := (Seen[Desc] > 1) ? (Desc . " #" . Seen[Desc]) : Desc
		}
		return Out
}
