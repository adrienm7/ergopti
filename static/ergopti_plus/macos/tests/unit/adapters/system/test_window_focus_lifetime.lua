--- tests/unit/adapters/system/test_window_focus_lifetime.lua

--- ==============================================================================
--- MODULE: Window Focus Lifetime
--- DESCRIPTION:
--- Hammerspoon 1.1.1 window:focus returns self even when application() is nil.
--- An application that exits during a switch must not publish a successful focus or
--- suppress the next candidate. The native application() documents nil on process exit;
--- this model does not qualify actual macOS Accessibility focus delivery.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_windows(options, callback)
	helpers.with_stub_scope({
		"adapters.window_manager", "adapters.mouse_control",
		"modules.gestures.app_switch", "infra.logger",
	}, function()
		local focused = {}
		local function window(id, pid, behavior)
			local alive = behavior ~= "exited"
			local app = { pid = function() return pid end }
			local win = {
				id = function() return id end,
				application = function() if alive then return app end end,
				screen = function() return { id = function() return 1 end } end,
				isStandard = function() return true end,
				isMinimized = function()
					-- The last inventory read completes just before its application exits.
					if behavior == "after_inventory" then alive = false end
					return false
				end,
			}
			function win:focus()
				if behavior == "during_focus" then alive = false end
				-- Pinned hs.window:focus looks up its app, skips native work when
				-- absent, and returns self in both branches (window.lua:513).
				if self:application() then focused[#focused + 1] = id end
				return self
			end
			return win
		end
		local candidate = window(22, 202, options.behavior)
		local healthy = window(33, 303)
		local manager = helpers.load_with_stubs("adapters.window_manager", {
			window = {
				get = function(id) if id == 22 then return candidate end end,
				orderedWindows = function() return { candidate, healthy } end,
			},
			application = {
				frontmostApplication = function() return { pid = function() return 101 end } end,
			},
			processInfo = { processID = 999 },
		})
		callback({
			manager = manager,
			record = { window = candidate, id = 22, pid = 202, minimized = false },
			focused = focused,
			switch = function()
				local switch = require("modules.gestures.app_switch")
				return switch.previous_app(switch.SCOPE_ALL_SCREENS)
			end,
		})
	end)
end

helpers.describe("window focus refuses a detached native window", function()
	helpers.it("activate rejects a chain result with no application (window-focus-lifetime)", function()
		with_windows({ behavior = "exited" }, function(f)
			helpers.assert_eq(f.manager.activate(22), false,
				"the native focus chain result alone must not prove that its application still exists")
			helpers.assert_eq(f.focused, {})
		end)
	end)

	helpers.it("focus_window rejects a terminated application record (window-focus-lifetime)", function()
		with_windows({ behavior = "exited" }, function(f)
			helpers.assert_eq(f.manager.focus_window(f.record), false)
			helpers.assert_eq(f.focused, {})
		end)
	end)

	helpers.it("rejects process exit during either native focus call (window-focus-lifetime)", function()
		for _, method in ipairs({ "activate", "focus_window" }) do
			with_windows({ behavior = "during_focus" }, function(f)
				local target = method == "activate" and 22 or f.record
				helpers.assert_eq(f.manager[method](target), false,
					"a returned self cannot hide process exit inside the focus operation")
				helpers.assert_eq(f.focused, {})
			end)
		end
	end)

	helpers.it("tries the next candidate after an inventoried application exits (window-focus-lifetime)", function()
		with_windows({ behavior = "after_inventory" }, function(f)
			helpers.assert_eq(f.switch(), true)
			helpers.assert_eq(f.focused, { 33 },
				"a chainable no-op must not suppress the healthy fallback application")
		end)
	end)

	helpers.it("preserves the documented chain result for live windows (window-focus-lifetime)", function()
		with_windows({}, function(f)
			helpers.assert_eq(f.manager.activate(22), true)
			helpers.assert_eq(f.manager.focus_window(f.record), true)
			helpers.assert_eq(f.focused, { 22, 22 })
		end)
	end)
end)
