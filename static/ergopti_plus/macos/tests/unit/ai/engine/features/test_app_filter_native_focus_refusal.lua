--- tests/unit/ai/engine/features/test_app_filter_native_focus_refusal.lua

--- Preserves native focus-read refusal at the public AI exclusion boundary.
local helpers = require("tests.helpers")

--- Owns the real filter and classifier plus declared native and cache boundaries.
---@param callback function Receives the real filter and native controls.
local function with_filter(callback)
	return helpers.with_stub_scope({ "core.logger.engine.logger", "modules.keymap.utils",
		"platform.focus.secure_field_detector", "ai.engine.prediction.app_filter" }, function()
		local c = { mode = "healthy", role = "AXTextField", subrole = nil,
			bundle = "com.apple.Safari", ignored = false, focus_reads = 0, calls = {} }
		local field = { attributeValue = function(_, attribute)
			if attribute == c.unsupported_attribute then return nil, "Attribute is not supported by target" end
			if attribute == c.failed_attribute then
				if c.failed_exception then error("AX read failed") end
				return nil, "Messaging failed"
			end
			if attribute == "AXRole" and c.role_error then return nil, "Messaging failed" end
			if attribute == "AXRole" and c.role_throws then error("AX role unavailable") end
			if attribute == "AXRole" then return c.role end
			if attribute == "AXSubrole" then return c.subrole end
			if attribute == "AXParent" then return c.parent end
			return nil
		end }
		local app_element = { attributeValue = function(_, attribute)
			helpers.assert_eq(attribute, "AXFocusedUIElement")
			c.focus_reads = c.focus_reads + 1
			if c.mode == "native_error" then
				c.calls[#c.calls + 1] = { count = 2, value_is_nil = true, detail = "Messaging failed" }
				return nil, "Messaging failed"
			end
			if c.mode == "exception" then error("native focus bridge exception", 0) end
			if c.mode == "nil_exception" then error(nil, 0) end
			c.calls[#c.calls + 1] = { count = 1, value_is_nil = c.mode == "absent" }
			if c.mode == "absent" then return nil end
			return field
		end }
		local front = { pid = function() if c.mode == "pid_error" then error("PID unavailable") end; return 4242 end,
			bundleID = function() if c.mode == "bundle_error" then error("bundle unavailable") end; if c.mode == "bundle_bad" then return 7 end; return c.bundle end,
			path = function() if c.mode == "path_error" then error("path unavailable") end; if c.mode == "path_bad" then return {} end; if c.mode == "path_absent" then return nil end; return "/Applications/Editor.app" end,
			name = function() if c.mode == "name_error" then error("name unavailable") end; if c.mode == "name_bad" then return 7 end; return "Editor" end }
		_G.hs = { application = { frontmostApplication = function()
				if c.mode == "front_error" then error("front application unavailable") end
				return front
			end },
			window = { focusedWindow = function()
				if c.mode == "window_error" then error("focused window unavailable") end
				if c.mode == "no_window" or c.mode == "front_error" then return nil end
				return { application = function()
					if c.mode == "window_app_error" then error("window application unavailable") end
					if c.mode == "window_app_absent" then return nil end
					return front
				end }
			end },
			axuielement = { applicationElementForPID = function(pid)
				helpers.assert_eq(pid, 4242)
				if c.mode == "app_error" then error("AX application unavailable") end
				if c.mode == "app_absent" then return nil end
				return app_element
			end } }
		package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
		package.loaded["modules.keymap.utils"] = { is_ignored_window = function() return c.ignored end }
		return callback(require("ai.engine.prediction.app_filter"), c)
	end)
end

--- Checks the public one-boolean return and the exact lazy native-read count.
local function blocked(filter, controls, secure, url, expected, reads, label)
	local before = controls.focus_reads
	local values = table.pack(filter.is_blocked({}, {}, url, secure))
	helpers.assert_eq(values.n, 1, "The public exclusion contract returns exactly one value")
	helpers.assert_eq(controls.focus_reads - before, reads, "The active filters share one lazy AX focus resolution")
	helpers.assert_eq(values[1], expected, label)
end

helpers.describe("Native AX focus refusal in the AI app filter", function()
	helpers.it("(native-ai-focus) admits a healthy ordinary field", function()
		with_filter(function(f, c) blocked(f, c, true, true, false, 1) end)
	end)
	for _, axis in ipairs({ "role", "subrole" }) do
		helpers.it("(native-ai-focus) blocks a healthy secure " .. axis, function()
			with_filter(function(f, c)
				if axis == "role" then c.role = "AXSecureTextField" else c.subrole = "AXSecureTextField" end
				blocked(f, c, true, false, true, 1)
			end)
		end)
	end
	helpers.it("(native-ai-focus) blocks a healthy browser URL field", function()
		with_filter(function(f, c)
			c.subrole = "AXURLField"
			blocked(f, c, false, true, true, 1)
		end)
	end)
	helpers.it("(native-ai-url-role) admits a known non-text browser role", function()
		with_filter(function(f, c)
			c.role = "AXButton"
			blocked(f, c, false, true, false, 1)
		end)
	end)
	for _, mode in ipairs({ "nil", "empty", "malformed", "native_error", "exception" }) do
		helpers.it("(native-ai-url-role) blocks an unclassifiable browser role: " .. mode, function()
			with_filter(function(f, c)
				if mode == "nil" then c.role = nil
				elseif mode == "empty" then c.role = ""
				elseif mode == "malformed" then c.role = 7
				elseif mode == "native_error" then c.role_error = true
				else c.role_throws = true end
				blocked(f, c, false, true, true, 1, "an unknown browser role cannot rule out a URL bar")
			end)
		end)
	end
	for _, attribute in ipairs({ "AXSubrole", "AXIdentifier", "AXParent" }) do
		for _, mode in ipairs({ "native", "exception" }) do
			helpers.it("blocks browser URL classification when " .. attribute .. " refuses: " .. mode, function()
				with_filter(function(f, c)
					c.failed_attribute, c.failed_exception = attribute, mode == "exception"
					blocked(f, c, false, true, true, 1, "a transport failure cannot prove the field is not a URL bar")
				end)
			end)
		end
	end
	helpers.it("admits an ordinary field when an optional URL attribute is unsupported", function()
		for _, attribute in ipairs({ "AXSubrole", "AXIdentifier", "AXParent" }) do
			with_filter(function(f, c)
				c.unsupported_attribute = attribute
				blocked(f, c, false, true, false, 1, "unsupported differs from failed transport")
			end)
		end
	end)
	for _, stage in ipairs({ "parent_role", "parent_parent", "grandparent_role" }) do
		helpers.it("blocks an unreadable URL ancestry: " .. stage, function()
			with_filter(function(f, c)
				local grandparent = { attributeValue = function() return nil, "Messaging failed" end }
				c.parent = { attributeValue = function(_, attribute)
					if stage == "parent_role" and attribute == "AXRole" then return nil, "Messaging failed" end
					if attribute == "AXRole" then return "AXGroup" end
					if stage == "parent_parent" then return nil, "Messaging failed" end
					return grandparent
				end }
				blocked(f, c, false, true, true, 1)
			end)
		end)
	end
	for _, filter in ipairs({ "secure", "url" }) do
		helpers.it("(native-ai-focus) preserves nil-only absence with " .. filter .. " filtering", function()
			with_filter(function(f, c)
				c.mode = "absent"
				blocked(f, c, filter == "secure", filter == "url", false, 1)
				helpers.assert_eq(c.calls[1].count, 1)
			end)
		end)
	end
	for _, selection in ipairs({ "secure", "url", "both" }) do
		helpers.it("(native-ai-focus) blocks native focus refusal with " .. selection .. " filtering", function()
			with_filter(function(f, c)
				local secure, url = selection ~= "url", selection ~= "secure"
				c.subrole = selection == "url" and "AXURLField" or "AXSecureTextField"
				blocked(f, c, secure, url, true, 1)
				c.mode = "native_error"
				blocked(f, c, secure, url, true, 1, "Confirmed native AX focus refusal must retain AI exclusion")
				local refusal = c.calls[#c.calls]
				helpers.assert_eq(refusal.count, 2); helpers.assert_eq(refusal.value_is_nil, true)
				helpers.assert_eq(refusal.detail, "Messaging failed")
				c.mode = "healthy"
				blocked(f, c, secure, url, true, 1)
				c.subrole = nil
				blocked(f, c, secure, url, false, 1)
			end)
		end)
	end
	for _, selection in ipairs({ "secure", "url" }) do
		helpers.it("(native-ai-focus) blocks focus exceptions with " .. selection .. " filtering", function()
			with_filter(function(f, c)
				c.mode = "exception"
				blocked(f, c, selection == "secure", selection == "url", true, 1,
					"A failed focus read must retain AI exclusion")
			end)
		end)
	end
	helpers.it("does not bypass a path exclusion when native application path is unavailable", function()
		with_filter(function(f, c)
			local exclusions = { { appPath = "/Applications/Secret.app" } }
			helpers.assert_eq(f.is_blocked({}, exclusions, false, false), false)
			c.mode = "path_absent"
			helpers.assert_eq(f.is_blocked({}, exclusions, false, false), true,
				"a missing native path cannot prove that a path exclusion does not apply")
			helpers.assert_eq(f.is_blocked({}, {}, false, false), false,
				"an unused missing path must not block ordinary applications")
		end)
	end)
	for _, mode in ipairs({ "bundle_error", "path_error", "name_error", "bundle_bad", "path_bad", "name_bad" }) do
		helpers.it("(native-ai-metadata) blocks when the focused application's metadata raises: " .. mode, function()
			with_filter(function(f, c)
				c.mode = mode
				blocked(f, c, false, false, true, 0, "an unreadable app cannot be checked against exclusions")
			end)
		end)
	end
	helpers.it("(native-ai-metadata) blocks a bundle error before URL classification", function()
		with_filter(function(f, c)
			c.mode = "bundle_error"
			blocked(f, c, false, true, true, 0)
		end)
	end)
	for _, mode in ipairs({ "window_error", "window_app_error", "window_app_absent", "front_error" }) do
		helpers.it("(native-ai-focus-owner) blocks an unreadable focused application: " .. mode, function()
			with_filter(function(f, c)
				c.mode = mode
				blocked(f, c, true, true, true, 0, "a failed window-owner read must not use another application")
				helpers.assert_nil(f.focused_app_id())
			end)
		end)
	end
	helpers.it("(native-ai-focus-owner) retains frontmost fallback when no window exists", function()
		with_filter(function(f, c)
			c.mode = "no_window"
			blocked(f, c, true, true, false, 1)
			helpers.assert_eq(f.focused_app_id(), c.bundle)
		end)
	end)
	for _, mode in ipairs({ "pid_error", "app_error", "app_absent" }) do
		helpers.it("(native-ai-application) blocks when AX application acquisition fails: " .. mode, function()
			with_filter(function(f, c)
				c.mode = mode
				blocked(f, c, true, true, true, 0, "unavailable AX application cannot prove input is safe")
			end)
		end)
	end
	helpers.it("(native-ai-focus) blocks a nil-valued Lua focus exception", function()
		with_filter(function(f, c)
			c.mode = "nil_exception"
			blocked(f, c, true, false, true, 1, "A failed focus read must retain AI exclusion")
		end)
	end)
	helpers.it("(native-ai-focus) keeps disabled filters free of AX reads", function()
		with_filter(function(f, c)
			c.mode = "native_error"
			blocked(f, c, false, false, false, 0)
		end)
	end)
	helpers.it("(native-ai-focus) keeps URL-only non-browser checks free of AX reads", function()
		with_filter(function(f, c)
			c.mode, c.bundle = "native_error", "test.editor"
			blocked(f, c, false, true, false, 0)
		end)
	end)
	helpers.it("(native-ai-focus) refuses an unknown keymap cache before AX reads", function()
		with_filter(function(f, c)
			c.mode, c.ignored = "native_error", nil
			blocked(f, c, true, true, true, 0)
		end)
	end)
end)
