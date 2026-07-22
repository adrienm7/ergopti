--- tests/unit/ui/menu/menu_llm/test_ollama_manager_nonblocking.lua

--- Regression test for M-15: Ollama model-manager menu actions must not
--- block the Hammerspoon run loop.
---
--- Three call sites were synchronous:
--- 1. ensure_ollama_running — curl without a timeout cap could hang indefinitely
---    when the Ollama server was unreachable.
--- 2. check_requirements — ollama list was run with hs.execute (blocking).
--- 3. delete_model — ollama rm was run with hs.execute (blocking).
---
--- Fixes:
--- 1. Both curl invocations now pass --max-time 5 to cap the blocking window.
--- 2. check_requirements uses hs.task.new (non-blocking) for ollama list.
--- 3. delete_model uses hs.task.new (non-blocking) for ollama rm.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/menu/menu_llm/models_manager_ollama.lua"
local fh = io.open(src_path, "r")
if not fh then error("models_manager_ollama.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: curl calls in ensure_ollama_running must include --max-time 5.
helpers.assert_true(
	src:find("--max-time 5", 1, true) ~= nil,
	"ensure_ollama_running curl calls must include --max-time 5 to cap the blocking window"
)

-- Test 2: check_requirements must NOT use hs.execute for ollama list.
-- The only remaining hs.execute calls are for curl and command -v; they
-- must not appear immediately before the string "list" (which was the old
-- blocking pattern `hs.execute, bin .. " list"`).
helpers.assert_true(
	src:find('hs%.execute.*" list', 1, false) == nil,
	"check_requirements must not call hs.execute for 'ollama list' — use hs.task.new instead"
)

-- Test 3: delete_model must NOT use hs.execute for ollama rm.
helpers.assert_true(
	src:find('hs%.execute.*" rm ', 1, false) == nil,
	"delete_model must not call hs.execute for 'ollama rm' — use hs.task.new instead"
)

-- Test 4: both check_requirements and delete_model must use hs.task.new.
-- The file already had one hs.task for refresh_installed_async; after the
-- fix there must be at least three hs.task.new calls (list-refresh, list-check,
-- and rm).
local count = 0
for _ in src:gmatch("hs%.task%.new") do count = count + 1 end
helpers.assert_true(
	count >= 3,
	string.format(
		"models_manager_ollama.lua must have at least 3 hs.task.new calls after the fix; found %d",
		count
	)
)

print("[PASS] test_ollama_manager_nonblocking")
