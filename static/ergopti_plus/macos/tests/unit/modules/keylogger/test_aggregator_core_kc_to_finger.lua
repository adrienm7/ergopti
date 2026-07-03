--- tests/unit/modules/keylogger/test_aggregator_core_kc_to_finger.lua

--- ==============================================================================
--- MODULE: keylogger.aggregator.core KC_TO_FINGER Single-Source Tests (DC-1)
--- DESCRIPTION:
--- KC_TO_FINGER (macOS virtual-keycode -> finger column, used for same-finger/
--- same-hand streak tracking in events.lua) used to be a hand-copied literal
--- table with no mechanism catching drift against the canonical
--- _shared/data/keycodes/azerty.json. It is now derived at module-load time by
--- reading and parsing that shared JSON. These tests pin the fix:
---   1. KC_TO_FINGER is non-empty and has the expected content-key count.
---   2. Every entry's finger value matches azerty.json exactly (parity).
---   3. The keycode set is unchanged from the pre-refactor hardcoded table
---      (no accidental widening/narrowing of the streak-tracking scope).
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
helpers.load_with_stubs("lib.logger")

local core = helpers.load_with_stubs("modules.keylogger.aggregator.core")

--- The exact keycode set the pre-refactor hardcoded KC_TO_FINGER covered.
--- Deliberately duplicated here (not read from core.lua) so this test also
--- catches an accidental change to CONTENT_KCS itself, not just a mismatch
--- against azerty.json.
local EXPECTED_KCS = {
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11,
	12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
	25, 26, 28, 29, 31, 32, 34, 35, 37, 38, 40, 41, 43, 44, 45, 46, 47,
}

local function read_azerty_json()
	local path = helpers.shared("data/keycodes/azerty.json")
	local fh = io.open(path, "r")
	if not fh then return nil, "cannot open " .. tostring(path) end
	local raw = fh:read("*a")
	fh:close()
	local ok, data = pcall(hs.json.decode, raw)
	if not ok then return nil, "JSON parse error: " .. tostring(data) end
	return data, nil
end

local azerty, azerty_err = read_azerty_json()




-- ==========================================
-- ==========================================
-- ======= 1/ Shape & completeness =========
-- ==========================================
-- ==========================================

helpers.describe("aggregator.core KC_TO_FINGER (DC-1)", function()
	helpers.it("azerty.json is readable and parseable", function()
		helpers.assert_true(azerty ~= nil, azerty_err or "azerty.json must parse")
	end)

	helpers.it("has exactly the pre-refactor content-keycode count", function()
		local count = 0
		for _ in pairs(core.KC_TO_FINGER) do count = count + 1 end
		helpers.assert_eq(count, #EXPECTED_KCS)
	end)

	helpers.it("covers exactly EXPECTED_KCS, no more, no fewer", function()
		local wanted = {}
		for _, kc in ipairs(EXPECTED_KCS) do wanted[kc] = true end

		for kc in pairs(core.KC_TO_FINGER) do
			helpers.assert_true(wanted[kc] == true, "unexpected kc " .. tostring(kc) .. " present in KC_TO_FINGER")
		end
		for _, kc in ipairs(EXPECTED_KCS) do
			helpers.assert_true(core.KC_TO_FINGER[kc] ~= nil, "expected kc " .. tostring(kc) .. " missing from KC_TO_FINGER")
		end
	end)




	-- ==========================================
	-- ======= 2/ Parity against azerty.json ====
	-- ==========================================

	helpers.it("every finger value matches azerty.json's canonical map", function()
		if not azerty then return end
		local by_kc = {}
		for _, entry in ipairs(azerty.keys) do
			by_kc[entry.kc] = entry.finger
		end

		for _, kc in ipairs(EXPECTED_KCS) do
			helpers.assert_eq(core.KC_TO_FINGER[kc], by_kc[kc], "kc " .. tostring(kc))
		end
	end)
end)
