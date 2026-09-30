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
		local delays, ran = {}, {}
		local poll
		local dashboard, context = load_dashboard({
			after = function(delay, run)
				local handle = { timer = {} }
				local index = #timers + 1
				delays[index] = delay
				timers[index] = function() ran[index] = true; handle.timer = nil; run() end
				return handle, true
			end,
			every = function(_, run) poll = run; return { timer = {} }, true end,
			cancel = function(handle) handle.timer = nil; return true end,
		})
		context.poll = function() return poll() end
		-- Runs every pending paced-projection slice until the queue is idle
		local job_gap = require("infra.paced_job").DEFAULT_GAP_SEC
		context.settle_jobs = function()
			local progressed = true
			while progressed do
				progressed = false
				for index = 1, #timers do
					if not ran[index] and delays[index] == job_gap then
						timers[index]()
						progressed = true
					end
				end
			end
		end
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
		local original_open, original_rename = io.open, os.rename
		io.open = function()
			local file = {}
			file.write = function() return file end
			file.close = function() return true end
			return file
		end
		os.rename = function() return true end
		local ok, err = xpcall(function()
			helpers.assert_eq(dashboard.show(), true)
			for index = #successes, 1, -1 do successes[index] = nil end
			callback(dashboard, context, timers, errors, successes, evaluations, filesystem)
		end, debug.traceback)
		io.open = original_open
		os.rename = original_rename
		if not ok then error(err, 0) end
	end)
end
