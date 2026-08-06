--- tests/unit/modules/hotstrings/test_personal_info_combo_resolver.lua
---
--- ==============================================================================
--- MODULE: Regression — Linux registered only SINGLE-letter @-tags
---         (linux-multi-letter-combos-absent)
--- DESCRIPTION:
--- `manager.lua` filtered its registration loop with `if #letter == 1`, so on
--- Linux the @-family stopped at one letter. @np, @npd, @npdt expanded to
--- nothing — not because a hand-written list was short, as on Windows, but
--- because no multi-letter combo existed at all. macOS has resolved them
--- dynamically all along (`resolve_combo`), and Windows now does too
--- (`HSE_TryPersonalInfoCombo`); Linux was the driver with the feature missing.
---
--- ROOT CAUSE ENCODED: the combos cannot be pre-registered. With thirteen alias
--- letters the space is 169 combinations at length two and 28 561 at length
--- four, which is why Windows shipped a sample of thirty-one and why that sample
--- was missing the two the user reached for. Resolving at fire time is the only
--- shape that covers all of them, and it makes ORDER significant for free.
---
--- These tests drive the REAL manager against a fixture personal_info.toml, so
--- they exercise the parse, the letters map and the resolver together — the
--- three places a combo can go missing.
--- ==============================================================================

local helpers = require("tests.helpers")
local dh      = helpers.load_module("modules.dynamic_hotstrings.manager")

-- Real-shaped, nobody's data. The IBAN is distinctive enough that a substring
-- search cannot match it by accident; the email carries no metacharacter because
-- Linux types through the layout planner rather than a Send parser.
local FIXTURE = [[
[info]
last_name = "Dupont"
first_name = "Marie"
date_of_birth = "01/02/1990"
phone_number = "0606060606"
email_address = "marie.tag@example.org"
iban = "FR7630006000011234567890189"

[letters]
n = "last_name"
p = "first_name"
d = "date_of_birth"
t = "phone_number"
m = "email_address"
i = "iban"
]]

--- Writes the fixture, inits the manager against it, deletes it.
--- The file has to be real: init() opens it, and a stubbed parser would test the
--- test rather than the parse.
local function with_fixture(body)
	local tmp_dir = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
	local path = tmp_dir:gsub("\\", "/") .. "/ergopti_combo_resolver.toml"
	local fh = assert(io.open(path, "w"))
	fh:write(FIXTURE)
	fh:close()
	local ok, err = pcall(function()
		dh.init({ trigger_char = "\\", personal_info_path = path })
		body()
	end)
	os.remove(path)
	if not ok then error(err, 0) end
end

--- The values a tag resolves to, joined, so an assertion reads like the row.
local function joined(tag)
	return table.concat(dh.resolve_combo_values(tag), "|")
end

helpers.describe("personal-info @-combo resolver", function()

	-- ==========================================================================
	-- 1. The lengths Linux never had
	-- ==========================================================================

	helpers.it("resolves combos of every length, not just one letter", function()
		with_fixture(function()
			helpers.assert_eq(joined("p"), "Marie",
				"one letter — the only length that worked before")
			helpers.assert_eq(joined("np"), "Dupont|Marie",
				"two letters: `if #letter == 1` refused to register these, so @np expanded to nothing")
			helpers.assert_eq(joined("npd"), "Dupont|Marie|01/02/1990",
				"three")
			helpers.assert_eq(joined("npdt"), "Dupont|Marie|01/02/1990|0606060606",
				"four — the case reported on Windows, and one Linux never had at all")
		end)
	end)

	helpers.it("letter order decides field order", function()
		with_fixture(function()
			helpers.assert_eq(joined("np"), "Dupont|Marie", "@np is surname then forename")
			helpers.assert_eq(joined("pn"), "Marie|Dupont", "@pn is the reverse")
			helpers.assert_true(joined("np") ~= joined("pn"),
				"the two must differ: a resolver treating the letters as a set would put the values in the wrong form fields")
		end)
	end)

	helpers.it("a repeated letter is a legitimate combo", function()
		with_fixture(function()
			helpers.assert_eq(joined("nn"), "Dupont|Dupont",
				"@nn is the same value twice — a valid thing to want, and not a typo to reject")
		end)
	end)

	-- ==========================================================================
	-- 2. What it must refuse
	-- ==========================================================================

	helpers.it("one unknown letter declines the whole combo", function()
		with_fixture(function()
			helpers.assert_eq(joined("npz"), "",
				"'z' aliases no field — declining whole is deliberate. macOS SKIPS what it cannot resolve, which silently drops a field and shifts every later value into the wrong box")
			helpers.assert_eq(joined("z"), "", "and a single unknown letter is not a combo")
		end)
	end)

	helpers.it("a field the user left blank declines the whole combo", function()
		local tmp_dir = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
		local path = tmp_dir:gsub("\\", "/") .. "/ergopti_combo_blank.toml"
		local fh = assert(io.open(path, "w"))
		fh:write('[info]\nlast_name = "Dupont"\nfirst_name = ""\n\n[letters]\nn = "last_name"\np = "first_name"\n')
		fh:close()
		local ok, err = pcall(function()
			dh.init({ trigger_char = "\\", personal_info_path = path })
			helpers.assert_eq(table.concat(dh.resolve_combo_values("np"), "|"), "",
				"a blank field must decline the combo: expanding the rest shifts every later value up one box, which is worse than nothing happening")
			helpers.assert_eq(table.concat(dh.resolve_combo_values("n"), "|"), "Dupont",
				"while the field that IS filled still resolves on its own — the guard must narrow, not close")
		end)
		os.remove(path)
		if not ok then error(err, 0) end
	end)

	-- ==========================================================================
	-- 3. Finding the tag in a buffer
	-- ==========================================================================

	helpers.it("reads the tag off the end of the buffer", function()
		with_fixture(function()
			helpers.assert_eq(dh.trailing_tag("@np"), "np", "the plain case")
			helpers.assert_eq(dh.trailing_tag("bonjour @np"), "np",
				"a tag mid-sentence is still a tag — the buffer holds everything since the last reset, so this is the ordinary case rather than the exception")
			helpers.assert_eq(dh.trailing_tag("@"), "", "'@' alone is not a tag yet")
			helpers.assert_eq(dh.trailing_tag(""), "", "an empty buffer resolves to nothing")
			helpers.assert_eq(dh.trailing_tag("np"), "", "no '@' at all is not a tag")
			helpers.assert_eq(dh.trailing_tag("@np dt"), "",
				"a separator AFTER the @ ends the tag: the '@' belongs to an earlier word and the letters at the end are not attached to it")
			helpers.assert_eq(dh.trailing_tag("@np2"), "",
				"a digit is not a tag character either — [letters] maps letters")
		end)
	end)

	helpers.it("an email address in the buffer is not read as a tag", function()
		with_fixture(function()
			helpers.assert_eq(dh.trailing_tag("marie.tag@example"), "example",
				"the letters after the @ do form a candidate tag — the resolver is what refuses it")
			helpers.assert_eq(joined("example"), "",
				"and it does refuse: 'x' and 'a' alias nothing, so nothing expands mid-address")
		end)
	end)

	-- ==========================================================================
	-- 4. The preview rows, which are the same answer
	-- ==========================================================================

	helpers.it("offers a preview row for a resolvable multi-letter combo", function()
		with_fixture(function()
			local rows = dh.preview_candidates("@np")
			helpers.assert_eq(#rows, 1, "one row for @np — the bubble showed none at all before, for the whole @ family")
			helpers.assert_eq(rows[1].trigger, "@np\\",
				"the row names the sequence the magic key will complete")
			helpers.assert_eq(#rows[1].parts, 2, "two parts, so each can be masked against its own field")
			helpers.assert_eq(rows[1].fields[1], "last_name", "first part's field")
			helpers.assert_eq(rows[1].fields[2], "first_name", "second part's field")
			helpers.assert_eq(rows[1].group, "personal",
				"and it wears the personal colour, as the same row does on the other two drivers")
		end)
	end)

	helpers.it("offers nothing the resolver would refuse", function()
		with_fixture(function()
			helpers.assert_eq(#dh.preview_candidates("@npz"), 0,
				"a bubble offering an expansion the magic key will not deliver is worse than no bubble")
			helpers.assert_eq(#dh.preview_candidates("@n"), 0,
				"and a single-letter tag is a REGISTERED rule that reaches the bubble by the ordinary path — offering it here too would draw the row twice")
			helpers.assert_eq(#dh.preview_candidates("bonjour"), 0,
				"ordinary typing offers nothing")
		end)
	end)

	helpers.it("preview and fire resolve the same fields", function()
		with_fixture(function()
			local rows = dh.preview_candidates("@npdt")
			helpers.assert_eq(#rows, 1, "the row exists")
			-- The property that matters: one function answers both questions, so the
			-- bubble cannot promise a different expansion from the one that fires.
			local fired = dh.resolve_combo("npdt")
			helpers.assert_eq(#rows[1].fields, #fired,
				"the bubble and the expansion must agree on how many fields there are")
			for index, field in ipairs(fired) do
				helpers.assert_eq(rows[1].fields[index], field,
					"and on which field is in which position")
			end
		end)
	end)

end)





-- ===============================================================
-- ===============================================================
-- ======= 5/ The privacy flag every sink downstream reads =======
-- ===============================================================
-- ===============================================================

--- The event `on_trigger` hands back is what the daemon forwards to
--- `keylogger.record_hotstring`, whose seventh parameter decides whether the
--- per-character synthetic record keeps the text or a placeholder. The daemon
--- passed nothing there for the whole life of this driver, so every @-tag
--- expansion — the single-letter ones included — persisted its resolved value
--- one character at a time. Fixing the caller is only half of it: the event has
--- to CARRY the answer, and only the rule's section knows it.
helpers.describe("dynamic expansion events carry the privacy verdict", function()

	helpers.it("a personal_info rule reports itself private", function()
		with_fixture(function()
			local fired, event = dh.on_trigger("@p\\", "\\")
			-- No escape hatch for "the injector could not run": the uinput channel
			-- is absent here and inject() swallows that, so on_trigger still returns
			-- its event. A test that shrugged when nothing fired would have reported
			-- green for the whole year this flag was missing.
			helpers.assert_true(fired, "'@p\\\\' must fire — the fixture maps 'p' to a filled field")
			helpers.assert_true(event ~= nil, "a fired expansion returns its event")
			helpers.assert_true(event.is_private == true,
				"'@p' resolves first_name out of personal_info.toml, so the keylogger must "
					.. "receive a placeholder per character rather than the value")
		end)
	end)

	helpers.it("a date rule does not, because a date is not a secret", function()
		with_fixture(function()
			local fired, event = dh.on_trigger("dt\\", "\\")
			helpers.assert_true(fired, "'dt\\\\' is a registered date rule and must fire")
			helpers.assert_true(event ~= nil, "a fired expansion returns its event")
			helpers.assert_true(event.is_private ~= true,
				"marking everything private protects nothing and would blank the dates out "
					.. "of the metrics, which is a metrics bug traded for no privacy gain")
		end)
	end)

	helpers.it("the verdict is derived from the section, not from the value", function()
		with_fixture(function()
			-- Source-level, and deliberately so: the two behavioural cases above
			-- cannot run to completion without a uinput channel, and a contract this
			-- quiet — a seventh argument nobody passed for a year — needs a guard
			-- that does not depend on the harness having a display.
			local path = helpers.driver_root() .. "/modules/dynamic_hotstrings/manager.lua"
			local fh = assert(io.open(path, "r"), "cannot open manager.lua")
			local src = fh:read("*a")
			fh:close()
			helpers.assert_contains(src, "is_private = (match.rule.section == PERSONAL_SECTION)",
				"the registered-rule path must set is_private from the SECTION: the resolver "
					.. "has already run by then and its output is just a string, so nothing else "
					.. "downstream can tell an IBAN from a date")
			helpers.assert_contains(src, "is_private = true",
				"and the multi-letter combo path must set it unconditionally — every field it "
					.. "can reach comes out of personal_info.toml")
		end)
	end)

	helpers.it("the daemon forwards the flag it is given", function()
		local path = helpers.driver_root() .. "/ergopti_hotstrings.lua"
		local fh = assert(io.open(path, "r"), "cannot open ergopti_hotstrings.lua")
		local src = fh:read("*a")
		fh:close()
		helpers.assert_contains(src, "dynamic_event.backspace_count, dynamic_event.is_private",
			"record_hotstring's seventh parameter is what redacts the synthetic record. "
				.. "The static path has always passed result.is_private; the dynamic path "
				.. "passed nothing, so the @-family wrote its values in full")
	end)

end)
