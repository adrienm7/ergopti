--- tests/unit/ui/action_picker/lifecycle/test_native_private_observer.lua

--- ==============================================================================
--- MODULE: Private Native Diagnostic Observer Controls
--- DESCRIPTION:
--- Exercises the actual read-only observer against Lua-owned upvalues and closed
--- file userdata type controls. No WebKit message or native success is simulated.
--- ==============================================================================

local helpers = require("tests.helpers")
local root = assert(helpers.driver_root():match("^(.*)/static/ergopti_plus/macos/$"))
local Observer = assert(loadfile(root .. "/tools/diagnostics/macos_action_picker_pool_observer.lua"))()

--- Creates userdata type controls with no open file descriptor.
--- @return userdata value Closed-file userdata carrying a test metatable.
local function userdata_value()
	local value = assert(io.tmpfile()); assert(value:close())
	debug.setmetatable(value, {})
	return value
end

--- Creates a plain private owner; these values are never native evidence.
--- @return table session Private observer test state.
local function session_value()
	local sentinel = {}
	return { webview = userdata_value(), usercontent = userdata_value(),
		on_confirm = function() return sentinel end, controller_lease = {} }
end

--- Captures the exact expected upvalue name in a Lua fixture, with a clear seam.
--- @param state any Upvalue value for the observer's type controls.
--- @return table picker Source-owned fixture.
--- @return function clear Releases the fixture's state without debug mutation.
local function subject(state)
	local _active_session = state
	return { open = function() return _active_session ~= nil end }, function() _active_session = nil end
end

--- Observes only when the actual function's source matches the expected owner.
--- @param picker table Source-owned fixture.
--- @return table observation View and controller only.
local function observe(picker)
	return Observer.snapshot(picker, debug.getinfo(picker.open, "S").source)
end

--- Requires refusal without depending on exception wording.
--- @param callback function Invalid observation.
local function refuses(callback)
	local accepted = pcall(callback)
	helpers.assert_eq(accepted, false)
end

helpers.describe("private source-pinned observer remains read-only and exact", function()
	helpers.it("returns only exact view/controller without retaining the private owner or callbacks", function()
		local session = session_value()
		local weak = setmetatable({ session = session, callback = session.on_confirm,
			sentinel = session.on_confirm() }, { __mode = "v" })
		local original_view, original_controller, original_token = session.webview, session.usercontent, session.controller_lease
		local picker, clear = subject(session)
		local observed = observe(picker)
		helpers.assert_true(picker.open(), "observer must not revoke the source-owned upvalue")
		helpers.assert_true(rawequal(observed.view, original_view) and rawequal(session.webview, original_view))
		helpers.assert_true(rawequal(observed.controller, original_controller) and rawequal(session.usercontent, original_controller))
		helpers.assert_true(rawequal(session.controller_lease, original_token))
		helpers.assert_true(rawequal(session.on_confirm, weak.callback))
		local count = 0
		for key in pairs(observed) do
			assert(key == "view" or key == "controller", "private owner escaped the observer")
			count = count + 1
		end
		helpers.assert_eq(count, 2)
		clear(); session = nil
		collectgarbage("collect"); collectgarbage("collect")
		helpers.assert_nil(weak.session)
		helpers.assert_nil(weak.callback)
		helpers.assert_nil(weak.sentinel)
		helpers.assert_not_nil(getmetatable(observed.view))
	end)

	helpers.it("refuses a foreign source instead of accepting a matching upvalue spelling", function()
		local picker = subject(session_value())
		refuses(function() Observer.snapshot(picker, "@foreign/action_picker/init.lua") end)
	end)

	helpers.it("refuses missing and renamed current-owner upvalues", function()
		refuses(function() observe({ open = function() return true end }) end)
		local other_session = session_value()
		refuses(function() observe({ open = function() return other_session ~= nil end }) end)
	end)

	helpers.it("refuses changed upvalue types and metatable-backed private state", function()
		for _, value in ipairs({ false, "owner", userdata_value(), setmetatable(session_value(), {}) }) do
			local picker = subject(value)
			refuses(function() observe(picker) end)
		end
		local picker = subject(nil)
		refuses(function() observe(picker) end)
	end)

	for _, field in ipairs({ "closing", "retired" }) do
		helpers.it("refuses the current owner after " .. field, function()
			local session = session_value(); session[field] = true
			local picker = subject(session)
			refuses(function() observe(picker) end)
		end)
	end

	helpers.it("refuses absent controllers and consumed views without changing either", function()
		local session = session_value()
		local picker = subject(session)
		local controller = session.usercontent
		session.usercontent = nil
		refuses(function() observe(picker) end)
		session.usercontent = controller
		debug.setmetatable(session.webview, nil)
		refuses(function() observe(picker) end)
		helpers.assert_nil(getmetatable(session.webview))
		helpers.assert_true(rawequal(session.usercontent, controller))
	end)

	helpers.it("keeps the native completion error and value without accepting an NSError failure", function()
		helpers.with_stub_scope({ "json", "adapters.webview_result", "compat.utf8" }, function()
			for _, failure in ipairs({ { code = 0 }, { code = 5, domain = "WKErrorDomain",
				localizedDescription = "JavaScript execution returned an unsupported type" } }) do
				local completion, script, accepted, detail, observed
				-- This is a completion-port double, never a WebKit message or native evidence.
				local view = setmetatable({ evaluateJavaScript = function(_, source, callback)
					script, completion = source, callback
				end }, {})
				Observer.post_registered_action({ view = view }, "owned_id", function(ok, reason, evaluation)
					accepted, detail, observed = ok, reason, evaluation
				end)
				helpers.assert_eq(script, 'doConfirm("owned_id"); true')
				helpers.assert_nil(accepted, "the observer must await the completion port")
				completion(true, failure)
				helpers.assert_eq(accepted, failure.code == 0)
				helpers.assert_true(rawequal(observed.value, failure))
				helpers.assert_eq(observed.result, true)
				helpers.assert_eq(observed.result_type, "boolean")
				helpers.assert_eq(observed.value_type, "table")
				if failure.code == 5 then helpers.assert_not_nil(detail) else helpers.assert_nil(detail) end
			end
		end)
	end)
end)
