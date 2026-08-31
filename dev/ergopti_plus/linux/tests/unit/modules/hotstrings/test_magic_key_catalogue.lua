--- tests/unit/modules/hotstrings/test_magic_key_catalogue.lua

--- ==============================================================================
--- MODULE: Magic-Key Catalogue Substitution
--- DESCRIPTION:
--- Proves that the configured magic key replaces the shipped suffix across the
--- complete static catalogue, both on live reload and on a fresh manager.
--- ==============================================================================

local helpers = require("tests.helpers")

local function ends_with(value, suffix)
	return type(value) == "string" and type(suffix) == "string"
		and suffix ~= "" and #value >= #suffix and value:sub(-#suffix) == suffix
end

local function pack(name)
	return require("infra.paths").shared("modules/hotstrings/" .. name)
end

helpers.describe("magic key: static catalogue ownership", function()

	helpers.it("moves every shipped magic-key trigger and leaves every other trigger intact", function()
		local Loader = helpers.load_module("modules.hotstrings.loader")
		local paths = { pack("magickey.toml"), pack("sfbsreduction.toml") }
		local canonical = Loader.load_catalogue(paths).mappings
		local custom = Loader.load_catalogue(paths, {
			magic_key = "§",
			canonical_magic_key = "★",
		}).mappings

		helpers.assert_eq(#custom, #canonical, "substitution must neither add nor drop mappings")
		local moved = 0
		for index, before in ipairs(canonical) do
			local after = custom[index]
			if ends_with(before.trigger, "★") then
				moved = moved + 1
				local base = before.trigger:sub(1, #before.trigger - #"★")
				helpers.assert_eq(after.trigger, base .. "§",
					"owned trigger did not move at catalogue index " .. index)
				helpers.assert_eq(ends_with(after.trigger, "★"), false,
					"an owned trigger remained on the shipped key")
			else
				helpers.assert_eq(after.trigger, before.trigger,
					"a trigger with no magic-key suffix must stay byte-identical")
			end
		end
		helpers.assert_true(moved >= 900,
			"the full shipped pack must be covered, not a small fixture; moved " .. moved)
	end)

	helpers.it("applies a new key on reload and after a fresh config-manager start", function()
		local temporary = os.tmpname()
		os.remove(temporary)
		local path = temporary .. "_magic_key.toml"
		local file = assert(io.open(path, "w"))
		file:write([=[
[[probe]]
"alpha★" = { output = "expanded", is_word = false, auto_expand = true }
"plain" = { output = "unchanged", is_word = false, auto_expand = true }
]=])
		file:close()

		local ok, err = pcall(function()
			local loaded = nil
			local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
			Config.init({ load_mappings = function(_, mappings) loaded = mappings end }, path, nil)
			helpers.assert_true(Config.set_magic_key("§", "★"))
			Config.load_all()
			helpers.assert_eq(loaded[1].trigger, "alpha§", "startup must use the configured key")
			helpers.assert_eq(loaded[2].trigger, "plain", "unowned triggers must stay unchanged")

			helpers.assert_true(Config.set_magic_key("◆", "★"))
			Config.reload()
			helpers.assert_eq(loaded[1].trigger, "alpha◆", "live reload must retire the previous key")
			helpers.assert_eq(ends_with(loaded[1].trigger, "★"), false)
			helpers.assert_eq(ends_with(loaded[1].trigger, "§"), false)

			loaded = nil
			Config = helpers.load_module("modules.hotstrings.hotstrings_config")
			Config.init({ load_mappings = function(_, mappings) loaded = mappings end }, path, nil)
			helpers.assert_true(Config.set_magic_key("§", "★"))
			Config.load_all()
			helpers.assert_eq(loaded[1].trigger, "alpha§",
				"a fresh process must reconstruct the same configured catalogue")
		end)

		os.remove(path)
		if not ok then error(err, 0) end
	end)

end)
