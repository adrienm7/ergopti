--- _shared/lua/test/slot_roles_contract.lua

--- Replays the neutral keyboard-slot vectors through a driver's unit gate.
--- The same corpus runs on macOS and Linux (and on Windows once it adopts the
--- model), so the role table cannot mean different keys on different drivers.
--- @param helpers table Actual driver assertion helpers.
--- @param SlotRoles table Shared slot-role resolver.
--- @param fixture table { driver = "macos"|"linux"|"windows", corpus = table }.
return function(helpers, SlotRoles, fixture)
	local corpus, driver = fixture.corpus, fixture.driver
	assert(corpus.version == 1 and #corpus.valid >= 12 and #corpus.invalid >= 15 and #corpus.crosswalk >= 40,
		"slot-role corpus must keep its independent positive, refusal and crosswalk inventory")

	local function as_set(list)
		local set = {}
		for _, item in ipairs(list) do set[item] = true end
		return set
	end

	helpers.describe("neutral keyboard slots (" .. driver .. "): shared contract", function()
		for _, case in ipairs(corpus.valid) do
			helpers.it("(slot-roles) parses and rebuilds " .. case.slot, function()
				local parsed = SlotRoles.parse(case.slot)
				helpers.assert_type(parsed, "table")
				helpers.assert_eq(parsed.roles, case.roles)
				helpers.assert_eq(parsed.key, case.key)
				helpers.assert_eq(SlotRoles.id(parsed.roles, parsed.key), case.slot)
			end)
			helpers.it("(slot-roles) resolves " .. case.slot .. " on " .. driver, function()
				local native, reason = SlotRoles.native(driver, case.slot)
				local expected = case.native[driver]
				if expected.absent == true then
					helpers.assert_nil(native, case.slot)
					helpers.assert_type(reason, "string", case.slot)
				else
					helpers.assert_type(native, "table", case.slot)
					helpers.assert_eq(native.modifiers, expected.modifiers)
					helpers.assert_eq(native.key, expected.key)
				end
			end)
		end

		for index, slot in ipairs(corpus.invalid) do
			helpers.it("(slot-roles) refuses independent invalid id " .. tostring(index), function()
				local parsed, reason = SlotRoles.parse(slot)
				helpers.assert_nil(parsed, tostring(slot))
				helpers.assert_type(reason, "string", tostring(slot))
				local native = SlotRoles.native(driver, slot)
				helpers.assert_nil(native, tostring(slot))
			end)
		end

		for index, row in ipairs(corpus.crosswalk) do
			helpers.it("(slot-roles) crosswalk " .. tostring(index) .. " " .. row.driver .. " " .. row.slot, function()
				helpers.assert_eq(SlotRoles.from_native(row.driver, row.modifiers, row.key), row.slot)
				local native = SlotRoles.native(row.driver, row.slot)
				helpers.assert_type(native, "table", row.slot)
				helpers.assert_eq(native.key, row.key)
				helpers.assert_eq(as_set(native.modifiers), as_set(row.modifiers))
			end)
		end

		helpers.it("(slot-roles) refuses a driver it does not describe", function()
			local ok = pcall(SlotRoles.native, "beos", "primary_g")
			helpers.assert_eq(ok, false)
		end)

		helpers.it("(slot-roles) a native chord with a foreign modifier has no slot", function()
			local slot, reason = SlotRoles.from_native(driver, { "hyper" }, "g")
			helpers.assert_nil(slot)
			helpers.assert_type(reason, "string")
		end)
	end)
end
