; static/ergopti_plus/windows/lib/hotstrings/generated_rolls.ahk

; ==============================================================================
; MODULE: Generated Hotstrings — rolls
; DESCRIPTION:
; AUTO-GENERATED FILE — DO NOT EDIT BY HAND.
; Regenerate with ``node scripts/build-hotstrings.cjs`` from the repo root
; whenever the bundled TOML files under ``static/ergopti_plus/_shared/hotstrings/`` change.
;
; Contains the ``_GenLoad_*`` loader functions and the partial
; ``_GENERATED_HOTSTRINGS`` map entries for the ``rolls`` category.
; Included automatically by ``hotstrings_generated.ahk``.
; ==============================================================================






; =====================================
; =====================================
; ======= 1/ Generated registry =======
; =====================================
; =====================================

global _GENERATED_HOTSTRINGS_ROLLS := Map(
	"rolls.assign", _GenLoad_rolls_assign,
	"rolls.assign_arrow_equal_left", _GenLoad_rolls_assign_arrow_equal_left,
	"rolls.assign_arrow_equal_right", _GenLoad_rolls_assign_arrow_equal_right,
	"rolls.assign_arrow_minus_left", _GenLoad_rolls_assign_arrow_minus_left,
	"rolls.assign_arrow_minus_right", _GenLoad_rolls_assign_arrow_minus_right,
	"rolls.bracket_quote", _GenLoad_rolls_bracket_quote,
	"rolls.chevron_greater", _GenLoad_rolls_chevron_greater,
	"rolls.chevron_less", _GenLoad_rolls_chevron_less,
	"rolls.close_chevron_tag", _GenLoad_rolls_close_chevron_tag,
	"rolls.comment_close", _GenLoad_rolls_comment_close,
	"rolls.comment_open", _GenLoad_rolls_comment_open,
	"rolls.ct", _GenLoad_rolls_ct,
	"rolls.cx", _GenLoad_rolls_cx,
	"rolls.english_negation", _GenLoad_rolls_english_negation,
	"rolls.equal_string", _GenLoad_rolls_equal_string,
	"rolls.ez", _GenLoad_rolls_ez,
	"rolls.hashtag_close_bracket", _GenLoad_rolls_hashtag_close_bracket,
	"rolls.hashtag_open_bracket", _GenLoad_rolls_hashtag_open_bracket,
	"rolls.hashtag_parenthesis", _GenLoad_rolls_hashtag_parenthesis,
	"rolls.hc", _GenLoad_rolls_hc,
	"rolls.left_arrow", _GenLoad_rolls_left_arrow,
	"rolls.not_equal", _GenLoad_rolls_not_equal,
	"rolls.paren_quote", _GenLoad_rolls_paren_quote,
	"rolls.sx", _GenLoad_rolls_sx,
)





; ====================================
; ====================================
; ======= 2/ Generated loaders =======
; ====================================
; ====================================

_GenLoad_rolls_assign(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assign")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " #!", " := ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assign")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " #ç", " := ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assign")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#!", " := ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assign")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#ç", " := ", _GenOpts)
}

_GenLoad_rolls_assign_arrow_equal_left(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assign_arrow_equal_left")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " = $", " <= ", _GenOpts)
}

_GenLoad_rolls_assign_arrow_equal_right(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assign_arrow_equal_right")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " $ = ", " => ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assign_arrow_equal_right")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "$ = ", " => ", _GenOpts)
}

_GenLoad_rolls_assign_arrow_minus_left(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assign_arrow_minus_left")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " ?+", " <- ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assign_arrow_minus_left")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "?+", " <- ", _GenOpts)
}

_GenLoad_rolls_assign_arrow_minus_right(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assign_arrow_minus_right")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " +?", " -> ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assign_arrow_minus_right")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "+?", " -> ", _GenOpts)
}

_GenLoad_rolls_bracket_quote(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "bracket_quote")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "[#", '["', _GenOpts)
}

_GenLoad_rolls_chevron_greater(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "chevron_greater")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", ">%", ">=", _GenOpts)
}

_GenLoad_rolls_chevron_less(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "chevron_less")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "<%", "<=", _GenOpts)
}

_GenLoad_rolls_close_chevron_tag(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "close_chevron_tag")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "<@", "</", _GenOpts)
}

_GenLoad_rolls_comment_close(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "comment_close")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", '"\"', "*/", _GenOpts)
}

_GenLoad_rolls_comment_open(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "comment_open")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", '\"', "/*", _GenOpts)
}

_GenLoad_rolls_ct(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "rolls", "Section", "ct")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "p'", "ct", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "rolls", "Section", "ct")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?C", "p ?", "p ?", _GenOpts)
}

_GenLoad_rolls_cx(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "rolls", "Section", "cx")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "cx", "ck", _GenOpts)
}

_GenLoad_rolls_english_negation(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "rolls", "Section", "english_negation")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "nt'", "n’t", _GenOpts)
}

_GenLoad_rolls_equal_string(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "equal_string")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " [)", ' = ""', _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "equal_string")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "[)", ' = ""', _GenOpts)
}

_GenLoad_rolls_ez(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "rolls", "Section", "ez")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eé", "ez", _GenOpts)
}

_GenLoad_rolls_hashtag_close_bracket(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "hashtag_close_bracket")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#]", '"]', _GenOpts)
}

_GenLoad_rolls_hashtag_open_bracket(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "hashtag_open_bracket")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#[", '"]', _GenOpts)
}

_GenLoad_rolls_hashtag_parenthesis(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "hashtag_parenthesis")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#(", '")', _GenOpts)
}

_GenLoad_rolls_hc(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "rolls", "Section", "hc")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "hc", "wh", _GenOpts)
}

_GenLoad_rolls_left_arrow(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "rolls", "Section", "left_arrow")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " = +", " ➜ ", _GenOpts)
}

_GenLoad_rolls_not_equal(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "not_equal")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " !#", " != ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "not_equal")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " ç#", " != ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "not_equal")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "!#", " != ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "not_equal")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "ç#", " != ", _GenOpts)
}

_GenLoad_rolls_paren_quote(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "paren_quote")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "(#", '("', _GenOpts)
}

_GenLoad_rolls_sx(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "rolls", "Section", "sx")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "sx", "sk", _GenOpts)
}

