--- tests/meta/architecture/test_native_bridge_transport_setup.lua

--- ==============================================================================
--- MODULE: Installed Source Bridge Transport Setup Guard
--- DESCRIPTION:
--- The installed physical source bridge makes its five transport descriptors
--- nonblocking before its relay loop, whose first step reads the child's
--- output pipe and only then sends a cancellation.
---
--- ROOT CAUSE ENCODED (28 October audit lead, confirmed in the source): the
--- setup was written `cancelled = cancelled || !descriptors.allSatisfy(...)`.
--- Swift's || short-circuits, so after a preparation or activation refusal the
--- pipes stayed blocking, and the first read of a quiet held child blocked the
--- bridge before ergopti_owned_program_cancel could ever run. allSatisfy also
--- stops at its first refusal, leaving the later descriptors blocking.
--- The launcher lane cannot reach this path without a real installed peer, so
--- this guard reads the bridge itself.
--- ==============================================================================

local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")

--- Reads the bridge without its comments, so prose cannot satisfy the guard.
--- @return string source
local function bridge_code()
	local source = assert(SourceFile.read(helpers.driver_root()
		.. "launcher/Sources/ErgoptiPlus/InstalledPhysicalSourceBridge.swift"))
	local lines = {}
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = line:gsub("//.*$", "")
	end
	return table.concat(lines, "\n")
end

helpers.describe("installed source bridge: transport setup runs on every path (bridge-transport-nonblocking)", function()
	helpers.it("sets every descriptor nonblocking whatever an earlier refusal decided", function()
		local code = bridge_code()
		local setup = code:find("nonblocking)", 1, true) or code:find("nonblocking }", 1, true)
		helpers.assert_true(setup ~= nil, "the bridge must still apply its nonblocking transport setup")
		helpers.assert_true(code:find("||[^\n]*nonblocking") == nil,
			"a short-circuited setup leaves the pipes blocking after a refusal")
		helpers.assert_true(code:find("%]%s*%.allSatisfy%(nonblocking%)") == nil,
			"allSatisfy stops at the first refusal and leaves the later descriptors blocking")
		helpers.assert_true(code:find("%.map%(nonblocking%)") ~= nil,
			"each descriptor is set nonblocking before the verdict is combined")
	end)

	helpers.it("finishes the setup before the relay loop first reads the child", function()
		local code = bridge_code()
		local setup = code:find("%.map%(nonblocking%)")
		local loop = code:find("while true {", 1, true)
		helpers.assert_true(setup ~= nil and loop ~= nil, "the setup and the relay loop must both exist")
		helpers.assert_true(setup < loop, "the descriptors are nonblocking before the first read")
	end)
end)
