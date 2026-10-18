--- tests/unit/ui/lifecycle/test_window_script_callback_custody.lua

--- ==============================================================================
--- MODULE: Window Script Callback Custody
--- DESCRIPTION:
--- The native script callback registry is independent of WebView userdata GC.
--- Run real hosts and factory while retaining rejected unref capabilities,
--- fencing old bridge actions and admitting successors only after cleanup.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_window = require("tests.support.ui.owned_window_close_fixture")

--- Controls only native controller return values and userdata retirement.
--- @param module_name string Real window host.
--- @param scenario function Complete callback and window lifetime scenario.
local function with_bridge(module_name, scenario)
	return helpers.with_fresh_modules({ "updater.release_parser", "updater.check_result" }, function()
		return with_window(module_name, function(host, h)
			h.releases = 0
			local construct_view, construct_controller = hs.webview.new, hs.webview.usercontent.new
			hs.webview.new = function(...)
				local view = construct_view(...)
				setmetatable(view, { __name = "hs.webview" })
				for _, name in ipairs({ "delete", "user_close" }) do
					local native = view[name]
					view[name] = function(self, ...)
						local result = table.pack(pcall(native, self, ...))
						if self.disposed then setmetatable(self, nil) end
						if not result[1] then error(result[2], 0) end
						return table.unpack(result, 2, result.n)
					end
				end
				return view
			end
			hs.webview.usercontent.new = function(...)
				local controller = construct_controller(...)
				local native = controller.setCallback
				function controller:setCallback(callback)
					if callback == nil then
						h.releases = h.releases + 1
						if h.on_release then h.on_release(self) end
						if h.unref_mode == "throw" then error("native callback unref refused") end
						if h.unref_mode == "false" then return false end
						if h.unref_mode == "nil" then return nil end
						if h.unref_mode == "foreign" then return {} end
					end
					local result = native(self, callback)
					if callback ~= nil and h.bind_throws then error("native callback retained before binding raised") end
					return result
				end
				return controller
			end
			local logger, errors = require("infra.logger"), {}
			local original = logger.error
			h.errors = errors
			logger.error = function(tag, message, ...)
				errors[#errors + 1] = string.format(message, ...)
				return original(tag, message, ...)
			end
			local ok, err = xpcall(function() scenario(host, h) end, debug.traceback)
			logger.error = original
			if not ok then error(err, 0) end
		end)
	end)
end

--- Delivers a legitimate old host action after page authority was retired.
--- @param module_name string Host whose bridge is retained.
--- @param receiver function Original native callback.
local function old_action(module_name, receiver)
	if module_name == "ui.model_browser" then receiver({ body = "ready" })
	elseif module_name == "ui.metrics_apps" then receiver({ body = { action = "pick" } })
	else receiver({ body = { action = "close" } }) end
end

helpers.describe("script callback cleanup keeps exact native custody", function()
	for _, module_name in ipairs({ "ui.update_check", "ui.model_browser", "ui.metrics_apps" }) do
		helpers.it(module_name .. " preserves an active callback during ordinary same-window reuse", function()
			with_bridge(module_name, function(_, h)
				helpers.assert_true(h.show())
				local controller, receiver = h.controllers[1], h.script_refs[h.controllers[1]]
				helpers.assert_type(receiver, "function")
				helpers.assert_true(h.show())
				helpers.assert_eq(#h.controllers, 1)
				helpers.assert_true(h.script_refs[controller] == receiver)
				helpers.assert_eq(h.releases, 0)
				helpers.assert_true(h.close())
				h.drain()
				helpers.assert_nil(next(h.retained))
			end)
		end)
		for _, mode in ipairs({ "user", "explicit" }) do
			helpers.it(module_name .. " releases its callback on " .. mode .. " close without touching a successor", function()
				with_bridge(module_name, function(_, h)
					helpers.assert_true(h.show())
					local first, controller = h.windows[1], h.controllers[1]
					helpers.assert_not_nil(h.script_refs[controller])
					if mode == "user" then first:user_close() else helpers.assert_true(h.close()) end
					helpers.assert_nil(h.script_refs[controller], "window GC alone does not release a script callback")
					helpers.assert_eq(h.releases, 1, "the exact callback must be released once")
					helpers.assert_true(h.show())
					local successor = h.controllers[2]
					h.drain()
					helpers.assert_nil(h.retained[first])
					helpers.assert_not_nil(h.script_refs[successor], "old native fade completion cannot unref a new bridge")
					h.windows[2]:user_close()
					helpers.assert_nil(next(h.script_refs))
				end)
			end)
		end

		for _, refusal in ipairs({ "throw", "false", "nil", "foreign" }) do
			helpers.it(module_name .. " retains rejected unref " .. refusal .. " and retries before reopening", function()
				with_bridge(module_name, function(_, h)
					helpers.assert_true(h.show())
					local controller = h.controllers[1]
					local receiver = h.script_refs[controller]
					h.unref_mode = refusal
					h.windows[1]:user_close()
					helpers.assert_nil(next(h.retained))
					helpers.assert_true(h.script_refs[controller] == receiver)
					local timers = #h.timers
					old_action(module_name, receiver)
					helpers.assert_eq(#h.timers, timers, "retired bridge actions must not create native work")
					helpers.assert_eq(h.show(), false, "unacknowledged unref must block a new controller")
					helpers.assert_eq(#h.controllers, 1)
					h.unref_mode = nil
					helpers.assert_true(h.show())
					helpers.assert_nil(h.script_refs[controller])
					old_action(module_name, receiver)
					helpers.assert_not_nil(h.script_refs[h.controllers[2]])
					h.windows[2]:user_close()
					helpers.assert_nil(next(h.script_refs))
				end)
			end)
		end

		helpers.it(module_name .. " retires callback ownership when native window publication fails", function()
			with_bridge(module_name, function(_, h)
				h.policy_refuses = "throw"
				helpers.assert_eq(h.show(), false)
				h.drain()
				helpers.assert_nil(next(h.retained))
				helpers.assert_nil(next(h.script_refs))
			end)
		end)

		helpers.it(module_name .. " blocks callback-cleanup reentry until native acknowledgement", function()
			with_bridge(module_name, function(_, h)
				helpers.assert_true(h.show())
				local entered = false
				h.on_release = function()
					entered = true
					helpers.assert_eq(h.show(), false)
					helpers.assert_eq(#h.controllers, 1)
				end
				h.windows[1]:user_close()
				helpers.assert_true(entered)
				helpers.assert_nil(next(h.script_refs))
			end)
		end)

		helpers.it(module_name .. " retains an append-then-throw callback until exact cleanup succeeds", function()
			with_bridge(module_name, function(_, h)
				h.bind_throws, h.unref_mode = true, "throw"
				local ok, opened = pcall(h.show)
				helpers.assert_true(ok, "native binding refusal must return through the host boundary")
				helpers.assert_eq(opened, false)
				helpers.assert_not_nil(h.script_refs[h.controllers[1]])
				local errors = table.concat(h.errors, "\n")
				helpers.assert_true(errors:find("native callback retained before binding raised", 1, true) ~= nil)
				helpers.assert_true(errors:find("native callback unref refused", 1, true) ~= nil)
				h.bind_throws = false
				helpers.assert_eq(h.show(), false)
				helpers.assert_eq(#h.controllers, 1)
				h.unref_mode = nil
				helpers.assert_true(h.show())
				h.windows[1]:user_close()
				helpers.assert_nil(next(h.script_refs))
			end)
		end)
	end
end)

helpers.describe("close logging preserves exact callback ownership", function()
	helpers.it("update-check close cannot unref a successor admitted by a synchronous log sink", function()
		with_bridge("ui.update_check", function(_, h)
			helpers.assert_true(h.show())
			local logger = require("infra.logger")
			local original, entered = logger.info, false
			logger.info = function(tag, message, ...)
				if not entered and message == "Update-check window closed." then
					entered = true
					helpers.assert_true(h.show())
				end
				return original(tag, message, ...)
			end
			local ok, err = xpcall(function()
				helpers.assert_true(h.close())
				helpers.assert_true(entered)
				helpers.assert_eq(#h.controllers, 2)
				helpers.assert_nil(h.script_refs[h.controllers[1]])
				helpers.assert_not_nil(h.script_refs[h.controllers[2]], "old cleanup cannot unref a successor")
				h.drain()
				h.windows[2]:user_close()
				helpers.assert_nil(next(h.script_refs))
			end, debug.traceback)
			logger.info = original
			if not ok then error(err, 0) end
		end)
	end)
end)

helpers.describe("callback custody covers native option evaluation", function()
	helpers.it("update-check retires its bound callback when the native geometry getter raises", function()
		with_bridge("ui.update_check", function(_, h)
			local logger, errors = require("infra.logger"), {}
			local original = logger.error
			logger.error = function(tag, message, ...)
				errors[#errors + 1] = string.format(message, ...)
				return original(tag, message, ...)
			end
			local screen = hs.screen.mainScreen
			hs.screen.mainScreen = function() error("native geometry port refused") end
			local ok, err = xpcall(function()
				local admitted, opened = pcall(h.show)
				helpers.assert_true(admitted, "native option failure must be contained by the host")
				helpers.assert_eq(opened, false)
				helpers.assert_nil(next(h.script_refs))
				helpers.assert_true(table.concat(errors, "\n"):find("native geometry port refused", 1, true) ~= nil)
				hs.screen.mainScreen = screen
				helpers.assert_true(h.show())
				h.windows[1]:user_close()
				helpers.assert_nil(next(h.script_refs))
			end, debug.traceback)
			logger.error = original
			if not ok then error(err, 0) end
		end)
	end)
end)
