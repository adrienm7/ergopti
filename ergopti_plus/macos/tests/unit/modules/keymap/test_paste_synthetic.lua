--- tests/unit/modules/keymap/test_paste_synthetic.lua

--- ==============================================================================
--- MODULE: keymap.utils paste provenance
--- DESCRIPTION:
--- Clipboard output has no character-by-character keyboard echo. These tests
--- exercise the real SyntheticInput collector and prove that the Cmd+V pair is
--- owned by one immutable tagged batch, while ordinary typed text is represented
--- by its own tagged key pairs. Untagged physical input remains outside both.
--- ==============================================================================

local helpers = require("tests.helpers")


local function load_fixture()
	for _, name in ipairs({
		"modules.keymap.utils", "adapters.synthetic_input",
		"adapters.event_provenance", "adapters.timer_scheduler",
		"infra.logger", "infra.timings",
	}) do
		package.loaded[name] = nil
	end
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.timings"] = {
		sec = function(_, key)
			return key == "clipboard_restore_ms" and 0.15 or 0.08
		end,
	}

	return {
		hs = hs_stub,
		synthetic = require("adapters.synthetic_input"),
		utils = require("modules.keymap.utils"),
	}
end


local function collect(fixture, emitter)
	fixture.synthetic.enter_callback()
	local results = table.pack(emitter())
	local consume, events = fixture.synthetic.leave_callback()
	return results, consume, events
end


local function tag_of(fixture, event)
	local property = fixture.hs.eventtap.event.properties.eventSourceUserData
	return fixture.synthetic.lookup_tag(event:getProperty(property))
end


local function assert_one_pair(fixture, events, key)
	helpers.assert_not_nil(events)
	helpers.assert_eq(#events, 2)
	helpers.assert_eq(events[1].key, key)
	helpers.assert_eq(events[2].key, key)
	local down = tag_of(fixture, events[1])
	local up = tag_of(fixture, events[2])
	helpers.assert_true(down.owned and up.owned)
	helpers.assert_eq(down.generation, up.generation)
	helpers.assert_eq(down.batch, up.batch)
	helpers.assert_eq(down.ordinal, 1)
	helpers.assert_eq(up.ordinal, 1)
	helpers.assert_eq(down.phase, "down")
	helpers.assert_eq(up.phase, "up")
	return down
end


helpers.describe("KU.emit_text: immutable paste provenance", function()
	helpers.it("returns the full logical result and one tagged Cmd+V pair for long text", function()
		local fixture = load_fixture()
		local long_text = ("a"):rep(60)
		local results, consume, events = collect(fixture, function()
			return fixture.utils.emit_text(long_text)
		end)

		helpers.assert_true(consume)
		helpers.assert_eq(results[1], 60)
		helpers.assert_eq(results[2], "")
		helpers.assert_eq(results[3], long_text)
		helpers.assert_true(results[4] > 0,
			"clipboard output must expose its target-settle fence")
		local metadata = assert_one_pair(fixture, events, "v")
		helpers.assert_eq(metadata.owner, "ambient.callback")
		helpers.assert_eq(metadata.effect, "action")
	end)

	helpers.it("uses the same tagged Cmd+V contract for high Unicode text", function()
		local fixture = load_fixture()
		local emoji = "\xF0\x9F\x98\x80"
		local results, _, events = collect(fixture, function()
			return fixture.utils.emit_text(emoji)
		end)

		helpers.assert_eq(results[1], 1)
		helpers.assert_eq(results[2], "")
		helpers.assert_eq(results[3], emoji)
		assert_one_pair(fixture, events, "v")
	end)

	helpers.it("rejects non-string input without opening a transaction", function()
		local fixture = load_fixture()
		local before = fixture.synthetic.stats().generation
		local results, consume, events = collect(fixture, function()
			return fixture.utils.emit_text(nil)
		end)

		helpers.assert_eq(results[1], 0)
		helpers.assert_eq(results[2], "")
		helpers.assert_eq(results[3], "")
		helpers.assert_eq(consume, false)
		helpers.assert_nil(events)
		helpers.assert_eq(fixture.synthetic.stats().generation, before)
	end)

	helpers.it("represents short text as ordered tagged character pairs", function()
		local fixture = load_fixture()
		local results, consume, events = collect(fixture, function()
			return fixture.utils.emit_text("hi")
		end)

		helpers.assert_true(consume)
		helpers.assert_eq(results[1], 2)
		helpers.assert_eq(results[2], "hi")
		helpers.assert_eq(results[3], "hi")
		helpers.assert_eq(results[4], 0)
		helpers.assert_eq(#events, 4)
		local first = tag_of(fixture, events[1])
		local second = tag_of(fixture, events[3])
		helpers.assert_eq(first.generation, second.generation)
		helpers.assert_eq(first.batch, second.batch)
		helpers.assert_eq(first.ordinal, 1)
		helpers.assert_eq(second.ordinal, 2)
	end)
end)


helpers.describe("KU.emit_tokens: immutable paste provenance", function()
	helpers.it("returns the logical token text and one tagged Cmd+V pair", function()
		local fixture = load_fixture()
		local long_text = ("b"):rep(60)
		local results, _, events = collect(fixture, function()
			return fixture.utils.emit_tokens({ { kind = "text", value = long_text } })
		end)

		helpers.assert_eq(results[1], 60)
		helpers.assert_eq(results[2], "")
		helpers.assert_eq(results[3], long_text)
		assert_one_pair(fixture, events, "v")
	end)

	helpers.it("assigns a fresh generation to each independent paste", function()
		local fixture = load_fixture()
		local function emit(value)
			local _, _, events = collect(fixture, function()
				return fixture.utils.emit_text(value)
			end)
			return tag_of(fixture, events[1])
		end

		local first = emit(("c"):rep(60))
		local second = emit(("d"):rep(60))
		helpers.assert_true(second.generation > first.generation,
			"independent producers must never share mutable ownership state")
	end)

	helpers.it("never classifies an untagged physical Cmd+V as owned output", function()
		local fixture = load_fixture()
		local _, _, events = collect(fixture, function()
			return fixture.utils.emit_text(("e"):rep(60))
		end)
		assert_one_pair(fixture, events, "v")

		helpers.assert_nil(fixture.synthetic.lookup_tag(0),
			"an untagged physical paste must remain distinguishable from our batch")
	end)
end)
