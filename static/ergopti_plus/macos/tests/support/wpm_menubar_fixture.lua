--- tests/support/wpm_menubar_fixture.lua

--- ==============================================================================
--- MODULE: WPM Menubar Fixture
--- DESCRIPTION:
--- Owns distinct native items and timer handles across reentrant lifecycle calls.
--- ==============================================================================

local helpers = require("tests.helpers")

return function(callback)
	local original_hs = _G.hs
	local ok, err = xpcall(function()
		helpers.with_fresh_modules({ "ui.wpm.wpm_menubar", "ui.wpm.shared", "ui.wpm.wpm_widget",
			"ui.tooltip", "modules.keylogger", "infra.logger", "adapters.timer_scheduler" }, function()
			local state = { items = {}, timers = {}, logs = {} }
			local logger = helpers.make_logger_stub()
			for _, level in ipairs({ "debug", "info", "error" }) do
				logger[level] = function(_, message)
					state.logs[#state.logs + 1] = { level = level, message = message }
					if state.on_log then state.on_log(level, message) end
				end
			end
			package.loaded["infra.logger"] = logger
			package.loaded["modules.keylogger"] = { get_live_stats = function() return { wpm = 10 } end }
			package.loaded["ui.wpm.wpm_widget"] = { _load_shared_const = function() return { source_color_duration = 1 } end }
			package.loaded["ui.wpm.shared"] = { get_active_source = function() return "none" end,
				format_mpm_label = function() return "10" end }
			package.loaded["ui.tooltip"] = { is_visible = function() return false end }
			package.loaded["adapters.timer_scheduler"] = {
				every = function(_, run)
					local timer = { timer = {}, run = run }
					state.timers[#state.timers + 1] = timer
					return timer, true
				end,
				cancel = function(timer) timer.timer = nil; return true end,
			}
			local module = helpers.load_with_stubs("ui.wpm.wpm_menubar", {
				timer = { absoluteTime = function() return 0 end },
				styledtext = { new = function(text) return text end },
				menubar = { new = function()
					if state.new_failure == "nil" then return nil end
					if state.new_failure == "throw" then error("PRIVATE_DETAIL") end
					local item = { deleted = false, titles = 0 }
					item.delete = function(self) self.deleted = true end
					item.setTitle = function(self)
						helpers.assert_eq(self.deleted, false, "retired native item must not receive titles")
						self.titles = self.titles + 1
						return self
					end
					state.items[#state.items + 1] = item
					return item
				end },
			})
			callback(module, state)
		end)
	end, debug.traceback)
	_G.hs = original_hs
	if not ok then error(err, 0) end
end
