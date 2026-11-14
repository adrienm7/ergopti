--- tests/unit/modules/hotstrings/engine/test_prefix_expansions.lua

--- ==============================================================================
--- MODULE: Typing the Start of Your IBAN Types the Rest of It
--- DESCRIPTION:
--- The three prefix families — phone, social-security number, IBAN — as they
--- reach the matcher, and what a user gets back when they type four digits.
---
--- WHAT WAS MISSING:
--- The manifest has declared these three since the manifest existed, Windows and
--- macOS both register and render them, and no Linux code registered a single
--- one. So the feature was three lines in a file that no code read, on the one
--- driver of the three.
---
--- WHY THEY ARE NOT DYNAMIC RULES:
--- The date families and the @-tags fire on the magic key: the user types `td★`
--- and the dynamic engine resolves it. A prefix has no trigger character —
--- typing `0750` IS the trigger — so these are ordinary auto-expanding mappings
--- handed to the ordinary matcher. That difference is why their switches cannot
--- be read at match time and the family has to be rebuilt instead, which is the
--- second half of what this file pins.
---
--- WHY THE THRESHOLDS ARE NOT ASSERTED AS LITERALS HERE:
--- `compute_prefix_counts` in the shared engine already owns them, and
--- `_shared/tests/corpus/dynamic_hotstrings/prefix_vectors.json` is the
--- cross-driver corpus that pins them for all three. Restating "4 digits" here
--- would be a second source that can disagree with the first. What is asserted
--- is that this driver builds what that count promises.
---
--- WHAT ONLY HARDWARE CAN SAY:
--- Whether the expansion arrives in the application. The matcher is pure and
--- decides everything above the injector; HARDWARE.md covers the rest.
--- ==============================================================================

local helpers = require("tests.helpers")
local restore_family_preferences = require("tests.support.dynamic_hotstrings_fixture").install()

local Prefix = helpers.load_module("modules.dynamic_hotstrings.prefix_rules")

-- The example file's own values, so a change to it that breaks the thresholds
-- shows up here rather than only on a user's machine.
local INFO = {
	phone_number           = "0750399576",
	phone_number_clean     = "07 50 39 95 76",
	social_security_number = "1 99 99 99 999 999 99",
	iban                   = "FR00 0000 0000 0000 0000 0000 000",
}

--- Every mapping built for one section.
--- @param section string
--- @param info table|nil
--- @return table
local function for_section(section, info)
	local out = {}
	for _, mapping in ipairs(Prefix.build(info or INFO, nil)) do
		if mapping.section == section then out[#out + 1] = mapping end
	end
	return out
end

--- The mapping whose trigger is exactly this, or nil.
--- @param trigger string
--- @return table|nil
local function by_trigger(trigger)
	for _, mapping in ipairs(Prefix.build(INFO, nil)) do
		if mapping.trigger == trigger then return mapping end
	end
	return nil
end




-- =================================================================
-- =================================================================
-- ======= 1/ What gets built ======================================
-- =================================================================
-- =================================================================

helpers.describe("prefix expansions: what is built", function()
	helpers.it("counts formatted phone characters rather than UTF-8 bytes", function()
		local phone = "06 12 34 56 78"
		local found = {}
		for _, mapping in ipairs(for_section("phoneprefixes", { phone_number_clean = phone })) do
			found[mapping.trigger] = mapping.replacement
		end
		helpers.assert_nil(found["06 "])
		helpers.assert_eq(found["06 12"], phone)
		helpers.assert_eq(#for_section("phoneprefixes", { phone_number_clean = "06 " }), 0)
	end)

	helpers.it("retains compact and spaced IBAN expansions for nonbreaking spaces", function()
		local iban = "FR76 12 3456"
		local mappings = for_section("ibanprefixes", { iban = iban })
		local found = {}
		for _, mapping in ipairs(mappings) do found[mapping.trigger] = mapping.replacement end
		helpers.assert_eq(found["FR7612"], "FR76123456")
		helpers.assert_eq(found["FR76 12"], iban)
	end)


	helpers.it("completes a phone number from its first four digits", function()
		local mapping = by_trigger("0750")
		helpers.assert_not_nil(mapping, "the plain four-digit prefix must be registered")
		helpers.assert_eq(mapping.replacement, INFO.phone_number,
			"and it must give back the whole number, which is the entire point")
		helpers.assert_true(mapping.auto_expand,
			"there is no terminator to wait for — the prefix IS the trigger")
	end)

	helpers.it("requires the configured magic key for the two-digit phone prefix", function()
		local engine = require("hotstrings.engine.matcher").new()
		engine:load_mappings(Prefix.build(INFO, nil, "\\"))
		helpers.assert_nil(engine:on_char("0"))
		helpers.assert_nil(engine:on_char("7"), "ordinary two-digit typing must not insert a phone number")
		local result = engine:on_char("\\")
		helpers.assert_not_nil(result)
		helpers.assert_eq(result.replacement, INFO.phone_number)
	end)

	helpers.it("offers the international form too", function()
		helpers.assert_not_nil(by_trigger("+3307"),
			"a number stored as 07… is also wanted as +3375…, which is the form "
				.. "every non-French form expects")
	end)

	helpers.it("international phone prefixes remove the national trunk zero", function()
		for _, trigger in ipairs({ "+3307", "+33750" }) do
			local mapping = by_trigger(trigger)
			helpers.assert_not_nil(mapping)
			helpers.assert_eq(mapping.replacement, "+33750399576")
		end
	end)

	helpers.it("keeps the first digit of an international phone without a trunk zero", function()
		local mappings = Prefix.build({ phone_number = "750399576" }, nil, "*")
		local triggers = {}
		for _, mapping in ipairs(mappings) do triggers[mapping.trigger] = mapping.replacement end
		helpers.assert_eq(triggers["+337503"], "+33750399576")
		helpers.assert_nil(triggers["+33503"], "an unrelated international number must not expand")
	end)

	helpers.it("gives back the form the user started typing", function()
		-- The shortest prefix holding five non-space characters, which for
		-- "1 99 99 99…" runs to the seventh byte. Taken from the shared helper
		-- rather than typed out, so this reads the same rule the build does.
		local Engine = require("hotstrings.engine.dynamic.core")
		local spaced = by_trigger(Engine.spaced_prefix(INFO.social_security_number, 5))
		helpers.assert_not_nil(spaced, "the spaced trigger must exist alongside the raw one")
		helpers.assert_eq(spaced.replacement, INFO.social_security_number,
			"a user who typed the spaces wants the spaces back, not the compact form")
		helpers.assert_eq(by_trigger("19999").replacement,
			(INFO.social_security_number:gsub("%s+", "")),
			"and one who typed none wants none")
	end)

	helpers.it("matches an IBAN whatever the casing", function()
		local mapping = by_trigger("FR0000")
		helpers.assert_not_nil(mapping)
		helpers.assert_true(not mapping.is_case_sensitive,
			"an IBAN is conventionally written in capitals and typed in whatever "
				.. "the hands produce — it is the one of the three that must fold case")
	end)

	helpers.it("builds as many mappings as the shared count promises", function()
		local counts = Prefix.counts(INFO)
		for section, promised in pairs(counts) do
			local built = #for_section(section)
			helpers.assert_true(built <= promised,
				section .. ": the menu count is what the other two drivers show, so "
					.. "building MORE than it promises means this driver disagrees with "
					.. "them about what the family contains")
			helpers.assert_true(built > 0,
				section .. ": a family the count says is non-empty must have mappings")
		end
	end)

	helpers.it("counts one trigger per family for values stored without spaces (PIS-001)", function()
		local compact = {
			phone_number           = "0750399576",
			phone_number_clean     = "07 50 39 95 76",
			social_security_number = "199999999999999",
			iban                   = "FR0000000000000000000000000",
		}
		local counts = Prefix.counts(compact)
		for _, section in ipairs({ "ssnprefixes", "ibanprefixes" }) do
			helpers.assert_eq(#for_section(section, compact), 1,
				section .. ": an unspaced value registers a single trigger")
			helpers.assert_eq(counts[section], 1,
				section .. ": the menu must announce exactly the triggers that exist")
		end
		local spaced = Prefix.counts(INFO)
		helpers.assert_eq(spaced.ssnprefixes, 2)
		helpers.assert_eq(spaced.ibanprefixes, 2)
	end)

	helpers.it("builds nothing at all from an empty personal_info", function()
		helpers.assert_eq(#Prefix.build({}, nil), 0,
			"a user who has filled in nothing gets no mappings, not mappings that "
				.. "expand to the empty string and silently eat their trigger")
	end)

	helpers.it("builds nothing from a value too short to identify", function()
		helpers.assert_eq(#for_section("phoneprefixes", { phone_number = "07" }) > 0, true,
			"two digits plus the magic key is an explicit request and stays allowed")
		helpers.assert_eq(#for_section("ssnprefixes", { social_security_number = "1 99" }), 0,
			"but four characters of an SSN would fire inside any date the user types")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ Every one of them is private =========================
-- =================================================================
-- =================================================================

helpers.describe("prefix expansions: privacy", function()

	helpers.it("marks every mapping private, without exception", function()
		local all = Prefix.build(INFO, nil)
		helpers.assert_true(#all > 0)
		for _, mapping in ipairs(all) do
			helpers.assert_true(mapping.is_private,
				"the replacement IS the secret and so is the trigger — the first six "
					.. "characters of an IBAN identify the account as surely as all "
					.. "twenty-seven. One unmarked mapping is one leak.")
		end
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ The switches =========================================
-- =================================================================
-- =================================================================

helpers.describe("prefix expansions: the switches", function()

	helpers.it("drops a family that is switched off", function()
		local gate = function(_group, section) return section ~= "ibanprefixes" end
		for _, mapping in ipairs(Prefix.build(INFO, gate)) do
			helpers.assert_true(mapping.section ~= "ibanprefixes",
				"the gate is read at BUILD time because the ordinary matcher these "
					.. "mappings live in knows nothing about dynamic families — so "
					.. "switching one off has to remove its mappings, not filter them")
		end
		helpers.assert_true(#for_section("phoneprefixes") > 0,
			"and only that family: the other two are untouched")
	end)

	helpers.it("takes a switched-off family out of the category's count", function()
		local Fakes = helpers.load_module("tests.fakes")
		local storage = Fakes.storage({})
		local previous_storage = package.loaded["core.fs.adapters.storage"]
		package.loaded["core.fs.adapters.storage"] = storage

		local path = os.tmpname()
		local fh = assert(io.open(path, "w"))
		fh:write("[info]\n")
		for key, value in pairs(INFO) do fh:write(key .. ' = "' .. value .. '"\n') end
		fh:close()

		local dh = helpers.load_module("modules.dynamic_hotstrings.manager")
		dh.init({ trigger_char = "\\", personal_info_path = path })
		dh.set_enabled(true)
		require("tests.support.dynamic_hotstrings_fixture").prefer_families(dh)

		local before = dh.active_count()
		dh.set_rule_enabled("phoneprefixes", false)
		local after = dh.active_count()

		package.loaded["core.fs.adapters.storage"] = previous_storage
		os.remove(path)

		helpers.assert_true(before > after,
			"the number beside the category is what the other two drivers show, and "
				.. "it counts what is LIVE — a count that does not move when a family "
				.. "is switched off says the switch did nothing")
		helpers.assert_eq(before - after, Prefix.counts(INFO).phoneprefixes,
			"and it moves by exactly that family's size, not by one")
	end)

	helpers.it("passes the configured magic key through the real prefix provider", function()
		local previous_storage = package.loaded["core.fs.adapters.storage"]
		package.loaded["core.fs.adapters.storage"] = helpers.load_module("tests.fakes").storage({})
		local path = os.tmpname()
		local file = assert(io.open(path, "w"))
		file:write('[info]\nphone_number = "0750399576"\n')
		file:close()
		local ok, err = pcall(function()
			local manager = helpers.load_module("modules.dynamic_hotstrings.manager")
			manager.init({ trigger_char = "\\", personal_info_path = path })
			manager.set_enabled(true)
			require("tests.support.dynamic_hotstrings_fixture").prefer_families(manager)
			local engine = require("hotstrings.engine.matcher").new()
			engine:load_mappings(manager.prefix_mappings())
			helpers.assert_nil(engine:on_char("0"))
			helpers.assert_nil(engine:on_char("7"))
			local result = engine:on_char("\\")
			helpers.assert_not_nil(result)
			helpers.assert_eq(result.replacement, INFO.phone_number)
		end)
		package.loaded["core.fs.adapters.storage"] = previous_storage
		os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("is pure, so the rebuild is the only moving part", function()
		local first  = Prefix.build(INFO, nil)
		local second = Prefix.build(INFO, nil)
		helpers.assert_eq(#first, #second)
		for index, mapping in ipairs(first) do
			helpers.assert_eq(mapping.trigger, second[index].trigger,
				"same input, same list — anything else makes a reload change what "
					.. "expands for reasons the user cannot see")
		end
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 4/ They reach the matcher ===============================
-- =================================================================
-- =================================================================

helpers.describe("prefix expansions: reaching the engine", function()

	--- Loads the catalogue with a provider supplying two mappings and returns
	--- what the engine ended up holding.
	--- @param provider function|nil
	--- @return table Array of mappings the engine was given.
	local function loaded_with(provider)
		local config = helpers.load_module("modules.hotstrings.hotstrings_config")
		local given, publications = {}, 0
		local engine = require("hotstrings.engine.matcher").new()
		local load = engine.load_mappings
		engine.load_mappings = function(self, mappings)
			given = mappings
			publications = publications + 1
			return load(self, mappings)
		end
		config.init(engine, nil, nil)
		if not config.is_section_checked("dynamichotstrings", "phoneprefixes") then
			helpers.assert_true(config.toggle_section("dynamichotstrings", "phoneprefixes"))
		end
		config.set_extra_mappings_provider(provider)
		local previous_publications = publications
		local _, committed, reason = config.load_all()
		config.set_extra_mappings_provider(nil)
		return given, committed, reason, publications - previous_publications
	end

	helpers.it("hands the provider's mappings to the engine", function()
		local given = loaded_with(function()
			return { { trigger = "0750", replacement = "0750399576",
				group = "dynamichotstrings", section = "phoneprefixes",
				auto_expand = true, is_private = true } }
		end)
		local found = false
		for _, mapping in ipairs(given) do
			if mapping.trigger == "0750" then found = true end
		end
		helpers.assert_true(found,
			"a mapping the provider builds and the engine never receives is the "
				.. "same as no feature at all — which is what this driver had")
	end)

	helpers.it("refuses replacement when the personal provider raises", function()
		local _, committed, reason, publications = loaded_with(function()
			error("personal_info.toml is unreadable")
		end)
		helpers.assert_eq(committed, false, "an incomplete replacement must be refused")
		helpers.assert_eq(publications, 0, "a failed personal source cannot replace the healthy engine")
		helpers.assert_true(reason:find("personal_info.toml is unreadable", 1, true) ~= nil,
			"the exact source failure must reach the caller")
	end)

	helpers.it("still registers them when the catalogue is empty", function()
		-- load_all() used to return the moment it found no hotstring TOML, which
		-- took the provider's mappings down with it. Two unrelated files — the
		-- hotstring catalogue and personal_info.toml — and one was punishing the
		-- other: a machine whose packs were missing or unreadable silently lost
		-- its phone, SSN and IBAN completions as well.
		local config = helpers.load_module("modules.hotstrings.hotstrings_config")
		local given = nil
		local engine = require("hotstrings.engine.matcher").new()
		local load = engine.load_mappings
		engine.load_mappings = function(self, mappings) given = mappings; return load(self, mappings) end
		config.init(engine, nil, nil)
		if not config.is_section_checked("dynamichotstrings", "phoneprefixes") then
			helpers.assert_true(config.toggle_section("dynamichotstrings", "phoneprefixes"))
		end
		config.set_extra_mappings_provider(function()
			return { { trigger = "0750", replacement = "0750399576",
				group = "dynamichotstrings", section = "phoneprefixes", auto_expand = true } }
		end)
		-- No catalogue: an explicit directory that holds nothing.
		config.load_all()
		config.set_extra_mappings_provider(nil)

		helpers.assert_not_nil(given, "the engine must be loaded at all")
		local found = false
		for _, mapping in ipairs(given) do
			if mapping.trigger == "0750" then found = true end
		end
		helpers.assert_true(found,
			"the personal expansions do not come from the catalogue and must not "
				.. "disappear with it")
	end)

end)

restore_family_preferences()
