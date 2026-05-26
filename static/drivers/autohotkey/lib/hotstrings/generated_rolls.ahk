; static/drivers/autohotkey/lib/hotstrings/generated_rolls.ahk

; ==============================================================================
; MODULE: Generated Hotstrings — rolls
; DESCRIPTION:
; AUTO-GENERATED FILE — DO NOT EDIT BY HAND.
; Regenerate with ``python tools/compile_hotstrings.py`` from the repo root
; whenever the bundled TOML files under ``static/hotstrings/`` change.
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
	"rolls.assignarrowequalleft", _GenLoad_rolls_assignarrowequalleft,
	"rolls.assignarrowequalright", _GenLoad_rolls_assignarrowequalright,
	"rolls.assignarrowminusleft", _GenLoad_rolls_assignarrowminusleft,
	"rolls.assignarrowminusright", _GenLoad_rolls_assignarrowminusright,
	"rolls.bracketquote", _GenLoad_rolls_bracketquote,
	"rolls.chevrongreater", _GenLoad_rolls_chevrongreater,
	"rolls.chevronless", _GenLoad_rolls_chevronless,
	"rolls.closechevrontag", _GenLoad_rolls_closechevrontag,
	"rolls.commentclose", _GenLoad_rolls_commentclose,
	"rolls.commentopen", _GenLoad_rolls_commentopen,
	"rolls.ct", _GenLoad_rolls_ct,
	"rolls.cx", _GenLoad_rolls_cx,
	"rolls.englishnegation", _GenLoad_rolls_englishnegation,
	"rolls.equalstring", _GenLoad_rolls_equalstring,
	"rolls.ez", _GenLoad_rolls_ez,
	"rolls.hashtagclosebracket", _GenLoad_rolls_hashtagclosebracket,
	"rolls.hashtagopenbracket", _GenLoad_rolls_hashtagopenbracket,
	"rolls.hashtagparenthesis", _GenLoad_rolls_hashtagparenthesis,
	"rolls.hc", _GenLoad_rolls_hc,
	"rolls.leftarrow", _GenLoad_rolls_leftarrow,
	"rolls.notequal", _GenLoad_rolls_notequal,
	"rolls.parenquote", _GenLoad_rolls_parenquote,
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

_GenLoad_rolls_assignarrowequalleft(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assignarrowequalleft")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " = $", " <= ", _GenOpts)
}

_GenLoad_rolls_assignarrowequalright(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assignarrowequalright")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " $ = ", " => ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assignarrowequalright")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "$ = ", " => ", _GenOpts)
}

_GenLoad_rolls_assignarrowminusleft(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assignarrowminusleft")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " ?+", " <- ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assignarrowminusleft")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "?+", " <- ", _GenOpts)
}

_GenLoad_rolls_assignarrowminusright(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assignarrowminusright")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " +?", " -> ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "assignarrowminusright")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "+?", " -> ", _GenOpts)
}

_GenLoad_rolls_bracketquote(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "bracketquote")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "[#", "[`"", _GenOpts)
}

_GenLoad_rolls_chevrongreater(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "chevrongreater")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", ">%", ">=", _GenOpts)
}

_GenLoad_rolls_chevronless(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "chevronless")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "<%", "<=", _GenOpts)
}

_GenLoad_rolls_closechevrontag(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "closechevrontag")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "<@", "</", _GenOpts)
}

_GenLoad_rolls_commentclose(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "commentclose")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "`"\", "*/", _GenOpts)
}

_GenLoad_rolls_commentopen(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "commentopen")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "\`"", "/*", _GenOpts)
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

_GenLoad_rolls_englishnegation(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "rolls", "Section", "englishnegation")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "nt'", "n’t", _GenOpts)
}

_GenLoad_rolls_equalstring(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "equalstring")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " [)", " = `"`"", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "equalstring")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "[)", " = `"`"", _GenOpts)
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

_GenLoad_rolls_hashtagclosebracket(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "hashtagclosebracket")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#]", "`"]", _GenOpts)
}

_GenLoad_rolls_hashtagopenbracket(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "hashtagopenbracket")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#[", "`"]", _GenOpts)
}

_GenLoad_rolls_hashtagparenthesis(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "hashtagparenthesis")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "#(", "`")", _GenOpts)
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

_GenLoad_rolls_leftarrow(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "rolls", "Section", "leftarrow")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " = +", " ➜ ", _GenOpts)
}

_GenLoad_rolls_notequal(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "notequal")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " !#", " != ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "notequal")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " ç#", " != ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "notequal")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "!#", " != ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "notequal")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "ç#", " != ", _GenOpts)
}

_GenLoad_rolls_parenquote(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "rolls", "Section", "parenquote")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "(#", "(`"", _GenOpts)
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

