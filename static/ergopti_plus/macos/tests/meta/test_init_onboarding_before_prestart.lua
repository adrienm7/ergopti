--- tests/meta/test_init_onboarding_before_prestart.lua

--- ==============================================================================
--- MODULE: Regression — onboarding short-circuit fires before gestures pre-start (M-14)
--- DESCRIPTION:
--- Before M-14, init.lua ran gestures.start() and shortcuts.start() (Section 1
--- Module Pre-start) BEFORE the onboarding early-return check in Section 3.
--- On first launch (no config.toml), the wizard ran with gestures active:
--- CoreState.enabled=true meant 3-finger taps fired synthetic clicks and swipes
--- sent Alt+arrow keys to the focused window — all before the user consented.
---
--- Fix: the onboarding should_run/return block was moved to BEFORE Section 1,
--- so gestures and shortcuts are never pre-started during the wizard.
---
--- Test: source scan — assert the onboarding guard byte-position is strictly
--- before both gestures.start() and require("modules.llm.boot_cleanup").
--- ==============================================================================

local helpers = require("tests.helpers")

local ONBOARDING_FAILURE_EXIT =
	'emergency_exit_after_runtime_failure("onboarding", "module_load_failed")'


--- Removes Lua line and long-bracket comments before executable assertions.
--- @param source string
--- @return string code
local function strip_lua_comments(source)
	local code = source
	local cursor = 1
	while true do
		local open_at, open_end, equals = code:find("%-%-%[(=*)%[", cursor)
		if not open_at then break end
		local close_token = "]" .. equals .. "]"
		local _, close_end = code:find(close_token, open_end + 1, true)
		if not close_end then
			code = code:sub(1, open_at - 1)
			break
		end
		local block = code:sub(open_at, close_end)
		local newlines = block:gsub("[^\n]", "")
		code = code:sub(1, open_at - 1) .. newlines .. code:sub(close_end + 1)
		cursor = open_at + #newlines
	end
	return (code:gsub("%-%-[^\n]*", ""))
end


--- Replaces one exact occurrence and proves the mutation precondition.
--- @param source string Original source.
--- @param needle string Exact text.
--- @param replacement string Replacement text.
--- @return string mutant
local function replace_plain(source, needle, replacement)
	local at = source:find(needle, 1, true)
	helpers.assert_true(at ~= nil, "mutation precondition missing: " .. needle)
	return source:sub(1, at - 1) .. replacement .. source:sub(at + #needle)
end


--- Validates the onboarding load-failure terminal boundary.
--- @param source string Root source or a synthetic mutant.
--- @return boolean valid
--- @return string|nil reason
local function onboarding_failure_is_terminal(source)
	local code = strip_lua_comments(source)
	local req_pos = code:find('pcall(require, "ui.onboarding")', 1, true)
	local should_pos = code:find("should_run", req_pos or 1, true)
	local gesture_pos = code:find("gestures.start()", should_pos or 1, true)
	if not req_pos or not should_pos or not gesture_pos then
		return false, "onboarding boot anchors are incomplete"
	end

	local guard = code:sub(req_pos, should_pos)
	local refusal_at = guard:find("not ok_ob", 1, true)
	local log_at = guard:find("Logger.error", 1, true)
	local exit_at = guard:find(ONBOARDING_FAILURE_EXIT, 1, true)
	local return_at = guard:find("\n\t\treturn\n", 1, true)
	if not refusal_at or not log_at or not exit_at or not return_at then
		return false, "the onboarding load refusal is not logged and terminal"
	end
	if not (refusal_at < log_at and log_at < exit_at and exit_at < return_at) then
		return false, "the onboarding load refusal operations are out of order"
	end
	if should_pos >= gesture_pos then
		return false, "the onboarding guard runs after gestures start"
	end
	return true
end





-- =================================================================================
-- =================================================================================
-- ======= 1/ init.lua: onboarding check is before gestures pre-start (M-14) =======
-- =================================================================================
-- =================================================================================

helpers.describe("M-14: onboarding short-circuit before module pre-start", function()

	helpers.it("onboarding.should_run appears before gestures.start() in init.lua", function()
		-- Selected by a declaration unique to init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function has_common_hotstring_groups")
		helpers.assert_true(src ~= nil, "init.lua source must be locatable")

		local ob_pos      = src:find("should_run", 1, true)
		local gesture_pos = src:find("gestures.start()", 1, true)

		helpers.assert_true(ob_pos ~= nil,
			"init.lua must call onboarding.should_run() to guard first-launch")
		helpers.assert_true(gesture_pos ~= nil,
			"init.lua must call gestures.start()")
		helpers.assert_true(ob_pos < gesture_pos,
			"onboarding.should_run() must appear BEFORE gestures.start() in init.lua — " ..
			"gestures must not arm before the user has completed the wizard (M-14)")
	end)

	helpers.it("onboarding.should_run appears before boot_cleanup in init.lua", function()
		-- Selected by a declaration unique to init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function has_common_hotstring_groups")
		helpers.assert_true(src ~= nil, "init.lua source must be locatable")

		local ob_pos      = src:find("should_run", 1, true)
		local cleanup_pos = src:find("boot_cleanup", 1, true)

		helpers.assert_true(ob_pos ~= nil,
			"init.lua must call onboarding.should_run()")
		helpers.assert_true(cleanup_pos ~= nil,
			"init.lua must reference boot_cleanup")
		helpers.assert_true(ob_pos < cleanup_pos,
			"onboarding.should_run() must appear BEFORE boot_cleanup in init.lua (M-14)")
	end)
end)





-- =================================================================================
-- =================================================================================
-- ======= 2/ ui.onboarding load failure aborts boot (fail-fast, no consent) =======
-- =================================================================================
-- =================================================================================

helpers.describe("ui.onboarding require failure is fail-fast, not silently skipped", function()

	-- Root cause: the first-launch guard loads ui.onboarding via pcall(require).
	-- If that require failed, the block used to fall through and pre-start gestures
	-- and shortcuts anyway — arming synthetic input BEFORE the user consented. The
	-- not-ok case must log the exact load error, request the bounded runtime exit,
	-- and return only as a root-chunk backstop between the require and first use.
	helpers.it("requests a bounded exit when ui.onboarding fails to load", function()
		-- Selected by a declaration unique to init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function has_common_hotstring_groups")
		helpers.assert_true(src ~= nil, "init.lua source must be locatable")

		local valid, reason = onboarding_failure_is_terminal(src)
		helpers.assert_true(valid,
			"a failed ui.onboarding load must request a bounded exit: " .. tostring(reason))
	end)

	helpers.it("rejects commented-out bounded exits", function()
		local src = helpers.read_driver_source("local function has_common_hotstring_groups")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"init.lua source must be locatable")
		local commented_exit = replace_plain(src, ONBOARDING_FAILURE_EXIT,
			"-- " .. ONBOARDING_FAILURE_EXIT)
		local block_commented_exit = replace_plain(src, ONBOARDING_FAILURE_EXIT,
			"--[[\n" .. ONBOARDING_FAILURE_EXIT .. "\n]]")
		helpers.assert_eq(onboarding_failure_is_terminal(commented_exit), false)
		helpers.assert_eq(onboarding_failure_is_terminal(block_commented_exit), false)
	end)
end)
