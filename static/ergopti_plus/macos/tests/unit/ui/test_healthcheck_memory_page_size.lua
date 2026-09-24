--- tests/unit/ui/test_healthcheck_memory_page_size.lua

--- ==============================================================================
--- MODULE: Healthcheck Memory Page Size Regression
--- DESCRIPTION:
--- Exercises the real hardware and system collectors with native memory
--- snapshots so free memory uses the host page size instead of assuming
--- Intel-sized pages. The values are bytes; the shared page formats them.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("healthcheck-memory-page-size", function()
	--- Loads the real collectors over one hs.host.vmStat answer.
	--- @param snapshot table What vmStat returns.
	--- @return table hardware, table system
	local function collect(snapshot)
		helpers.load_with_stubs("infra.logger")
		hs.host.vmStat = function() return snapshot end
		package.loaded["ui.healthcheck.helpers"] = nil
		local H = require("ui.healthcheck.helpers")
		return H.collect_hardware(), H.collect_system(false, 0)
	end

	helpers.it("uses 16 KiB native pages when computing free memory", function()
		local hardware, system = collect({ pagesFree = 65536, pageSize = 16384, memSize = 17179869184 })
		helpers.assert_eq(system.ram_free, 1073741824)
		helpers.assert_eq(hardware.ram_total, 17179869184)
	end)

	helpers.it("preserves 4 KiB pages and zero free memory", function()
		local hardware, system = collect({ pagesFree = 262144, pageSize = 4096, memSize = 8589934592 })
		helpers.assert_eq(system.ram_free, 1073741824)
		helpers.assert_eq(hardware.ram_total, 8589934592)
		local _, empty = collect({ pagesFree = 0, pageSize = 16384, memSize = 17179869184 })
		helpers.assert_eq(empty.ram_free, 0)
	end)

	helpers.it("does not invent a page size when the native snapshot is incomplete", function()
		local hardware, system = collect({ pagesFree = 65536, memSize = 17179869184 })
		helpers.assert_nil(system.ram_free, "an unknown page size must leave free memory unknown")
		helpers.assert_eq(hardware.ram_total, 17179869184)
	end)
end)
