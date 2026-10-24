--- tests/unit/modules/keymap/repeat/test_repeat_feature_arm_time.lua

--- ==============================================================================
--- MODULE: Repeat Feature Synthetic Transaction Regression Tests
--- DESCRIPTION:
--- Exercises try_repeat_feature through the production expander, TextSender, and
--- SyntheticInput adapter. Deleting the magic key and emitting the repeated
--- character must form one tagged replacement transaction, and consecutive
--- repeats must receive distinct immutable generations even in the same tick.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Loads a fresh expander wired to the real synthetic-input adapter.

--- @param opts table|nil Optional buffer and magic-key overrides.
--- @return table fixture
local function load_fixture(opts)
	opts = opts or {}
	local notifications = {}
	package.loaded["modules.keystats"] = {
		notify_synthetic = function(text, source, deletes, variant)
			notifications[#notifications + 1] = {
				text = text, source = source, deletes = deletes, variant = variant,
			}
		end,
	}
	package.loaded["modules.keymap.expander"] = nil
	package.loaded["modules.keymap.terminator_replay"] = nil

	local expander = helpers.load_with_stubs("modules.keymap.expander")
	local synthetic = require("adapters.synthetic_input")
	local state = {
		buffer = opts.buffer or "ab★",
		magic_key = opts.magic_key or "★",
		is_repeat_feature_enabled = function() return true end,
		suppress_rescan = function() end,
	}
	expander.init(state, {}, {
		get_llm_enabled = function() return false end,
		is_runtime_available = function() return true end,
		start_timer = function() end,
	})
	return {
		expander = expander,
		synthetic = synthetic,
		state = state,
		notifications = notifications,
		hs = require("hs"),
		cleanup = function()
			package.loaded["modules.keystats"] = nil
			package.loaded["modules.keymap.expander"] = nil
			package.loaded["modules.keymap.terminator_replay"] = nil
		end,
	}
end


--- Fires one ignored-window repeat inside a real callback collector.
--- @param fixture table
--- @return table events
local function fire_repeat(fixture, chars)
	fixture.synthetic.enter_callback()
	local fired = fixture.expander.try_repeat_feature(chars or "★", true)
	local consume, events = fixture.synthetic.leave_callback(fired)
	helpers.assert_true(fired, "the repeat feature must fire for a valid magic event")
	helpers.assert_true(consume)
	helpers.assert_not_nil(events)
	return events
end


helpers.describe("keymap expander: repeat uses an explicit replacement transaction", function()
	helpers.it("tags the delete and repeated character with one generation", function()
		local fixture = load_fixture()
		local events = fire_repeat(fixture)
		helpers.assert_eq(#events, 4,
			"ignored-window repeat must return Backspace down/up and text down/up")
		helpers.assert_eq(fixture.state.buffer, "abb")

		local property = fixture.hs.eventtap.event.properties.eventSourceUserData
		local first = fixture.synthetic.lookup_tag(events[1]:getProperty(property))
		local last = fixture.synthetic.lookup_tag(events[4]:getProperty(property))
		helpers.assert_true(first and first.owned and last and last.owned)
		helpers.assert_eq(first.owner, "repeat_key")
		helpers.assert_eq(first.effect, "replacement")
		helpers.assert_eq(first.generation, last.generation,
			"delete and insertion must be indivisible members of one replacement")
		helpers.assert_eq(first.ordinal, 1)
		helpers.assert_eq(last.ordinal, 2)
		fixture.cleanup()
	end)

	helpers.it("allocates a new generation for an immediate consecutive repeat", function()
		local fixture = load_fixture()
		local first_events = fire_repeat(fixture)
		fixture.state.buffer = fixture.state.buffer .. "★"
		local second_events = fire_repeat(fixture)

		local property = fixture.hs.eventtap.event.properties.eventSourceUserData
		local first = fixture.synthetic.lookup_tag(first_events[1]:getProperty(property))
		local second = fixture.synthetic.lookup_tag(second_events[1]:getProperty(property))
		helpers.assert_true(first and second)
		helpers.assert_true(first.generation ~= second.generation,
			"transaction identity must not collapse two producers that run in the same tick")
		helpers.assert_eq(fixture.state.buffer, "abbb")
		fixture.cleanup()
	end)

	helpers.it("deletes both codepoints of a French composite magic event", function()
		local NBSP = string.char(0xC2, 0xA0)
		local physical_magic = NBSP .. ":"
		local fixture = load_fixture({
			buffer = "ab" .. physical_magic,
			magic_key = ":",
		})
		local events = fire_repeat(fixture, physical_magic)

		helpers.assert_eq(#events, 6,
			"two physical carrier/key codepoints need two Backspace pairs plus one text pair")
		helpers.assert_eq(fixture.state.buffer, "abb",
			"the raw carrier and punctuation must both leave the logical buffer")
		helpers.assert_eq(#fixture.notifications, 1)
		helpers.assert_eq(fixture.notifications[1].deletes, 2,
			"keystats reconciliation must delete the same two codepoints as the screen")
		helpers.assert_eq(fixture.notifications[1].variant, "repeat_key")
		fixture.cleanup()
	end)
end)


--- Decodes one shared hotstrings corpus file.
--- @param name string File name under _shared/tests/corpus/hotstrings.
--- @return table vectors
local function corpus_vectors(name)
	local fh = assert(io.open(helpers.shared("tests/corpus/hotstrings/" .. name), "rb"))
	local raw = fh:read("*a")
	fh:close()
	local ok, corpus = pcall(require("hs").json.decode, raw)
	assert(ok and #corpus.vectors > 0, name .. " must be valid JSON holding vectors")
	return corpus.vectors
end

helpers.describe("keymap expander: the shared repeat_key_vectors.json corpus", function()
	for _, vector in ipairs(corpus_vectors("repeat_key_vectors.json")) do
		helpers.it(vector.id .. " (repeat-key-corpus)", function()
			local fixture = load_fixture({ buffer = vector.buffer, magic_key = vector.magic_key })
			fixture.state.start_is_word_boundary = vector.start_is_word_boundary ~= false
			fixture.synthetic.enter_callback()
			local fired = fixture.expander.try_repeat_feature(vector.magic_key, true)
			fixture.synthetic.leave_callback(fired)
			helpers.assert_eq(fired, vector.fires, vector.description)
			if vector.fires then
				local expected = vector.buffer:sub(1, #vector.buffer - #vector.magic_key) .. vector.replacement
				helpers.assert_eq(fixture.state.buffer, expected, vector.description)
			end
			fixture.cleanup()
		end)
	end
end)

helpers.describe("keymap expander: the shared idle_reset_vectors.json corpus", function()
	local Core = require("hotstring_engine")
	for _, vector in ipairs(corpus_vectors("idle_reset_vectors.json")) do
		helpers.it(vector.id .. " (idle-reset-corpus)", function()
			-- A JSON null decodes to nil or a sentinel: only a number is a keystroke time.
			local last = type(vector.last_ms) == "number" and vector.last_ms or nil
			helpers.assert_eq(Core.idle_resets_word(last, vector.now_ms, vector.idle_seconds, 0),
				vector.resets, vector.description)
		end)
	end
end)
