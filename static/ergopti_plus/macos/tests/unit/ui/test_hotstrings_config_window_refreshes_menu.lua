--- tests/unit/ui/test_hotstrings_config_window_refreshes_menu.lua

--- ==============================================================================
--- MODULE: Hotstrings Config Window — Menubar Refresh Channel (regression)
--- DESCRIPTION:
--- Locks down that the delay / colour configuration window notifies its opener
--- after every mutation of the shared override store.
---
--- ROOT CAUSE ENCODED — NO REFRESH CHANNEL AT ALL, not "the label is wrong":
--- ui/menu/menu_hotstrings_management.lua make_category_delay_item bakes the
--- RESOLVED delay and the "(default)" indicator into the menu item title at BUILD
--- time. The config window performs nine set_override writes against that very
--- same store, yet contained zero references to updateMenu / save_prefs / any menu
--- module — so an edit made in the window left the menubar rows rendering pre-edit
--- values and a now-FALSE default tag for the rest of the session.
---
--- The proof it was unintended is the quick-edit sibling in that same menu file:
--- it does the identical set_override and then correctly calls ctx.save_prefs()
--- and ctx.updateMenu(). Both files' headers claim the two UIs share "the one
--- persistent source … so the two UIs never desync" — they did desync.
---
--- The assertion is on the CHANNEL firing, never on rendered label text, so a
--- cosmetic title change cannot silently retire this guard.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Category / delay used to drive a realistic "set_delay" message through the
-- bridge handler. The value is arbitrary; only the notification matters.
local TEST_CATEGORY  = "magickey"
local TEST_DELAY_MS  = 420





-- =============================================
-- =============================================
-- ======= 1/ Override-Store Test Double =======
-- =============================================
-- =============================================

--- Installs a spying hotstrings_config double and loads the window against it.
--- Installed BEFORE load_with_stubs so the window captures the double at
--- require-time (load_with_stubs does not evict modules.hotstrings.*).
--- @return table window_module, table store_spy
local function load_window()
	local store = { sets = 0, clears = 0 }
	package.loaded["modules.hotstrings.hotstrings_config"] = {
		set_override   = function() store.sets   = store.sets   + 1 return true end,
		clear_override = function() store.clears = store.clears + 1 return true end,
		get_sections   = function() return {} end,
		resolve        = function() return { delay = 0.5, color = "#000000" } end,
		resolve_ext    = function() return { delay = 0.5, color = "#000000" } end,
	}
	local win = helpers.load_with_stubs("ui.hotstrings_config_window")
	return win, store
end

--- Drives one bridge message through the window's handler.
--- @param win table The window module.
--- @param body table The message body.
local function send(win, body)
	win._on_message({ body = body })
end





-- =============================================
-- =============================================
-- ======= 2/ The Refresh Channel Exists =======
-- =============================================
-- =============================================

helpers.describe("hotstrings config window notifies the menubar after an edit", function()
	helpers.it("fires the injected callback after a delay change", function()
		local win, store = load_window()
		local fired = 0
		win._on_config_changed = function() fired = fired + 1 end

		send(win, { action = "set_delay", category = TEST_CATEGORY, ms = TEST_DELAY_MS })

		helpers.assert_eq(store.sets, 1, "the override must actually be written")
		helpers.assert_eq(fired, 1,
			"the window must notify its opener — the menubar bakes the resolved delay "
			.. "into item titles at build time and cannot discover the change itself")
	end)

	helpers.it("fires after a colour change", function()
		local win = load_window()
		local fired = 0
		win._on_config_changed = function() fired = fired + 1 end

		send(win, { action = "set_color", category = TEST_CATEGORY, hex = "#43a047" })

		helpers.assert_eq(fired, 1, "a colour edit desyncs the menubar exactly like a delay edit")
	end)

	helpers.it("fires after a clear that restores the default", function()
		local win = load_window()
		local fired = 0
		win._on_config_changed = function() fired = fired + 1 end

		send(win, { action = "clear_delay", category = TEST_CATEGORY })

		helpers.assert_eq(fired, 1,
			"clearing an override flips the '(default)' indicator back on — the "
			.. "menubar must rebuild or it keeps showing a stale, false tag")
	end)

	helpers.it("fires after the reset_all and set_all_grey bulk operations", function()
		for _, action in ipairs({ "reset_all", "set_all_grey" }) do
			local win = load_window()
			local fired = 0
			win._on_config_changed = function() fired = fired + 1 end
			send(win, { action = action })
			helpers.assert_eq(fired, 1, "bulk operation '" .. action .. "' must notify too")
		end
	end)
end)





-- =================================================
-- =================================================
-- ======= 3/ The Channel Is Safe and Scoped =======
-- =================================================
-- =================================================

helpers.describe("hotstrings config window refresh channel is defensive", function()
	helpers.it("does not fire on a non-mutating message", function()
		local win = load_window()
		local fired = 0
		win._on_config_changed = function() fired = fired + 1 end

		send(win, { action = "totally_unknown_action", category = TEST_CATEGORY })

		helpers.assert_eq(fired, 0, "a message that writes nothing must not rebuild the menu")
	end)

	helpers.it("logs and contains a callback that throws (HS-198)", function()
		local win, store = load_window()
		local calls = 0
		win._on_config_changed = function()
			calls = calls + 1
			error("menu rebuild exploded")
		end
		local Logger = require("infra.logger")
		local lines = {}
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line) lines[#lines + 1] = line end)

		-- The override write already succeeded; a failing observer must not
		-- propagate back out of the bridge handler and kill the window.
		local ok, err = xpcall(function()
			send(win, { action = "set_delay", category = TEST_CATEGORY, ms = TEST_DELAY_MS })
		end, debug.traceback)
		Logger.set_sink(nil)

		helpers.assert_true(ok, "the callback failure must remain contained: " .. tostring(err))
		helpers.assert_eq(store.sets, 1, "the write must still have landed")
		helpers.assert_eq(calls, 1, "the refresh controller must run exactly once")
		local log = table.concat(lines, "\n")
		helpers.assert_contains(log, "Hotstrings configuration refresh")
		helpers.assert_contains(log, "menu rebuild exploded")
	end)

	helpers.it("works when no callback was injected", function()
		local win, store = load_window()
		win._on_config_changed = nil
		send(win, { action = "set_delay", category = TEST_CATEGORY, ms = TEST_DELAY_MS })
		helpers.assert_eq(store.sets, 1, "an un-wired window must keep working")
	end)
end)





-- ================================================
-- ================================================
-- ======= 4/ The Menu Actually Wires It Up =======
-- ================================================
-- ================================================

helpers.describe("the menubar wires its refresh callback at the open site", function()
	-- The channel is only useful if the opener injects it. Guard the wiring at the
	-- source level so a future edit that drops it reintroduces the desync with
	-- every behavioural test above still green.
	helpers.it("menu_hotstrings_management injects _on_config_changed before open", function()
		local src = helpers.read_driver_source("_on_config_changed")
		helpers.assert_not_nil(src, "a config-changed wiring site must be locatable")

		-- Two production files assign _on_config_changed, so the scan returns
		-- both. Check EVERY occurrence and require one to carry the wiring,
		-- rather than inspecting whichever happens to come first — that is what
		-- the assertion always meant, and it no longer depends on file order.
		local found = false
		local at = 1
		while true do
			local wire_at = src:find("_on_config_changed%s*=", at)
			if not wire_at then break end
			local window = src:sub(wire_at, wire_at + 400)
			if window:find("save_prefs", 1, true) and window:find("updateMenu", 1, true) then
				found = true
				break
			end
			at = wire_at + 1
		end
		helpers.assert_true(found,
			"the config-window open site must inject a refresh callback that persists "
			.. "the change (save_prefs) and rebuilds the menubar (updateMenu) so "
			.. "baked-in titles are re-resolved")
	end)
end)
