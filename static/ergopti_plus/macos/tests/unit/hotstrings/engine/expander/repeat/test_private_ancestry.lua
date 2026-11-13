--- tests/unit/hotstrings/engine/expander/repeat/test_private_ancestry.lua

--- ==============================================================================
--- MODULE: Repeat Private Ancestry Regression Tests
--- DESCRIPTION:
--- URM-001: a character the magic-key repeat derives from the span a private
--- expansion marked is itself a secret-derived scalar. It must reach synthetic
--- telemetry as private, extend the AI privacy mark and keep its value out of
--- the DEBUG log, while text typed publicly after the span repeats as before.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Loads a fresh expander wired to the real synthetic-input adapter.
--- @param opts table Buffer, private mark and magic-key overrides.
--- @return table fixture
local function load_fixture(opts)
	local notifications, marks = {}, {}
	package.loaded["modules.keystats"] = {
		notify_synthetic = function(text, source, deletes, variant, _, is_private)
			notifications[#notifications + 1] = {
				text = text, source = source, deletes = deletes, variant = variant, private = is_private,
			}
		end,
	}
	package.loaded["hotstrings.engine.expander.expander"] = nil
	package.loaded["hotstrings.engine.expander.terminator_replay"] = nil
	local expander = helpers.load_with_stubs("hotstrings.engine.expander.expander")
	local synthetic = require("platform.input.synthetic_input")
	local state = {
		buffer = opts.buffer,
		llm_private_mark = opts.mark or "",
		magic_key = "★",
		is_repeat_feature_enabled = function() return true end,
		suppress_rescan = function() end,
	}
	expander.init(state, {}, {
		get_llm_enabled = function() return false end,
		is_runtime_available = function() return true end,
		start_timer = function() end,
		mark_private_context = function(buffer)
			marks[#marks + 1] = buffer
			state.llm_private_mark = buffer
		end,
	})
	return {
		expander = expander, synthetic = synthetic, state = state,
		notifications = notifications, marks = marks,
		cleanup = function()
			package.loaded["modules.keystats"] = nil
			package.loaded["hotstrings.engine.expander.expander"] = nil
			package.loaded["hotstrings.engine.expander.terminator_replay"] = nil
		end,
	}
end


--- Fires one repeat inside a real callback collector.
--- @param fixture table
--- @return boolean fired
local function fire_repeat(fixture)
	fixture.synthetic.enter_callback()
	local fired = fixture.expander.try_repeat_feature("★", true)
	fixture.synthetic.leave_callback(fired)
	return fired
end


helpers.describe("keymap expander: repeat keeps private ancestry (URM-001)", function()
	helpers.it("a scalar repeated from the private span stays private and extends the mark", function()
		local fixture = load_fixture({ buffer = "2840175123456★", mark = "2840175123456" })
		helpers.assert_true(fire_repeat(fixture), "the repeat itself still fires")
		helpers.assert_eq(fixture.state.buffer, "28401751234566")
		helpers.assert_eq(fixture.notifications[1].private, true,
			"the derived scalar must reach synthetic telemetry as private")
		helpers.assert_eq(fixture.marks[1], "28401751234566",
			"the AI privacy mark must cover the repeated scalar")
		fixture.state.buffer = fixture.state.buffer .. "★"
		helpers.assert_true(fire_repeat(fixture))
		helpers.assert_eq(fixture.notifications[2].private, true, "a second repeat stays private")
		fixture.cleanup()
	end)

	helpers.it("text typed publicly after the private span repeats as public", function()
		local fixture = load_fixture({ buffer = "2840175123456 ab★", mark = "2840175123456" })
		helpers.assert_true(fire_repeat(fixture))
		helpers.assert_eq(fixture.notifications[1].private, false)
		helpers.assert_eq(#fixture.marks, 0, "a public repeat must not touch the privacy mark")
		fixture.cleanup()
	end)

	helpers.it("an ordinary repeat with no mark stays public", function()
		local fixture = load_fixture({ buffer = "ab★" })
		helpers.assert_true(fire_repeat(fixture))
		helpers.assert_eq(fixture.notifications[1].private, false)
		fixture.cleanup()
	end)
end)
