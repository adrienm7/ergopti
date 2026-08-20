--- tests/unit/ui/menu/menu_llm/test_mlx_manager_delete_nonblocking.lua

--- ==============================================================================
--- MODULE: Regression — MLX model-manager delete_model must not block (F-HIGH-19)
--- DESCRIPTION:
--- obj.delete_model() in models_manager_mlx.lua deleted a multi-GB model-cache
--- directory via a synchronous os.execute("rm -rf " .. path) on the menu-click
--- handler's thread — Hammerspoon's single main run loop. A large model cache
--- delete could freeze keystrokes, timers, and the menubar for the whole
--- deletion. The sibling Ollama manager (models_manager_ollama.lua) was already
--- fixed for the identical bug class across its own hs.execute call sites
--- (see test_ollama_manager_nonblocking.lua); this MLX twin was never brought
--- in line.
---
--- Fix: delete_model now spawns /bin/rm -rf via TaskLifecycle.native (async), with the
--- task forward-declared per the closure-before-local convention and pinned
--- in M._active_tasks so Hammerspoon's GC cannot SIGTERM it mid-delete.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Selected by a declaration unique to ui/menu/menu_llm/models_manager_mlx.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("\"Cause inconnue. Consultez la console Hammerspoon.\"")
helpers.assert_true(src ~= nil, "ui/menu/menu_llm/models_manager_mlx.lua source must be locatable")

-- Scope every check to the delete_model FUNCTION BODY only (up to the next
-- top-level `function obj.` or `return obj`), not the whole file — the fix's
-- own docstring legitimately mentions the old os.execute("rm -rf ...") pattern
-- in prose, which would otherwise false-positive test 1 below.
local delete_fn_start = src:find("function obj%.delete_model", 1, false)
helpers.assert_true(delete_fn_start ~= nil, "obj.delete_model must be defined")

local body_end = src:find("\n\treturn obj", delete_fn_start, true)
	or src:find("\n\tfunction obj%.", delete_fn_start + 1, false)
	or #src
local delete_fn_body = src:sub(delete_fn_start, body_end)

-- Test 1: the old blocking pattern must be gone entirely from delete_model's body.
helpers.assert_true(
	delete_fn_body:find('os%.execute%("rm %-rf', 1, false) == nil,
	'delete_model must not call os.execute("rm -rf ...") — it blocks the Hammerspoon run loop'
)

-- Test 2: delete_model must dispatch the delete via TaskLifecycle.native with -rf args,
-- mirroring the Ollama manager's async fix.
helpers.assert_true(
	delete_fn_body:find("TaskLifecycle%.native", 1, false) ~= nil,
	"delete_model must use TaskLifecycle.native for the async rm -rf"
)
helpers.assert_true(
	delete_fn_body:find('"%-rf"', 1, false) ~= nil,
	'delete_model\'s TaskLifecycle.native call must pass "-rf" as a task argument'
)

-- Test 3: the spawned task must be GC-root pinned (M._active_tasks), matching
-- the canonical pattern already used by models_manager_mlx_server.lua's
-- sweep/probe tasks in this same module family.
helpers.assert_true(
	delete_fn_body:find("_active_tasks", 1, false) ~= nil,
	"delete_model's hs.task must be pinned in M._active_tasks so GC cannot SIGTERM it mid-delete"
)

print("[PASS] test_mlx_manager_delete_nonblocking")
