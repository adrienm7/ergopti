--- tests/unit/modules/karabiner/test_config_repo_root.lua

--- Regression test for karabiner-gen-1: save_user_config() constructed the
--- repo-root path with the pattern "static/drivers/..." which no longer
--- matches the actual layout "static/ergopti_plus/macos/...". The gsub
--- returned the unchanged _script_dir (deep inside the tree), so
--- _format_script pointed nowhere and the TOML formatter never ran.
---
--- Fix: changed the pattern to "static/.*$" (strips everything from "static/"
--- onwards) so the repo root is correctly resolved regardless of the sub-path
--- under static/.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "modules/karabiner/config.lua"
local fh = io.open(src_path, "r")
if not fh then error("config.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: The old pattern that references the non-existent "drivers" sub-tree must be gone.
local has_old_pattern = src:find('"static[/\\\\]drivers[/\\\\]', 1, true) ~= nil
helpers.assert_true(
	not has_old_pattern,
	'config.lua must not use "static/drivers/" pattern for repo-root (path never existed in this layout) (karabiner-gen-1)'
)

-- Test 2: The corrected pattern that strips from "static/" onward must be present.
local has_new_pattern = src:find('"static[/\\\\]', 1, true) ~= nil
helpers.assert_true(
	has_new_pattern,
	'config.lua must use "static/" pattern (without sub-path) for repo-root gsub (karabiner-gen-1)'
)

-- Test 3: The format script is still referenced via _repo_root (formatter path not hardcoded).
local has_format_script = src:find('_repo_root .. "/tools/format_toml.py"', 1, true) ~= nil
helpers.assert_true(
	has_format_script,
	'config.lua must build _format_script from _repo_root .. "/tools/format_toml.py" (karabiner-gen-1)'
)

print("[PASS] test_config_repo_root")
