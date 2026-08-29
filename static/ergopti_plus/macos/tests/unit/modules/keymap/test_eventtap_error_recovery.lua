--- tests/unit/modules/keymap/test_eventtap_error_recovery.lua

--- ==============================================================================
--- MODULE: Regression — keyDown error recovery reconciles native eventtap state
--- DESCRIPTION:
--- A keyDown callback failure enters a last-chance eventtap recovery path. That
--- path used to call isEnabled() outside protection, then discard start() errors.
--- A transient state-probe exception therefore escaped the callback; an
--- activated-then-throw restart could also be reported as a recovery without
--- proving whether the native tap was actually live.
---
--- This test drives the real callback through both native boundary behaviours.
--- The callback must contain the probe exception, attempt one immediate restart,
--- reconcile the post-error native state, and return with the exact tap enabled.
--- ==============================================================================

local helpers = require("tests.helpers")

local RESET_MODULES = {
	"adapters.event_provenance", "adapters.synthetic_input",
	"infra.logger", "infra.text_utils",
	"modules.hotstrings.hotstrings_config", "modules.keylogger",
	"modules.keymap", "modules.keymap.init", "modules.keymap.expander",
	"modules.keymap.llm_bridge", "modules.keymap.registry",
	"modules.keymap.state", "modules.keymap.terminator_replay",
	"modules.keymap.utils", "modules.llm", "modules.llm.prediction_engine",
	"ui.tooltip",
}


local function load_fixture()
	for _, name in ipairs(RESET_MODULES) do package.loaded[name] = nil end
	for name in pairs(package.loaded) do
		if type(name) == "string"
			and (name:match("^modules%.keymap") or name:match("^modules%.llm")) then
			package.loaded[name] = nil
		end
	end
	package.loaded["modules.keymap.utils"] = setmetatable({
		is_ignored_window = function() return false, 0 end,
		is_secure_field = function() return false end,
	}, { __index = function() return function() return true end end })

	local base = require("tests.stubs.hs").eventtap
	local taps = {}
	local eventtap = {}
	for key, value in pairs(base) do eventtap[key] = value end
	eventtap.new = function(types, callback)
		local tap = {
			types = types,
			callback = callback,
			enabled = false,
			start_calls = 0,
			probe_calls = 0,
		}
		function tap:start()
			self.start_calls = self.start_calls + 1
			self.enabled = true
			if taps[1] == self then error("native start raised after activation") end
			return self
		end
		function tap:stop()
			self.enabled = false
			return self
		end
		function tap:isEnabled()
			self.probe_calls = self.probe_calls + 1
			if taps[1] == self and self.probe_calls == 1 then
				error("transient native state-probe failure")
			end
			return self.enabled
		end
		taps[#taps + 1] = tap
		return tap
	end

	local keymap = helpers.load_with_stubs("modules.keymap", { eventtap = eventtap })
	return keymap, taps
end


helpers.describe("keymap keyDown failure recovery", function()
	helpers.it("contains a throwing probe and reconciles an activated-then-throw restart", function()
		local keymap, taps = load_fixture()
		local keydown_tap = taps[1]
		helpers.assert_not_nil(keydown_tap, "the keyDown eventtap must be captured")
		helpers.assert_type(keydown_tap.callback, "function")

		local event = {
			getProperty = function() return -1 end,
			getKeyCode = function() return 0 end,
			getFlags = function() return {} end,
			getCharacters = function() error("causal keyDown accessor failure") end,
		}
		keydown_tap.callback(event)
		helpers.assert_eq(keydown_tap.start_calls, 1,
			"a failed state probe must conservatively trigger one immediate restart")
		helpers.assert_true(keydown_tap.enabled,
			"the activated exact tap must remain the recovered native owner")
		helpers.assert_eq(keydown_tap.probe_calls, 2,
			"the restart exception must be reconciled against one post-state probe")
		helpers.assert_type(keymap, "table")
	end)
end)
