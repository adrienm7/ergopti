--- tests/unit/ui/test_escape_owned_by_trap.lua

--- ==============================================================================
--- MODULE: Regression — Escape belongs to the trap, not to the dismissal
---         watchers (escape-owned-by-trap)
--- DESCRIPTION:
--- Pressing Escape to dismiss a tooltip also opened Raycast. The keystroke was
--- reaching the application instead of being consumed.
---
--- ROOT CAUSE ENCODED: two taps compete for Escape. The persistent trap consumes
--- it — but only `if tooltip.is_visible()`, since Escape must pass through
--- normally when nothing is on screen. The dismissal watchers are created on
--- every render, so they are always NEWER than the trap and run first: they hid
--- the tooltip and returned false, and by the time the trap ran the tooltip was
--- already invisible. That is precisely the trap's signal to let Escape through,
--- so the key reached the app on every dismissal after the first show.
---
--- The ordering makes this unfixable from the trap's side — it cannot tell "no
--- tooltip was ever shown" from "a watcher just hid one microseconds ago". The
--- watchers must therefore not touch Escape at all. Both of them: the LLM
--- predictions tooltip and the hotstring preview, which had the identical list.
---
--- Escape still dismisses: the trap calls reset_predictions → engine.reset →
--- tooltip.hide_forced(), which hides BOTH surfaces. Ignoring the key in the
--- watchers removes a duplicate dismissal, not the dismissal.
--- ==============================================================================

local helpers = require("tests.helpers")

local KEYCODE_ESCAPE = 53
local KEYCODE_LETTER_A = 0

--- Builds a fake keyDown event carrying a keycode.
--- @param keycode number
--- @return table
local function fake_key_event(keycode)
	return {
		getKeyCode    = function() return keycode end,
		getFlags      = function() return {} end,
		getCharacters = function() return "" end,
	}
end

--- Loads tooltip_llm, captures the keyDown watcher callback the render path
--- mounts, and shows a prediction so the watcher is live.
--- @return table module, function|nil keydown_callback
local function load_with_keydown_watcher()
	local T = helpers.load_with_stubs("ui.tooltip.tooltip_llm")
	package.loaded["ui.tooltip.renderer"] = {
		render = function(_blocks, _state, on_shown) if type(on_shown) == "function" then on_shown() end end,
		hide   = function() end,
		canvas = { minimumTextSize = function() return { w = 100, h = 20 } end },
	}
	package.loaded["ui.tooltip.tooltip_llm"] = nil
	T = require("ui.tooltip.tooltip_llm")

	-- Installed AFTER load_with_stubs: the harness rebuilds the hs stub, so a spy
	-- set beforehand is discarded and nothing would be captured.
	local callbacks = {}
	local real_new = hs.eventtap.new
	hs.eventtap.new = function(types, fn)
		callbacks[#callbacks + 1] = { types = types, fn = fn }
		return real_new and real_new(types, fn) or { start = function() end, stop = function() end }
	end

	T.show_predictions({ "prédiction" }, 1, true)

	-- Selected by the event type it was mounted for, not by index and not by
	-- "whichever callback dismisses". The mouse watcher dismisses on ANY call
	-- because it ignores its argument entirely, so a behavioural probe picks IT
	-- first and every Escape assertion below would then be measuring the mouse
	-- tap — which is supposed to dismiss.
	local keydown_type = hs.eventtap.event.types.keyDown
	local keydown
	for _, c in ipairs(callbacks) do
		if type(c.types) == "table" and #c.types == 1 and c.types[1] == keydown_type then
			keydown = c.fn
			break
		end
	end

	return T, keydown
end




-- =============================================================
-- =============================================================
-- ======= 1/ The watcher must not act on Escape ===============
-- =============================================================
-- =============================================================

helpers.describe("tooltip_llm: the dismissal watcher leaves Escape alone", function()
	helpers.it("Escape does not dismiss through the watcher", function()
		local T, keydown = load_with_keydown_watcher()
		helpers.assert_true(type(keydown) == "function",
			"the keyDown dismissal watcher must be mounted and identifiable — without it this "
				.. "test would assert nothing at all")

		T.show_predictions({ "prédiction" }, 1, true)
		helpers.assert_true(T.is_visible(), "the tooltip must be showing before Escape arrives")

		local consumed = keydown(fake_key_event(KEYCODE_ESCAPE))

		helpers.assert_true(T.is_visible(),
			"the watcher must NOT hide on Escape. It runs before the persistent trap (it is "
				.. "created per render, so it is always the newer tap), and hiding here leaves the "
				.. "trap looking at an invisible tooltip — its signal to pass Escape through to "
				.. "the app, which is what opened Raycast on every dismissal")
		helpers.assert_true(not consumed,
			"and it must not consume the key either: the trap is what consumes Escape, and "
				.. "swallowing it here would leave the trap unable to reset the predictions")
	end)

	helpers.it("an ordinary keystroke still dismisses", function()
		local T, keydown = load_with_keydown_watcher()
		T.show_predictions({ "prédiction" }, 1, true)
		helpers.assert_true(T.is_visible(), "the tooltip must be showing")

		keydown(fake_key_event(KEYCODE_LETTER_A))

		helpers.assert_true(not T.is_visible(),
			"a normal keystroke must still dismiss — an exemption list that swallowed everything "
				.. "would pass the Escape assertion while breaking the watcher entirely")
	end)
end)




-- =============================================================
-- =============================================================
-- ======= 2/ Both watchers carry the exemption ================
-- =============================================================
-- =============================================================

helpers.describe("tooltips: every per-render dismissal watcher exempts Escape", function()
	helpers.it("both ignored-keycode lists name Keycodes.ESCAPE", function()
		-- read_driver_source concatenates every file naming the symbol, which is
		-- what makes this a CLASS check: the LLM tooltip and the hotstring preview
		-- both build an ignored_keycodes list, and both were missing Escape.
		local src = helpers.read_driver_source("local ignored_keycodes")
		helpers.assert_true(src ~= nil and src ~= "",
			"the tooltip sources must be locatable by their ignored-keycode lists")

		local code = src:gsub("%-%-[^\n]*", "")

		local lists, exempting = 0, 0
		local pos = 1
		while true do
			local at = code:find("local ignored_keycodes", pos, true)
			if not at then break end
			pos = at + 1
			lists = lists + 1
			local body = code:sub(at, (code:find("}", at, true) or at))
			-- Keycodes.ESCAPE, never the bare 53: the F15 sentinel already in these
			-- lists is a DIFFERENT key, and a raw number here would be one renumber
			-- away from silently exempting nothing.
			if body:find("Keycodes.ESCAPE", 1, true) then exempting = exempting + 1 end
		end

		helpers.assert_true(lists >= 2,
			"both tooltip surfaces must be reached by this scan (found " .. lists
				.. ") — a scan that matches one file cannot protect the other")
		helpers.assert_eq(exempting, lists,
			"every per-render dismissal watcher must exempt Escape (" .. exempting .. "/" .. lists
				.. "). The one that does not will hide first, and the trap will then pass Escape "
				.. "to the application")
	end)
end)
