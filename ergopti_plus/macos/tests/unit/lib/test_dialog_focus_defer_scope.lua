--- tests/unit/lib/test_dialog_focus_defer_scope.lua

--- ==============================================================================
--- MODULE: Dialog Focus — The Deferred Raise Is For The Non-Blocking Wrapper
--- DESCRIPTION:
--- `focus_hammerspoon()` uses three mechanisms to make sure a modal dialog gets
--- keyboard focus: two synchronous `hs.focus` / `app:activate` calls, and a
--- deferred `open <bundle>` a tenth of a second later.
---
--- THE THIRD ONE CONTRADICTS ITS OWN PREMISE for two of the three wrappers.
--- `hs.dialog.blockAlert` and `hs.dialog.textPrompt` park the main runloop until
--- the user dismisses them, so a timer armed just before cannot fire until after
--- dismissal — by which point the dialog it was meant to raise is gone. What
--- survives is the side effect: Hammerspoon jumps to the front over whatever the
--- user switched to next.
---
--- `M.alert` is the non-blocking one. Its runloop keeps turning, so the deferred
--- raise reaches the dialog in time and does what it is for.
---
--- WHY THIS IS A SOURCE CHECK: the defect is about a timer that CANNOT fire in
--- the blocking case, so there is nothing to observe from a test that drives
--- these wrappers — the very condition being guarded prevents the observation.
--- What is checkable is that the two blocking wrappers do not ask for the
--- deferral and the non-blocking one does.
---
--- The stall half of this finding shipped separately: the shell-out is
--- ShellRunner.spawn with an argv list now, not a blocking hs.execute, so it no
--- longer parks the runloop immediately before a modal dialog — the one moment
--- the driver can least afford to stop servicing the keyboard tap.
--- ==============================================================================

local helpers = require("tests.helpers")




helpers.describe("dialog_util: the deferred raise is scoped to the non-blocking wrapper", function()

	--- The module source, selected by a declaration unique to it.
	local src = helpers.read_driver_source("local function focus_hammerspoon")

	helpers.it("the source is locatable", function()
		helpers.assert_true(src ~= nil,
			"infra/dialog_util.lua must be locatable — every assertion below reads it")
	end)

	--- Returns the body of a wrapper function, up to its `end`.
	--- @param name string e.g. "M.block_alert".
	--- @return string|nil
	local function wrapper_body(name)
		if not src then return nil end
		local at = src:find("function " .. name .. "(", 1, true)
		if not at then return nil end
		local stop = src:find("\nend", at, true)
		return src:sub(at, stop or #src)
	end

	for _, blocking in ipairs({ "M.block_alert", "M.text_prompt" }) do
		helpers.it(blocking .. " does not arm the deferred raise", function()
			local body = wrapper_body(blocking)
			helpers.assert_true(body ~= nil, blocking .. " must exist")
			helpers.assert_true(body:find("focus_hammerspoon(true)", 1, true) == nil, string.format(
				"%s parks the runloop until the user dismisses it, so a timer armed just "
					.. "before cannot fire until after dismissal. Arming it there does not "
					.. "focus the dialog — it raises Hammerspoon over whatever the user "
					.. "switched to next.", blocking))
			helpers.assert_true(body:find("focus_hammerspoon(", 1, true) ~= nil,
				blocking .. " must still focus synchronously — that is what actually puts "
					.. "the dialog in front")
		end)
	end

	helpers.it("M.alert does arm it", function()
		local body = wrapper_body("M.alert")
		helpers.assert_true(body ~= nil, "M.alert must exist")
		helpers.assert_true(body:find("focus_hammerspoon(true)", 1, true) ~= nil,
			"M.alert is the non-blocking wrapper: its runloop keeps turning, so the "
				.. "deferred raise reaches the dialog in time and is the one case where the "
				.. "third mechanism earns its keep")
	end)

	helpers.it("the shell-out is spawned, not executed inline", function()
		-- The other half of the same finding. hs.execute is io.popen read to EOF —
		-- fully synchronous on the main runloop — and `open` waits on Launch
		-- Services, so the blocking form parked the runloop immediately before
		-- putting up a modal dialog.
		helpers.assert_true(src ~= nil and src:find("ShellRunner.spawn", 1, true) ~= nil,
			"the raise must go through ShellRunner.spawn")
		helpers.assert_true(src ~= nil and src:find("hs.execute", 1, true) == nil,
			"hs.execute is back in dialog_util — it stalls the runloop at the one moment "
				.. "the driver can least afford to stop servicing the keyboard tap")
	end)

end)
