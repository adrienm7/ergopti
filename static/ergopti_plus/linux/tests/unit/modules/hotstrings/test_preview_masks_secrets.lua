--- tests/unit/modules/hotstrings/test_preview_masks_secrets.lua

--- ==============================================================================
--- MODULE: The Bubble Hides What the Injector Types in Full
--- DESCRIPTION:
--- Partial masking of financial and identity values in the preview bubble, and
--- the boundary that makes it safe: the row is masked, the expansion is not.
---
--- THE TWO FAILURES THIS SITS BETWEEN:
--- Mask too late and the user's IBAN is on screen in a screen share. Mask too
--- early and the driver TYPES a row of bullets into their bank's form — which is
--- worse, because it is silent, it corrupts real data, and it looks like the
--- feature working. The seam is the preview ROW; the injector reads a different
--- field from a different call, and section 3 pins that they cannot converge.
---
--- WHY THE CLASSIFICATION IS SHARED AND NOT LOCAL:
--- The same four secret fields were already hand-repeated at four sites — the
--- three drivers and the shared prefix-count helper — with no gate between them.
--- Four hand-written lists is four chances for one to drift, and the drift is
--- silent in the worst direction: a field that stops being classified as a
--- secret does not error, it starts being shown. So the answer lives in
--- _shared/modules/personal_info/fields.toml and the vectors below are the
--- shared corpus, replayed unmodified.
---
--- WHY THE PHONE NUMBER IS A TEST CASE AND NOT AN OMISSION:
--- It is declared `masked = false` on purpose. A vector whose expected value
--- EQUALS its input is the only kind that proves the field table is consulted at
--- all, rather than everything being masked and the corpus agreeing by accident.
--- ==============================================================================

local helpers = require("tests.helpers")

local Mask = helpers.load_module("personal_info.mask")

--- The shared corpus, decoded.
--- @return table
local function corpus()
	local root = helpers.driver_root and helpers.driver_root() or "."
	local path = root .. "/../_shared/tests/corpus/personal_info/mask_vectors.json"
	local fh = io.open(path, "r")
	if not fh then
		fh = io.open("../_shared/tests/corpus/personal_info/mask_vectors.json", "r")
	end
	helpers.assert_true(fh ~= nil,
		"the shared corpus must be readable — a masking test that cannot find its "
			.. "vectors asserts nothing at all")
	local raw = fh:read("*a")
	fh:close()
	local json = require("json")
	local ok, decoded = pcall(json.decode, raw)
	helpers.assert_true(ok and type(decoded) == "table", "the corpus must decode")
	return decoded
end





-- =================================================================
-- =================================================================
-- ======= 1/ The shared vectors ===================================
-- =================================================================
-- =================================================================

helpers.describe("preview masking: the cross-driver corpus", function()

	helpers.it("produces the expected string for every vector", function()
		local data = corpus()
		local vectors = data.vectors or {}
		helpers.assert_true(#vectors >= 12,
			"the corpus must actually carry vectors; a decode that yielded an empty "
				.. "list would make this loop pass while checking nothing")

		-- The declaration the driver ships, not the corpus's copy of it: the point
		-- is that the TOML and the vectors agree, and reading the corpus's own
		-- policy back would compare it with itself.
		local Fields = helpers.load_module("infra.personal_info_fields")

		for _, vector in ipairs(vectors) do
			local got = Fields.for_preview(vector.value, vector.field)
			helpers.assert_eq(got, vector.expected,
				string.format("vector '%s' — %s", tostring(vector.id), tostring(vector.why)))
		end
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ Failing closed =======================================
-- =================================================================
-- =================================================================

helpers.describe("preview masking: what happens when it cannot decide", function()

	helpers.it("masks everything when the policy is unusable", function()
		local out = Mask.mask("FR76 3000 4000 5000", nil)
		helpers.assert_true(not out:find("FR", 1, true),
			"a caller with a broken policy must get everything hidden rather than "
				.. "everything shown — the whole point of this module is that a "
				.. "mistake does not end in a secret on screen")
	end)

	helpers.it("masks a field nobody classified", function()
		local Fields = helpers.load_module("infra.personal_info_fields")
		helpers.assert_true(Fields.is_masked("some_field_added_next_year"),
			"the opposite default reveals whatever a future edit forgets to declare")
		helpers.assert_true(Fields.is_masked(nil),
			"and a value whose provenance was lost on the way to the row is exactly "
				.. "the case where it must not be assumed public")
	end)

	helpers.it("leaves a declared-public field alone", function()
		local Fields = helpers.load_module("infra.personal_info_fields")
		helpers.assert_true(not Fields.is_masked("phone_number"),
			"masked = false is a decision, and a classifier that ignored it would "
				.. "make the whole declaration decorative")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 3/ The injector still types the truth ===================
-- =================================================================
-- =================================================================

helpers.describe("preview masking: display only", function()

	helpers.it("tags every prefix mapping with the field it came from", function()
		local Prefix = helpers.load_module("modules.dynamic_hotstrings.prefix_rules")
		local built = Prefix.build({
			phone_number           = "0750399576",
			phone_number_clean     = "07 50 39 95 76",
			social_security_number = "1 99 99 99 999 999 99",
			iban                   = "FR76 3000 4000 5000 6000 7000 123",
		}, nil)

		helpers.assert_true(#built > 0, "the fixture must produce mappings")
		for _, mapping in ipairs(built) do
			helpers.assert_true(type(mapping.field) == "string",
				"a mapping with no field is one the bubble has to assume is a secret, "
					.. "so an untagged prefix would be masked even when its field is "
					.. "declared public — the phone number would disappear behind dots")
		end
	end)

	helpers.it("keeps the replacement itself in clear", function()
		local Prefix = helpers.load_module("modules.dynamic_hotstrings.prefix_rules")
		local iban = "FR76 3000 4000 5000 6000 7000 123"
		for _, mapping in ipairs(Prefix.build({ iban = iban }, nil)) do
			helpers.assert_true(not mapping.replacement:find("•", 1, true),
				"masking is a DISPLAY concern. A mask applied to the mapping would "
					.. "make the driver type a row of bullets into the user's bank "
					.. "form — silent, destructive, and indistinguishable from the "
					.. "feature working")
		end
	end)

	helpers.it("carries the field through the engine to the preview", function()
		-- The link that makes the two halves meet. The shared engine's candidate
		-- record was strictly poorer than its firing record — it dropped even
		-- is_private — so the layer that puts a value on screen had no way to know
		-- it was a secret.
		local Engine = helpers.load_module("hotstring_engine")
		local engine = Engine.new()
		-- A plain lowercase trigger on purpose: what is under test is that `field`
		-- survives the engine, not that an IBAN prefix matches — mixing the two
		-- would make a matching subtlety look like a lost tag.
		engine:load_mappings({
			{ trigger = "btw", replacement = "FR76 3000 4000 5000 6000 7000 123",
				auto_expand = true, group = "dynamichotstrings", section = "ibanprefixes",
				field = "iban", is_private = true },
		})
		for _, char in ipairs({ "b", "t", "w" }) do
			engine:on_char(char, { is_terminator = false, terminator_consumed = false })
		end

		local found = nil
		for _, candidate in ipairs(engine:candidates(5) or {}) do
			if candidate.trigger == "btw" then found = candidate end
		end
		helpers.assert_not_nil(found, "the engine must offer the mapping as a candidate")
		helpers.assert_eq(found.field, "iban",
			"without the field the preview cannot ask the declaration anything, and "
				.. "a value that arrives unattributed is masked whole — which is safe "
				.. "but wrong for the fields declared public")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 4/ The cross-driver corpus ==============================
-- =================================================================
-- =================================================================

--- The bubble must read identically on all three drivers, and that is a claim
--- about output, not about intent — macOS and Linux render it in Lua, Windows in
--- AutoHotkey. _shared/modules/personal_info/preview_vectors.toml is where the
--- answer lives; this driver proves it satisfies it, and the other two are held
--- to the same file rather than to a description of it.
---
--- A value that reads differently on two machines is not cosmetic: the bubble
--- exists so a user can confirm WHICH of their values is about to be typed, and
--- a reveal on one platform and a blank on another are not the same check.
helpers.describe("preview masking: the shared cross-driver vectors", function()

	local Paths = require("infra.paths")
	local Reader = require("toml_codec")
	local Fields = helpers.load_module("infra.personal_info_fields")

	--- Reads the vector file through the same resolver the driver uses.
	--- @return table Array of { field, input, preview, why }.
	local function load_vectors()
		local path = Paths.shared("modules/personal_info/preview_vectors.toml")
		helpers.assert_not_nil(path, "the shared tree must resolve or this asserts nothing")
		local handle = io.open(path, "r")
		helpers.assert_not_nil(handle, "preview_vectors.toml must be readable: " .. tostring(path))
		local body = handle:read("*a")
		handle:close()
		local ok, parsed = pcall(Reader.decode, body)
		helpers.assert_true(ok and type(parsed) == "table",
			"preview_vectors.toml must parse: " .. tostring(parsed))
		return parsed.vectors or {}
	end

	helpers.it("renders every shared vector exactly", function()
		local vectors = load_vectors()
		-- A floor, because a corpus that silently loads zero rows is a test that
		-- asserts nothing while reporting success.
		helpers.assert_true(#vectors >= 15,
			"the shared corpus must carry its vectors — got " .. #vectors)

		for _, v in ipairs(vectors) do
			local got = Fields.for_preview(v.input, v.field)
			helpers.assert_eq(got, v.preview, string.format(
				"field=%s input=%s%s", tostring(v.field), tostring(v.input),
				v.why and ("  (" .. v.why .. ")") or ""))
		end
	end)

	helpers.it("covers both masked and public fields, and the missing-field case", function()
		local vectors = load_vectors()
		local masked, public, no_field = 0, 0, 0
		for _, v in ipairs(vectors) do
			if v.field == nil then
				no_field = no_field + 1
			elseif v.preview == v.input then
				public = public + 1
			else
				masked = masked + 1
			end
		end
		-- Each arm separately: a corpus of nothing but IBANs would pass the
		-- assertion above while proving nothing about the fields declared public,
		-- and it is the public ones a wrong port is most likely to get wrong.
		helpers.assert_true(masked >= 6, "vectors that must be masked: " .. masked)
		helpers.assert_true(public >= 4, "vectors that must be shown in full: " .. public)
		helpers.assert_true(no_field >= 1,
			"a vector with no field at all — the case that must mask rather than "
				.. "assume public — is missing")
	end)

end)





-- ===============================================================
-- ===============================================================
-- ======= 4/ A multi-field row masks each part separately =======
-- ===============================================================
-- ===============================================================

--- The @-combo rows carry parallel `parts` and `fields` arrays instead of one
--- value and one field name, because a combo mixes classifications: "@ti" is a
--- phone number (declared public) followed by an IBAN (declared secret). Masking
--- the joined string would force ONE verdict on the row, and whichever verdict
--- won would be wrong for the other half — either the IBAN on screen, or a phone
--- number the user cannot read back to check it is the right one.
---
--- Reached through build_rows rather than by calling the internal masker, so what
--- is pinned is what the renderer receives.
helpers.describe("preview: a multi-field @-combo row", function()

	local Preview = helpers.load_module("ui.tooltip.preview")

	--- The single row build_rows produces for one candidate.
	local function row_for(candidate)
		local rows = Preview.build_rows({ candidate }, {})
		helpers.assert_eq(#rows, 1, "one candidate makes one row")
		return rows[1]
	end

	helpers.it("hides the secret part and shows the public one, in the same row", function()
		local row = row_for({
			trigger     = "@ti\\",
			replacement = "0606060606 ⇥ FR7630006000011234567890189",
			parts       = { "0606060606", "FR7630006000011234567890189" },
			fields      = { "phone_number", "iban" },
			group       = "personal",
			fires       = true,
		})
		helpers.assert_contains(row.text, "0606060606",
			"phone_number is declared masked = false — hiding it helps nobody and "
				.. "removes the only way the user can tell which number is about to be typed")
		helpers.assert_true(not row.text:find("7630006000011234567890189", 1, true),
			"while the IBAN in the SAME row must be hidden: one verdict for the whole "
				.. "row is wrong whichever way it falls")
		helpers.assert_contains(row.text, "•",
			"and the hiding is the shared mask character, not an empty string")
	end)

	helpers.it("keeps the two parts separated by the tab glyph", function()
		local row = row_for({
			trigger     = "@np\\",
			replacement = "Dupont ⇥ Marie",
			parts       = { "Dupont", "Marie" },
			fields      = { "last_name", "first_name" },
			group       = "personal",
			fires       = true,
		})
		helpers.assert_contains(row.text, "⇥",
			"the expansion fires a real Tab keystroke between fields, which is invisible "
				.. "in a bubble — U+21E5 stands in for it, the same glyph macOS and Windows show")
		helpers.assert_contains(row.text, "Dupont", "first part")
		helpers.assert_contains(row.text, "Marie", "second part")
	end)

	helpers.it("still masks an ordinary single-field row", function()
		local row = row_for({
			trigger     = "@i\\",
			replacement = "FR7630006000011234567890189",
			field       = "iban",
			group       = "personal",
			fires       = true,
		})
		helpers.assert_true(not row.text:find("7630006000011234567890189", 1, true),
			"the single-field path must keep working — a new branch for combos that "
				.. "shadowed the old one would unmask every @-tag row")
	end)

	helpers.it("leaves a row that declares no field at all untouched", function()
		local row = row_for({
			trigger     = "pex\\",
			replacement = "par exemple",
			group       = "magickey",
			fires       = true,
		})
		helpers.assert_contains(row.text, "par exemple",
			"an ordinary hotstring has no field, is in no declaration, and must pass "
				.. "through — masking everything protects nothing and hides the feature")
	end)

end)
