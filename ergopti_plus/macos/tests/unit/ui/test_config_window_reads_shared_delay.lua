--- tests/unit/ui/test_config_window_reads_shared_delay.lua

--- ==============================================================================
--- MODULE: Regression — the config window must not mirror the shared delay
--- DESCRIPTION:
--- ui/hotstrings_config_window carried `GLOBAL_DEFAULT_DELAY_MS = 750` with a
--- comment saying it and hotstrings_config "must stay in sync". A hand-mirrored
--- constant with a note asking humans to keep it aligned IS the second source,
--- and it is the one that silently stops matching when the canon moves — the
--- canon here being the shared TOML the AutoHotkey driver reads too.
---
--- ROOT CAUSE ENCODED:
--- Project rule 5.2: a default lives in exactly one place and everyone else
--- reads it. The assertion is on the VALUE agreeing at runtime, so a future
--- change to the shared file has to move both or fail here.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("hotstrings config window: the default delay comes from the canon", function()

	helpers.it("hotstrings_config publishes the shared value", function()
		package.loaded["modules.hotstrings.hotstrings_config"] = nil
		local cfg = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
		helpers.assert_type(cfg.get_global_default_delay_ms, "function",
			"the owning module must publish the value, or every consumer has to mirror it")
	end)

	helpers.it("the window no longer declares its own authoritative copy", function()
		local src = helpers.read_driver_source("global_default_delay_ms")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the config window source must be readable or this asserts nothing")
		local code = src:gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find("GLOBAL_DEFAULT_DELAY_MS%s*=%s*750") == nil,
			"a mirrored constant asking humans to keep it in sync is the second source; the "
			.. "remaining literal must be reachable only as a fallback")
	end)

end)
