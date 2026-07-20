--- tests/unit/modules/keymap/test_lifecycle_preserves_interceptors.lua

--- ==============================================================================
--- MODULE: Regression — keymap.stop() must not destroy hooks start() cannot rebuild
--- DESCRIPTION:
--- Audit finding G2. M.stop() ended with
---   CoreState.interceptors      = {}
---   CoreState.preview_providers = {}
--- but the ONLY writers of those two tables are M.register_interceptor and
--- M.register_preview_provider, which dynamic_hotstrings calls exactly once at
--- boot. M.start() restarts the taps, the watchdog and the prewarm timer — it has
--- no re-registration step. So a stop()/start() cycle left the consumer loops
--- iterating empty tables forever.
---
--- Repro: menu "Tout désactiver" then "Tout activer" → `@nom★` no longer expands
--- and the dynamic-hotstring preview is dead until a full reload. Static TOML
--- hotstrings keep working (they live in the registry, not in these tables), so
--- the failure looks arbitrary.
---
--- Fix: stop clearing them. They are already inert while the tap is stopped —
--- both are only consulted from onKeyDownRaw, which cannot run once tap:stop()
--- has been called.
---
--- The assertions below are INVOCATION-based on purpose: they drive a real
--- keyDown through the captured tap callback and a real update_preview after the
--- stop/start cycle. Asserting that the sentinels actually ran (rather than that
--- a source line is absent) is what stops this test from going false-green if the
--- wipe is later reintroduced somewhere else in the lifecycle.
--- ==============================================================================

local helpers = require("tests.helpers")

-- "a" — a plain letter keycode, deliberately absent from FAST_EXIT_KEYCODES so
-- the event reaches the interceptor loop.
local KEYCODE_A = 0


--- Loads modules.keymap with an eventtap stub that captures each tap's callback.
--- The taps are created at module load time, so the override must be in place
--- before the require.
--- @return table KM, table taps The keymap module and the captured tap handles.
local function load_keymap_capturing_taps()
	-- Drop every cached keymap sub-module so llm_bridge / expander / registry are
	-- re-bound to the CoreState created by THIS load, not a previous test's.
	-- modules.llm.* goes too: llm_bridge captures `prediction_engine` at require
	-- time, and earlier test files in a full-suite run leave a PARTIAL stub of it
	-- in package.loaded (no get_llm_enabled), which would make update_preview
	-- raise here for a reason unrelated to what this test asserts.
	for name in pairs(package.loaded) do
		if type(name) == "string"
			and (name:match("^modules%.keymap") or name:match("^modules%.llm")) then
			package.loaded[name] = nil
		end
	end

	local base = require("tests.stubs.hs").eventtap
	local taps = {}
	local et = {}
	for k, v in pairs(base) do et[k] = v end
	et.new = function(_types, cb)
		local t = {
			started   = false,
			start     = function(self) self.started = true ; return self end,
			stop      = function(self) self.started = false ; return self end,
			isEnabled = function(self) return self.started end,
			callback  = cb,
		}
		table.insert(taps, t)
		return t
	end

	local KM = helpers.load_with_stubs("modules.keymap", { eventtap = et })
	return KM, taps
end

--- Builds a synthetic keyDown event exposing the accessors onKeyDownRaw uses.
--- @param chars string The character the keystroke produces.
--- @return table The fake event.
local function fake_key_event(chars)
	return {
		getKeyCode    = function() return KEYCODE_A end,
		getFlags      = function() return {} end,
		getCharacters = function() return chars end,
		getProperty   = function() return -1 end,
	}
end


helpers.describe("keymap lifecycle: a stop/start cycle preserves runtime hooks", function()
	helpers.it("the interceptor and preview provider still fire after stop() then start()", function()
		local KM, taps = load_keymap_capturing_taps()

		local interceptor_calls = 0
		local provider_calls    = 0

		-- Registered ONCE, exactly as dynamic_hotstrings does at boot.
		KM.register_interceptor(function(_event, _buffer)
			interceptor_calls = interceptor_calls + 1
			return nil  -- pass through, like the real date-rule interceptor on a miss
		end)
		KM.register_preview_provider(function(_buf)
			provider_calls = provider_calls + 1
			return nil  -- no match, so the tooltip pipeline is not entered
		end)

		-- The disable/enable round-trip the menu performs.
		KM.start()
		KM.stop()
		KM.start()

		local key_tap = taps[1]
		helpers.assert_not_nil(key_tap, "the keyDown tap must have been created")
		helpers.assert_type(key_tap.callback, "function", "the keyDown tap must carry a callback")

		-- Drive a real keystroke through the tap callback.
		key_tap.callback(fake_key_event("a"))
		helpers.assert_true(interceptor_calls > 0,
			"the interceptor registered at boot must still run after a stop/start cycle — "
			.. "wiping CoreState.interceptors in stop() kills @-tag expansion permanently")

		-- Drive the preview path. Autocorrect preview must be on, otherwise
		-- update_preview early-returns before reaching the provider loop.
		KM.set_preview_autocorrect_enabled(true)
		local LLMBridge = require("modules.keymap.llm_bridge")
		LLMBridge.update_preview("abc")
		helpers.assert_true(provider_calls > 0,
			"the preview provider registered at boot must still run after a stop/start cycle — "
			.. "wiping CoreState.preview_providers in stop() kills the dynamic-hotstring preview")
	end)
end)
