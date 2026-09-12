--- tests/unit/infra/test_module_scope_ownership.lua

--- ==============================================================================
--- MODULE: Module Scope Ownership Regressions
--- DESCRIPTION:
--- Invalid or callback-mutated input lists must not redirect cache restoration.
--- ==============================================================================

local helpers = require("tests.helpers")
local KEYS = { "tests.virtual.scope_first", "tests.virtual.scope_second", "tests.virtual.scope_neighbor" }

--- Observes cache state before rescuing the fixture's own virtual entries.
--- @param scope string Public helper entry point.
--- @param mode string Invalid input or callback mutation scenario.
local function check_scope(scope, mode)
	local previous = table.pack(package.loaded[KEYS[1]], package.loaded[KEYS[2]], package.loaded[KEYS[3]])
	local first, neighbor = {}, {}
	package.loaded[KEYS[1]], package.loaded[KEYS[2]], package.loaded[KEYS[3]] = first, false, neighbor
	local names = { KEYS[1], KEYS[2] }
	local invalid = mode == "duplicate" or mode == "invalid_late"
		or mode == "sparse" or mode == "named_key" or mode == "zero_index"
	if mode == "duplicate" then names[3] = KEYS[1] end
	if mode == "invalid_late" then names[3] = false end
	if mode == "sparse" then names[2], names[3] = nil, KEYS[2] end
	if mode == "named_key" then names.extra = KEYS[3] end
	if mode == "zero_index" then names[0] = KEYS[3] end
	local calls = 0
	local outcome = table.pack(pcall(helpers[scope], names, function()
		calls = calls + 1
		helpers.assert_nil(package.loaded[KEYS[1]], "first owner must start fresh")
		helpers.assert_nil(package.loaded[KEYS[2]], "false predecessor must start fresh")
		package.loaded[KEYS[1]], package.loaded[KEYS[2]] = {}, {}
		if mode == "delete" then names[1] = nil end
		if mode == "replace" or mode == "replace_throw" then names[1] = KEYS[3] end
		if mode == "append" then names[3] = KEYS[3] end
		if mode == "reorder" then names[1], names[2] = names[2], names[1] end
		if mode == "replace_throw" then error("controlled scope callback failure") end
		return "first", nil, "last"
	end))
	local observed = table.pack(package.loaded[KEYS[1]], package.loaded[KEYS[2]], package.loaded[KEYS[3]])
	for index, key in ipairs(KEYS) do package.loaded[key] = previous[index] end
	helpers.assert_true(rawequal(observed[1], first), "restore the exact first owner before rescue")
	helpers.assert_eq(observed[2], false, "restore the false predecessor before rescue")
	helpers.assert_true(rawequal(observed[3], neighbor), "never overwrite an unowned neighbor")
	helpers.assert_eq(calls, invalid and 0 or 1, "reject invalid lists before callback entry")
	if invalid or mode == "replace_throw" then
		helpers.assert_eq(outcome[1], false, "invalid input or callback failure must propagate")
		local reason = mode == "duplicate" and "duplicate module name"
			or mode == "invalid_late" and "non-empty strings"
			or mode == "sparse" and "dense sequence"
			or (mode == "named_key" or mode == "zero_index") and "positive integer indices"
			or "controlled scope callback failure"
		helpers.assert_true(tostring(outcome[2]):find(reason, 1, true) ~= nil, "preserve the original failure")
	else
		helpers.assert_eq(outcome[1], true, tostring(outcome[2]))
		helpers.assert_eq(outcome.n, 4, "preserve nil callback return slots")
		helpers.assert_eq(outcome[2], "first")
		helpers.assert_nil(outcome[3])
		helpers.assert_eq(outcome[4], "last")
	end
end

helpers.describe("module scope owns its validated name snapshot", function()
	for _, scope in ipairs({ "with_fresh_modules", "with_stub_scope" }) do
		for _, mode in ipairs({ "duplicate", "invalid_late", "sparse", "named_key", "zero_index",
			"delete", "replace", "append", "reorder", "replace_throw" }) do
			helpers.it("(module-scope-ownership) " .. scope .. "/" .. mode, function()
				check_scope(scope, mode)
			end)
		end
	end
end)
