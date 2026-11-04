--- tests/meta/architecture/test_launcher_swift_warnings.lua

--- ==============================================================================
--- MODULE: Launcher Swift Warning Guard
--- DESCRIPTION:
--- Keeps the four launcher warnings the Mac build printed (ledger L33) from
--- coming back. The Linux CI has no swiftc, so the shapes are pinned in source:
--- an always-true optional comparison, a statement after Darwin.exit, trailing
--- closures in a guard condition, and a descriptor declared var but never set.
---
--- ROOT CAUSE ENCODED: executeAndReturnError returns a non-optional descriptor,
--- so `returned != nil` was always true; Darwin.exit never returns, so the
--- semaphore signal after it never ran; Swift warns on a trailing closure in a
--- statement condition; the read end of the lease diagnostic pipe is only read.
--- ==============================================================================

local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")

local SOURCES = "launcher/Sources/ErgoptiPlus/"

--- Reads one launcher source.
--- @param name string File name under the launcher sources.
--- @return string source
local function read(name)
	return assert(SourceFile.read(helpers.driver_root() .. "/" .. SOURCES .. name), name)
end

helpers.describe("launcher Swift sources: the L33 warnings stay fixed", function()
	helpers.it("decides the administrator script by its error alone", function()
		local src = read("OwnedVirtualHIDDaemonReportMainOperation.swift")
		helpers.assert_true(src:find("_ = script.executeAndReturnError(&error)", 1, true) ~= nil)
		helpers.assert_true(src:find("scriptReturned = error == nil", 1, true) ~= nil)
		helpers.assert_true(src:find("returned != nil", 1, true) == nil, "an always-true comparison came back")
	end)

	helpers.it("writes nothing after the Darwin.exit of the report dispatch", function()
		local src = read("main.swift")
		local exit_at = assert(src:find("Darwin.exit(OwnedVirtualHIDDaemonReportMainOperation.run(", 1, true))
		local next_line = src:match("^[^\n]*\n([^\n]*)", exit_at)
		helpers.assert_true(next_line ~= nil and next_line:match("^%s*}%s*$") ~= nil,
			"a statement after Darwin.exit is never executed")
	end)

	helpers.it("parenthesises the closures of the request guard", function()
		local src = read("OwnedSuspendedImageGuardian.swift")
		helpers.assert_true(src:find('as? String).map({ validPath($0) }) == true', 1, true) ~= nil)
		helpers.assert_true(src:find('as? NSNumber).map({ CFGetTypeID($0)', 1, true) ~= nil)
	end)

	helpers.it("declares the read end of the lease diagnostic pipe as a constant", function()
		local src = read("RemapLeaseWorker.swift")
		helpers.assert_true(src:find("let diagnosticReadDescriptor = diagnosticPipe[0]", 1, true) ~= nil)
		helpers.assert_true(src:find("var diagnosticReadDescriptor", 1, true) == nil)
	end)
end)
