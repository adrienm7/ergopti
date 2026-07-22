--- tests/unit/meta/test_audit_hs_final_fixes.lua

--- ==============================================================================
--- MODULE: Audit Hammerspoon Final Regression Tests
--- DESCRIPTION:
--- Static-source guards for the bugs fixed from AUDIT_FINAL_SENIOR.md:
---   1. file_system.lua M.read: fh:close() skipped when fh:read() panics
---   2. toml_cache.lua M.store: fh:close() skipped when fh:write() panics
---   3. toml_cache.lua content_fingerprint: f:close() skipped on read error
---   4. gestures/engine.lua: lastFirePos not compensated on centroid jump
---   5. gestures/actions.lua: leftMouseTap doAfter(0) race re-engages hold
---   6. karabiner/watchers.lua: allWindows() nil-crash + task nil + hotkey pcall
---   7. modules/llm/api_remote.lua: shared HttpClient cancels in-flight inference
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

local function read_src(rel)
	local f = io.open(DRIVER_ROOT .. rel, "r")
	if not f then return nil, "cannot open: " .. DRIVER_ROOT .. rel end
	local s = f:read("*a")
	f:close()
	return s
end

helpers.describe("Audit-hs-final fixes", function()


	-- ==================================================
	-- ===== 1) file_system.lua: read() FD leak fixed
	-- ==================================================

	helpers.it("file_system.lua M.read must close fh even when fh:read() panics", function()
		local src = read_src("adapters/file_system.lua")
		assert(src, "adapters/file_system.lua must be readable")
		-- The fix: inner pcall around fh:read("*a") so fh:close() always runs.
		assert(
			src:find("pcall%(function%(%)", 1, false) and src:find("fh:close%(%)", 1, false),
			"file_system.lua: M.read must wrap fh:read() in pcall and call fh:close() outside it"
		)
	end)


	-- ===================================================
	-- ===== 2) toml_cache.lua: M.store FD leak fixed
	-- ===================================================

	helpers.it("toml_cache.lua M.store must close fh even when fh:write() panics", function()
		local src = read_src("adapters/toml_cache.lua")
		assert(src, "adapters/toml_cache.lua must be readable")
		-- The fix: inner pcall around fh:write(body) with fh:close() outside.
		assert(
			src:find("write_ok", 1, true),
			"toml_cache.lua: M.store must use an inner pcall capturing write_ok to guarantee fh:close()"
		)
	end)


	-- ==========================================================
	-- ===== 3) toml_cache.lua: content_fingerprint FD leak fixed
	-- ==========================================================

	helpers.it("toml_cache.lua content_fingerprint must close f even when f:read() panics", function()
		local src = read_src("adapters/toml_cache.lua")
		assert(src, "adapters/toml_cache.lua must be readable")
		-- The fix: inner pcall around f:read(...) with f:close() outside.
		assert(
			src:find("read_ok", 1, true),
			"toml_cache.lua: content_fingerprint must use inner pcall capturing read_ok to guarantee f:close()"
		)
	end)


	-- =========================================================
	-- ===== 4) engine.lua: lastFirePos compensated on centroid jump
	-- =========================================================

	helpers.it("engine.lua must compensate lastFirePos on finger-count centroid jump", function()
		local src = read_src("modules/gestures/engine.lua")
		assert(src, "modules/gestures/engine.lua must be readable")
		-- The bug: startPos was adjusted by jumpX/jumpY but lastFirePos was not.
		-- The reversal detector uses (pos - lastFirePos), so the jump appeared as
		-- movement in the wrong direction, firing a spurious reversal.
		assert(
			src:find("gs%.lastFirePos", 1, false) and src:find("jumpX", 1, true),
			"engine.lua: lastFirePos must be updated with the same jump offsets as startPos"
		)
		-- Verify both are updated in the same compensation block
		-- Window of 700 bytes: long comments with UTF-8 chars push lastFirePos past 650 bytes
		local comp_start = src:find("StartPos Compensation", 1, true)
		local comp_block = comp_start and src:sub(comp_start, comp_start + 700) or ""
		assert(
			comp_block:find("gs%.lastFirePos", 1, false),
			"engine.lua: lastFirePos compensation must be inside the centroid-jump block"
		)
	end)


	-- ========================================================
	-- ===== 5) actions.lua: leftMouseTap doAfter race fixed
	-- ========================================================

	helpers.it("actions.lua leftMouseTap must guard on leftClickHeld before re-toggling", function()
		-- The synthetic click-hold subsystem was extracted into actions_click.lua;
		-- read both so the guard assertion survives that move (move-resilient).
		local src = (read_src("modules/gestures/actions.lua") or "") ..
			"\n" .. (read_src("modules/gestures/actions_click.lua") or "")
		assert(src ~= "", "gestures actions/actions_click source must be readable")
		-- The bug: doAfter(0, M.toggle_left_click) fired unconditionally. If
		-- click_key_watcher had already set leftClickHeld=false, the deferred
		-- call re-engaged an infinite hold.
		-- The fix: guard inside the deferred closure.
		assert(
			not src:find("doAfter%(0, M%.toggle_left_click%)", 1, false),
			"actions.lua: bare doAfter(0, M.toggle_left_click) must be replaced with a guarded closure"
		)
		assert(
			src:find("if leftClickHeld then M%.toggle_left_click", 1, false),
			"actions.lua: the deferred leftMouseUp handler must check leftClickHeld before toggling"
		)
	end)


	-- =======================================================================
	-- ===== 6a) karabiner/watchers.lua: allWindows() nil-crash fixed
	-- =======================================================================

	helpers.it("karabiner/watchers.lua must guard allWindows() against nil return", function()
		local src = read_src("modules/karabiner/watchers.lua")
		assert(src, "modules/karabiner/watchers.lua must be readable")
		-- The bug: app:allWindows() can return nil if the app exits mid-call.
		-- ipairs(nil) would crash with "bad argument #1".
		assert(
			src:find("allWindows%(%)" .. "%s*or%s*{}", 1, false),
			"karabiner/watchers.lua: allWindows() must be guarded with `or {}` to prevent nil crash"
		)
	end)


	-- =======================================================================
	-- ===== 6b) karabiner/watchers.lua: inner hs.task nil-check added
	-- =======================================================================

	helpers.it("karabiner/watchers.lua inner hs.task must be nil-checked before :start()", function()
		local src = read_src("modules/karabiner/watchers.lua")
		assert(src, "modules/karabiner/watchers.lua must be readable")
		-- The bug: hs.task.new(...):start() chained with no nil-check — crashes
		-- if the CLI binary is missing and hs.task.new() returns nil.
		-- Use [^\n]* (not .-) because in Lua 5.4 the dot matches newlines,
		-- which would bridge the %b() close paren to a :start() call many lines later.
		assert(
			not src:find("hs%.task%.new%b()[^\n]*:start%(%)", 1, false),
			"karabiner/watchers.lua: hs.task.new() result must not chain directly to :start() — nil-check required"
		)
	end)


	-- =======================================================================
	-- ===== 6c) karabiner/watchers.lua: F17 hotkey wrapped in pcall
	-- =======================================================================

	helpers.it("karabiner/watchers.lua F17 cycle-windows hotkey must use pcall wrapper", function()
		local src = read_src("modules/karabiner/watchers.lua")
		assert(src, "modules/karabiner/watchers.lua must be readable")
		-- The other hotkeys (Shift+F17, Alt+F17) already wrap their callback in pcall.
		-- The plain F17 hotkey must match for consistency.
		assert(
			src:find("pcall%(cycle_windows_in_app%)", 1, false),
			"karabiner/watchers.lua: cycle_windows_in_app hotkey must call pcall(cycle_windows_in_app)"
		)
	end)


	-- =====================================================================
	-- ===== 7) api_remote.lua: split into _infer_client + _check_client
	-- =====================================================================

	helpers.it("api_remote.lua must use separate _infer_client and _check_client", function()
		local src = read_src("modules/llm/api_remote.lua")
		assert(src, "modules/llm/api_remote.lua must be readable")
		-- The bug: single HttpClient used for both POST inference and GET health-checks.
		-- http_client.lua cancels the in-flight request on every new call, so a
		-- background ping would silently abort a user's LLM completion.
		assert(
			not src:find("local HttpClient%s*=", 1, false),
			"api_remote.lua: must not use a single shared HttpClient — split into _infer_client and _check_client"
		)
		assert(src:find("_infer_client", 1, true), "api_remote.lua: must declare _infer_client for POST inference")
		assert(src:find("_check_client", 1, true), "api_remote.lua: must declare _check_client for GET health-checks")
		assert(src:find("_infer_client%.post", 1, false), "api_remote.lua: inference must use _infer_client.post")
		assert(src:find("_check_client%.get",  1, false), "api_remote.lua: health-checks must use _check_client.get")
	end)

end)
