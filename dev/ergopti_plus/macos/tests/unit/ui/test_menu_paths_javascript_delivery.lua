--- tests/unit/ui/test_menu_paths_javascript_delivery.lua

--- ==============================================================================
--- MODULE: Paths Editor JavaScript Delivery
--- DESCRIPTION:
--- Exercises native script failures and stale deferred callbacks without real configuration writes.
--- ==============================================================================

local helpers = require("tests.helpers")
local load_fixture = require("tests.support.paths_editor_fixture")

local function with_editor(callback)
	helpers.with_fresh_modules({ "infra.deferred_work" }, function()
		local pending, evaluations = {}, {}
		package.loaded["infra.deferred_work"] = { after = function(_, fn)
			pending[#pending + 1] = fn
			return true
		end }
		local state = {}
		local view = { delete = function() if state.delete_throws then error("delete refused") end end }
		function view:evaluateJavaScript(code, done)
			evaluations[#evaluations + 1] = { code = code, done = done }
			if state.submit then return state.submit(self, done) end
			return self
		end
		local editor, calls = load_fixture(view)
		helpers.assert_true(editor.init("/virtual/app/", function() error("reload not permitted") end))
		helpers.assert_true(editor.open_editor())
		hs.osascript = { applescript = function() return true, "/PRIVATE_PATH/" end }
		callback(editor, calls, state, evaluations, pending)
	end)
end

helpers.describe("paths JavaScript delivery", function()
	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("(paths-js-delivery) construction scheduling refusal " .. mode .. " is visible", function()
			with_editor(function(editor, calls, _, evaluations)
				calls.bridge_callback({ body = { action = "cancel" } })
				package.loaded["infra.deferred_work"].after = function()
					if mode == "throw" then error("PRIVATE_PATH") end
					return false
				end
				local builder = package.loaded["ui.ui_builder"]
				local create = builder.show_webview
				builder.show_webview = function(options)
					local view = create(options)
					options.on_navigation("didFinishNavigation")
					return view
				end
				helpers.assert_true(editor.open_editor())
				helpers.assert_eq(#evaluations, 0)
				helpers.assert_eq(#calls.errors, 1)
				helpers.assert_true(calls.errors[1]:find("scheduling refused", 1, true) ~= nil)
				helpers.assert_eq(calls.errors[1]:find("PRIVATE_PATH", 1, true), nil)
			end)
		end)
	end
	for _, mode in ipairs({ "nil", "false", "throw" }) do
		helpers.it("(paths-js-delivery) scheduling refusal " .. mode .. " is visible", function()
			with_editor(function(_, calls, _, evaluations)
				package.loaded["infra.deferred_work"].after = function()
					if mode == "throw" then error("PRIVATE_PATH") end
					if mode == "false" then return false end
				end
				calls.bridge_callback({ body = { action = "browse" } })
				helpers.assert_eq(#evaluations, 0)
				helpers.assert_eq(#calls.errors, 1)
				helpers.assert_eq(calls.errors[1]:find("PRIVATE_PATH", 1, true), nil)
			end)
		end)
	end
	helpers.it("(paths-js-delivery) cleanup-only owners reject late execution errors", function()
		with_editor(function(_, calls, state, evaluations)
			calls.bridge_callback({ body = { action = "ready" } })
			state.delete_throws = true
			calls.bridge_callback({ body = { action = "cancel" } })
			local errors = #calls.errors
			evaluations[1].done(nil, { message = "PRIVATE_PATH" })
			helpers.assert_eq(#calls.errors, errors)
		end)
	end)
	for _, mode in ipairs({ "throw", "wrong_type" }) do
		helpers.it("(paths-js-delivery) encoding failure " .. mode .. " is bounded", function()
			with_editor(function(_, calls, _, evaluations)
				hs.json.encode = function() if mode == "throw" then error("PRIVATE_PATH") end; return false end
				for _ = 1, 3 do calls.bridge_callback({ body = { action = "ready" } }) end
				helpers.assert_eq(#evaluations, 0)
				helpers.assert_eq(#calls.errors, 1)
				helpers.assert_eq(calls.errors[1]:find("PRIVATE_PATH", 1, true), nil)
			end)
		end)
	end
	for _, route in ipairs({ "navigation", "browse" }) do
		helpers.it("(paths-js-delivery) " .. route .. " cannot target a replacement", function()
			with_editor(function(editor, calls, _, evaluations, pending)
				if route == "navigation" then calls.options.on_navigation("didFinishNavigation")
				else calls.bridge_callback({ body = { action = "browse" } }); pending[1]() end
				local delayed = pending[#pending]
				calls.bridge_callback({ body = { action = "cancel" } })
				helpers.assert_true(editor.open_editor())
				delayed()
				helpers.assert_eq(#evaluations, 0)
			end)
		end)
	end
	helpers.it("(paths-js-delivery) a newer browse supersedes the previous result", function()
		with_editor(function(_, calls, _, evaluations, pending)
			calls.bridge_callback({ body = { action = "browse" } })
			pending[1]()
			calls.bridge_callback({ body = { action = "browse" } })
			pending[3]()
			pending[2]()
			helpers.assert_eq(#evaluations, 0)
			pending[4]()
			helpers.assert_eq(#evaluations, 1)
		end)
	end)
	helpers.it("(paths-js-delivery) logging reentry cannot redirect initData", function()
		with_editor(function(editor, calls, _, evaluations)
			package.loaded["infra.logger"].debug = function(_, message)
				if message == "Injecting initData into webview…" then
					calls.options.on_close()
					helpers.assert_true(editor.open_editor())
				end
			end
			calls.bridge_callback({ body = { action = "ready" } })
			helpers.assert_eq(#evaluations, 0)
		end)
	end)
	helpers.it("(paths-js-delivery) deferred navigation survives normal construction", function()
		with_editor(function(editor, calls, _, evaluations, pending)
			calls.bridge_callback({ body = { action = "cancel" } })
			local builder = package.loaded["ui.ui_builder"]
			local create = builder.show_webview
			builder.show_webview = function(options)
				local view = create(options)
				options.on_navigation("didFinishNavigation")
				return view
			end
			helpers.assert_true(editor.open_editor())
			helpers.assert_eq(#pending, 1)
			pending[1]()
			helpers.assert_eq(#evaluations, 1)
		end)
	end)
	helpers.it("(paths-js-delivery) browse control characters use JSON string encoding", function()
		with_editor(function(_, calls, _, evaluations, pending)
			local picked = "/PRIVATE\r\n\t\"\\PATH/"
			local expected = [["/PRIVATE\r\n\t\"\\PATH/"]]
			hs.json.encode = function(value)
				helpers.assert_eq(value, picked)
				return expected
			end
			hs.osascript.applescript = function() return true, picked end
			calls.bridge_callback({ body = { action = "browse" } })
			pending[1](); pending[2]()
			local encoded = assert(evaluations[1].code:match("^window%.applyBrowseResult%((.*)%)$"))
			helpers.assert_eq(encoded, expected)
			helpers.assert_eq(encoded:find("[%z\1-\31]"), nil)
		end)
	end)
	for _, action in ipairs({ "ready", "browse" }) do
		for _, mode in ipairs({ "nil", "false", "throw", "async", "success" }) do
			helpers.it("(paths-js-delivery) " .. action .. " " .. mode, function()
				with_editor(function(_, calls, state, evaluations, pending)
					state.submit = function(self)
						if mode == "nil" then return nil end
						if mode == "false" then return false end
						if mode == "throw" then error("PRIVATE_PATH") end
						return self
					end
					calls.bridge_callback({ body = { action = action } })
					if action == "browse" then pending[1](); pending[2]() end
					helpers.assert_eq(#evaluations, 1)
					if mode == "async" or mode == "success" then
						helpers.assert_type(evaluations[1].done, "function")
						evaluations[1].done(nil, mode == "async" and { message = "PRIVATE_PATH" } or nil)
					end
					helpers.assert_eq(#calls.errors, mode == "success" and 0 or 1)
					for _, message in ipairs(calls.errors) do helpers.assert_eq(message:find("PRIVATE_PATH", 1, true), nil) end
				end)
			end)
		end
	end
end)
