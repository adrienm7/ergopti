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
	{ key = "space", chars = { " " }, label = "␣ : Espace", default_enabled = true, consume = false },
	{ key = "nbsp", chars = { " " }, label = "⍽ : Espace insécable", default_enabled = false, consume = false },
	{ key = "nnbsp", chars = { " " }, label = "⍽ : Espace fine insécable", default_enabled = false, consume = false },
	{ key = "minus", chars = { "-" }, label = "- : Tiret", default_enabled = false, consume = false },
	{ key = "underscore", chars = { "_" }, label = "_ : Tiret bas", default_enabled = false, consume = false },
	{ label = "-", type = "separator" },
	{ key = "tab", chars = { "\t" }, label = "⇥ : Tabulation", default_enabled = true, consume = false },
	{ key = "enter", chars = { "\r", "\n" }, label = "⏎ : Entrée", default_enabled = true, consume = false },
	{ key = "star", chars = { "★" }, label = "★ : Touche magique", default_enabled = true, consume = true },
	{ label = "-", type = "separator" },
	{ key = "comma", chars = { "," }, label = ", : Virgule", default_enabled = true, consume = false },
	{ key = "semicolon", chars = { ";" }, label = "; : Point-virgule", default_enabled = true, consume = false },
	{ key = "period", chars = { "." }, label = ". : Point", default_enabled = true, consume = false },
	{ key = "ellipsis", chars = { "…" }, label = "… : Points de suspension", default_enabled = false, consume = false },
	{ key = "exclam", chars = { "!" }, label = "! : Point d'exclamation", default_enabled = true, consume = false },
	{ key = "question", chars = { "?" }, label = "? : Point d'interrogation", default_enabled = true, consume = false },
	{ key = "colon", chars = { ":" }, label = ": : Deux-points", default_enabled = true, consume = false },
	{ label = "-", type = "separator" },
	{ key = "parenright", chars = { ")" }, label = ") : Parenthèse fermante", default_enabled = false, consume = false },
	{ key = "braceright", chars = { "}" }, label = "} : Accolade fermante", default_enabled = false, consume = false },
	{ key = "bracketright", chars = { "]" }, label = "] : Crochet fermant", default_enabled = false, consume = false },
	{ key = "anglebracketright", chars = { ">" }, label = "> : Guillemet fermant", default_enabled = false, consume = false },
	{ label = "-", type = "separator" },
	{ key = "apostrophe_typo", chars = { "’" }, label = "’ : Apostrophe typographique", default_enabled = false, consume = false },
	{ key = "apostrophe_straight", chars = { "'" }, label = "' : Apostrophe droite", default_enabled = false, consume = false },
	{ key = "quote", chars = { "\"" }, label = "\" : Guillemet double", default_enabled = false, consume = false },
	{ key = "equal", chars = { "=" }, label = "= : Égal", default_enabled = false, consume = false },
	{ key = "slash", chars = { "/" }, label = "/ : Slash", default_enabled = false, consume = false },
	{ key = "backslash", chars = { "\\" }, label = "\\ : Backslash", default_enabled = false, consume = false }
}
