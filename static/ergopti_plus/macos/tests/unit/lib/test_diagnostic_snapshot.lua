--- tests/unit/lib/test_diagnostic_snapshot.lua

--- ==============================================================================
--- MODULE: Diagnostic snapshot and runtime diagnostics (macOS)
--- DESCRIPTION:
--- The macOS half of the cross-driver boot snapshot contract, plus the runtime
--- events that used to be invisible:
--- 1. The collector emits exactly one INFO line carrying every shared field,
---    once per Lua state, from a post-boot site outside init.lua.
--- 2. The boot total is frozen at init.lua's "Boot complete" mark.
--- 3. Reload requests name their reason; file-triggered reloads name the files;
---    webview open, load and close are timed; a failed notify/prime is logged.
--- 4. Privacy: no home directory, command line or typed text in these lines.
--- ==============================================================================

local helpers = require("tests.helpers")

local json     = require("json")
local Logger   = require("infra.logger")
local Snapshot = require("diagnostics.snapshot")

local Paths    = require("infra.paths")

--- The one production file containing `symbol`. Keyed by content, never by
--- path, so the assertions survive a file move.
--- @param symbol string
--- @return string
local function unit_with(symbol)
	local body, err = helpers.read_driver_unit(symbol)
	helpers.assert_true(body ~= nil, tostring(err))
	return body
end

--- Reads the shared snapshot contract.
--- @return table
local function read_contract()
	local path = assert(Paths.shared("modules/logger/diagnostic_snapshot.json"), "shared tree unreachable")
	local fh = assert(io.open(path, "r"))
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw))
end

--- Runs body with a capturing sink at DEBUG and returns the lines.
--- @param body function
--- @return table
local function capture(body)
	local lines = {}
	local previous = Logger.current_level
	Logger.set_level("DEBUG")
	Logger.set_sink(function(line) lines[#lines + 1] = tostring(line) end)
	local ok, err = pcall(body)
	Logger.set_sink(nil)
	Logger.current_level = previous
	if not ok then error(err, 0) end
	return lines
end

-- A complete probe table: every adapter answer is fixed so the line is exact.
local FAKE_SYSTEM = {
	os_version        = function() return "Version 15.5 (Build 24F74)" end,
	runtime_version   = function() return "1.0.0" end,
	arch              = function() return "arm64" end,
	monitor_count     = function() return 2 end,
	main_screen_scale = function() return 2 end,
	keyboard_layout   = function() return "com.apple.keylayout.French" end,
	elevated          = function() return "false" end,
	home              = function() return "/Users/alice" end,
}




-- =====================================
-- =====================================
-- ======= 1/ Snapshot contract ========
-- =====================================
-- =====================================

helpers.describe("Diagnostic snapshot: macOS collector", function()
	local contract = read_contract()
	local Collector = require("infra.diagnostic_snapshot")

	helpers.it("the shared vectors render byte for byte on the macOS path", function()
		helpers.assert_true(#contract.vectors >= 3, "the vectors must load")
		for _, vector in ipairs(contract.vectors) do
			helpers.assert_eq(vector.expected, Snapshot.format(vector.values), vector.id)
		end
	end)

	helpers.it("emits one INFO line with every shared field, once per session", function()
		Collector._reset_for_test()
		local ctx = {
			version = "3.1.0", boot_ms = 950.2, locale = "fr",
			config_dir = "/Users/alice/Library/Ergopti",
			state = { gestures = true, llm = false, hotstrings = { a = true, b = false } },
			git_fs = { read = function() return nil end, exists = function() return false end },
		}
		local first, second
		local lines = capture(function()
			first = Collector.emit_once(ctx, FAKE_SYSTEM)
			second = Collector.emit_once(ctx, FAKE_SYSTEM)
		end)
		helpers.assert_true(type(first) == "string", "the first call logs")
		helpers.assert_eq(nil, second, "a second call in the same Lua state is refused")
		local found = {}
		for _, line in ipairs(lines) do
			if line:find("[" .. contract.module .. "]", 1, true) then found[#found + 1] = line end
		end
		helpers.assert_eq(1, #found, "exactly one snapshot line")
		helpers.assert_true(found[1]:find("[INFO]", 1, true) ~= nil, found[1])
		for _, name in ipairs(contract.fields) do
			helpers.assert_true(found[1]:find(name .. "=", 1, true) ~= nil,
				"field '" .. name .. "' missing: " .. found[1])
		end
		helpers.assert_true(found[1]:find("features_enabled=2/4", 1, true) ~= nil, found[1])
		helpers.assert_true(found[1]:find("config_dir=~/Library/Ergopti", 1, true) ~= nil, found[1])
		helpers.assert_eq(nil, found[1]:find("alice", 1, true), "the account name must not be logged")
		Collector._reset_for_test()
	end)

	helpers.it("is emitted after boot from the menu prime, not from init.lua", function()
		local menu = unit_with("DiagnosticSnapshot.emit_once(")
		local prime = menu:find("_menu_primed = true", 1, true)
		local emit = menu:find("DiagnosticSnapshot.emit_once(", 1, true)
		helpers.assert_true(prime ~= nil and emit ~= nil and prime < emit,
			"the snapshot follows the one-shot menu prime that runs after boot")
		helpers.assert_true(menu:find("BootProfiler.boot_complete_ms()", 1, true) ~= nil,
			"it reports the boot total frozen at the Boot complete mark")
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ Boot total ===============
-- =====================================
-- =====================================

helpers.describe("Boot profiler: the Boot complete mark freezes the total", function()
	helpers.it("init.lua still closes boot with the label the profiler watches", function()
		local BootProfiler = require("infra.boot_profiler")
		local init = unit_with('Boot.mark("' .. BootProfiler.BOOT_COMPLETE_LABEL)
		helpers.assert_true(init:find('Boot.mark("' .. BootProfiler.BOOT_COMPLETE_LABEL, 1, true) ~= nil,
			"renaming the final mark would silently turn boot_ms into unknown")
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ Runtime events ===========
-- =====================================
-- =====================================

helpers.describe("Runtime diagnostics: previously invisible events now log", function()
	helpers.it("a controlled reload or exit logs its reason", function()
		local src = unit_with("Controlled %s requested (reason: %s).")
		helpers.assert_true(src:find('"Controlled %s requested (reason: %s)."', 1, true) ~= nil)
	end)

	helpers.it("a file-triggered reload names the changed files and a failed toast is logged", function()
		local src = unit_with("RuntimeLog.describe_paths(burst_paths)")
		helpers.assert_true(src:find("RuntimeLog.describe_paths(burst_paths)", 1, true) ~= nil)
		helpers.assert_true(src:find("Reload notification failed", 1, true) ~= nil)
	end)

	helpers.it("the webview factory times open, first load and close", function()
		local src = unit_with("page loaded in %.0f ms")
		for _, needle in ipairs({ "opened in %.0f ms", "page loaded in %.0f ms",
				"closed after %.1f s open", "i18n injection failed" }) do
			helpers.assert_true(src:find(needle, 1, true) ~= nil, needle)
		end
	end)

	helpers.it("menu feature toggles and menu prime failures are logged", function()
		local src = unit_with("Feature toggled from the menu")
		helpers.assert_true(src:find("Feature toggled from the menu", 1, true) ~= nil)
		helpers.assert_true(src:find("Menu cache prime '%s' failed", 1, true) ~= nil)
		helpers.assert_eq(nil, src:find("pcall(menu_mods.apps.prime, ctx)", 1, true),
			"the bare pcall that discarded a prime failure is gone")
	end)

	helpers.it("a settled pause or resume is logged", function()
		local src = unit_with("transaction settled (driver is now %s)")
		helpers.assert_true(src:find("transaction settled (driver is now %s)", 1, true) ~= nil)
	end)

	helpers.it("a process exit is logged by program name only", function()
		local RuntimeLog = require("diagnostics.runtime_log")
		helpers.assert_eq("osascript",
			RuntimeLog.program_name("/usr/bin/osascript -e 'set the clipboard to \"secret\"'"))
		local src = unit_with("_record_exit(RuntimeLog.program_name(executable)")
		helpers.assert_true(src:find("_record_exit(RuntimeLog.program_name(executable)", 1, true) ~= nil)
	end)
end)
