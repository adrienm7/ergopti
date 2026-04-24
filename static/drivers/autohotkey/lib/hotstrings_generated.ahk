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
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "qa", "qua", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "qà", "quà", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "qe", "que", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "qé", "qué", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "qè", "què", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "qê", "quê", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "qi", "qui", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "qo", "quo", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "q'", "qu’", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "q’", "qu’", Opts)
}

_GenLoad_distancesreduction_suffixesa(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àa", "aire", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àc", "ction", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "càd", "could", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "shàd", "should", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àd", "would", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àê", "able", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àf", "iste", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àg", "ought", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àh", "ight", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ài", "ying", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àk", "ique", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àl", "elle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àp", "ence", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àm", "isme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àn", "ation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àq", "ique", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àr", "erre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "às", "ement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àt", "ettre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àv", "ment", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àx", "ieux", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àz", "ez-vous", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "à'", "ance", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "à’", "ance", Opts)
}

_GenLoad_distancesreduction_commaj(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",à", "j", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",a", "ja", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",e", "je", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",é", "jé", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",i", "ji", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",o", "jo", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",u", "ju", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",ê", "ju", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",'", "j’", Opts)
}

_GenLoad_distancesreduction_commafarletters(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",è", "z", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",y", "k", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",c", "ç", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",x", "où ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",s", "q", Opts)
}

_GenLoad_distancesreduction_deadkeyecircumflex(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê ", "^", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê^", "^", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê¨", "/", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê_", "\", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê'", "⚠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê,", "➜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê.", "•", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê/", "⁄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê0", "🄋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê1", "➀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê2", "➁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê3", "➂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê4", "➃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê5", "➄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê6", "➅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê7", "➆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê8", "➇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê9", "➈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê:", "▶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ê`;", "↪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êa", "â", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êA", "Â", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êb", "ó", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êB", "Ó", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êc", "ç", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êC", "Ç", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êd", "★", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êD", "☆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êf", "⚐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êF", "⚑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êg", "ĝ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êG", "Ĝ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êh", "ĥ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êH", "Ĥ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êi", "î", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êI", "Î", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êj", "j", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êJ", "J", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êk", "☺", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êK", "☻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êl", "†", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êL", "‡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êm", "✅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êM", "☑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ên", "ñ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êN", "Ñ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êo", "ô", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êO", "Ô", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êp", "¶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êP", "⁂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êq", "☒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êQ", "☐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êr", "º", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êR", "°", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "ês", "ß", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êS", "ẞ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êu", "û", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êU", "Û", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êv", "✓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êV", "✔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êw", "ù ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êW", "Ù", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êx", "✕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êX", "✖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êy", "ŷ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êY", "Ŷ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êz", "ẑ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "êZ", "Ẑ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êà", "æ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êÀ", "Æ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êè", "í", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êÈ", "Í", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êé", "œ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êÉ", "Œ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êê", "á", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "êÊ", "Á", Opts)
}

_GenLoad_distancesreduction_ecircumflexe(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "êe", "œ", Opts)
}

_GenLoad_sfbsreduction_comma(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",f", "fl", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",g", "gl", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",h", "ph", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",z", "bj", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",v", "dv", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",n", "nl", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",t", "pt", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",r", "rq", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",q", "qu’", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",m", "ms", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",d", "ds", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",l", "cl", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",p", "xp", Opts)
}

_GenLoad_sfbsreduction_ecirc(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "êé", "oe", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "éê", "eo", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ê.", "u.", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ê,", "u,", Opts)
}

_GenLoad_sfbsreduction_egrave(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "yè", "â", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "èy", "aî", Opts)
}

_GenLoad_sfbsreduction_bu(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("il a mà★", "★", _GenMK), "il a mis à jour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("la mà★", "★", _GenMK), "la mise à jour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ta mà★", "★", _GenMK), "ta mise à jour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ma mà★", "★", _GenMK), "ma mise à jour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("e mà★", "★", _GenMK), "e mise à jour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("es mà★", "★", _GenMK), "es mises à jour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mà★", "★", _GenMK), "mettre à jour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mià★", "★", _GenMK), "mise à jour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pià★", "★", _GenMK), "pièce jointe", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tà★", "★", _GenMK), "toujours", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("à★", "★", _GenMK), "bu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àu", "ub", Opts)
}

_GenLoad_sfbsreduction_ie(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("ié★", "★", _GenMK), "ébu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àé", "éi", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "éà", "ié", Opts)
}

_GenLoad_rolls_hc(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "hc", "wh", Opts)
}

_GenLoad_rolls_sx(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "xlsx", "xlsx", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "sx", "sk", Opts)
}

_GenLoad_rolls_cx(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "cx", "ck", Opts)
}

_GenLoad_rolls_englishnegation(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "nt'", "n’t", Opts)
}

_GenLoad_rolls_ez(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eé", "ez", Opts)
}

_GenLoad_rolls_ct(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?C", "p ?", "p ?", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "p'", "ct", Opts)
}

_GenLoad_rolls_closechevrontag(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "<@", "</", Opts)
}

_GenLoad_rolls_chevronequal(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "<%", "<=", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", ">%", ">=", Opts)
}

_GenLoad_rolls_comment(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "\`"", "/*", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "`"\", "*/", Opts)
}

_GenLoad_rolls_assign(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " #ç", " := ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " #!", " := ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#ç", " := ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#!", " := ", Opts)
}

_GenLoad_rolls_notequal(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " ç#", " != ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " !#", " != ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "ç#", " != ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "!#", " != ", Opts)
}

_GenLoad_rolls_hashtagquote(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "(#", "(`"", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "[#", "[`"", Opts)
}

_GenLoad_rolls_hashtagparenthesis(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#(", "`")", Opts)
}

_GenLoad_rolls_hashtagbracket(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#[", "`"]", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#]", "`"]", Opts)
}

_GenLoad_rolls_equalstring(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " [)", " = `"`"", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "[)", " = `"`"", Opts)
}

_GenLoad_rolls_leftarrow(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " =+", " ➜ ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "=+", " ➜ ", Opts)
}

_GenLoad_rolls_assignarrowequalright(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " $=", " => ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "$=", " => ", Opts)
}

_GenLoad_rolls_assignarrowequalleft(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " =$", " <= ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "=$", " <= ", Opts)
}

_GenLoad_rolls_assignarrowminusright(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " +?", " -> ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "+?", " -> ", Opts)
}

_GenLoad_rolls_assignarrowminusleft(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " ?+", " <- ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "?+", " <- ", Opts)
}

_GenLoad_autocorrection_accents(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "abim", "abîm", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "accroit", "accroît", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "affut", "affût", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "agé", "âgé", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "agée", "âgée", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "agés", "âgés", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "agées", "âgées", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aieul", "aïeul", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aieux", "aïeux", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aigue", "aiguë", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aikido", "aïkido", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ainé", "aîné", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ambigue", "ambiguë", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ambigui", "ambiguï", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ame", "âme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ames", "âmes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ane", "âne", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "anerie", "ânerie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "anes", "ânes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "angstrom", "ångström", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "apotre", "apôtre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "appat", "appât", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "apprete", "apprête", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "appreter", "apprêter", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "apre", "âpre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "apres", "âpres", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "archaique", "archaïque", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "archaisme", "archaïsme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "archeveque", "archevêque", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "archeveques", "archevêques", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "arete", "arête", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "aretes", "arêtes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "arome", "arôme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "arret", "arrêt", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aout", "août", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aumone", "aumône", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aumonier", "aumônier", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aussitot", "aussitôt", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "avant-gout", "avant-goût", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "babord", "bâbord", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "baille", "bâille", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "bacler", "bâcler", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "baclé", "bâclé", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "baillon", "bâillon", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "baionnette", "baïonnette", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "batard", "bâtard", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "bati", "bâti", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "baton", "bâton", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "beche", "bêche", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "beches", "bêches", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "benet", "benêt", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "benets", "benêts", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "benoite", "benoîte", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "bete", "bête", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "betis", "bêtis", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "bientot", "bientôt", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "binome", "binôme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "blamer", "blâmer", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "bleme", "blême", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "blemes", "blêmes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "blemir", "blêmir", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "blémir", "blêmir", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "boeuf", "bœuf", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "boite", "boîte", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "brul", "brûl", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "buche", "bûche", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cabler", "câbler", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "calin", "câlin", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "canoe", "canoë", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "prochaine", "prochaine", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "chaine", "chaîne", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "chaîned", "chained", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "chainé", "chaîné", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chassis", "châssis", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chatain", "châtain", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chataigne", "châtaigne", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chateau", "château", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chatier", "châtier", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chatiment", "châtiment", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chomage", "chômage", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "chomer", "chômer", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chomeu", "chômeu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chomé", "chômé", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cloitre", "cloître", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cloture", "clôture", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cloturé", "clôturé", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cocaine", "cocaïne", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cocaino", "cocaïno", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "coeur", "cœur", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "coincide", "coïncide", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "connait", "connaît", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "controla", "contrôla", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "controle", "contrôle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "controlé", "contrôlé", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "controlo", "contrôlo", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "cout", "coût", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "coute", "coûte", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "couter", "coûter", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "coutera", "coûtera", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "couterez", "coûterez", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "couteu", "coûteu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "couts", "coûts", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "cote", "côte", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "cotes", "côtes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cotoie", "côtoie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cotoy", "côtoy", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "craner", "crâner", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cranien", "crânien", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "croitre", "croître", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "crouton", "croûton", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "crument", "crûment", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "débacle", "débâcle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "dégat", "dégât", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "dégout", "dégoût", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "dépech", "dépêch", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "dépot", "dépôt", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "dépots", "dépôts", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "diplome", "diplôme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "diplomé", "diplômé", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "drole", "drôle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "dument", "dûment", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "écoeuré", "écoeuré", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "écoeure", "écoeure", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "egoisme", "égoïsme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "égoisme", "égoïsme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "egoiste", "égoïste", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "égoiste", "égoïste", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "elle-meme", "elle-même", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "elles-meme", "elles-mêmes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "elles-memes", "elles-mêmes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "embet", "embêt", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "embuch", "embûch", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "empeche", "empêche", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "enchaine", "enchaîne", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "enjoleu", "enjôleu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "enrole", "enrôle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "entete", "entête", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "enteté", "entêté", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "entraina", "entraîna", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "entraine", "entraîne", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "entrainé", "entraîné", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "entrepot", "entrepôt", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "envout", "envoût", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "eux-meme", "eux-mêmes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "fache", "fâche", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "faché", "fâché", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "famé", "fâmé", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "fantom", "fantôm", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "fenetre", "fenêtre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "felure", "fêlure", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "félure", "fêlure", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "fete", "fête", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "feter", "fêter", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "fetes", "fêtes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flane", "flâne", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flaner", "flâner", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flanes", "flânes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "flaneu", "flâneu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flanez", "flânez", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flanons", "flânons", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flute", "flûte", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flutes", "flûtes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "foetus", "fœtus", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "foret", "forêt", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "fraich", "fraîch", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "frole", "frôle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "gach", "gâch", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "gateau", "gâteau", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gater", "gâter", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gaté", "gâté", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gatés", "gâtés", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "genant", "gênant", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gener", "gêner", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "génant", "gênant", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "génants", "gênants", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "geole", "geôle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "geolier", "geôlier", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "geoliè", "geôliè", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gout", "goût", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gouta", "goûta", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "goute", "goûte", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "gouter", "goûter", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "gouteux", "goûteux", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "goutes", "goûtes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "goutez", "goûtez", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "goutons", "goûtons", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "grele", "grêle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "grèle", "grêle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "greler", "grêler", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "guepe", "guêpe", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "guepier", "guêpier", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "hawaien", "hawaïen", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "heroiq", "héroïq", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "heroisme", "héroïsme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "héroin", "héroïn", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "héroiq", "héroïq", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "héroisme", "héroïsme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "honnete", "honnête", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "hopita", "hôpita", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "huitre", "huître", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "icone", "icône", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "idolatr", "idolâtr", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ile", "île", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "iles", "îles", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ilot", "îlot", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ilots", "îlots", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "impot", "impôt", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "impots", "impôts", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "indu", "indû", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "indument", "indûment", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "indus", "indûs", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "infame", "infâme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "infamie", "infâmie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "inoui", "inouï", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "interet", "intérêt", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "intéret", "intérêt", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "jeuner", "jeûner", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "lache", "lâche", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "laic", "laïc", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "laique", "laïque", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "laius", "laïus", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "les notres", "les nôtres", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "les votres", "les vôtres", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "lui-meme", "lui-même", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "m'apprete", "m'apprête", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "m’apprete", "m’apprête", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "mache", "mâche", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "macher", "mâcher", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "machoire", "mâchoire", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "machouill", "mâchouill", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "maelstrom", "maelström", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "malstrom", "malström", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "maitr", "maîtr", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "male", "mâle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "males", "mâles", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "manoeuvr", "manœuvr", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "maraich", "maraîch", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "maratre", "marâtre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "meler", "mêler", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "meme", "même", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "mome", "môme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "momes", "mômes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "mosaique", "mosaïque", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "multitache", "multitâche", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "murement", "mûrement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "murir", "mûrir", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "naif", "naïf", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "naifs", "naïfs", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "naivement", "naïvement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "naive", "naïve", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "naives", "naïves", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "naiveté", "naïveté", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "nait", "naît", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "naitre", "naître", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "noeud", "nœud", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "la notre", "la nôtre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "le notre", "le nôtre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "oecuméni", "œcuméni", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "oeil", "œil", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "oesophage", "œsophage", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "oeuf", "œuf", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oeuvre", "œuvre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oiaque", "oïaque", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oisme", "oïsme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oiste", "oïste", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "froide", "froide", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oide", "oïde", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "opiniatre", "opiniâtre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ouie", "ouïe", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ota", "ôta", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "otant", "ôtant", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "oté", "ôté", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "oter", "ôter", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "paella", "paëlla", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "palir", "pâlir", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "paquerette", "pâquerette", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "parait", "paraît", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "paranoia", "paranoïa", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "paté", "pâté", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "patée", "pâtée", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "patés", "pâtés", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "pate", "pâte", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "pates", "pâtes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "pati", "pâti", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "patir", "pâtir", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "patiss", "pâtiss", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "patur", "pâtur", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peche", "pêche", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "pecher", "pêcher", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peches", "pêches", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "pecheu", "pêcheu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "pentecote", "Pentecôte", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "phoenix", "phœnix", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "photovoltai", "photovoltaï", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "piqure", "piqûre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "plait", "plaît", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "platre", "plâtre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "plutot", "plutôt", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "poele", "poêle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "polynom", "polynôm", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "pret", "prêt", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "prets", "prêts", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "prosaique", "prosaïque", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "pylone", "pylône", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "quete", "quête", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "rala", "râla", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ralais", "râlais", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ralait", "râlait", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "raler", "râler", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ralez", "râlez", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ralons", "râlons", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "rebatir", "rebâtir", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "relach", "relâch", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "rene", "rêne", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "renes", "rênes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "revasse", "rêvasse", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "reve", "rêve", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "rever", "rêver", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "reverie", "rêverie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "reves", "rêves", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "requete", "requête", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "rodeur", "rôdeur", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "rodeuse", "rôdeuse", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "roti", "rôti", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "salpetre", "salpêtre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "samourai", "samouraï", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "soeur", "sœur", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "soule", "soûle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "souler", "soûler", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "soules", "soûles", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "soulé", "soûlé", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "stoique", "stoïque", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "stoicisme", "stoïcisme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "surement", "sûrement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "sureté", "sûreté", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "surcout", "surcoût", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "surcroit", "surcroît", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "surs", "sûrs", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "symptom", "symptôm", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "tabloid", "tabloïd", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "tantot", "tantôt", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "tater", "tâter", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "tatons", "tâtons", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "tete", "tête", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "tetes", "têtes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "theatr", "théâtr", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "théatr", "théâtr", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "tole", "tôle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "toles", "tôles", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "traina", "traîna", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "traine", "traîne", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "trainer", "traîner", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "traitr", "traîtr", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "treve", "trêve", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "treves", "trêves", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "trinome", "trinôme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "trona", "trôna", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "trone", "trône", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "tempete", "tempête", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "vetement", "vêtement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "voeu", "vœu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "la votre", "la vôtre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "le votre", "le vôtre", Opts)
}

_GenLoad_autocorrection_names(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "aid", "Aïd", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "alexei", "Alexeï", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "anais", "Anaïs", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "azerbaidjan", "Azerbaïdjan", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bahrein", "Bahreïn", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "benoit", "Benoît", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "caraibes", "Caraïbes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "citroen", "Citroën", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cleopatre", "Cléopâtre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cléopatre", "Cléopâtre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dostoievski", "Dostoïevski", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dostoieski", "Dostoïevski", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dubai", "Dubaï", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "gaetan", "Gaëtan", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "hanoi", "Hanoï", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "hawai", "Hawaï", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "héloise", "Héloïse", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "israel", "Israël", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "jamaique", "Jamaïque", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "jerome", "Jérôme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "jérome", "Jérôme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "joel", "Joël", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "joelle", "Joëlle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "koweit", "Koweït", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mickael", "Mickaël", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "nimes", "Nîmes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "noel", "Noël", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "paques", "Pâques", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "pentecote", "Pentecôte", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "quatar", "Qatar", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "quatari", "qatari", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "raphael", "Raphaël", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "serguei", "Sergueï", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "shanghai", "Shanghaï", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "taiwan", "Taïwan", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "thais", "Thaïs", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "thailande", "Thaïlande", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "tolstoi", "Tolstoï", Opts)
}

_GenLoad_autocorrection_caps(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "adaboost", "AdaBoost", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "adn", "ADN", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ag", "AG", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "api", "API", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "autohotkey", "AutoHotkey", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "aws", "AWS", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "axa", "AXA", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "azure devops", "Azure DevOps", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bbc", "BBC", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bbq", "BBQ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bdd", "BDD", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bdds", "BDDs", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bic", "BIC", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "catboost", "CatBoost", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "chatgpt", "ChatGPT", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cli", "CLI", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "comex", "COMEX", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cpu", "CPU", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "csp", "CSP", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "css", "CSS", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cv", "CV", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "data science", "Data Science", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "data scientist", "Data Scientist", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "databricks", "Databricks", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dna", "DNA", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "docker", "Docker", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ds", "DS", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dynatrace", "Dynatrace", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ergopti", "Ergopti", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "esg", "ESG", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "facebook", "Facebook", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "firefox", "Firefox", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "gcp", "GCP", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "github", "GitHub", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "google", "Google", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "gps", "GPS", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "gpu", "GPU", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "hammerspoon", "Hammerspoon", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ht", "HT", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ia", "IA", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "iban", "IBAN", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "insee", "INSEE", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "instagram", "Instagram", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "intellij", "IntelliJ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "json", "JSON", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ko", "KO", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "kpi", "KPI", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "kpis", "KPIs", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "latex", "LaTeX", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "lightgbm", "LightGBM", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "linux", "Linux", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "llm", "LLM", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "llms", "LLMs", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "lora", "LoRA", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "lualatex", "LuaLaTeX", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "macos", "macOS", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "maj", "MAJ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "majs", "MAJs", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mbti", "MBTI", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mcp", "MCP", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ml", "ML", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mle", "MLE", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mlflow", "MLflow", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mlops", "MLOps", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "nasa", "NASA", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "nfc", "NFC", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "nft", "NFT", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "nlp", "NLP", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ny", "NY", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ok", "OK", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "optimot", "Optimot", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "onedrive", "OneDrive", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "onenote", "OneNote", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "onu", "ONU", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "openshift", "OpenShift", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "opentelemetry", "OpenTelemetry", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "outlook", "Outlook", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "powerbi", "PowerBI", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "poc", "POC", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "pnl", "PNL", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "powerpoint", "PowerPoint", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "pr", "PR", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "qlora", "QLoRA", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "r", "R", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ram", "RAM", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "raid", "RAID", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "rdc", "RDC", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "rh", "RH", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "rib", "RIB", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "sas", "SAS", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "sharepoint", "SharePoint", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "slm", "SLM", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "sql", "SQL", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ssd", "SSD", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "sncf", "SNCF", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ssh", "SSH", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ssl", "SSL", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "swift", "SWIFT", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "tiktok", "TikTok", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "tls", "TLS", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ttc", "TTC", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ttm", "TTM", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ui", "UI", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "uno", "UNO", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "url", "URL", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ux", "UX", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "vpn", "VPN", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "vps", "VPS", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "vscode", "VSCode", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "wikipedia", "Wikipedia", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "wikipédia", "Wikipédia", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "windows", "Windows", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "xgboost", "XGBoost", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "youtube", "YouTube", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "iaas", "IaaS", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "paas", "PaaS", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "saas", "SaaS", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "caas", "CaaS", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "faas", "FaaS", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dbaas", "DBaaS", Opts)
}

_GenLoad_autocorrection_typographicapostrophe(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "c'", "c’", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "d'", "d’", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "j'", "j’", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "l'", "l’", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "m'", "m’", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "n'", "n’", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "s'", "s’", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "t'", "t’", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "n't", "n’t", Opts)
}

_GenLoad_autocorrection_errors(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "(_", "( ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", ")_", ") ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "+_", "+ ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "#_", "# ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "$_", "$ ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "=_", "= ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "[_", "[ ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "]_", "] ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "~_", "~ ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "*_", "* ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "OUi", "Oui", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "acceuil", "accueil", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "aeu", "eau", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eiu", "ieu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eua", "eau", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "fenètre", "fenêtre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "hotsring", "hotstring", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "laieus", "laïus", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oiu", "oui", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oyu", "you", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "poru", "pour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "sru", "sur", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "uio", "uoi", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "accuei", "accuei", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "uei", "uie", Opts)
}

_GenLoad_autocorrection_ou(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "où .", "où.", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "où ,", "où, ", Opts)
}

_GenLoad_autocorrection_multiplepunctuationmarks(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", " ! !", " !!", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "! !", "!!", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", " ? ?", " ??", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "? ?", "??", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", " ! ?", " !?", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "! ?", "!?", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", " ? !", " ?!", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "? !", "?!", Opts)
}

_GenLoad_autocorrection_suffixesachaining(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàa", "aire", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàf", "iste", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàl", "elle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàm", "isme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàn", "ation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàp", "ence", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ieàq", "ique", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàq", "ique", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàr", "erre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàs", "ement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàt", "ettre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàz", "ez-vous", Opts)
}

_GenLoad_autocorrection_minus(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "aije", "ai-je", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "astu", "as-tu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "atil", "a-t-il", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "aton", "a-t-on", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "auratelle", "aura-t-elle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "auratil", "aura-t-il", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "auraton", "aura-t-on", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "dismoi", "dis-moi", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ditelle", "dit-elle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ditil", "dit-il", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "distu", "dis-tu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "diton", "dit-on", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "doisje", "dois-je", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "doitelle", "doit-elle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "doitil", "doit-il", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "doiton", "doit-on", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "estu", "es-tu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "estil", "est-il", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "eston", "est-on", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "fautelle", "faut-elle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "fautil", "faut-il", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "fauton", "faut-on", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peutil", "peut-il", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peutelle", "peut-elle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peuton", "peut-on", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peuxtu", "peux-tu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "puisje", "puis-je", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "vatelle", "va-t-elle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "vatil", "va-t-il", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "vaton", "va-t-on", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "veutelle", "veut-elle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "veutil", "veut-il", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "veuton", "veut-on", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "veuxtu", "veux-tu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "yatil", "y a-t-il", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "vonsn", "vons-n", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "vezv", "vez-v", Opts)
}

_GenLoad_autocorrection_minusapostrophe(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ai'j", "ai-j", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ai',", "ai-j", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "as't", "as-t", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a't", "a-t", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a-t’e", "a-t-e", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a't'e", "a-t-e", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a-t’i", "a-t-i", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a't'i", "a-t-i", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a-t’o", "a-t-o", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a't'o", "a-t-o", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "s',", "s-j", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "s'j", "s-j", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "s'm", "s-m", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "s'n", "s-n", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "s't", "s-t", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "t'e", "t-e", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "t'i", "t-i", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "t'o", "t-o", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "x't", "x-t", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "z'v", "z-v", Opts)
}

_GenLoad_magickey_repeat(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "arrê", "arrê", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "emmê", "emmê", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "honnê", "honnê", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ccê", "ccu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ddê", "ddu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ffê", "ffu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ggê", "ggu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "llê", "llu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "mmê", "mmu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "nnê", "nnu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ppê", "ppu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "rrê", "rru", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ssê", "ssu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ttê", "ttu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("a★", "★", _GenMK), "aa", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("b★", "★", _GenMK), "bb", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("c★", "★", _GenMK), "cc", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("d★", "★", _GenMK), "dd", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("e★", "★", _GenMK), "ee", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("é★", "★", _GenMK), "éé", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("è★", "★", _GenMK), "èè", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("ê★", "★", _GenMK), "êê", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("f★", "★", _GenMK), "ff", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("g★", "★", _GenMK), "gg", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("h★", "★", _GenMK), "hh", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("i★", "★", _GenMK), "ii", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("j★", "★", _GenMK), "jj", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("k★", "★", _GenMK), "kk", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("l★", "★", _GenMK), "ll", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("m★", "★", _GenMK), "mm", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("n★", "★", _GenMK), "nn", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("o★", "★", _GenMK), "oo", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("p★", "★", _GenMK), "pp", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("q★", "★", _GenMK), "qq", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("r★", "★", _GenMK), "rr", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("s★", "★", _GenMK), "ss", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("t★", "★", _GenMK), "tt", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("u★", "★", _GenMK), "uu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("v★", "★", _GenMK), "vv", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("w★", "★", _GenMK), "ww", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("x★", "★", _GenMK), "xx", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("y★", "★", _GenMK), "yy", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("z★", "★", _GenMK), "zz", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("0★", "★", _GenMK), "00", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("1★", "★", _GenMK), "11", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("2★", "★", _GenMK), "22", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("3★", "★", _GenMK), "33", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("4★", "★", _GenMK), "44", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("5★", "★", _GenMK), "55", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("6★", "★", _GenMK), "66", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("7★", "★", _GenMK), "77", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("8★", "★", _GenMK), "88", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("9★", "★", _GenMK), "99", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("<★", "★", _GenMK), "<<", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace(">★", "★", _GenMK), ">>", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("{★", "★", _GenMK), "{{", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("}★", "★", _GenMK), "}}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("(★", "★", _GenMK), "((", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace(")★", "★", _GenMK), "))", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("[★", "★", _GenMK), "[[", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("]★", "★", _GenMK), "]]", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("-★", "★", _GenMK), "--", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("_★", "★", _GenMK), "__", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace(":★", "★", _GenMK), "::", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("`;★", "★", _GenMK), "`;`;", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("?★", "★", _GenMK), "??", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("!★", "★", _GenMK), "!!", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("+★", "★", _GenMK), "++", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("^★", "★", _GenMK), "^^", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("#★", "★", _GenMK), "##", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("``★", "★", _GenMK), "````", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("=★", "★", _GenMK), "==", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("/★", "★", _GenMK), "//", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("\★", "★", _GenMK), "\\", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("|★", "★", _GenMK), "||", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("&★", "★", _GenMK), "&&", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("$★", "★", _GenMK), "$$", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("@★", "★", _GenMK), "@@", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("~★", "★", _GenMK), "~~", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", StrReplace("*★", "★", _GenMK), "**", Opts)
}

_GenLoad_magickey_textexpansion(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("ae★", "★", _GenMK), "æ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("oe★", "★", _GenMK), "œ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("1er★", "★", _GenMK), "premier", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("1ere★", "★", _GenMK), "première", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("2e★", "★", _GenMK), "deuxième", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("3e★", "★", _GenMK), "troisième", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("4e★", "★", _GenMK), "quatrième", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("5e★", "★", _GenMK), "cinquième", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("6e★", "★", _GenMK), "sixième", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("7e★", "★", _GenMK), "septième", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("8e★", "★", _GenMK), "huitième", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("9e★", "★", _GenMK), "neuvième", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("10e★", "★", _GenMK), "dixième", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("11e★", "★", _GenMK), "onzième", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("12e★", "★", _GenMK), "douzième", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("20e★", "★", _GenMK), "vingtième", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("100e★", "★", _GenMK), "centième", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("1000e★", "★", _GenMK), "millième", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("2s★", "★", _GenMK), "2 secondes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("//★", "★", _GenMK), "rapport", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("+m★", "★", _GenMK), "meilleur", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("a★", "★", _GenMK), "ainsi", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("abr★", "★", _GenMK), "abréviation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("actu★", "★", _GenMK), "actualité", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("add★", "★", _GenMK), "addresse", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("admin★", "★", _GenMK), "administrateur", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("afr★", "★", _GenMK), "à faire", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ah★", "★", _GenMK), "aujourd’hui", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ahk★", "★", _GenMK), "autohotkey", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ajd★", "★", _GenMK), "aujourd’hui", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("algo★", "★", _GenMK), "algorithme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("alpha★", "★", _GenMK), "alphabétique", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("amé★", "★", _GenMK), "amélioration", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("amélio★", "★", _GenMK), "amélioration", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("anc★", "★", _GenMK), "ancien", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ano★", "★", _GenMK), "anomalie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("anniv★", "★", _GenMK), "anniversaire", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("apm★", "★", _GenMK), "après-midi", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("apad★", "★", _GenMK), "à partir de", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("app★", "★", _GenMK), "application", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("appart★", "★", _GenMK), "appartement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("appli★", "★", _GenMK), "application", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("approx★", "★", _GenMK), "approximation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("archi★", "★", _GenMK), "architecture", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("arg★", "★", _GenMK), "argument", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("asso★", "★", _GenMK), "association", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("asap★", "★", _GenMK), "le plus rapidement possible", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("atd★", "★", _GenMK), "attend", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("att★", "★", _GenMK), "attention", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("au★", "★", _GenMK), "aujourd’hui", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("aud★", "★", _GenMK), "aujourd’hui", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("aug★", "★", _GenMK), "augmentation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("auj★", "★", _GenMK), "aujourd’hui", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("auto★", "★", _GenMK), "automatique", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("av★", "★", _GenMK), "avant", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("avv★", "★", _GenMK), "avez-vous", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("avvd★", "★", _GenMK), "avez-vous déjà", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("b★", "★", _GenMK), "bonjour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bb★", "★", _GenMK), "barbecue", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bc★", "★", _GenMK), "because", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bcp★", "★", _GenMK), "beaucoup", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bdd★", "★", _GenMK), "base de données", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bdds★", "★", _GenMK), "bases de données", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bea★", "★", _GenMK), "beaucoup", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bec★", "★", _GenMK), "because", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bib★", "★", _GenMK), "bibliographie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("biblio★", "★", _GenMK), "bibliographie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bjr★", "★", _GenMK), "bonjour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("brain★", "★", _GenMK), "brainstorming", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("br★", "★", _GenMK), "bonjour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bsr★", "★", _GenMK), "bonsoir", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bv★", "★", _GenMK), "bravo", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bvd★", "★", _GenMK), "boulevard", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bvn★", "★", _GenMK), "bienvenue", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bwe★", "★", _GenMK), "bon week-end", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("bwk★", "★", _GenMK), "bon week-end", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("c★", "★", _GenMK), "c’est", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cad★", "★", _GenMK), "c’est-à-dire", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("camp★", "★", _GenMK), "campagne", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("carac★", "★", _GenMK), "caractère", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("caract★", "★", _GenMK), "caractéristique", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cb★", "★", _GenMK), "combien", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cc★", "★", _GenMK), "copier-coller", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ccé★", "★", _GenMK), "copié-collé", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ccl★", "★", _GenMK), "conclusion", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cdg★", "★", _GenMK), "Charles de Gaulle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cdt★", "★", _GenMK), "cordialement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("certif★", "★", _GenMK), "certification", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("chg★", "★", _GenMK), "charge", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("chap★", "★", _GenMK), "chapitre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("chr★", "★", _GenMK), "chercher", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ci★", "★", _GenMK), "ci-joint", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cj★", "★", _GenMK), "ci-joint", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("coeff★", "★", _GenMK), "coefficient", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cog★", "★", _GenMK), "cognition", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cogv★", "★", _GenMK), "cognitive", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("comp★", "★", _GenMK), "comprendre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cond★", "★", _GenMK), "condition", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("conds★", "★", _GenMK), "conditions", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("config★", "★", _GenMK), "configuration", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("conso★", "★", _GenMK), "consommation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("chgt★", "★", _GenMK), "changement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cnp★", "★", _GenMK), "ce n’est pas", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("contrib★", "★", _GenMK), "contribution", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("couv★", "★", _GenMK), "couverture", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cpd★", "★", _GenMK), "cependant", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cq★", "★", _GenMK), "ce que", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cr★", "★", _GenMK), "compte-rendu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ct★", "★", _GenMK), "c’était", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ctb★", "★", _GenMK), "c’est très bien", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cv★", "★", _GenMK), "ça va ?", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("cvt★", "★", _GenMK), "ça va toi ?", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ctc★", "★", _GenMK), "Est-ce que cela te convient ?", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cvc★", "★", _GenMK), "Est-ce que cela vous convient ?", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dac★", "★", _GenMK), "d’accord", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ddl★", "★", _GenMK), "download", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dé★", "★", _GenMK), "déjà", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dê★", "★", _GenMK), "d’être", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("déc★", "★", _GenMK), "décembre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dec★", "★", _GenMK), "décembre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dedt★", "★", _GenMK), "d’emploi du temps", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("déf★", "★", _GenMK), "définition", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("def★", "★", _GenMK), "définition", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("défs★", "★", _GenMK), "définitions", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("démo★", "★", _GenMK), "démonstration", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("demo★", "★", _GenMK), "démonstration", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dep★", "★", _GenMK), "département", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("deux★", "★", _GenMK), "deuxième", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("desc★", "★", _GenMK), "description", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dev★", "★", _GenMK), "développeur", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dév★", "★", _GenMK), "développeur", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("devt★", "★", _GenMK), "développement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dico★", "★", _GenMK), "dictionnaire", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("diff★", "★", _GenMK), "différence", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("difft★", "★", _GenMK), "différent", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dim★", "★", _GenMK), "dimension", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dimi★", "★", _GenMK), "diminution", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("la dispo★", "★", _GenMK), "la disposition", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ta dispo★", "★", _GenMK), "ta disposition", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("une dispo★", "★", _GenMK), "une disposition", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dispo★", "★", _GenMK), "disponible", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("distri★", "★", _GenMK), "distributeur", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("distrib★", "★", _GenMK), "distributeur", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dj★", "★", _GenMK), "déjà", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dm★", "★", _GenMK), "donne-moi", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("la doc★", "★", _GenMK), "la documentation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("une doc★", "★", _GenMK), "une documentation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("doc★", "★", _GenMK), "document", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("docs★", "★", _GenMK), "documents", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dp★", "★", _GenMK), "de plus", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dr★", "★", _GenMK), "de rien", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ds★", "★", _GenMK), "data science", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dsl★", "★", _GenMK), "désolé", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dst★", "★", _GenMK), "data scientist", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dtm★", "★", _GenMK), "détermine", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("dvlp★", "★", _GenMK), "développe", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("e★", "★", _GenMK), "est", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("echant★", "★", _GenMK), "échantillon", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("echants★", "★", _GenMK), "échantillons", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("eco★", "★", _GenMK), "économie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ecq★", "★", _GenMK), "est-ce que", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("edt★", "★", _GenMK), "emploi du temps", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("eef★", "★", _GenMK), "en effet", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("elt★", "★", _GenMK), "élément", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("elts★", "★", _GenMK), "éléments", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("eo★", "★", _GenMK), "en outre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("enc★", "★", _GenMK), "encore", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("eng★", "★", _GenMK), "english", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("enft★", "★", _GenMK), "en fait", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ens★", "★", _GenMK), "ensemble", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ent★", "★", _GenMK), "entreprise", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("env★", "★", _GenMK), "environ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ep★", "★", _GenMK), "épisode", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("eps★", "★", _GenMK), "épisodes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("eq★", "★", _GenMK), "équation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ety★", "★", _GenMK), "étymologie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("eve★", "★", _GenMK), "événement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("evtl★", "★", _GenMK), "éventuel", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("evtle★", "★", _GenMK), "éventuelle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("evtlt★", "★", _GenMK), "éventuellement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ex★", "★", _GenMK), "exemple", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("exo★", "★", _GenMK), "exercice", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("exp★", "★", _GenMK), "expérience", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("expo★", "★", _GenMK), "exposition", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("é★", "★", _GenMK), "écart", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("échant★", "★", _GenMK), "échantillon", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("échants★", "★", _GenMK), "échantillons", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("éco★", "★", _GenMK), "économie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ém★", "★", _GenMK), "écris-moi", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("éq★", "★", _GenMK), "équation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ê★", "★", _GenMK), "être", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("êt★", "★", _GenMK), "es-tu", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("f★", "★", _GenMK), "faire", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fam★", "★", _GenMK), "famille", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fb★", "★", _GenMK), "facebook", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fc★", "★", _GenMK), "fonction", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fct★", "★", _GenMK), "fonction", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fea★", "★", _GenMK), "feature", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("feat★", "★", _GenMK), "feature", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fev★", "★", _GenMK), "février", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fi★", "★", _GenMK), "financier", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fiè★", "★", _GenMK), "financière", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ff★", "★", _GenMK), "firefox", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fig★", "★", _GenMK), "figure", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fl★", "★", _GenMK), "falloir", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("freq★", "★", _GenMK), "fréquence", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fr★", "★", _GenMK), "France", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("frs★", "★", _GenMK), "français", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ft★", "★", _GenMK), "fine-tune", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ftg★", "★", _GenMK), "fine-tuning", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("fti★", "★", _GenMK), "fine-tuning", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("g★", "★", _GenMK), "j’ai", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("g1r★", "★", _GenMK), "j’ai une réunion", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gar★", "★", _GenMK), "garantie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gars★", "★", _GenMK), "garanties", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gd★", "★", _GenMK), "grand", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gg★", "★", _GenMK), "google", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ges★", "★", _GenMK), "gestion", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gf★", "★", _GenMK), "j’ai fait", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gh★", "★", _GenMK), "github", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ghc★", "★", _GenMK), "GitHub Copilot", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ght★", "★", _GenMK), "j’ai acheté", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gmag★", "★", _GenMK), "j’ai mis à jour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gov★", "★", _GenMK), "government", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gouv★", "★", _GenMK), "gouvernement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("indiv★", "★", _GenMK), "individuel", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gpa★", "★", _GenMK), "je n’ai pas", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gt★", "★", _GenMK), "j’étais", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("gvt★", "★", _GenMK), "gouvernement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("h★", "★", _GenMK), "heure", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("hf★", "★", _GenMK), "Hugging Face", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("his★", "★", _GenMK), "historique", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("histo★", "★", _GenMK), "historique", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("hs★", "★", _GenMK), "hammerspoon", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("htu★", "★", _GenMK), "how to use", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("hyp★", "★", _GenMK), "hypothèse", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ia★", "★", _GenMK), "intelligence artificielle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("id★", "★", _GenMK), "identifiant", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("idf★", "★", _GenMK), "Île-de-France", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("idk★", "★", _GenMK), "I don’t know", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ids★", "★", _GenMK), "identifiants", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("img★", "★", _GenMK), "image", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("imgs★", "★", _GenMK), "images", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("imm★", "★", _GenMK), "immeuble", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("imo★", "★", _GenMK), "in my opinion", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("imp★", "★", _GenMK), "impossible", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("inf★", "★", _GenMK), "inférieur", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("info★", "★", _GenMK), "information", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("infos★", "★", _GenMK), "informations", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("infra★", "★", _GenMK), "infrastructure", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("insta★", "★", _GenMK), "instagram", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("intart★", "★", _GenMK), "intelligence artificielle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("inter★", "★", _GenMK), "international", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("intro★", "★", _GenMK), "introduction", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("j★", "★", _GenMK), "bonjour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ja★", "★", _GenMK), "jamais", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("janv★", "★", _GenMK), "janvier", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jm★", "★", _GenMK), "j’aime", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jms★", "★", _GenMK), "jamais", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jnsp★", "★", _GenMK), "je ne sais pas", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("js★", "★", _GenMK), "je suis", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jsp★", "★", _GenMK), "je ne sais pas", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jtm★", "★", _GenMK), "je t’aime", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ju★", "★", _GenMK), "jusque", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ju'★", "★", _GenMK), "jusqu’", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jus★", "★", _GenMK), "jusque", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jusq★", "★", _GenMK), "jusqu’", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jus'★", "★", _GenMK), "jusqu’", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("jui★", "★", _GenMK), "juillet", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("k★", "★", _GenMK), "contacter", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("kb★", "★", _GenMK), "keyboard", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("kbd★", "★", _GenMK), "keyboard", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "kdo", "cadeau", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("kn★", "★", _GenMK), "construction", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("l★", "★", _GenMK), "elle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("la★", "★", _GenMK), "Los Angeles", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("lê★", "★", _GenMK), "l’être", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ledt★", "★", _GenMK), "l’emploi du temps", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("lex★", "★", _GenMK), "l’exemple", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("lgb★", "★", _GenMK), "lightgbm", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("lim★", "★", _GenMK), "limite", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("llm★", "★", _GenMK), "large language model", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("m★", "★", _GenMK), "mais", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ma★", "★", _GenMK), "madame", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("maj★", "★", _GenMK), "mise à jour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("majs★", "★", _GenMK), "mises à jour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("màj★", "★", _GenMK), "mise à jour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("màjs★", "★", _GenMK), "mises à jour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("math★", "★", _GenMK), "mathématique", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("manip★", "★", _GenMK), "manipulation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("maths★", "★", _GenMK), "mathématiques", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("max★", "★", _GenMK), "maximum", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("md★", "★", _GenMK), "markdown", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mdav★", "★", _GenMK), "merci d’avance", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mdb★", "★", _GenMK), "merci de bien vouloir", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mdl★", "★", _GenMK), "modèle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mdp★", "★", _GenMK), "mot de passe", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mdps★", "★", _GenMK), "mots de passe", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("méthodo★", "★", _GenMK), "méthodologie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("min★", "★", _GenMK), "minimum", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mio★", "★", _GenMK), "million", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mios★", "★", _GenMK), "millions", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mjo★", "★", _GenMK), "mettre à jour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ml★", "★", _GenMK), "machine learning", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mle★", "★", _GenMK), "machine learning engineer", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mm★", "★", _GenMK), "même", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mme★", "★", _GenMK), "madame", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("modif★", "★", _GenMK), "modification", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mom★", "★", _GenMK), "moi-même", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mq★", "★", _GenMK), "montre que", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mr★", "★", _GenMK), "monsieur", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mrc★", "★", _GenMK), "merci", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("msg★", "★", _GenMK), "message", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mtn★", "★", _GenMK), "maintenant", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("moy★", "★", _GenMK), "moyenne", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mutu★", "★", _GenMK), "mutualiser", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mvt★", "★", _GenMK), "mouvement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("n★", "★", _GenMK), "nouveau", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("nav★", "★", _GenMK), "navigation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("nb★", "★", _GenMK), "nombre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("nean★", "★", _GenMK), "néanmoins", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("new★", "★", _GenMK), "nouveau", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("newe★", "★", _GenMK), "nouvelle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("nimp★", "★", _GenMK), "n’importe", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("niv★", "★", _GenMK), "niveau", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("norm★", "★", _GenMK), "normalement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("nota★", "★", _GenMK), "notamment", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("notm★", "★", _GenMK), "notamment", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("nouv★", "★", _GenMK), "nouvelle", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("nov★", "★", _GenMK), "novembre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("now★", "★", _GenMK), "maintenant", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("np★", "★", _GenMK), "ne pas", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("nrj★", "★", _GenMK), "énergie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ns★", "★", _GenMK), "nous", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("num★", "★", _GenMK), "numéro", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ny★", "★", _GenMK), "New York", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("o-★", "★", _GenMK), "au moins", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("o+★", "★", _GenMK), "au plus", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("obj★", "★", _GenMK), "objectif", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("obs★", "★", _GenMK), "observation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("oct★", "★", _GenMK), "octobre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("odj★", "★", _GenMK), "ordre du jour", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("opé★", "★", _GenMK), "opération", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("oqp★", "★", _GenMK), "occupé", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ordi★", "★", _GenMK), "ordinateur", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("org★", "★", _GenMK), "organisation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("orga★", "★", _GenMK), "organisation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ortho★", "★", _GenMK), "orthographe", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("out★", "★", _GenMK), "Où es-tu ?", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("outv★", "★", _GenMK), "Où êtes-vous ?", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ouv★", "★", _GenMK), "ouverture", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("p★", "★", _GenMK), "prendre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("p//★", "★", _GenMK), "par rapport", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("par★", "★", _GenMK), "paragraphe", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("param★", "★", _GenMK), "paramètre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("params★", "★", _GenMK), "paramètres", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pè★", "★", _GenMK), "problème", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pb★", "★", _GenMK), "problème", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pcq★", "★", _GenMK), "parce que", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pck★", "★", _GenMK), "parce que", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pckil★", "★", _GenMK), "parce qu’il", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pcquil★", "★", _GenMK), "parce qu’il", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pcquon★", "★", _GenMK), "parce qu’on", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pckon★", "★", _GenMK), "parce qu’on", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pd★", "★", _GenMK), "pendant", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pdt★", "★", _GenMK), "pendant", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pdv★", "★", _GenMK), "point de vue", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pdvs★", "★", _GenMK), "points de vue", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("perf★", "★", _GenMK), "performance", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("perso★", "★", _GenMK), "personne", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pê★", "★", _GenMK), "peut-être", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("péri★", "★", _GenMK), "périmètre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("périm★", "★", _GenMK), "périmètre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("peut-ê★", "★", _GenMK), "peut-être", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pex★", "★", _GenMK), "par exemple", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pf★", "★", _GenMK), "portefeuille", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pg★", "★", _GenMK), "pas grave", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pgm★", "★", _GenMK), "programme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pi★", "★", _GenMK), "pour information", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pic★", "★", _GenMK), "picture", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pics★", "★", _GenMK), "pictures", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("piè★", "★", _GenMK), "pièce jointe", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pj★", "★", _GenMK), "pièce jointe", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pjs★", "★", _GenMK), "pièces jointes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pk★", "★", _GenMK), "pourquoi", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pls★", "★", _GenMK), "please", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("poc★", "★", _GenMK), "proof of concept", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("poum★", "★", _GenMK), "plus ou moins", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("poss★", "★", _GenMK), "possible", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pourcent★", "★", _GenMK), "pourcentage", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ppt★", "★", _GenMK), "PowerPoint", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pq★", "★", _GenMK), "pourquoi", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pr★", "★", _GenMK), "pull request", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prd★", "★", _GenMK), "produit", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prem★", "★", _GenMK), "premier", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prez★", "★", _GenMK), "présentation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prg★", "★", _GenMK), "programme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prio★", "★", _GenMK), "priorité", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pro★", "★", _GenMK), "professionnel", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prob★", "★", _GenMK), "problème", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("proba★", "★", _GenMK), "probabilité", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prod★", "★", _GenMK), "production", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prof★", "★", _GenMK), "professeur", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prog★", "★", _GenMK), "programme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prop★", "★", _GenMK), "propriété", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("propo★", "★", _GenMK), "proposition", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("props★", "★", _GenMK), "propriétés", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pros★", "★", _GenMK), "professionnels", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prot★", "★", _GenMK), "professionnellement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("prov★", "★", _GenMK), "provision", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("psycha★", "★", _GenMK), "psychanalyse", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("psycho★", "★", _GenMK), "psychologie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("psb★", "★", _GenMK), "possible", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("psy★", "★", _GenMK), "psychologie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pt★", "★", _GenMK), "point", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ptf★", "★", _GenMK), "portefeuille", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pts★", "★", _GenMK), "points", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pub★", "★", _GenMK), "publicité", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pvv★", "★", _GenMK), "pouvez-vous", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("py★", "★", _GenMK), "python", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("q★", "★", _GenMK), "question", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("qc★", "★", _GenMK), "qu’est-ce", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("qcq★", "★", _GenMK), "qu’est-ce que", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("qcq'★", "★", _GenMK), "qu’est-ce qu’", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("qq★", "★", _GenMK), "quelque", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("qqch★", "★", _GenMK), "quelque chose", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("qqs★", "★", _GenMK), "quelques", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("qqn★", "★", _GenMK), "quelqu’un", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("quasi★", "★", _GenMK), "quasiment", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ques★", "★", _GenMK), "question", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("quid★", "★", _GenMK), "qu’en est-il de", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("r★", "★", _GenMK), "rien", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rapidt★", "★", _GenMK), "rapidement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rdc★", "★", _GenMK), "rez-de-chaussée", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rdv★", "★", _GenMK), "rendez-vous", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ré★", "★", _GenMK), "réunion", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rés★", "★", _GenMK), "réunions", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rép★", "★", _GenMK), "répertoire", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("résil★", "★", _GenMK), "résiliation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("reco★", "★", _GenMK), "recommandation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ref★", "★", _GenMK), "référence", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rep★", "★", _GenMK), "répertoire", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rex★", "★", _GenMK), "retour d’expérience", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rh★", "★", _GenMK), "ressources humaines", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rmq★", "★", _GenMK), "remarque", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rpz★", "★", _GenMK), "représente", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("rs★", "★", _GenMK), "résultat", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("seg★", "★", _GenMK), "segment", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("segm★", "★", _GenMK), "segment", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("sep★", "★", _GenMK), "septembre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("sept★", "★", _GenMK), "septembre", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("simpl★", "★", _GenMK), "simplement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("situ★", "★", _GenMK), "situation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("smth★", "★", _GenMK), "something", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("srx★", "★", _GenMK), "sérieux", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("sécu★", "★", _GenMK), "sécurité", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("st★", "★", _GenMK), "s’était", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("stat★", "★", _GenMK), "statistique", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("sth★", "★", _GenMK), "something", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("stp★", "★", _GenMK), "s’il te plaît", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("strat★", "★", _GenMK), "stratégique", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("stream★", "★", _GenMK), "streaming", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("suff★", "★", _GenMK), "suffisant", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("sufft★", "★", _GenMK), "suffisamment", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("supé★", "★", _GenMK), "supérieur", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("surv★", "★", _GenMK), "survenance", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("svp★", "★", _GenMK), "s’il vous plaît", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("svt★", "★", _GenMK), "souvent", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("sya★", "★", _GenMK), "s’il y a", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("syn★", "★", _GenMK), "synonyme", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("sync★", "★", _GenMK), "synchronisation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("syncro★", "★", _GenMK), "synchronisation", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("sys★", "★", _GenMK), "système", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("t★", "★", _GenMK), "très", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tb★", "★", _GenMK), "très bien", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("temp★", "★", _GenMK), "temporaire", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tes★", "★", _GenMK), "tu es", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tél★", "★", _GenMK), "téléphone", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("teq★", "★", _GenMK), "telle que", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("teqs★", "★", _GenMK), "telles que", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tfk★", "★", _GenMK), "qu’est-ce que tu fais ?", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tgh★", "★", _GenMK), "together", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("théo★", "★", _GenMK), "théorie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("thm★", "★", _GenMK), "théorème", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tj★", "★", _GenMK), "toujours", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tjr★", "★", _GenMK), "toujours", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tlm★", "★", _GenMK), "tout le monde", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tq★", "★", _GenMK), "tel que", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tqs★", "★", _GenMK), "tels que", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tout★", "★", _GenMK), "toutefois", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tra★", "★", _GenMK), "travail", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("trad★", "★", _GenMK), "traduction", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("trav★", "★", _GenMK), "travail", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("trkl★", "★", _GenMK), "tranquille", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tt★", "★", _GenMK), "télétravail", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ttm★", "★", _GenMK), "time to market", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tv★", "★", _GenMK), "télévision", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ty★", "★", _GenMK), "thank you", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("typo★", "★", _GenMK), "typographie", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("une amé★", "★", _GenMK), "une amélioration", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("uniq★", "★", _GenMK), "uniquement", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("usa★", "★", _GenMK), "États-Unis", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("v★", "★", _GenMK), "version", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("var★", "★", _GenMK), "variable", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("vav★", "★", _GenMK), "vis-à-vis", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("verif★", "★", _GenMK), "vérification", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("vérif★", "★", _GenMK), "vérification", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("vocab★", "★", _GenMK), "vocabulaire", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("volat★", "★", _GenMK), "volatilité", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("vrm★", "★", _GenMK), "vraiment", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("vrmt★", "★", _GenMK), "vraiment", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("vs★", "★", _GenMK), "vous êtes", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("vsc★", "★", _GenMK), "VSCode", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("w★", "★", _GenMK), "with", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("wd★", "★", _GenMK), "windows", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("wk★", "★", _GenMK), "week-end", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("wknd★", "★", _GenMK), "week-end", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("wiki★", "★", _GenMK), "wikipédia", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("x★", "★", _GenMK), "exemple", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("xg★", "★", _GenMK), "xgboost", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("xgb★", "★", _GenMK), "xgboost", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("xp★", "★", _GenMK), "expérience", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ya★", "★", _GenMK), "il y a", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("yapa★", "★", _GenMK), "il n’y a pas", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("yatil★", "★", _GenMK), "y a-t-il", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("yc★", "★", _GenMK), "y compris", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("yt★", "★", _GenMK), "youtube", Opts)
}

_GenLoad_magickey_textexpansionauto(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ju'", "jusqu’", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ya", "y’a", Opts)
}

_GenLoad_magickey_textexpansionemojis(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace(":)★", "★", _GenMK), "😀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace(":))★", "★", _GenMK), "😁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace(":/★", "★", _GenMK), "🫤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace(":(★", "★", _GenMK), "☹️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace(":3★", "★", _GenMK), "😗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace(":D★", "★", _GenMK), "😁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace(":O★", "★", _GenMK), "😮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace(":P★", "★", _GenMK), "😛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("abeille★", "★", _GenMK), "🐝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("aigle★", "★", _GenMK), "🦅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("araignée★", "★", _GenMK), "🕷️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("baleine★", "★", _GenMK), "🐋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("canard★", "★", _GenMK), "🦆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cerf★", "★", _GenMK), "🦌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("chameau★", "★", _GenMK), "🐪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("chat★", "★", _GenMK), "🐈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("chauve-souris★", "★", _GenMK), "🦇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("chèvre★", "★", _GenMK), "🐐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cheval★", "★", _GenMK), "🐎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("chien★", "★", _GenMK), "🐕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cochon★", "★", _GenMK), "🐖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("coq★", "★", _GenMK), "🐓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("crabe★", "★", _GenMK), "🦀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("croco★", "★", _GenMK), "🐊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("crocodile★", "★", _GenMK), "🐊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cygne★", "★", _GenMK), "🦢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("dauphin★", "★", _GenMK), "🐬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("dragon★", "★", _GenMK), "🐉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("écureuil★", "★", _GenMK), "🐿️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("éléphant★", "★", _GenMK), "🐘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("escargot★", "★", _GenMK), "🐌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("flamant★", "★", _GenMK), "🦩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fourmi★", "★", _GenMK), "🐜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("girafe★", "★", _GenMK), "🦒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("gorille★", "★", _GenMK), "🦍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("grenouille★", "★", _GenMK), "🐸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("hamster★", "★", _GenMK), "🐹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("hérisson★", "★", _GenMK), "🦔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("hibou★", "★", _GenMK), "🦉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("hippopotame★", "★", _GenMK), "🦛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("homard★", "★", _GenMK), "🦞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("kangourou★", "★", _GenMK), "🦘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("koala★", "★", _GenMK), "🐨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("lama★", "★", _GenMK), "🦙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("lapin★", "★", _GenMK), "🐇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("léopard★", "★", _GenMK), "🐆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("licorne★", "★", _GenMK), "🦄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("lion★", "★", _GenMK), "🦁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("loup★", "★", _GenMK), "🐺", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("mouton★", "★", _GenMK), "🐑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("octopus★", "★", _GenMK), "🐙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ours★", "★", _GenMK), "🐻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("panda★", "★", _GenMK), "🐼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("papillon★", "★", _GenMK), "🦋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("paresseux★", "★", _GenMK), "🦥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("perroquet★", "★", _GenMK), "🦜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pingouin★", "★", _GenMK), "🐧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("poisson★", "★", _GenMK), "🐟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("poule★", "★", _GenMK), "🐔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("poussin★", "★", _GenMK), "🐣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("renard★", "★", _GenMK), "🦊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("requin★", "★", _GenMK), "🦈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("rhinocéros★", "★", _GenMK), "🦏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("rhinoceros★", "★", _GenMK), "🦏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("sanglier★", "★", _GenMK), "🐗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("serpent★", "★", _GenMK), "🐍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("singe★", "★", _GenMK), "🐒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("souris★", "★", _GenMK), "🐁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("tigre★", "★", _GenMK), "🐅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("tortue★", "★", _GenMK), "🐢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("trex★", "★", _GenMK), "🦖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("vache★", "★", _GenMK), "🐄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("zèbre★", "★", _GenMK), "🦓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("aimant★", "★", _GenMK), "🧲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ampoule★", "★", _GenMK), "💡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ancre★", "★", _GenMK), "⚓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("arbre★", "★", _GenMK), "🌲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("argent★", "★", _GenMK), "💰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("attention★", "★", _GenMK), "⚠️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("avion★", "★", _GenMK), "✈️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("balance★", "★", _GenMK), "⚖️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ballon★", "★", _GenMK), "🎈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("batterie★", "★", _GenMK), "🔋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("blanc★", "★", _GenMK), "🏳️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("bombe★", "★", _GenMK), "💣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("boussole★", "★", _GenMK), "🧭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("brain★", "★", _GenMK), "🧠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("bougie★", "★", _GenMK), "🕯️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cadeau★", "★", _GenMK), "🎁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cadenas★", "★", _GenMK), "🔒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("calendrier★", "★", _GenMK), "📅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("caméra★", "★", _GenMK), "📷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cerveau★", "★", _GenMK), "🧠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("clavier★", "★", _GenMK), "⌨️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("check★", "★", _GenMK), "✔️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("clé★", "★", _GenMK), "🔑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cloche★", "★", _GenMK), "🔔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("computer★", "★", _GenMK), "💻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("couronne★", "★", _GenMK), "👑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("croix★", "★", _GenMK), "❌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("danse★", "★", _GenMK), "💃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("diamant★", "★", _GenMK), "💎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("drapeau★", "★", _GenMK), "🏁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("douche★", "★", _GenMK), "🛁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("éclair★", "★", _GenMK), "⚡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("eau★", "★", _GenMK), "💧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("email★", "★", _GenMK), "📧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("épée★", "★", _GenMK), "⚔️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("étoile★", "★", _GenMK), "⭐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("faux★", "★", _GenMK), "❌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("feu★", "★", _GenMK), "🔥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fete★", "★", _GenMK), "🎉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fête★", "★", _GenMK), "🎉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("film★", "★", _GenMK), "🎬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fleur★", "★", _GenMK), "🌸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fusée★", "★", _GenMK), "🚀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("guitare★", "★", _GenMK), "🎸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("idée★", "★", _GenMK), "💡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("idee★", "★", _GenMK), "💡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("interdit★", "★", _GenMK), "⛔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("journal★", "★", _GenMK), "📰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ko★", "★", _GenMK), "❌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("livre★", "★", _GenMK), "📖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("loupe★", "★", _GenMK), "🔎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("lune★", "★", _GenMK), "🌙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("médaille★", "★", _GenMK), "🥇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("medaille★", "★", _GenMK), "🥇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("microphone★", "★", _GenMK), "🎤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("montre★", "★", _GenMK), "⌚", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("musique★", "★", _GenMK), "🎵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("noel★", "★", _GenMK), "🎄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("nuage★", "★", _GenMK), "☁️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ok★", "★", _GenMK), "✅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("olaf★", "★", _GenMK), "⛄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ordi★", "★", _GenMK), "💻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ordinateur★", "★", _GenMK), "💻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("parapluie★", "★", _GenMK), "☂️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pc★", "★", _GenMK), "💻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("piano★", "★", _GenMK), "🎹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pirate★", "★", _GenMK), "🏴‍☠️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pluie★", "★", _GenMK), "🌧️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("radioactif★", "★", _GenMK), "☢️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("regard★", "★", _GenMK), "👀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("robot★", "★", _GenMK), "🤖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("rocket★", "★", _GenMK), "🚀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("sacoche★", "★", _GenMK), "💼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("smartphone★", "★", _GenMK), "📱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("soleil★", "★", _GenMK), "☀️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("terre★", "★", _GenMK), "🌍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("thermomètre★", "★", _GenMK), "🌡️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("timer★", "★", _GenMK), "⏲️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("toilette★", "★", _GenMK), "🧻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("trophee★", "★", _GenMK), "🏆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("trophée★", "★", _GenMK), "🏆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("trophy★", "★", _GenMK), "🏆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("telephone★", "★", _GenMK), "☎️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("téléphone★", "★", _GenMK), "☎️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("train★", "★", _GenMK), "🚂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("vélo★", "★", _GenMK), "🚲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("voiture★", "★", _GenMK), "🚗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("yeux★", "★", _GenMK), "👀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ananas★", "★", _GenMK), "🍍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("aubergine★", "★", _GenMK), "🍆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("avocat★", "★", _GenMK), "🥑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("banane★", "★", _GenMK), "🍌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("bière★", "★", _GenMK), "🍺", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("brocoli★", "★", _GenMK), "🥦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("burger★", "★", _GenMK), "🍔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("café★", "★", _GenMK), "☕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("carotte★", "★", _GenMK), "🥕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cerise★", "★", _GenMK), "🍒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("champignon★", "★", _GenMK), "🍄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("chocolat★", "★", _GenMK), "🍫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("citron★", "★", _GenMK), "🍋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("coco★", "★", _GenMK), "🥥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cookie★", "★", _GenMK), "🍪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("croissant★", "★", _GenMK), "🥐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("donut★", "★", _GenMK), "🍩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fraise★", "★", _GenMK), "🍓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("frites★", "★", _GenMK), "🍟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fromage★", "★", _GenMK), "🧀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("gâteau★", "★", _GenMK), "🎂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("glace★", "★", _GenMK), "🍦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("hamburger★", "★", _GenMK), "🍔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("hotdog★", "★", _GenMK), "🌭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("kebab★", "★", _GenMK), "🥙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("kiwi★", "★", _GenMK), "🥝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("lait★", "★", _GenMK), "🥛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("maïs★", "★", _GenMK), "🌽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("melon★", "★", _GenMK), "🍈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("miel★", "★", _GenMK), "🍯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("orange★", "★", _GenMK), "🍊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pain★", "★", _GenMK), "🍞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pastèque★", "★", _GenMK), "🍉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pates★", "★", _GenMK), "🍝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pêche★", "★", _GenMK), "🍑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pizza★", "★", _GenMK), "🍕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("poire★", "★", _GenMK), "🍐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pomme★", "★", _GenMK), "🍎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("popcorn★", "★", _GenMK), "🍿", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("raisin★", "★", _GenMK), "🍇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("riz★", "★", _GenMK), "🍚", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("salade★", "★", _GenMK), "🥗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("sandwich★", "★", _GenMK), "🥪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("spaghetti★", "★", _GenMK), "🍝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("taco★", "★", _GenMK), "🌮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("tacos★", "★", _GenMK), "🌮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("thé★", "★", _GenMK), "🍵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("tomate★", "★", _GenMK), "🍅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("vin★", "★", _GenMK), "🍷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("amour★", "★", _GenMK), "🥰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ange★", "★", _GenMK), "👼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("bisou★", "★", _GenMK), "😘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("bouche★", "★", _GenMK), "🤭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("caca★", "★", _GenMK), "💩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("clap★", "★", _GenMK), "👏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("clin★", "★", _GenMK), "😉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cœur★", "★", _GenMK), "❤️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("coeur★", "★", _GenMK), "❤️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("colère★", "★", _GenMK), "😠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("cowboy★", "★", _GenMK), "🤠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("dégoût★", "★", _GenMK), "🤮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("délice★", "★", _GenMK), "😋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("délicieux★", "★", _GenMK), "😋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("diable★", "★", _GenMK), "😈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("dislike★", "★", _GenMK), "👎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("dodo★", "★", _GenMK), "😴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("effroi★", "★", _GenMK), "😱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("facepalm★", "★", _GenMK), "🤦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fatigue★", "★", _GenMK), "😩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fier★", "★", _GenMK), "😤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fort★", "★", _GenMK), "💪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("fou★", "★", _GenMK), "🤪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("heureux★", "★", _GenMK), "😊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("innocent★", "★", _GenMK), "😇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("intello★", "★", _GenMK), "🤓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("larme★", "★", _GenMK), "😢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("larmes★", "★", _GenMK), "😭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("like★", "★", _GenMK), "👍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("lol★", "★", _GenMK), "😂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("lunettes★", "★", _GenMK), "🤓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("malade★", "★", _GenMK), "🤒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("masque★", "★", _GenMK), "😷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("mdr★", "★", _GenMK), "😂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("mignon★", "★", _GenMK), "🥺", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("monocle★", "★", _GenMK), "🧐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("mort★", "★", _GenMK), "💀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("muscles★", "★", _GenMK), "💪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("(n)★", "★", _GenMK), "👎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("nice★", "★", _GenMK), "👌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ouf★", "★", _GenMK), "😅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("oups★", "★", _GenMK), "😅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("parfait★", "★", _GenMK), "👌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("penser★", "★", _GenMK), "🤔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pensif★", "★", _GenMK), "🤔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("peur★", "★", _GenMK), "😨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pleur★", "★", _GenMK), "😭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pleurer★", "★", _GenMK), "😭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("pouce★", "★", _GenMK), "👍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("rage★", "★", _GenMK), "😡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("rire★", "★", _GenMK), "😂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("silence★", "★", _GenMK), "🤫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("snif★", "★", _GenMK), "😢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("stress★", "★", _GenMK), "😰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("strong★", "★", _GenMK), "💪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("surprise★", "★", _GenMK), "😲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("timide★", "★", _GenMK), "😳", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("triste★", "★", _GenMK), "😢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("victoire★", "★", _GenMK), "✌️", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("(y)★", "★", _GenMK), "👍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("zombie★", "★", _GenMK), "🧟", Opts)
}

_GenLoad_magickey_textexpansionsymbols(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/★", "★", _GenMK), "⅟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/2★", "★", _GenMK), "½", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("0/3★", "★", _GenMK), "↉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/3★", "★", _GenMK), "⅓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("2/3★", "★", _GenMK), "⅔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/4★", "★", _GenMK), "¼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("3/4★", "★", _GenMK), "¾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/5★", "★", _GenMK), "⅕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("2/5★", "★", _GenMK), "⅖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("3/5★", "★", _GenMK), "⅗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("4/5★", "★", _GenMK), "⅘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/6★", "★", _GenMK), "⅙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("5/6★", "★", _GenMK), "⅚", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/8★", "★", _GenMK), "⅛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("3/8★", "★", _GenMK), "⅜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("5/8★", "★", _GenMK), "⅝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("7/8★", "★", _GenMK), "⅞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/7★", "★", _GenMK), "⅐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/9★", "★", _GenMK), "⅑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("1/10★", "★", _GenMK), "⅒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(0)★", "★", _GenMK), "🄋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(1)★", "★", _GenMK), "➀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(2)★", "★", _GenMK), "➁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(3)★", "★", _GenMK), "➂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(4)★", "★", _GenMK), "➃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(5)★", "★", _GenMK), "➄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(6)★", "★", _GenMK), "➅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(7)★", "★", _GenMK), "➆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(8)★", "★", _GenMK), "➇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(9)★", "★", _GenMK), "➈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(10)★", "★", _GenMK), "➉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(0n)★", "★", _GenMK), "🄌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(1n)★", "★", _GenMK), "➊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(2n)★", "★", _GenMK), "➋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(3n)★", "★", _GenMK), "➌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(4n)★", "★", _GenMK), "➍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(5n)★", "★", _GenMK), "➎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(6n)★", "★", _GenMK), "➏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(7n)★", "★", _GenMK), "➐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(8n)★", "★", _GenMK), "➑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(9n)★", "★", _GenMK), "➒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(10n)★", "★", _GenMK), "➓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(0b)★", "★", _GenMK), "𝟎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(1b)★", "★", _GenMK), "𝟏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(2b)★", "★", _GenMK), "𝟐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(3b)★", "★", _GenMK), "𝟑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(4b)★", "★", _GenMK), "𝟒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(5b)★", "★", _GenMK), "𝟓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(6b)★", "★", _GenMK), "𝟔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(7b)★", "★", _GenMK), "𝟕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(8b)★", "★", _GenMK), "𝟖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(9b)★", "★", _GenMK), "𝟗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(0g)★", "★", _GenMK), "𝟬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(1g)★", "★", _GenMK), "𝟭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(2g)★", "★", _GenMK), "𝟮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(3g)★", "★", _GenMK), "𝟯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(4g)★", "★", _GenMK), "𝟰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(5g)★", "★", _GenMK), "𝟱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(6g)★", "★", _GenMK), "𝟲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(7g)★", "★", _GenMK), "𝟳", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(8g)★", "★", _GenMK), "𝟴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(9g)★", "★", _GenMK), "𝟵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(infini)★", "★", _GenMK), "∞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(product)★", "★", _GenMK), "∏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(produit)★", "★", _GenMK), "∏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(coproduct)★", "★", _GenMK), "∐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(coproduit)★", "★", _GenMK), "∐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(forall)★", "★", _GenMK), "∀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(for all)★", "★", _GenMK), "∀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(pour tout)★", "★", _GenMK), "∀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(exist)★", "★", _GenMK), "∃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(exists)★", "★", _GenMK), "∃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(vide)★", "★", _GenMK), "∅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(ensemble vide)★", "★", _GenMK), "∅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(void)★", "★", _GenMK), "∅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(empty)★", "★", _GenMK), "∅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(prop)★", "★", _GenMK), "∝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(proportionnel)★", "★", _GenMK), "∝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(proportionnal)★", "★", _GenMK), "∝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(union)★", "★", _GenMK), "∪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(intersection)★", "★", _GenMK), "⋂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(appartient)★", "★", _GenMK), "∈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(inclus)★", "★", _GenMK), "⊂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(non inclus)★", "★", _GenMK), "⊄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(non appartient)★", "★", _GenMK), "∉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(n’appartient pas)★", "★", _GenMK), "∉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(non)★", "★", _GenMK), "¬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(et)★", "★", _GenMK), "∧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(sqrt)★", "★", _GenMK), "√", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(racine)★", "★", _GenMK), "√", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(^)★", "★", _GenMK), "∧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(delta)★", "★", _GenMK), "∆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(nabla)★", "★", _GenMK), "∇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(<<)★", "★", _GenMK), "≪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(partial)★", "★", _GenMK), "∂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(end of proof)★", "★", _GenMK), "∎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(eop)★", "★", _GenMK), "∎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(int)★", "★", _GenMK), "∫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(s)★", "★", _GenMK), "∫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(so)★", "★", _GenMK), "∮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(sso)★", "★", _GenMK), "∯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(sss)★", "★", _GenMK), "∭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(ssso)★", "★", _GenMK), "∰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(=)★", "★", _GenMK), "≡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(equivalent)★", "★", _GenMK), "⇔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(équivalent)★", "★", _GenMK), "⇔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(implique)★", "★", _GenMK), "⇒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(impliqué)★", "★", _GenMK), "⇒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(imply)★", "★", _GenMK), "⇒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(non implique)★", "★", _GenMK), "⇏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(non impliqué)★", "★", _GenMK), "⇏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(non équivalent)★", "★", _GenMK), "⇎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(not equivalent)★", "★", _GenMK), "⇎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace(" -> ★", "★", _GenMK), " ➜ ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("-->★", "★", _GenMK), " ➜ ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace(">★", "★", _GenMK), "➢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("==>★", "★", _GenMK), "⇒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("=/=>★", "★", _GenMK), "⇏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("<==★", "★", _GenMK), "⇐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("<==>★", "★", _GenMK), "⇔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("<=/=>★", "★", _GenMK), "⇎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("<=>★", "★", _GenMK), "⇔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("^|★", "★", _GenMK), "↑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("|^★", "★", _GenMK), "↓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("->★", "★", _GenMK), "→", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("<-★", "★", _GenMK), "←", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("->>★", "★", _GenMK), "➡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("<<-★", "★", _GenMK), "⬅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("|->★", "★", _GenMK), "↪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("<-|★", "★", _GenMK), "↩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("^|-★", "★", _GenMK), "⭮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(v)★", "★", _GenMK), "✓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(x)★", "★", _GenMK), "✗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("[v]★", "★", _GenMK), "☑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("[x]★", "★", _GenMK), "☒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("/!\★", "★", _GenMK), "⚠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("**★", "★", _GenMK), "⁂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("°C★", "★", _GenMK), "℃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(b)★", "★", _GenMK), "•", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(c)★", "★", _GenMK), "©", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("eme★", "★", _GenMK), "ᵉ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ème★", "★", _GenMK), "ᵉ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ieme★", "★", _GenMK), "ᵉ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", StrReplace("ième★", "★", _GenMK), "ᵉ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(o)★", "★", _GenMK), "•", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(r)★", "★", _GenMK), "®", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", StrReplace("(tm)★", "★", _GenMK), "™", Opts)
}

_GenLoad_magickey_textexpansionsymbolstypst(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$wj$", "{U+2060}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$zwj$", "{U+200D}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$zwnj$", "{U+200C}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$zws$", "{U+200B}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lrm$", "{U+200E}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rlm$", "{U+200F}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space$", "{U+0020}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.nobreak$", "{U+00A0}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.nobreak.narrow$", "{U+202F}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.en$", "{U+2002}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.quad$", "{U+2003}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.third$", "{U+2004}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.quarter$", "{U+2005}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.sixth$", "{U+2006}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.med$", "{U+205F}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.fig$", "{U+2007}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.punct$", "{U+2008}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.thin$", "{U+2009}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$space.hair$", "{U+200A}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.l$", "(", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.l.flat$", "⟮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.l.closed$", "⦇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.l.stroked$", "⦅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.l.double$", "⦅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.r$", ")", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.r.flat$", "⟯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.r.closed$", "⦈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.r.stroked$", "⦆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.r.double$", "⦆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.t$", "⏜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$paren.b$", "⏝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$brace.l$", "{", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$brace.l.stroked$", "{U+27C3}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$brace.l.double$", "{U+27C3}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$brace.r$", "}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$brace.r.stroked$", "⦄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$brace.r.double$", "⦄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$brace.t$", "⏞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$brace.b$", "⏟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.l$", "[", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.l.tick.t$", "⦍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.l.tick.b$", "⦏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.l.stroked$", "⟦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.l.double$", "⟦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.r$", "]", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.r.tick.t$", "⦐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.r.tick.b$", "⦎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.r.stroked$", "⟧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.r.double$", "⟧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.t$", "⎴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bracket.b$", "⎵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.l$", "❲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.l.stroked$", "⟬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.l.filled$", "⦗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.l.double$", "⟬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.r$", "❳", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.r.stroked$", "⟭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.r.filled$", "⦘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.r.double$", "⟭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.t$", "⏠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shell.b$", "⏡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bag.l$", "⟅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bag.r$", "⟆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$mustache.l$", "⎰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$mustache.r$", "⎱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bar.v$", "|", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bar.v.double$", "‖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bar.v.triple$", "⦀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bar.v.broken$", "¦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bar.v.o$", "⦶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bar.v.circle$", "⦶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bar.h$", "―", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$fence.l$", "⧘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$fence.l.double$", "⧚", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$fence.r$", "⧙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$fence.r.double$", "⧛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$fence.dotted$", "⦙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.l$", "⟨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.l.curly$", "⧼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.l.dot$", "⦑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.l.closed$", "⦉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.l.double$", "⟪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.r$", "⟩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.r.curly$", "⧽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.r.dot$", "⦒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.r.closed$", "⦊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chevron.r.double$", "⟫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ceil.l$", "⌈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ceil.r$", "⌉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$floor.l$", "⌊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$floor.r$", "⌋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$corner.l.t$", "⌜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$corner.l.b$", "⌞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$corner.r.t$", "⌝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$corner.r.b$", "⌟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$amp$", "&", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$amp.inv$", "⅋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.op$", "∗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.op.o$", "⊛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.basic$", "*", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.low$", "⁎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.double$", "⁑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.triple$", "⁂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.small$", "﹡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.circle$", "⊛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ast.square$", "⧆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", true)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$at$", "@", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$backslash$", "\", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$backslash.o$", "⦸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$backslash.circle$", "⦸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$backslash.not$", "⧷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$co$", "℅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$colon$", ":", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$colon.currency$", "₡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$colon.double$", "∷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$colon.tri$", "⁝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$colon.tri.op$", "⫶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$colon.eq$", "≔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$colon.double.eq$", "⩴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$comma$", ",", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$comma.inv$", "⸲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$comma.rev$", "⹁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dagger$", "†", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dagger.double$", "‡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dagger.triple$", "⹋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dagger.l$", "⸶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dagger.r$", "⸷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dagger.inv$", "⸸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.en$", "–", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.em$", "—", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.em.two$", "⸺", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.em.three$", "⸻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.fig$", "‒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.wave$", "〜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.colon$", "∹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.o$", "⊝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.circle$", "⊝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dash.wave.double$", "〰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.op$", "⋅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.basic$", ".", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.c$", "·", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.o$", "⊙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.o.big$", "⨀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.circle$", "⊙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.circle.big$", "⨀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.square$", "⊡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.double$", "¨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.triple$", "{U+20DB}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dot.quad$", "{U+20DC}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$excl$", "!", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$excl.double$", "‼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$excl.inv$", "¡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$excl.quest$", "⁉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quest$", "?", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quest.double$", "⁇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quest.excl$", "⁈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quest.inv$", "¿", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$interrobang$", "‽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$interrobang.inv$", "⸘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hash$", "#", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hyph$", "‐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hyph.minus$", "-", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hyph.nobreak$", "{U+2011}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hyph.point$", "‧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hyph.soft$", "{U+00AD}", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$numero$", "№", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$percent$", "%", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$permille$", "‰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$permyriad$", "‱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$pilcrow$", "¶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$pilcrow.rev$", "⁋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$section$", "§", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$semi$", "`;", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$semi.inv$", "⸵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$semi.rev$", "⁏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$slash$", "/", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$slash.o$", "⊘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$slash.double$", "⫽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$slash.triple$", "⫻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$slash.big$", "⧸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dots.h.c$", "⋯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dots.h$", "…", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dots.v$", "⋮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dots.down$", "⋱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dots.up$", "⋰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.op$", "∼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.basic$", "~", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.dot$", "⩪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.eq$", "≃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.eq.not$", "≄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.eq.rev$", "⋍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.equiv$", "≅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.equiv.not$", "≇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.nequiv$", "≆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.not$", "≁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.rev$", "∽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.rev.equiv$", "≌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tilde.triple$", "≋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$acute$", "´", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$acute.double$", "˝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$breve$", "˘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$caret$", "‸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$caron$", "ˇ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hat$", "^", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diaer$", "¨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$grave$", "``", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$macron$", "¯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.double$", "`"", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.single$", "'", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.l.double$", "“", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.l.single$", "‘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.r.double$", "”", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.r.single$", "’", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.chevron.l.double$", "«", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.chevron.l.single$", "‹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.chevron.r.double$", "»", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.chevron.r.single$", "›", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.angle.l.double$", "«", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.angle.l.single$", "‹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.angle.r.double$", "»", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.angle.r.single$", "›", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.high.double$", "‟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.high.single$", "‛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.low.double$", "„", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$quote.low.single$", "‚", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prime$", "′", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prime.rev$", "‵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prime.double$", "″", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prime.double.rev$", "‶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prime.triple$", "‴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prime.triple.rev$", "‷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prime.quad$", "⁗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus$", "+", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.o$", "⊕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.o.l$", "⨭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.o.r$", "⨮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.o.arrow$", "⟴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.o.big$", "⨁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.circle$", "⊕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.circle.arrow$", "⟴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.circle.big$", "⨁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.dot$", "∔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.double$", "⧺", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.minus$", "±", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.small$", "﹢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.square$", "⊞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.triangle$", "⨹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$plus.triple$", "⧻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$minus$", "−", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$minus.o$", "⊖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$minus.circle$", "⊖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$minus.dot$", "∸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$minus.plus$", "∓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$minus.square$", "⊟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$minus.tilde$", "≂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$minus.triangle$", "⨺", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$div$", "÷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$div.o$", "⨸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$div.slanted.o$", "⦼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$div.circle$", "⨸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times$", "×", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.big$", "⨉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.o$", "⊗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.o.l$", "⨴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.o.r$", "⨵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.o.hat$", "⨶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.o.big$", "⨂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.circle$", "⊗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.circle.big$", "⨂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.div$", "⋇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.three.l$", "⋋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.three.r$", "⋌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.l$", "⋉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.r$", "⋊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.square$", "⊠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$times.triangle$", "⨻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ratio$", "∶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq$", "=", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.star$", "≛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.o$", "⊜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.circle$", "⊜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.colon$", "≕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.dots$", "≑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.dots.down$", "≒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.dots.up$", "≓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.def$", "≝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.delta$", "≜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.equi$", "≚", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.est$", "≙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.gt$", "⋝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.lt$", "⋜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.m$", "≞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.not$", "≠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.prec$", "⋞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.quest$", "≟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.small$", "﹦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.succ$", "⋟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.triple$", "≡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.triple.not$", "≢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eq.quad$", "≣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt$", ">", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.o$", "⧁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.circle$", "⧁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.dot$", "⋗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.approx$", "⪆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.double$", "≫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.eq$", "≥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.eq.slant$", "⩾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.eq.lt$", "⋛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.eq.not$", "≱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.equiv$", "≧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.lt$", "≷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.lt.not$", "≹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.neq$", "⪈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.napprox$", "⪊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.nequiv$", "≩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.not$", "≯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.ntilde$", "⋧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.small$", "﹥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.tilde$", "≳", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.tilde.not$", "≵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.tri$", "⊳", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.tri.eq$", "⊵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.tri.eq.not$", "⋭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.tri.not$", "⋫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.triple$", "⋙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gt.triple.nested$", "⫸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt$", "<", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.o$", "⧀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.circle$", "⧀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.dot$", "⋖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.approx$", "⪅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.double$", "≪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.eq$", "≤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.eq.slant$", "⩽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.eq.gt$", "⋚", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.eq.not$", "≰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.equiv$", "≦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.gt$", "≶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.gt.not$", "≸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.neq$", "⪇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.napprox$", "⪉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.nequiv$", "≨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.not$", "≮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.ntilde$", "⋦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.small$", "﹤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.tilde$", "≲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.tilde.not$", "≴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.tri$", "⊲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.tri.eq$", "⊴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.tri.eq.not$", "⋬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.tri.not$", "⋪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.triple$", "⋘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lt.triple.nested$", "⫷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$approx$", "≈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$approx.eq$", "≊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$approx.not$", "≉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec$", "≺", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.approx$", "⪷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.curly.eq$", "≼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.curly.eq.not$", "⋠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.double$", "⪻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.eq$", "⪯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.equiv$", "⪳", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.napprox$", "⪹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.neq$", "⪱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.nequiv$", "⪵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.not$", "⊀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.ntilde$", "⋨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prec.tilde$", "≾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ$", "≻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.approx$", "⪸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.curly.eq$", "≽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.curly.eq.not$", "⋡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.double$", "⪼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.eq$", "⪰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.equiv$", "⪴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.napprox$", "⪺", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.neq$", "⪲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.nequiv$", "⪶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.not$", "⊁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.ntilde$", "⋩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$succ.tilde$", "≿", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$equiv$", "≡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$equiv.not$", "≢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$smt$", "⪪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$smt.eq$", "⪬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lat$", "⪫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lat.eq$", "⪭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$prop$", "∝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$original$", "⊶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$image$", "⊷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$asymp$", "≍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$asymp.not$", "≭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$emptyset$", "∅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$emptyset.arrow.r$", "⦳", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$emptyset.arrow.l$", "⦴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$emptyset.bar$", "⦱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$emptyset.circle$", "⦲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$emptyset.rev$", "⦰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$nothing$", "∅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$nothing.arrow.r$", "⦳", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$nothing.arrow.l$", "⦴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$nothing.bar$", "⦱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$nothing.circle$", "⦲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$nothing.rev$", "⦰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$without$", "∖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$complement$", "∁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$in$", "∈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$in.not$", "∉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$in.rev$", "∋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$in.rev.not$", "∌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$in.rev.small$", "∍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$in.small$", "∊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset$", "⊂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.dot$", "⪽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.double$", "⋐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.eq$", "⊆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.eq.not$", "⊈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.eq.sq$", "⊑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.eq.sq.not$", "⋢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.neq$", "⊊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.not$", "⊄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.sq$", "⊏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$subset.sq.neq$", "⋤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset$", "⊃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.dot$", "⪾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.double$", "⋑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.eq$", "⊇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.eq.not$", "⊉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.eq.sq$", "⊒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.eq.sq.not$", "⋣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.neq$", "⊋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.not$", "⊅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.sq$", "⊐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$supset.sq.neq$", "⋥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union$", "∪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.arrow$", "⊌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.big$", "⋃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.dot$", "⊍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.dot.big$", "⨃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.double$", "⋓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.minus$", "⩁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.or$", "⩅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.plus$", "⊎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.plus.big$", "⨄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.sq$", "⊔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.sq.big$", "⨆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$union.sq.double$", "⩏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$inter$", "∩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$inter.and$", "⩄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$inter.big$", "⋂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$inter.dot$", "⩀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$inter.double$", "⋒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$inter.sq$", "⊓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$inter.sq.big$", "⨅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$inter.sq.double$", "⩎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sect$", "∩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sect.and$", "⩄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sect.big$", "⋂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sect.dot$", "⩀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sect.double$", "⋒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sect.sq$", "⊓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sect.sq.big$", "⨅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sect.sq.double$", "⩎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$infinity$", "∞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$infinity.bar$", "⧞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$infinity.incomplete$", "⧜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$infinity.tie$", "⧝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$oo$", "∞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diff$", "∂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$partial$", "∂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gradient$", "∇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$nabla$", "∇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sum$", "∑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sum.integral$", "⨋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$product$", "∏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$product.co$", "∐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral$", "∫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.arrow.hook$", "⨗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.ccw$", "⨑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.cont$", "∮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.cont.ccw$", "∳", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.cont.cw$", "∲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.cw$", "∱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.dash$", "⨍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.dash.double$", "⨎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.double$", "∬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.quad$", "⨌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.inter$", "⨙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.sect$", "⨙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.slash$", "⨏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.square$", "⨖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.surf$", "∯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.times$", "⨘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.triple$", "∭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.union$", "⨚", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$integral.vol$", "∰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$laplace$", "∆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$forall$", "∀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$exists$", "∃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$exists.not$", "∄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$top$", "⊤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bot$", "⊥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$not$", "¬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$and$", "∧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$and.big$", "⋀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$and.curly$", "⋏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$and.dot$", "⟑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$and.double$", "⩓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$or$", "∨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$or.big$", "⋁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$or.curly$", "⋎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$or.dot$", "⟇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$or.double$", "⩔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$xor$", "⊕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$xor.big$", "⨁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$models$", "⊧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$forces$", "⊩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$forces.not$", "⊮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$therefore$", "∴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$because$", "∵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$qed$", "∎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$mapsto$", "↦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$mapsto.long$", "⟼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$compose$", "∘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$compose.o$", "⊚", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$convolve$", "∗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$convolve.o$", "⊛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$multimap$", "⊸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$multimap.double$", "⧟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tiny$", "⧾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$miny$", "⧿", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$divides$", "∣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$divides.not$", "∤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$divides.not.rev$", "⫮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$divides.struck$", "⟊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$wreath$", "≀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle$", "∠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.l$", "⟨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.l.curly$", "⧼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.l.dot$", "⦑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.l.double$", "⟪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.r$", "⟩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.r.curly$", "⧽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.r.dot$", "⦒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.r.double$", "⟫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.acute$", "⦟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.arc$", "∡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.arc.rev$", "⦛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.azimuth$", "⍼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.oblique$", "⦦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.rev$", "⦣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.right$", "∟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.right.rev$", "⯾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.right.arc$", "⊾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.right.dot$", "⦝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.right.sq$", "⦜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.s$", "⦞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.spatial$", "⟀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.spheric$", "∢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.spheric.rev$", "⦠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.spheric.t$", "⦡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angle.spheric.top$", "⦡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angzarr$", "⍼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel$", "∥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.struck$", "⫲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.o$", "⦷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.circle$", "⦷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.eq$", "⋕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.equiv$", "⩨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.not$", "∦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.slanted.eq$", "⧣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.slanted.eq.tilde$", "⧤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.slanted.equiv$", "⧥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallel.tilde$", "⫳", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$perp$", "⟂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$perp.o$", "⦹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$perp.circle$", "⦹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$earth$", "🜨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$earth.alt$", "♁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$jupiter$", "♃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$mars$", "♂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$mercury$", "☿", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$neptune$", "♆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$neptune.alt$", "⯉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$saturn$", "♄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sun$", "☉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$uranus$", "⛢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$uranus.alt$", "♅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$venus$", "♀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diameter$", "⌀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$interleave$", "⫴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$interleave.big$", "⫼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$interleave.struck$", "⫵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$join$", "⨝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$join.r$", "⟖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$join.l$", "⟕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$join.l.r$", "⟗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hourglass.stroked$", "⧖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hourglass.filled$", "⧗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$degree$", "°", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$smash$", "⨳", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$power.standby$", "⏻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$power.on$", "⏽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$power.off$", "⭘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$power.on.off$", "⏼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$power.sleep$", "⏾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$smile$", "⌣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$frown$", "⌢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$afghani$", "؋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$baht$", "฿", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bitcoin$", "₿", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cedi$", "₵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cent$", "¢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$currency$", "¤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dollar$", "$", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dong$", "₫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dorome$", "߾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dram$", "֏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$euro$", "€", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$franc$", "₣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$guarani$", "₲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hryvnia$", "₴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$kip$", "₭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lari$", "₾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lira$", "₺", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$manat$", "₼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$naira$", "₦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$pataca$", "$", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$peso$", "$", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$peso.philippine$", "₱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$pound$", "£", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$riel$", "៛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ruble$", "₽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rupee.indian$", "₹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rupee.generic$", "₨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rupee.tamil$", "௹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rupee.wancho$", "𞋿", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shekel$", "₪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$som$", "⃀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$taka$", "৳", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$taman$", "߿", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tenge$", "₸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$togrog$", "₮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$won$", "₩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$yen$", "¥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$yuan$", "¥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ballot$", "☐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ballot.cross$", "☒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ballot.check$", "☑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ballot.check.heavy$", "🗹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$checkmark$", "✓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$checkmark.light$", "🗸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$checkmark.heavy$", "✔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$crossmark$", "✗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$crossmark.heavy$", "✘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$floral$", "❦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$floral.l$", "☙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$floral.r$", "❧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$refmark$", "※", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cc$", "🅭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cc.by$", "🅯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cc.nc$", "🄏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cc.nd$", "⊜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cc.public$", "🅮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cc.sa$", "🄎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$cc.zero$", "🄍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$copyright$", "©", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$copyright.sound$", "℗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$copyleft$", "🄯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$trademark$", "™", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$trademark.registered$", "®", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$trademark.service$", "℠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$maltese$", "✠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$suit.club.filled$", "♣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$suit.club.stroked$", "♧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$suit.diamond.filled$", "♦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$suit.diamond.stroked$", "♢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$suit.heart.filled$", "♥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$suit.heart.stroked$", "♡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$suit.spade.filled$", "♠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$suit.spade.stroked$", "♤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.up$", "🎜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.down$", "🎝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.whole$", "𝅝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.half$", "𝅗𝅥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.quarter$", "𝅘𝅥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.quarter.alt$", "♩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.eighth$", "𝅘𝅥𝅮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.eighth.alt$", "♪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.eighth.beamed$", "♫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.sixteenth$", "𝅘𝅥𝅯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.sixteenth.beamed$", "♬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.grace$", "𝆕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$note.grace.slash$", "𝆔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rest.whole$", "𝄻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rest.multiple$", "𝄺", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rest.multiple.measure$", "𝄩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rest.half$", "𝄼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rest.quarter$", "𝄽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rest.eighth$", "𝄾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rest.sixteenth$", "𝄿", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$natural$", "♮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$natural.t$", "𝄮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$natural.b$", "𝄯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$flat$", "♭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$flat.t$", "𝄬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$flat.b$", "𝄭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$flat.double$", "𝄫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$flat.quarter$", "𝄳", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sharp$", "♯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sharp.t$", "𝄰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sharp.b$", "𝄱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sharp.double$", "𝄪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sharp.quarter$", "𝄲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet$", "•", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.op$", "∙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.o$", "⦿", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.stroked$", "◦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.stroked.o$", "⦾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.hole$", "◘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.hyph$", "⁃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.tri$", "‣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.l$", "⁌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bullet.r$", "⁍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.stroked$", "○", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.stroked.tiny$", "∘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.stroked.small$", "⚬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.stroked.big$", "◯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.filled$", "●", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.filled.tiny$", "⦁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.filled.small$", "∙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.filled.big$", "⬤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.dotted$", "◌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$circle.nested$", "⊚", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ellipse.stroked.h$", "⬭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ellipse.stroked.v$", "⬯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ellipse.filled.h$", "⬬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ellipse.filled.v$", "⬮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.t$", "△", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.b$", "▽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.r$", "▷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.l$", "◁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.bl$", "◺", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.br$", "◿", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.tl$", "◸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.tr$", "◹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.small.t$", "▵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.small.b$", "▿", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.small.r$", "▹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.small.l$", "◃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.rounded$", "🛆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.nested$", "⟁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.stroked.dot$", "◬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.t$", "▲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.b$", "▼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.r$", "▶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.l$", "◀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.bl$", "◣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.br$", "◢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.tl$", "◤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.tr$", "◥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.small.t$", "▴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.small.b$", "▾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.small.r$", "▸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$triangle.filled.small.l$", "◂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.stroked$", "□", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.stroked.tiny$", "▫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.stroked.small$", "◽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.stroked.medium$", "◻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.stroked.big$", "⬜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.stroked.dotted$", "⬚", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.stroked.rounded$", "▢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.filled$", "■", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.filled.tiny$", "▪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.filled.small$", "◾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.filled.medium$", "◼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$square.filled.big$", "⬛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rect.stroked.h$", "▭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rect.stroked.v$", "▯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rect.filled.h$", "▬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rect.filled.v$", "▮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$penta.stroked$", "⬠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$penta.filled$", "⬟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hexa.stroked$", "⬡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$hexa.filled$", "⬢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diamond.stroked$", "◇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diamond.stroked.small$", "⋄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diamond.stroked.medium$", "⬦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diamond.stroked.dot$", "⟐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diamond.filled$", "◆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diamond.filled.medium$", "⬥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$diamond.filled.small$", "⬩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lozenge.stroked$", "◊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lozenge.stroked.small$", "⬫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lozenge.stroked.medium$", "⬨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lozenge.filled$", "⧫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lozenge.filled.small$", "⬪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lozenge.filled.medium$", "⬧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallelogram.stroked$", "▱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$parallelogram.filled$", "▰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$star.op$", "⋆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$star.stroked$", "☆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$star.filled$", "★", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r$", "→", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.long.bar$", "⟼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.bar$", "↦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.curve$", "⤷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.turn$", "⮎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.dashed$", "⇢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.dotted$", "⤑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.double$", "⇒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.double.bar$", "⤇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.double.long$", "⟹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.double.long.bar$", "⟾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.double.not$", "⇏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.double.struck$", "⤃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.filled$", "➡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.hook$", "↪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.long$", "⟶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.long.squiggly$", "⟿", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.loop$", "↬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.not$", "↛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.quad$", "⭆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.squiggly$", "⇝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.stop$", "⇥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.stroked$", "⇨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.struck$", "⇸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.dstruck$", "⇻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.tail$", "↣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.tail.struck$", "⤔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.tail.dstruck$", "⤕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.tilde$", "⥲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.triple$", "⇛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.twohead$", "↠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.twohead.bar$", "⤅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.twohead.struck$", "⤀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.twohead.dstruck$", "⤁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.twohead.tail$", "⤖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.twohead.tail.struck$", "⤗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.twohead.tail.dstruck$", "⤘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.open$", "⇾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.r.wave$", "↝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l$", "←", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.bar$", "↤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.curve$", "⤶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.turn$", "⮌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.dashed$", "⇠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.dotted$", "⬸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.double$", "⇐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.double.bar$", "⤆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.double.long$", "⟸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.double.long.bar$", "⟽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.double.not$", "⇍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.double.struck$", "⤂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.filled$", "⬅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.hook$", "↩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.long$", "⟵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.long.bar$", "⟻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.long.squiggly$", "⬳", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.loop$", "↫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.not$", "↚", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.quad$", "⭅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.squiggly$", "⇜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.stop$", "⇤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.stroked$", "⇦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.struck$", "⇷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.dstruck$", "⇺", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.tail$", "↢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.tail.struck$", "⬹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.tail.dstruck$", "⬺", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.tilde$", "⭉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.triple$", "⇚", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.twohead$", "↞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.twohead.bar$", "⬶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.twohead.struck$", "⬴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.twohead.dstruck$", "⬵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.twohead.tail$", "⬻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.twohead.tail.struck$", "⬼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.twohead.tail.dstruck$", "⬽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.open$", "⇽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.wave$", "↜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t$", "↑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.bar$", "↥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.curve$", "⤴", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.turn$", "⮍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.dashed$", "⇡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.double$", "⇑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.filled$", "⬆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.quad$", "⟰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.stop$", "⤒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.stroked$", "⇧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.struck$", "⤉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.dstruck$", "⇞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.triple$", "⤊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.twohead$", "↟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b$", "↓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.bar$", "↧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.curve$", "⤵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.turn$", "⮏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.dashed$", "⇣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.double$", "⇓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.filled$", "⬇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.quad$", "⟱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.stop$", "⤓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.stroked$", "⇩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.struck$", "⤈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.dstruck$", "⇟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.triple$", "⤋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.b.twohead$", "↡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r$", "↔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.double$", "⇔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.double.long$", "⟺", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.double.not$", "⇎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.double.struck$", "⤄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.filled$", "⬌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.long$", "⟷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.not$", "↮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.stroked$", "⬄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.struck$", "⇹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.dstruck$", "⇼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.open$", "⇿", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.l.r.wave$", "↭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.b$", "↕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.b.double$", "⇕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.b.filled$", "⬍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.t.b.stroked$", "⇳", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tr$", "↗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tr.double$", "⇗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tr.filled$", "⬈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tr.hook$", "⤤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tr.stroked$", "⬀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.br$", "↘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.br.double$", "⇘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.br.filled$", "⬊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.br.hook$", "⤥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.br.stroked$", "⬂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tl$", "↖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tl.double$", "⇖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tl.filled$", "⬉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tl.hook$", "⤣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tl.stroked$", "⬁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.bl$", "↙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.bl.double$", "⇙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.bl.filled$", "⬋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.bl.hook$", "⤦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.bl.stroked$", "⬃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tl.br$", "⤡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.tr.bl$", "⥢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.ccw$", "↺", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.ccw.half$", "↶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.cw$", "↻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.cw.half$", "↷", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrow.zigzag$", "↯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.rr$", "⇉", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.ll$", "⇇", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.tt$", "⇈", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.bb$", "⇊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.lr$", "⇆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.lr.stop$", "↹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.rl$", "⇄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.tb$", "⇅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.bt$", "⇵", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.rrr$", "⇶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrows.lll$", "⬱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrowhead.t$", "⌃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$arrowhead.b$", "⌄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.rt$", "⇀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.rt.bar$", "⥛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.rt.stop$", "⥓", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.rb$", "⇁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.rb.bar$", "⥟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.rb.stop$", "⥗", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lt$", "↼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lt.bar$", "⥚", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lt.stop$", "⥒", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lb$", "↽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lb.bar$", "⥞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lb.stop$", "⥖", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tl$", "↿", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tl.bar$", "⥠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tl.stop$", "⥘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tr$", "↾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tr.bar$", "⥜", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tr.stop$", "⥔", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.bl$", "⇃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.bl.bar$", "⥡", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.bl.stop$", "⥙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.br$", "⇂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.br.bar$", "⥝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.br.stop$", "⥕", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lt.rt$", "⥎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lb.rb$", "⥐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lb.rt$", "⥋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.lt.rb$", "⥊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tl.bl$", "⥑", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tr.br$", "⥏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tl.br$", "⥍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoon.tr.bl$", "⥌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.rtrb$", "⥤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.blbr$", "⥥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.bltr$", "⥯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.lbrb$", "⥧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.ltlb$", "⥢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.ltrb$", "⇋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.ltrt$", "⥦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.rblb$", "⥩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.rtlb$", "⇌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.rtlt$", "⥨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.tlbr$", "⥮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$harpoons.tltr$", "⥣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.r$", "⊢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.r.not$", "⊬", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.r.long$", "⟝", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.r.short$", "⊦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.r.double$", "⊨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.r.double.not$", "⊭", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.l$", "⊣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.l.long$", "⟞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.l.short$", "⫞", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.l.double$", "⫤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.t$", "⊥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.t.big$", "⟘", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.t.double$", "⫫", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.t.short$", "⫠", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.b$", "⊤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.b.big$", "⟙", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.b.double$", "⫪", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.b.short$", "⫟", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tack.l.r$", "⟛", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$alpha$", "α", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$beta$", "β", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$beta.alt$", "ϐ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$chi$", "χ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$delta$", "δ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$digamma$", "ϝ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$epsilon$", "ε", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$epsilon.alt$", "ϵ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$epsilon.alt.rev$", "϶", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$eta$", "η", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gamma$", "γ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$iota$", "ι", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$iota.inv$", "℩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$kai$", "ϗ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$kappa$", "κ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$kappa.alt$", "ϰ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$lambda$", "λ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$mu$", "μ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$nu$", "ν", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$omega$", "ω", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$omicron$", "ο", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$phi$", "φ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$phi.alt$", "ϕ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$pi$", "π", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$pi.alt$", "ϖ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$psi$", "ψ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rho$", "ρ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$rho.alt$", "ϱ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sigma$", "σ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sigma.alt$", "ς", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$tau$", "τ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$theta$", "θ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$theta.alt$", "ϑ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$upsilon$", "υ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$xi$", "ξ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$zeta$", "ζ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Alpha$", "Α", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Beta$", "Β", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Chi$", "Χ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Delta$", "Δ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Digamma$", "Ϝ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Epsilon$", "Ε", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Eta$", "Η", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Gamma$", "Γ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Iota$", "Ι", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Kai$", "Ϗ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Kappa$", "Κ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Lambda$", "Λ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Mu$", "Μ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Nu$", "Ν", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Omega$", "Ω", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Omega.inv$", "℧", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Omicron$", "Ο", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Phi$", "Φ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Pi$", "Π", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Psi$", "Ψ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Rho$", "Ρ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Sigma$", "Σ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Tau$", "Τ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Theta$", "Θ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Theta.alt$", "ϴ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Upsilon$", "Υ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Xi$", "Ξ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Zeta$", "Ζ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$sha$", "ш", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Sha$", "Ш", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$aleph$", "א", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$alef$", "א", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$beth$", "ב", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$bet$", "ב", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gimel$", "ג", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gimmel$", "ג", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$daleth$", "ד", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dalet$", "ד", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$shin$", "ש", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$AA$", "𝔸", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$BB$", "𝔹", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$CC$", "ℂ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$DD$", "𝔻", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$EE$", "𝔼", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$FF$", "𝔽", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$GG$", "𝔾", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$HH$", "ℍ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$II$", "𝕀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$JJ$", "𝕁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$KK$", "𝕂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$LL$", "𝕃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$MM$", "𝕄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$NN$", "ℕ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$OO$", "𝕆", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$PP$", "ℙ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$QQ$", "ℚ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$RR$", "ℝ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$SS$", "𝕊", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$TT$", "𝕋", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$UU$", "𝕌", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$VV$", "𝕍", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$WW$", "𝕎", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$XX$", "𝕏", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$YY$", "𝕐", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ZZ$", "ℤ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$angstrom$", "Å", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$ell$", "ℓ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$planck$", "ħ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$planck.reduce$", "ħ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Re$", "ℜ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$Im$", "ℑ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dotless.i$", "ı", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$dotless.j$", "ȷ", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$die.six$", "⚅", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$die.five$", "⚄", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$die.four$", "⚃", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$die.three$", "⚂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$die.two$", "⚁", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$die.one$", "⚀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$errorbar.square.stroked$", "⧮", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$errorbar.square.filled$", "⧯", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$errorbar.diamond.stroked$", "⧰", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$errorbar.diamond.filled$", "⧱", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$errorbar.circle.stroked$", "⧲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$errorbar.circle.filled$", "⧳", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.female$", "♀", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.female.double$", "⚢", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.female.male$", "⚤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.intersex$", "⚥", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.male$", "♂", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.male.double$", "⚣", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.male.female$", "⚤", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.male.stroke$", "⚦", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.male.stroke.t$", "⚨", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.male.stroke.r$", "⚩", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.neuter$", "⚲", Opts)
	Opts := Map("TimeActivationSeconds", TimeAct, "FinalResult", false)
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		Opts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "$gender.trans$", "⚧", Opts)
}

