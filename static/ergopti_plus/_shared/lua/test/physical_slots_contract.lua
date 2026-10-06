--- _shared/lua/test/physical_slots_contract.lua

--- Replays independent physical-slot vectors through both driver unit gates.
--- Native registry metadata is checked separately from physical delivery proof.
--- @param helpers table Actual driver assertion and discovery helpers.
--- @param Model table Shared physical-slot implementation.
--- @param fixture table { registry, corpus, json, manifest }.
return function(helpers, Model, fixture)
	local registry, corpus, Json = fixture.registry, fixture.corpus, fixture.json
	local before = Json.encode(registry)
	local owner = Model.new(registry)
	assert(corpus.version == 1 and #corpus.valid == 16 and #corpus.invalid_slots > 30,
		"physical-slot corpus must retain its independent positive and refusal inventory")

	helpers.describe("user physical slots: shared contract", function()
		for _, case in ipairs(corpus.valid) do
			helpers.it("(physical-slots) canonical entry " .. case.slot, function()
				local parsed = owner.parse(case.slot)
				helpers.assert_type(parsed, "table")
				helpers.assert_eq(parsed.slot, case.slot)
				helpers.assert_eq(parsed.code, case.code)
				helpers.assert_eq(parsed.mods, case.mods)
				helpers.assert_eq(owner.encode(case.code, case.mods), case.slot)
				helpers.assert_true(owner.owns(case.slot))
				helpers.assert_eq(owner.match({ physical = true, code = case.code, mods = case.mods }), case.slot)
			end)
		end
		for index, slot in ipairs(corpus.invalid_slots) do
			helpers.it("(physical-slots) rejects independent invalid entry " .. tostring(index), function()
				local parsed, reason = owner.parse(slot)
				helpers.assert_nil(parsed, slot)
				helpers.assert_type(reason, "string", slot)
				helpers.assert_eq(owner.owns(slot), false, slot)
			end)
		end
		for _, code in ipairs(corpus.arbitrary_codes) do
			helpers.it("(physical-slots) permits arbitrary registry position " .. code, function()
				helpers.assert_eq(owner.encode(code, {}), "physical_none_" .. code)
				helpers.assert_eq(owner.parse("physical_none_" .. code).code, code)
			end)
		end
		for index, case in ipairs(corpus.native) do
			helpers.it("(physical-slots) native metadata fact " .. tostring(index), function()
				local identity, reason = owner.native_code(case.slot, case.field, case.form)
				helpers.assert_eq(identity, case.identity)
				helpers.assert_eq(reason, case.reason)
			end)
		end

		helpers.it("(physical-slots) preserves neutral absence in the existing dynamic scope", function()
			helpers.assert_eq(fixture.manifest.default_for("shortcuts.keyboard.physical_none_KeyJ"), "none")
			helpers.assert_eq(fixture.manifest.recommended_for("shortcuts.keyboard.physical_none_KeyJ"), "none")
			helpers.assert_nil(owner.assignments)
			helpers.assert_eq(Json.encode(registry), before, "construction and lookups must not rewrite metadata")
		end)

		helpers.it("(physical-slots) malformed namespace stays distinct from unrelated keys", function()
			helpers.assert_true(Model.is_namespace("physical_invalid"))
			helpers.assert_true(owner.is_namespace("physical_"))
			helpers.assert_eq(owner.owns("physical_invalid"), false)
			for _, value in ipairs({ "cmd_j", "future_key", "physical", "Physical_none_KeyJ", 37, true }) do
				helpers.assert_eq(Model.is_namespace(value), false)
			end
			helpers.assert_eq(Model.is_namespace(nil), false)
		end)

		helpers.it("(physical-slots) encodes modifier order without accepting aliases or sparse arrays", function()
			helpers.assert_eq(owner.encode("KeyJ", { "super", "shift", "ctrl", "alt" }),
				"physical_ctrl_alt_shift_super_KeyJ")
			helpers.assert_eq(owner.encode("KeyJ", { ctrl = false, alt = false, shift = false, super = false }),
				"physical_none_KeyJ")
			local refused = {
				{ "ctrl", "ctrl" }, { [2] = "ctrl" }, { [1] = "ctrl", [3] = "alt" },
				{ [1] = "ctrl", shift = true }, { ctrl = 1 }, { ctrl = "true" },
				{ meta = true }, { cmd = true }, { altgr = true }, { fn = false },
				setmetatable({ ctrl = true }, {}),
			}
			for _, modifiers in ipairs(refused) do
				local slot, reason = owner.encode("KeyJ", modifiers)
				helpers.assert_nil(slot)
				helpers.assert_eq(reason, "invalid_modifiers")
			end
			helpers.assert_nil(owner.encode("KeyJ", "ctrl"))
		end)

		helpers.it("(physical-slots) requires exact physical evidence and never resolves logical text", function()
			local refused = {
				{ physical = false, code = "KeyJ", mods = {} },
				{ physical = 1, code = "KeyJ", mods = {} },
				{ code = "KeyJ", mods = {} }, { physical = true, code = "KeyJ" },
				{ physical = true, key = "j", mods = {} },
				{ physical = true, code = 36, key = "j", mods = {} },
				{ physical = true, code = "KeyJ", mods = { altgr = true } },
				{ physical = true, code = "KeyJ", mods = { "ctrl" } },
			}
			for _, detail in ipairs(refused) do helpers.assert_nil(owner.match(detail)) end
			helpers.assert_nil(owner.match(nil))
			helpers.assert_nil(owner.match("KeyJ"))
			helpers.assert_eq(owner.match({ physical = true, code = "KeyJ", mods = { ctrl = true, shift = true } }),
				"physical_ctrl_shift_KeyJ", "extra modifiers name a different exact entry")
		end)

		helpers.it("(physical-slots) returns detached descriptors and snapshots registry identities", function()
			local mutable = Json.decode(Json.encode(registry))
			local snapshot = Model.new(mutable)
			mutable.keys.KeyJ.hs = 14
			mutable.keys.Backquote.macos_iso.hs = 50
			mutable.keys.KeyJ = nil
			helpers.assert_eq(snapshot.native_code("physical_none_KeyJ", "hs", "ansi"), 38)
			helpers.assert_eq(snapshot.native_code("physical_none_Backquote", "hs", "iso"), 10)
			local parsed = snapshot.parse("physical_ctrl_KeyJ")
			parsed.code, parsed.mods.shift = "KeyE", true
			helpers.assert_eq(snapshot.parse("physical_ctrl_KeyJ").mods, { ctrl = true })
			local modifiers = Model.modifiers()
			modifiers[1] = "unowned"
			helpers.assert_eq(Model.modifiers(), { "ctrl", "alt", "shift", "super" })
			local candidates = snapshot.candidates("hs", "ansi")
			candidates[1] = "unowned"
			helpers.assert_eq(snapshot.candidates("hs", "ansi")[1] == "unowned", false)
		end)

		helpers.it("(physical-slots) refuses absent native identities without another-platform fallback", function()
			local missing = Json.decode(Json.encode(registry))
			missing.keys.KeyJ.hs = nil
			local unavailable = Model.new(missing)
			local native, reason = unavailable.native_code("physical_none_KeyJ", "hs", "ansi")
			helpers.assert_nil(native)
			helpers.assert_eq(reason, "native_key_unavailable")
			helpers.assert_eq(unavailable.native_code("physical_none_KeyJ", "evdev", "ansi"), 36)
			for _, code in ipairs(unavailable.candidates("hs", "ansi")) do helpers.assert_eq(code == "KeyJ", false) end
			helpers.assert_nil(owner.candidates("logical", "ansi"))
			helpers.assert_nil(owner.candidates("hs", "unknown"))
		end)

		helpers.it("(physical-slots) capture resolves only a unique native physical identity", function()
			helpers.assert_eq(owner.code_for(38, "hs", "ansi"), "KeyJ")
			helpers.assert_eq(owner.code_for(36, "evdev", "ansi"), "KeyJ")
			helpers.assert_eq(owner.code_for("SC024", "ahk", "ansi"), "KeyJ")
			helpers.assert_eq(owner.code_for(10, "hs", "iso"), "Backquote")
			helpers.assert_eq(owner.code_for(50, "hs", "iso"), "IntlBackslash")
			helpers.assert_nil(owner.code_for("j", "hs", "ansi"))
			helpers.assert_nil(owner.code_for(nil, "hs", "ansi"))
			local ambiguous = Json.decode(Json.encode(registry))
			ambiguous.keys.KeyE.hs = 38
			local code, reason = Model.new(ambiguous).code_for(38, "hs", "ansi")
			helpers.assert_nil(code)
			helpers.assert_eq(reason, "ambiguous_native_key")
		end)

		helpers.it("(physical-slots) every candidate retains its exact canonical registry identity", function()
			for _, field in ipairs({ "hs", "evdev", "ahk" }) do
				for _, form in ipairs(registry.forms) do
					local candidates, previous = owner.candidates(field, form), nil
					helpers.assert_true(#candidates > 0)
					for _, code in ipairs(candidates) do
						local record = registry.keys[code]
						helpers.assert_eq(record.kind, "key")
						helpers.assert_true(previous == nil or previous < code, "candidate order is stable and unique")
						previous = code
						local expected = field == "hs" and record["macos_" .. form]
							and record["macos_" .. form].hs or record[field]
						helpers.assert_eq(owner.native_code(owner.encode(code), field, form), expected)
					end
				end
			end
			helpers.assert_eq(Json.encode(registry), before)
		end)

		helpers.it("(physical-slots) board-form ambiguity stays unavailable without an event receipt", function()
			helpers.assert_eq(owner.stable_native_code("physical_none_KeyJ", "hs"), 38)
			helpers.assert_eq(owner.stable_native_code("physical_none_KeyJ", "evdev"), 36)
			for _, slot in ipairs({ "physical_none_Backquote", "physical_none_IntlBackslash" }) do
				local native, reason = owner.stable_native_code(slot, "hs")
				helpers.assert_nil(native)
				helpers.assert_eq(reason, "keyboard_form_required")
			end
			helpers.assert_eq(owner.key_group("physical_none_AudioVolumeUp"), "media")
			helpers.assert_nil(owner.key_group("physical_none_unknown"))
		end)

		helpers.it("(physical-slots) rejects malformed registry construction before exposing an owner", function()
			local mutations = {
				function(candidate) candidate.schema_version = 2 end,
				function(candidate) candidate.forms = {} end,
				function(candidate) candidate.forms = { [2] = "iso" } end,
				function(candidate) candidate.forms = { "ansi", "ansi" } end,
				function(candidate) candidate.forms = { ansi = true } end,
				function(candidate) candidate.keys.KeyJ.kind = "logical" end,
				function(candidate) candidate.keys.KeyJ.hs = "j" end,
				function(candidate) candidate.keys.KeyJ.evdev = 0 end,
				function(candidate) candidate.keys.KeyJ.ahk = "SC024\n" end,
				function(candidate) candidate.keys.KeyJ.geometry = "ansi" end,
				function(candidate) candidate.keys.Backquote.macos_iso.hs = "grave" end,
			}
			for _, mutate in ipairs(mutations) do
				local candidate = Json.decode(Json.encode(registry))
				mutate(candidate)
				local accepted = pcall(Model.new, candidate)
				helpers.assert_eq(accepted, false)
			end
			helpers.assert_eq(pcall(Model.new, nil), false)
		end)
	end)
end
