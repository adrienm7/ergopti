--- tests/unit/ui/test_download_window_javascript_boundary.lua

--- ==============================================================================
--- MODULE: Download Window JavaScript Boundary Contracts
--- DESCRIPTION:
--- Pins strict native submission, asynchronous result observation, privacy and
--- operation-scoped diagnostic bounds independently of the window lifecycle.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the boundary with an isolated observable logger.
--- @param scenario function Receives the module and captured errors.
local function with_boundary(scenario)
	local name = "ui.download_window.javascript"
	local saved_module, saved_logger = package.loaded[name], package.loaded["infra.logger"]
	local errors = {}
	package.loaded[name] = nil
	package.loaded["infra.logger"] = { error = function(_, message, ...)
		errors[#errors + 1] = string.format(message, ...)
	end }
	local ok, err = xpcall(function() scenario(require(name), errors) end, debug.traceback)
	package.loaded[name], package.loaded["infra.logger"] = saved_module, saved_logger
	if not ok then error(err, 0) end
end

helpers.describe("download-window-javascript-boundary", function()
	helpers.it("commits only the exact native receiver and observes successful completion", function()
		with_boundary(function(boundary, errors)
			local context = boundary.new_context(1, "mlx_install")
			local callback, received
			local view = { evaluateJavaScript = function(self, code, done)
				callback, received = done, code
				return self
			end }
			helpers.assert_true(boundary.execute(view, "PRIVATE_PAYLOAD", context))
			helpers.assert_eq(received, "PRIVATE_PAYLOAD")
			helpers.assert_eq(type(callback), "function")
			callback(nil, nil)
			helpers.assert_eq(#errors, 0)
		end)
	end)

	for _, refusal in ipairs({ "nil", "false", "other-object" }) do
		helpers.it("rejects native " .. refusal .. " without pretending submission succeeded", function()
			with_boundary(function(boundary, errors)
				local view = { evaluateJavaScript = function()
					if refusal == "false" then return false end
					if refusal == "other-object" then return {} end
				end }
				helpers.assert_eq(boundary.execute(view, "PRIVATE_PAYLOAD", boundary.new_context(1, "mlx_install")), false)
				helpers.assert_eq(#errors, 1)
			end)
		end)
	end

	helpers.it("bounds each category independently and never logs native error text", function()
		with_boundary(function(boundary, errors)
			local context = boundary.new_context(12, "mlx_install")
			local mode, callback = "throw", nil
			local view = { evaluateJavaScript = function(self, _, done)
				if mode == "throw" then error("PRIVATE_NATIVE_ERROR") end
				if mode == "refuse" then return nil end
				callback = done
				return self
			end }
			for _, failure in ipairs({ "throw", "refuse", "async" }) do
				mode = failure
				for _ = 1, 20 do
					local submitted = boundary.execute(view, "PRIVATE_PAYLOAD", context)
					helpers.assert_eq(submitted, failure == "async")
					if callback then callback(nil, { localizedDescription = "PRIVATE_SCRIPT_ERROR" }) end
				end
			end
			helpers.assert_eq(#errors, 3)
			for _, message in ipairs(errors) do
				helpers.assert_true(message:find("session=12", 1, true) ~= nil)
				helpers.assert_true(message:find("kind=mlx_install", 1, true) ~= nil)
				helpers.assert_true(message:find("PRIVATE_", 1, true) == nil)
			end
		end)
	end)

	helpers.it("late errors retain their original operation and cannot consume a successor diagnostic", function()
		with_boundary(function(boundary, errors)
			local callbacks = {}
			local view = { evaluateJavaScript = function(self, _, callback)
				callbacks[#callbacks + 1] = callback
				return self
			end }
			helpers.assert_true(boundary.execute(view, "old", boundary.new_context(1, "mlx_install")))
			helpers.assert_true(boundary.execute(view, "new", boundary.new_context(2, "ollama_install")))
			callbacks[1](nil, {})
			callbacks[1](nil, {})
			callbacks[2](nil, {})
			helpers.assert_eq(#errors, 2)
			helpers.assert_true(errors[1]:find("session=1", 1, true) ~= nil)
			helpers.assert_true(errors[2]:find("session=2", 1, true) ~= nil)
		end)
	end)

	helpers.it("fails fast on invalid operation metadata and payload", function()
		with_boundary(function(boundary)
			local cases = {
				{ call = function() boundary.new_context(0, "mlx_install") end,
					message = "positive integer session" },
				{ call = function() boundary.new_context(math.huge, "mlx_install") end,
					message = "positive integer session" },
				{ call = function() boundary.new_context(1, "unsafe\nkind") end,
					message = "stable kind identifier" },
				{ call = function() boundary.execute({}, nil, boundary.new_context(1, "mlx_install")) end,
					message = "string payload" },
				{ call = function() boundary.execute({}, "code", nil) end,
					message = "operation diagnostic context" },
			}
			for _, case in ipairs(cases) do
				local ok, err = pcall(case.call)
				helpers.assert_eq(ok, false)
				helpers.assert_true(tostring(err):find(case.message, 1, true) ~= nil,
					"failure must identify the rejected contract, not an unrelated exception")
			end
		end)
	end)
end)
