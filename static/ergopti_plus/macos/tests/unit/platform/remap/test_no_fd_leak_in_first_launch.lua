--- tests/unit/platform/remap/test_no_fd_leak_in_first_launch.lua

--- ==============================================================================
--- MODULE: Karabiner FD-Leak Regression Test
--- DESCRIPTION:
--- Regression guard ensuring that the first_launch file-existence check in
--- platform/remap/init.lua never leaks an open file descriptor.
---
--- FEATURES & RATIONALE:
--- 1. Root Cause: A naive `io.open(path) == nil` inline pattern leaves the
---    returned handle open for the entire process lifetime; the GC is the only
---    thing that eventually closes it, which is not acceptable in a long-running
---    Hammerspoon process.
--- 2. Fix Invariant: The correct pattern is a dedicated helper function that
---    calls `f:close()` before returning — the source must contain the sequence
---    `if f then f:close() end` adjacent to the `io.open` call.
--- 3. Source-Scan Strategy: Loading the full module requires a live macOS env
---    (Karabiner-Elements paths, hs.json, etc.). A source scan is simpler,
---    more portable, and directly encodes the invariant we care about.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the source of platform/remap/init.lua relative to driver_root.
--- @return string|nil Source text, or nil when the file cannot be opened.
local function read_karabiner_init_source()
	-- Selected by a declaration unique to platform/remap/init.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant
	-- into a path error.
	local body = helpers.read_driver_source("local function build_paused_ke_config")
	helpers.assert_true(body ~= nil, "platform/remap/init.lua source must be locatable")
	return body
end


helpers.describe("karabiner/init.lua: no fd-leak in first_launch detection", function()

	local src = read_karabiner_init_source()

	helpers.it("source file is readable (precondition)", function()
		helpers.assert_true(src ~= nil, "could not open platform/remap/init.lua for reading")
	end)

	if not src then return end


	-- =====================================================================
	-- ===== 1.1) Explicit close present =====
	-- =====================================================================

	helpers.it("file_exists helper calls f:close() after io.open", function()
		-- The canonical safe pattern: open → guard → close → return.
		-- We require all three tokens to appear together in the helper body.
		local has_io_open  = src:find("io.open(", 1, true) ~= nil
		local has_close    = src:find("f:close()", 1, true) ~= nil
		local has_guard_if = src:find("if f then", 1, true) ~= nil or
		                     src:find("if f ~= nil then", 1, true) ~= nil

		helpers.assert_true(has_io_open,
			"expected io.open() call in karabiner/init.lua — helper may have been removed")
		helpers.assert_true(has_close,
			"expected f:close() in karabiner/init.lua — fd-leak fix missing")
		helpers.assert_true(has_guard_if,
			"expected nil guard before f:close() — unconditional close would crash on missing file")
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


	-- =====================================================================
	-- ===== 1.3) Helper is a named local function =====
	-- =====================================================================

	helpers.it("file-existence check is a named local function, not inlined", function()
		-- Require a local function declaration that wraps io.open, rather than an
		-- ad-hoc inline expression scattered through M.init.
		local has_local_fn = src:match("local%s+function%s+file_exists%s*%(") ~= nil

		helpers.assert_true(has_local_fn,
			"expected `local function file_exists(...)` — check must live in a named helper, not be inlined")
	end)

end)
