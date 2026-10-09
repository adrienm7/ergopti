--- tests/meta/test_hs_boot_ready_key_single_source.lua

--- ==============================================================================
--- MODULE: Regression — HS_BOOT_READY_SETTING_KEY single source of truth (F-LOW-11)
--- DESCRIPTION:
--- The "hs_boot_ready_v1" logical settings-key string literal used to be
--- independently declared in BOTH init.lua and platform/remap/ke_lifecycle.lua.
--- A future rename in only one file would silently desync the boot-readiness
--- notification with no error — init.lua would flip a key ke_lifecycle.lua
--- never reads, so the Karabiner-ready notification would stay pending forever.
---
--- Fix: ke_lifecycle.lua is the sole reader of the flag (init.lua only ever
--- writes it), so it now owns and exports the constant as
--- M.HS_BOOT_READY_SETTING_KEY. init.lua reads it via
--- require("platform.remap.ke_lifecycle").HS_BOOT_READY_SETTING_KEY instead
--- of re-declaring the literal.
---
--- Test: the literal string must appear exactly ONCE across both files
--- (in ke_lifecycle.lua, where it is authored), and init.lua must reference
--- ke_lifecycle's export rather than re-declaring it.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

--- Counts non-overlapping occurrences of a literal substring.
--- @param src string Haystack.
--- @param literal string Needle (plain-text, not a pattern).
--- @return number
local function count_occurrences(src, literal)
	local count, pos = 0, 1
	while true do
		local s = src:find(literal, pos, true)
		if not s then break end
		count = count + 1
		pos = s + #literal
	end
	return count
end

helpers.describe("F-LOW-11: HS_BOOT_READY_SETTING_KEY has a single source of truth", function()

	helpers.it('the literal "hs_boot_ready_v1" appears exactly once across init.lua + ke_lifecycle.lua', function()
		local init_src        = read("local function has_common_hotstring_groups") -- init.lua
		local ke_lifecycle_src = read("local KE_GRABBER_CHECK") -- platform/remap/ke_lifecycle.lua

		local literal = "hs_boot_ready_v1"
		local total = count_occurrences(init_src, literal) + count_occurrences(ke_lifecycle_src, literal)

		helpers.assert_true(total == 1,
			string.format('the literal "%s" must be declared exactly once across init.lua + ke_lifecycle.lua ' ..
				"(single source of truth, F-LOW-11) — found %d occurrence(s)", literal, total))
	end)

	helpers.it("ke_lifecycle.lua exports HS_BOOT_READY_SETTING_KEY on its module table", function()
		local src = read("local KE_GRABBER_CHECK") -- platform/remap/ke_lifecycle.lua
		helpers.assert_true(src:find("M.HS_BOOT_READY_SETTING_KEY", 1, true) ~= nil,
			"ke_lifecycle.lua must expose M.HS_BOOT_READY_SETTING_KEY so init.lua can read it (F-LOW-11)")
	end)

	helpers.it("init.lua reads the constant from ke_lifecycle instead of re-declaring the literal", function()
		local src = read("local function has_common_hotstring_groups") -- init.lua
		helpers.assert_true(
			src:find('require("platform.remap.ke_lifecycle").HS_BOOT_READY_SETTING_KEY', 1, true) ~= nil,
			"init.lua must obtain HS_BOOT_READY_SETTING_KEY via ke_lifecycle's export (F-LOW-11)")
	end)
end)
