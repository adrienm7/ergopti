--- _shared/lua/test/extension_magic_key_contract.lua

--- Replays the shared magic-key declaration vectors against the Lua scanner, so
--- the macOS and Linux suites pin the decisions the Windows scanner and the
--- registry index builder replay too.
return function(helpers, Extensions, vectors)
	helpers.describe("extensions: shared physical magic-key vectors", function()
		helpers.it("(layout-magic-key) the vectors cover declarations, absence and refusals", function()
			local declared, refused = 0, 0
			for _, case in ipairs(vectors.cases) do
				if not case.valid then refused = refused + 1
				elseif case.magic_key ~= "" then declared = declared + 1 end
			end
			helpers.assert_true(declared >= 2 and refused >= 4, "the shared vectors lost their coverage")
		end)

		for _, case in ipairs(vectors.cases) do
			helpers.it("(layout-magic-key) " .. case.name, function()
				local ok, found = pcall(Extensions.scan, { "/ext" }, {
					list_dirs = function(root) return root == "/ext" and { "/ext/geometry" } or {} end,
					list_files = function() return {} end,
					read_file = function(path)
						return path == "/ext/geometry/manifest.toml" and case.manifest or nil
					end,
				})
				helpers.assert_eq(ok, case.valid, tostring(found))
				if case.valid then
					helpers.assert_eq(found[1].magic_key or "", case.magic_key)
				end
			end)
		end
	end)
end
