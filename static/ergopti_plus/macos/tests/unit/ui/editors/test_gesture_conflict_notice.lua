--- tests/unit/ui/editors/test_gesture_conflict_notice.lua

--- ==============================================================================
--- MODULE: Gesture Warning Consent
--- DESCRIPTION:
--- Dialog button identity, storage refusal, and repeat dismissal are behavioral
--- boundaries: closing a warning must never write consent or open Settings.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("gesture warning consent (gesture-conflicts)", function()
	for _, choice in ipairs({ "menu.gestures.open_settings", "gestures.system.dismiss", "close", "refused" }) do
		helpers.it("honours the " .. choice .. " button", function()
			local names = { "ui.gesture_conflict_notice", "infra.dialog_util", "core.i18n.engine.i18n", "core.fs.adapters.storage",
				"infra.deferred_work", "infra.logger" }
			local saved, store, timers = {}, {}, {}
			local saved_shell = package.loaded["adapters.shell_runner"]
			local opened, dialogs, errors, reject_schedule = 0, 0, 0, true
			local on_dialog
			for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
			package.loaded["infra.dialog_util"] = { block_alert = function()
				dialogs = dialogs + 1
				if on_dialog then on_dialog() end
				return choice == "refused" and "gestures.system.dismiss" or choice
			end }
			package.loaded["core.i18n.engine.i18n"] = { get = function(key) return key end }
			package.loaded["core.fs.adapters.storage"] = {
				get = function(key) return store[key] end,
				set = function(key, value)
					if choice == "refused" then return false end
					store[key] = value; return true
				end,
			}
			package.loaded["infra.deferred_work"] = { after = function(_, fn)
				if reject_schedule then return false end
				timers[#timers + 1] = fn; return true
			end }
			package.loaded["adapters.shell_runner"] = { open = function() opened = opened + 1; return true end }
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.logger"].error = function() errors = errors + 1 end
			local ok, err = xpcall(function()
				local notice = require("ui.gesture_conflict_notice")
				local warning = { key = "tap_2", msg = "Conflict", url = "settings" }
				helpers.assert_eq(notice.show(warning), false, "a refused timer is reported")
				reject_schedule = false
				notice.show(warning)
				notice.show(warning)
				helpers.assert_eq(#timers, 1, "duplicate requests share the pending dialog")
				helpers.assert_eq(dialogs, 0, "the dialog must be deferred")
				on_dialog = function()
					notice.show(warning)
					helpers.assert_eq(#timers, 0, "a modal dialog also coalesces reentrant requests")
				end
				table.remove(timers, 1)()
				helpers.assert_eq(opened, choice == "menu.gestures.open_settings" and 1 or 0)
				helpers.assert_eq(store["gesture_conflict_dismissed.tap_2"], choice == "gestures.system.dismiss" and true or nil)
				helpers.assert_eq(errors, choice == "refused" and 1 or 0)
				notice.show(warning)
				helpers.assert_eq(#timers, choice == "gestures.system.dismiss" and 0 or 1)
			end, debug.traceback)
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
			package.loaded["adapters.shell_runner"] = saved_shell
			if not ok then error(err, 0) end
		end)
	end
end)
