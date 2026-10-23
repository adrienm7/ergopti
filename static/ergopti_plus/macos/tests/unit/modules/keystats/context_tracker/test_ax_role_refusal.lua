--- tests/unit/modules/keystats/context_tracker/test_ax_role_refusal.lua

--- Exercises native role refusals through the real public pause/resume and sink.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.keystats.context_tracker.ax_role_refusal_fixture")

--- Requires the actual output gate and synthetic snapshot sink to agree.
---@param runtime table Existing real public runtime.
---@param expected boolean Expected persistence permission.
local function sink(runtime, expected)
	local accepted, snapshots = runtime.sink()
	helpers.assert_eq(runtime.engine.may_persist(), expected)
	helpers.assert_eq(accepted, expected)
	helpers.assert_eq(snapshots, expected and 1 or 0)
end

--- Publishes a healthy target before any pause or native transport refusal.
---@param runtime table Existing real public runtime.
---@param shape string ordinary, appkit, or webkit.
local function target(runtime, shape)
	runtime.native.field_role = shape == "appkit" and "AXSecureTextField" or "AXTextField"
	runtime.native.field_subrole = shape == "webkit" and "AXSecureTextField" or nil
	runtime.foreground(shape == "appkit" and "TextEdit" or "Google Chrome",
		shape == "appkit" and "com.apple.TextEdit" or "com.google.Chrome")
	runtime.native.title = "Ordinary fixture page"
	runtime.activate()
	helpers.assert_eq(runtime.state.is_secure_field, shape ~= "ordinary")
	sink(runtime, shape == "ordinary")
end

--- Keeps unrelated lifecycle errors and AX-focus faults out of this regression.
---@param runtime table Existing real public runtime.
local function healthy(runtime)
	helpers.assert_eq(runtime.native.refused_focus_reads, 0)
	helpers.assert_eq(runtime.native.absent_focus_reads, 0)
	helpers.assert_eq(#runtime.observation.logs, 0)
end

--- Requires the real resume to settle its identity and modifier owners.
---@param runtime table Existing real public runtime.
---@return table row Actual public resume receipt.
local function resume(runtime)
	local row = runtime.resume()
	helpers.assert_eq(runtime.observation.tracker_receipts[#runtime.observation.tracker_receipts].result, true)
	helpers.assert_eq(row.foreground_refresh_pending, false)
	helpers.assert_eq(row.modifier_context_pending, false)
	helpers.assert_eq(row.auth_modifier_pending, false)
	helpers.assert_eq(row.admission_open, true)
	return row
end

helpers.describe("Native AX role refusal during public resume", function()
	for _, shape in ipairs({ "ordinary", "appkit", "webkit" }) do
		helpers.it("preserves healthy public admission for " .. shape, function()
			Fixture.with_runtime(function(runtime)
				target(runtime, shape); runtime.pause(); resume(runtime)
				sink(runtime, shape == "ordinary"); healthy(runtime)
			end)
		end)
	end
	for _, site in ipairs({ "role", "subrole", "both" }) do
		helpers.it("denies a known secure target through native " .. site .. " refusal and retry", function()
			Fixture.with_runtime(function(runtime)
				target(runtime, site == "role" and "appkit" or "webkit")
				local pid, name = runtime.native.pid, runtime.native.name
				local role, subrole = runtime.native.field_role, runtime.native.field_subrole
				runtime.pause(); runtime.activate()
				runtime.native.role_refused = site ~= "subrole"
				runtime.native.subrole_refused = site ~= "role"
				local role_errors, subrole_errors = runtime.native.refused_role_reads, runtime.native.refused_subrole_reads
				local row = resume(runtime)
				helpers.assert_eq(row.secure, true); sink(runtime, false)
				helpers.assert_eq(runtime.native.refused_role_reads - role_errors, site ~= "subrole" and 2 or 0)
				helpers.assert_eq(runtime.native.refused_subrole_reads - subrole_errors, site ~= "role" and 2 or 0)
				helpers.assert_eq(runtime.state.active_app_pid, pid); helpers.assert_eq(row.active_app_name, name)
				runtime.native.role_refused, runtime.native.subrole_refused = false, false
				runtime.pause(); resume(runtime); sink(runtime, false)
				helpers.assert_eq(runtime.native.field_role, role); helpers.assert_eq(runtime.native.field_subrole, subrole)
				helpers.assert_eq(runtime.native.pid, pid); helpers.assert_eq(runtime.native.name, name)
				healthy(runtime)
			end)
		end)
	end
	for _, site in ipairs({ "role", "subrole" }) do
		helpers.it("reopens an unchanged ordinary target after a healthy " .. site .. " retry", function()
			Fixture.with_runtime(function(runtime)
				target(runtime, "ordinary"); runtime.pause()
				runtime.native.role_refused = site == "role"
				runtime.native.subrole_refused = site == "subrole"
				resume(runtime); sink(runtime, false)
				helpers.assert_eq(runtime.state.is_secure_field, true)
				runtime.native.role_refused, runtime.native.subrole_refused = false, false
				runtime.pause(); resume(runtime); sink(runtime, true)
				helpers.assert_eq(runtime.state.is_secure_field, false); healthy(runtime)
			end)
		end)
	end
end)
