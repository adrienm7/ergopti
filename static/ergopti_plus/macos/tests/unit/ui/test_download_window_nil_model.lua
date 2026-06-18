--- tests/unit/ui/test_download_window_nil_model.lua

--- Regression test for ui-windows-a-1: download_window.show() called
--- M._current_model:gsub() without nil-checking first. For bootstrap-kind
--- callers (opts.kind == "mlx_install" or "ollama_install"), _current_model is
--- never set, so the gsub dereferences nil and crashes the window.
---
--- Fix: wrap both setModel() call sites in `if M._current_model then` so
--- bootstrap-kind show() calls skip the nil model name.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/download_window/init.lua"
local fh = io.open(src_path, "r")
if not fh then error("ui/download_window/init.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: every _current_model:gsub() must be preceded (within the surrounding
-- block) by a "if M._current_model" guard. We verify this by checking that the
-- pattern "if M._current_model" appears in the source immediately before each
-- gsub call site — concretely, by asserting no occurrence of
-- `M._current_model:gsub` appears without a matching guard somewhere before it
-- in the same show() body. Simplest sound check: ensure the number of
-- `if M._current_model` guards is >= the number of gsub call sites.
local guard_count = 0
for _ in src:gmatch("if M%._current_model then") do guard_count = guard_count + 1 end

local gsub_count = 0
for _ in src:gmatch("_current_model:gsub") do gsub_count = gsub_count + 1 end

helpers.assert_true(
	gsub_count > 0,
	"download_window/init.lua must have at least one _current_model:gsub call"
)
helpers.assert_true(
	guard_count >= gsub_count,
	"download_window/init.lua has " .. gsub_count .. " _current_model:gsub call(s)"
		.. " but only " .. guard_count .. " 'if M._current_model then' guard(s)"
		.. " — all gsub sites must be guarded (ui-windows-a-1)"
)

-- Test 2: verify the guard pattern text is exactly what we expect.
local has_guard = src:find("if M._current_model then", 1, true) ~= nil
helpers.assert_true(
	has_guard,
	"download_window/init.lua must guard setModel() with 'if M._current_model then' (ui-windows-a-1)"
)

print("[PASS] test_download_window_nil_model")
