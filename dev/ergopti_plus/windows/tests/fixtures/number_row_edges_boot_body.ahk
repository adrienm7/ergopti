; tests/fixtures/number_row_edges_boot_body.ahk

; The parent loads the real number-row owner, policy and KeyState adapter.
; Native state reads are passive; no hotkey is registered and nothing is sent.
global _SharedDir := A_Args[3]
global _LRPE_Mode := A_Args[5], _LRPE_KanaHeld := _LRPE_Mode == "kana-held"
global Features := Map("layout", Map("direct_access_digits", "symbols", "number_row_reorder_edges", true,
	"ergopti_base", false, "emulate_number_row", true, "emulate_top_row", true,
	"emulate_home_row", true, "emulate_bottom_row", true))
global CategoryEnabled := Map("Layout", true), KLE_Model := 0, KLE_Id := "", LayerEnabled := false
global _ALTGR_KANA_FIXUP := _LRPE_KanaHeld
global _TapHoldModifierIsHeld := (*) => _LRPE_KanaHeld

GetKeyState(*) => false
GetForegroundKeyboardLayout() {
	throw Error("the passive fixture must not read the host foreground layout")
}

_LRPE_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_LRPE_Publish() {
	global _SharedDir, _NumberRowForegroundLayout, _DigitRowProfiles, KS_DIGIT_ROW_KEYS
	; Frozen corpus data describes the cached source; no native probe is run.
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\layouts\number_row_levels.json"))
	Us := Corpus["native"][2], Plain := Map(), Shift := Map()
	_LRPE_Require(Us["id"] == "qwerty", "the positive source must be the independent QWERTY vector")
	for Index, Key in KS_DIGIT_ROW_KEYS {
		Plain[Key[2]] := Us["plain"][Index]
		Shift[Key[2]] := Us["shift"][Index]
	}
	Policy := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\layouts\number_row_policy.json"))
	EdgeVector := 0
	for Vector in Policy["edges"]
		if Vector["id"] == "us_qwerty"
			EdgeVector := Vector
	_LRPE_Require(EdgeVector is Map, "the independent edge capability vector must exist")
	Edges := Map()
	for Index, Scan in [0x29, 0x0C, 0x0D]
		Edges[Scan] := Map("plain", EdgeVector["plain"][Index], "shift", EdgeVector["shift"][Index])
	_NumberRowForegroundLayout := 0x7E570409
	_DigitRowProfiles := Map(_NumberRowForegroundLayout,
		Map("shifted", false, "symbols", Plain, "shift_symbols", Shift, "edges", Edges))
}

_LRPE_Run() {
	global _LRPE_Mode, Features, CategoryEnabled, _NumberRowForegroundLayout, NUMBER_ROW_EDGE_SCS, _DigitRowProfiles
	global KS_DIGIT_ROW_KEYS, KLE_Model
	Early := _LRPE_Mode == "features-unpublished" || _LRPE_Mode == "category-unpublished"
		|| _LRPE_Mode == "category-masked" || _LRPE_Mode == "native-policy"
	if Early {
		; Recreate first evaluation during Bundle_Init, before the owning includes
		; have executed their global initializers. No later state can hide a read.
		_NumberRowForegroundLayout := unset
		NUMBER_ROW_EDGE_SCS := unset
		_DigitRowProfiles := unset
		KS_DIGIT_ROW_KEYS := unset
		KLE_Model := unset
		if _LRPE_Mode == "features-unpublished"
			Features := unset
		else if _LRPE_Mode == "category-unpublished"
			CategoryEnabled := unset
		else if _LRPE_Mode == "category-masked"
			CategoryEnabled := Map("Layout", false)
		else
			Features["layout"]["direct_access_digits"] := "native"
	} else {
		_LRPE_Publish()
		if _LRPE_Mode == "published-off"
			Features["layout"]["number_row_reorder_edges"] := false
		if _LRPE_Mode == "inert-ordering"
			Features["layout"]["direct_access_digits"] := "digits"
	}
	; A baseline failure is an actual unset-global read, never an AssertThrows
	; accepting an unrelated setup failure. The positive controls must also run.
	Expected := _LRPE_Mode == "published-on"
	_LRPE_Require(_LRPE_EdgeCriterion() == Expected, "only an admitted, supported and unmodified edge may be consumed")
	if _LRPE_Mode == "published-on" || _LRPE_Mode == "published-off" {
		State := NumberRowEdgesState()
		_LRPE_Require(State["reason"] == "", "the menu must retain capability reasons even while the edge choice is off")
		_LRPE_Require(State["stored"] == (_LRPE_Mode == "published-on"), "the stored edge choice must retain its own owner")
	}
	if Expected
		_LRPE_Require(NumberRowEdgeText(0x29, false, _NumberRowForegroundLayout, false) == "~",
			"published admission must retain the existing swapped edge resolver")
}

try {
	_LRPE_Run()
	FileAppend("PASS number-row-edges-admission", "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
