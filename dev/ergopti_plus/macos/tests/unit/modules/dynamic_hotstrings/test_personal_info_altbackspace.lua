--- tests/unit/modules/dynamic_hotstrings/test_personal_info_altbackspace.lua

--- ==============================================================================
--- MODULE: personal_info Alt+Backspace Desync Regression Tests
--- DESCRIPTION:
--- Source-level guard for the "personal-info-altbackspace-desync" bug in
--- modules/dynamic_hotstrings/personal_info.lua.
---
--- ROOT CAUSE ENCODED:
--- The interceptor handled single backspace (kc 51) by trimming one character
--- from _combo. However, Alt+Backspace on macOS deletes an entire word, not
--- one character. After an Alt+Backspace, _combo contained extra characters
--- that no longer existed on screen. When the trigger (★) fired next, the
--- module computed a wrong backspace count and overwrote unrelated text.
---
--- The fix: detect flags.alt when kc == 51 and reset _state to STATE_IDLE
--- instead of trimming one char, so the next @-trigger starts clean.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==================================================================================================
-- ==================================================================================================
-- ======= 1/ Alt+Backspace guard resets state instead of trimming one char (dynhotstrings-2) =======
-- ==================================================================================================
-- ==================================================================================================

helpers.describe("personal_info interceptor — Alt+Backspace resets state (dynhotstrings-2 regression)", function()

	local function read_source()
		-- Selected by a declaration unique to modules/dynamic_hotstrings/personal_info.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function parse_toml_section")
		helpers.assert_true(src ~= nil, "modules/dynamic_hotstrings/personal_info.lua source must be locatable")
		return src
	end

	helpers.it("source contains flags.alt check inside the backspace handler", function()
		local src = read_source()
		-- The fix must test flags.alt when processing kc == 51 so that
		-- word-delete (Alt+Backspace) resets the state instead of trimming one char.
		helpers.assert_true(
			src:find("flags.alt", 1, true) ~= nil,
			"personal_info.lua must check flags.alt in the backspace handler (dynhotstrings-2)"
		)
	end)

	helpers.it("flags.alt branch resets _state to STATE_IDLE", function()
		local src = read_source()
		-- When flags.alt is true the state machine must abort collection — look
		-- for the reset pattern within a few lines of the flags.alt check.
		local alt_pos = src:find("flags.alt", 1, true)
		helpers.assert_true(alt_pos ~= nil, "flags.alt check must be present")
		-- The STATE_IDLE assignment must follow within 200 chars of the alt check
		local window = src:sub(alt_pos, alt_pos + 200)
		helpers.assert_true(
			window:find("STATE_IDLE", 1, true) ~= nil,
			"flags.alt branch must reset _state to STATE_IDLE within the handler (dynhotstrings-2)"
		)
	end)

end)
