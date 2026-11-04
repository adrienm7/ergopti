--- tests/unit/ui/download_window/lifecycle/test_javascript_completion_retirement.lua

--- ==============================================================================
--- MODULE: Progress Window JavaScript Completion Retirement
--- DESCRIPTION:
--- Real progress host/factory with native-shaped asynchronous execution callbacks.
--- Retiring a window or operation must revoke only its own diagnostic authority.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.ui.owned_window_close_fixture")
local SUBJECTS = { "ui.download_window", "ui.download_window.javascript", "ui.download_window.pending_queue" }
local FAILURE = { code = 5, domain = "WKErrorDomain" }

--- Starts a real progress operation and observes its native execution boundary.
--- @param scenario function Receives host, native observations, completions and errors.
local function with_download(scenario)
	helpers.with_fresh_modules(SUBJECTS, function()
		Fixture("ui.download_window", function(host, h)
			assert(host.show({ kind = "mlx_model", model = "A" }))
			local pending, errors, logger = {}, {}, require("infra.logger")
			local previous = logger.error
			logger.error = function(_, format, ...) errors[#errors + 1] = string.format(format, ...) end
			function h.observe(view)
				function view:evaluateJavaScript(_, callback)
					assert(not self.disposed, "consumed view cannot accept JavaScript")
					if type(callback) == "function" then pending[#pending + 1] = callback end
					return self
				end
				assert(view.navigation_callback)("didFinishNavigation")
			end
			h.observe(h.windows[1])
			assert(type(pending[1]) == "function", "actual progress publication absent")
			local result = table.pack(xpcall(function() scenario(host, h, pending, errors) end, debug.traceback))
			logger.error = previous
			if not result[1] then error(result[2], 0) end
		end)
	end)
end

helpers.describe("download JavaScript completion retirement", function()
	helpers.it("preserves native code-zero success", function()
		with_download(function(_, _, pending, errors)
			pending[1](true, { code = 0 })
			assert(#errors == 0)
		end)
	end)

	helpers.it("reports a current execution error once without native contents", function()
		with_download(function(host, _, pending, errors)
			pending[1](nil, FAILURE)
			host.set_detail("current update")
			pending[#pending](nil, FAILURE)
			assert(#errors == 1 and errors[1]:find("execution failed", 1, true))
			assert(not errors[1]:find("WKErrorDomain", 1, true))
		end)
	end)

	for _, kind in ipairs({ "explicit", "user" }) do
		helpers.it("ignores a consumed " .. kind .. " window's delayed error", function()
			with_download(function(host, h, pending, errors)
				local old, view = pending[1], h.windows[1]
				if kind == "explicit" then assert(host.hide()) else view:user_close() end
				h.drain(); assert(view.disposed and next(h.script_refs) == nil)
				old(nil, FAILURE)
				assert(#errors == 0, "retired execution must not publish ERROR")
			end)
		end)
	end

	helpers.it("preserves new native B errors without reporting retired A", function()
		with_download(function(host, h, pending, errors)
			local old = pending[1]
			assert(host.hide()); h.drain()
			assert(host.show({ kind = "mlx_model", model = "B" }))
			assert(#h.windows == 2)
			h.observe(h.windows[2])
			old(nil, FAILURE); assert(#errors == 0)
			pending[#pending](nil, FAILURE)
			assert(#errors == 1, "current B error must remain visible")
		end)
	end)

	helpers.it("retires A before reusing its native view for B", function()
		with_download(function(host, h, pending, errors)
			local old, count = pending[1], #pending
			assert(host.show({ kind = "mlx_model", model = "B" }))
			assert(#h.windows == 1 and #pending > count)
			old(nil, FAILURE); assert(#errors == 0)
			pending[#pending](nil, FAILURE); assert(#errors == 1)
		end)
	end)

	helpers.it("keeps the current context when a new show is rejected before ownership", function()
		with_download(function(host, _, pending, errors)
			assert(host.show({ kind = "invalid-kind" }) == false)
			local count = #errors
			pending[1](nil, FAILURE)
			assert(#errors == count + 1, "invalid input cannot retire the actual current operation")
		end)
	end)

	helpers.it("revokes publication before uncertain native hide and retains exact cleanup", function()
		with_download(function(host, h, pending, errors)
			local old, view = pending[1], h.windows[1]
			local delete = view.delete
			function view:delete() error("native delete refused before consumption") end
			assert(host.hide() == false and not view.disposed)
			local count = #errors
			old(nil, FAILURE); assert(#errors == count)
			view.delete = delete
			assert(host.hide()); h.drain(); assert(view.disposed)
		end)
	end)
end)
