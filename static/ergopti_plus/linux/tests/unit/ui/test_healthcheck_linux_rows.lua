--- tests/unit/ui/test_healthcheck_linux_rows.lua

--- ==============================================================================
--- MODULE: The Linux Healthcheck Describes The Machine (Linux)
--- DESCRIPTION:
--- The Linux snapshot once carried only os, arch and the display kind, so the
--- shared page printed "?" in every CPU, RAM, screen and locale row and had no
--- row naming the distribution or the kernel. The version 2 snapshot reports
--- the facts the boot snapshot line already probes (one probe set for both),
--- sizes in bytes the page formats, and a fact that cannot be read stays absent
--- so the page shows it as unknown. tools/test/test-diagnostic-ui-integrity.cjs
--- renders the page side.
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
		helpers.assert_eq(facts.ram_total, 32505856 * 1024)
		helpers.assert_eq(facts.ram_free, 16252928 * 1024)
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

helpers.describe("healthcheck (linux): the window title", function()
	-- macOS and Windows title the window with menu.debug.healthcheck; Linux
	-- hardcoded "Diagnostic", in English, whatever the user's language
	-- (diagnostics-window-name).
	helpers.it("uses the menu row's translated name (diagnostics-window-name)", function()
		local I18n = require("infra.i18n")
		I18n.init()
		local expected = I18n.get("menu.debug.healthcheck")
		helpers.assert_true(expected ~= "menu.debug.healthcheck", "the locale must be loaded")
		helpers.assert_eq(helpers.load_module("ui.webview_manager")._app_title("healthcheck"), expected)
	end)
end)

helpers.describe("healthcheck (linux): optional modules that are off", function()
	-- The AI engine is loaded by every daemon, whether the user enabled it or
	-- not. Switched off, it must read as a neutral "disabled", never as a red
	-- failure beside the modules the daemon cannot run without; absent, it did
	-- not load, which is a failure and must not be dressed as "disabled"
	-- (developer-details).
	helpers.it("reports an AI engine the user switched off as disabled, not failed (developer-details)", function()
		local developer = helpers.load_module("ui.healthcheck.bridge").build_snapshot({
			engine = {}, keylogger = {}, config = {},
			llm = { is_enabled = function() return false end },
		}, false).sections.developer
		helpers.assert_eq(developer.modules_failed, {})
		helpers.assert_eq(developer.modules_disabled, { "llm" })
		helpers.assert_eq(developer.modules_ok, { "engine", "keylogger", "config" })
	end)

	helpers.it("counts an AI engine that is switched on as loaded (developer-details)", function()
		local developer = helpers.load_module("ui.healthcheck.bridge").build_snapshot({
			engine = {}, keylogger = {}, config = {},
			llm = { is_enabled = function() return true end },
		}, false).sections.developer
		helpers.assert_eq(developer.modules_failed, {})
		helpers.assert_eq(developer.modules_disabled, {})
		helpers.assert_eq(developer.modules_ok, { "engine", "keylogger", "config", "llm" })
	end)

	helpers.it("fails an AI engine that did not load instead of calling it disabled (developer-details)", function()
		local developer = helpers.load_module("ui.healthcheck.bridge").build_snapshot({
			engine = {}, keylogger = {}, config = {},
		}, false).sections.developer
		helpers.assert_eq(developer.modules_failed, { "llm (not loaded)" })
		helpers.assert_eq(developer.modules_disabled, {})
	end)

	helpers.it("still fails a missing required module (developer-details)", function()
		local developer = helpers.load_module("ui.healthcheck.bridge").build_snapshot({
			keylogger = {}, config = {}, llm = {},
		}, false).sections.developer
		helpers.assert_eq(developer.modules_failed, { "engine (not wired)" })
		helpers.assert_eq(developer.modules_disabled, {})
	end)
end)

helpers.describe("healthcheck (linux): the system rows the page renders", function()
	helpers.it("sends every Linux system and hardware value the schema declares", function()
		local previous = package.loaded["infra.diagnostic_snapshot"]
		package.loaded["infra.diagnostic_snapshot"] = {
			system_facts = function() return Collector.system_facts(fixture_env(MACHINE)) end,
			resolve_commit = function() return "f58d15798", "build" end,
		}
		local ok, result = pcall(function()
			return helpers.load_module("ui.healthcheck.bridge").build_snapshot({}, false)
		end)
		package.loaded["infra.diagnostic_snapshot"] = previous
		helpers.assert_true(ok, tostring(result))
		local system, hardware = result.sections.system, result.sections.hardware
		helpers.assert_eq(result.driver, "linux")
		helpers.assert_eq(system.os, "Fedora Linux 41 (Workstation Edition)")
		helpers.assert_eq(system.kernel, "6.11.4-301.fc41.x86_64")
		helpers.assert_eq(hardware.cpu, "AMD Ryzen 7 7840U")
		helpers.assert_eq(hardware.cpu_cores, 2)
		helpers.assert_eq(hardware.ram_total, 32505856 * 1024)
		helpers.assert_eq(system.ram_free, 16252928 * 1024)
		helpers.assert_true(system.display_server ~= nil, "the display server row needs its value")
		helpers.assert_true(hardware.arch ~= nil and hardware.arch ~= "n/a", "no placeholder in place of the architecture")
		helpers.assert_eq(result.sections.versions.commit, "f58d15798 (build)")
	end)
end)
