--- tests/unit/adapters/test_atspi_context_async.lua

--- Exercises the private async protocol without replacing native ownership rules.
local helpers = require("tests.helpers")
local Json = require("json")
-- Native transitive owners must initialize before a scoped transport substitution.
require("adapters.atspi_focus")

local function fixture(body)
	local names = { "adapters.atspi_focus", "adapters.owned_process", "luv" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local state = { deliveries = 0 }
	package.loaded["luv"] = { exepath = function() return "/owned/lua" end, os_getpid = function() return 1234 end }
	package.loaded["adapters.owned_process"] = { start = function(executable, argv, options, callback)
		state.executable, state.argv, state.options, state.callback = executable, argv, options, callback
		state.operation = { on_settled = function(_, fn) state.settled_callback = fn end }
		return state.operation
	end }
	package.loaded["adapters.atspi_focus"] = nil
	local ok, err = pcall(function()
		local focus = require("adapters.atspi_focus")
		local field = { bus = ":1.7", path = "/field/A", role = 61 }
		state.field = field
		focus.start_context_capture(field, { owner = "generation:1", authorized = function() return true end }, function(context)
			state.deliveries, state.context = state.deliveries + 1, context
		end)
		function state.frame(receipt)
			return "CONTEXT:" .. Json.encode({ field = receipt or field,
				context = { app_id = "editor", title = "PRIVATE_TITLE_CANARY", native_identity = "native:window" } })
		end
		body(state)
	end)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

helpers.describe("owned asynchronous AT-SPI context protocol", function()
	helpers.it("(context-async) direct canonical worker retains one deadline and no private argv/body capture", function()
		fixture(function(state)
			assert(state.executable == "/owned/lua")
			assert(state.argv[1]:match("/adapters/atspi_context_worker%.lua$"))
			assert(state.argv[5] == require("infra.paths").shared("lua"))
			assert(state.argv[6] == "1234")
			assert(state.options.timeout_ms == 1000 and state.options.capture_output == false and state.options.capture_tail == false)
			for _, value in ipairs(state.argv) do assert(not value:find("PRIVATE_TITLE_CANARY", 1, true)) end
			local encoded = state.frame()
			state.options.on_output(encoded:sub(1, 13), "stdout")
			state.options.on_output(encoded:sub(14), "stdout")
			assert(state.deliveries == 0)
			state.callback({ ok = true })
			assert(state.deliveries == 1 and state.context.title == "PRIVATE_TITLE_CANARY")
		end)
	end)

	helpers.it("(context-async) rejects missing malformed duplicate stderr failed and mismatched observations", function()
		for _, mode in ipairs({ "empty", "malformed", "duplicate", "stderr", "failed", "field", "role" }) do
			fixture(function(state)
				local receipt = mode == "field" and { bus = ":1.7", path = "/field/B", role = 61 }
					or mode == "role" and { bus = ":1.7", path = "/field/A", role = 40 } or nil
				local frame = state.frame(receipt)
				if mode == "malformed" then frame = "CONTEXT:{" end
				if mode == "duplicate" then frame = frame .. frame end
				if mode ~= "empty" then state.options.on_output(frame, mode == "stderr" and "stderr" or "stdout") end
				state.callback({ ok = mode ~= "failed" })
				assert(state.deliveries == 1 and state.context == nil, mode .. " cannot authorize context")
			end)
		end
	end)

	helpers.it("(context-async) canceled settlement discards staged private data without completion", function()
		fixture(function(state)
			state.options.on_output(state.frame(), "stdout")
			state.settled_callback()
			assert(state.deliveries == 0)
			state.callback({ ok = true })
			assert(state.context == nil, "revoked output must not remain after physical settlement")
		end)
	end)
end)
