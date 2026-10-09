--- tests/unit/lib/test_manifest_coverage_gaps.lua

--- ==============================================================================
--- MODULE: Platform-Coverage Gaps (the reason_key consumer)
--- DESCRIPTION:
--- `reason_key` names the locale key that explains WHY a feature is unavailable
--- on this platform. It sat in the schema, was policed by a frozen ratchet of 142
--- entries, and was read by NOTHING — a grep over the whole repository found it
--- only inside the ratchet that counts it.
---
--- THE ROOT CAUSE, and it is the thing this file exists to pin:
--- the driver could not read one even if it wanted to. `build-features-manifest.js`
--- filters the feature list per platform —
---
---     const platformFeatures = features.filter((f) => f.platforms.includes(platform));
---
--- — so a feature restricted to Windows simply DOES NOT APPEAR in
--- `features_manifest.lua`. macOS could not enumerate its own absences, let alone
--- explain one. Writing 142 reasons into that would have been writing ~3 000
--- translated strings into configuration nothing could ever read, which is
--- precisely the objection the ratchet's own header raises against doing it.
---
--- So the fix was not "write the reasons". It was to ship the absences: the
--- generator now emits an `M.unavailable` table alongside `M.features`, and this
--- file asserts that table is present, non-empty, and split correctly into the
--- explained and the silent halves.
---
--- WHY THE SILENT COUNT IS ASSERTED TOO:
--- a report that listed only the explained absences would look complete while
--- hiding the ones that matter most. The number the user needs is "139 of these
--- have no recorded reason", and it can only be produced by counting both.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The first reason written through the chain end to end, on 2026-08-03. Pinned
-- by name: if it disappears, the chain has an explained half of zero and every
-- assertion about the explained path below becomes vacuous.
local FIRST_EXPLAINED_PATH = "script.alt_gr_is_kana_remap"

-- Floor on the absences macOS has. It was 104 when the table was first emitted;
-- a table that collapsed to a handful would make the split assertions pass
-- while measuring nothing.
local MIN_UNAVAILABLE = 50




helpers.describe("manifest_reader: platform coverage", function()

	helpers.it("ships the features this platform does NOT have", function()
		local Manifest = helpers.load_with_stubs("infra.manifest_reader")
		local gaps = Manifest.unavailable()
		helpers.assert_true(type(gaps) == "table",
			"the generated manifest must carry an M.unavailable table")
		helpers.assert_true(#gaps >= MIN_UNAVAILABLE,
			"only " .. tostring(#gaps) .. " absence(s) shipped, floor " .. tostring(MIN_UNAVAILABLE)
			.. " — M.features is filtered to this platform, so without this table the driver cannot "
			.. "know a feature exists at all and reason_key is unreadable by construction")
	end)

	helpers.it("every absence names a path and the platforms that do have it", function()
		local Manifest = helpers.load_with_stubs("infra.manifest_reader")
		for _, gap in ipairs(Manifest.unavailable()) do
			helpers.assert_true(type(gap.path) == "string" and gap.path ~= "",
				"an absence with no path cannot be reported to anyone")
			helpers.assert_true(type(gap.platforms) == "table" and #gap.platforms > 0,
				gap.path .. ": an absence must say which platforms DO have the feature — "
				.. "'unavailable here' with no 'available there' is not an explanation")
			local claims_this = false
			for _, p in ipairs(gap.platforms) do
				if p == "hs" then claims_this = true end
			end
			helpers.assert_true(not claims_this,
				gap.path .. " is listed as unavailable on macOS while its platforms list includes "
				.. "\"hs\" — the generator's filter and this table disagree, so one of them is wrong")
		end
	end)

	helpers.it("splits the absences into explained and silent", function()
		local Manifest = helpers.load_with_stubs("infra.manifest_reader")
		local explained, silent = Manifest.coverage_gaps()
		helpers.assert_true(type(explained) == "table" and type(silent) == "table",
			"coverage_gaps() must return both halves")
		helpers.assert_eq(#explained + #silent, #Manifest.unavailable(),
			"every absence belongs to exactly one half — a gap that falls through both is one the "
			.. "report never shows and never counts")
		helpers.assert_true(#silent > 0,
			"the silent half is empty, which would mean all 139 remaining restrictions were "
			.. "explained at once. If that is genuinely true, lower the ratchet baseline in "
			.. "test-platform-restrictions-explained.cjs — do not let this assertion be the "
			.. "only thing that noticed")
	end)

	helpers.it("every explained absence carries a non-empty reason key", function()
		local Manifest = helpers.load_with_stubs("infra.manifest_reader")
		local explained = Manifest.coverage_gaps()
		helpers.assert_true(#explained > 0,
			"no absence carries a reason_key. The consumer chain would then be complete and "
			.. "unexercised — the state it was built to leave behind")
		for _, gap in ipairs(explained) do
			helpers.assert_true(type(gap.reason_key) == "string" and gap.reason_key ~= "",
				gap.path .. " is in the explained half with no reason_key — the split is wrong")
		end
	end)

	helpers.it("the first reason written through the chain is still there", function()
		local Manifest = helpers.load_with_stubs("infra.manifest_reader")
		local explained = Manifest.coverage_gaps()
		local found = nil
		for _, gap in ipairs(explained) do
			if gap.path == FIRST_EXPLAINED_PATH then found = gap end
		end
		helpers.assert_true(found ~= nil,
			FIRST_EXPLAINED_PATH .. " no longer reports a reason. It is the one entry that proves "
			.. "the generator → reader → healthcheck chain carries a real value end to end; without "
			.. "it every assertion above holds on an empty set")
		helpers.assert_eq(found.reason_key, "platform_reason.alt_gr_is_kana_remap")
	end)

end)
