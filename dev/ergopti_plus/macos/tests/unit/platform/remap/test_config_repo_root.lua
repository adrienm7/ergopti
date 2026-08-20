--- tests/unit/platform/remap/test_config_repo_root.lua

--- Regression tests for karabiner/config.lua save_user_config path and
--- run-loop blocking.
---
--- Former bug (karabiner-gen-1): save_user_config built the repo-root path
--- with the pattern "static/drivers/..." which never matched the real layout
--- "static/ergopti_plus/macos/...". The gsub returned the unchanged script
--- dir, so the format script path pointed nowhere.
---
--- Former bug (karabiner-gen-2): save_user_config called os.execute("python3
--- format_toml.py ...") synchronously on every config save, blocking the
--- Hammerspoon main run loop for 100-500 ms on each setter call.
--- The formatter was cosmetic only — TomlCodec.encode already emits valid TOML.
--- Fix: removed the synchronous os.execute call entirely.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to platform/remap/config.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function append_shared_modifier_chords")
helpers.assert_true(src ~= nil, "platform/remap/config.lua source must be locatable")

-- Test 1: The old path pattern that referenced the non-existent "drivers" sub-tree must be gone.
local has_old_pattern = src:find('"static[/\\\\]drivers[/\\\\]', 1, true) ~= nil
helpers.assert_true(
	not has_old_pattern,
	'config.lua must not use "static/drivers/" pattern for repo-root (path never existed in this layout)'
)

-- Test 2: save_user_config must not call os.execute with a Python formatter —
-- that call blocked the run loop synchronously on every settings change.
local has_sync_format = src:find('os.execute', 1, true) ~= nil
helpers.assert_true(
	not has_sync_format,
	'config.lua must not call os.execute (synchronous Python formatter blocks the run loop)'
)

-- Test 3: The Python format_toml.py call must not be present.
local has_format_py = src:find('format_toml.py', 1, true) ~= nil
helpers.assert_true(
	not has_format_py,
	'config.lua must not reference format_toml.py (formatter removed — TomlCodec already emits valid TOML)'
)

print("[PASS] test_config_repo_root")
