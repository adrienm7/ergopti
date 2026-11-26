--- tests/unit/hotstrings/engine/dynamic/personal_info/test_personal_tag_case.lua

--- ==============================================================================
--- MODULE: Personal @-Tag Case (hcd-5-tag-case)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/personal_info/tag_case_vectors.json through the
--- macOS resolver (`_resolve_combo_for_test`), which every @-tag expansion goes
--- through. A personal tag follows the typed case, one field per letter
--- (maintainer decision HCD-5, 2026-11-21); macOS used to fold the case, so
--- `@Np★` typed « Nom Prénom ». Windows and Linux replay the same vectors.
--- ==============================================================================

local helpers = require("tests.helpers")

local PersonalInfo = helpers.load_with_stubs("hotstrings.engine.dynamic.personal_info")

--- Reads the shared vectors.
--- @return table
local function read_corpus()
	local fh = assert(io.open(helpers.shared("tests/corpus/personal_info/tag_case_vectors.json"), "r"))
	local raw = fh:read("*a")
	fh:close()
	local ok, corpus = pcall(require("hs").json.decode, raw)
	assert(ok, "tag-case corpus is not valid JSON")
	return corpus
end

helpers.describe("personal @-tag case: the shared corpus (hcd-5-tag-case)", function()
	local corpus = read_corpus()
	for _, vector in ipairs(corpus.vectors) do
		helpers.it(vector.id .. " (hcd-5-tag-case)", function()
			local values = PersonalInfo._resolve_combo_for_test(corpus.info, corpus.letters, vector.tag)
			helpers.assert_eq(table.concat(vector.values, "|"), table.concat(values, "|"),
				"the typed values of @" .. vector.tag)
		end)
	end
end)




-- ===========================================================
-- ===========================================================
-- ======= 2/ The dynamic category's delay (hcd-4) ===========
-- ===========================================================
-- ===========================================================

--- One physical key for the interceptor.
--- @param char string
--- @return table
local function key(char)
	return {
		getFlags = function() return { cmd = false, ctrl = false } end,
		getKeyCode = function() return 0 end,
		getCharacters = function() return char end,
	}
end

--- Boots the real interceptor against a keymap whose delay verdict is given.
--- @param within boolean The keymap's dynamic delay verdict.
--- @return function interceptor, table record, table module
local function boot(within)
	package.loaded["hotstrings.engine.dynamic.personal_info"] = nil
	package.loaded["modules.keystats"] = {}
	package.loaded["hotstrings.ui.personal_info_editor"] = {}
	package.loaded["platform.input.synthetic_input"] = {
		emit_key_stroke = function() return true end,
		emit_key_strokes = function() return true end,
	}
	local record = { asked = {}, injected = 0 }
	local interceptor
	local keymap = {
		get_trigger_char = function() return "★" end,
		register_interceptor = function(callback) interceptor = callback end,
		dynamic_rule_within_delay = function(section, elapsed)
			record.asked[#record.asked + 1] = { section = section, elapsed = elapsed }
			return within
		end,
		register_preview_provider = function() end,
		classify_trigger = function() return false, false, false end,
		inject_dynamic = function()
			record.injected = record.injected + 1
			return true
		end,
	}
	local PI = helpers.load_with_stubs("hotstrings.engine.dynamic.personal_info")
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	file:write('[info]\nlast_name = "Nom"\n\n[letters]\nn = "last_name"\n')
	file:close()
	PI.start("", keymap, path, function(_, publish) return publish() end)
	PI.enable()
	os.remove(path)
	helpers.assert_type(interceptor, "function", "personal_info must register its interceptor")
	return interceptor, record, PI
end

helpers.describe("personal @-tags: the dynamic category's delay (hcd-4-personal-delay)", function()
	for _, case in ipairs({ { within = true, verdict = "consume", injected = 1 },
		{ within = false, verdict = nil, injected = 0 } }) do
		helpers.it("a tag " .. (case.within and "within" or "past") .. " the delay (hcd-4-personal-delay)", function()
			local interceptor, record, PI = boot(case.within)
			interceptor(key("@"), "", { elapsed = 0.1 })
			interceptor(key("n"), "@", { elapsed = 0.1 })
			local verdict = interceptor(key("★"), "@n", { elapsed = 0.7 })
			PI.stop()
			helpers.assert_eq(case.verdict, verdict, "the magic key's verdict")
			helpers.assert_eq(case.injected, record.injected, "what was typed")
			helpers.assert_eq(1, #record.asked, "the delay is asked once, at the magic key")
			helpers.assert_eq("personal_info", record.asked[1].section, "the personal section of the dynamic family")
			helpers.assert_eq(0.7, record.asked[1].elapsed, "the gap before the magic key")
		end)
	end
end)
