--- tests/meta/test_ollama_no_usleep.lua

--- ==============================================================================
--- MODULE: Ollama No usleep Meta Test
--- DESCRIPTION:
--- Static source guard for the "ollama-usleep-main-thread-freeze" audit finding
--- in ui/menu/menu_llm/models_manager_ollama.lua.
---
--- ROOT CAUSE ENCODED:
--- A synchronous polling loop called hs.timer.usleep(200 * 1000) up to 20 times
--- to wait for the Ollama API to become ready. Lua runs on Hammerspoon's main
--- thread — any usleep call blocks the entire event loop, freezing the UI and
--- suspending all hs.eventtap callbacks (keylogger, hotstrings). A suspension
--- longer than macOS's watchdog threshold permanently disables the input tap,
--- breaking the keylogger until the next full Hammerspoon reload.
---
--- The fix: the blocking function (wait_for_ollama_api) was dead code and has
--- been removed. The production polling path (ensure_ollama_running) already
--- uses hs.timer.doAfter for fully async polling with no usleep.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

local function read_source(rel)
	local fh = io.open(DRIVER_ROOT .. rel, "r")
	assert(fh, "cannot open " .. rel)
	local src = fh:read("*a")
	fh:close()
	return src
end


-- ======================================================================
-- ======================================================================
-- ======= 1/ hs.timer.usleep must not appear in models_manager ===========
-- ======================================================================
-- ======================================================================

helpers.describe("ui/menu/menu_llm/models_manager_ollama.lua: no usleep (ollama-usleep-main-thread-freeze)", function()

	helpers.it("hs.timer.usleep is absent from models_manager_ollama.lua", function()
		local src = read_source("ui/menu/menu_llm/models_manager_ollama.lua")
		helpers.assert_true(
			src:find("hs%.timer%.usleep") == nil,
			"models_manager_ollama.lua must NOT call hs.timer.usleep — it blocks the main thread and can kill eventtap hooks (ollama-usleep-main-thread-freeze)")
	end)

	helpers.it("async polling uses hs.timer.doAfter, not a blocking loop", function()
		local src = read_source("ui/menu/menu_llm/models_manager_ollama.lua")
		helpers.assert_true(
			src:find("hs%.timer%.doAfter") ~= nil,
			"models_manager_ollama.lua must use hs.timer.doAfter for async Ollama readiness polling (ollama-usleep-main-thread-freeze)")
	end)

end)
