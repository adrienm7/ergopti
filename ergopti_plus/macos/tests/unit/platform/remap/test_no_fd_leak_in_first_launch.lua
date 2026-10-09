--- tests/unit/platform/remap/test_no_fd_leak_in_first_launch.lua

--- ==============================================================================
--- MODULE: Karabiner FD-Leak Regression Test
--- DESCRIPTION:
--- Regression guard ensuring that first-launch detection in
--- platform/remap/init.lua never opens a file descriptor of its own.
---
--- FEATURES & RATIONALE:
--- 1. Root Cause: A naive `io.open(path) == nil` inline pattern leaves the
---    returned handle open for the entire process lifetime; the GC is the only
---    thing that eventually closes it, which is not acceptable in a long-running
---    Hammerspoon process.
--- 2. Fix Invariant: The boot path delegates to Config.load_user_config(), whose
---    status distinguishes absent configuration from read failure. The entry
---    point performs no raw `io.open` at all.
--- 3. Source-Scan Strategy: Loading the full module requires a live macOS env
---    (Karabiner-Elements paths, hs.json, etc.). This scan pins the delegation
---    boundary while the config tests exercise its status semantics.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the source of platform/remap/init.lua relative to driver_root.
--- @return string|nil Source text, or nil when the file cannot be opened.
local function read_karabiner_init_source()
	-- Selected by a declaration unique to platform/remap/init.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant
	-- into a path error.
	local body = helpers.read_driver_source("local KARABINER_KE_TILDE_PATH")
	helpers.assert_true(body ~= nil, "platform/remap/init.lua source must be locatable")
	return body
end


helpers.describe("karabiner/init.lua: no fd-leak in first_launch detection", function()

	local src = read_karabiner_init_source()

	helpers.it("source file is readable (precondition)", function()
		helpers.assert_true(src ~= nil, "could not open platform/remap/init.lua for reading")
	end)

	if not src then return end


	-- ======================================
	-- ===== 1.1) Delegated status load =====
	-- ======================================

	helpers.it("delegates first-launch classification without opening a file", function()
		local code = src:gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find("Config.load_user_config", 1, true) ~= nil,
			"first-launch detection must use the status-bearing config loader")
		helpers.assert_true(code:find("io.open(", 1, true) == nil,
			"the boot entry point must not reacquire a raw descriptor for existence detection")
	end)


	-- =====================================================================
	-- ===== 1.2) Bare leak pattern absent =====
	-- =====================================================================

	helpers.it("source does NOT contain the bare io.open(...) == nil leak pattern", function()
		-- The leak pattern: comparing the raw io.open return directly to nil
		-- without ever storing the handle, so close() can never be called.
		-- Variants:  `io.open(path) == nil`  and  `not io.open(path)`.
		local has_open_eq_nil = src:match("io%.open%b()%s*==%s*nil") ~= nil
		local has_not_open    = src:match("not%s+io%.open%b()") ~= nil

		helpers.assert_true(not has_open_eq_nil,
			"found bare `io.open(...) == nil` — this leaks an fd; use a helper that calls f:close()")
		helpers.assert_true(not has_not_open,
			"found `not io.open(...)` — this leaks an fd when the file exists; use a helper that calls f:close()")
	end)


	-- =====================================
	-- ===== 1.3) Error before absence =====
	-- =====================================

	helpers.it("distinguishes unreadable configuration from an absent first launch", function()
		local code = src:gsub("%-%-[^\n]*", "")
		local load_at = code:find("Config.load_user_config", 1, true)
		local error_at = load_at and code:find('user_config_status == "error"', load_at, true)
		local absent_at = load_at and code:find('local first_launch = user_config_status == "absent"', load_at, true)
		helpers.assert_true(load_at ~= nil and error_at ~= nil and absent_at ~= nil,
			"the status-bearing load, error refusal, and absent classification must all remain present")
		helpers.assert_true(error_at < absent_at,
			"an unreadable config must be refused before the absent status can seed defaults")
	end)

end)
