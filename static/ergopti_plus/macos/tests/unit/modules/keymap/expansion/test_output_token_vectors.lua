--- tests/unit/modules/keymap/expansion/test_output_token_vectors.lua

--- ==============================================================================
--- MODULE: Tokens of a hotstring output replay the shared vectors (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/hotstrings/output_token_vectors.json, which the
--- Linux and Windows suites replay too, through send_input.parse_output and the
--- emitter's tokens_from_repl, over the real vocabulary.
---
--- ROOT CAUSE ENCODED:
--- macOS kept its own short key table: {bs}, {pgup}, {Left 2} and every shipped
--- {U+XXXX} symbol were typed as text, and a {Left} left the buffer claiming the
--- caret still sat behind the replacement.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local SendInput = require("send_input")

local function read_shared(relative)
	local fh = assert(io.open(helpers.shared(relative), "r"), "cannot open " .. relative)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), relative .. " is not valid JSON")
end

local corpus = read_shared("tests/corpus/hotstrings/output_token_vectors.json")
local vocabulary = read_shared("modules/actions/send_keys.json")

--- @param tokens table Tokens of parse_output, or of the corpus.
--- @return string One comparable line.
local function shape(tokens)
	local out = {}
	for _, token in ipairs(tokens) do
		if token.kind == "text" then out[#out + 1] = "[" .. token.value .. "]"
		elseif token.kind == "key" then out[#out + 1] = "<" .. token.id .. "*" .. token.count .. ">"
		elseif token.key then out[#out + 1] = "<" .. token.key .. "*" .. token.count .. ">"
		else out[#out + 1] = "[" .. token.text .. "]" end
	end
	return table.concat(out)
end

helpers.describe("hotstring outputs replay the shared token corpus", function()
	helpers.it("the corpus is loaded", function()
		helpers.assert_true(#corpus.vectors >= 40, "the corpus must hold its vectors")
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("output token vector '" .. vector.id .. "'", function()
			local parsed = SendInput.parse_output(vector.output, vocabulary)
			helpers.assert_eq(shape(parsed.tokens), shape(vector.tokens), vector.id .. ": tokens")
			helpers.assert_eq(parsed.text, vector.text, vector.id .. ": typed text")
			helpers.assert_eq(parsed.has_keys, vector.has_keys, vector.id .. ": has_keys")
		end)
	end
end)

helpers.describe("the emitter plays the grammar with Hammerspoon key names", function()
	local Shared = require("keymap.utils")
	local function vocab() return vocabulary end

	helpers.it("a counted key is that many key tokens", function()
		local tokens = Shared.tokens_from_repl('""{Left 2}', vocab)
		helpers.assert_eq(#tokens, 3)
		helpers.assert_eq(tokens[1].value, '""')
		helpers.assert_eq(tokens[2].value, "left")
		helpers.assert_eq(tokens[3].value, "left")
	end)

	helpers.it("backspace and delete keep their Hammerspoon names", function()
		local tokens = Shared.tokens_from_repl("{bs}{del}", vocab)
		helpers.assert_eq(tokens[1].value, "delete")
		helpers.assert_eq(tokens[2].value, "forwarddelete")
	end)

	helpers.it("plain text never reads the vocabulary", function()
		local tokens = Shared.tokens_from_repl("plain", function() error("read for plain text") end)
		helpers.assert_eq(tokens[1].value, "plain")
	end)
end)

--- Loads the real expander and emitter over a stubbed OS, as the no-op suite does.
--- @param buffer string The typed text.
--- @return table fixture
local function load_expander(buffer)
	for name in pairs(package.loaded) do
		if type(name) == "string" and (
			name:match("^modules%.keymap") or name == "modules.keystats"
			or name:match("^adapters%.") or name == "infra.logger" or name == "infra.timings"
		) then
			package.loaded[name] = nil
		end
	end
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.timings"] = {
		ms = function() return 5 end,
		sec = function(_, key) return key == "clipboard_restore_ms" and 0.15 or 0.08 end,
	}
	package.loaded["modules.keystats"] = {
		notify_synthetic = function() end,
		set_buffer = function() end,
		log_hotstring = function() end,
	}
	package.loaded["adapters.tooltip_renderer"] = { hide = function() end }
	package.loaded["adapters.file_system"] = {
		read = function()
			local fh = assert(io.open(helpers.shared("modules/actions/send_keys.json"), "r"))
			local raw = fh:read("*a")
			fh:close()
			return raw
		end,
	}
	package.loaded["adapters.json_codec"] = { decode = json.decode }
	local synthetic = require("adapters.synthetic_input")
	local expander = require("modules.keymap.expander")
	local state = {
		buffer = buffer, magic_key = "\226\152\133", start_is_word_boundary = true,
		start_is_line_start = true,
		is_repeat_feature_enabled = function() return false end,
		suppress_rescan = function() end,
		prepare_suppress_rescan = function() return 1 end,
		commit_suppress_rescan = function() end,
	}
	expander.init(state, {
		is_terminator = function(value) return value == " " end,
		terminator_is_consumed = function() return false end,
		mappings_for_tail = function() return {} end,
	}, {
		update_preview = function() end,
		get_llm_enabled = function() return false end,
		start_timer = function() end,
	})
	return { synthetic = synthetic, expander = expander, state = state }
end

--- @param trigger string
--- @param output string The output as the registry stores it.
--- @param plain string Its typed text alone.
--- @param is_private boolean|nil
--- @return table A registry mapping.
local function mapping(trigger, output, plain, is_private)
	return {
		trigger = trigger, trigger_bytes = #trigger, tlen = #trigger,
		repl = output, plain_repl = plain, is_word = false, auto = true,
		match_mode = "exact", final_result = true, is_private = is_private,
	}
end

--- @param events table Quartz events of one batch.
--- @return string What the application receives, key downs only.
local function downs(events)
	local parts = {}
	for _, event in ipairs(events) do
		if event.isDown then parts[#parts + 1] = event.unicode or ("{" .. tostring(event.key) .. "}") end
	end
	return table.concat(parts)
end

helpers.describe("a fired output with a key token (macOS)", function()
	helpers.it("output token: {left} is pressed and the buffer is forgotten", function()
		local fixture = load_expander("qq")
		fixture.synthetic.enter_callback()
		local fired = fixture.expander.try_auto_expand(mapping("qq", "ab{left}", "ab"), 1, false)
		local _, events = fixture.synthetic.leave_callback(fired)
		helpers.assert_true(fired, "the mapping fires")
		helpers.assert_eq(downs(events), "{delete}ab{left}", "one erase, the text, then the arrow")
		helpers.assert_eq(fixture.state.buffer, "", "the caret moved: the buffer cannot hold the text")
		helpers.assert_eq(fixture.state.start_is_word_boundary, false, "the next text starts nowhere known")
		helpers.assert_eq(fixture.state.start_is_line_start, false, "and not at a known empty line")
	end)

	helpers.it("output token: a terminator trigger forgets the buffer too", function()
		local fixture = load_expander("qq ")
		local entry = mapping("qq", "ab{left}", "ab")
		entry.auto = false
		fixture.synthetic.enter_callback()
		local fired = fixture.expander.try_terminator_expand(entry, " ", 1, false)
		fixture.synthetic.leave_callback(fired)
		helpers.assert_true(fired, "the mapping fires")
		helpers.assert_eq(fixture.state.buffer, "", "the buffer is forgotten after a terminator trigger")
	end)

	helpers.it("output token: a plain output keeps its text in the buffer", function()
		local fixture = load_expander("qq")
		fixture.synthetic.enter_callback()
		local fired = fixture.expander.try_auto_expand(mapping("qq", "ab", "ab"), 1, false)
		fixture.synthetic.leave_callback(fired)
		helpers.assert_true(fired, "the mapping fires")
		helpers.assert_eq(fixture.state.buffer, "ab", "the positive control")
	end)

	helpers.it("output token: the registry form of an output resolves text and keeps keys", function()
		load_expander("")
		local KU = require("modules.keymap.utils")
		local text, text_keys = KU.resolve_output("{U+27C3}")
		helpers.assert_eq(text, "\226\159\131", "a shipped symbol is its character")
		helpers.assert_eq(text_keys, false)
		local escaped = KU.resolve_output("{{}Left}")
		helpers.assert_eq(escaped, "{Left}", "the written-out form is the six characters")
		local raw, raw_keys = KU.resolve_output("ab{Left}")
		helpers.assert_eq(raw, "ab{Left}", "the output with a key stays as written")
		helpers.assert_eq(raw_keys, true)
	end)
end)
