--- tests/unit/adapters/keyboard/test_text_sender_identity_without_accessibility.lua

--- ==============================================================================
--- MODULE: The typing application is read without Accessibility
--- DESCRIPTION:
--- Runs TextSender.focusedAppIdentity and terminalInputTarget against an hs
--- double whose Accessibility window read hangs, as it does for an application
--- that does not answer.
---
--- ROOT CAUSE ENCODED:
--- Both are called inside the keyboard event tap: on every expansion that
--- deletes (terminal pacing) and, since 1.0.5, on every bare Return, Cmd+A and
--- Cmd+L. They read hs.window.focusedWindow(), an Accessibility round trip to
--- the focused application that waits up to six seconds while every key of
--- every application waits behind the tap; macOS then disables the tap and
--- releases the queued keys late or held (issues #99 and #100). The typing
--- application must come from NSWorkspace, which never asks it
--- (identity-without-accessibility).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs body over an hs double whose Accessibility window read fails.
--- @param front table|nil The frontmost application double.
--- @param body function fn(TextSender, reads)
local function with_front(front, body)
	local saved_application, saved_window = hs.application, hs.window
	local reads = { window = 0 }
	hs.window = {
		focusedWindow = function()
			reads.window = reads.window + 1
			error("AX: the application does not answer")
		end,
	}
	hs.application = {
		frontmostApplication = function() return front end,
	}
	local ok, err = pcall(helpers.with_fresh_modules, { "adapters.text_sender" }, function()
		body(require("adapters.text_sender"), reads)
	end)
	hs.application, hs.window = saved_application, saved_window
	if not ok then error(err, 0) end
end

--- Builds an application double.
--- @param bundle string
--- @param name string
--- @return table app
local function app(bundle, name)
	return {
		bundleID = function() return bundle end,
		name = function() return name end,
	}
end

helpers.describe("TextSender reads the typing application from NSWorkspace (identity-without-accessibility)", function()
	helpers.it("names the frontmost application without an Accessibility read", function()
		local front = app("com.microsoft.teams2", "Microsoft Teams")
		with_front(front, function(TextSender, reads)
			local bundle, name, found = TextSender.focusedAppIdentity()
			helpers.assert_eq(bundle, "com.microsoft.teams2")
			helpers.assert_eq(name, "Microsoft Teams")
			helpers.assert_true(found == front)
			helpers.assert_eq(reads.window, 0, "no Accessibility window read inside the key tap")
		end)
	end)

	helpers.it("finds a terminal target without an Accessibility read", function()
		local terminal = app("com.googlecode.iterm2", "iTerm2")
		with_front(terminal, function(TextSender, reads)
			helpers.assert_true(TextSender.terminalInputTarget() == terminal)
			helpers.assert_eq(reads.window, 0)
		end)
	end)

	helpers.it("reports no application when none is frontmost", function()
		with_front(nil, function(TextSender, reads)
			helpers.assert_nil(TextSender.focusedAppIdentity())
			helpers.assert_nil(TextSender.terminalInputTarget())
			helpers.assert_eq(reads.window, 0)
		end)
	end)
end)
