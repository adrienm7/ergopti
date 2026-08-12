--- tests/unit/modules/keymap/test_preview_masks_secrets.lua

--- ==============================================================================
--- MODULE: The Bubble Hides What the Driver Types in Full
--- DESCRIPTION:
--- Partial masking of financial and identity values in the preview tooltip, and
--- the boundary that makes it safe: the row is masked, the expansion is not.
---
--- THE TWO FAILURES THIS SITS BETWEEN:
--- Mask too late and the user's IBAN is on screen in a screen share. Mask too
--- early and the driver TYPES a row of bullets into their bank's form — which is
--- worse, because it is silent, it corrupts real data, and it looks like the
--- feature working. The seam is the preview ROW; the registry entry the expander
--- reads is a different field reached by a different call, and sections 4 and 5
--- pin that the two cannot converge.
---
--- WHY THE CLASSIFICATION IS SHARED AND NOT LOCAL:
--- The same four secret fields were already hand-repeated across the drivers with
--- no gate between them, and the drift such a list produces is silent in the
--- worst direction: a field that stops being classified as a secret does not
--- error, it starts being shown. So the answer lives in
--- _shared/modules/personal_info/fields.toml, and section 1 replays the shared
--- corpus at _shared/modules/personal_info/preview_vectors.toml unmodified — the
--- same file Linux and Windows are held to, so "identical on all three drivers"
--- is measured rather than intended.
---
--- WHY THE PHONE NUMBER IS A TEST CASE AND NOT AN OMISSION:
--- It is declared `masked = false` on purpose. A vector whose expected value
--- EQUALS its input is the only kind that proves the field table is consulted at
--- all, rather than everything being masked and the corpus agreeing by accident.
---
--- WHY macOS NEEDS MORE CASES THAN LINUX:
--- Linux's preview reads the shared engine's candidate records, which already
--- carry `field`. macOS builds its own match records from its own registry, so
--- the provenance had to be threaded through four layers — the rules engine names
--- the field, the registry stores it, the bridge copies it into the match, and
--- only then can the row ask the declaration. Sections 3 and 5 drive the real
--- production paths end to end, because a helper that masks correctly while
--- nothing calls it is the failure this shape invites.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The corpus's headline IBAN and what the policy says the bubble may show of it.
-- Restated here rather than looked up so a row assertion reads as an answer, not
-- as a second call to the code under test.
local IBAN_FULL   = "FR7630006000011234567890189"
local IBAN_MASKED = "FR•••••••••••••••••••••0189"

-- A phone number, declared `masked = false`. The control case: a driver that
-- masked everything would satisfy every IBAN assertion in this file.
local PHONE_FULL = "+33 6 12 34 56 78"

-- An ordinary hotstring: no personal_info field, so nothing to ask about.
local PLAIN_REPL = "by the way"

-- The bullet the policy masks with (U+2022). Named so an assertion can say
-- "no masking happened here" without embedding the glyph in three places.
local MASK_CHAR = "•"

-- The floor the shared corpus must clear. Sixteen vectors ship today; a decode
-- that silently yielded an empty list would otherwise make section 1 iterate
-- nothing and report success.
local MIN_VECTORS = 15





-- ====================================
-- ====================================
-- ======= 1/ The shared corpus =======
-- ====================================
-- ====================================

--- The bubble must read identically on all three drivers, and that is a claim
--- about output, not about intent. This driver proves it satisfies the shared
--- file; the other two are held to the same file rather than to a description
--- of it.
helpers.describe("preview masking: the shared cross-driver vectors", function()

	-- Loaded through the stub loader so infra.paths resolves the shared tree the
	-- same way in CI as on a dev checkout, and so the cached declaration is this
	-- test's, not one an earlier file happened to warm.
	local Fields = helpers.load_with_stubs("infra.personal_info_fields")
	local Paths  = require("infra.paths")
	local Codec  = require("infra.toml.codec")
	Fields._reset()

	--- Reads the vector file through the same resolver the driver uses.
	--- @return table Array of { field, input, preview, why }.
	local function load_vectors()
		local path = Paths.shared("modules/personal_info/preview_vectors.toml")
		helpers.assert_not_nil(path, "the shared tree must resolve or this asserts nothing")
		local handle = io.open(path, "r")
		helpers.assert_not_nil(handle, "preview_vectors.toml must be readable: " .. tostring(path))
		local body = handle:read("*a")
		handle:close()
		-- Codec.decode, NOT infra.toml.reader.parse: the reader is the
		-- hotstrings-format parser and returns a well-formed EMPTY result on this
		-- file instead of erroring, which would load zero vectors and report green.
		local ok, parsed = pcall(Codec.decode, body)
		helpers.assert_true(ok and type(parsed) == "table",
			"preview_vectors.toml must parse: " .. tostring(parsed))
		return parsed.vectors or {}
	end

	helpers.it("renders every shared vector exactly", function()
		local vectors = load_vectors()
		-- A floor, because a corpus that silently loads zero rows is a test that
		-- asserts nothing while reporting success.
		helpers.assert_true(#vectors >= MIN_VECTORS,
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





-- =================================
-- =================================
-- ======= 2/ Failing closed =======
-- =================================
-- =================================

helpers.describe("preview masking: what happens when it cannot decide", function()

	local Fields = helpers.load_with_stubs("infra.personal_info_fields")
	local Mask   = require("personal_info.mask")
	Fields._reset()

	helpers.it("masks everything when the policy is unusable", function()
		local out = Mask.mask(IBAN_FULL, nil)
		helpers.assert_true(not out:find("FR", 1, true),
			"a caller with a broken policy must get everything hidden rather than "
				.. "everything shown — the whole point of the shared masker is that a "
				.. "mistake does not end in a secret on screen")
	end)

	helpers.it("masks a field nobody classified", function()
		helpers.assert_true(Fields.is_masked("some_field_added_next_year"),
			"the opposite default reveals whatever a future edit forgets to declare")
		helpers.assert_true(Fields.is_masked(nil),
			"and a value whose provenance was lost on the way to the row is exactly "
				.. "the case where it must not be assumed public")
	end)

	helpers.it("leaves a declared-public field alone", function()
		helpers.assert_true(not Fields.is_masked("phone_number"),
			"masked = false is a decision, and a classifier that ignored it would "
				.. "make the whole declaration decorative")
	end)

end)





-- ====================================
-- ====================================
-- ======= 3/ The row on screen =======
-- ====================================
-- ====================================

--- Drives the REAL update_preview over a REAL registry and returns the rows the
--- tooltip was asked to draw.
---
--- Three traps are already documented in this directory and all three produce a
--- vacuous green rather than a failure:
---   1. The render is deferred through TimerScheduler, so nothing is drawn until
---      the scheduled timer fires.
---   2. TimerScheduler captures `hs` at REQUIRE time, so a stale instance
---      schedules into a previous stub's timer list that __fire_all never sees.
---   3. The real renderer throws under the hs stub while measuring styled text,
---      and update_preview draws before it records — so leaving the tooltip alone
---      makes the function never reach the row builder at all.
--- The floor assertion in each case below is what makes all three visible.
--- @param register function Called with the Registry to add the mappings under test.
--- @param buf string The buffer to preview.
--- @return table rows, table state
local function capture_rows(register, buf)
	-- Everything the bridge pulls in is loaded FIRST, then the bridge: it captures
	-- its dependencies as upvalues at require time.
	local State = helpers.load_with_stubs("modules.keymap.state")

	-- Dropped so it is re-required under the fresh stub the bridge load installs;
	-- see trap 2 above. Registry and Expander are stateful singletons too: leaving
	-- either cached makes the resolver answer for a previous test's CoreState.
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["modules.keymap.registry"] = nil
	package.loaded["modules.keymap.terminators"] = nil
	package.loaded["modules.keymap.expander"] = nil
	package.loaded["modules.keymap.llm_bridge"] = nil
	local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")

	-- The registry instance the BRIDGE resolved, not a separately loaded one: the
	-- bridge captured its Registry upvalue at require time, and a second instance
	-- would be initialised over a state the bridge never reads.
	local Registry = package.loaded["modules.keymap.registry"]
	helpers.assert_not_nil(Registry, "the bridge must have loaded the registry")
	local Expander = package.loaded["modules.keymap.expander"]
	helpers.assert_not_nil(Expander, "the bridge must have loaded the expander")

	-- The REAL tooltip with exactly one method neutralised (trap 3). Patched
	-- rather than replaced: a hand-written stub has to guess the whole surface.
	local tooltip = require("ui.tooltip")
	local real_show_stacked = tooltip.show_stacked
	local captured = nil
	tooltip.show_stacked = function(rows) captured = rows; return true end

	local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
	state.preview_providers         = {}
	state.is_repeat_feature_enabled = function() return false end
	Registry.init(state)
	register(Registry)
	Registry.sort_mappings()

	Bridge.init(state, { preview_star_enabled = true, preview_autocorrect_enabled = true })
	Expander.init(state, Registry, Bridge)
	Bridge.set_preview_star_enabled(true)
	Bridge.set_preview_autocorrect_enabled(true)

	-- NOT pcall'd. A throw means the function never reached the row builder, and
	-- every assertion below would then be measuring the throw.
	Bridge.update_preview(buf)
	hs.timer.__fire_all()
	tooltip.show_stacked = real_show_stacked

	return captured or {}, state
end

--- Concatenates every row's text, for absence assertions.
--- @param rows table
--- @return string
local function row_text(rows)
	local parts = {}
	for _, row in ipairs(rows) do parts[#parts + 1] = tostring(row.text) end
	return table.concat(parts, "\n")
end

helpers.describe("preview rows: a declared secret is partially masked on screen", function()

	helpers.it("shows an IBAN with only its head and tail", function()
		local rows = capture_rows(function(Registry)
			Registry.add("FR7630★", IBAN_FULL,
				{ auto_expand = true, is_case_sensitive = true, is_private = true, field = "iban" })
		end, "FR7630")

		helpers.assert_true(#rows > 0,
			"no row reached the tooltip, so this assertion inspected nothing — see the "
				.. "three traps documented on capture_rows")
		helpers.assert_eq(rows[1].text, IBAN_MASKED,
			"the bubble exists so the user can confirm WHICH value is about to be "
				.. "typed, and the last four characters are enough for that — the rest "
				.. "is what a shoulder or a screen share must not get")
	end)

	helpers.it("leaves a declared-public personal_info field in full", function()
		local rows = capture_rows(function(Registry)
			Registry.add("0612★", PHONE_FULL,
				{ auto_expand = true, is_case_sensitive = true, is_private = true, field = "phone_number" })
		end, "0612")

		helpers.assert_true(#rows > 0, "no row reached the tooltip")
		helpers.assert_eq(rows[1].text, PHONE_FULL,
			"phone_number is declared masked = false by the maintainer's decision. "
				.. "Without this case a driver that bulleted EVERYTHING would satisfy "
				.. "every other assertion in this file")
	end)

	helpers.it("leaves an ordinary hotstring untouched", function()
		local rows = capture_rows(function(Registry)
			Registry.add("btw★", PLAIN_REPL, { auto_expand = true })
		end, "btw")

		helpers.assert_true(#rows > 0, "no row reached the tooltip")
		helpers.assert_true(not row_text(rows):find(MASK_CHAR, 1, true),
			"a mapping with no personal_info field is not in the declaration at all. "
				.. "The shared masker masks an unknown field on purpose, so the row "
				.. "builder must gate on the field being present first — omit that gate "
				.. "and every autocorrection on the machine becomes a row of dots")
		helpers.assert_contains(row_text(rows), PLAIN_REPL,
			"and the ordinary replacement must still be shown")
	end)

end)





-- ==================================
-- ==================================
-- ======= 4/ The typed value =======
-- ==================================
-- ==================================

helpers.describe("preview masking: display only", function()

	helpers.it("keeps the registry entry the expander types from in clear", function()
		local rows, state = capture_rows(function(Registry)
			Registry.add("FR7630★", IBAN_FULL,
				{ auto_expand = true, is_case_sensitive = true, is_private = true, field = "iban" })
		end, "FR7630")

		helpers.assert_eq(rows[1] and rows[1].text, IBAN_MASKED,
			"the row must be masked, or the comparison below proves nothing")

		local entry = nil
		for _, mapping in ipairs(state.mappings) do
			if mapping.trigger == "FR7630★" then entry = mapping end
		end
		helpers.assert_not_nil(entry, "the mapping must be registered")
		helpers.assert_eq(entry.repl, IBAN_FULL,
			"masking is a DISPLAY concern. The expander reads this entry through an "
				.. "entirely different call, and a mask that reached it would make the "
				.. "driver type a row of bullets into the user's bank form — silent, "
				.. "destructive, and indistinguishable from the feature working")
		helpers.assert_eq(entry.plain_repl, IBAN_FULL,
			"the precomputed plain form is what the expansion emits, so it must be "
				.. "just as untouched as the raw one")
		helpers.assert_eq(entry.field, "iban",
			"and the provenance must survive registration, or the row above has "
				.. "nothing to ask the declaration about")
	end)

	helpers.it("tags every prefix mapping with the field it came from", function()
		local RE = helpers.load_with_stubs("modules.dynamic_hotstrings.rules_engine")

		local added = {}
		local fake_km = {
			add = function(trigger, replacement, opts)
				added[#added + 1] = { trigger = trigger, replacement = replacement, opts = opts }
			end,
			is_section_enabled        = function() return true end,
			set_group_context         = function() end,
			sort_mappings             = function() end,
			register_lua_group        = function() end,
			set_post_load_hook        = function() end,
			register_interceptor      = function() end,
			register_preview_provider = function() end,
			registry_transaction      = function(_, mutation) return mutation() == true end,
		}

		RE.inject_data({
			phone_number           = "0612345678",
			phone_number_clean     = "+33612345678",
			social_security_number = "1 85 05 78 006 084 36",
			iban                   = "FR76 3000 6000 0112 3456 7890 189",
		}, "★")
		RE.start(fake_km)

		helpers.assert_true(#added > 0, "the fixture must produce prefix mappings")
		for _, call in ipairs(added) do
			helpers.assert_true(type(call.opts) == "table" and type(call.opts.field) == "string",
				"a mapping with no field is one the bubble has to assume is a secret, "
					.. "so an untagged prefix would be masked even when its field is "
					.. "declared public — the phone number would disappear behind dots. "
					.. "Untagged trigger: " .. tostring(call.trigger))
			helpers.assert_true(not call.replacement:find(MASK_CHAR, 1, true),
				"the registered replacement is what gets TYPED and must never carry a "
					.. "mask: " .. tostring(call.trigger))
		end

		-- The exact trap the shared-table shape invites: both phone fields are
		-- registered from the same block, so one `opts.field = …` written once
		-- would tag the spaced variant as the raw one. Both are declared public
		-- today, which is precisely what would keep that mistake invisible until
		-- one of them was reclassified.
		local seen = {}
		for _, call in ipairs(added) do
			seen[call.opts.field] = (seen[call.opts.field] or 0) + 1
			if call.replacement == "+33612345678" then
				helpers.assert_eq(call.opts.field, "phone_number_clean",
					"the spaced phone variant is its own declared field")
			end
		end
		helpers.assert_true(seen["phone_number"] ~= nil, "the raw phone field must be named")
		helpers.assert_true(seen["phone_number_clean"] ~= nil, "and so must its spaced sibling")
		helpers.assert_true(seen["social_security_number"] ~= nil, "and the SSN")
		helpers.assert_true(seen["iban"] ~= nil, "and the IBAN")
	end)

end)





-- =====================================
-- =====================================
-- ======= 5/ The @-tag provider =======
-- =====================================
-- =====================================

--- The second on-screen sink, and the one Linux has no counterpart for: its
--- `manager.preview` has no production caller, so an @-combo never reaches a
--- bubble there. On macOS it does, and a single combo can resolve to SEVERAL
--- fields at once — which is why the masking happens part by part, where each
--- part still knows which field produced it.
helpers.describe("preview masking: the @-tag provider", function()

	--- Boots personal_info alone against a fake keymap, capturing both the
	--- interceptor (what gets typed) and the preview provider (what is shown).
	--- @return function provider, function interceptor, table rec
	local function boot()
		package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
		local PI  = helpers.load_with_stubs("modules.dynamic_hotstrings.personal_info")

		local rec = { injects = {} }
		local provider, interceptor
		local fake_km = {
			get_trigger_char          = function() return "★" end,
			is_section_enabled        = function() return true end,
			is_group_enabled          = function() return true end,
			register_lua_group        = function() end,
			set_post_load_hook        = function() end,
			set_group_context         = function() end,
			sort_mappings             = function() end,
			add                       = function() end,
			register_preview_provider = function(fn) provider = fn end,
			register_interceptor      = function(fn) interceptor = fn end,
			inject_dynamic            = function(deletes, text)
				rec.injects[#rec.injects + 1] = { deletes = deletes, text = text }
				return true
			end,
		}

		local path = os.tmpname()
		local handle = assert(io.open(path, "w"))
		handle:write(string.format(
			'[info]\niban = "%s"\nfirst_name = "Adrien"\n\n[letters]\ni = "iban"\np = "first_name"\n',
			IBAN_FULL))
		handle:close()
		PI.start("", fake_km, path)
		PI.enable()
		os.remove(path)

		helpers.assert_type(provider, "function", "personal_info must register a preview provider")
		helpers.assert_type(interceptor, "function", "personal_info must register an interceptor")
		return provider, interceptor, rec
	end

	--- @param char string
	--- @return table Fake keyDown event.
	local function key(char)
		return {
			getFlags      = function() return { cmd = false, ctrl = false } end,
			getKeyCode    = function() return 0 end,
			getCharacters = function() return char end,
		}
	end

	helpers.it("masks the IBAN an @-combo would insert", function()
		local provider = boot()
		helpers.assert_eq(provider("@i"), IBAN_MASKED,
			"typing @i★ inserts the IBAN, so the bubble that announces it is exactly "
				.. "the surface a screen share captures")
	end)

	helpers.it("masks part by part, so a public field in the same combo survives", function()
		local provider = boot()
		helpers.assert_eq(provider("@ip"), IBAN_MASKED .. " ⇥ " .. "Adrien",
			"one combo can resolve to several fields that are not classified alike. "
				.. "Masking the joined string would have no field to ask about and "
				.. "would have to hide the name too")
	end)

	helpers.it("still injects the complete value", function()
		local _, interceptor, rec = boot()

		interceptor(key("@"), "")
		interceptor(key("i"), "@")
		interceptor(key("★"), "@i")

		helpers.assert_eq(#rec.injects, 1, "the ordinary expansion path must still fire")
		helpers.assert_eq(rec.injects[1].text, IBAN_FULL,
			"the provider and the injector both read the resolved values, and only "
				.. "the provider may mask them. A mask that crossed over would type "
				.. "bullets into whatever form the user was filling in")
	end)

end)
