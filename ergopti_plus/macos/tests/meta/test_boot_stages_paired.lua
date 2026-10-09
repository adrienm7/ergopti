--- tests/meta/test_boot_stages_paired.lua

--- ==============================================================================
--- MODULE: Every boot mark closes an opened stage (boot-stage-trail)
--- DESCRIPTION:
--- A START line with no SUCCESS is how a log shows where a boot died, and the
--- fatal report names the open stage. That only works when every
--- Boot.mark("X") in init.lua closes a Boot.stage("X") opened before it, with
--- no other mark in between. Root boot cannot be loaded headlessly, so this
--- guard reads init.lua.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Returns init.lua with line comments removed.
local function init_code()
	local source = helpers.read_driver_unit("local function abort_pre_runtime_boot")
	helpers.assert_true(type(source) == "string" and source ~= "",
		"root init.lua must remain discoverable by its pre-runtime abort boundary")
	return (source:gsub("%-%-[^\n]*", ""))
end

--- Lists boot profiler calls in source order.
local function boot_calls(code)
	local calls = {}
	for at, kind, name in code:gmatch('()Boot%.(%a+)%("([^"]*)"%)') do
		if kind == "stage" or kind == "mark" then
			calls[#calls + 1] = { at = at, kind = kind, name = name }
		end
	end
	table.sort(calls, function(a, b) return a.at < b.at end)
	return calls
end

helpers.describe("root boot: paired boot stages (boot-stage-trail)", function()
	helpers.it("every Boot.mark closes the Boot.stage opened just before it", function()
		local calls = boot_calls(init_code())
		local marks = 0
		local open = nil
		for _, call in ipairs(calls) do
			if call.kind == "stage" then
				open = call.name
			else
				marks = marks + 1
				helpers.assert_eq(open, call.name,
					"Boot.mark(\"" .. call.name .. "\") must close a stage of the same name")
				-- The onboarding branch closes the same stage on its early return.
				if call.name ~= "First-launch guard (onboarding check)" then open = nil end
			end
		end
		helpers.assert_true(marks >= 20, "expected every boot mark, found " .. tostring(marks))
	end)

	helpers.it("boot ends with a whole-boot duration", function()
		local code = init_code()
		local last_mark = code:find('Boot.mark("Boot complete (post-init deferrals scheduled)")', 1, true)
		local complete = code:find("Boot.complete()", last_mark or 1, true)
		helpers.assert_true(last_mark ~= nil and complete ~= nil,
			"Boot.complete() must follow the final mark")
	end)

	helpers.it("a post-onboarding abort names the running stage", function()
		local code = init_code()
		local body_at = code:find("local function emergency_exit_after_runtime_failure(", 1, true)
		local report_at = code:find("BootFatal.report(report_stage,", body_at or 1, true)
		local stage_at = code:find("Boot.current_stage()", body_at or 1, true)
		helpers.assert_true(body_at ~= nil and stage_at ~= nil and report_at ~= nil
			and stage_at < report_at,
			"the generic boot owner must be replaced by Boot.current_stage() in the fatal report")
	end)
end)
