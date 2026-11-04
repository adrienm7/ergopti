--- tests/unit/modules/hotstrings/engine/test_hotstring_final_result.lua

--- ==============================================================================
--- MODULE: Final-result hotstrings — Unit Tests (shared engine, Linux)
--- DESCRIPTION:
--- Replays the shared final_result_vectors.json corpus through the real engine,
--- applying each result the way the daemon does (ergopti_hotstrings.lua): erase,
--- type, then keep or forget the buffer. The same corpus runs on Windows
--- (test_hotstring_final_result.ahk) and macOS (test_hotstring_final_result.lua).
--- ==============================================================================

local helpers = require("tests.helpers")

local Engine = require("hotstring_engine")

--- Reads the shared corpus.
--- @return table corpus
local function load_corpus()
	local path = helpers.driver_root() .. "/../_shared/tests/corpus/hotstrings/final_result_vectors.json"
	local file = assert(io.open(path, "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw), "final_result_vectors.json must be valid JSON")
end

--- Whether a typed character is an end character in this corpus.
--- @param ch string One character.
--- @return boolean
local function is_end_char(ch)
	return ch == " " or ch == "\t" or ch == "\n"
end

--- Types `typed` into a fresh engine holding `rules`.
--- @param rules table Corpus rules.
--- @param typed string The typed characters.
--- @param max_arrows number hotstrings.cascade_max_arrows.
--- @return string screen What the application shows.
local function replay(rules, typed, max_arrows)
	local mappings = {}
	for _, rule in ipairs(rules) do
		mappings[#mappings + 1] = {
			trigger                  = rule.trigger,
			replacement              = rule.replacement,
			auto_expand              = rule.auto == true,
			is_word                  = rule.word_start == true,
			priority                 = rule.priority,
			final_result             = rule.final_result == true,
			is_case_sensitive        = rule.case_sensitive == true,
			is_case_sensitive_strict = rule.case_sensitive == true,
		}
	end
	local engine = Engine.new()
	engine:load_mappings(mappings)
	local screen = {}
	for ch in typed:gmatch(".") do
		screen[#screen + 1] = ch
		local result = engine:on_char(ch, { is_terminator = is_end_char(ch), cascade_max_arrows = max_arrows })
		if result then
			for _ = 1, result.backspace_count do table.remove(screen) end
			for out in result.replacement:gmatch(".") do screen[#screen + 1] = out end
			if result.replay_terminator then screen[#screen + 1] = result.replay_terminator end
			if result.final_result then engine:reset() else engine:apply_expansion(result) end
		end
	end
	return table.concat(screen)
end

local CORPUS = load_corpus()

helpers.describe("shared engine: the shared final_result_vectors.json corpus", function()
	local matrix = CORPUS.matrix
	for _, personal_auto in ipairs(matrix.personal_auto) do
		for _, bundled_auto in ipairs(matrix.bundled_auto) do
			for _, case_sensitive in ipairs(matrix.case_sensitive) do
				for _, output in ipairs(matrix.output) do
					for _, arrows in ipairs(matrix.max_arrows) do
						for _, end_char in ipairs(matrix.end_char) do
							local name = string.format("(hotstring-final-result) personal_auto=%s bundled_auto=%s cs=%s output=%s arrows=%d end=%d",
								tostring(personal_auto), tostring(bundled_auto), tostring(case_sensitive), output, arrows, end_char:byte())
							helpers.it(name, function()
								local screen = replay({
									{ trigger = matrix.trigger, replacement = output, auto = personal_auto, word_start = true,
										priority = matrix.personal_priority, final_result = true, case_sensitive = case_sensitive },
									{ trigger = matrix.trigger, replacement = matrix.bundled, auto = bundled_auto, word_start = true,
										priority = matrix.bundled_priority },
								}, matrix.trigger .. end_char, arrows)
								helpers.assert_eq(screen, output .. end_char, name)
							end)
						end
					end
				end
			end
		end
	end

	for _, vector in ipairs(CORPUS.vectors) do
		helpers.it(vector.id .. " (hotstring-final-result)", function()
			helpers.assert_eq(replay(vector.rules, vector.typed, vector.max_arrows), vector.expect_screen, vector.description)
		end)
	end
end)
