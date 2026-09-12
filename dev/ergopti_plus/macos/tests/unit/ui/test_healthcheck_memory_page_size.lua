--- tests/unit/ui/test_healthcheck_memory_page_size.lua

--- ==============================================================================
--- MODULE: Healthcheck Memory Page Size Regression
--- DESCRIPTION:
--- Exercises the real system collector with native memory snapshots so free
--- memory uses the host page size instead of assuming Intel-sized pages.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("healthcheck-memory-page-size", function()
	local function collect(snapshot)
		helpers.load_with_stubs("infra.logger", {
			execute = function(command)
				if command:find("vm_stat", 1, true) then return tostring(snapshot.pagesFree) .. "\n" end
				if command:find("hw.memsize", 1, true) then return tostring(snapshot.memSize) .. "\n" end
				return ""
			end,
		})
		package.loaded["hs.host"] = {
			operatingSystemVersionString = function() return "macOS" end,
			locale = { current = function() return "en_US" end },
			vmStat = function() return snapshot end,
		}
		package.loaded["ui.healthcheck.helpers"] = nil
		return require("ui.healthcheck.helpers").sys_info()
	end

	helpers.it("uses 16 KiB native pages when computing free memory", function()
		local info = collect({ pagesFree = 65536, pageSize = 16384, memSize = 17179869184 })
		helpers.assert_eq(info.ram_free, "1.0 GB")
		helpers.assert_eq(info.ram_total, "16.0 GB")
	end)

	helpers.it("preserves 4 KiB pages and zero free memory", function()
		local info = collect({ pagesFree = 262144, pageSize = 4096, memSize = 8589934592 })
		helpers.assert_eq(info.ram_free, "1.0 GB")
		helpers.assert_eq(info.ram_total, "8.0 GB")
		info = collect({ pagesFree = 0, pageSize = 16384, memSize = 17179869184 })
		helpers.assert_eq(info.ram_free, "0.0 GB")
	end)

	helpers.it("does not invent a page size when the native snapshot is incomplete", function()
		local info = collect({ pagesFree = 65536, memSize = 17179869184 })
		helpers.assert_eq(info.ram_free, "?")
		helpers.assert_eq(info.ram_total, "16.0 GB")
	end)
end)
