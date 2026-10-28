--- tests/unit/adapters/keyboard/test_secure_role_native_refusal.lua

--- Native AX nil/error results must remain distinct from optional nil-only values.
local helpers = require("tests.helpers")
local SECURE = "AXSecureTextField"

--- Loads a fresh detector over a counted native attribute boundary.
---@param callback function Receives the detector and declared native controls.
local function with_detector(callback)
	return helpers.with_stub_scope({ "adapters.secure_field_detector", "infra.logger", "hs", "tests.stubs.hs" }, function()
		local control = { role = "AXTextField", queries = {}, logs = {} }
		package.loaded["infra.logger"] = { debug = function(_, format, ...)
			control.logs[#control.logs + 1] = string.format(format, ...)
		end }
		local field = { attributeValue = function(_, attribute)
			control.queries[#control.queries + 1] = attribute
			local role = attribute == "AXRole"
			if (role and control.role_throws) or (not role and control.subrole_throws) then
				error("controlled native AX exception", 0)
			end
			if (role and control.role_refused) or (not role and control.subrole_refused) then
				return nil, "Messaging failed"
			end
			if role then return control.role end
			return control.subrole
		end }
		local app = { pid = function() return 4242 end }
		local detector = helpers.load_with_stubs("adapters.secure_field_detector", {
			application = { frontmostApplication = function() return app end },
			axuielement = { applicationElementForPID = function(pid)
				helpers.assert_eq(pid, 4242)
				return { attributeValue = function(_, attribute)
					helpers.assert_eq(attribute, "AXFocusedUIElement")
					return field
				end }
			end },
		})
		return callback(detector, control, field)
	end)
end

local CASES = {
	{ "ordinary optional nil subrole", { role = "AXTextField" }, false, true },
	{ "ordinary explicit subrole", { role = "AXTextField", subrole = "AXTextEntryArea" }, false, true },
	{ "native secure role", { role = SECURE }, true, true },
	{ "browser secure subrole", { role = "AXTextField", subrole = SECURE }, true, true },
	{ "nil-only role", { nil_role = true }, false, false },
	{ "malformed role", { role = 7 }, false, false },
	{ "malformed subrole", { role = "AXTextField", subrole = {} }, false, false },
	{ "native role error", { role = SECURE, role_refused = true }, true, false },
	{ "native subrole error", { role = "AXTextField", subrole = SECURE, subrole_refused = true }, true, false },
	{ "both native errors", { role_refused = true, subrole_refused = true }, true, false },
	{ "role exception", { role_throws = true }, true, false },
	{ "subrole exception", { subrole_throws = true }, true, false },
	{ "known secure role despite subrole error", { role = SECURE, subrole_refused = true }, true, true },
	{ "known secure subrole despite role error", { role_refused = true, subrole = SECURE }, true, true },
	{ "known secure role despite subrole exception", { role = SECURE, subrole_throws = true }, true, true },
	{ "known secure subrole despite role exception", { role_throws = true, subrole = SECURE }, true, true },
}
helpers.describe("Native AXRole and AXSubrole error returns", function()
	for _, recipe in ipairs(CASES) do
		helpers.it("preserves classification evidence for " .. recipe[1], function()
			with_detector(function(detector, control, field)
				for key, value in pairs(recipe[2]) do control[key] = value end
				if control.nil_role then control.role = nil end
				local calls, complete = 0, nil
				local values = table.pack(detector.isElementSecure(field, function(known)
					calls, complete = calls + 1, known
				end))
				helpers.assert_eq(values.n, 1)
				helpers.assert_eq(values[1], recipe[3], "Native AX refusal must suppress capture")
				helpers.assert_eq(complete, recipe[4]); helpers.assert_eq(calls, 1)
				helpers.assert_eq(control.queries, { "AXRole", "AXSubrole" })
			end)
		end)
	end
	helpers.it("keeps exactly two public inspection results and the exact inspected PID", function()
		with_detector(function(detector, control)
			control.subrole_refused = true
			local calls, complete, pid = 0, nil, nil
			local values = table.pack(detector.inspectFocusedElement(4242, function(known, inspected)
				calls, complete, pid = calls + 1, known, inspected
			end))
			helpers.assert_eq(values.n, 2); helpers.assert_eq(values[1], true); helpers.assert_nil(values[2])
			helpers.assert_eq(calls, 1); helpers.assert_eq(complete, false); helpers.assert_eq(pid, 4242)
			helpers.assert_eq(control.queries, { "AXRole", "AXSubrole" })
		end)
	end)
	helpers.it("keeps refresh void and recovers the cache through a healthy ordinary read", function()
		with_detector(function(detector, control)
			control.subrole_refused = true
			local complete, pid
			local values = table.pack(detector.refresh(function(known, inspected) complete, pid = known, inspected end))
			helpers.assert_eq(values.n, 0); helpers.assert_eq(detector.isSecureField(), true)
			helpers.assert_eq(complete, false); helpers.assert_eq(pid, 4242)
			control.subrole_refused, control.queries = false, {}
			values = table.pack(detector.refresh(function(known, inspected) complete, pid = known, inspected end))
			helpers.assert_eq(values.n, 0); helpers.assert_eq(detector.isSecureField(), false)
			helpers.assert_eq(complete, true); helpers.assert_eq(pid, 4242)
			helpers.assert_eq(control.queries, { "AXRole", "AXSubrole" })
		end)
	end)
	helpers.it("reports the failed native read in the existing diagnostic", function()
		with_detector(function(detector, control, field)
			control.subrole_refused = true
			helpers.assert_eq(detector.isElementSecure(field), true)
			helpers.assert_eq(#control.logs, 1)
			helpers.assert_true(control.logs[1]:find("role_read=true, subrole_read=false", 1, true) ~= nil)
		end)
	end)
end)
