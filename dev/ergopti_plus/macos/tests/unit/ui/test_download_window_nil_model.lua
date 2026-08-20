--- tests/unit/ui/test_download_window_nil_model.lua

--- Regression test for ui-windows-a-1: download_window.show() called
--- M._current_model:gsub() without nil-checking first. For bootstrap-kind
--- callers (opts.kind == "mlx_install" or "ollama_install"), _current_model is
--- never set, so dereferencing it directly crashes the window.
---
--- Fix: wrap both setModel() call sites in `if M._current_model then` so
--- bootstrap-kind show() calls skip the nil model name.
---
--- F-LOW-16 update: the two setModel() call sites used to hand-roll their own
--- escaping via M._current_model:gsub(...); they now route through the file's
--- shared js_str() helper instead (which also nil-checks internally). The
--- gsub-specific assertions below were pinned to that now-removed
--- implementation detail — updated to assert the real invariant this test
--- protects: every setModel(js_str(M._current_model)) call site remains
--- guarded by `if M._current_model then`, so a nil model name is never passed
--- to js_str() at all.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to ui/download_window/init.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function ensure_webview")
helpers.assert_true(src ~= nil, "ui/download_window/init.lua source must be locatable")

-- Test 1: every js_str(M._current_model) call site must be guarded.
-- Sound check: the number of `if M._current_model then` guards must be >= the
-- number of js_str(...) call sites that reference M._current_model directly
-- (the setModel(...) call is built via string concatenation, so this pattern
-- targets the js_str() argument rather than the full call expression).
local guard_count = 0
for _ in src:gmatch("if M%._current_model then") do guard_count = guard_count + 1 end

local set_model_count = 0
for _ in src:gmatch("js_str%(M%._current_model%)") do set_model_count = set_model_count + 1 end

helpers.assert_true(
	set_model_count > 0,
	"download_window/init.lua must have at least one js_str(M._current_model) call (F-LOW-16)"
)
helpers.assert_true(
	guard_count >= set_model_count,
	"download_window/init.lua has " .. set_model_count .. " setModel(js_str(M._current_model)) call(s)"
		.. " but only " .. guard_count .. " 'if M._current_model then' guard(s)"
		.. " — all setModel() sites must be guarded (ui-windows-a-1)"
)

-- Test 2: verify the guard pattern text is exactly what we expect.
local has_guard = src:find("if M._current_model then", 1, true) ~= nil
helpers.assert_true(
	has_guard,
	"download_window/init.lua must guard setModel() with 'if M._current_model then' (ui-windows-a-1)"
)

print("[PASS] test_download_window_nil_model")
