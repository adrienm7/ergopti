--- tests/unit/modules/hotstrings/engine/test_output_token_vectors.lua

--- ==============================================================================
--- MODULE: Tokens of a hotstring output (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/hotstrings/output_token_vectors.json, which the
--- macOS and Windows suites replay too, through modules.hotstrings.output_tokens,
--- then runs an output through the shared engine and reads the evdev events the
--- injector writes.
---
--- ROOT CAUSE ENCODED:
--- The Linux driver had no token grammar at all: inject() typed the output, so
--- {Left}, {Enter} and {U+XXXX} reached the application as characters, or through
--- the clipboard when the layout could not type a brace.
--- ==============================================================================

local restore_loaded = require("tests.helpers").keep_loaded({ "adapters.keyboard_hook" })
local helpers = require("tests.helpers")
local json = require("json")
local OutputTokens = require("modules.hotstrings.output_tokens")
local EvdevCodes = require("infra.evdev_codes")

local CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/hotstrings/output_token_vectors.json"

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the output token corpus is not valid JSON")
end

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

--- Loads the injector over a recording channel and a layout that types `chars`.
--- @param chars string
--- @return table injector, table events, table code_of
local function with_recorder(chars)
	local layout_table, code_of, code = {}, {}, 200
	for index = 1, #chars do
		local char = chars:sub(index, index)
		layout_table[char] = { keycode = code, level = 1, mods = {} }
		code_of[char] = code
		code = code + 1
	end
	local layout = helpers.load_module("adapters.keyboard_layout")
	layout._set_table_for_test(layout_table)
	package.loaded["adapters.keyboard_layout"] = layout
	package.loaded["adapters.keyboard_hook"] = {
		held_text_modifier_codes = function() return {} end,
	}
	local injector = helpers.load_module("modules.hotstrings.injector")
	local events = {}
	injector._set_uinput({
		is_open = function() return true end,
		emit = function(key, value)
			events[#events + 1] = key .. ":" .. value
			return true
		end,
	})
	return injector, events, code_of
end

--- @param codes table Keycodes, pressed in order.
--- @return table The expected down and up pairs.
local function presses(codes)
	local out = {}
	for _, code in ipairs(codes) do
		out[#out + 1] = code .. ":1"
		out[#out + 1] = code .. ":0"
	end
	return out
end

helpers.describe("hotstring outputs replay the shared token corpus", function()
	local corpus = read_corpus()

	helpers.it("the corpus is loaded", function()
		helpers.assert_true(#corpus.vectors >= 40, "the corpus must hold its vectors")
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("output token vector '" .. vector.id .. "'", function()
			local parsed = OutputTokens.parse(vector.output)
			helpers.assert_eq(shape(parsed.tokens), shape(vector.tokens), vector.id .. ": tokens")
			helpers.assert_eq(parsed.text, vector.text, vector.id .. ": typed text")
			helpers.assert_eq(parsed.has_keys, vector.has_keys, vector.id .. ": has_keys")
		end)
	end
end)

helpers.describe("the injector plays output tokens", function()
	helpers.it("output token: {left} is the Left key, in order with the text and the terminator", function()
		local injector, events, code_of = with_recorder("ab ")
		local result = injector.inject_tokens(2, OutputTokens.parse("ab{left}").tokens, false, " ")
		helpers.assert_true(result.ok, tostring(result.error))
		local expected = presses({ EvdevCodes.KEY_BACKSPACE, EvdevCodes.KEY_BACKSPACE,
			code_of.a, code_of.b, 105, code_of[" "] })
		helpers.assert_eq(table.concat(events, " "), table.concat(expected, " "))
	end)

	helpers.it("output token: a count presses the key that many times", function()
		local injector, events = with_recorder("")
		local result = injector.inject_tokens(0, OutputTokens.parse("{Left 3}").tokens, false)
		helpers.assert_true(result.ok, tostring(result.error))
		helpers.assert_eq(table.concat(events, " "), table.concat(presses({ 105, 105, 105 }), " "))
	end)

	helpers.it("output token: inject() still types the characters of a token", function()
		local injector, events, code_of = with_recorder("{Left}")
		local result = injector.inject(0, "{Left}", false)
		helpers.assert_true(result.ok, tostring(result.error))
		helpers.assert_eq(table.concat(events, " "), table.concat(presses({
			code_of["{"], code_of.L, code_of.e, code_of.f, code_of.t, code_of["}"] }), " "),
			"a prediction holding these characters must not press anything")
	end)
end)

helpers.describe("the shared engine and output tokens", function()
	local Engine = require("hotstring_engine")

	--- @param mappings table
	--- @return table engine
	local function engine_with(mappings)
		local engine = Engine.new()
		helpers.assert_true(engine:load_mappings(mappings))
		return engine
	end

	local function feed(engine, text, options)
		local result
		for char in text:gmatch(".") do result = engine:on_char(char, options or {}) end
		return result
	end

	helpers.it("output token: the result says it presses a key", function()
		local replacement, has_keys = OutputTokens.resolve("ab{left}")
		local engine = engine_with({ { trigger = "qq", replacement = replacement, auto_expand = true,
			has_key_tokens = has_keys } })
		local result = feed(engine, "qq")
		helpers.assert_eq(result.has_key_tokens, true)
		helpers.assert_eq(result.replacement, "ab{left}")
	end)

	helpers.it("output token: the shipped {U+XXXX} symbols reach the engine as characters", function()
		local loader = helpers.load_module("modules.hotstrings.loader")
		local catalogue = loader.load_catalogue({
			require("infra.paths").shared("modules/hotstrings/magickey.toml"),
		})
		local found = 0
		for _, mapping in ipairs(catalogue.mappings) do
			helpers.assert_true(mapping.replacement:find("{U+", 1, true) == nil,
				"'" .. mapping.trigger .. "' would type its code")
			if mapping.trigger:find("$hyph.nobreak$", 1, true) then
				helpers.assert_eq(mapping.replacement, "\226\128\145", "U+2011 is the character")
				found = found + 1
			end
		end
		helpers.assert_true(found > 0, "the shipped entry must be there to pin")
	end)

	helpers.it("output token: a loaded key token survives every copy up to the engine", function()
		local path = os.tmpname() .. ".toml"
		local fh = assert(io.open(path, "w"))
		fh:write('[[tokens]]\n"qq" = { output = "ab{left}", is_word = false, auto_expand = true,'
			.. ' is_case_sensitive = true, final_result = false }\n')
		fh:close()
		local loader = helpers.load_module("modules.hotstrings.loader")
		local catalogue = loader.load_catalogue({ path })
		os.remove(path)
		helpers.assert_eq(#catalogue.mappings, 1, "the fixture entry loads")
		local engine = engine_with(catalogue.mappings)
		local result = feed(engine, "qq")
		helpers.assert_eq(result.has_key_tokens, true, "the flag crosses the loader and the engine")
		helpers.assert_eq(result.replacement, "ab{left}", "and the daemon reads the tokens from it")
	end)

	helpers.it("output token: a code point is the character from the loader on", function()
		local replacement, has_keys = OutputTokens.resolve("{U+00E9}")
		helpers.assert_eq(replacement, "\195\169")
		helpers.assert_eq(has_keys, false)
	end)

	helpers.it("output token: a key token starts no cascade and joins none", function()
		local engine = engine_with({
			{ trigger = "gh", replacement = "ij{Left}", auto_expand = true, has_key_tokens = true },
			{ trigger = "ij", replacement = "never", auto_expand = true },
			{ trigger = "ab", replacement = "cd", auto_expand = true },
			{ trigger = "cd", replacement = "ef{Left}", auto_expand = true, has_key_tokens = true },
		})
		helpers.assert_eq(feed(engine, "gh", { cascade_max_arrows = 3 }).replacement, "ij{Left}", "starts none")
		engine:reset()
		local joined = feed(engine, "ab", { cascade_max_arrows = 3 })
		helpers.assert_eq(joined.replacement, "cd", "joins none")
		helpers.assert_true(not joined.has_key_tokens, "the plain first step is what fires")
	end)
end)

restore_loaded()
