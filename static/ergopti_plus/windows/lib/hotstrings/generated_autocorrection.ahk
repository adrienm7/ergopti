; static/ergopti_plus/windows/lib/hotstrings/generated_autocorrection.ahk

; ==============================================================================
; MODULE: Generated Hotstrings — autocorrection
; DESCRIPTION:
; AUTO-GENERATED FILE — DO NOT EDIT BY HAND.
; Regenerate with ``node scripts/build-hotstrings.cjs`` from the repo root
; whenever the bundled TOML files under ``static/ergopti_plus/shared/hotstrings/`` change.
;
; Contains the ``_GenLoad_*`` loader functions and the partial
; ``_GENERATED_HOTSTRINGS`` map entries for the ``autocorrection`` category.
; Included automatically by ``hotstrings_generated.ahk``.
; ==============================================================================






; =====================================
; =====================================
; ======= 1/ Generated registry =======
; =====================================
; =====================================

global _GENERATED_HOTSTRINGS_AUTOCORRECTION := Map(
	"autocorrection.accents", _GenLoad_autocorrection_accents,
	"autocorrection.caps", _GenLoad_autocorrection_caps,
	"autocorrection.errors", _GenLoad_autocorrection_errors,
	"autocorrection.minus", _GenLoad_autocorrection_minus,
	"autocorrection.minusapostrophe", _GenLoad_autocorrection_minusapostrophe,
	"autocorrection.multiplepunctuationmarks", _GenLoad_autocorrection_multiplepunctuationmarks,
	"autocorrection.names", _GenLoad_autocorrection_names,
	"autocorrection.ou", _GenLoad_autocorrection_ou,
	"autocorrection.suffixesachaining", _GenLoad_autocorrection_suffixesachaining,
	"autocorrection.typographicapostrophe", _GenLoad_autocorrection_typographicapostrophe,
)





; ====================================
; ====================================
; ======= 2/ Generated loaders =======
; ====================================
; ====================================

_GenLoad_autocorrection_accents(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "abim", "abîm", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "accroit", "accroît", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "affut", "affût", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "agé", "âgé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "agée", "âgée", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "agées", "âgées", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "agés", "âgés", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aieul", "aïeul", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aieux", "aïeux", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aigue", "aiguë", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aikido", "aïkido", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ainé", "aîné", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ambigue", "ambiguë", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ambigui", "ambiguï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ame", "âme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ames", "âmes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "amphithéatre", "amphithéâtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ane", "âne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "anerie", "ânerie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "anes", "ânes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "anesse", "ânesse", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "angstrom", "ångström", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aout", "août", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "apotre", "apôtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "appat", "appât", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "apprete", "apprête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "appreter", "apprêter", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "apre", "âpre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "apres", "âpres", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "archaique", "archaïque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "archaisme", "archaïsme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "archeveque", "archevêque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "archeveques", "archevêques", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "arete", "arête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "aretes", "arêtes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "arome", "arôme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "arret", "arrêt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aumone", "aumône", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aumonier", "aumônier", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "aussitot", "aussitôt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "avant-gout", "avant-goût", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "babord", "bâbord", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "baclé", "bâclé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "bacler", "bâcler", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "baille", "bâille", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "baillon", "bâillon", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "baionnette", "baïonnette", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "batard", "bâtard", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "bati", "bâti", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "baton", "bâton", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "beche", "bêche", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "beches", "bêches", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "benet", "benêt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "benets", "benêts", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "benoite", "benoîte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "bete", "bête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "betis", "bêtis", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "bientot", "bientôt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "binome", "binôme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "blamer", "blâmer", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "bleautre", "bleuâtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "bleme", "blême", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "blemes", "blêmes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "blemir", "blêmir", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "blémir", "blêmir", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "boeuf", "bœuf", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "boite", "boîte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "brul", "brûl", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "buche", "bûche", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cablé", "câblé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cabler", "câbler", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "calin", "câlin", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "canoe", "canoë", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "chaine", "chaîne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "chainé", "chaîné", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "chaîned", "chained", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chassis", "châssis", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chataigne", "châtaigne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chatain", "châtain", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chateau", "château", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chatelain", "châtelain", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chatelet", "châtelet", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chatier", "châtier", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chatiment", "châtiment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chomage", "chômage", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chomé", "chômé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "chomer", "chômer", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "chomeu", "chômeu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cloitre", "cloître", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cloitré", "cloîtré", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "clotura", "clôtura", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cloture", "clôture", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cloturé", "clôturé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cocaine", "cocaïne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cocaino", "cocaïno", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "coeur", "cœur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "coincide", "coïncide", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "connait", "connaît", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "controla", "contrôla", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "controle", "contrôle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "controlé", "contrôlé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "controlo", "contrôlo", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "cote", "côte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "cotes", "côtes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cotoie", "côtoie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cotoy", "côtoy", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "cout", "coût", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "coute", "coûte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "couter", "coûter", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "couteu", "coûteu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "couts", "coûts", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "craner", "crâner", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "cranien", "crânien", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "croitre", "croître", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "crouton", "croûton", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "crument", "crûment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "débacle", "débâcle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "dégat", "dégât", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "dégout", "dégoût", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "dépech", "dépêch", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "dépot", "dépôt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "dépots", "dépôts", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "détron", "détrôn", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "diplome", "diplôme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "diplomé", "diplômé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "drole", "drôle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "dument", "dûment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "écoeure", "écœure", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "écoeuré", "écœuré", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "egoisme", "égoïsme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "égoisme", "égoïsme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "egoiste", "égoïste", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "égoiste", "égoïste", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "elle-meme", "elle-même", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "elles-meme", "elles-mêmes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "elles-memes", "elles-mêmes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "embet", "embêt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "embuch", "embûch", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "empeche", "empêche", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "enchain", "enchaîn", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "enjoleu", "enjôleu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "enrole", "enrôle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "entete", "entête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "enteté", "entêté", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "entraina", "entraîna", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "entraine", "entraîne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "entrainé", "entraîné", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "entrepot", "entrepôt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "envout", "envoût", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "eux-meme", "eux-mêmes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "fache", "fâche", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "faché", "fâché", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "famé", "fâmé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "fantome", "fantôme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "felure", "fêlure", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "félure", "fêlure", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "fenetre", "fenêtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "fete", "fête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "feter", "fêter", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "fetes", "fêtes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flane", "flâne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flaner", "flâner", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flanes", "flânes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "flaneu", "flâneu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flanez", "flânez", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flanons", "flânons", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flute", "flûte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "flutes", "flûtes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "foetus", "fœtus", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "foret", "forêt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "fraich", "fraîch", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "frole", "frôle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "futs", "fûts", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "gach", "gâch", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gaté", "gâté", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "gateau", "gâteau", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gater", "gâter", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gatés", "gâtés", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "genant", "gênant", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "génant", "gênant", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "génants", "gênants", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gener", "gêner", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "geole", "geôle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "geoliè", "geôliè", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "geolier", "geôlier", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gite", "gîte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gout", "goût", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "gouta", "goûta", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "goute", "goûte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "gouté", "goûté", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "gouter", "goûter", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "goutes", "goûtes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "gouteur", "goûteur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "gouteux", "goûteux", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "goutez", "goûtez", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "goutons", "goûtons", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "grele", "grêle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "grèle", "grêle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "greler", "grêler", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "guepe", "guêpe", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "guepier", "guêpier", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "hawaien", "hawaïen", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "héroin", "héroïn", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "heroiq", "héroïq", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "héroiq", "héroïq", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "heroisme", "héroïsme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "héroisme", "héroïsme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "honnete", "honnête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "hopita", "hôpita", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "hotelier", "hôtelier", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "hotellerie", "hôtellerie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "hotes", "hôtes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "huitre", "huître", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "icone", "icône", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "idolatr", "idolâtr", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ile", "île", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "iles", "îles", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ilot", "îlot", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ilots", "îlots", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "impot", "impôt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "impots", "impôts", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "indu", "indû", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "indument", "indûment", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "indus", "indûs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "infame", "infâme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "infamie", "infâmie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "inoui", "inouï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "interet", "intérêt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "intéret", "intérêt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "jaunatre", "jaunâtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "jeuner", "jeûner", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "la notre", "la nôtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "la votre", "la vôtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "lache", "lâche", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "laché", "lâché", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "laic", "laïc", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "laique", "laïque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "laius", "laïus", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "le notre", "le nôtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "le votre", "le vôtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "les notres", "les nôtres", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "les votres", "les vôtres", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "lui-meme", "lui-même", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "m'apprete", "m'apprête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "mache", "mâche", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "macher", "mâcher", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "machoire", "mâchoire", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "machouill", "mâchouill", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "maelstrom", "maelström", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "maitr", "maîtr", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "male", "mâle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "males", "mâles", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "malstrom", "malström", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "manoeuvr", "manœuvr", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "maraich", "maraîch", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "maratre", "marâtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "meler", "mêler", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "meme", "même", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "moeur", "mœur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "mome", "môme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "momes", "mômes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "mosaique", "mosaïque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "multitache", "multitâche", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "murement", "mûrement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "murir", "mûrir", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "murit", "mûrit", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "m’apprete", "m’apprête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "naif", "naïf", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "naifs", "naïfs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "nait", "naît", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "naitre", "naître", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "naive", "naïve", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "naivement", "naïvement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "naives", "naïves", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "naiveté", "naïveté", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "noeud", "nœud", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "oecuméni", "œcuméni", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "oeil", "œil", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "oesophage", "œsophage", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "oeuf", "œuf", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oeuvre", "œuvre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "opiniatre", "opiniâtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ota", "ôta", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "otant", "ôtant", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "oté", "ôté", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "oter", "ôter", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ouie", "ouïe", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "paella", "paëlla", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "pali", "pâli", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "palir", "pâlir", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "palis", "pâlis", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "palit", "pâlit", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "paquerette", "pâquerette", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "parait", "paraît", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "paranoia", "paranoïa", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "pate", "pâte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "paté", "pâté", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "patée", "pâtée", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "pates", "pâtes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "patés", "pâtés", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "pati", "pâti", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "patir", "pâtir", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "patur", "pâtur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peche", "pêche", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "pecher", "pêcher", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peches", "pêches", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "pecheu", "pêcheu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "pentecote", "Pentecôte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "phoenix", "phœnix", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "photovoltai", "photovoltaï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "pina colada", "piña colada", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "piqure", "piqûre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "plait", "plaît", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "platre", "plâtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "plutot", "plutôt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "poele", "poêle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "polynom", "polynôm", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "pret", "prêt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "prets", "prêts", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "prochaine", "prochaine", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "prosaique", "prosaïque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "pylone", "pylône", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "quete", "quête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "rala", "râla", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ralais", "râlais", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ralait", "râlait", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ralé", "râlé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "raler", "râler", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "raleu", "râleu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ralez", "râlez", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ralons", "râlons", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "rebatir", "rebâtir", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "relach", "relâch", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "rene", "rêne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "renes", "rênes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "requete", "requête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "revasse", "rêvasse", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "reve", "rêve", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "rever", "rêver", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "reverie", "rêverie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "reves", "rêves", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "rodeur", "rôdeur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "rodeuse", "rôdeuse", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "roti", "rôti", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "salpetre", "salpêtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "samourai", "samouraï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "soeur", "sœur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "soule", "soûle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "soulé", "soûlé", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "souler", "soûler", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "soules", "soûles", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "stoicisme", "stoïcisme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "stoique", "stoïque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "surcout", "surcoût", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "surcroit", "surcroît", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "surement", "sûrement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "sureté", "sûreté", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "surs", "sûrs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "symptom", "symptôm", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "tabloid", "tabloïd", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "tantot", "tantôt", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "tater", "tâter", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "tatons", "tâtons", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "tempete", "tempête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "tete", "tête", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "tetes", "têtes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "thailanda", "thaïlanda", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "theatr", "théâtr", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "théatr", "théâtr", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "tole", "tôle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "toles", "tôles", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "traina", "traîna", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "traine", "traîne", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "trainer", "traîner", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "traitr", "traîtr", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "treve", "trêve", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "treves", "trêves", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "trinome", "trinôme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "trona", "trôna", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "trone", "trône", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ushuaia", "Ushuaïa", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "vetement", "vêtement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "voeu", "vœu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "voute", "voûte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "accents")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "vouté", "voûté", _GenOpts)
}

_GenLoad_autocorrection_caps(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "adaboost", "AdaBoost", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "adn", "ADN", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ag", "AG", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "api", "API", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "autohotkey", "AutoHotkey", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "aws", "AWS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "axa", "AXA", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "azure devops", "Azure DevOps", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bbc", "BBC", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bbq", "BBQ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bdd", "BDD", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bdds", "BDDs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bic", "BIC", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bpce", "BPCE", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bspce", "BSPCE", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "caas", "CaaS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "captcha", "CAPTCHA", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "catboost", "CatBoost", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cdd", "CDD", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cdi", "CDI", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "chatgpt", "ChatGPT", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cli", "CLI", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "comex", "COMEX", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cpu", "CPU", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "csp", "CSP", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "css", "CSS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cv", "CV", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "data science", "Data Science", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "data scientist", "Data Scientist", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "databricks", "Databricks", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dbaas", "DBaaS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dna", "DNA", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "docker", "Docker", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ds", "DS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dynatrace", "Dynatrace", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ergopti", "Ergopti", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "esg", "ESG", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "faas", "FaaS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "facebook", "Facebook", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "firefox", "Firefox", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "fmi", "FMI", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "gcp", "GCP", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "gdpr", "GDPR", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "github", "GitHub", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "google", "Google", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "gps", "GPS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "gpu", "GPU", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "hammerspoon", "Hammerspoon", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "hd", "HD", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ht", "HT", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ia", "IA", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "iaas", "IaaS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "iban", "IBAN", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "imf", "IMF", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "insee", "Insee", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "instagram", "Instagram", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "intellij", "IntelliJ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ip", "IP", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "iptv", "IPTV", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "json", "JSON", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ko", "KO", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "kpi", "KPI", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "kpis", "KPIs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "latex", "LaTeX", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "lightgbm", "LightGBM", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "linux", "Linux", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "llm", "LLM", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "llms", "LLMs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "lora", "LoRA", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "lualatex", "LuaLaTeX", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "macos", "macOS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "maj", "MAJ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "majs", "MAJs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mbti", "MBTI", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mcp", "MCP", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ml", "ML", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mle", "MLE", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mlflow", "MLflow", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mlops", "MLOps", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "nasa", "NASA", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "nato", "NATO", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "nfc", "NFC", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "nft", "NFT", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "nlp", "NLP", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ny", "NY", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ok", "OK", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "onedrive", "OneDrive", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "onenote", "OneNote", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "onu", "ONU", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "openshift", "OpenShift", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "opentelemetry", "OpenTelemetry", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "optimot", "Optimot", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "otan", "OTAN", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "outlook", "Outlook", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ovni", "OVNI", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ovnis", "OVNIS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "paas", "PaaS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "pnl", "PNL", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "poc", "POC", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "powerbi", "PowerBI", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "powerpoint", "PowerPoint", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "pr", "PR", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "qlora", "QLoRA", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "r", "R", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "raid", "RAID", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ram", "RAM", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "rdc", "RDC", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "rgpd", "RGPD", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "rh", "RH", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "rib", "RIB", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "saas", "SaaS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "sas", "SAS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "sharepoint", "SharePoint", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "siret", "SIRET", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "slm", "SLM", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "sncf", "SNCF", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "sql", "SQL", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ssd", "SSD", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ssh", "SSH", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ssl", "SSL", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "swift", "SWIFT", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "tiktok", "TikTok", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "tldr", "TL`;DR", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "tls", "TLS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ttc", "TTC", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ttm", "TTM", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ui", "UI", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "uno", "UNO", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "url", "URL", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "urss", "URSS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "ux", "UX", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "vendome", "Vendôme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "vpn", "VPN", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "vps", "VPS", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "vscode", "VSCode", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "wikipedia", "Wikipedia", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "wikipédia", "Wikipédia", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "windows", "Windows", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "xgboost", "XGBoost", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "caps")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "youtube", "YouTube", _GenOpts)
}

_GenLoad_autocorrection_errors(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", " = _", "= ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "#_", "# ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "$_", "$ ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "(_", "( ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", ")_", ") ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "*_", "* ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "+_", "+ ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "[_", "[ ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "]_", "] ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "acceuil", "accueil", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "accuei", "accuei", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "aeu", "eau", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "avce", "avec", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eiu", "ieu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eua", "eau", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "fenètre", "fenêtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "hotsring", "hotstring", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "laieus", "laïus", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oiu", "oui", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*C", "OUi", "Oui", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "oyu", "you", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "poru", "pour", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "sru", "sur", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "uei", "uie", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "uio", "uoi", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "errors")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*", "~_", "~ ", _GenOpts)
}

_GenLoad_autocorrection_minus(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "aije", "ai-je", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "astu", "as-tu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "atil", "a-t-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "aton", "a-t-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "auratelle", "aura-t-elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "auratil", "aura-t-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "auraton", "aura-t-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "dismoi", "dis-moi", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "distu", "dis-tu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ditelle", "dit-elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ditil", "dit-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "diton", "dit-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "doisje", "dois-je", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "doitelle", "doit-elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "doitil", "doit-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "doiton", "doit-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "estil", "est-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "eston", "est-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "estu", "es-tu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "fautelle", "faut-elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "fautil", "faut-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "fauton", "faut-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peutelle", "peut-elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peutil", "peut-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peuton", "peut-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "peuxtu", "peux-tu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "puisje", "puis-je", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "vatelle", "va-t-elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "vatil", "va-t-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "vaton", "va-t-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "veutelle", "veut-elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "veutil", "veut-il", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "veuton", "veut-on", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "veuxtu", "veux-tu", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "vezv", "vez-v", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "vonsn", "vons-n", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minus")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "yatil", "y a-t-il", _GenOpts)
}

_GenLoad_autocorrection_minusapostrophe(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a't", "a-t", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a't'e", "a-t-e", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a't'i", "a-t-i", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "a't'o", "a-t-o", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ai',", "ai-j", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ai'j", "ai-j", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "as't", "as-t", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "s',", "s-j", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "s'j", "s-j", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "s'm", "s-m", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "s'n", "s-n", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "s't", "s-t", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "t'e", "t-e", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "t'i", "t-i", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "t'o", "t-o", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "x't", "x-t", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("", "ya", "y'a", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "minusapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "z'v", "z-v", _GenOpts)
}

_GenLoad_autocorrection_multiplepunctuationmarks(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "multiplepunctuationmarks")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "! !", "!!", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "multiplepunctuationmarks")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "! ?", "!?", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "multiplepunctuationmarks")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "? !", "?!", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "multiplepunctuationmarks")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", "? ?", "??", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "multiplepunctuationmarks")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " ! !", " !!", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "multiplepunctuationmarks")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " ! ?", " !?", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "multiplepunctuationmarks")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " ? !", " ?!", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "multiplepunctuationmarks")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("*?", " ? ?", " ??", _GenOpts)
}

_GenLoad_autocorrection_names(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "adélaide", "Adélaïde", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "aicha", "Aïcha", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "aid", "Aïd", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "alexei", "Alexeï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "anais", "Anaïs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "azerbaidjan", "Azerbaïdjan", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "bahrein", "Bahreïn", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "benoit", "Benoît", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "caraibes", "Caraïbes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "citroen", "Citroën", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cleopatre", "Cléopâtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "cléopatre", "Cléopâtre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dostoieski", "Dostoïevski", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dostoievski", "Dostoïevski", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "dubai", "Dubaï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "gaetan", "Gaëtan", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "hanoi", "Hanoï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "hawai", "Hawaï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "héloise", "Héloïse", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "israel", "Israël", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "jamaique", "Jamaïque", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "jerome", "Jérôme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "jérome", "Jérôme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "joel", "Joël", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "joelle", "Joëlle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "koweit", "Koweït", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mendeleiev", "Mendeleïev", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "mickael", "Mickaël", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "nimes", "Nîmes", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "noel", "Noël", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "noelle", "Noëlle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "paques", "Pâques", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "pentecote", "Pentecôte", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "raphael", "Raphaël", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "serguei", "Sergueï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "shanghai", "Shanghaï", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "taiwan", "Taïwan", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "thailande", "Thaïlande", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "thais", "Thaïs", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", true, "IsRepeat", false, "Category", "autocorrection", "Section", "names")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateHotstring("", "tolstoi", "Tolstoï", _GenOpts)
}

_GenLoad_autocorrection_ou(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "ou")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "où ,", "où, ", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "ou")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "où .", "où.", _GenOpts)
}

_GenLoad_autocorrection_suffixesachaining(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "suffixesachaining")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàa", "aire", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "suffixesachaining")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàf", "iste", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "suffixesachaining")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàl", "elle", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "suffixesachaining")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàm", "isme", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "suffixesachaining")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàn", "ation", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "suffixesachaining")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàp", "ence", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "suffixesachaining")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàq", "ique", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "suffixesachaining")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàr", "erre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "suffixesachaining")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàs", "ement", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "suffixesachaining")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàt", "ettre", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "suffixesachaining")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "eàz", "ez-vous", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "suffixesachaining")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "ieàq", "ique", _GenOpts)
}

_GenLoad_autocorrection_typographicapostrophe(FeatureConfig, ExtraOptions := unset) {
	global ScriptInformation
	_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	_GenMK := ScriptInformation["MagicKey"]
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "typographicapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "c'", "c’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "typographicapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ch'ti", "ch’ti", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "typographicapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "d'", "d’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "typographicapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "ju'", "jusqu’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "typographicapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "j'", "j’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "typographicapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "l'", "l’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "typographicapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "m'", "m’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "typographicapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "n'", "n’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "typographicapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*?", "n't", "n’t", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "typographicapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "s'", "s’", _GenOpts)
	_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", false, "IsRepeat", false, "Category", "autocorrection", "Section", "typographicapostrophe")
	if IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {
		_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]
	}
	CreateCaseSensitiveHotstrings("*", "t'", "t’", _GenOpts)
}

