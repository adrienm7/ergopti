--- tests/unit/modules/dynamic_hotstrings/test_personal_info.lua

--- ==============================================================================
--- MODULE: personal_info Unit Tests
--- DESCRIPTION:
--- Validates the public surface of the personal info module: enable/disable
--- toggles, getters for the trigger character and the info table, and the
--- save_info file-write contract (against an in-memory mocked path).
--- ==============================================================================

local helpers = require("tests.helpers")

-- Pause invariant for personal info hotstrings: they must not expand while the
-- driver is paused. personal_info has no pause state of its own — the guard is
-- the early return at the top of the keystroke path — so this case used to be
-- "assert_true(true)" with a comment saying where the real guard lived.
--
-- What is checkable is WHERE that guard sits. Action-epoch reconciliation and
-- stale internal-loopback disposal intentionally precede it in every state, but
-- no physical event accessor, interceptor, or buffer mutation may. Otherwise the
-- first thing typed after a resume could expand against a buffer built while the
-- user thought nothing was listening.
local PHYSICAL_OBSERVATION_MARKERS = {
	"e:getKeyCode()",
	"e:getFlags()",
	"e:getCharacters(false)",
	"CoreState.interceptors",
	"LLMBridge.handle_llm_keys",
	"CoreState.buffer",
}


--- @param source string
--- @return string raw
local function raw_keydown_slice(source)
	local start_pos = source:find("local function onKeyDownRaw%(")
	local end_pos = start_pos and source:find(
		"\nlocal function merge_returned_events", start_pos, true)
	helpers.assert_not_nil(start_pos, "onKeyDownRaw must remain locatable")
	helpers.assert_not_nil(end_pos, "onKeyDownRaw must remain independently bounded")
	return source:sub(start_pos, end_pos - 1)
end


--- @param raw string
--- @return boolean valid
local function pause_precedes_physical_observation(raw)
	local code = raw:gsub("%-%-[^\n]*", "")
	local parameters = code:match("local function onKeyDownRaw%s*%(([^)]*)%)")
	parameters = parameters and parameters:gsub("%s+", "") or nil
	if parameters ~= "e,provenance,provenance_status" then return false end
	local stale_at = code:find(
		"if provenance and provenance.stale_loopback then return true end", 1, true)
	local unreadable_at = code:find(
		"if provenance_status == EventProvenance.STATUS_UNREADABLE then", 1, true)
	local owned_at = code:find(
		"if provenance and not internal_loopback then return false end", 1, true)
	local pause_at = code:find(
		"if CoreState.processing_paused then return internal_loopback == true end", 1, true)
	if not (stale_at and unreadable_at and owned_at and pause_at) then return false end
	if not (stale_at < unreadable_at and unreadable_at < owned_at and owned_at < pause_at) then
		return false
	end
	for _, marker in ipairs(PHYSICAL_OBSERVATION_MARKERS) do
		local marker_at = code:find(marker, 1, true)
		if marker_at == nil or marker_at <= pause_at then return false end
	end
	return true
end


helpers.describe("Personal info pause guard", function()
	helpers.it("the keystroke path returns on pause before observing physical input", function()
		local src, err = helpers.read_driver_unit("local function onKeyDownRaw")
		helpers.assert_not_nil(src, err)
		local raw = raw_keydown_slice(src)
		helpers.assert_true(pause_precedes_physical_observation(raw),
			"the current (event, provenance, status) handler must reconcile provenance, "
				.. "then stop paused input before every enumerated physical observation")

		local pause = "if CoreState.processing_paused then return internal_loopback == true end"
		local pause_at = raw:find(pause, 1, true)
		helpers.assert_not_nil(pause_at, "the sensitivity mutation needs the real pause gate")
		for _, marker in ipairs(PHYSICAL_OBSERVATION_MARKERS) do
			local mutant = raw:sub(1, pause_at - 1) .. marker .. "\n" .. raw:sub(pause_at)
			helpers.assert_true(not pause_precedes_physical_observation(mutant),
				"the pause guard must fail if physical work moves ahead of it: " .. marker)
		end
	end)
end)

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local PI = helpers.load_with_stubs("modules.dynamic_hotstrings.personal_info")




-- =====================================
-- =====================================
-- ======= 1/ Default getters ==========
-- =====================================
-- =====================================

helpers.describe("PersonalInfo getters", function()
	helpers.it("get_trigger_char returns a non-empty string", function()
		local t = PI.get_trigger_char()
		helpers.assert_true(type(t) == "string" and t ~= "")
	end)

	helpers.it("get_info returns a table (possibly empty before init)", function()
		helpers.assert_eq(type(PI.get_info()), "table")
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ enable / disable =========
-- =====================================
-- =====================================

helpers.describe("PersonalInfo enable / disable", function()
	helpers.it("enable does not crash before start()", function()
		PI.enable()
	end)

	helpers.it("disable does not crash before start()", function()
		PI.disable()
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ save_info ================
-- =====================================
-- =====================================

helpers.describe("PersonalInfo.save_info", function()
	helpers.it("ignores non-table input", function()
		PI.save_info(nil)
		PI.save_info("oops")
		PI.save_info(42)
	end)
end)




-- =====================================================================
-- =====================================================================
-- ======= 4/ TOML round-trip for underscore keys (F-CRIT-1) ==========
-- =====================================================================
-- =====================================================================

-- Regression for F-CRIT-1: parse_toml_section's key pattern used to be
-- '^(%w+)%s*=%s*"(.*)"$' — Lua's %w class excludes '_', so every
-- underscore-named key (date_of_birth, phone_number, social_security_number,
-- …) silently failed to parse and fell back to DEFAULT_CONFIG on every
-- restart, wiping the user's real personal data with no error.
helpers.describe("PersonalInfo TOML round-trip — underscore-named keys survive a restart (F-CRIT-1 regression)", function()

	helpers.it("every DEFAULT_CONFIG.info key, including underscore-named ones, round-trips through a real file", function()
		local tmp_path = os.tmpname()

		local lines = { "[info]" }
		local expected = {}

		-- Build a personal_info.toml exercising every default key with a
		-- distinct, non-default sentinel value (underscore-heavy on purpose).
		local sentinel_keys = {
			"first_name", "last_name", "date_of_birth", "email_address",
			"work_email_address", "phone_number", "phone_number_clean",
			"street_address", "city", "country", "postal_code", "iban",
			"bic", "credit_card", "social_security_number",
		}
		for _, key in ipairs(sentinel_keys) do
			local value = "SENTINEL_" .. key:upper()
			expected[key] = value
			table.insert(lines, string.format('%s = "%s"', key, value))
		end

		local fh = io.open(tmp_path, "w")
		helpers.assert_true(fh ~= nil, "must be able to write the temp personal_info.toml")
		fh:write(table.concat(lines, "\n") .. "\n")
		fh:close()

		PI.start(nil, nil, tmp_path)
		local info = PI.get_info()

		for _, key in ipairs(sentinel_keys) do
			helpers.assert_eq(info[key], expected[key], "field '" .. key .. "' must round-trip, not silently fall back to its default")
		end

		os.remove(tmp_path)
	end)

end)
