--- tests/support/typing_delivery_fixture.lua

--- ==============================================================================
--- MODULE: Typing Delivery Fixture
--- DESCRIPTION:
--- Drives real dashboard publications without database or configuration I/O.
--- ==============================================================================

local helpers = require("tests.helpers")
local load_dashboard = require("tests.support.metrics_typing_fixture")
local Scope = require("tests.support.metrics_typing_scope")

return function(callback)
	return Scope.run(function()
		local timers, errors, successes, evaluations = {}, {}, {}, {}
		local poll
		local dashboard, context = load_dashboard({
			after = function(_, run)
				local handle = { timer = {} }
				timers[#timers + 1] = function() handle.timer = nil; run() end
				return handle, true
			end,
			every = function(_, run) poll = run; return { timer = {} }, true end,
			cancel = function(handle) handle.timer = nil; return true end,
		})
		context.poll = function() return poll() end
		package.loaded["modules.keylogger.log_manager"].get_sqlite_path = function() return nil end
		package.loaded["modules.keylogger.sqlite_reader"] = {}
		local filesystem = package.loaded["adapters.file_system"]
		filesystem.read_with_status = function() return nil, "absent" end
		local logger = package.loaded["infra.logger"]
		logger.error = function(_, template, ...) errors[#errors + 1] = string.format(template, ...) end
		logger.success = function(tag, template, ...)
			if tag == "metrics_typing" then successes[#successes + 1] = string.format(template, ...) end
		end
		context.webview.evaluateJavaScript = function(self, code, done)
			evaluations[#evaluations + 1] = { code = code, done = done }
			return self
		end
		local original_open = io.open
		io.open = function()
			local file = {}
			file.write = function() return file end
			file.close = function() return true end
			return file
		end
		local ok, err = xpcall(function()
			helpers.assert_eq(dashboard.show(), true)
			for index = #successes, 1, -1 do successes[index] = nil end
			callback(dashboard, context, timers, errors, successes, evaluations, filesystem)
		end, debug.traceback)
		io.open = original_open
		if not ok then error(err, 0) end
	end)
end
