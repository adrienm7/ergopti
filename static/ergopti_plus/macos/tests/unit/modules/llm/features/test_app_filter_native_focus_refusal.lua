--- tests/unit/modules/llm/features/test_app_filter_native_focus_refusal.lua

--- Preserves native focus-read refusal at the public AI exclusion boundary.
local helpers = require("tests.helpers")

--- Owns the real filter and classifier plus declared native and cache boundaries.
---@param callback function Receives the real filter and native controls.
local function with_filter(callback)
	return helpers.with_stub_scope({ "infra.logger", "modules.keymap.utils",
		"adapters.secure_field_detector", "modules.llm.app_filter" }, function()
		local c = { mode = "healthy", role = "AXTextField", subrole = nil,
			bundle = "com.apple.Safari", ignored = false, focus_reads = 0, calls = {} }
		local field = { attributeValue = function(_, attribute)
			if attribute == "AXRole" then return c.role end
			if attribute == "AXSubrole" then return c.subrole end
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
		local front = { pid = function() return 4242 end,
			bundleID = function() return c.bundle end, path = function() return "/Applications/Editor.app" end,
			name = function() return "Editor" end }
		_G.hs = { application = { frontmostApplication = function() return front end },
			window = { focusedWindow = function() return { application = function() return front end } end },
			axuielement = { applicationElementForPID = function(pid)
				helpers.assert_eq(pid, 4242)
				return app_element
			end } }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["modules.keymap.utils"] = { is_ignored_window = function() return c.ignored end }
		return callback(require("modules.llm.app_filter"), c)
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
