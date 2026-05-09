; static/drivers/autohotkey/lib/hotstrings_generated.ahk

; ==============================================================================
; MODULE: Generated Hotstrings Registrar
; DESCRIPTION:
; AUTO-GENERATED FILE — DO NOT EDIT BY HAND.
; Regenerate with ``python tools/compile_hotstrings.py`` from the repo root
; whenever the bundled TOML files under ``static/drivers/hotstrings/`` change.
;
; The generator reads the same TOML payload that the runtime parser used to
; consume on every startup and emits direct ``CreateHotstring`` /
; ``CreateCaseSensitiveHotstrings`` calls grouped per (category, section).
; ``LoadHotstringsSection`` consults ``_GENERATED_HOTSTRINGS`` first and only
; falls back to the TOML parser for the ``personal`` category and for sections
; this file does not cover (e.g. a freshly-added TOML file that has not yet
; been recompiled).
; ==============================================================================




; =============================================
; =============================================
; ======= 1/ Generated registry =======
; =============================================
; =============================================


global _GENERATED_HOTSTRINGS := Map(
	"distancesreduction.qu", _GenLoad_distancesreduction_qu,
	"distancesreduction.suffixesa", _GenLoad_distancesreduction_suffixesa,
	"distancesreduction.commaj", _GenLoad_distancesreduction_commaj,
	"distancesreduction.commafarletters", _GenLoad_distancesreduction_commafarletters,
	"distancesreduction.deadkeyecircumflex", _GenLoad_distancesreduction_deadkeyecircumflex,
	"distancesreduction.ecircumflexe", _GenLoad_distancesreduction_ecircumflexe,
	"sfbsreduction.comma", _GenLoad_sfbsreduction_comma,
	"sfbsreduction.ecirc", _GenLoad_sfbsreduction_ecirc,
	"sfbsreduction.egrave", _GenLoad_sfbsreduction_egrave,
	"sfbsreduction.bu", _GenLoad_sfbsreduction_bu,
	"sfbsreduction.ie", _GenLoad_sfbsreduction_ie,
	"rolls.hc", _GenLoad_rolls_hc,
	"rolls.sx", _GenLoad_rolls_sx,
	"rolls.cx", _GenLoad_rolls_cx,
	"rolls.englishnegation", _GenLoad_rolls_englishnegation,
	"rolls.ez", _GenLoad_rolls_ez,
	"rolls.ct", _GenLoad_rolls_ct,
	"rolls.closechevrontag", _GenLoad_rolls_closechevrontag,
	"rolls.chevronequal", _GenLoad_rolls_chevronequal,
	"rolls.comment", _GenLoad_rolls_comment,
	"rolls.assign", _GenLoad_rolls_assign,
	"rolls.notequal", _GenLoad_rolls_notequal,
	"rolls.hashtagquote", _GenLoad_rolls_hashtagquote,
	"rolls.hashtagparenthesis", _GenLoad_rolls_hashtagparenthesis,
	"rolls.hashtagbracket", _GenLoad_rolls_hashtagbracket,
	"rolls.equalstring", _GenLoad_rolls_equalstring,
	"rolls.leftarrow", _GenLoad_rolls_leftarrow,
	"rolls.assignarrowequalright", _GenLoad_rolls_assignarrowequalright,
	"rolls.assignarrowequalleft", _GenLoad_rolls_assignarrowequalleft,
	"rolls.assignarrowminusright", _GenLoad_rolls_assignarrowminusright,
	"rolls.assignarrowminusleft", _GenLoad_rolls_assignarrowminusleft,
	"autocorrection.accents", _GenLoad_autocorrection_accents,
	"autocorrection.names", _GenLoad_autocorrection_names,
	"autocorrection.caps", _GenLoad_autocorrection_caps,
	"autocorrection.typographicapostrophe", _GenLoad_autocorrection_typographicapostrophe,
	"autocorrection.errors", _GenLoad_autocorrection_errors,
	"autocorrection.ou", _GenLoad_autocorrection_ou,
	"autocorrection.multiplepunctuationmarks", _GenLoad_autocorrection_multiplepunctuationmarks,
	"autocorrection.suffixesachaining", _GenLoad_autocorrection_suffixesachaining,
	"autocorrection.minus", _GenLoad_autocorrection_minus,
	"autocorrection.minusapostrophe", _GenLoad_autocorrection_minusapostrophe,
	"magickey.repeat", _GenLoad_magickey_repeat,
	"magickey.textexpansion", _GenLoad_magickey_textexpansion,
	"magickey.textexpansionauto", _GenLoad_magickey_textexpansionauto,
	"magickey.textexpansionemojis", _GenLoad_magickey_textexpansionemojis,
	"magickey.textexpansionsymbols", _GenLoad_magickey_textexpansionsymbols,
	"magickey.textexpansionsymbolstypst", _GenLoad_magickey_textexpansionsymbolstypst,
)


; ===========================================
; ===========================================
; ======= 2/ Generated loaders =======
; ===========================================
; ===========================================


_GenLoad_distancesreduction_qu(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "qa", "qua", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "qà", "quà", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "qe", "que", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "qé", "qué", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "qè", "què", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "qê", "quê", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "qi", "qui", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "qo", "quo", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "q'", "qu’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "q’", "qu’", _GenOpts)
}

_GenLoad_distancesreduction_suffixesa(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àa", "aire", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àc", "ction", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "càd", "could", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "shàd", "should", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àd", "would", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àê", "able", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àf", "iste", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àg", "ought", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àh", "ight", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ài", "ying", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àk", "ique", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àl", "elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àp", "ence", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àm", "isme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àn", "ation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àq", "ique", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àr", "erre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "às", "ement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àt", "ettre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àv", "ment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àx", "ieux", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àz", "ez-vous", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "à'", "ance", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "à’", "ance", _GenOpts)
}

_GenLoad_distancesreduction_commaj(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",à", "j", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",a", "ja", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",e", "je", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",é", "jé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",i", "ji", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",o", "jo", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",u", "ju", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",ê", "ju", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",'", "j’", _GenOpts)
}

_GenLoad_distancesreduction_commafarletters(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",è", "z", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",y", "k", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",c", "ç", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",x", "où ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",s", "q", _GenOpts)
}

_GenLoad_distancesreduction_deadkeyecircumflex(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê ", "^", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê^", "^", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê¨", "/", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê_", "\", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê'", "⚠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê,", "➜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê.", "•", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê/", "⁄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê0", "🄋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê1", "➀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê2", "➁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê3", "➂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê4", "➃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê5", "➄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê6", "➅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê7", "➆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê8", "➇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê9", "➈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê:", "▶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê`;", "↪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êa", "â", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êA", "Â", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êb", "ó", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êB", "Ó", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êc", "ç", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êC", "Ç", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êd", "★", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êD", "☆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êf", "⚐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êF", "⚑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êg", "ĝ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êG", "Ĝ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êh", "ĥ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êH", "Ĥ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êi", "î", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êI", "Î", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êj", "j", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êJ", "J", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êk", "☺", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êK", "☻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êl", "†", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êL", "‡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êm", "✅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êM", "☑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ên", "ñ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êN", "Ñ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êo", "ô", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êO", "Ô", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êp", "¶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êP", "⁂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êq", "☒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êQ", "☐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êr", "º", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êR", "°", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ês", "ß", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êS", "ẞ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êu", "û", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êU", "Û", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êv", "✓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êV", "✔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êw", "ù ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êW", "Ù", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êx", "✕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êX", "✖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êy", "ŷ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êY", "Ŷ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êz", "ẑ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êZ", "Ẑ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êà", "æ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êÀ", "Æ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êè", "í", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êÈ", "Í", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êé", "œ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êÉ", "Œ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êê", "á", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êÊ", "Á", _GenOpts)
}

_GenLoad_distancesreduction_ecircumflexe(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "êe", "œ", _GenOpts)
}

_GenLoad_sfbsreduction_comma(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",f", "fl", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",g", "gl", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",h", "ph", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",z", "bj", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",v", "dv", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",n", "nl", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",t", "pt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",r", "rq", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",q", "qu’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",m", "ms", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",d", "ds", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",l", "cl", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",p", "xp", _GenOpts)
}

_GenLoad_sfbsreduction_ecirc(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "êé", "oe", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "éê", "eo", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ê.", "u.", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ê,", "u,", _GenOpts)
}

_GenLoad_sfbsreduction_egrave(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "yè", "â", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "èy", "aî", _GenOpts)
}

_GenLoad_sfbsreduction_bu(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("il a mà★", "★", _GenMK), "il a mis à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("la mà★", "★", _GenMK), "la mise à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ta mà★", "★", _GenMK), "ta mise à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ma mà★", "★", _GenMK), "ma mise à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("e mà★", "★", _GenMK), "e mise à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("es mà★", "★", _GenMK), "es mises à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mà★", "★", _GenMK), "mettre à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mià★", "★", _GenMK), "mise à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pià★", "★", _GenMK), "pièce jointe", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tà★", "★", _GenMK), "toujours", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("à★", "★", _GenMK), "bu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àu", "ub", _GenOpts)
}

_GenLoad_sfbsreduction_ie(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("ié★", "★", _GenMK), "ébu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àé", "éi", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "éà", "ié", _GenOpts)
}

_GenLoad_rolls_hc(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "hc", "wh", _GenOpts)
}

_GenLoad_rolls_sx(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "xlsx", "xlsx", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "sx", "sk", _GenOpts)
}

_GenLoad_rolls_cx(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "cx", "ck", _GenOpts)
}

_GenLoad_rolls_englishnegation(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "nt'", "n’t", _GenOpts)
}

_GenLoad_rolls_ez(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eé", "ez", _GenOpts)
}

_GenLoad_rolls_ct(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?C", "p ?", "p ?", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "p'", "ct", _GenOpts)
}

_GenLoad_rolls_closechevrontag(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "<@", "</", _GenOpts)
}

_GenLoad_rolls_chevronequal(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "<%", "<=", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", ">%", ">=", _GenOpts)
}

_GenLoad_rolls_comment(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "\`"", "/*", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "`"\", "*/", _GenOpts)
}

_GenLoad_rolls_assign(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " #ç", " := ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " #!", " := ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#ç", " := ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#!", " := ", _GenOpts)
}

_GenLoad_rolls_notequal(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " ç#", " != ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " !#", " != ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "ç#", " != ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "!#", " != ", _GenOpts)
}

_GenLoad_rolls_hashtagquote(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "(#", "(`"", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "[#", "[`"", _GenOpts)
}

_GenLoad_rolls_hashtagparenthesis(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#(", "`")", _GenOpts)
}

_GenLoad_rolls_hashtagbracket(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#[", "`"]", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#]", "`"]", _GenOpts)
}

_GenLoad_rolls_equalstring(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " [)", " = `"`"", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "[)", " = `"`"", _GenOpts)
}

_GenLoad_rolls_leftarrow(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " =+", " ➜ ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "=+", " ➜ ", _GenOpts)
}

_GenLoad_rolls_assignarrowequalright(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " $=", " => ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "$=", " => ", _GenOpts)
}

_GenLoad_rolls_assignarrowequalleft(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " =$", " <= ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "=$", " <= ", _GenOpts)
}

_GenLoad_rolls_assignarrowminusright(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " +?", " -> ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "+?", " -> ", _GenOpts)
}

_GenLoad_rolls_assignarrowminusleft(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " ?+", " <- ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "?+", " <- ", _GenOpts)
}

_GenLoad_autocorrection_accents(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "abim", "abîm", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "accroit", "accroît", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "affut", "affût", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "agé", "âgé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "agée", "âgée", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "agés", "âgés", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "agées", "âgées", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aieul", "aïeul", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aieux", "aïeux", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aigue", "aiguë", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aikido", "aïkido", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ainé", "aîné", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ambigue", "ambiguë", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ambigui", "ambiguï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ame", "âme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ames", "âmes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ane", "âne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "anerie", "ânerie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "anes", "ânes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "angstrom", "ångström", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "apotre", "apôtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "appat", "appât", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "apprete", "apprête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "appreter", "apprêter", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "apre", "âpre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "apres", "âpres", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "archaique", "archaïque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "archaisme", "archaïsme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "archeveque", "archevêque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "archeveques", "archevêques", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "arete", "arête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "aretes", "arêtes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "arome", "arôme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "arret", "arrêt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aout", "août", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aumone", "aumône", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aumonier", "aumônier", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aussitot", "aussitôt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "avant-gout", "avant-goût", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "babord", "bâbord", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "baille", "bâille", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "bacler", "bâcler", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "baclé", "bâclé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "baillon", "bâillon", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "baionnette", "baïonnette", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "batard", "bâtard", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "bati", "bâti", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "baton", "bâton", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "beche", "bêche", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "beches", "bêches", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "benet", "benêt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "benets", "benêts", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "benoite", "benoîte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "bete", "bête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "betis", "bêtis", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "bientot", "bientôt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "binome", "binôme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "blamer", "blâmer", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "bleme", "blême", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "blemes", "blêmes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "blemir", "blêmir", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "blémir", "blêmir", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "boeuf", "bœuf", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "boite", "boîte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "brul", "brûl", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "buche", "bûche", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cabler", "câbler", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "calin", "câlin", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "canoe", "canoë", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "prochaine", "prochaine", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "chaine", "chaîne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "chaîned", "chained", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "chainé", "chaîné", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chassis", "châssis", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chatain", "châtain", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chataigne", "châtaigne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chateau", "château", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chatier", "châtier", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chatiment", "châtiment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chomage", "chômage", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "chomer", "chômer", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chomeu", "chômeu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chomé", "chômé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cloitre", "cloître", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cloture", "clôture", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cloturé", "clôturé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cocaine", "cocaïne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cocaino", "cocaïno", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "coeur", "cœur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "coincide", "coïncide", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "connait", "connaît", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "controla", "contrôla", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "controle", "contrôle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "controlé", "contrôlé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "controlo", "contrôlo", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "cout", "coût", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "coute", "coûte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "couter", "coûter", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "coutera", "coûtera", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "couterez", "coûterez", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "couteu", "coûteu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "couts", "coûts", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "cote", "côte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "cotes", "côtes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cotoie", "côtoie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cotoy", "côtoy", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "craner", "crâner", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cranien", "crânien", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "croitre", "croître", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "crouton", "croûton", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "crument", "crûment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "débacle", "débâcle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "dégat", "dégât", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "dégout", "dégoût", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "dépech", "dépêch", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "dépot", "dépôt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "dépots", "dépôts", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "diplome", "diplôme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "diplomé", "diplômé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "drole", "drôle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "dument", "dûment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "écoeuré", "écœuré", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "écoeure", "écœure", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "egoisme", "égoïsme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "égoisme", "égoïsme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "egoiste", "égoïste", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "égoiste", "égoïste", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "elle-meme", "elle-même", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "elles-meme", "elles-mêmes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "elles-memes", "elles-mêmes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "embet", "embêt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "embuch", "embûch", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "empeche", "empêche", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "enchaine", "enchaîne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "enjoleu", "enjôleu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "enrole", "enrôle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "entete", "entête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "enteté", "entêté", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "entraina", "entraîna", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "entraine", "entraîne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "entrainé", "entraîné", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "entrepot", "entrepôt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "envout", "envoût", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "eux-meme", "eux-mêmes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "fache", "fâche", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "faché", "fâché", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "famé", "fâmé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "fantom", "fantôm", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "fenetre", "fenêtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "felure", "fêlure", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "félure", "fêlure", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "fete", "fête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "feter", "fêter", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "fetes", "fêtes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flane", "flâne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flaner", "flâner", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flanes", "flânes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "flaneu", "flâneu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flanez", "flânez", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flanons", "flânons", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flute", "flûte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flutes", "flûtes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "foetus", "fœtus", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "foret", "forêt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "fraich", "fraîch", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "frole", "frôle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "gach", "gâch", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "gateau", "gâteau", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gater", "gâter", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gaté", "gâté", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gatés", "gâtés", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "genant", "gênant", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gener", "gêner", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "génant", "gênant", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "génants", "gênants", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "geole", "geôle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "geolier", "geôlier", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "geoliè", "geôliè", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gout", "goût", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gouta", "goûta", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "goute", "goûte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "gouter", "goûter", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "gouteux", "goûteux", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "goutes", "goûtes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "goutez", "goûtez", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "goutons", "goûtons", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "grele", "grêle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "grèle", "grêle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "greler", "grêler", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "guepe", "guêpe", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "guepier", "guêpier", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "hawaien", "hawaïen", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "heroiq", "héroïq", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "heroisme", "héroïsme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "héroin", "héroïn", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "héroiq", "héroïq", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "héroisme", "héroïsme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "honnete", "honnête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "hopita", "hôpita", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "huitre", "huître", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "icone", "icône", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "idolatr", "idolâtr", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ile", "île", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "iles", "îles", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ilot", "îlot", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ilots", "îlots", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "impot", "impôt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "impots", "impôts", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "indu", "indû", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "indument", "indûment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "indus", "indûs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "infame", "infâme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "infamie", "infâmie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "inoui", "inouï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "interet", "intérêt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "intéret", "intérêt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "jeuner", "jeûner", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "lache", "lâche", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "laic", "laïc", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "laique", "laïque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "laius", "laïus", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "les notres", "les nôtres", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "les votres", "les vôtres", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "lui-meme", "lui-même", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "m'apprete", "m'apprête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "m’apprete", "m’apprête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "mache", "mâche", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "macher", "mâcher", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "machoire", "mâchoire", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "machouill", "mâchouill", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "maelstrom", "maelström", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "malstrom", "malström", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "maitr", "maîtr", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "male", "mâle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "males", "mâles", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "manoeuvr", "manœuvr", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "maraich", "maraîch", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "maratre", "marâtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "meler", "mêler", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "meme", "même", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "mome", "môme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "momes", "mômes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "mosaique", "mosaïque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "multitache", "multitâche", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "murement", "mûrement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "murir", "mûrir", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "naif", "naïf", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "naifs", "naïfs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "naivement", "naïvement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "naive", "naïve", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "naives", "naïves", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "naiveté", "naïveté", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "nait", "naît", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "naitre", "naître", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "noeud", "nœud", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "la notre", "la nôtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "le notre", "le nôtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "oecuméni", "œcuméni", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "oeil", "œil", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "oesophage", "œsophage", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "oeuf", "œuf", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oeuvre", "œuvre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oiaque", "oïaque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oisme", "oïsme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oiste", "oïste", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "froide", "froide", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oide", "oïde", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "opiniatre", "opiniâtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ouie", "ouïe", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ota", "ôta", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "otant", "ôtant", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "oté", "ôté", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "oter", "ôter", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "paella", "paëlla", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "palir", "pâlir", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "paquerette", "pâquerette", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "parait", "paraît", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "paranoia", "paranoïa", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "paté", "pâté", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "patée", "pâtée", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "patés", "pâtés", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "pate", "pâte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "pates", "pâtes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "pati", "pâti", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "patir", "pâtir", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "patiss", "pâtiss", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "patur", "pâtur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peche", "pêche", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "pecher", "pêcher", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peches", "pêches", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "pecheu", "pêcheu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "pentecote", "Pentecôte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "phoenix", "phœnix", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "photovoltai", "photovoltaï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "piqure", "piqûre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "plait", "plaît", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "platre", "plâtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "plutot", "plutôt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "poele", "poêle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "polynom", "polynôm", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "pret", "prêt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "prets", "prêts", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "prosaique", "prosaïque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "pylone", "pylône", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "quete", "quête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "rala", "râla", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ralais", "râlais", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ralait", "râlait", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "raler", "râler", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ralez", "râlez", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ralons", "râlons", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "rebatir", "rebâtir", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "relach", "relâch", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "rene", "rêne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "renes", "rênes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "revasse", "rêvasse", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "reve", "rêve", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "rever", "rêver", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "reverie", "rêverie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "reves", "rêves", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "requete", "requête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "rodeur", "rôdeur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "rodeuse", "rôdeuse", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "roti", "rôti", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "salpetre", "salpêtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "samourai", "samouraï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "soeur", "sœur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "soule", "soûle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "souler", "soûler", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "soules", "soûles", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "soulé", "soûlé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "stoique", "stoïque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "stoicisme", "stoïcisme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "surement", "sûrement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "sureté", "sûreté", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "surcout", "surcoût", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "surcroit", "surcroît", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "surs", "sûrs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "symptom", "symptôm", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "tabloid", "tabloïd", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "tantot", "tantôt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "tater", "tâter", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "tatons", "tâtons", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "tete", "tête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "tetes", "têtes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "theatr", "théâtr", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "théatr", "théâtr", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "tole", "tôle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "toles", "tôles", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "traina", "traîna", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "traine", "traîne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "trainer", "traîner", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "traitr", "traîtr", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "treve", "trêve", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "treves", "trêves", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "trinome", "trinôme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "trona", "trôna", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "trone", "trône", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "tempete", "tempête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "vetement", "vêtement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "voeu", "vœu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "la votre", "la vôtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "le votre", "le vôtre", _GenOpts)
}

_GenLoad_autocorrection_names(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "aid", "Aïd", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "alexei", "Alexeï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "anais", "Anaïs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "azerbaidjan", "Azerbaïdjan", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bahrein", "Bahreïn", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "benoit", "Benoît", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "caraibes", "Caraïbes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "citroen", "Citroën", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cleopatre", "Cléopâtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cléopatre", "Cléopâtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dostoievski", "Dostoïevski", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dostoieski", "Dostoïevski", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dubai", "Dubaï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "gaetan", "Gaëtan", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "hanoi", "Hanoï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "hawai", "Hawaï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "héloise", "Héloïse", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "israel", "Israël", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "jamaique", "Jamaïque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "jerome", "Jérôme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "jérome", "Jérôme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "joel", "Joël", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "joelle", "Joëlle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "koweit", "Koweït", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mickael", "Mickaël", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "nimes", "Nîmes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "noel", "Noël", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "paques", "Pâques", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "pentecote", "Pentecôte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "quatar", "Qatar", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "quatari", "qatari", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "raphael", "Raphaël", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "serguei", "Sergueï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "shanghai", "Shanghaï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "taiwan", "Taïwan", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "thais", "Thaïs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "thailande", "Thaïlande", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "tolstoi", "Tolstoï", _GenOpts)
}

_GenLoad_autocorrection_caps(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "adaboost", "AdaBoost", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "adn", "ADN", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ag", "AG", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "api", "API", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "autohotkey", "AutoHotkey", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "aws", "AWS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "axa", "AXA", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "azure devops", "Azure DevOps", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bbc", "BBC", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bbq", "BBQ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bdd", "BDD", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bdds", "BDDs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bic", "BIC", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "catboost", "CatBoost", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "chatgpt", "ChatGPT", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cli", "CLI", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "comex", "COMEX", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cpu", "CPU", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "csp", "CSP", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "css", "CSS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cv", "CV", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "data science", "Data Science", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "data scientist", "Data Scientist", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "databricks", "Databricks", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dna", "DNA", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "docker", "Docker", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ds", "DS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dynatrace", "Dynatrace", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ergopti", "Ergopti", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "esg", "ESG", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "facebook", "Facebook", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "firefox", "Firefox", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "gcp", "GCP", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "github", "GitHub", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "google", "Google", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "gps", "GPS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "gpu", "GPU", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "hammerspoon", "Hammerspoon", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ht", "HT", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ia", "IA", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "iban", "IBAN", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "insee", "INSEE", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "instagram", "Instagram", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "intellij", "IntelliJ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "json", "JSON", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ko", "KO", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "kpi", "KPI", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "kpis", "KPIs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "latex", "LaTeX", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "lightgbm", "LightGBM", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "linux", "Linux", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "llm", "LLM", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "llms", "LLMs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "lora", "LoRA", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "lualatex", "LuaLaTeX", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "macos", "macOS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "maj", "MAJ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "majs", "MAJs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mbti", "MBTI", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mcp", "MCP", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ml", "ML", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mle", "MLE", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mlflow", "MLflow", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mlops", "MLOps", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "nasa", "NASA", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "nfc", "NFC", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "nft", "NFT", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "nlp", "NLP", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ny", "NY", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ok", "OK", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "optimot", "Optimot", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "onedrive", "OneDrive", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "onenote", "OneNote", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "onu", "ONU", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "openshift", "OpenShift", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "opentelemetry", "OpenTelemetry", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "outlook", "Outlook", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "powerbi", "PowerBI", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "poc", "POC", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "pnl", "PNL", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "powerpoint", "PowerPoint", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "pr", "PR", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "qlora", "QLoRA", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "r", "R", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ram", "RAM", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "raid", "RAID", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "rdc", "RDC", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "rh", "RH", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "rib", "RIB", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "sas", "SAS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "sharepoint", "SharePoint", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "slm", "SLM", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "sql", "SQL", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ssd", "SSD", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "sncf", "SNCF", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ssh", "SSH", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ssl", "SSL", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "swift", "SWIFT", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "tiktok", "TikTok", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "tls", "TLS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ttc", "TTC", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ttm", "TTM", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ui", "UI", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "uno", "UNO", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "url", "URL", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ux", "UX", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "vpn", "VPN", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "vps", "VPS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "vscode", "VSCode", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "wikipedia", "Wikipedia", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "wikipédia", "Wikipédia", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "windows", "Windows", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "xgboost", "XGBoost", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "youtube", "YouTube", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "iaas", "IaaS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "paas", "PaaS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "saas", "SaaS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "caas", "CaaS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "faas", "FaaS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dbaas", "DBaaS", _GenOpts)
}

_GenLoad_autocorrection_typographicapostrophe(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "c'", "c’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "d'", "d’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "j'", "j’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "l'", "l’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "m'", "m’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "n'", "n’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "s'", "s’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "t'", "t’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "n't", "n’t", _GenOpts)
}

_GenLoad_autocorrection_errors(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "(_", "( ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", ")_", ") ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "+_", "+ ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "#_", "# ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "$_", "$ ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "=_", "= ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "[_", "[ ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "]_", "] ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "~_", "~ ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "*_", "* ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "OUi", "Oui", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "acceuil", "accueil", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "aeu", "eau", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eiu", "ieu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eua", "eau", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "fenètre", "fenêtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "hotsring", "hotstring", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "laieus", "laïus", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oiu", "oui", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oyu", "you", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "poru", "pour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "sru", "sur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "uio", "uoi", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "accuei", "accuei", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "uei", "uie", _GenOpts)
}

_GenLoad_autocorrection_ou(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "où .", "où.", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "où ,", "où, ", _GenOpts)
}

_GenLoad_autocorrection_multiplepunctuationmarks(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", " ! !", " !!", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "! !", "!!", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", " ? ?", " ??", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "? ?", "??", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", " ! ?", " !?", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "! ?", "!?", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", " ? !", " ?!", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "? !", "?!", _GenOpts)
}

_GenLoad_autocorrection_suffixesachaining(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàa", "aire", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàf", "iste", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàl", "elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàm", "isme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàn", "ation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàp", "ence", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ieàq", "ique", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàq", "ique", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàr", "erre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàs", "ement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàt", "ettre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàz", "ez-vous", _GenOpts)
}

_GenLoad_autocorrection_minus(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "aije", "ai-je", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "astu", "as-tu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "atil", "a-t-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "aton", "a-t-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "auratelle", "aura-t-elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "auratil", "aura-t-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "auraton", "aura-t-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "dismoi", "dis-moi", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ditelle", "dit-elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ditil", "dit-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "distu", "dis-tu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "diton", "dit-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "doisje", "dois-je", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "doitelle", "doit-elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "doitil", "doit-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "doiton", "doit-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "estu", "es-tu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "estil", "est-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "eston", "est-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "fautelle", "faut-elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "fautil", "faut-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "fauton", "faut-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peutil", "peut-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peutelle", "peut-elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peuton", "peut-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peuxtu", "peux-tu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "puisje", "puis-je", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "vatelle", "va-t-elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "vatil", "va-t-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "vaton", "va-t-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "veutelle", "veut-elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "veutil", "veut-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "veuton", "veut-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "veuxtu", "veux-tu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "yatil", "y a-t-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "vonsn", "vons-n", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "vezv", "vez-v", _GenOpts)
}

_GenLoad_autocorrection_minusapostrophe(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ai'j", "ai-j", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ai',", "ai-j", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "as't", "as-t", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a't", "a-t", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a-t’e", "a-t-e", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a't'e", "a-t-e", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a-t’i", "a-t-i", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a't'i", "a-t-i", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a-t’o", "a-t-o", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a't'o", "a-t-o", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "s',", "s-j", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "s'j", "s-j", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "s'm", "s-m", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "s'n", "s-n", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "s't", "s-t", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "t'e", "t-e", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "t'i", "t-i", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "t'o", "t-o", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "x't", "x-t", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "z'v", "z-v", _GenOpts)
}

_GenLoad_magickey_repeat(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "arrê", "arrê", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "emmê", "emmê", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "honnê", "honnê", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ccê", "ccu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ddê", "ddu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ffê", "ffu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ggê", "ggu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "llê", "llu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "mmê", "mmu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "nnê", "nnu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ppê", "ppu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "rrê", "rru", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ssê", "ssu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ttê", "ttu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("a★", "★", _GenMK), "aa", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("b★", "★", _GenMK), "bb", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("c★", "★", _GenMK), "cc", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("d★", "★", _GenMK), "dd", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("e★", "★", _GenMK), "ee", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("é★", "★", _GenMK), "éé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("è★", "★", _GenMK), "èè", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("ê★", "★", _GenMK), "êê", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("f★", "★", _GenMK), "ff", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("g★", "★", _GenMK), "gg", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("h★", "★", _GenMK), "hh", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("i★", "★", _GenMK), "ii", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("j★", "★", _GenMK), "jj", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("k★", "★", _GenMK), "kk", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("l★", "★", _GenMK), "ll", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("m★", "★", _GenMK), "mm", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("n★", "★", _GenMK), "nn", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("o★", "★", _GenMK), "oo", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("p★", "★", _GenMK), "pp", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("q★", "★", _GenMK), "qq", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("r★", "★", _GenMK), "rr", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("s★", "★", _GenMK), "ss", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("t★", "★", _GenMK), "tt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("u★", "★", _GenMK), "uu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("v★", "★", _GenMK), "vv", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("w★", "★", _GenMK), "ww", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("x★", "★", _GenMK), "xx", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("y★", "★", _GenMK), "yy", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("z★", "★", _GenMK), "zz", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("0★", "★", _GenMK), "00", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("1★", "★", _GenMK), "11", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("2★", "★", _GenMK), "22", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("3★", "★", _GenMK), "33", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("4★", "★", _GenMK), "44", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("5★", "★", _GenMK), "55", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("6★", "★", _GenMK), "66", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("7★", "★", _GenMK), "77", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("8★", "★", _GenMK), "88", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("9★", "★", _GenMK), "99", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("<★", "★", _GenMK), "<<", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace(">★", "★", _GenMK), ">>", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("{★", "★", _GenMK), "{{", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("}★", "★", _GenMK), "}}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("(★", "★", _GenMK), "((", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace(")★", "★", _GenMK), "))", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("[★", "★", _GenMK), "[[", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("]★", "★", _GenMK), "]]", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("-★", "★", _GenMK), "--", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("_★", "★", _GenMK), "__", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace(":★", "★", _GenMK), "::", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("`;★", "★", _GenMK), "`;`;", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("?★", "★", _GenMK), "??", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("!★", "★", _GenMK), "!!", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("+★", "★", _GenMK), "++", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("^★", "★", _GenMK), "^^", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("#★", "★", _GenMK), "##", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("``★", "★", _GenMK), "````", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("=★", "★", _GenMK), "==", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("/★", "★", _GenMK), "//", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("\★", "★", _GenMK), "\\", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("|★", "★", _GenMK), "||", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("&★", "★", _GenMK), "&&", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("$★", "★", _GenMK), "$$", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("@★", "★", _GenMK), "@@", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("~★", "★", _GenMK), "~~", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("*★", "★", _GenMK), "**", _GenOpts)
}

_GenLoad_magickey_textexpansion(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("ae★", "★", _GenMK), "æ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("oe★", "★", _GenMK), "œ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("1er★", "★", _GenMK), "premier", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("1ere★", "★", _GenMK), "première", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("2e★", "★", _GenMK), "deuxième", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("3e★", "★", _GenMK), "troisième", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("4e★", "★", _GenMK), "quatrième", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("5e★", "★", _GenMK), "cinquième", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("6e★", "★", _GenMK), "sixième", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("7e★", "★", _GenMK), "septième", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("8e★", "★", _GenMK), "huitième", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("9e★", "★", _GenMK), "neuvième", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("10e★", "★", _GenMK), "dixième", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("11e★", "★", _GenMK), "onzième", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("12e★", "★", _GenMK), "douzième", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("20e★", "★", _GenMK), "vingtième", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("100e★", "★", _GenMK), "centième", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("1000e★", "★", _GenMK), "millième", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("2s★", "★", _GenMK), "2 secondes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("//★", "★", _GenMK), "rapport", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("+m★", "★", _GenMK), "meilleur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("a★", "★", _GenMK), "ainsi", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("abr★", "★", _GenMK), "abréviation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("actu★", "★", _GenMK), "actualité", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("add★", "★", _GenMK), "addresse", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("admin★", "★", _GenMK), "administrateur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("afr★", "★", _GenMK), "à faire", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ah★", "★", _GenMK), "aujourd’hui", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ahk★", "★", _GenMK), "autohotkey", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ajd★", "★", _GenMK), "aujourd’hui", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("algo★", "★", _GenMK), "algorithme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("alpha★", "★", _GenMK), "alphabétique", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("amé★", "★", _GenMK), "amélioration", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("amélio★", "★", _GenMK), "amélioration", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("anc★", "★", _GenMK), "ancien", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ano★", "★", _GenMK), "anomalie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("anniv★", "★", _GenMK), "anniversaire", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("apm★", "★", _GenMK), "après-midi", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("apad★", "★", _GenMK), "à partir de", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("app★", "★", _GenMK), "application", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("appart★", "★", _GenMK), "appartement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("appli★", "★", _GenMK), "application", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("approx★", "★", _GenMK), "approximation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("archi★", "★", _GenMK), "architecture", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("arg★", "★", _GenMK), "argument", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("asso★", "★", _GenMK), "association", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("asap★", "★", _GenMK), "le plus rapidement possible", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("atd★", "★", _GenMK), "attend", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("att★", "★", _GenMK), "attention", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("au★", "★", _GenMK), "aujourd’hui", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("aud★", "★", _GenMK), "aujourd’hui", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("aug★", "★", _GenMK), "augmentation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("auj★", "★", _GenMK), "aujourd’hui", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("auto★", "★", _GenMK), "automatique", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("av★", "★", _GenMK), "avant", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("avv★", "★", _GenMK), "avez-vous", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("avvd★", "★", _GenMK), "avez-vous déjà", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("b★", "★", _GenMK), "bonjour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bb★", "★", _GenMK), "barbecue", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bc★", "★", _GenMK), "because", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bcp★", "★", _GenMK), "beaucoup", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bdd★", "★", _GenMK), "base de données", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bdds★", "★", _GenMK), "bases de données", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bea★", "★", _GenMK), "beaucoup", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bec★", "★", _GenMK), "because", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bib★", "★", _GenMK), "bibliographie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("biblio★", "★", _GenMK), "bibliographie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bjr★", "★", _GenMK), "bonjour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("brain★", "★", _GenMK), "brainstorming", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("br★", "★", _GenMK), "bonjour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bsr★", "★", _GenMK), "bonsoir", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bv★", "★", _GenMK), "bravo", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bvd★", "★", _GenMK), "boulevard", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bvn★", "★", _GenMK), "bienvenue", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bwe★", "★", _GenMK), "bon week-end", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bwk★", "★", _GenMK), "bon week-end", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("c★", "★", _GenMK), "c’est", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cad★", "★", _GenMK), "c’est-à-dire", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("camp★", "★", _GenMK), "campagne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("carac★", "★", _GenMK), "caractère", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("caract★", "★", _GenMK), "caractéristique", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cb★", "★", _GenMK), "combien", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cc★", "★", _GenMK), "copier-coller", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ccé★", "★", _GenMK), "copié-collé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ccl★", "★", _GenMK), "conclusion", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cdg★", "★", _GenMK), "Charles de Gaulle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cdt★", "★", _GenMK), "cordialement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("certif★", "★", _GenMK), "certification", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("chg★", "★", _GenMK), "charge", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("chap★", "★", _GenMK), "chapitre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("chr★", "★", _GenMK), "chercher", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ci★", "★", _GenMK), "ci-joint", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cj★", "★", _GenMK), "ci-joint", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("coeff★", "★", _GenMK), "coefficient", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cog★", "★", _GenMK), "cognition", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cogv★", "★", _GenMK), "cognitive", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("comp★", "★", _GenMK), "comprendre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cond★", "★", _GenMK), "condition", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("conds★", "★", _GenMK), "conditions", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("config★", "★", _GenMK), "configuration", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("conso★", "★", _GenMK), "consommation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("chgt★", "★", _GenMK), "changement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cnp★", "★", _GenMK), "ce n’est pas", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("contrib★", "★", _GenMK), "contribution", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("couv★", "★", _GenMK), "couverture", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cpd★", "★", _GenMK), "cependant", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cq★", "★", _GenMK), "ce que", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cr★", "★", _GenMK), "compte-rendu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ct★", "★", _GenMK), "c’était", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ctb★", "★", _GenMK), "c’est très bien", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cv★", "★", _GenMK), "ça va ?", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cvt★", "★", _GenMK), "ça va toi ?", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ctc★", "★", _GenMK), "Est-ce que cela te convient ?", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cvc★", "★", _GenMK), "Est-ce que cela vous convient ?", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dac★", "★", _GenMK), "d’accord", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ddl★", "★", _GenMK), "download", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dé★", "★", _GenMK), "déjà", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dê★", "★", _GenMK), "d’être", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("déc★", "★", _GenMK), "décembre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dec★", "★", _GenMK), "décembre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dedt★", "★", _GenMK), "d’emploi du temps", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("déf★", "★", _GenMK), "définition", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("def★", "★", _GenMK), "définition", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("défs★", "★", _GenMK), "définitions", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("démo★", "★", _GenMK), "démonstration", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("demo★", "★", _GenMK), "démonstration", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dep★", "★", _GenMK), "département", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("deux★", "★", _GenMK), "deuxième", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("desc★", "★", _GenMK), "description", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dev★", "★", _GenMK), "développeur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dév★", "★", _GenMK), "développeur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("devt★", "★", _GenMK), "développement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dico★", "★", _GenMK), "dictionnaire", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("diff★", "★", _GenMK), "différence", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("difft★", "★", _GenMK), "différent", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dim★", "★", _GenMK), "dimension", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dimi★", "★", _GenMK), "diminution", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("la dispo★", "★", _GenMK), "la disposition", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ta dispo★", "★", _GenMK), "ta disposition", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("une dispo★", "★", _GenMK), "une disposition", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dispo★", "★", _GenMK), "disponible", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("distri★", "★", _GenMK), "distributeur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("distrib★", "★", _GenMK), "distributeur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dj★", "★", _GenMK), "déjà", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dm★", "★", _GenMK), "donne-moi", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("la doc★", "★", _GenMK), "la documentation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("une doc★", "★", _GenMK), "une documentation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("doc★", "★", _GenMK), "document", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("docs★", "★", _GenMK), "documents", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dp★", "★", _GenMK), "de plus", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dr★", "★", _GenMK), "de rien", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ds★", "★", _GenMK), "data science", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dsl★", "★", _GenMK), "désolé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dst★", "★", _GenMK), "data scientist", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dtm★", "★", _GenMK), "détermine", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dvlp★", "★", _GenMK), "développe", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("e★", "★", _GenMK), "est", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("echant★", "★", _GenMK), "échantillon", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("echants★", "★", _GenMK), "échantillons", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("eco★", "★", _GenMK), "économie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ecq★", "★", _GenMK), "est-ce que", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("edt★", "★", _GenMK), "emploi du temps", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("eef★", "★", _GenMK), "en effet", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("elt★", "★", _GenMK), "élément", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("elts★", "★", _GenMK), "éléments", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("eo★", "★", _GenMK), "en outre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("enc★", "★", _GenMK), "encore", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("eng★", "★", _GenMK), "english", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("enft★", "★", _GenMK), "en fait", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ens★", "★", _GenMK), "ensemble", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ent★", "★", _GenMK), "entreprise", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("env★", "★", _GenMK), "environ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ep★", "★", _GenMK), "épisode", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("eps★", "★", _GenMK), "épisodes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("eq★", "★", _GenMK), "équation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ety★", "★", _GenMK), "étymologie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("eve★", "★", _GenMK), "événement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("evtl★", "★", _GenMK), "éventuel", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("evtle★", "★", _GenMK), "éventuelle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("evtlt★", "★", _GenMK), "éventuellement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ex★", "★", _GenMK), "exemple", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("exo★", "★", _GenMK), "exercice", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("exp★", "★", _GenMK), "expérience", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("expo★", "★", _GenMK), "exposition", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("é★", "★", _GenMK), "écart", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("échant★", "★", _GenMK), "échantillon", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("échants★", "★", _GenMK), "échantillons", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("éco★", "★", _GenMK), "économie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ém★", "★", _GenMK), "écris-moi", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("éq★", "★", _GenMK), "équation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ê★", "★", _GenMK), "être", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("êt★", "★", _GenMK), "es-tu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("f★", "★", _GenMK), "faire", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fam★", "★", _GenMK), "famille", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fb★", "★", _GenMK), "facebook", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fc★", "★", _GenMK), "fonction", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fct★", "★", _GenMK), "fonction", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fea★", "★", _GenMK), "feature", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("feat★", "★", _GenMK), "feature", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fev★", "★", _GenMK), "février", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fi★", "★", _GenMK), "financier", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fiè★", "★", _GenMK), "financière", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ff★", "★", _GenMK), "firefox", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fig★", "★", _GenMK), "figure", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fl★", "★", _GenMK), "falloir", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("freq★", "★", _GenMK), "fréquence", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fr★", "★", _GenMK), "France", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("frs★", "★", _GenMK), "français", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ft★", "★", _GenMK), "fine-tune", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ftg★", "★", _GenMK), "fine-tuning", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fti★", "★", _GenMK), "fine-tuning", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("g★", "★", _GenMK), "j’ai", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("g1r★", "★", _GenMK), "j’ai une réunion", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gar★", "★", _GenMK), "garantie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gars★", "★", _GenMK), "garanties", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gd★", "★", _GenMK), "grand", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gg★", "★", _GenMK), "google", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ges★", "★", _GenMK), "gestion", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gf★", "★", _GenMK), "j’ai fait", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gh★", "★", _GenMK), "github", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ghc★", "★", _GenMK), "GitHub Copilot", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ght★", "★", _GenMK), "j’ai acheté", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gmag★", "★", _GenMK), "j’ai mis à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gov★", "★", _GenMK), "government", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gouv★", "★", _GenMK), "gouvernement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("indiv★", "★", _GenMK), "individuel", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gpa★", "★", _GenMK), "je n’ai pas", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gt★", "★", _GenMK), "j’étais", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gvt★", "★", _GenMK), "gouvernement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("h★", "★", _GenMK), "heure", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("hf★", "★", _GenMK), "Hugging Face", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("his★", "★", _GenMK), "historique", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("histo★", "★", _GenMK), "historique", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("hs★", "★", _GenMK), "hammerspoon", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("htu★", "★", _GenMK), "how to use", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("hyp★", "★", _GenMK), "hypothèse", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ia★", "★", _GenMK), "intelligence artificielle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("id★", "★", _GenMK), "identifiant", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("idf★", "★", _GenMK), "Île-de-France", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("idk★", "★", _GenMK), "I don’t know", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ids★", "★", _GenMK), "identifiants", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("img★", "★", _GenMK), "image", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("imgs★", "★", _GenMK), "images", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("imm★", "★", _GenMK), "immeuble", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("imo★", "★", _GenMK), "in my opinion", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("imp★", "★", _GenMK), "impossible", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("inf★", "★", _GenMK), "inférieur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("info★", "★", _GenMK), "information", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("infos★", "★", _GenMK), "informations", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("infra★", "★", _GenMK), "infrastructure", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("insta★", "★", _GenMK), "instagram", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("intart★", "★", _GenMK), "intelligence artificielle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("inter★", "★", _GenMK), "international", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("intro★", "★", _GenMK), "introduction", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("j★", "★", _GenMK), "bonjour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ja★", "★", _GenMK), "jamais", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("janv★", "★", _GenMK), "janvier", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jm★", "★", _GenMK), "j’aime", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jms★", "★", _GenMK), "jamais", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jnsp★", "★", _GenMK), "je ne sais pas", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("js★", "★", _GenMK), "je suis", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jsp★", "★", _GenMK), "je ne sais pas", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jtm★", "★", _GenMK), "je t’aime", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ju★", "★", _GenMK), "jusque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ju'★", "★", _GenMK), "jusqu’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jus★", "★", _GenMK), "jusque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jusq★", "★", _GenMK), "jusqu’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jus'★", "★", _GenMK), "jusqu’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jui★", "★", _GenMK), "juillet", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("k★", "★", _GenMK), "contacter", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("kb★", "★", _GenMK), "keyboard", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("kbd★", "★", _GenMK), "keyboard", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "kdo", "cadeau", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("kn★", "★", _GenMK), "construction", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("l★", "★", _GenMK), "elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("la★", "★", _GenMK), "Los Angeles", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("lê★", "★", _GenMK), "l’être", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ledt★", "★", _GenMK), "l’emploi du temps", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("lex★", "★", _GenMK), "l’exemple", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("lgb★", "★", _GenMK), "lightgbm", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("lim★", "★", _GenMK), "limite", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("llm★", "★", _GenMK), "large language model", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("m★", "★", _GenMK), "mais", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ma★", "★", _GenMK), "madame", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("maj★", "★", _GenMK), "mise à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("majs★", "★", _GenMK), "mises à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("màj★", "★", _GenMK), "mise à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("màjs★", "★", _GenMK), "mises à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("math★", "★", _GenMK), "mathématique", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("manip★", "★", _GenMK), "manipulation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("maths★", "★", _GenMK), "mathématiques", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("max★", "★", _GenMK), "maximum", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("md★", "★", _GenMK), "markdown", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mdav★", "★", _GenMK), "merci d’avance", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mdb★", "★", _GenMK), "merci de bien vouloir", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mdl★", "★", _GenMK), "modèle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mdp★", "★", _GenMK), "mot de passe", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mdps★", "★", _GenMK), "mots de passe", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("méthodo★", "★", _GenMK), "méthodologie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("min★", "★", _GenMK), "minimum", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mio★", "★", _GenMK), "million", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mios★", "★", _GenMK), "millions", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mjo★", "★", _GenMK), "mettre à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ml★", "★", _GenMK), "machine learning", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mle★", "★", _GenMK), "machine learning engineer", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mm★", "★", _GenMK), "même", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mme★", "★", _GenMK), "madame", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("modif★", "★", _GenMK), "modification", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mom★", "★", _GenMK), "moi-même", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mq★", "★", _GenMK), "montre que", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mr★", "★", _GenMK), "monsieur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mrc★", "★", _GenMK), "merci", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("msg★", "★", _GenMK), "message", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mtn★", "★", _GenMK), "maintenant", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("moy★", "★", _GenMK), "moyenne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mutu★", "★", _GenMK), "mutualiser", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mvt★", "★", _GenMK), "mouvement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("n★", "★", _GenMK), "nouveau", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("nav★", "★", _GenMK), "navigation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("nb★", "★", _GenMK), "nombre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("nean★", "★", _GenMK), "néanmoins", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("new★", "★", _GenMK), "nouveau", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("newe★", "★", _GenMK), "nouvelle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("nimp★", "★", _GenMK), "n’importe", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("niv★", "★", _GenMK), "niveau", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("norm★", "★", _GenMK), "normalement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("nota★", "★", _GenMK), "notamment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("notm★", "★", _GenMK), "notamment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("nouv★", "★", _GenMK), "nouvelle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("nov★", "★", _GenMK), "novembre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("now★", "★", _GenMK), "maintenant", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("np★", "★", _GenMK), "ne pas", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("nrj★", "★", _GenMK), "énergie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ns★", "★", _GenMK), "nous", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("num★", "★", _GenMK), "numéro", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ny★", "★", _GenMK), "New York", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("o-★", "★", _GenMK), "au moins", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("o+★", "★", _GenMK), "au plus", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("obj★", "★", _GenMK), "objectif", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("obs★", "★", _GenMK), "observation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("oct★", "★", _GenMK), "octobre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("odj★", "★", _GenMK), "ordre du jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("opé★", "★", _GenMK), "opération", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("oqp★", "★", _GenMK), "occupé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ordi★", "★", _GenMK), "ordinateur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("org★", "★", _GenMK), "organisation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("orga★", "★", _GenMK), "organisation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ortho★", "★", _GenMK), "orthographe", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("out★", "★", _GenMK), "Où es-tu ?", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("outv★", "★", _GenMK), "Où êtes-vous ?", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ouv★", "★", _GenMK), "ouverture", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("p★", "★", _GenMK), "prendre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("p//★", "★", _GenMK), "par rapport", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("par★", "★", _GenMK), "paragraphe", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("param★", "★", _GenMK), "paramètre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("params★", "★", _GenMK), "paramètres", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pè★", "★", _GenMK), "problème", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pb★", "★", _GenMK), "problème", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pcq★", "★", _GenMK), "parce que", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pck★", "★", _GenMK), "parce que", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pckil★", "★", _GenMK), "parce qu’il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pcquil★", "★", _GenMK), "parce qu’il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pcquon★", "★", _GenMK), "parce qu’on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pckon★", "★", _GenMK), "parce qu’on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pd★", "★", _GenMK), "pendant", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pdt★", "★", _GenMK), "pendant", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pdv★", "★", _GenMK), "point de vue", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pdvs★", "★", _GenMK), "points de vue", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("perf★", "★", _GenMK), "performance", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("perso★", "★", _GenMK), "personne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pê★", "★", _GenMK), "peut-être", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("péri★", "★", _GenMK), "périmètre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("périm★", "★", _GenMK), "périmètre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("peut-ê★", "★", _GenMK), "peut-être", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pex★", "★", _GenMK), "par exemple", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pf★", "★", _GenMK), "portefeuille", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pg★", "★", _GenMK), "pas grave", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pgm★", "★", _GenMK), "programme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pi★", "★", _GenMK), "pour information", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pic★", "★", _GenMK), "picture", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pics★", "★", _GenMK), "pictures", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("piè★", "★", _GenMK), "pièce jointe", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pj★", "★", _GenMK), "pièce jointe", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pjs★", "★", _GenMK), "pièces jointes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pk★", "★", _GenMK), "pourquoi", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pls★", "★", _GenMK), "please", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("poc★", "★", _GenMK), "proof of concept", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("poum★", "★", _GenMK), "plus ou moins", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("poss★", "★", _GenMK), "possible", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pourcent★", "★", _GenMK), "pourcentage", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ppt★", "★", _GenMK), "PowerPoint", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pq★", "★", _GenMK), "pourquoi", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pr★", "★", _GenMK), "pull request", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prd★", "★", _GenMK), "produit", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prem★", "★", _GenMK), "premier", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prez★", "★", _GenMK), "présentation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prg★", "★", _GenMK), "programme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prio★", "★", _GenMK), "priorité", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pro★", "★", _GenMK), "professionnel", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prob★", "★", _GenMK), "problème", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("proba★", "★", _GenMK), "probabilité", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prod★", "★", _GenMK), "production", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prof★", "★", _GenMK), "professeur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prog★", "★", _GenMK), "programme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prop★", "★", _GenMK), "propriété", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("propo★", "★", _GenMK), "proposition", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("props★", "★", _GenMK), "propriétés", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pros★", "★", _GenMK), "professionnels", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prot★", "★", _GenMK), "professionnellement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prov★", "★", _GenMK), "provision", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("psycha★", "★", _GenMK), "psychanalyse", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("psycho★", "★", _GenMK), "psychologie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("psb★", "★", _GenMK), "possible", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("psy★", "★", _GenMK), "psychologie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pt★", "★", _GenMK), "point", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ptf★", "★", _GenMK), "portefeuille", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pts★", "★", _GenMK), "points", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pub★", "★", _GenMK), "publicité", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pvv★", "★", _GenMK), "pouvez-vous", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("py★", "★", _GenMK), "python", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("q★", "★", _GenMK), "question", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("qc★", "★", _GenMK), "qu’est-ce", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("qcq★", "★", _GenMK), "qu’est-ce que", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("qcq'★", "★", _GenMK), "qu’est-ce qu’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("qq★", "★", _GenMK), "quelque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("qqch★", "★", _GenMK), "quelque chose", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("qqs★", "★", _GenMK), "quelques", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("qqn★", "★", _GenMK), "quelqu’un", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("quasi★", "★", _GenMK), "quasiment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ques★", "★", _GenMK), "question", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("quid★", "★", _GenMK), "qu’en est-il de", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("r★", "★", _GenMK), "rien", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rapidt★", "★", _GenMK), "rapidement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rdc★", "★", _GenMK), "rez-de-chaussée", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rdv★", "★", _GenMK), "rendez-vous", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ré★", "★", _GenMK), "réunion", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rés★", "★", _GenMK), "réunions", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rép★", "★", _GenMK), "répertoire", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("résil★", "★", _GenMK), "résiliation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("reco★", "★", _GenMK), "recommandation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ref★", "★", _GenMK), "référence", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rep★", "★", _GenMK), "répertoire", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rex★", "★", _GenMK), "retour d’expérience", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rh★", "★", _GenMK), "ressources humaines", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rmq★", "★", _GenMK), "remarque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rpz★", "★", _GenMK), "représente", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rs★", "★", _GenMK), "résultat", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("seg★", "★", _GenMK), "segment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("segm★", "★", _GenMK), "segment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("sep★", "★", _GenMK), "septembre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("sept★", "★", _GenMK), "septembre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("simpl★", "★", _GenMK), "simplement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("situ★", "★", _GenMK), "situation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("smth★", "★", _GenMK), "something", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("srx★", "★", _GenMK), "sérieux", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("sécu★", "★", _GenMK), "sécurité", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("st★", "★", _GenMK), "s’était", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("stat★", "★", _GenMK), "statistique", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("sth★", "★", _GenMK), "something", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("stp★", "★", _GenMK), "s’il te plaît", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("strat★", "★", _GenMK), "stratégique", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("stream★", "★", _GenMK), "streaming", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("suff★", "★", _GenMK), "suffisant", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("sufft★", "★", _GenMK), "suffisamment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("supé★", "★", _GenMK), "supérieur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("surv★", "★", _GenMK), "survenance", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("svp★", "★", _GenMK), "s’il vous plaît", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("svt★", "★", _GenMK), "souvent", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("sya★", "★", _GenMK), "s’il y a", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("syn★", "★", _GenMK), "synonyme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("sync★", "★", _GenMK), "synchronisation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("syncro★", "★", _GenMK), "synchronisation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("sys★", "★", _GenMK), "système", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("t★", "★", _GenMK), "très", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tb★", "★", _GenMK), "très bien", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("temp★", "★", _GenMK), "temporaire", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tes★", "★", _GenMK), "tu es", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tél★", "★", _GenMK), "téléphone", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("teq★", "★", _GenMK), "telle que", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("teqs★", "★", _GenMK), "telles que", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tfk★", "★", _GenMK), "qu’est-ce que tu fais ?", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tgh★", "★", _GenMK), "together", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("théo★", "★", _GenMK), "théorie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("thm★", "★", _GenMK), "théorème", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tj★", "★", _GenMK), "toujours", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tjr★", "★", _GenMK), "toujours", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tlm★", "★", _GenMK), "tout le monde", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tq★", "★", _GenMK), "tel que", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tqs★", "★", _GenMK), "tels que", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tout★", "★", _GenMK), "toutefois", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tra★", "★", _GenMK), "travail", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("trad★", "★", _GenMK), "traduction", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("trav★", "★", _GenMK), "travail", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("trkl★", "★", _GenMK), "tranquille", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tt★", "★", _GenMK), "télétravail", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ttm★", "★", _GenMK), "time to market", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tv★", "★", _GenMK), "télévision", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ty★", "★", _GenMK), "thank you", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("typo★", "★", _GenMK), "typographie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("une amé★", "★", _GenMK), "une amélioration", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("uniq★", "★", _GenMK), "uniquement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("usa★", "★", _GenMK), "États-Unis", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("v★", "★", _GenMK), "version", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("var★", "★", _GenMK), "variable", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("vav★", "★", _GenMK), "vis-à-vis", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("verif★", "★", _GenMK), "vérification", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("vérif★", "★", _GenMK), "vérification", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("vocab★", "★", _GenMK), "vocabulaire", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("volat★", "★", _GenMK), "volatilité", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("vrm★", "★", _GenMK), "vraiment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("vrmt★", "★", _GenMK), "vraiment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("vs★", "★", _GenMK), "vous êtes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("vsc★", "★", _GenMK), "VSCode", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("w★", "★", _GenMK), "with", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("wd★", "★", _GenMK), "windows", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("wk★", "★", _GenMK), "week-end", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("wknd★", "★", _GenMK), "week-end", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("wiki★", "★", _GenMK), "wikipédia", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("x★", "★", _GenMK), "exemple", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("xg★", "★", _GenMK), "xgboost", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("xgb★", "★", _GenMK), "xgboost", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("xp★", "★", _GenMK), "expérience", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ya★", "★", _GenMK), "il y a", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("yapa★", "★", _GenMK), "il n’y a pas", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("yatil★", "★", _GenMK), "y a-t-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("yc★", "★", _GenMK), "y compris", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("yt★", "★", _GenMK), "youtube", _GenOpts)
}

_GenLoad_magickey_textexpansionauto(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ju'", "jusqu’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ya", "y’a", _GenOpts)
}

_GenLoad_magickey_textexpansionemojis(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace(":)★", "★", _GenMK), "😀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace(":))★", "★", _GenMK), "😁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace(":/★", "★", _GenMK), "🫤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace(":(★", "★", _GenMK), "☹️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace(":3★", "★", _GenMK), "😗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace(":D★", "★", _GenMK), "😁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace(":O★", "★", _GenMK), "😮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace(":P★", "★", _GenMK), "😛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("abeille★", "★", _GenMK), "🐝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("aigle★", "★", _GenMK), "🦅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("araignée★", "★", _GenMK), "🕷️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("baleine★", "★", _GenMK), "🐋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("canard★", "★", _GenMK), "🦆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cerf★", "★", _GenMK), "🦌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("chameau★", "★", _GenMK), "🐪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("chat★", "★", _GenMK), "🐈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("chauve-souris★", "★", _GenMK), "🦇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("chèvre★", "★", _GenMK), "🐐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cheval★", "★", _GenMK), "🐎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("chien★", "★", _GenMK), "🐕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cochon★", "★", _GenMK), "🐖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("coq★", "★", _GenMK), "🐓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("crabe★", "★", _GenMK), "🦀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("croco★", "★", _GenMK), "🐊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("crocodile★", "★", _GenMK), "🐊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cygne★", "★", _GenMK), "🦢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("dauphin★", "★", _GenMK), "🐬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("dragon★", "★", _GenMK), "🐉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("écureuil★", "★", _GenMK), "🐿️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("éléphant★", "★", _GenMK), "🐘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("escargot★", "★", _GenMK), "🐌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("flamant★", "★", _GenMK), "🦩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fourmi★", "★", _GenMK), "🐜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("girafe★", "★", _GenMK), "🦒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("gorille★", "★", _GenMK), "🦍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("grenouille★", "★", _GenMK), "🐸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("hamster★", "★", _GenMK), "🐹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("hérisson★", "★", _GenMK), "🦔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("hibou★", "★", _GenMK), "🦉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("hippopotame★", "★", _GenMK), "🦛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("homard★", "★", _GenMK), "🦞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("kangourou★", "★", _GenMK), "🦘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("koala★", "★", _GenMK), "🐨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("lama★", "★", _GenMK), "🦙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("lapin★", "★", _GenMK), "🐇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("léopard★", "★", _GenMK), "🐆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("licorne★", "★", _GenMK), "🦄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("lion★", "★", _GenMK), "🦁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("loup★", "★", _GenMK), "🐺", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("mouton★", "★", _GenMK), "🐑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("octopus★", "★", _GenMK), "🐙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ours★", "★", _GenMK), "🐻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("panda★", "★", _GenMK), "🐼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("papillon★", "★", _GenMK), "🦋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("paresseux★", "★", _GenMK), "🦥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("perroquet★", "★", _GenMK), "🦜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pingouin★", "★", _GenMK), "🐧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("poisson★", "★", _GenMK), "🐟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("poule★", "★", _GenMK), "🐔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("poussin★", "★", _GenMK), "🐣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("renard★", "★", _GenMK), "🦊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("requin★", "★", _GenMK), "🦈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("rhinocéros★", "★", _GenMK), "🦏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("rhinoceros★", "★", _GenMK), "🦏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("sanglier★", "★", _GenMK), "🐗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("serpent★", "★", _GenMK), "🐍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("singe★", "★", _GenMK), "🐒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("souris★", "★", _GenMK), "🐁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("tigre★", "★", _GenMK), "🐅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("tortue★", "★", _GenMK), "🐢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("trex★", "★", _GenMK), "🦖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("vache★", "★", _GenMK), "🐄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("zèbre★", "★", _GenMK), "🦓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("aimant★", "★", _GenMK), "🧲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ampoule★", "★", _GenMK), "💡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ancre★", "★", _GenMK), "⚓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("arbre★", "★", _GenMK), "🌲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("argent★", "★", _GenMK), "💰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("attention★", "★", _GenMK), "⚠️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("avion★", "★", _GenMK), "✈️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("balance★", "★", _GenMK), "⚖️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ballon★", "★", _GenMK), "🎈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("batterie★", "★", _GenMK), "🔋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("blanc★", "★", _GenMK), "🏳️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("bombe★", "★", _GenMK), "💣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("boussole★", "★", _GenMK), "🧭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("brain★", "★", _GenMK), "🧠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("bougie★", "★", _GenMK), "🕯️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cadeau★", "★", _GenMK), "🎁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cadenas★", "★", _GenMK), "🔒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("calendrier★", "★", _GenMK), "📅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("caméra★", "★", _GenMK), "📷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cerveau★", "★", _GenMK), "🧠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("clavier★", "★", _GenMK), "⌨️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("check★", "★", _GenMK), "✔️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("clé★", "★", _GenMK), "🔑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cloche★", "★", _GenMK), "🔔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("computer★", "★", _GenMK), "💻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("couronne★", "★", _GenMK), "👑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("croix★", "★", _GenMK), "❌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("danse★", "★", _GenMK), "💃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("diamant★", "★", _GenMK), "💎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("drapeau★", "★", _GenMK), "🏁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("douche★", "★", _GenMK), "🛁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("éclair★", "★", _GenMK), "⚡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("eau★", "★", _GenMK), "💧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("email★", "★", _GenMK), "📧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("épée★", "★", _GenMK), "⚔️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("étoile★", "★", _GenMK), "⭐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("faux★", "★", _GenMK), "❌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("feu★", "★", _GenMK), "🔥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fete★", "★", _GenMK), "🎉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fête★", "★", _GenMK), "🎉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("film★", "★", _GenMK), "🎬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fleur★", "★", _GenMK), "🌸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fusée★", "★", _GenMK), "🚀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("guitare★", "★", _GenMK), "🎸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("idée★", "★", _GenMK), "💡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("idee★", "★", _GenMK), "💡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("interdit★", "★", _GenMK), "⛔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("journal★", "★", _GenMK), "📰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ko★", "★", _GenMK), "❌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("livre★", "★", _GenMK), "📖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("loupe★", "★", _GenMK), "🔎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("lune★", "★", _GenMK), "🌙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("médaille★", "★", _GenMK), "🥇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("medaille★", "★", _GenMK), "🥇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("microphone★", "★", _GenMK), "🎤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("montre★", "★", _GenMK), "⌚", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("musique★", "★", _GenMK), "🎵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("noel★", "★", _GenMK), "🎄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("nuage★", "★", _GenMK), "☁️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ok★", "★", _GenMK), "✅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("olaf★", "★", _GenMK), "⛄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ordi★", "★", _GenMK), "💻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ordinateur★", "★", _GenMK), "💻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("parapluie★", "★", _GenMK), "☂️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pc★", "★", _GenMK), "💻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("piano★", "★", _GenMK), "🎹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pirate★", "★", _GenMK), "🏴‍☠️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pluie★", "★", _GenMK), "🌧️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("radioactif★", "★", _GenMK), "☢️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("regard★", "★", _GenMK), "👀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("robot★", "★", _GenMK), "🤖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("rocket★", "★", _GenMK), "🚀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("sacoche★", "★", _GenMK), "💼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("smartphone★", "★", _GenMK), "📱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("soleil★", "★", _GenMK), "☀️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("terre★", "★", _GenMK), "🌍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("thermomètre★", "★", _GenMK), "🌡️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("timer★", "★", _GenMK), "⏲️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("toilette★", "★", _GenMK), "🧻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("trophee★", "★", _GenMK), "🏆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("trophée★", "★", _GenMK), "🏆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("trophy★", "★", _GenMK), "🏆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("telephone★", "★", _GenMK), "☎️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("téléphone★", "★", _GenMK), "☎️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("train★", "★", _GenMK), "🚂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("vélo★", "★", _GenMK), "🚲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("voiture★", "★", _GenMK), "🚗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("yeux★", "★", _GenMK), "👀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ananas★", "★", _GenMK), "🍍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("aubergine★", "★", _GenMK), "🍆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("avocat★", "★", _GenMK), "🥑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("banane★", "★", _GenMK), "🍌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("bière★", "★", _GenMK), "🍺", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("brocoli★", "★", _GenMK), "🥦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("burger★", "★", _GenMK), "🍔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("café★", "★", _GenMK), "☕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("carotte★", "★", _GenMK), "🥕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cerise★", "★", _GenMK), "🍒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("champignon★", "★", _GenMK), "🍄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("chocolat★", "★", _GenMK), "🍫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("citron★", "★", _GenMK), "🍋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("coco★", "★", _GenMK), "🥥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cookie★", "★", _GenMK), "🍪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("croissant★", "★", _GenMK), "🥐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("donut★", "★", _GenMK), "🍩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fraise★", "★", _GenMK), "🍓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("frites★", "★", _GenMK), "🍟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fromage★", "★", _GenMK), "🧀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("gâteau★", "★", _GenMK), "🎂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("glace★", "★", _GenMK), "🍦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("hamburger★", "★", _GenMK), "🍔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("hotdog★", "★", _GenMK), "🌭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("kebab★", "★", _GenMK), "🥙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("kiwi★", "★", _GenMK), "🥝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("lait★", "★", _GenMK), "🥛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("maïs★", "★", _GenMK), "🌽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("melon★", "★", _GenMK), "🍈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("miel★", "★", _GenMK), "🍯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("orange★", "★", _GenMK), "🍊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pain★", "★", _GenMK), "🍞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pastèque★", "★", _GenMK), "🍉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pates★", "★", _GenMK), "🍝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pêche★", "★", _GenMK), "🍑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pizza★", "★", _GenMK), "🍕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("poire★", "★", _GenMK), "🍐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pomme★", "★", _GenMK), "🍎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("popcorn★", "★", _GenMK), "🍿", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("raisin★", "★", _GenMK), "🍇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("riz★", "★", _GenMK), "🍚", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("salade★", "★", _GenMK), "🥗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("sandwich★", "★", _GenMK), "🥪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("spaghetti★", "★", _GenMK), "🍝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("taco★", "★", _GenMK), "🌮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("tacos★", "★", _GenMK), "🌮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("thé★", "★", _GenMK), "🍵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("tomate★", "★", _GenMK), "🍅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("vin★", "★", _GenMK), "🍷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("amour★", "★", _GenMK), "🥰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ange★", "★", _GenMK), "👼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("bisou★", "★", _GenMK), "😘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("bouche★", "★", _GenMK), "🤭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("caca★", "★", _GenMK), "💩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("clap★", "★", _GenMK), "👏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("clin★", "★", _GenMK), "😉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cœur★", "★", _GenMK), "❤️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("coeur★", "★", _GenMK), "❤️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("colère★", "★", _GenMK), "😠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cowboy★", "★", _GenMK), "🤠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("dégoût★", "★", _GenMK), "🤮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("délice★", "★", _GenMK), "😋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("délicieux★", "★", _GenMK), "😋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("diable★", "★", _GenMK), "😈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("dislike★", "★", _GenMK), "👎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("dodo★", "★", _GenMK), "😴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("effroi★", "★", _GenMK), "😱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("facepalm★", "★", _GenMK), "🤦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fatigue★", "★", _GenMK), "😩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fier★", "★", _GenMK), "😤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fort★", "★", _GenMK), "💪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fou★", "★", _GenMK), "🤪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("heureux★", "★", _GenMK), "😊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("innocent★", "★", _GenMK), "😇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("intello★", "★", _GenMK), "🤓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("larme★", "★", _GenMK), "😢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("larmes★", "★", _GenMK), "😭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("like★", "★", _GenMK), "👍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("lol★", "★", _GenMK), "😂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("lunettes★", "★", _GenMK), "🤓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("malade★", "★", _GenMK), "🤒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("masque★", "★", _GenMK), "😷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("mdr★", "★", _GenMK), "😂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("mignon★", "★", _GenMK), "🥺", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("monocle★", "★", _GenMK), "🧐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("mort★", "★", _GenMK), "💀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("muscles★", "★", _GenMK), "💪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("(n)★", "★", _GenMK), "👎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("nice★", "★", _GenMK), "👌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ouf★", "★", _GenMK), "😅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("oups★", "★", _GenMK), "😅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("parfait★", "★", _GenMK), "👌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("penser★", "★", _GenMK), "🤔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pensif★", "★", _GenMK), "🤔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("peur★", "★", _GenMK), "😨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pleur★", "★", _GenMK), "😭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pleurer★", "★", _GenMK), "😭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pouce★", "★", _GenMK), "👍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("rage★", "★", _GenMK), "😡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("rire★", "★", _GenMK), "😂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("silence★", "★", _GenMK), "🤫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("snif★", "★", _GenMK), "😢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("stress★", "★", _GenMK), "😰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("strong★", "★", _GenMK), "💪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("surprise★", "★", _GenMK), "😲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("timide★", "★", _GenMK), "😳", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("triste★", "★", _GenMK), "😢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("victoire★", "★", _GenMK), "✌️", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("(y)★", "★", _GenMK), "👍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("zombie★", "★", _GenMK), "🧟", _GenOpts)
}

_GenLoad_magickey_textexpansionsymbols(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/★", "★", _GenMK), "⅟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/2★", "★", _GenMK), "½", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("0/3★", "★", _GenMK), "↉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/3★", "★", _GenMK), "⅓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("2/3★", "★", _GenMK), "⅔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/4★", "★", _GenMK), "¼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("3/4★", "★", _GenMK), "¾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/5★", "★", _GenMK), "⅕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("2/5★", "★", _GenMK), "⅖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("3/5★", "★", _GenMK), "⅗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("4/5★", "★", _GenMK), "⅘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/6★", "★", _GenMK), "⅙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("5/6★", "★", _GenMK), "⅚", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/8★", "★", _GenMK), "⅛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("3/8★", "★", _GenMK), "⅜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("5/8★", "★", _GenMK), "⅝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("7/8★", "★", _GenMK), "⅞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/7★", "★", _GenMK), "⅐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/9★", "★", _GenMK), "⅑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/10★", "★", _GenMK), "⅒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(0)★", "★", _GenMK), "🄋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(1)★", "★", _GenMK), "➀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(2)★", "★", _GenMK), "➁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(3)★", "★", _GenMK), "➂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(4)★", "★", _GenMK), "➃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(5)★", "★", _GenMK), "➄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(6)★", "★", _GenMK), "➅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(7)★", "★", _GenMK), "➆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(8)★", "★", _GenMK), "➇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(9)★", "★", _GenMK), "➈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(10)★", "★", _GenMK), "➉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(0n)★", "★", _GenMK), "🄌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(1n)★", "★", _GenMK), "➊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(2n)★", "★", _GenMK), "➋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(3n)★", "★", _GenMK), "➌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(4n)★", "★", _GenMK), "➍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(5n)★", "★", _GenMK), "➎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(6n)★", "★", _GenMK), "➏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(7n)★", "★", _GenMK), "➐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(8n)★", "★", _GenMK), "➑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(9n)★", "★", _GenMK), "➒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(10n)★", "★", _GenMK), "➓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(0b)★", "★", _GenMK), "𝟎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(1b)★", "★", _GenMK), "𝟏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(2b)★", "★", _GenMK), "𝟐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(3b)★", "★", _GenMK), "𝟑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(4b)★", "★", _GenMK), "𝟒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(5b)★", "★", _GenMK), "𝟓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(6b)★", "★", _GenMK), "𝟔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(7b)★", "★", _GenMK), "𝟕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(8b)★", "★", _GenMK), "𝟖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(9b)★", "★", _GenMK), "𝟗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(0g)★", "★", _GenMK), "𝟬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(1g)★", "★", _GenMK), "𝟭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(2g)★", "★", _GenMK), "𝟮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(3g)★", "★", _GenMK), "𝟯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(4g)★", "★", _GenMK), "𝟰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(5g)★", "★", _GenMK), "𝟱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(6g)★", "★", _GenMK), "𝟲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(7g)★", "★", _GenMK), "𝟳", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(8g)★", "★", _GenMK), "𝟴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(9g)★", "★", _GenMK), "𝟵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(infini)★", "★", _GenMK), "∞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(product)★", "★", _GenMK), "∏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(produit)★", "★", _GenMK), "∏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(coproduct)★", "★", _GenMK), "∐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(coproduit)★", "★", _GenMK), "∐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(forall)★", "★", _GenMK), "∀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(for all)★", "★", _GenMK), "∀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(pour tout)★", "★", _GenMK), "∀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(exist)★", "★", _GenMK), "∃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(exists)★", "★", _GenMK), "∃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(vide)★", "★", _GenMK), "∅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(ensemble vide)★", "★", _GenMK), "∅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(void)★", "★", _GenMK), "∅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(empty)★", "★", _GenMK), "∅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(prop)★", "★", _GenMK), "∝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(proportionnel)★", "★", _GenMK), "∝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(proportionnal)★", "★", _GenMK), "∝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(union)★", "★", _GenMK), "∪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(intersection)★", "★", _GenMK), "⋂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(appartient)★", "★", _GenMK), "∈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(inclus)★", "★", _GenMK), "⊂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(non inclus)★", "★", _GenMK), "⊄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(non appartient)★", "★", _GenMK), "∉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(n’appartient pas)★", "★", _GenMK), "∉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(non)★", "★", _GenMK), "¬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(et)★", "★", _GenMK), "∧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(sqrt)★", "★", _GenMK), "√", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(racine)★", "★", _GenMK), "√", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(^)★", "★", _GenMK), "∧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(delta)★", "★", _GenMK), "∆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(nabla)★", "★", _GenMK), "∇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(<<)★", "★", _GenMK), "≪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(partial)★", "★", _GenMK), "∂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(end of proof)★", "★", _GenMK), "∎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(eop)★", "★", _GenMK), "∎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(int)★", "★", _GenMK), "∫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(s)★", "★", _GenMK), "∫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(so)★", "★", _GenMK), "∮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(sso)★", "★", _GenMK), "∯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(sss)★", "★", _GenMK), "∭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(ssso)★", "★", _GenMK), "∰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(=)★", "★", _GenMK), "≡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(equivalent)★", "★", _GenMK), "⇔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(équivalent)★", "★", _GenMK), "⇔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(implique)★", "★", _GenMK), "⇒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(impliqué)★", "★", _GenMK), "⇒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(imply)★", "★", _GenMK), "⇒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(non implique)★", "★", _GenMK), "⇏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(non impliqué)★", "★", _GenMK), "⇏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(non équivalent)★", "★", _GenMK), "⇎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(not equivalent)★", "★", _GenMK), "⇎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace(" -> ★", "★", _GenMK), " ➜ ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("-->★", "★", _GenMK), " ➜ ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace(">★", "★", _GenMK), "➢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("==>★", "★", _GenMK), "⇒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("=/=>★", "★", _GenMK), "⇏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("<==★", "★", _GenMK), "⇐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("<==>★", "★", _GenMK), "⇔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("<=/=>★", "★", _GenMK), "⇎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("<=>★", "★", _GenMK), "⇔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("^|★", "★", _GenMK), "↑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("|^★", "★", _GenMK), "↓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("->★", "★", _GenMK), "→", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("<-★", "★", _GenMK), "←", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("->>★", "★", _GenMK), "➡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("<<-★", "★", _GenMK), "⬅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("|->★", "★", _GenMK), "↪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("<-|★", "★", _GenMK), "↩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("^|-★", "★", _GenMK), "⭮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(v)★", "★", _GenMK), "✓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(x)★", "★", _GenMK), "✗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("[v]★", "★", _GenMK), "☑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("[x]★", "★", _GenMK), "☒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("/!\★", "★", _GenMK), "⚠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("**★", "★", _GenMK), "⁂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("°C★", "★", _GenMK), "℃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(b)★", "★", _GenMK), "•", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(c)★", "★", _GenMK), "©", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("eme★", "★", _GenMK), "ᵉ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ème★", "★", _GenMK), "ᵉ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ieme★", "★", _GenMK), "ᵉ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ième★", "★", _GenMK), "ᵉ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(o)★", "★", _GenMK), "•", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(r)★", "★", _GenMK), "®", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(tm)★", "★", _GenMK), "™", _GenOpts)
}

_GenLoad_magickey_textexpansionsymbolstypst(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$wj$", "{U+2060}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$zwj$", "{U+200D}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$zwnj$", "{U+200C}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$zws$", "{U+200B}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lrm$", "{U+200E}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rlm$", "{U+200F}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space$", "{U+0020}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.nobreak$", "{U+00A0}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.nobreak.narrow$", "{U+202F}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.en$", "{U+2002}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.quad$", "{U+2003}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.third$", "{U+2004}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.quarter$", "{U+2005}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.sixth$", "{U+2006}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.med$", "{U+205F}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.fig$", "{U+2007}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.punct$", "{U+2008}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.thin$", "{U+2009}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.hair$", "{U+200A}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.l$", "(", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.l.flat$", "⟮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.l.closed$", "⦇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.l.stroked$", "⦅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.l.double$", "⦅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.r$", ")", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.r.flat$", "⟯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.r.closed$", "⦈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.r.stroked$", "⦆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.r.double$", "⦆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.t$", "⏜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.b$", "⏝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$brace.l$", "{", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$brace.l.stroked$", "{U+27C3}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$brace.l.double$", "{U+27C3}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$brace.r$", "}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$brace.r.stroked$", "⦄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$brace.r.double$", "⦄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$brace.t$", "⏞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$brace.b$", "⏟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.l$", "[", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.l.tick.t$", "⦍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.l.tick.b$", "⦏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.l.stroked$", "⟦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.l.double$", "⟦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.r$", "]", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.r.tick.t$", "⦐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.r.tick.b$", "⦎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.r.stroked$", "⟧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.r.double$", "⟧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.t$", "⎴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.b$", "⎵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.l$", "❲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.l.stroked$", "⟬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.l.filled$", "⦗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.l.double$", "⟬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.r$", "❳", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.r.stroked$", "⟭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.r.filled$", "⦘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.r.double$", "⟭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.t$", "⏠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.b$", "⏡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bag.l$", "⟅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bag.r$", "⟆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$mustache.l$", "⎰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$mustache.r$", "⎱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bar.v$", "|", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bar.v.double$", "‖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bar.v.triple$", "⦀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bar.v.broken$", "¦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bar.v.o$", "⦶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bar.v.circle$", "⦶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bar.h$", "―", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$fence.l$", "⧘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$fence.l.double$", "⧚", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$fence.r$", "⧙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$fence.r.double$", "⧛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$fence.dotted$", "⦙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.l$", "⟨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.l.curly$", "⧼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.l.dot$", "⦑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.l.closed$", "⦉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.l.double$", "⟪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.r$", "⟩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.r.curly$", "⧽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.r.dot$", "⦒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.r.closed$", "⦊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.r.double$", "⟫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ceil.l$", "⌈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ceil.r$", "⌉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$floor.l$", "⌊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$floor.r$", "⌋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$corner.l.t$", "⌜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$corner.l.b$", "⌞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$corner.r.t$", "⌝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$corner.r.b$", "⌟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$amp$", "&", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$amp.inv$", "⅋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.op$", "∗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.op.o$", "⊛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.basic$", "*", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.low$", "⁎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.double$", "⁑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.triple$", "⁂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.small$", "﹡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.circle$", "⊛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.square$", "⧆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$at$", "@", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$backslash$", "\", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$backslash.o$", "⦸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$backslash.circle$", "⦸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$backslash.not$", "⧷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$co$", "℅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$colon$", ":", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$colon.currency$", "₡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$colon.double$", "∷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$colon.tri$", "⁝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$colon.tri.op$", "⫶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$colon.eq$", "≔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$colon.double.eq$", "⩴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$comma$", ",", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$comma.inv$", "⸲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$comma.rev$", "⹁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dagger$", "†", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dagger.double$", "‡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dagger.triple$", "⹋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dagger.l$", "⸶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dagger.r$", "⸷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dagger.inv$", "⸸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.en$", "–", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.em$", "—", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.em.two$", "⸺", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.em.three$", "⸻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.fig$", "‒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.wave$", "〜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.colon$", "∹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.o$", "⊝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.circle$", "⊝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.wave.double$", "〰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.op$", "⋅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.basic$", ".", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.c$", "·", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.o$", "⊙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.o.big$", "⨀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.circle$", "⊙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.circle.big$", "⨀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.square$", "⊡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.double$", "¨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.triple$", "{U+20DB}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.quad$", "{U+20DC}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$excl$", "!", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$excl.double$", "‼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$excl.inv$", "¡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$excl.quest$", "⁉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quest$", "?", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quest.double$", "⁇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quest.excl$", "⁈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quest.inv$", "¿", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$interrobang$", "‽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$interrobang.inv$", "⸘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hash$", "#", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hyph$", "‐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hyph.minus$", "-", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hyph.nobreak$", "{U+2011}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hyph.point$", "‧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hyph.soft$", "{U+00AD}", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$numero$", "№", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$percent$", "%", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$permille$", "‰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$permyriad$", "‱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$pilcrow$", "¶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$pilcrow.rev$", "⁋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$section$", "§", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$semi$", "`;", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$semi.inv$", "⸵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$semi.rev$", "⁏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$slash$", "/", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$slash.o$", "⊘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$slash.double$", "⫽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$slash.triple$", "⫻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$slash.big$", "⧸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dots.h.c$", "⋯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dots.h$", "…", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dots.v$", "⋮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dots.down$", "⋱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dots.up$", "⋰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.op$", "∼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.basic$", "~", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.dot$", "⩪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.eq$", "≃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.eq.not$", "≄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.eq.rev$", "⋍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.equiv$", "≅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.equiv.not$", "≇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.nequiv$", "≆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.not$", "≁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.rev$", "∽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.rev.equiv$", "≌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.triple$", "≋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$acute$", "´", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$acute.double$", "˝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$breve$", "˘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$caret$", "‸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$caron$", "ˇ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hat$", "^", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diaer$", "¨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$grave$", "``", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$macron$", "¯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.double$", "`"", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.single$", "'", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.l.double$", "“", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.l.single$", "‘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.r.double$", "”", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.r.single$", "’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.chevron.l.double$", "«", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.chevron.l.single$", "‹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.chevron.r.double$", "»", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.chevron.r.single$", "›", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.angle.l.double$", "«", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.angle.l.single$", "‹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.angle.r.double$", "»", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.angle.r.single$", "›", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.high.double$", "‟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.high.single$", "‛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.low.double$", "„", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.low.single$", "‚", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prime$", "′", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prime.rev$", "‵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prime.double$", "″", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prime.double.rev$", "‶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prime.triple$", "‴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prime.triple.rev$", "‷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prime.quad$", "⁗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus$", "+", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.o$", "⊕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.o.l$", "⨭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.o.r$", "⨮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.o.arrow$", "⟴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.o.big$", "⨁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.circle$", "⊕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.circle.arrow$", "⟴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.circle.big$", "⨁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.dot$", "∔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.double$", "⧺", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.minus$", "±", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.small$", "﹢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.square$", "⊞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.triangle$", "⨹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.triple$", "⧻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$minus$", "−", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$minus.o$", "⊖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$minus.circle$", "⊖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$minus.dot$", "∸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$minus.plus$", "∓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$minus.square$", "⊟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$minus.tilde$", "≂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$minus.triangle$", "⨺", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$div$", "÷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$div.o$", "⨸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$div.slanted.o$", "⦼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$div.circle$", "⨸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times$", "×", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.big$", "⨉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.o$", "⊗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.o.l$", "⨴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.o.r$", "⨵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.o.hat$", "⨶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.o.big$", "⨂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.circle$", "⊗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.circle.big$", "⨂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.div$", "⋇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.three.l$", "⋋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.three.r$", "⋌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.l$", "⋉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.r$", "⋊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.square$", "⊠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.triangle$", "⨻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ratio$", "∶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq$", "=", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.star$", "≛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.o$", "⊜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.circle$", "⊜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.colon$", "≕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.dots$", "≑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.dots.down$", "≒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.dots.up$", "≓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.def$", "≝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.delta$", "≜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.equi$", "≚", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.est$", "≙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.gt$", "⋝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.lt$", "⋜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.m$", "≞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.not$", "≠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.prec$", "⋞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.quest$", "≟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.small$", "﹦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.succ$", "⋟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.triple$", "≡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.triple.not$", "≢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.quad$", "≣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt$", ">", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.o$", "⧁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.circle$", "⧁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.dot$", "⋗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.approx$", "⪆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.double$", "≫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.eq$", "≥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.eq.slant$", "⩾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.eq.lt$", "⋛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.eq.not$", "≱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.equiv$", "≧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.lt$", "≷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.lt.not$", "≹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.neq$", "⪈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.napprox$", "⪊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.nequiv$", "≩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.not$", "≯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.ntilde$", "⋧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.small$", "﹥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.tilde$", "≳", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.tilde.not$", "≵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.tri$", "⊳", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.tri.eq$", "⊵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.tri.eq.not$", "⋭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.tri.not$", "⋫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.triple$", "⋙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.triple.nested$", "⫸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt$", "<", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.o$", "⧀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.circle$", "⧀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.dot$", "⋖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.approx$", "⪅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.double$", "≪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.eq$", "≤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.eq.slant$", "⩽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.eq.gt$", "⋚", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.eq.not$", "≰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.equiv$", "≦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.gt$", "≶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.gt.not$", "≸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.neq$", "⪇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.napprox$", "⪉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.nequiv$", "≨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.not$", "≮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.ntilde$", "⋦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.small$", "﹤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.tilde$", "≲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.tilde.not$", "≴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.tri$", "⊲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.tri.eq$", "⊴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.tri.eq.not$", "⋬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.tri.not$", "⋪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.triple$", "⋘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.triple.nested$", "⫷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$approx$", "≈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$approx.eq$", "≊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$approx.not$", "≉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec$", "≺", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.approx$", "⪷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.curly.eq$", "≼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.curly.eq.not$", "⋠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.double$", "⪻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.eq$", "⪯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.equiv$", "⪳", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.napprox$", "⪹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.neq$", "⪱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.nequiv$", "⪵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.not$", "⊀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.ntilde$", "⋨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.tilde$", "≾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ$", "≻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.approx$", "⪸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.curly.eq$", "≽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.curly.eq.not$", "⋡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.double$", "⪼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.eq$", "⪰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.equiv$", "⪴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.napprox$", "⪺", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.neq$", "⪲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.nequiv$", "⪶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.not$", "⊁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.ntilde$", "⋩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.tilde$", "≿", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$equiv$", "≡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$equiv.not$", "≢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$smt$", "⪪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$smt.eq$", "⪬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lat$", "⪫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lat.eq$", "⪭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prop$", "∝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$original$", "⊶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$image$", "⊷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$asymp$", "≍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$asymp.not$", "≭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$emptyset$", "∅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$emptyset.arrow.r$", "⦳", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$emptyset.arrow.l$", "⦴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$emptyset.bar$", "⦱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$emptyset.circle$", "⦲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$emptyset.rev$", "⦰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$nothing$", "∅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$nothing.arrow.r$", "⦳", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$nothing.arrow.l$", "⦴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$nothing.bar$", "⦱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$nothing.circle$", "⦲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$nothing.rev$", "⦰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$without$", "∖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$complement$", "∁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$in$", "∈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$in.not$", "∉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$in.rev$", "∋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$in.rev.not$", "∌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$in.rev.small$", "∍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$in.small$", "∊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset$", "⊂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.dot$", "⪽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.double$", "⋐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.eq$", "⊆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.eq.not$", "⊈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.eq.sq$", "⊑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.eq.sq.not$", "⋢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.neq$", "⊊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.not$", "⊄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.sq$", "⊏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.sq.neq$", "⋤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset$", "⊃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.dot$", "⪾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.double$", "⋑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.eq$", "⊇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.eq.not$", "⊉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.eq.sq$", "⊒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.eq.sq.not$", "⋣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.neq$", "⊋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.not$", "⊅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.sq$", "⊐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.sq.neq$", "⋥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union$", "∪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.arrow$", "⊌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.big$", "⋃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.dot$", "⊍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.dot.big$", "⨃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.double$", "⋓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.minus$", "⩁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.or$", "⩅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.plus$", "⊎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.plus.big$", "⨄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.sq$", "⊔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.sq.big$", "⨆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.sq.double$", "⩏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$inter$", "∩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$inter.and$", "⩄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$inter.big$", "⋂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$inter.dot$", "⩀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$inter.double$", "⋒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$inter.sq$", "⊓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$inter.sq.big$", "⨅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$inter.sq.double$", "⩎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sect$", "∩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sect.and$", "⩄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sect.big$", "⋂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sect.dot$", "⩀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sect.double$", "⋒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sect.sq$", "⊓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sect.sq.big$", "⨅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sect.sq.double$", "⩎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$infinity$", "∞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$infinity.bar$", "⧞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$infinity.incomplete$", "⧜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$infinity.tie$", "⧝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$oo$", "∞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diff$", "∂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$partial$", "∂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gradient$", "∇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$nabla$", "∇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sum$", "∑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sum.integral$", "⨋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$product$", "∏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$product.co$", "∐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral$", "∫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.arrow.hook$", "⨗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.ccw$", "⨑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.cont$", "∮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.cont.ccw$", "∳", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.cont.cw$", "∲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.cw$", "∱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.dash$", "⨍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.dash.double$", "⨎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.double$", "∬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.quad$", "⨌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.inter$", "⨙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.sect$", "⨙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.slash$", "⨏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.square$", "⨖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.surf$", "∯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.times$", "⨘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.triple$", "∭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.union$", "⨚", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.vol$", "∰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$laplace$", "∆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$forall$", "∀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$exists$", "∃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$exists.not$", "∄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$top$", "⊤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bot$", "⊥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$not$", "¬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$and$", "∧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$and.big$", "⋀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$and.curly$", "⋏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$and.dot$", "⟑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$and.double$", "⩓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$or$", "∨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$or.big$", "⋁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$or.curly$", "⋎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$or.dot$", "⟇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$or.double$", "⩔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$xor$", "⊕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$xor.big$", "⨁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$models$", "⊧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$forces$", "⊩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$forces.not$", "⊮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$therefore$", "∴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$because$", "∵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$qed$", "∎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$mapsto$", "↦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$mapsto.long$", "⟼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$compose$", "∘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$compose.o$", "⊚", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$convolve$", "∗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$convolve.o$", "⊛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$multimap$", "⊸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$multimap.double$", "⧟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tiny$", "⧾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$miny$", "⧿", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$divides$", "∣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$divides.not$", "∤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$divides.not.rev$", "⫮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$divides.struck$", "⟊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$wreath$", "≀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle$", "∠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.l$", "⟨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.l.curly$", "⧼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.l.dot$", "⦑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.l.double$", "⟪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.r$", "⟩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.r.curly$", "⧽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.r.dot$", "⦒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.r.double$", "⟫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.acute$", "⦟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.arc$", "∡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.arc.rev$", "⦛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.azimuth$", "⍼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.oblique$", "⦦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.rev$", "⦣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.right$", "∟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.right.rev$", "⯾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.right.arc$", "⊾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.right.dot$", "⦝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.right.sq$", "⦜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.s$", "⦞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.spatial$", "⟀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.spheric$", "∢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.spheric.rev$", "⦠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.spheric.t$", "⦡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.spheric.top$", "⦡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angzarr$", "⍼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel$", "∥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.struck$", "⫲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.o$", "⦷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.circle$", "⦷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.eq$", "⋕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.equiv$", "⩨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.not$", "∦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.slanted.eq$", "⧣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.slanted.eq.tilde$", "⧤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.slanted.equiv$", "⧥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.tilde$", "⫳", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$perp$", "⟂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$perp.o$", "⦹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$perp.circle$", "⦹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$earth$", "🜨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$earth.alt$", "♁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$jupiter$", "♃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$mars$", "♂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$mercury$", "☿", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$neptune$", "♆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$neptune.alt$", "⯉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$saturn$", "♄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sun$", "☉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$uranus$", "⛢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$uranus.alt$", "♅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$venus$", "♀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diameter$", "⌀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$interleave$", "⫴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$interleave.big$", "⫼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$interleave.struck$", "⫵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$join$", "⨝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$join.r$", "⟖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$join.l$", "⟕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$join.l.r$", "⟗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hourglass.stroked$", "⧖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hourglass.filled$", "⧗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$degree$", "°", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$smash$", "⨳", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$power.standby$", "⏻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$power.on$", "⏽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$power.off$", "⭘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$power.on.off$", "⏼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$power.sleep$", "⏾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$smile$", "⌣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$frown$", "⌢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$afghani$", "؋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$baht$", "฿", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bitcoin$", "₿", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cedi$", "₵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cent$", "¢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$currency$", "¤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dollar$", "$", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dong$", "₫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dorome$", "߾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dram$", "֏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$euro$", "€", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$franc$", "₣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$guarani$", "₲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hryvnia$", "₴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$kip$", "₭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lari$", "₾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lira$", "₺", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$manat$", "₼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$naira$", "₦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$pataca$", "$", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$peso$", "$", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$peso.philippine$", "₱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$pound$", "£", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$riel$", "៛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ruble$", "₽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rupee.indian$", "₹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rupee.generic$", "₨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rupee.tamil$", "௹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rupee.wancho$", "𞋿", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shekel$", "₪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$som$", "⃀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$taka$", "৳", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$taman$", "߿", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tenge$", "₸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$togrog$", "₮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$won$", "₩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$yen$", "¥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$yuan$", "¥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ballot$", "☐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ballot.cross$", "☒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ballot.check$", "☑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ballot.check.heavy$", "🗹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$checkmark$", "✓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$checkmark.light$", "🗸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$checkmark.heavy$", "✔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$crossmark$", "✗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$crossmark.heavy$", "✘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$floral$", "❦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$floral.l$", "☙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$floral.r$", "❧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$refmark$", "※", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cc$", "🅭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cc.by$", "🅯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cc.nc$", "🄏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cc.nd$", "⊜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cc.public$", "🅮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cc.sa$", "🄎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cc.zero$", "🄍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$copyright$", "©", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$copyright.sound$", "℗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$copyleft$", "🄯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$trademark$", "™", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$trademark.registered$", "®", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$trademark.service$", "℠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$maltese$", "✠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$suit.club.filled$", "♣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$suit.club.stroked$", "♧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$suit.diamond.filled$", "♦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$suit.diamond.stroked$", "♢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$suit.heart.filled$", "♥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$suit.heart.stroked$", "♡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$suit.spade.filled$", "♠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$suit.spade.stroked$", "♤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.up$", "🎜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.down$", "🎝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.whole$", "𝅝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.half$", "𝅗𝅥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.quarter$", "𝅘𝅥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.quarter.alt$", "♩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.eighth$", "𝅘𝅥𝅮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.eighth.alt$", "♪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.eighth.beamed$", "♫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.sixteenth$", "𝅘𝅥𝅯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.sixteenth.beamed$", "♬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.grace$", "𝆕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.grace.slash$", "𝆔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rest.whole$", "𝄻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rest.multiple$", "𝄺", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rest.multiple.measure$", "𝄩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rest.half$", "𝄼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rest.quarter$", "𝄽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rest.eighth$", "𝄾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rest.sixteenth$", "𝄿", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$natural$", "♮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$natural.t$", "𝄮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$natural.b$", "𝄯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$flat$", "♭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$flat.t$", "𝄬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$flat.b$", "𝄭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$flat.double$", "𝄫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$flat.quarter$", "𝄳", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sharp$", "♯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sharp.t$", "𝄰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sharp.b$", "𝄱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sharp.double$", "𝄪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sharp.quarter$", "𝄲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet$", "•", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.op$", "∙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.o$", "⦿", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.stroked$", "◦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.stroked.o$", "⦾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.hole$", "◘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.hyph$", "⁃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.tri$", "‣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.l$", "⁌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.r$", "⁍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.stroked$", "○", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.stroked.tiny$", "∘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.stroked.small$", "⚬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.stroked.big$", "◯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.filled$", "●", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.filled.tiny$", "⦁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.filled.small$", "∙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.filled.big$", "⬤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.dotted$", "◌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.nested$", "⊚", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ellipse.stroked.h$", "⬭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ellipse.stroked.v$", "⬯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ellipse.filled.h$", "⬬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ellipse.filled.v$", "⬮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.t$", "△", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.b$", "▽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.r$", "▷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.l$", "◁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.bl$", "◺", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.br$", "◿", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.tl$", "◸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.tr$", "◹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.small.t$", "▵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.small.b$", "▿", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.small.r$", "▹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.small.l$", "◃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.rounded$", "🛆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.nested$", "⟁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.dot$", "◬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.t$", "▲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.b$", "▼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.r$", "▶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.l$", "◀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.bl$", "◣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.br$", "◢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.tl$", "◤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.tr$", "◥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.small.t$", "▴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.small.b$", "▾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.small.r$", "▸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.small.l$", "◂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.stroked$", "□", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.stroked.tiny$", "▫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.stroked.small$", "◽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.stroked.medium$", "◻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.stroked.big$", "⬜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.stroked.dotted$", "⬚", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.stroked.rounded$", "▢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.filled$", "■", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.filled.tiny$", "▪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.filled.small$", "◾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.filled.medium$", "◼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.filled.big$", "⬛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rect.stroked.h$", "▭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rect.stroked.v$", "▯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rect.filled.h$", "▬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rect.filled.v$", "▮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$penta.stroked$", "⬠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$penta.filled$", "⬟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hexa.stroked$", "⬡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hexa.filled$", "⬢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diamond.stroked$", "◇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diamond.stroked.small$", "⋄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diamond.stroked.medium$", "⬦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diamond.stroked.dot$", "⟐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diamond.filled$", "◆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diamond.filled.medium$", "⬥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diamond.filled.small$", "⬩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lozenge.stroked$", "◊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lozenge.stroked.small$", "⬫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lozenge.stroked.medium$", "⬨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lozenge.filled$", "⧫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lozenge.filled.small$", "⬪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lozenge.filled.medium$", "⬧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallelogram.stroked$", "▱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallelogram.filled$", "▰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$star.op$", "⋆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$star.stroked$", "☆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$star.filled$", "★", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r$", "→", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.long.bar$", "⟼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.bar$", "↦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.curve$", "⤷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.turn$", "⮎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.dashed$", "⇢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.dotted$", "⤑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.double$", "⇒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.double.bar$", "⤇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.double.long$", "⟹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.double.long.bar$", "⟾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.double.not$", "⇏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.double.struck$", "⤃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.filled$", "➡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.hook$", "↪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.long$", "⟶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.long.squiggly$", "⟿", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.loop$", "↬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.not$", "↛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.quad$", "⭆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.squiggly$", "⇝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.stop$", "⇥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.stroked$", "⇨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.struck$", "⇸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.dstruck$", "⇻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.tail$", "↣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.tail.struck$", "⤔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.tail.dstruck$", "⤕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.tilde$", "⥲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.triple$", "⇛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.twohead$", "↠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.twohead.bar$", "⤅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.twohead.struck$", "⤀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.twohead.dstruck$", "⤁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.twohead.tail$", "⤖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.twohead.tail.struck$", "⤗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.twohead.tail.dstruck$", "⤘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.open$", "⇾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.wave$", "↝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l$", "←", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.bar$", "↤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.curve$", "⤶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.turn$", "⮌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.dashed$", "⇠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.dotted$", "⬸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.double$", "⇐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.double.bar$", "⤆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.double.long$", "⟸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.double.long.bar$", "⟽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.double.not$", "⇍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.double.struck$", "⤂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.filled$", "⬅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.hook$", "↩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.long$", "⟵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.long.bar$", "⟻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.long.squiggly$", "⬳", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.loop$", "↫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.not$", "↚", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.quad$", "⭅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.squiggly$", "⇜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.stop$", "⇤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.stroked$", "⇦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.struck$", "⇷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.dstruck$", "⇺", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.tail$", "↢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.tail.struck$", "⬹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.tail.dstruck$", "⬺", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.tilde$", "⭉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.triple$", "⇚", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.twohead$", "↞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.twohead.bar$", "⬶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.twohead.struck$", "⬴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.twohead.dstruck$", "⬵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.twohead.tail$", "⬻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.twohead.tail.struck$", "⬼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.twohead.tail.dstruck$", "⬽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.open$", "⇽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.wave$", "↜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t$", "↑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.bar$", "↥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.curve$", "⤴", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.turn$", "⮍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.dashed$", "⇡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.double$", "⇑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.filled$", "⬆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.quad$", "⟰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.stop$", "⤒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.stroked$", "⇧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.struck$", "⤉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.dstruck$", "⇞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.triple$", "⤊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.twohead$", "↟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b$", "↓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.bar$", "↧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.curve$", "⤵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.turn$", "⮏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.dashed$", "⇣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.double$", "⇓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.filled$", "⬇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.quad$", "⟱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.stop$", "⤓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.stroked$", "⇩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.struck$", "⤈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.dstruck$", "⇟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.triple$", "⤋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.twohead$", "↡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r$", "↔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.double$", "⇔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.double.long$", "⟺", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.double.not$", "⇎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.double.struck$", "⤄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.filled$", "⬌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.long$", "⟷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.not$", "↮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.stroked$", "⬄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.struck$", "⇹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.dstruck$", "⇼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.open$", "⇿", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.wave$", "↭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.b$", "↕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.b.double$", "⇕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.b.filled$", "⬍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.b.stroked$", "⇳", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tr$", "↗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tr.double$", "⇗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tr.filled$", "⬈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tr.hook$", "⤤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tr.stroked$", "⬀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.br$", "↘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.br.double$", "⇘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.br.filled$", "⬊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.br.hook$", "⤥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.br.stroked$", "⬂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tl$", "↖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tl.double$", "⇖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tl.filled$", "⬉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tl.hook$", "⤣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tl.stroked$", "⬁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.bl$", "↙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.bl.double$", "⇙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.bl.filled$", "⬋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.bl.hook$", "⤦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.bl.stroked$", "⬃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tl.br$", "⤡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tr.bl$", "⥢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.ccw$", "↺", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.ccw.half$", "↶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.cw$", "↻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.cw.half$", "↷", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.zigzag$", "↯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.rr$", "⇉", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.ll$", "⇇", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.tt$", "⇈", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.bb$", "⇊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.lr$", "⇆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.lr.stop$", "↹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.rl$", "⇄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.tb$", "⇅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.bt$", "⇵", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.rrr$", "⇶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.lll$", "⬱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrowhead.t$", "⌃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrowhead.b$", "⌄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.rt$", "⇀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.rt.bar$", "⥛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.rt.stop$", "⥓", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.rb$", "⇁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.rb.bar$", "⥟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.rb.stop$", "⥗", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lt$", "↼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lt.bar$", "⥚", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lt.stop$", "⥒", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lb$", "↽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lb.bar$", "⥞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lb.stop$", "⥖", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tl$", "↿", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tl.bar$", "⥠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tl.stop$", "⥘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tr$", "↾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tr.bar$", "⥜", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tr.stop$", "⥔", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.bl$", "⇃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.bl.bar$", "⥡", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.bl.stop$", "⥙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.br$", "⇂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.br.bar$", "⥝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.br.stop$", "⥕", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lt.rt$", "⥎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lb.rb$", "⥐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lb.rt$", "⥋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lt.rb$", "⥊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tl.bl$", "⥑", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tr.br$", "⥏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tl.br$", "⥍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tr.bl$", "⥌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.rtrb$", "⥤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.blbr$", "⥥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.bltr$", "⥯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.lbrb$", "⥧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.ltlb$", "⥢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.ltrb$", "⇋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.ltrt$", "⥦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.rblb$", "⥩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.rtlb$", "⇌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.rtlt$", "⥨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.tlbr$", "⥮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.tltr$", "⥣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.r$", "⊢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.r.not$", "⊬", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.r.long$", "⟝", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.r.short$", "⊦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.r.double$", "⊨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.r.double.not$", "⊭", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.l$", "⊣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.l.long$", "⟞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.l.short$", "⫞", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.l.double$", "⫤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.t$", "⊥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.t.big$", "⟘", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.t.double$", "⫫", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.t.short$", "⫠", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.b$", "⊤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.b.big$", "⟙", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.b.double$", "⫪", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.b.short$", "⫟", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.l.r$", "⟛", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$alpha$", "α", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$beta$", "β", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$beta.alt$", "ϐ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chi$", "χ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$delta$", "δ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$digamma$", "ϝ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$epsilon$", "ε", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$epsilon.alt$", "ϵ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$epsilon.alt.rev$", "϶", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eta$", "η", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gamma$", "γ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$iota$", "ι", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$iota.inv$", "℩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$kai$", "ϗ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$kappa$", "κ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$kappa.alt$", "ϰ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lambda$", "λ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$mu$", "μ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$nu$", "ν", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$omega$", "ω", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$omicron$", "ο", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$phi$", "φ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$phi.alt$", "ϕ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$pi$", "π", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$pi.alt$", "ϖ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$psi$", "ψ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rho$", "ρ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rho.alt$", "ϱ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sigma$", "σ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sigma.alt$", "ς", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tau$", "τ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$theta$", "θ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$theta.alt$", "ϑ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$upsilon$", "υ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$xi$", "ξ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$zeta$", "ζ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Alpha$", "Α", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Beta$", "Β", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Chi$", "Χ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Delta$", "Δ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Digamma$", "Ϝ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Epsilon$", "Ε", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Eta$", "Η", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Gamma$", "Γ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Iota$", "Ι", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Kai$", "Ϗ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Kappa$", "Κ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Lambda$", "Λ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Mu$", "Μ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Nu$", "Ν", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Omega$", "Ω", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Omega.inv$", "℧", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Omicron$", "Ο", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Phi$", "Φ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Pi$", "Π", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Psi$", "Ψ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Rho$", "Ρ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Sigma$", "Σ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Tau$", "Τ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Theta$", "Θ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Theta.alt$", "ϴ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Upsilon$", "Υ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Xi$", "Ξ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Zeta$", "Ζ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sha$", "ш", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Sha$", "Ш", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$aleph$", "א", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$alef$", "א", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$beth$", "ב", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bet$", "ב", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gimel$", "ג", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gimmel$", "ג", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$daleth$", "ד", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dalet$", "ד", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shin$", "ש", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$AA$", "𝔸", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$BB$", "𝔹", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$CC$", "ℂ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$DD$", "𝔻", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$EE$", "𝔼", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$FF$", "𝔽", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$GG$", "𝔾", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$HH$", "ℍ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$II$", "𝕀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$JJ$", "𝕁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$KK$", "𝕂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$LL$", "𝕃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$MM$", "𝕄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$NN$", "ℕ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$OO$", "𝕆", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$PP$", "ℙ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$QQ$", "ℚ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$RR$", "ℝ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$SS$", "𝕊", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$TT$", "𝕋", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$UU$", "𝕌", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$VV$", "𝕍", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$WW$", "𝕎", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$XX$", "𝕏", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$YY$", "𝕐", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ZZ$", "ℤ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angstrom$", "Å", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ell$", "ℓ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$planck$", "ħ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$planck.reduce$", "ħ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Re$", "ℜ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Im$", "ℑ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dotless.i$", "ı", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dotless.j$", "ȷ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$die.six$", "⚅", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$die.five$", "⚄", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$die.four$", "⚃", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$die.three$", "⚂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$die.two$", "⚁", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$die.one$", "⚀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$errorbar.square.stroked$", "⧮", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$errorbar.square.filled$", "⧯", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$errorbar.diamond.stroked$", "⧰", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$errorbar.diamond.filled$", "⧱", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$errorbar.circle.stroked$", "⧲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$errorbar.circle.filled$", "⧳", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.female$", "♀", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.female.double$", "⚢", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.female.male$", "⚤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.intersex$", "⚥", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.male$", "♂", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.male.double$", "⚣", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.male.female$", "⚤", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.male.stroke$", "⚦", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.male.stroke.t$", "⚨", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.male.stroke.r$", "⚩", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.neuter$", "⚲", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.trans$", "⚧", _GenOpts)
}

