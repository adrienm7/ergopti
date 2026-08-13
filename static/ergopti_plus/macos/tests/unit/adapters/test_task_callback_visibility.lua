--- tests/unit/adapters/test_task_callback_visibility.lua

--- ==============================================================================
--- MODULE: Direct task callback visibility
--- DESCRIPTION:
--- Drives the two direct task callbacks added to the class-wide H9 migration.
--- A native hs.task callback exception goes only to Hammerspoon Console unless
--- the callback body reaches Logger.pcall; both tests require the real owner to
--- contain the throw and emit one central error.
--- ==============================================================================

local helpers = require("tests.helpers")

local function capturing_logger(errors)
	local logger = helpers.make_logger_stub()
	logger.pcall = function(_module, fn, ...)
		local ok, result = pcall(fn, ...)
		if not ok then errors[#errors + 1] = tostring(result) end
		return ok, result
	end
	return logger
end

helpers.describe("direct task callbacks: exceptions reach the file-logger boundary", function()
	helpers.it("logs a keylogger system-load sink exception", function()
		local errors = {}
		local completion
		package.loaded["infra.logger"] = capturing_logger(errors)
		package.loaded["infra.timings"] = { ms = function() return 1 end }
		package.loaded["modules.keylogger.log_manager"] = {
			log_system_event = function() error("system event sink exploded") end,
		}
		package.loaded["adapters.task_lifecycle"] = nil
		local Watchers = helpers.load_with_stubs("modules.keylogger.watchers", {
			timer = {
				absoluteTime = function() return 1000000000000000 end,
				doAfter = function() end,
			},
			task = { new = function(_, cb)
				completion = cb
				return { start = function(self) return self end }
			end },
		})
		Watchers.init({ session_last_active = 0 }, function() return false end)
		Watchers.check_idle()
		helpers.assert_true(type(completion) == "function", "the sampler callback must be captured")
		completion(0, "CPU usage: 1.0% user\nPhysMem: 1G used", "")
		helpers.assert_eq(1, #errors, "the contained callback error must reach Logger.pcall")
		helpers.assert_true(errors[1]:find("system event sink exploded", 1, true) ~= nil,
			"the logged error must preserve the thrown cause")
	end)

	helpers.it("logs an active-layout on_done exception", function()
		local errors = {}
		local completion
		package.loaded["infra.logger"] = capturing_logger(errors)
		package.loaded["adapters.task_lifecycle"] = nil
		local InputSources = helpers.load_with_stubs("modules.keymap.input_sources", {
			task = { new = function(_, cb)
				completion = cb
				return { start = function(self) return self end }
			end },
		})
		InputSources.refresh_active_layouts_async(function()
			error("layout refresh listener exploded")
		end)
		helpers.assert_true(type(completion) == "function", "the layout callback must be captured")
		completion(0, '["French"]', "")
		helpers.assert_eq(1, #errors, "the contained listener error must reach Logger.pcall")
		helpers.assert_true(errors[1]:find("layout refresh listener exploded", 1, true) ~= nil,
			"the logged error must preserve the thrown cause")
	end)
end)
