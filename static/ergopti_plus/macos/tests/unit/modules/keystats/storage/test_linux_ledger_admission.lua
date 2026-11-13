--- tests/unit/modules/keystats/storage/test_linux_ledger_admission.lua

--- ==============================================================================
--- MODULE: Linux Ledgers Admitted By The Foreign Scanner
--- DESCRIPTION:
--- Linux now publishes by_device/<id>/data.sql. The shared fixture is the
--- exact output of the Linux exporter (its suite fails when the two diverge);
--- this suite proves the macOS foreign-ledger scanner admits it whole: every
--- batch committed, the rollover marker read as a fact, the typing ids found,
--- and no refusal of its INSERT forms.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["core.i18n.engine.i18n"] = { get = function(k) return k end, t = function(k) return k end }
local Export = helpers.load_with_stubs("modules.keystats.export")

local function fixture()
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	local root = assert(source:match("^(.*)/macos/tests/"), "the macOS suite runs from its checkout")
	local handle = assert(io.open(root .. "/_shared/tests/fixtures/keystats/linux_ledger.sql", "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

-- The canonical marker predicate of log_manager's _has_trailing_rollover.
local function is_rollover(trailing)
	local found = false
	for line in trailing:gmatch("[^\n]+") do
		if not line:match("^%s*$") then
			local previous, date = line:match("^%-%- === day rollover (.-) %-%> (%d%d%d%d%-%d%d%-%d%d) ===$")
			if not date or (previous ~= "" and not previous:match("^%d%d%d%d%-%d%d%-%d%d$")) then return false end
			found = true
		end
	end
	return found
end

helpers.describe("Linux ledger admitted by the foreign scanner", function()
	helpers.it("linux-ledger-admission: every Linux batch is complete and applicable", function()
		local text = fixture()
		helpers.assert_eq(Export._last_complete_batch_offset(text), #text)
	end)

	helpers.it("linux-ledger-admission: rollover facts and typing ids are read without refusal", function()
		local facts, reason = Export._typing_rollover_boundaries(fixture(), "'linux-ledger-host'", true, is_rollover)
		helpers.assert_nil(reason)
		helpers.assert_true(facts ~= nil, "facts returned")
		helpers.assert_eq(facts.has_markers, true)
		helpers.assert_eq(facts.unreadable, false)
		helpers.assert_nil(facts.regression)
		helpers.assert_eq(facts.ids[1], true)
		helpers.assert_eq(facts.ids[11], true,
			"the second day's typing row follows all ten raw families of the first, including ROI and the clipboard")
		helpers.assert_eq(facts.cutoffs[1], 1)
	end)
end)
