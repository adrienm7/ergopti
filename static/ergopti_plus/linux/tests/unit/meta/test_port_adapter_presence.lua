--- static/ergopti_plus/linux/tests/unit/meta/test_port_adapter_presence.lua

--- ==============================================================================
--- MODULE: Port-Adapter Presence Test (Linux driver)
--- DESCRIPTION:
--- Verifies that every one of the 9 port adapters required by the hexagonal
--- architecture has a corresponding .lua file under the linux/adapters/
--- directory. A missing adapter means a port contract exists on paper but is
--- not honoured by the Linux driver.
---
--- FEATURES & RATIONALE:
--- 1. Exhaustive list: the EXPECTED_ADAPTERS table enumerates all 9 canonical
---    adapter file names derived from the shared/ports/*.spec.js contracts.
--- 2. File-based check: we open each file with io.open to avoid depending on
---    lfs or any external library — the test runs under plain LuaJIT.
--- 3. Fail-fast reporting: each missing file is printed individually so the
---    developer knows exactly which adapters need to be created.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()
local ADAPTERS_DIR = DRIVER_ROOT .. "/adapters"


-- =====================================================
-- =====================================================
-- ======= 1/ Expected Adapter File Registry ==========
-- =====================================================
-- =====================================================

-- Canonical list of the 9 port adapters the Linux driver must implement.
-- Derived from static/ergopti_plus/shared/ports/*.spec.js via snake_case mapping.
local EXPECTED_ADAPTERS = {
	"notifier.lua",
	"timer_scheduler.lua",
	"file_system.lua",
	"window_info.lua",
	"tray_menu.lua",
	"text_sender.lua",
	"http_client.lua",
	"keyboard_hook.lua",
	"tooltip_renderer.lua",
}


-- ===================================================
-- ===================================================
-- ======= 2/ Adapter-Presence Invariant Test ========
-- ===================================================
-- ===================================================

helpers.describe("linux: port adapter presence", function()
	local missing = {}

	for _, filename in ipairs(EXPECTED_ADAPTERS) do
		local path = ADAPTERS_DIR .. "/" .. filename
		local fh   = io.open(path, "r")
		if fh then
			fh:close()
		else
			missing[#missing + 1] = filename
			print(string.format("  WARN: adapter missing — expected %s", path))
		end
	end

	helpers.it(
		string.format("all %d adapter files exist under adapters/", #EXPECTED_ADAPTERS),
		function()
			helpers.assert_true(
				#missing == 0,
				string.format("%d adapter file(s) missing: %s", #missing, table.concat(missing, ", "))
			)
		end
	)
end)
