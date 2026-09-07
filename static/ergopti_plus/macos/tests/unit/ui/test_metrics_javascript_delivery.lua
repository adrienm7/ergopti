--- tests/unit/ui/test_metrics_javascript_delivery.lua

--- ==============================================================================
--- MODULE: Metrics JavaScript Delivery Boundaries
--- DESCRIPTION:
--- Drives real fresh and cached publication through native submission and completion.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_window = require("tests.support.dashboard_window_fixture")

local function with_delivery(cached, callback)
	helpers.with_fresh_modules({ "adapters.file_system", "modules.keylogger.sqlite_reader",
		"modules.keylogger.context_tracker" }, function()
		package.loaded["adapters.file_system"] = { read_with_status = function() return "{}", "ok" end }
		package.loaded["modules.keylogger.sqlite_reader"] = { read_manifest = function() return {} end }
		package.loaded["modules.keylogger.context_tracker"] = { get_active_app_snapshot = function() end }
		with_window("ui.metrics_apps", function(dashboard, state)
			local pending, evaluations, errors, successes = {}, {}, {}, {}
			local original_open = io.open
			local ok, err = xpcall(function()
				io.open = function(_, mode)
					if mode == "w" then return { write = function() end, close = function() end } end
					if cached then return { read = function() return "cache" end, close = function() end } end
					return nil
				end
				package.loaded["hs.fs"].attributes = function() return true end
				package.loaded["hs.json"].encode = function() return "{}" end
				package.loaded["hs.json"].decode = function(value)
					return value == "cache" and { manifest = "{}" } or {}
				end
				local manager = package.loaded["modules.keylogger.log_manager"]
				manager.get_sqlite_path = function() return "/virtual/db.sqlite" end
				manager.get_db_rev = function() return 1 end
				package.loaded["adapters.timer_scheduler"].after = function(_, fn)
					local handle = { timer = {} }
					pending[#pending + 1] = function() handle.timer = nil; fn() end
					return handle, true
				end
				helpers.assert_true(dashboard.show())
				state.view.evaluateJavaScript = function(self, code, done)
					evaluations[#evaluations + 1] = { code = code, done = done }
					if state.submit then return state.submit(self, code, done) end
					return self
				end
				local logger = package.loaded["infra.logger"]
				logger.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
				logger.success = function(_, message, ...) successes[#successes + 1] = string.format(message, ...) end
				pending[#pending]()
				if not cached then pending[#pending]() end
				helpers.assert_eq(#evaluations, 1)
				callback(dashboard, state, evaluations, errors, successes, pending)
			end, debug.traceback)
			io.open = original_open
			if not ok then error(err, 0) end
		end)
	end)
end

helpers.describe("metrics JavaScript delivery", function()
	for _, mode in ipairs({ "nil", "async", "success" }) do
		helpers.it("(metrics-js-delivery) category publication " .. mode, function()
			with_delivery(false, function(dashboard, state, evaluations, errors)
				local choose
				hs.chooser = {}
				hs.chooser.new = function(callback)
					choose = callback
					local chooser = {}
					for _, method in ipairs({ "placeholderText", "choices", "searchSubText", "show", "delete" }) do
						chooser[method] = function(self) return self end
					end
					return chooser
				end
				package.loaded["infra.dialog_util"].text_prompt = function() return "button.ok", "1" end
				package.loaded["adapters.file_system"].write_if_unchanged = function() return true end
				state.submit = function(self) if mode ~= "nil" then return self end end
				helpers.assert_true(dashboard.prompt_category("Example", "Old", 0))
				choose({ _kind = "pick", _value = "New" })
				helpers.assert_eq(#evaluations, 2)
				helpers.assert_true(evaluations[2].code:find("updateUserCategories", 1, true) ~= nil)
				if mode ~= "nil" then
					evaluations[2].done(nil, mode == "async" and { message = "PRIVATE_PAYLOAD" } or nil)
				end
				helpers.assert_eq(#errors, mode == "success" and 0 or 1)
				for _, message in ipairs(errors) do helpers.assert_eq(message:find("PRIVATE_PAYLOAD", 1, true), nil) end
			end)
		end)
	end
	helpers.it("(metrics-js-delivery) synchronous completion cannot precede native admission", function()
		with_delivery(false, function(_, state, evaluations, errors, successes)
			state.submit = function(_, _, done) done(nil); return nil end
			evaluations[1].done("function")
			helpers.assert_eq(#errors, 1)
			helpers.assert_eq(#successes, 0)
			evaluations[2].done(nil)
			helpers.assert_eq(#successes, 0)
		end)
	end)
	helpers.it("(metrics-js-delivery) old and duplicate completions cannot publish", function()
		with_delivery(false, function(dashboard, _, evaluations, errors, successes)
			evaluations[1].done("function")
			evaluations[1].done("function")
			helpers.assert_eq(#evaluations, 2)
			helpers.assert_true(dashboard.close())
			helpers.assert_true(dashboard.show())
			local count = #successes
			evaluations[2].done(nil)
			evaluations[2].done(nil, { message = "PRIVATE_PAYLOAD" })
			helpers.assert_eq(#errors, 0)
			helpers.assert_eq(#successes, count)
		end)
	end)
	helpers.it("(metrics-js-delivery) failure logging cannot transfer an old completion", function()
		with_delivery(false, function(dashboard, _, evaluations, errors, successes)
			evaluations[1].done("function")
			local logger = package.loaded["infra.logger"]
			local report = logger.error
			logger.error = function(...)
				report(...)
				helpers.assert_true(dashboard.close())
				helpers.assert_true(dashboard.show())
			end
			evaluations[2].done(nil, { message = "PRIVATE_PAYLOAD" })
			local count = #successes
			evaluations[2].done(nil)
			helpers.assert_eq(#errors, 1)
			helpers.assert_eq(#successes, count)
		end)
	end)
	for _, route in ipairs({ "fresh", "cache", "legacy fresh", "legacy cache" }) do
		local cached = route:find("cache", 1, true) ~= nil
		local legacy = route:find("legacy", 1, true) ~= nil
		for _, mode in ipairs({ "nil", "false", "throw", "async", "success", "probe_error" }) do
			helpers.it("(metrics-js-delivery) " .. route .. " mode=" .. mode, function()
				with_delivery(cached, function(_, state, evaluations, errors, successes, pending)
					if mode == "probe_error" then
						if legacy then evaluations[1].done("undefined") end
						local count = #pending
						evaluations[#evaluations].done(nil, { message = "PRIVATE_PAYLOAD" })
						helpers.assert_eq(#errors, 1)
						helpers.assert_eq(#pending, count, "execution failure is not a readiness retry")
					else
						state.submit = function(self, code)
							if code:find("typeof", 1, true) == 1 then return self end
							if mode == "nil" then return nil end
							if mode == "false" then return false end
							if mode == "throw" then error("PRIVATE_PAYLOAD") end
							return self
						end
						if legacy then
							evaluations[1].done("undefined")
							evaluations[2].done("function")
						else
							evaluations[1].done("function")
						end
						helpers.assert_eq(#successes, 0, "submission is not successful execution")
						if mode == "async" or mode == "success" then
							helpers.assert_type(evaluations[#evaluations].done, "function")
							evaluations[#evaluations].done(nil, mode == "async" and { message = "PRIVATE_PAYLOAD" } or nil)
						end
						helpers.assert_eq(#errors, mode == "success" and 0 or 1)
						helpers.assert_eq(#successes, mode == "success" and 1 or 0)
					end
					for _, message in ipairs(errors) do helpers.assert_eq(message:find("PRIVATE_PAYLOAD", 1, true), nil) end
				end)
			end)
		end
	end
end)
