--- tools/build/gen-process-prediction-corpus.lua

--- ==============================================================================
--- MODULE: process_prediction Cross-Driver Golden Generator
--- DESCRIPTION:
--- Generates the cross-driver golden corpus for the LLM semantic-diff parser
--- (process_prediction) by running the SHARED Lua implementation
--- (_shared/lua/llm/parser.lua) — the canonical source after the parser lift — as
--- the oracle over a curated set of input vectors. The emitted corpus
--- (_shared/tests/corpus/llm/process_prediction_vectors.json) is consumed by both
--- the macOS Lua suite and the AHK suite, which assert their parser produces the
--- same PHYSICAL output (deletes / to_type / nw / has_corrections / disable_bold)
--- for each vector. The `chunks` field is tooltip-display-only and is computed
--- differently per driver, so it is deliberately NOT part of the parity contract.
---
--- USAGE:
---     lua tools/build/gen-process-prediction-corpus.lua
--- ==============================================================================

--- Repo root, derived from THIS script's own path.
---
--- Both paths below used to be absolute — "D:/Documents/GitHub/ergopti/…", one
--- maintainer's checkout. The generator therefore could not run on any other
--- machine or in CI: it would either fail to require the shared parser or, worse,
--- write its corpus to a directory that does not exist.
--- @return string Absolute repo root, no trailing slash.
local function repo_root()
	local src = debug.getinfo(1, "S").source
	if src:sub(1, 1) == "@" then src = src:sub(2) end
	src = src:gsub("\\", "/")
	-- src is <root>/tools/build/gen-process-prediction-corpus.lua
	local root = src:match("^(.*)/tools/build/[^/]+$")
	return root or "."
end

local ROOT = repo_root()

-- Resolve the repo's _shared/lua so the shared modules resolve regardless of cwd.
local SHARED_LUA = ROOT .. "/static/ergopti_plus/_shared/lua"
package.path = SHARED_LUA .. "/?.lua;" .. SHARED_LUA .. "/?/init.lua;" .. package.path

local parser = require("llm.parser")

-- The curated input vectors. Each exercises a distinct path of the algorithm.
-- full_text is the whole buffer; tail_text is its trailing slice; block is the
-- raw model output. min/max are the word limits the caller resolves.
local VECTORS = {
	{
		id = "basic_completion_no_tags",
		description = "Plain completion with no TAIL_CORRECTED/NEXT_WORDS tags.",
		full_text = "je suis ", tail_text = "je suis ",
		block = "content de vous voir", min_words = 1, max_words = 15,
	},
	{
		id = "advanced_full_tail_correction",
		description = "Advanced format, whole tail word corrected, then new words.",
		full_text = "je envoit", tail_text = "je envoit",
		block = "TAIL_CORRECTED: je envoie\nNEXT_WORDS: ce mail", min_words = 1, max_words = 15,
	},
	{
		id = "advanced_tail_unchanged_only_new",
		description = "Advanced format, tail matches exactly, only new words follow.",
		full_text = "bonjour comment", tail_text = "bonjour comment",
		block = "TAIL_CORRECTED: bonjour comment\nNEXT_WORDS: allez vous", min_words = 1, max_words = 15,
	},
	{
		id = "advanced_partial_intra_word",
		description = "Advanced format, intra-word correction (messieu -> messieurs).",
		full_text = "bonjour messieu", tail_text = "bonjour messieu",
		block = "TAIL_CORRECTED: bonjour messieurs\nNEXT_WORDS: ravi", min_words = 1, max_words = 15,
	},
	{
		id = "advanced_word_cap_two",
		description = "max_words=2 truncates the NEXT_WORDS continuation.",
		full_text = "je ", tail_text = "je ",
		block = "TAIL_CORRECTED: je\nNEXT_WORDS: suis tres content de vous", min_words = 1, max_words = 2,
	},
	{
		id = "advanced_empty_next_words",
		description = "Advanced format with empty NEXT_WORDS — only the correction.",
		full_text = "je envoit", tail_text = "je envoit",
		block = "TAIL_CORRECTED: je envoie\nNEXT_WORDS: ", min_words = 1, max_words = 15,
	},
	{
		id = "empty_block_discarded",
		description = "Empty model output is discarded (nil).",
		full_text = "hello", tail_text = "hello",
		block = "", min_words = 1, max_words = 15,
	},
	{
		id = "advanced_suffix_append",
		description = "Tail correction appends a suffix to the last word (cat -> cats).",
		full_text = "the cat", tail_text = "the cat",
		block = "TAIL_CORRECTED: the cats\nNEXT_WORDS: are here", min_words = 1, max_words = 15,
	},
	{
		id = "advanced_accented_intra_word",
		description = "Accented intra-word correction (prefere -> préfère).",
		full_text = "je prefere", tail_text = "je prefere",
		block = "TAIL_CORRECTED: je préfère\nNEXT_WORDS: ce choix", min_words = 1, max_words = 15,
	},
	{
		id = "advanced_apostrophe_insert",
		description = "Correction inserts a typographic apostrophe (l envoie -> l'envoie).",
		full_text = "je l envoie", tail_text = "je l envoie",
		block = "TAIL_CORRECTED: je l'envoie\nNEXT_WORDS: demain", min_words = 1, max_words = 15,
	},
	{
		id = "advanced_multi_word_change",
		description = "A whole word is replaced (beau -> froid) then new words.",
		full_text = "il fait beau", tail_text = "il fait beau",
		block = "TAIL_CORRECTED: il fait froid\nNEXT_WORDS: ce matin", min_words = 1, max_words = 15,
	},
	{
		id = "advanced_overlap_dup_word",
		description = "tc tail and nw head share a word — the overlap must be stripped.",
		full_text = "je vais", tail_text = "je vais",
		block = "TAIL_CORRECTED: je vais\nNEXT_WORDS: vais manger", min_words = 1, max_words = 15,
	},
	{
		id = "advanced_punctuation_next",
		description = "NEXT_WORDS begins with punctuation (no space inserted before it).",
		full_text = "bonjour", tail_text = "bonjour",
		block = "TAIL_CORRECTED: bonjour\nNEXT_WORDS: , comment allez", min_words = 1, max_words = 15,
	},
	{
		id = "advanced_long_buffer_window",
		description = "Buffer longer than the 60-char context window; correction near the end.",
		full_text = "this is a fairly long buffer of context exceeding sixty chars here weater",
		tail_text = "here weater",
		block = "TAIL_CORRECTED: here weather\nNEXT_WORDS: today", min_words = 1, max_words = 15,
	},
	{
		id = "advanced_append_only_no_change",
		description = "Tail matches exactly across several words; only an append.",
		full_text = "the cat sat", tail_text = "the cat sat",
		block = "TAIL_CORRECTED: the cat sat\nNEXT_WORDS: on the mat", min_words = 1, max_words = 15,
	},
	{
		id = "basic_next_prefix_stripped",
		description = "Basic (no tags): a leading NEXT: label is stripped.",
		full_text = "hello ", tail_text = "hello ",
		block = "NEXT: world how are you", min_words = 1, max_words = 15,
	},
	{
		id = "advanced_word_cap_one",
		description = "max_words=1 keeps a single new word.",
		full_text = "je ", tail_text = "je ",
		block = "TAIL_CORRECTED: je\nNEXT_WORDS: suis tres content", min_words = 1, max_words = 1,
	},
}




-- ==================================
-- ==================================
-- ======= 1/ JSON serialisation ====
-- ==================================
-- ==================================

-- Escape a Lua string into a JSON string body (no surrounding quotes).
local function json_escape(s)
	s = s:gsub("\\", "\\\\")
	s = s:gsub('"', '\\"')
	s = s:gsub("\n", "\\n")
	s = s:gsub("\r", "\\r")
	s = s:gsub("\t", "\\t")
	return s
end

local function jstr(s) return '"' .. json_escape(tostring(s)) .. '"' end
local function jbool(b) return b and "true" or "false" end

-- Serialise the PHYSICAL parity fields of a prediction result (or nil) into a
-- compact JSON object. chunks are intentionally excluded (display-only, per-driver).
local function serialize_expected(pred)
	if pred == nil then
		return '{ "is_nil": true }'
	end
	return string.format(
		'{ "is_nil": false, "deletes": %d, "to_type": %s, "nw": %s, "has_corrections": %s, "disable_bold": %s }',
		tonumber(pred.deletes) or 0,
		jstr(pred.to_type or ""),
		jstr(pred.nw or ""),
		jbool(pred.has_corrections and true or false),
		jbool(pred.disable_bold and true or false))
end




-- ===================================
-- ===================================
-- ======= 2/ Generate + write =======
-- ===================================
-- ===================================

local lines = {}
table.insert(lines, "{")
table.insert(lines, '\t"$schema": "./process_prediction_vectors.schema.json",')
table.insert(lines, '\t"description": "Cross-driver golden corpus for the LLM semantic-diff parser (process_prediction). Generated from the shared Lua oracle by tools/build/gen-process-prediction-corpus.lua. Parity contract = physical fields only (deletes/to_type/nw/has_corrections/disable_bold); chunks are display-only and excluded.",')
table.insert(lines, '\t"version": 1,')
table.insert(lines, '\t"vectors": [')

for idx, v in ipairs(VECTORS) do
	local pred = parser.process_prediction(v.full_text, v.tail_text, v.block,
		{ min_words = v.min_words, max_words = v.max_words })
	local obj = {}
	table.insert(obj, '\t\t{')
	table.insert(obj, '\t\t\t"id": ' .. jstr(v.id) .. ',')
	table.insert(obj, '\t\t\t"description": ' .. jstr(v.description) .. ',')
	table.insert(obj, '\t\t\t"full_text": ' .. jstr(v.full_text) .. ',')
	table.insert(obj, '\t\t\t"tail_text": ' .. jstr(v.tail_text) .. ',')
	table.insert(obj, '\t\t\t"block": ' .. jstr(v.block) .. ',')
	table.insert(obj, '\t\t\t"min_words": ' .. tostring(v.min_words) .. ',')
	table.insert(obj, '\t\t\t"max_words": ' .. tostring(v.max_words) .. ',')
	table.insert(obj, '\t\t\t"expected": ' .. serialize_expected(pred))
	table.insert(obj, '\t\t}' .. (idx < #VECTORS and "," or ""))
	table.insert(lines, table.concat(obj, "\n"))

	-- Human-readable summary to stderr so it never pollutes the JSON file.
	if pred == nil then
		io.stderr:write(string.format("  %-32s -> nil (discarded)\n", v.id))
	else
		io.stderr:write(string.format("  %-32s -> deletes=%d to_type=%q nw=%q\n",
			v.id, tonumber(pred.deletes) or 0, pred.to_type or "", pred.nw or ""))
	end
end

table.insert(lines, "\t]")
table.insert(lines, "}")

local OUT = ROOT .. "/static/ergopti_plus/_shared/tests/corpus/llm/process_prediction_vectors.json"
local fh = assert(io.open(OUT, "w"))
fh:write(table.concat(lines, "\n") .. "\n")
fh:close()
io.stderr:write("\nWrote " .. #VECTORS .. " vectors to " .. OUT .. "\n")
