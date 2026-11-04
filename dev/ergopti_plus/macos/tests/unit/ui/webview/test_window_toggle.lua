--- tests/unit/ui/webview/test_window_toggle.lua

--- ==============================================================================
--- MODULE: Web-View Window Toggle (macOS)
--- DESCRIPTION:
--- The three-state rule behind the shared `open_*` window actions: closed
--- opens, open but covered comes to the front, focused closes. Driven
--- through ui/window_toggle with a recording page module and presentation
--- port, then through the gesture registry so every catalogue window action
--- reaches its own page.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")
package.loaded["ui.window_toggle"] = nil
local WindowToggle = require("ui.window_toggle")





-- ===========================================
-- ===========================================
-- ======= 1/ A recording page fixture =======
-- ===========================================
-- ===========================================

--- Installs a fake module for one page and a fake presentation port.
--- @param page string A WindowToggle.PAGES id.
--- @param body function Receives the recorded state table.
local function with_page(page, body)
	local spec = WindowToggle.PAGES[page]
	local previous = package.loaded[spec.module]
	local state = { view = nil, focused = false, opened = 0, presented = 0, closed = 0 }
	local fake = {}
	fake[spec.window or "window"] = function() return state.view end
	fake[spec.close or "close"] = function()
		state.closed = state.closed + 1
		state.view = nil
		return true
	end
	if spec.open then
		fake[spec.open] = function()
			state.opened = state.opened + 1
			state.view = { page = page }
			return true
		end
	end
	package.loaded[spec.module] = fake
	WindowToggle._set_ui_builder(function()
		return {
			is_window_focused = function(view) return view == state.view and state.focused end,
			force_focus = function(view)
				state.presented = state.presented + 1
				if view == state.view then state.focused = true end
				return true
			end,
		}
	end)
	local ok, err = pcall(body, state)
	package.loaded[spec.module] = previous
	WindowToggle._set_ui_builder(nil)
	WindowToggle._reset_openers()
	if not ok then error(err, 0) end
end





-- =====================================
-- =====================================
-- ======= 2/ The three states =========
-- =====================================
-- =====================================

helpers.describe("window toggle (macOS)", function()

	helpers.it("opens a closed page, presents a covered one and closes a focused one", function()
		with_page("metrics_typing", function(state)
			helpers.assert_true(WindowToggle.toggle("metrics_typing"), "a closed page opens")
			helpers.assert_eq(state.opened, 1, "the page's own opener ran once")

			state.focused = false
			helpers.assert_true(WindowToggle.toggle("metrics_typing"), "a covered page is presented")
			helpers.assert_eq(state.presented, 1, "covered means bring to front")
			helpers.assert_eq(state.closed, 0, "a covered page is never closed")
			helpers.assert_eq(state.opened, 1, "presenting reuses the open window")

			helpers.assert_true(WindowToggle.toggle("metrics_typing"), "a focused page closes")
			helpers.assert_eq(state.closed, 1, "the page's own close ran once")
			helpers.assert_eq(state.view, nil, "the page is closed")
		end)
	end)

	helpers.it("a context page opens only through its registered opener", function()
		with_page("layer_editor", function(state)
			helpers.assert_eq(WindowToggle.toggle("layer_editor"), false,
				"without the session's opener nothing opens and the refusal is reported")
			local calls = 0
			WindowToggle.set_opener("layer_editor", function()
				calls = calls + 1
				state.view = { page = "layer_editor" }
				return true
			end)
			helpers.assert_true(WindowToggle.toggle("layer_editor"))
			helpers.assert_eq(calls, 1, "the registered opener ran")
			state.focused = true
			helpers.assert_true(WindowToggle.toggle("layer_editor"))
			helpers.assert_eq(state.closed, 1, "a focused context page closes through its module")
		end)
	end)

	helpers.it("refuses an unknown page and an opener for one", function()
		helpers.assert_eq(WindowToggle.toggle("no_such_page"), false)
		local ok = pcall(WindowToggle.set_opener, "no_such_page", function() end)
		helpers.assert_eq(ok, false, "registering an unknown page raises")
	end)

	helpers.it("every page module exposes its window and close hooks", function()
		for page, spec in pairs(WindowToggle.PAGES) do
			-- Resolved by module name, as require would, so a move keeps the check;
			-- the health check defines its window hooks in its core submodule.
			local name = spec.module == "ui.healthcheck" and "ui.healthcheck.core" or spec.module
			local path = package.searchpath(name, package.path)
			helpers.assert_true(path ~= nil, page .. ": page module " .. name .. " resolves")
			local handle = io.open(path)
			helpers.assert_true(handle ~= nil, page .. ": page module source is readable")
			local src = handle:read("*a")
			handle:close()
			for _, hook in ipairs({ spec.window or "window", spec.close or "close" }) do
				helpers.assert_true(src:find("function M%." .. hook .. "%(") ~= nil,
					page .. " exposes M." .. hook .. "()")
			end
			if spec.open then
				helpers.assert_true(src:find("function M%." .. spec.open .. "%(") ~= nil,
					page .. " exposes M." .. spec.open .. "()")
			end
		end
	end)
end)





-- ==================================================
-- ==================================================
-- ======= 3/ Every window action reaches it ========
-- ==================================================
-- ==================================================

helpers.describe("window actions reach the toggle (macOS)", function()
	helpers.it("each catalogue window action toggles its own page", function()
		package.loaded["modules.gestures.actions"] = nil
		local Actions = helpers.load_with_stubs("modules.gestures.actions")
		local Catalogue = require("_generated.action_catalogue")
		helpers.assert_eq(type(Actions.WINDOW_ACTIONS), "table")
		local count = 0
		local previous = package.loaded["ui.window_toggle"]
		local toggled
		package.loaded["ui.window_toggle"] = { toggle = function(page) toggled = page; return true end }
		local ok, err = pcall(function()
			for action_id, page in pairs(Actions.WINDOW_ACTIONS) do
				count = count + 1
				helpers.assert_true(Catalogue.actions[action_id] ~= nil, action_id .. " is in the macOS catalogue")
				helpers.assert_true(WindowToggle.PAGES[page] ~= nil, action_id .. " names a toggleable page")
				toggled = nil
				helpers.assert_true(Actions.execute_single(action_id, nil), action_id .. " is registered and runs")
				helpers.assert_eq(toggled, page, action_id .. " toggles its own page")
			end
		end)
		package.loaded["ui.window_toggle"] = previous
		if not ok then error(err, 0) end
		helpers.assert_eq(count, 10, "the ten window actions of the UI group")
	end)
end)
