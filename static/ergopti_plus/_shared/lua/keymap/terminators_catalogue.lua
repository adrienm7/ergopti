--- _shared/lua/keymap/terminators_catalogue.lua
--- AUTO-GENERATED from _shared/core/domain/Terminators.spec.js.
--- DO NOT EDIT BY HAND — run `npm run codegen:terminators` to refresh.

--- ==============================================================================
--- DATA: Terminator Catalogue
--- DESCRIPTION:
--- Pure, ordered terminator definitions seeded from the shared spec. Consumed
--- by keymap.terminators (the hand-written logic module) so the macOS driver
--- and the AHK driver start from byte-identical catalogue data. The list
--- ORDER is the menu order; { type = "separator" } entries render as "-".
--- ==============================================================================

return {
	{ key = "space", chars = { " " }, label_key = "terminators.label_space", default_enabled = true, consume = false },
	{ key = "nbsp", chars = { " " }, label_key = "terminators.label_nbsp", default_enabled = false, consume = false },
	{ key = "nnbsp", chars = { " " }, label_key = "terminators.label_nnbsp", default_enabled = false, consume = false },
	{ key = "minus", chars = { "-" }, label_key = "terminators.label_minus", default_enabled = false, consume = false },
	{ key = "underscore", chars = { "_" }, label_key = "terminators.label_underscore", default_enabled = false, consume = false },
	{ label = "-", type = "separator" },
	{ key = "tab", chars = { "\t" }, label_key = "terminators.label_tab", default_enabled = true, consume = false },
	{ key = "enter", chars = { "\r", "\n" }, label_key = "terminators.label_enter", default_enabled = true, consume = false },
	{ key = "star", chars = { "★" }, label_key = "terminators.label_star", default_enabled = true, consume = true },
	{ label = "-", type = "separator" },
	{ key = "comma", chars = { "," }, label_key = "terminators.label_comma", default_enabled = true, consume = false },
	{ key = "semicolon", chars = { ";" }, label_key = "terminators.label_semicolon", default_enabled = true, consume = false },
	{ key = "period", chars = { "." }, label_key = "terminators.label_period", default_enabled = true, consume = false },
	{ key = "ellipsis", chars = { "…" }, label_key = "terminators.label_ellipsis", default_enabled = false, consume = false },
	{ key = "exclam", chars = { "!" }, label_key = "terminators.label_exclam", default_enabled = true, consume = false },
	{ key = "question", chars = { "?" }, label_key = "terminators.label_question", default_enabled = true, consume = false },
	{ key = "colon", chars = { ":" }, label_key = "terminators.label_colon", default_enabled = true, consume = false },
	{ label = "-", type = "separator" },
	{ key = "parenright", chars = { ")" }, label_key = "terminators.label_parenright", default_enabled = false, consume = false },
	{ key = "braceright", chars = { "}" }, label_key = "terminators.label_braceright", default_enabled = false, consume = false },
	{ key = "bracketright", chars = { "]" }, label_key = "terminators.label_bracketright", default_enabled = false, consume = false },
	{ key = "anglebracketright", chars = { ">" }, label_key = "terminators.label_anglebracketright", default_enabled = false, consume = false },
	{ label = "-", type = "separator" },
	{ key = "apostrophe_typo", chars = { "’" }, label_key = "terminators.label_apostrophe_typo", default_enabled = false, consume = false },
	{ key = "apostrophe_straight", chars = { "'" }, label_key = "terminators.label_apostrophe_straight", default_enabled = false, consume = false },
	{ key = "quote", chars = { "\"" }, label_key = "terminators.label_quote", default_enabled = false, consume = false },
	{ key = "equal", chars = { "=" }, label_key = "terminators.label_equal", default_enabled = false, consume = false },
	{ key = "slash", chars = { "/" }, label_key = "terminators.label_slash", default_enabled = false, consume = false },
	{ key = "backslash", chars = { "\\" }, label_key = "terminators.label_backslash", default_enabled = false, consume = false }
}
