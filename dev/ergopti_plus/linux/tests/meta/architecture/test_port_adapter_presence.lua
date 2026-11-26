--- tests/meta/architecture/test_port_adapter_presence.lua

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

local DRIVER_ROOT   = (helpers.driver_root():gsub("[/\\]$", ""))




-- ===================================================
-- ===================================================
-- ======= 1/ Enumerate what the driver ships ========
-- ===================================================
-- ===================================================

--- Lists the adapter module names present on disk: every Lua file directly
--- inside a folder named adapters/, wherever the feature tree puts it
--- (adapters/, clipboard/adapters/, core/fs/adapters/ …), tests excluded.
--- Derived from the filesystem, never from a hardcoded list: the list is what
--- went stale last time — it named nine adapters while the driver had far more,
--- so a new adapter joined without anything noticing. Scanning only the
--- driver's top adapters/ folder went stale the same way once the structure
--- plan moved adapters into their features' folders. A file there that is
--- run as a script (its last statement is not `return <module>`, such as the
--- network probes the daemon starts with arguments) is not a module and is
--- left to its own runtime tests.
--- @return table Array of module names, e.g. "core.fs.adapters.file_system".
local function adapter_modules()
	local paths, detail = require("tests.lua.core.runner_discovery").files(DRIVER_ROOT, function(name)
		return name:match("%.lua$") ~= nil
	end, { tests = true })
	assert(paths, detail)
	local names = {}
	for _, path in ipairs(paths) do
		local relative = path:sub(#DRIVER_ROOT + 2):gsub("\\", "/")
		local folder, stem = relative:match("^(.-)/?([%w_]+)%.lua$")
		if folder == "adapters" or (folder and folder:match("/adapters$")) then
			local last = nil
			for line in io.lines(path) do
				if line:match("%S") and not line:match("^%s*%-%-") then last = line end
			end
			if last and last:match("^return%s+[%w_]+%s*$") then
				names[#names + 1] = (folder .. "/" .. stem):gsub("/", ".")
			end
		end
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
			"found only %d adapter(s) in the adapters/ folders under %s — the scan is broken, "
				.. "and a check over an empty set is not a check", #MODULES, DRIVER_ROOT))
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
