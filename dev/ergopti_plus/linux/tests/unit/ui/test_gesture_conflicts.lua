--- tests/unit/ui/test_gesture_conflicts.lua

--- ==============================================================================
--- MODULE: Desktop Gesture Conflict Behavior
--- DESCRIPTION:
--- Checks cached menu status, actual reader posture, and explicit dismissal at
--- the shell and modal boundaries without starting a desktop or grabbing input.
--- ==============================================================================

local h = require("tests.helpers")

--- Executes one isolated notice scenario and restores every module boundary.
--- @param choice string Simulated list selection; empty means cancellation.
--- @param body function Assertions against the real module and observed effects.
local function scenario(choice, body)
	local names = { "ui.gesture_conflicts", "infra.i18n", "adapters.storage", "adapters.shell_runner",
		"logger.shim", "adapters.event_loop", "ui.modal" }
	local saved, store, queued = {}, {}, {}
	local observed = { shells = 0, modals = 0, dialogs = 0 }
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["adapters.storage"] = { get = function(key) return store[key] end,
		set = function(key, value) store[key] = value; return true end }
	package.loaded["adapters.shell_runner"] = {
		quote = function(value) return "'" .. value .. "'" end,
		has_command = function() observed.shells = observed.shells + 1; return false end,
		run = function() observed.shells = observed.shells + 1; return true end,
		exec_checked = function() observed.dialogs = observed.dialogs + 1; return choice ~= "", choice end,
	}
	package.loaded["logger.shim"] = { warn = function() end, error = function() end }
	package.loaded["adapters.event_loop"] = { defer = function(fn) queued[#queued + 1] = fn; return true end }
	package.loaded["ui.modal"] = { run = function(fn) observed.modals = observed.modals + 1; return fn() end }
	local ok, err = xpcall(function() body(require("ui.gesture_conflicts"), observed, store, queued) end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

h.describe("system gesture conflicts", function()
	h.it("builds status from the real reader without shell probes and deduplicates groups", function()
		scenario("", function(module, observed)
			local gestures = { DEFAULT_GESTURES = { swipe_3_left = "none", swipe_3_right = "none", tap_2 = "none" },
				is_enabled = function() return true end, is_reading = function() return false end,
				get_action = function(slot) return slot == "tap_2" and "none" or "tab_next" end }
			h.assert_eq(#module.groups(gestures), 1)
			local rows = module.rows(gestures)
			h.assert_eq(rows[1].label, "gestures.system.unknown")
			h.assert_eq(rows[1].items[1].label, "menu.gestures.reading_off")
			h.assert_eq(observed.shells, 0)
			gestures.is_reading = function() return true end
			h.assert_eq(module.rows(gestures)[1].items[1].label, "menu.gestures.reading_on")
			gestures.is_enabled = function() return false end
			h.assert_eq(#module.groups(gestures), 0)
		end)
	end)
	for _, choice in ipairs({ "", "gestures.system.dismiss" }) do
		h.it("persists only explicit dismissal: " .. choice, function()
			scenario(choice, function(module, observed, store, queued)
				local group = { key = "swipe_3", slot = "swipe_3_left" }
				module.show(group)
				h.assert_eq(observed.dialogs, 0)
				table.remove(queued, 1)()
				h.assert_eq(observed.dialogs, 1)
				h.assert_eq(observed.modals, 1)
				h.assert_eq(store["gesture_conflict_dismissed.swipe_3"], choice ~= "" and true or nil)
				module.show({ key = "swipe_3", slot = "swipe_3_right" })
				h.assert_eq(#queued, choice ~= "" and 0 or 1)
			end)
		end)
	end
	h.it("maps only supported touchpad panels", function()
		scenario("", function(module)
			h.assert_eq(module.settings_command("GNOME"), "gnome-control-center mouse")
			h.assert_eq(module.settings_command("KDE"), "systemsettings kcm_touchpad")
			h.assert_eq(module.settings_command("unknown"), nil)
		end)
	end)
end)
