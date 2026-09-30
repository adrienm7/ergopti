--- _shared/lua/test/magic_key_source_contract.lua

--- Replays the shared physical magic-key decisions (keymap.magic_key_source)
--- against the real feature manifest entry and physical-key registry, with the
--- native id field of the driver running it, so both Lua suites pin the same
--- rules the Windows reader applies to [hotstrings] magic_key_source.
--- @param helpers table The driver's test helpers.
--- @param Source table The shared keymap.magic_key_source module.
--- @param fixture table { entry, registry, field, override? } as the driver builds its resolver.
return function(helpers, Source, fixture)
	local resolver = Source.new(fixture)

	helpers.describe("magic key source: shared decisions (" .. fixture.field .. ")", function()
		helpers.it("(magic-key-source) every manifest candidate names one native key and back", function()
			local codes = resolver.candidates()
			helpers.assert_eq(#codes, #fixture.entry.enum_values - 1, "every value but the automatic one is a key")
			for index, code in ipairs(codes) do
				helpers.assert_eq(code, fixture.entry.enum_values[index + 1], "candidates keep the manifest order")
				local native = resolver.native(code)
				helpers.assert_type(native, "number", code)
				helpers.assert_eq(resolver.code_for(native), code, "a pressed key names its value back: " .. code)
			end
			helpers.assert_nil(resolver.native(resolver.automatic), "the automatic value names no key")
			helpers.assert_eq(resolver.automatic, fixture.entry.default)
		end)

		helpers.it("(magic-key-source) reads an outdated value as automatic and says why", function()
			helpers.assert_eq(resolver.normalize(nil), resolver.automatic)
			helpers.assert_eq(resolver.normalize(resolver.automatic), resolver.automatic)
			helpers.assert_eq(resolver.normalize("KeyJ"), "KeyJ")
			for _, stale in ipairs({ "SC03B", "Space", "keyj", "F5", 46, true }) do
				local value, why = resolver.normalize(stale)
				helpers.assert_eq(value, resolver.automatic, tostring(stale))
				helpers.assert_type(why, "string", "an outdated value is reported: " .. tostring(stale))
			end
			helpers.assert_nil(resolver.code_for(-1), "a key no candidate names chooses nothing")
			local ok = pcall(resolver.native, "Space")
			helpers.assert_eq(ok, false, "the space bar is never the magic key")
		end)

		helpers.it("(magic-key-source) only a press without modifier is remapped", function()
			helpers.assert_true(Source.unmodified(nil))
			helpers.assert_true(Source.unmodified({}))
			helpers.assert_true(Source.unmodified({ capslock = true, fn = true }),
				"CapsLock and Fn keep the magic key, as on Windows")
			for _, name in ipairs({ "shift", "ctrl", "alt", "altgr", "meta", "cmd" }) do
				helpers.assert_eq(Source.unmodified({ [name] = true }), false, name .. " keeps the key's own character")
			end
		end)

		helpers.it("(magic-key-source) refuses a manifest or registry it cannot trust", function()
			local function refused(opts)
				return not pcall(Source.new, opts)
			end
			helpers.assert_true(refused({ entry = {}, registry = fixture.registry, field = fixture.field }))
			helpers.assert_true(refused({ entry = fixture.entry, registry = {}, field = fixture.field }))
			helpers.assert_true(refused({ entry = fixture.entry, registry = fixture.registry, field = "" }))
			helpers.assert_true(refused({ entry = { default = "auto", enum_values = { "auto", "KeyNope" } },
				registry = fixture.registry, field = fixture.field }), "a candidate absent from the registry")
			helpers.assert_true(refused({ entry = { default = "auto", enum_values = { "auto" } },
				registry = fixture.registry, field = fixture.field }), "no candidate at all")
			helpers.assert_true(refused({ entry = { default = "auto", enum_values = { "auto", "KeyA", "KeyB" } },
				registry = { keys = { KeyA = { [fixture.field] = 1 }, KeyB = { [fixture.field] = 1 } } },
				field = fixture.field }), "two values naming one key")
		end)
	end)
end
