--- tests/unit/modules/hotstrings/engine/test_hotstring_cascade.lua

--- ==============================================================================
--- MODULE: Hotstring Cascade — Unit Tests (shared engine, Linux)
--- DESCRIPTION:
--- With `cascade_max_arrows` above 1 the text a hotstring produced may complete further
--- hotstrings: `chatg` gives `chatgpt` and `chatgpt` gives `ChatGPT`, so typing
--- `chatg` ends on `ChatGPT` from 2 arrows. The engine resolves the whole chain on
--- a virtual buffer and returns ONE net edit (one erase count, one text), which
--- is what the injector sends and what an Undo restores. Pinned here: 1 arrow is
--- today's behaviour, 2 and 3 arrows, the same-spec guard, a final_result link, an
--- end character that is replayed or swallowed, the per-step gate, and the net
--- edit's trigger. The same scenarios are pinned on Windows
--- (test_hotstring_cascade.ahk) and macOS (test_hotstring_cascade.lua).
--- ==============================================================================

local helpers = require("tests.helpers")

local Engine = require("hotstring_engine")

--- Builds an engine from mappings (auto_expand unless stated).
--- @param mappings table Array of mapping tables.
--- @return table engine
local function engine_with(mappings)
	local engine = Engine.new()
	engine:load_mappings(mappings)
	return engine
end

--- Types a string through on_char, applying every expansion like the daemon does.
--- @param engine table
--- @param text string ASCII text.
--- @param options table on_char options (cascade_max_arrows, ...).
--- @return table|nil last The last result that fired.
local function type_text(engine, text, options)
	local last
	for ch in text:gmatch(".") do
		local result = engine:on_char(ch, options)
		if result then
			last = result
			if result.final_result then engine:reset() else engine:apply_expansion(result) end
		end
	end
	return last
end

local CHAIN = {
	{ trigger = "chatg", replacement = "chatgpt", auto_expand = true },
	{ trigger = "chatgpt", replacement = "ChatGPT", auto_expand = true, is_case_sensitive_strict = true },
}

helpers.describe("shared engine: the hotstring cascade", function()

	helpers.it("cascade, one arrow and an absent count are today's behaviour", function()
		for _, options in ipairs({ { cascade_max_arrows = 1 }, {} }) do
			local engine = engine_with(CHAIN)
			local result = type_text(engine, "chatg", options)
			helpers.assert_eq("chatgpt", result.replacement, "the output is final")
			helpers.assert_eq(5, result.backspace_count)
			helpers.assert_eq("chatgpt", engine:current_buffer())
			helpers.assert_eq(nil, result.cascade_steps, "no chain was resolved")
		end
	end)

	helpers.it("cascade, two arrows return ONE net edit: chatg gives ChatGPT", function()
		local engine = engine_with(CHAIN)
		local result = type_text(engine, "chatg", { cascade_max_arrows = 2 })
		helpers.assert_eq("ChatGPT", result.replacement, "the last link's text")
		helpers.assert_eq(5, result.backspace_count, "what the user typed is erased once")
		helpers.assert_eq("chatg", result.trigger, "the erased text is what was typed")
		helpers.assert_eq(2, result.cascade_steps)
		helpers.assert_eq("ChatGPT", engine:current_buffer(), "the buffer follows the chain")
	end)

	helpers.it("cascade, two arrows stop after one more link, three go on", function()
		local three = {
			{ trigger = "ab", replacement = "cd", auto_expand = true },
			{ trigger = "cd", replacement = "ef", auto_expand = true },
			{ trigger = "ef", replacement = "gh", auto_expand = true },
		}
		local engine = engine_with(three)
		type_text(engine, "ab", { cascade_max_arrows = 2 })
		helpers.assert_eq("ef", engine:current_buffer())
		engine = engine_with(three)
		type_text(engine, "ab", { cascade_max_arrows = 3 })
		helpers.assert_eq("gh", engine:current_buffer())
	end)

	helpers.it("cascade, a replacement that ends with its own trigger does not loop", function()
		local engine = engine_with({ { trigger = "ab", replacement = "xab", auto_expand = true } })
		local result = type_text(engine, "ab", { cascade_max_arrows = 6 })
		helpers.assert_eq("xab", result.replacement)
		helpers.assert_eq("xab", engine:current_buffer(), "the same spec never fires twice in one chain")
	end)

	helpers.it("cascade, the guard folds case: the UPPER output of a rule is the same spec", function()
		local engine = engine_with({ { trigger = "ab", replacement = "xAB", auto_expand = true,
			is_case_sensitive = true } })
		type_text(engine, "ab", { cascade_max_arrows = 6 })
		helpers.assert_eq("xAB", engine:current_buffer())
	end)

	helpers.it("cascade, a final_result link ends the chain, and the net edit stays final", function()
		local engine = engine_with({
			{ trigger = "ab", replacement = "cd", auto_expand = true, final_result = true },
			{ trigger = "cd", replacement = "ef", auto_expand = true },
		})
		local result = type_text(engine, "ab", { cascade_max_arrows = 4 })
		helpers.assert_eq("cd", result.replacement, "nothing may chain off a final result")
		engine = engine_with({
			{ trigger = "ab", replacement = "cd", auto_expand = true },
			{ trigger = "cd", replacement = "ef", auto_expand = true, final_result = true },
			{ trigger = "ef", replacement = "gh", auto_expand = true },
		})
		result = engine:on_char("a", { cascade_max_arrows = 4 })
		result = engine:on_char("b", { cascade_max_arrows = 4 })
		helpers.assert_eq("ef", result.replacement)
		helpers.assert_eq(true, result.final_result, "the chain ended on a final link")
	end)

	helpers.it("cascade, the second link may reach back into the text typed before the first", function()
		local engine = engine_with({
			{ trigger = "ab", replacement = "cd", auto_expand = true },
			{ trigger = "xcd", replacement = "YZ", auto_expand = true },
		})
		engine:on_char("x", { cascade_max_arrows = 2 })
		engine:on_char("a", { cascade_max_arrows = 2 })
		local result = engine:on_char("b", { cascade_max_arrows = 2 })
		helpers.assert_eq("YZ", result.replacement)
		helpers.assert_eq(3, result.backspace_count, "x, a and b are erased: the net edit reaches back")
		helpers.assert_eq("xab", result.trigger, "an Undo restores the text that was really erased")
	end)

	helpers.it("cascade, a private link is never composed into another hotstring's output", function()
		local engine = engine_with({
			{ trigger = "ab", replacement = "cd", auto_expand = true },
			{ trigger = "cd", replacement = "ef", auto_expand = true, is_private = true },
		})
		local result = type_text(engine, "ab", { cascade_max_arrows = 2 })
		helpers.assert_eq("cd", result.replacement, "the private link takes no part")
		engine = engine_with({
			{ trigger = "ab", replacement = "cd", auto_expand = true, is_private = true },
			{ trigger = "cd", replacement = "ef", auto_expand = true },
		})
		result = type_text(engine, "ab", { cascade_max_arrows = 2 })
		helpers.assert_eq("cd", result.replacement, "a private first hotstring starts no chain")
	end)

	helpers.it("cascade, the per-step gate can refuse a link, keeping the first one", function()
		local engine = engine_with(CHAIN)
		local asked = {}
		local result = type_text(engine, "chatg", { cascade_max_arrows = 2, cascade_gate = function(step)
			asked[#asked + 1] = step
			return false
		end })
		helpers.assert_eq("chatgpt", result.replacement, "the refused link is not applied")
		helpers.assert_eq(1, #asked)
		helpers.assert_eq("chatgpt", asked[1].trigger)
		helpers.assert_eq("ChatGPT", asked[1].replacement)
	end)

	helpers.it("cascade, a link produced from output carries the time of the expander", function()
		local engine = engine_with(CHAIN)
		local gap
		type_text(engine, "chatg", { cascade_max_arrows = 2, typed_at_ms = 1000, cascade_gate = function(step)
			gap = step.expander_gap_ms
			return true
		end })
		helpers.assert_eq(0, gap, "a trigger wholly inside the output has no typing pause")
	end)

	helpers.it("cascade, rejects an invalid arrow count loudly and keeps the first link", function()
		local engine = engine_with(CHAIN)
		local result = type_text(engine, "chatg", { cascade_max_arrows = 0 })
		helpers.assert_eq("chatgpt", result.replacement)
		helpers.assert_eq(false, Engine.valid_cascade_max_arrows(1.5))
		helpers.assert_eq(false, Engine.valid_cascade_max_arrows(0), "zero arrows is not a chain")
		helpers.assert_eq(false, Engine.valid_cascade_max_arrows(11), "ten is the longest chain")
		helpers.assert_eq(true, Engine.valid_cascade_max_arrows(1))
		helpers.assert_eq(true, Engine.valid_cascade_max_arrows(10))
	end)

end)

helpers.describe("shared engine: the cascade and Backspace undo", function()

	--- The screen after the daemon injects a result: erase, type, replay the terminator.
	local function inject(screen, result)
		local kept = screen:sub(1, #screen - result.backspace_count)
		return kept .. result.replacement .. (result.end_char and not result.consume_terminator
			and result.terminator or "")
	end

	--- The screen after the daemon's Undo: erase what was typed back, type the trigger.
	local function undo(screen, result)
		local typed_back = result.replacement .. (result.end_char and not result.consume_terminator
			and result.terminator or "")
		return screen:sub(1, #screen - #typed_back) .. result.trigger
			.. (result.end_char and not result.consume_terminator and result.terminator or "")
	end

	helpers.it("cascade, an Undo restores what was typed, not a half-way text", function()
		local engine = engine_with(CHAIN)
		local result = type_text(engine, "chatg", { cascade_max_arrows = 2 })
		local screen = inject("chatg", result)
		helpers.assert_eq("ChatGPT", screen)
		helpers.assert_eq("chatg", undo(screen, result), "one Undo gives back the typed trigger")
	end)

	helpers.it("cascade, an Undo restores the text a later link reached back over", function()
		local engine = engine_with({
			{ trigger = "ab", replacement = "cd", auto_expand = true },
			{ trigger = "xcd", replacement = "YZ", auto_expand = true },
		})
		local options = { cascade_max_arrows = 2 }
		engine:on_char("x", options); engine:on_char("a", options)
		local result = engine:on_char("b", options)
		local screen = inject("xab", result)
		helpers.assert_eq("YZ", screen)
		helpers.assert_eq("xab", undo(screen, result))
	end)

	helpers.it("cascade, an Undo after an end character puts the trigger and the terminator back", function()
		local engine = engine_with({
			{ trigger = "ab", replacement = "cd", auto_expand = false },
			{ trigger = "cd", replacement = "ef", auto_expand = false },
		})
		local options = { cascade_max_arrows = 2 }
		engine:on_char("a", options); engine:on_char("b", options)
		options.is_terminator = true
		local result = engine:on_char(" ", options)
		local screen = inject("ab ", result)
		helpers.assert_eq("ef ", screen)
		helpers.assert_eq("ab ", undo(screen, result), "the typed trigger and its space")
	end)

end)

helpers.describe("shared engine: the cascade and end characters", function()

	local END_CHAIN = {
		{ trigger = "ab", replacement = "cd", auto_expand = false },
		{ trigger = "cd", replacement = "ef", auto_expand = false },
	}

	helpers.it("cascade, an end-character link cascades into another end-character link", function()
		local engine = engine_with(END_CHAIN)
		local options = { cascade_max_arrows = 2, is_terminator = false }
		engine:on_char("a", options)
		engine:on_char("b", options)
		options.is_terminator = true
		local result = engine:on_char(" ", options)
		helpers.assert_eq("ef", result.replacement, "the same space ends the second link")
		helpers.assert_eq(3, result.backspace_count, "ab and the space are erased once")
		helpers.assert_eq(true, result.end_char)
		helpers.assert_eq(" ", result.terminator, "the space is replayed once")
	end)

	helpers.it("cascade, one arrow leaves the end-character chain to the next keystroke", function()
		local engine = engine_with(END_CHAIN)
		engine:on_char("a"); engine:on_char("b")
		local result = engine:on_char(" ", { is_terminator = true })
		helpers.assert_eq("cd", result.replacement)
	end)

	helpers.it("cascade, a consumed delimiter still lets the end-character chain run, then swallows it once", function()
		local engine = engine_with(END_CHAIN)
		local options = { cascade_max_arrows = 2 }
		engine:on_char("a", options); engine:on_char("b", options)
		options.is_terminator = true
		options.terminator_consumed = true
		local result = engine:on_char(" ", options)
		helpers.assert_eq("ef", result.replacement, "the chain gives the same text as for an unconsumed delimiter")
		helpers.assert_eq(3, result.backspace_count, "ab and the space are erased once")
		helpers.assert_eq(true, result.consume_terminator, "the delimiter's choice is reported")
		engine:apply_expansion(result)
		helpers.assert_eq("ef", engine:current_buffer(), "the swallowed space is not in the buffer")
	end)

	helpers.it("cascade, a link that would swallow the typed end character ends the chain instead", function()
		local engine = engine_with({
			{ trigger = "ab", replacement = "cd", auto_expand = false },
			{ trigger = "cd ", replacement = "X", auto_expand = true },
		})
		local options = { cascade_max_arrows = 2 }
		engine:on_char("a", options); engine:on_char("b", options)
		options.is_terminator = true
		local result = engine:on_char(" ", options)
		helpers.assert_eq("cd", result.replacement, "the end character the user typed always lands after the text")
		helpers.assert_eq(true, result.end_char)
		helpers.assert_eq(" ", result.terminator)
	end)

	helpers.it("cascade, a word-start-only link never fires in the middle of a word", function()
		local engine = engine_with({
			{ trigger = "fb", replacement = "facebook", auto_expand = false, is_word = true },
			{ trigger = "ok", replacement = "OK", auto_expand = true, is_word = true },
		})
		local options = { cascade_max_arrows = 3 }
		engine:on_char("f", options); engine:on_char("b", options)
		options.is_terminator = true
		local result = engine:on_char(" ", options)
		helpers.assert_eq("facebook", result.replacement, "'ok' ends facebook but is not at a word start")
		-- Typed on its own, at a word start, the same rule fires.
		local alone = type_text(engine_with({ { trigger = "ok", replacement = "OK", auto_expand = true,
			is_word = true } }), "ok", { cascade_max_arrows = 3 })
		helpers.assert_eq("OK", alone.replacement)
	end)

end)

--- Replays the shared cascade_vectors.json corpus: the same rules, keystrokes and
--- expected text on the three drivers, so the end-character and arrow-count rules
--- cannot drift apart.
local function corpus_vectors()
	local path = helpers.driver_root() .. "/../_shared/tests/corpus/hotstrings/cascade_vectors.json"
	local file = assert(io.open(path, "rb"))
	local raw = file:read("*a")
	file:close()
	local corpus = assert(require("json").decode(raw), "cascade_vectors.json must be valid JSON")
	assert(#corpus.vectors > 0, "cascade_vectors.json must hold vectors")
	return corpus.vectors
end

helpers.describe("shared engine: the shared cascade_vectors.json corpus", function()
	for _, vector in ipairs(corpus_vectors()) do
		helpers.it(vector.id .. " (cascade-corpus)", function()
			local mappings = {}
			for _, rule in ipairs(vector.rules) do
				mappings[#mappings + 1] = {
					trigger           = rule.trigger,
					replacement       = rule.replacement,
					auto_expand       = rule.auto == true,
					is_word           = rule.word_start == true,
					is_case_sensitive = rule.case_sensitive == true,
				}
			end
			local engine = engine_with(mappings)
			local expansions = 0
			local function feed(ch, options)
				local result = engine:on_char(ch, options)
				if not result then return end
				expansions = expansions + 1
				if result.final_result then engine:reset() else engine:apply_expansion(result) end
			end
			local typed_options = { cascade_max_arrows = vector.max_arrows }
			for ch in vector.typed:gmatch("[%z\1-\127\194-\244][\128-\191]*") do feed(ch, typed_options) end
			if vector.end_char ~= "" then
				feed(vector.end_char, {
					cascade_max_arrows  = vector.max_arrows,
					is_terminator       = true,
					terminator_consumed = vector.end_char_consumed == true,
				})
			end
			helpers.assert_eq(vector.expect_buffer, engine:current_buffer(), vector.description)
			helpers.assert_eq(vector.expect_expansions, expansions, "one send for the whole chain")
		end)
	end
end)
