--- tests/unit/meta/test_port_adapter_presence.lua

--- ==============================================================================
--- MODULE: Port Adapters — Every One Present Is Real
--- DESCRIPTION:
--- This file used to assert the opposite invariant: that a hardcoded list of
--- nine port names each had a file under adapters/. That reading of ADR-001 —
--- "adding a new driver requires only implementing the twenty port adapters" —
--- is what produced nine Linux adapters with no production caller: 1 549 lines
--- written to satisfy a checklist, every one of them passing the presence check
--- and the compliance check while no code path reached it.
---
--- ADR-008 supersedes that clause. A port is a CONTRACT for drivers that need
--- the capability, not a checklist every driver must complete. The nine were
--- deleted; what remains is the invariant worth holding, which is the other
--- direction:
---
---   every adapter this driver SHIPS must be loadable, and must be required by
---   something outside adapters/.
---
--- That is the check the old one could not make. A missing file is loud — the
--- require fails at boot and the daemon says so. An adapter that exists and
--- nobody calls is silent, and silence was the whole defect.
---
--- Reachability across all three drivers is ratcheted by
--- tools/test/test-adapter-reachability.cjs; this is the Linux-side runtime half,
--- because a file can be required by name and still fail to load.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT   = helpers.driver_root()
local ADAPTERS_DIR  = DRIVER_ROOT .. "/adapters"




-- ===================================================
-- ===================================================
-- ======= 1/ Enumerate what the driver ships ========
-- ===================================================
-- ===================================================

--- Lists the adapter module names present on disk.
--- Derived from the filesystem, never from a hardcoded list: the list is what
--- went stale last time — it named nine adapters while the driver had far more,
--- so a new adapter joined without anything noticing.
--- @return table Array of module names, e.g. "adapters.file_system".
local function adapter_modules()
	local names, seen = {}, {}

	--- Reads one listing command and folds its .lua entries in.
	--- @param cmd string Shell command whose stdout is one filename per line.
	local function absorb(cmd)
		local pipe = io.popen(cmd)
		if not pipe then return end
		for line in pipe:lines() do
			-- Both listings can emit a full path; take the basename either way.
			-- Two separate classes rather than one holding both separators: the
			-- backslash needs escaping inside a Lua pattern, and an escape that a
			-- rewriting tool does not preserve byte for byte yields a pattern that
			-- still compiles and matches the wrong thing.
			local base = line:match("([^/]+)$") or line
			base = base:match("([^\\]+)$") or base
			local stem = base:match("^([%w_]+)%.lua%s*$")
			if stem and not seen[stem] then
				seen[stem] = true
				names[#names + 1] = "adapters." .. stem
			end
		end
		pipe:close()
	end

	-- POSIX first; the suite also runs on a Windows dev box, where `ls` is absent
	-- or cannot read the drive-letter path. Trying both beats making the test
	-- Linux-only, which would mean it never runs where it is written.
	absorb(string.format("ls -1 %q 2>/dev/null", ADAPTERS_DIR))
	if #names == 0 then
		absorb(string.format('dir /b "%s" 2>nul', (ADAPTERS_DIR:gsub("/", "\\"))))
	end
	table.sort(names)
	return names
end

local MODULES = adapter_modules()




-- ===================================================
-- ===================================================
-- ======= 2/ Every one of them loads ================
-- ===================================================
-- ===================================================

helpers.describe("port adapters: every shipped adapter is real", function()

	helpers.it("the enumeration found adapters at all", function()
		-- A scan that finds nothing passes every assertion below for free.
		helpers.assert_true(#MODULES >= 10, string.format(
			"found only %d adapter(s) under %s — the scan is broken, and a check over an "
				.. "empty set is not a check", #MODULES, ADAPTERS_DIR))
	end)

	for _, mod in ipairs(MODULES) do
		helpers.it(mod .. " loads", function()
			local ok, err = pcall(require, mod)
			helpers.assert_true(ok and type(package.loaded[mod]) == "table", string.format(
				"%s is shipped but does not load: %s. An adapter that fails to require "
					.. "takes the daemon down at boot, or — worse — is pcall'd by its caller "
					.. "and silently disables one feature.", mod, tostring(err)))
		end)
	end

end)
