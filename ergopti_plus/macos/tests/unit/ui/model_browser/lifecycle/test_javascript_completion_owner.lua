--- tests/unit/ui/model_browser/lifecycle/test_javascript_completion_owner.lua

--- ==============================================================================
--- MODULE: Model Browser JavaScript Completion Ownership
--- DESCRIPTION:
--- Keeps delayed native execution errors inside their exact presentation operation.
--- Real host/factory behavior runs behind the shared native reference fixture;
--- evaluateJavaScript retains its callback and acknowledges with the exact view.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.ui.owned_window_close_fixture")

local FAILURE = { code = 5, domain = "WKErrorDomain" }

--- Captures actual catalogue submissions after the native page's ready message.
--- @param h table Shared native reference observations.
--- @return table pending Ordered real JavaScript completion callbacks.
local function ready(h)
	local view = h.windows[#h.windows]
	local pending = {}
	function view:evaluateJavaScript(code, callback)
		assert(not self.disposed, "consumed native view cannot accept JavaScript")
		pending[#pending + 1] = { code = code, complete = callback }
		return self
	end
	h.script_refs[h.controllers[#h.controllers]]({ body = "ready" })
	assert(#pending == 1 and type(pending[1].complete) == "function", "actual catalogue submission absent")
	return pending
end

--- Runs an opened real browser with a controlled diagnostic sink.
--- @param scenario function Receives host, observations and captured ERROR metadata.
local function with_browser(scenario)
	Fixture("ui.model_browser", function(host, h)
		assert(h.show())
		local logger, errors = require("infra.logger"), {}
		local previous = logger.error
		logger.error = function(_, format, ...) errors[#errors + 1] = string.format(format, ...) end
		local result = table.pack(xpcall(function() scenario(host, h, errors) end, debug.traceback))
		logger.error = previous
		if not result[1] then error(result[2], 0) end
	end)
end

helpers.describe("model browser exact JavaScript completion owner", function()
	helpers.it("accepts the native bare code-zero sentinel without an error", function()
		with_browser(function(_, h, errors)
			ready(h)[1].complete(true, { code = 0 })
			assert(#errors == 0)
		end)
	end)

	helpers.it("reports a current native error once without payload or error contents", function()
		with_browser(function(host, h, errors)
			local pending = ready(h)
			assert(host.open({ presets = {}, active_backend = "mlx" }))
			assert(#pending == 2)
			pending[2].complete(nil, FAILURE)
			assert(host.open({ presets = {}, active_backend = "mlx" }))
			pending[3].complete(nil, FAILURE)
			assert(#errors == 1 and errors[1]:find("execution failed", 1, true))
			assert(not errors[1]:find("WKErrorDomain", 1, true))
		end)
	end)

	for _, kind in ipairs({ "explicit", "user" }) do
		helpers.it("ignores delayed execution failure after consumed " .. kind .. " close", function()
			with_browser(function(host, h, errors)
				local complete, view = ready(h)[1].complete, h.windows[1]
				if kind == "explicit" then assert(host.close()) else view:user_close() end
				h.drain()
				assert(view.disposed and next(h.script_refs) == nil)
				complete(nil, FAILURE)
				assert(#errors == 0, "retired native execution must not emit an ERROR")
			end)
		end)
	end

	helpers.it("isolates a retired view's failure from its new native successor", function()
		with_browser(function(host, h, errors)
			local a = ready(h)[1].complete
			assert(host.close()); h.drain(); assert(h.show())
			assert(#h.windows == 2)
			local b = ready(h)[1].complete
			a(nil, FAILURE)
			assert(#errors == 0, "A completion must remain inert while B is current")
			b(nil, FAILURE)
			assert(#errors == 1, "B's legitimate native error must still be reported")
		end)
	end)

	helpers.it("ignores an old operation without suppressing a failure on the same native view", function()
		with_browser(function(host, h, errors)
			local pending = ready(h)
			assert(host.open({ presets = {}, active_backend = "mlx" }))
			assert(#h.windows == 1 and #pending == 2)
			pending[1].complete(nil, FAILURE)
			assert(#errors == 0, "old operation may not claim this window's error suppression")
			pending[2].complete(nil, FAILURE)
			assert(#errors == 1, "current operation's error must remain visible")
		end)
	end)
end)
