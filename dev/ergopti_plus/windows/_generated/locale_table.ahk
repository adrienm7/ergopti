; _generated/locale_table.ahk
; AUTO-GENERATED from _shared/data/locale_order.json + locale_names.json.
; DO NOT EDIT BY HAND — run `npm run codegen:locale-tables` to refresh.
#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: Locale Table (Windows)
; DESCRIPTION:
; The language menu rows, in canonical display order.
;
; The display ORDER comes from _shared/data/locale_order.json and the native
; names from _shared/data/locale_names.json. Both are shared, because three
; hand-maintained copies is how the Linux table came to hold 16 of 21 locales
; — its five missing rows rendered as bare two-letter codes in the menu.
; The presentation column is a "[XX]" tag rather than a flag emoji, because
; flag emoji do not render in Win32 menus. It is derived from the code, so it
; carries no data of its own and cannot drift from one.
; ==============================================================================

; A function, not a global initialiser, so include order cannot matter.
LocaleTableData() {
	return [
		{ Code: "da", Tag: "[DA]", Name: "Dansk"        },
		{ Code: "de", Tag: "[DE]", Name: "Deutsch"      },
		{ Code: "en", Tag: "[EN]", Name: "English"      },
		{ Code: "es", Tag: "[ES]", Name: "Español"      },
		{ Code: "fr", Tag: "[FR]", Name: "Français"     },
		{ Code: "it", Tag: "[IT]", Name: "Italiano"     },
		{ Code: "nl", Tag: "[NL]", Name: "Nederlands"   },
		{ Code: "no", Tag: "[NO]", Name: "Norsk"        },
		{ Code: "pl", Tag: "[PL]", Name: "Polski"       },
		{ Code: "pt", Tag: "[PT]", Name: "Português"    },
		{ Code: "sv", Tag: "[SV]", Name: "Svenska"      },
		{ Code: "tr", Tag: "[TR]", Name: "Türkçe"       },
		{ Code: "cs", Tag: "[CS]", Name: "Čeština"      },
		{ Code: "ru", Tag: "[RU]", Name: "Русский"      },
		{ Code: "uk", Tag: "[UK]", Name: "Українська"   },
		{ Code: "he", Tag: "[HE]", Name: "עברית"        },
		{ Code: "ar", Tag: "[AR]", Name: "العربية"      },
		{ Code: "hi", Tag: "[HI]", Name: "हिन्दी"       },
		{ Code: "zh", Tag: "[ZH]", Name: "中文"           },
		{ Code: "ja", Tag: "[JA]", Name: "日本語"          },
		{ Code: "ko", Tag: "[KO]", Name: "한국어"          },
	]
}
