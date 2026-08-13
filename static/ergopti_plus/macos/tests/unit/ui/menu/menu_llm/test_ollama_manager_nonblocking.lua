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
--- 2. check_requirements uses TaskLifecycle.native (non-blocking) for ollama list.
--- 3. delete_model uses TaskLifecycle.native (non-blocking) for ollama rm.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to ui/menu/menu_llm/models_manager_ollama.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function get_ollama_path")
helpers.assert_true(src ~= nil, "ui/menu/menu_llm/models_manager_ollama.lua source must be locatable")

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
	"check_requirements must not call hs.execute for 'ollama list' — use TaskLifecycle.native instead"
)

-- Test 3: delete_model must NOT use hs.execute for ollama rm.
helpers.assert_true(
	src:find('hs%.execute.*" rm ', 1, false) == nil,
	"delete_model must not call hs.execute for 'ollama rm' — use TaskLifecycle.native instead"
)

-- Test 4: all model operations must use the guarded native-task adapter.
local count = 0
for _ in src:gmatch("TaskLifecycle%.native") do count = count + 1 end
helpers.assert_true(
	count >= 4,
	string.format(
		"models_manager_ollama.lua must have at least 4 guarded native task launches; found %d",
		count
	)
)

print("[PASS] test_ollama_manager_nonblocking")
