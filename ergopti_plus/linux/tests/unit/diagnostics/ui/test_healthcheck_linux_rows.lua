--- tests/unit/diagnostics/ui/test_healthcheck_linux_rows.lua

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

local Collector = helpers.load_module("diagnostics.engine.reports.snapshot")

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
		local I18n = require("core.i18n.engine.i18n")
		I18n.init()
		local expected = I18n.get("menu.debug.healthcheck")
		helpers.assert_true(expected ~= "menu.debug.healthcheck", "the locale must be loaded")
		helpers.assert_eq(helpers.load_module("core.ui.ui.webview_manager")._app_title("healthcheck"), expected)
	end)
end)

helpers.describe("healthcheck (linux): optional modules that are off", function()
	-- The AI engine is loaded by every daemon, whether the user enabled it or
	-- not. Switched off, it must read as a neutral "disabled", never as a red
	-- failure beside the modules the daemon cannot run without; absent, it did
	-- not load, which is a failure and must not be dressed as "disabled"
	-- (developer-details).
	helpers.it("reports an AI engine the user switched off as disabled, not failed (developer-details)", function()
		local developer = helpers.load_module("diagnostics.ui.healthcheck.bridge").build_snapshot({
			engine = {}, keystats = {}, config = {},
			llm = { is_enabled = function() return false end },
		}, false).sections.developer
		helpers.assert_eq(developer.modules_failed, {})
		helpers.assert_eq(developer.modules_disabled, { "llm" })
		helpers.assert_eq(developer.modules_ok, { "engine", "keystats", "config" })
	end)

	helpers.it("counts an AI engine that is switched on as loaded (developer-details)", function()
		local developer = helpers.load_module("diagnostics.ui.healthcheck.bridge").build_snapshot({
			engine = {}, keystats = {}, config = {},
			llm = { is_enabled = function() return true end },
		}, false).sections.developer
		helpers.assert_eq(developer.modules_failed, {})
		helpers.assert_eq(developer.modules_disabled, {})
		helpers.assert_eq(developer.modules_ok, { "engine", "keystats", "config", "llm" })
	end)

	helpers.it("fails an AI engine that did not load instead of calling it disabled (developer-details)", function()
		local developer = helpers.load_module("diagnostics.ui.healthcheck.bridge").build_snapshot({
			engine = {}, keystats = {}, config = {},
		}, false).sections.developer
		helpers.assert_eq(developer.modules_failed, { "llm (not loaded)" })
		helpers.assert_eq(developer.modules_disabled, {})
	end)

	helpers.it("still fails a missing required module (developer-details)", function()
		local developer = helpers.load_module("diagnostics.ui.healthcheck.bridge").build_snapshot({
			keystats = {}, config = {}, llm = {},
		}, false).sections.developer
		helpers.assert_eq(developer.modules_failed, { "engine (not wired)" })
		helpers.assert_eq(developer.modules_disabled, {})
	end)
end)

helpers.describe("healthcheck (linux): the system rows the page renders", function()
	helpers.it("sends every Linux system and hardware value the schema declares", function()
		local previous = package.loaded["diagnostics.engine.reports.snapshot"]
		package.loaded["diagnostics.engine.reports.snapshot"] = {
			system_facts = function() return Collector.system_facts(fixture_env(MACHINE)) end,
			resolve_commit = function() return "f58d15798", "build" end,
		}
		local ok, result = pcall(function()
			return helpers.load_module("diagnostics.ui.healthcheck.bridge").build_snapshot({}, false)
		end)
		package.loaded["diagnostics.engine.reports.snapshot"] = previous
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

helpers.describe("healthcheck (linux): the daemon's own load", function()
	-- The resident memory of the daemon, which a report of a slow or leaking
	-- driver is read for (system-load)
	helpers.it("reports the daemon's resident memory from /proc/self/status (system-load)", function()
		local reader = require("core.fs.engine.regular_file_reader")
		local real_read = reader.read_source
		reader.read_source = function(path)
			if path ~= "/proc/self/status" then return real_read(path) end
			return "Name:\tluajit\nUid:\t1000\t1000\t1000\t1000\nVmRSS:\t   51200 kB\nThreads:\t3\n"
		end
		local ok, result = pcall(function()
			return helpers.load_module("diagnostics.ui.healthcheck.bridge").build_snapshot({}, false)
		end)
		reader.read_source = real_read
		helpers.assert_true(ok, tostring(result))
		helpers.assert_eq(result.sections.system.process_memory, 51200 * 1024)
		helpers.assert_eq(result.sections.system.elevated, false, "the same file answers the elevation")
	end)
end)

helpers.describe("healthcheck (linux): the features the page lists", function()
	--- The features section of a snapshot, as an id → enabled map.
	--- @param state table Daemon state.
	--- @return table
	local function features_of(state)
		local items = helpers.load_module("diagnostics.ui.healthcheck.bridge").build_snapshot(state, false).sections.features.items
		local by_id = {}
		for _, item in ipairs(items) do by_id[item.id] = item.enabled end
		return by_id, #items
	end

	--- A hotstrings configuration whose named groups are on.
	--- @param on table Set of the enabled group names.
	--- @return table
	local function hotstrings_config(on)
		return {
			get_groups = function() return { "base", "emoji", "symbols" } end,
			is_group_enabled = function(name) return on[name] == true end,
		}
	end

	-- The daemon runs hotstrings, shortcuts and gestures, and the page listed
	-- none of them: a report saying "gestures off" on macOS said nothing at all
	-- on Linux (features-parity)
	helpers.it("lists hotstrings, shortcuts and gestures with their switches (features-parity)", function()
		local features, count = features_of({
			config    = hotstrings_config({ emoji = true }),
			shortcuts = { is_enabled = function() return true end },
			gestures  = { is_enabled = function() return false end },
			llm       = { is_enabled = function() return false end },
			keystats = { is_enabled = function() return true end },
		})
		helpers.assert_eq(features.hotstrings, true, "one enabled group is hotstrings on")
		helpers.assert_eq(features.shortcuts, true)
		helpers.assert_eq(features.gestures, false)
		helpers.assert_eq(features.llm, false)
		helpers.assert_eq(features.metrics, true)
		helpers.assert_true(count >= 5, "five switches at least, got " .. tostring(count))
	end)

	helpers.it("reads hotstrings as off when every group is off (features-parity)", function()
		local features = features_of({ config = hotstrings_config({}) })
		helpers.assert_eq(features.hotstrings, false)
	end)

	-- Arch field report of 2026-11-25: config.toml had the tap-holds off and
	-- no key, the runtime switch stayed on, and the page read « Tap-Holds: on ».
	for _, case in ipairs({ { feature = false, runtime = true }, { feature = true, runtime = true } }) do
		helpers.it("reports the tap-hold feature state the tray shows, feature=" .. tostring(case.feature), function()
			local name = "platform.remap.tap_hold_manager"
			local previous = package.loaded[name]
			package.loaded[name] = {
				is_enabled = function() return case.runtime end,
				is_active = function() return true end,
				feature_enabled = function() return case.feature end,
			}
			local ok, features = pcall(features_of, { config = hotstrings_config({ base = true }) })
			package.loaded[name] = previous
			helpers.assert_true(ok, tostring(features))
			helpers.assert_eq(features.tapholds, case.feature,
				"the runtime switch alone, or an engine running for key combinations, is not the feature")
		end)
	end

	helpers.it("leaves out a feature whose module the daemon does not run (features-parity)", function()
		local features = features_of({ config = hotstrings_config({ base = true }) })
		helpers.assert_nil(features.shortcuts, "no shortcuts module: no row, rather than a guessed off")
		helpers.assert_nil(features.gestures)
	end)
end)

helpers.describe("healthcheck (linux): the features this driver lacks", function()
	-- macOS alone published the manifest-derived `unavailable` section, so a
	-- Linux user could not ask the page why a documented feature is missing.
	helpers.it("lists every Linux absence of the generated manifest with its reason", function()
		local unavailable = helpers.load_module("diagnostics.ui.healthcheck.bridge").build_snapshot({
			engine = {}, keystats = {}, config = {}, llm = {},
		}, false).sections.unavailable
		local explained, silent = require("menu.engine.manifest_reader").coverage_gaps()
		helpers.assert_true(type(unavailable) == "table" and type(unavailable.items) == "table",
			"the snapshot carries the section")
		helpers.assert_eq(#unavailable.items, #explained + #silent, "every absence, explained or not")
		helpers.assert_true(#explained > 0, "the Linux manifest explains some absences")
		local by_feature = {}
		for _, item in ipairs(unavailable.items) do by_feature[item.feature] = item end
		for _, gap in ipairs(explained) do
			local item = by_feature[gap.path]
			helpers.assert_true(item ~= nil, "listed: " .. tostring(gap.path))
			helpers.assert_eq(item.reason, gap.reason_key)
			helpers.assert_true(not item.platforms:find("Linux", 1, true), "Linux never offers what it lacks")
		end
		local schema = require("diagnostics.ui.healthcheck.bridge").config().schema
		for _, section in ipairs(schema.sections) do
			if section.id == "unavailable" then
				helpers.assert_true(table.concat(section.platforms, ","):find("linux", 1, true) ~= nil,
					"the page renders the section on Linux")
			end
		end
	end)
end)

helpers.describe("healthcheck (linux): the engine and text automation rows", function()
	-- Field report, Arch Linux, KDE Plasma Wayland, 2026-11-25: "Remapping
	-- engine: unknown" while the emulation ran, "running for: 0 s" after
	-- minutes, and no row said why every hotstring was withheld.

	--- Builds one snapshot with the keyboard hook and the text status doubled.
	--- @param hook table { running, recovering }
	--- @param paused boolean
	--- @return table input, table system
	local function rows(hook, paused)
		local Hook = require("platform.input.keyboard_hook")
		local saved_running, saved_recovering = Hook.isRunning, Hook.isRecovering
		Hook.isRunning = function() return hook.running end
		Hook.isRecovering = function() return hook.recovering == true end
		local ok, result = pcall(function()
			return helpers.load_module("diagnostics.ui.healthcheck.bridge").build_snapshot(
				{ is_paused = function() return paused end }, false)
		end)
		Hook.isRunning, Hook.isRecovering = saved_running, saved_recovering
		helpers.assert_true(ok, tostring(result))
		return result.sections.input, result.sections.system
	end

	helpers.it("(text-automation-visible) names the keyboard engine's real state", function()
		helpers.assert_eq(rows({ running = true }, false).remap_phase, "active")
		helpers.assert_eq(rows({ running = true }, true).remap_phase, "paused")
		helpers.assert_eq(rows({ running = false }, false).remap_phase, "idle")
		helpers.assert_eq(rows({ running = false, recovering = true }, false).remap_phase, "recovering")
	end)

	helpers.it("(text-automation-visible) states whether hotstrings may act, and why", function()
		local Status = require("platform.focus.text_automation_status")
		Status._reset_for_test()
		Status.bind(function() return { mode = "window", reason = "no_accessible_window" } end)
		local input = rows({ running = true }, false)
		Status._reset_for_test()
		helpers.assert_eq(input.text_automation, "open")
		helpers.assert_eq(input.text_automation_reason, "no_accessible_window")
	end)

	helpers.it("(text-automation-visible) counts the daemon's uptime from its boot clock", function()
		local BootProfiler = require("core.logger.engine.boot_profiler")
		local saved = BootProfiler.uptime_ms
		BootProfiler.uptime_ms = function() return 125400 end
		local _, system = rows({ running = true }, false)
		BootProfiler.uptime_ms = saved
		helpers.assert_eq(system.uptime, 125, "not the time since the page's module loaded")
	end)
end)
