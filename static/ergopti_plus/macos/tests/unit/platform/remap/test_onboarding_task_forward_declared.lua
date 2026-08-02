--- tests/unit/platform/remap/test_onboarding_task_forward_declared.lua

--- ==============================================================================
--- MODULE: Regression — onboarding async task closure-nil forward declaration
--- DESCRIPTION:
--- onboarding.lua spawns four hs.task jobs (shasum, curl, hdiutil, osascript).
--- Each completion callback clears the GC-root pin via M._active_tasks[task] = nil.
--- When the task handle is declared inline — `local task = hs.task.new(...)` —
--- the closure is compiled before the local is in scope, so `task` binds the nil
--- global _G.task. The callback then executes M._active_tasks[nil] = nil, which
--- raises "table index is nil". Hammerspoon swallows hs.task callback errors to
--- the Console (never the file logger), so the KE install wedges silently.
---
--- Fix: forward-declare each handle before the hs.task.new call:
---   local task
---   task = hs.task.new(...)
--- and guard the pin clear: if task then M._active_tasks[task] = nil end
---
--- This test pins the ROOT CAUSE (declaration order) — it fails on the inline form
--- and passes only on the split forward-declaration form.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("karabiner/onboarding: all four hs.task closures forward-declare their handle (closure-nil guard)", function()
	local function read_src()
		-- Selected by a declaration unique to platform/remap/onboarding.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function run_pkg_with_sudo_async")
		helpers.assert_true(src ~= nil, "platform/remap/onboarding.lua source must be locatable")
		return src
	end

	helpers.it("no hs.task.new handle is assigned inline into a `local` on the same line", function()
		local src = read_src()
		-- Scan non-comment lines: any `local <id> = hs.task.new(` is the broken form.
		-- A comment may document why the broken form is forbidden; don't fail on those.
		local offending
		for line in src:gmatch("[^\n]+") do
			local stripped = line:match("^%s*(.-)%s*$") or line
			if not stripped:match("^%-%-") and stripped:find("local%s+[%w_]+%s*=%s*hs%.task%.new") then
				offending = stripped
				break
			end
		end
		helpers.assert_true(offending == nil,
			"all hs.task.new handles that are referenced inside callbacks must be forward-declared "
			.. "(local X; X = hs.task.new(...)). Offending line: " .. tostring(offending))
	end)

	helpers.it("all four async task sites use the split forward-declaration pattern", function()
		local src = read_src()
		-- Each site must have:  "local task\n\ttask = hs.task.new("  (two separate lines)
		local _, fwd_count = src:gsub("local task%s*\n%s*task = hs%.task%.new%(", "")
		helpers.assert_true(fwd_count >= 4,
			"expected at least 4 forward-declared `local task` sites in onboarding.lua; got " .. tostring(fwd_count))
	end)

	helpers.it("all four GC-pin releases are guarded against nil task", function()
		local src = read_src()
		-- Without the guard, if hs.task.new returns nil (binary missing), the callback
		-- would still run M._active_tasks[nil] = nil → "table index is nil".
		local _, guard_count = src:gsub("if task then M%._active_tasks%[task%] = nil end", "")
		helpers.assert_true(guard_count >= 4,
			"expected at least 4 nil-guarded GC-pin releases in onboarding.lua; got " .. tostring(guard_count))
	end)
end)
