; static/drivers/autohotkey/lib/hotstrings/generated_sfbsreduction.ahk

; ==============================================================================
; MODULE: Generated Hotstrings — sfbsreduction
; DESCRIPTION:
; AUTO-GENERATED FILE — DO NOT EDIT BY HAND.
; Regenerate with ``python tools/compile_hotstrings.py`` from the repo root
; whenever the bundled TOML files under ``static/hotstrings/`` change.
;
; Contains the ``_GenLoad_*`` loader functions and the partial
; ``_GENERATED_HOTSTRINGS`` map entries for the ``sfbsreduction`` category.
; Included automatically by ``hotstrings_generated.ahk``.
; ==============================================================================






; =====================================
; =====================================
; ======= 1/ Generated registry =======
; =====================================
; =====================================

global _GENERATED_HOTSTRINGS_SFBSREDUCTION := Map(
	"sfbsreduction.bu", _GenLoad_sfbsreduction_bu,
	"sfbsreduction.comma", _GenLoad_sfbsreduction_comma,
	"sfbsreduction.ecirc", _GenLoad_sfbsreduction_ecirc,
	"sfbsreduction.egrave", _GenLoad_sfbsreduction_egrave,
	"sfbsreduction.ie", _GenLoad_sfbsreduction_ie,
)





; ====================================
; ====================================
; ======= 2/ Generated loaders =======
; ====================================
; ====================================

_GenLoad_sfbsreduction_bu(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "bu")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àu", "ub", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "bu")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("à★", "★", _GenMK), "bu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "bu")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("e mà★", "★", _GenMK), "e mise à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "bu")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("es mà★", "★", _GenMK), "es mises à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "bu")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("il a mà★", "★", _GenMK), "il a mis à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "bu")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("la mà★", "★", _GenMK), "la mise à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "bu")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ma mà★", "★", _GenMK), "ma mise à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "bu")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mà★", "★", _GenMK), "mettre à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "bu")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("mià★", "★", _GenMK), "mise à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "bu")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("pià★", "★", _GenMK), "pièce jointe", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "bu")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("ta mà★", "★", _GenMK), "ta mise à jour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "bu")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", StrReplace("tà★", "★", _GenMK), "toujours", _GenOpts)
}

_GenLoad_sfbsreduction_comma(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "comma")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",d", "ds", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "comma")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",f", "fl", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "comma")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",g", "gl", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "comma")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",h", "ph", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "comma")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",l", "cl", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "comma")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",m", "ms", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "comma")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",n", "nl", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "comma")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",p", "xp", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "comma")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",q", "qu’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "comma")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",r", "rq", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "comma")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",t", "pt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "comma")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",v", "dv", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "comma")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", ",z", "bj", _GenOpts)
}

_GenLoad_sfbsreduction_ecirc(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "ecirc")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ê,", "u,", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "ecirc")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ê.", "u.", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "ecirc")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "éê", "eo", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "ecirc")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "êé", "oe", _GenOpts)
}

_GenLoad_sfbsreduction_egrave(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "egrave")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "èy", "aî", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "egrave")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "yè", "â", _GenOpts)
}

_GenLoad_sfbsreduction_ie(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "ie")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "àé", "éi", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "ie")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "éà", "ié", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "sfbsreduction", "Section", "ie")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", StrReplace("ié★", "★", _GenMK), "ébu", _GenOpts)
}

