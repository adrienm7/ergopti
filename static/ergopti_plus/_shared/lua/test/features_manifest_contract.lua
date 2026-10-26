--- _shared/lua/test/features_manifest_contract.lua

--- ==============================================================================
--- MODULE: Features Manifest Projection Contract
--- DESCRIPTION:
--- Replays the facts the macOS and Linux drivers rely on when they load the
--- manifest the two share (features.manifest_data, projected by
--- features.manifest): every row lands either in the driver's features or in
--- its unavailable list, a default or recommendation that differs per driver
--- resolves to the loading driver's value, the loaded tables belong to the
--- caller, and an unknown driver is refused. The node test
--- test-lua-features-manifest-projection.cjs separately compares the whole
--- loaded table with the generator's model.
--- ==============================================================================

local M = {}

local Manifest = require("features.manifest")
local Data = require("features.manifest_data")

--- Index of a manifest's features by path.
--- @param manifest table
--- @return table
local function by_path(manifest)
	local index = {}
	for _, entry in ipairs(manifest.features) do index[entry.path] = entry end
	return index
end

--- Registers the projection cases for one driver.
--- @param helpers table Driver assertions and case registration.
--- @param platform string "hs" or "linux".
--- @param reader table The driver's infra.manifest_reader.
function M.run(helpers, platform, reader)
	helpers.describe("features manifest projection (" .. platform .. ")", function()
		helpers.it("keeps every shared row exactly once, as a feature or as an absence", function()
			local manifest = Manifest.for_platform(platform)
			helpers.assert_eq(#manifest.features + #manifest.unavailable, #Data.features)
			for _, entry in ipairs(manifest.features) do
				local named = false
				for _, name in ipairs(entry.platforms) do named = named or name == platform end
				helpers.assert_true(named, entry.path .. " is kept only when it names " .. platform)
				helpers.assert_eq(entry.reason_key, nil, "a kept feature carries no absence reason")
			end
			for _, row in ipairs(manifest.unavailable) do
				for _, name in ipairs(row.platforms) do
					helpers.assert_true(name ~= platform, row.path .. " is absent only when it omits " .. platform)
				end
				helpers.assert_eq(type(row.reason_key), "string")
			end
		end)

		helpers.it("resolves a default or recommendation that differs per driver to this driver's value", function()
			local features = by_path(Manifest.for_platform(platform))
			local differing = 0
			for _, row in ipairs(Data.features) do
				for by, field in pairs({ default_by = "default", recommended_by = "recommended" }) do
					if row[by] then
						differing = differing + 1
						helpers.assert_eq(features[row.path][field], row[by][platform], row.path .. " " .. field)
					end
				end
			end
			helpers.assert_true(differing > 0, "the shared data declares per-driver values to resolve")
		end)

		helpers.it("is what the driver's manifest reader exposes", function()
			local expected = Manifest.for_platform(platform)
			helpers.assert_eq(reader.version(), expected.version)
			-- macOS resolves its backend default from the hardware on a lookup, so the
			-- declared entry (the loaded row itself) is what compares.
			local lookup = reader.find_declared_entry_by_path or reader.find_entry_by_path
			for _, entry in ipairs(expected.features) do
				helpers.assert_eq(lookup(entry.path), entry, entry.path)
			end
		end)

		helpers.it("hands every caller tables of its own", function()
			local first = Manifest.for_platform(platform)
			local path = first.features[1].path
			first.features[1].path = "edited"
			first.sections.script.platforms[1] = "edited"
			local second = Manifest.for_platform(platform)
			helpers.assert_eq(second.features[1].path, path)
			helpers.assert_true(second.sections.script.platforms[1] ~= "edited")
		end)

		helpers.it("refuses a driver the shared data does not describe", function()
			local ok, err = pcall(Manifest.for_platform, "ahk")
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find("unknown driver ahk", 1, true) ~= nil)
		end)
	end)
end

return M
