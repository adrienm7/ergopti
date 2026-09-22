--- tests/unit/ui/test_healthcheck_linux_rows.lua

--- ==============================================================================
--- MODULE: The Linux Healthcheck Describes The Machine (Linux)
--- DESCRIPTION:
--- The Linux snapshot's `sys` carried only os, arch and the display kind, so
--- the shared page printed "?" in every CPU, RAM, screen and locale row and had
--- no row naming the distribution or the kernel. The healthcheck now reports
--- the facts the boot snapshot line already probes (one probe set for both),
--- and a fact that cannot be read stays absent so the page omits its row.
--- tools/test/test-diagnostic-ui-integrity.cjs renders the page side.
--- ==============================================================================

local helpers = require("tests.helpers")

local Collector = helpers.load_module("infra.diagnostic_snapshot")

--- An in-memory reader from a path → content table.
--- @param files table
--- @return table
local function fixture_env(files)
	return { read = function(path) return files[path] end }
end

local MACHINE = {
	["/etc/os-release"] = 'NAME="Fedora Linux"\nVERSION_ID=41\nPRETTY_NAME="Fedora Linux 41 (Workstation Edition)"\n',
	["/proc/sys/kernel/osrelease"] = "6.11.4-301.fc41.x86_64\n",
	["/proc/sys/kernel/arch"] = "x86_64\n",
	["/proc/cpuinfo"] = "processor\t: 0\nmodel name\t: AMD Ryzen 7 7840U\n\nprocessor\t: 1\nmodel name\t: AMD Ryzen 7 7840U\n",
	["/proc/meminfo"] = "MemTotal:       32505856 kB\nMemFree:         1000000 kB\nMemAvailable:   16252928 kB\n",
}

helpers.describe("healthcheck (linux): the system facts", function()
	helpers.it("reads the distribution, kernel, CPU and memory", function()
		local facts = Collector.system_facts(fixture_env(MACHINE))
		helpers.assert_eq(facts.os_name, "Fedora Linux 41 (Workstation Edition)")
		helpers.assert_eq(facts.kernel, "6.11.4-301.fc41.x86_64")
		helpers.assert_eq(facts.cpu_model, "AMD Ryzen 7 7840U")
		helpers.assert_eq(facts.cpu_cores, 2)
		helpers.assert_eq(facts.ram_total, "31.0 GB")
		helpers.assert_eq(facts.ram_free, "15.5 GB")
		helpers.assert_true(type(facts.display_server) == "string" and facts.display_server ~= "")
		helpers.assert_true(type(facts.runtime) == "string" and facts.runtime ~= "")
	end)

	helpers.it("leaves an unreadable fact absent instead of inventing one", function()
		local facts = Collector.system_facts(fixture_env({}))
		helpers.assert_nil(facts.os_name)
		helpers.assert_nil(facts.kernel)
		helpers.assert_nil(facts.cpu_model)
		helpers.assert_nil(facts.cpu_cores)
		helpers.assert_nil(facts.ram_total)
	end)

	helpers.it("feeds the boot snapshot line from the same probes", function()
		local values = Collector.collect({ shared_root = "/nowhere", script_dir = "/nowhere" }, fixture_env(MACHINE))
		helpers.assert_eq(values.os, "Fedora Linux")
		helpers.assert_eq(values.os_version, "41 kernel 6.11.4-301.fc41.x86_64")
	end)
end)

helpers.describe("healthcheck (linux): the sys payload the page renders", function()
	helpers.it("sends every Linux row the page's Linux branch reads", function()
		local previous = package.loaded["infra.diagnostic_snapshot"]
		package.loaded["infra.diagnostic_snapshot"] = {
			system_facts = function() return Collector.system_facts(fixture_env(MACHINE)) end,
			resolve_commit = function() return "f58d15798", "build" end,
		}
		local ok, result = pcall(function()
			return helpers.load_module("ui.healthcheck.bridge").on_message("ready", {})
		end)
		package.loaded["infra.diagnostic_snapshot"] = previous
		helpers.assert_true(ok, tostring(result))
		local sys = result.sys
		helpers.assert_eq(sys.os, "linux", "the page picks its Linux branch from sys.os")
		helpers.assert_eq(sys.os_name, "Fedora Linux 41 (Workstation Edition)")
		helpers.assert_eq(sys.kernel, "6.11.4-301.fc41.x86_64")
		helpers.assert_eq(sys.cpu_model, "AMD Ryzen 7 7840U")
		helpers.assert_eq(sys.cpu_cores, 2)
		helpers.assert_eq(sys.ram_total, "31.0 GB")
		helpers.assert_eq(sys.ram_free, "15.5 GB")
		helpers.assert_true(sys.display_server ~= nil, "the display server row needs its value")
		helpers.assert_true(sys.arch ~= nil and sys.arch ~= "n/a", "no placeholder in place of the architecture")
	end)
end)
