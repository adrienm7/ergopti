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
--- The fix: no readiness shell operation runs on the Lua thread. ShellRunner
--- owns curl/restart processes and TimerScheduler owns every retry boundary;
--- merely moving a blocking call into hs.timer.doAfter would still freeze the
--- same Hammerspoon runloop.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end


-- ======================================================================
-- ======================================================================
-- ======= 1/ hs.timer.usleep must not appear in models_manager ===========
-- ======================================================================
-- ======================================================================

helpers.describe("ui/menu/menu_llm/models_manager_ollama.lua: no usleep (ollama-usleep-main-thread-freeze)", function()

	helpers.it("hs.timer.usleep is absent from models_manager_ollama.lua", function()
		local src = read_source("local function get_ollama_path") -- ui/menu/menu_llm/models_manager_ollama.lua
		helpers.assert_true(
			src:find("hs%.timer%.usleep") == nil,
			"models_manager_ollama.lua must NOT call hs.timer.usleep — it blocks the main thread and can kill eventtap hooks (ollama-usleep-main-thread-freeze)")
	end)

	helpers.it("readiness polling owns async tasks and retained timers", function()
		local src = read_source("local function get_ollama_path") -- ui/menu/menu_llm/models_manager_ollama.lua
		helpers.assert_true(
			src:find("ShellRunner%.spawn") ~= nil
				and src:find("TimerScheduler%.after") ~= nil,
			"Ollama readiness must own subprocess and retry capabilities through async adapters")
		helpers.assert_true(
			src:find("pcall%(hs%.execute") == nil and src:find("hs%.execute%(") == nil,
			"bounded hs.execute still blocks the Hammerspoon runloop and is forbidden")
	end)

end)
