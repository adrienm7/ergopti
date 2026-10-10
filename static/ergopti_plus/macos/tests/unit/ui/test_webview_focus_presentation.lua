--- tests/unit/ui/test_webview_focus_presentation.lua

--- ============================================================================
--- MODULE: User-Requested Window Presentation
--- DESCRIPTION:
--- Runs the real focus helper with inert native boundaries and records activation,
--- restoration and exact-window effects independently of its return value.
--- ============================================================================

local helpers = require("tests.helpers")

local function with_presentation(mode, is_new, scenario)
	local saved, prior_hs = {}, _G.hs
	for key, value in pairs(package.loaded) do saved[key] = value end
	local state = { current = true, active = false, minimized = true, effects = {}, errors = {}, pending = {} }
	local ok, err = xpcall(function()
		package.loaded["infra.logger"] = {
			debug = function() end, info = function() end, warn = function() end,
			error = function(_, text) state.errors[#state.errors + 1] = text end,
		}
		package.loaded["infra.paths"] = { shared = function() return "/virtual" end }
		package.loaded["infra.deferred_work"] = { after = function(_, callback)
			state.pending[#state.pending + 1] = callback
			return true
		end }
		package.loaded["hs.spaces"] = {
			activeSpaceOnScreen = function() return 1 end,
			moveWindowToSpace = function() return true end,
		}
		_G.hs = {
			screen = { mainScreen = function() return {} end },
			focus = function()
				state.effects[#state.effects + 1] = "activate"
				state.active = true
				if mode == "retire on activate" then state.current = false end
			end,
		}
		local window = {
			moveToScreen = function(self) return self end,
			unminimize = function(self)
				state.effects[#state.effects + 1] = "restore"
				if mode == "restore false" then return false end
				if mode == "restore throw" then error("owned restore failed") end
				state.minimized = false
				return self
			end,
			raise = function(self)
				state.effects[#state.effects + 1] = "raise"
				return self
			end,
			focus = function(self)
				state.effects[#state.effects + 1] = "focus"
				state.target_focused = state.active and not state.minimized
				return self
			end,
		}
		local view = {
			hswindow = function()
				if mode == "queued cancel" then return nil end
				return window
			end,
			level = function() error("User presentation must not change window levels") end,
			bringToFront = function() error("User presentation must not float the window") end,
		}
		package.loaded["ui.ui_builder"] = nil
		local result = require("ui.ui_builder").force_focus(view, is_new, {
			is_current = function() return state.current end,
		})
		if mode == "queued cancel" then
			state.current = false
			for _, callback in ipairs(state.pending) do callback() end
		end
		scenario(result, state)
	end, debug.traceback)
	_G.hs = prior_hs
	for key in pairs(package.loaded) do if saved[key] == nil then package.loaded[key] = nil end end
	for key, value in pairs(saved) do package.loaded[key] = value end
	if not ok then error(err, 0) end
end

for _, is_new in ipairs({ true, false }) do
	helpers.it("user-window-presentation activates then restores and focuses " .. (is_new and "new" or "requested again"), function()
		with_presentation("valid", is_new, function(result, state)
			helpers.assert_true(result)
			helpers.assert_eq(state.effects, { "activate", "restore", "raise", "focus" })
			helpers.assert_true(state.target_focused, "The exact requested window must end focused")
			helpers.assert_eq(#state.errors, 0)
		end)
	end)
end

for _, mode in ipairs({ "restore false", "restore throw" }) do
	helpers.it("user-window-presentation refuses " .. mode, function()
		with_presentation(mode, true, function(result, state)
			helpers.assert_eq(result, false)
			helpers.assert_eq(state.effects, { "activate", "restore" })
			helpers.assert_eq(#state.errors, 1)
		end)
	end)
end

helpers.it("user-window-presentation rechecks retirement after application activation", function()
	with_presentation("retire on activate", true, function(result, state)
		helpers.assert_eq(result, false)
		helpers.assert_eq(state.effects, { "activate" })
	end)
end)

helpers.it("user-window-presentation cancelled queued retry has no foreground effects", function()
	with_presentation("queued cancel", true, function(result, state)
		helpers.assert_true(result)
		helpers.assert_eq(#state.pending, 1)
		helpers.assert_eq(state.effects, {})
	end)
end)
