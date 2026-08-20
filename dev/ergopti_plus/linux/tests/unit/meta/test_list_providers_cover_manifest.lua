--- tests/unit/meta/test_list_providers_cover_manifest.lua

--- ==============================================================================
--- MODULE: Every List The Manifest Promises Linux Has A Provider
--- DESCRIPTION:
--- A `list` row is the one manifest type whose contents the driver supplies:
--- the renderer draws it and asks the driver for the rows. A list declared for
--- this platform with no provider registered is SKIPPED with a warning, so the
--- submenu simply loses a section.
---
--- WHY THAT IS WORSE THAN A CRASH:
--- Nothing errors, the menu opens, and the missing section is visible only to
--- somebody comparing against another platform side by side. The renderer\'s own
--- comment says as much where it skips: "Silence here is a menu section that
--- vanishes."
---
--- THE DIRECTION THIS GUARDS:
--- Declaring a row for a platform is cheap and satisfying; wiring the provider
--- is the work. This makes the declaration fail until the work is done, which is
--- the only order that keeps the manifest a description rather than a wish.
--- ==============================================================================

local helpers = require("tests.helpers")

local Paths = helpers.load_module("infra.paths")

--- Every `list` id the built manifest declares for this platform.
--- @return table Array of { menu = string, id = string }.
local function declared_lists()
	local root = Paths.shared_root()
	helpers.assert_not_nil(root, "the shared tree must be findable")
	local handle = assert(io.open(root .. "/modules/menu/menu_manifest.json", "r"))
	local body = handle:read("*a")
	handle:close()

	local Json = helpers.load_module("json")
	local manifest = Json.decode(body)
	helpers.assert_eq(type(manifest), "table", "the built menu manifest must decode")

	local out = {}
	for menu_key, rows in pairs(manifest) do
		if type(rows) == "table" and #rows > 0 then
			for _, row in ipairs(rows) do
				if type(row) == "table" and row.type == "list" and type(row.id) == "string" then
					-- No `platforms` means every platform, which is how the renderer
					-- reads it too.
					local allowed = true
					if type(row.platforms) == "table" then
						allowed = false
						for _, name in ipairs(row.platforms) do
							if name == "linux" then allowed = true end
						end
					end
					if allowed then out[#out + 1] = { menu = menu_key, id = row.id } end
				end
			end
		end
	end
	return out
end

--- Every list id the menu builder registers a provider for.
--- @return table Set of ids.
local function registered_providers()
	local handle = assert(io.open(helpers.driver_root() .. "/ui/menu/menu_builder.lua", "r"))
	local source = handle:read("*a")
	handle:close()
	local found = {}
	-- Deliberately broad: a bracketed string key assigned anything. The file
	-- registers providers three ways — inside a table literal, as
	-- `providers["id"] = function`, and as `["id"] = rows` pointing at a named
	-- local — and a pattern narrow enough to tell them apart reported a provider
	-- that exists as missing the first time this ran.
	--
	-- Breadth costs precision in one direction only: an id used as a key for
	-- something that is NOT a provider would satisfy it. That is intersected with
	-- the declared LIST ids below, so it would take a dynamic handler and a list
	-- sharing one id, which the manifest does not do.
	for id in source:gmatch('%["([a-z0-9_]+)"%]%s*=') do found[id] = true end
	for id in source:gmatch('providers%.([a-z0-9_]+)%s*=') do found[id] = true end
	return found
end




-- =================================================================
-- =================================================================
-- ======= 1/ Coverage =============================================
-- =================================================================
-- =================================================================

helpers.describe("menu lists: what the manifest promises this platform", function()

	helpers.it("registers a provider for every list declared for linux", function()
		local lists = declared_lists()
		local providers = registered_providers()

		helpers.assert_true(#lists > 0,
			"no list rows were found for this platform — the manifest moved or the "
				.. "scan broke, and a scan that finds nothing agrees with any driver")

		local missing = {}
		for _, entry in ipairs(lists) do
			if not providers[entry.id] then
				missing[#missing + 1] = entry.menu .. "." .. entry.id
			end
		end
		table.sort(missing)
		helpers.assert_eq(#missing, 0,
			"declared for linux with no provider: " .. table.concat(missing, ", ")
				.. ". The renderer skips such a row with a warning, so the submenu "
				.. "loses a whole section and nothing errors — visible only to "
				.. "somebody comparing against another platform side by side.")
	end)

	helpers.it("includes the configurable keyboard slots", function()
		-- Named explicitly as well as covered by the sweep above, because this row
		-- was restricted away from linux for a year with an accurate reason, and
		-- the sweep alone would go quiet again the moment somebody restricted it
		-- back rather than fixing whatever broke.
		local found = false
		for _, entry in ipairs(declared_lists()) do
			if entry.id == "keyboard_slots" then found = true end
		end
		helpers.assert_true(found,
			"keyboard_slots is the row this driver could not answer until it had a "
				.. "chord capture and an assignment store; it has both now")
	end)

end)
