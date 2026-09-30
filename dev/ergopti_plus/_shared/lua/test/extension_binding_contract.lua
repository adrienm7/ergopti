--- _shared/lua/test/extension_binding_contract.lua

--- Replays the shared extension-binding vectors against the Lua scanner, so the
--- macOS and Linux suites pin the same decisions the Windows scanner replays.
return function(helpers, Extensions, vectors)
	--- An injected filesystem holding the packs of one vector case.
	--- @param packs table Vector packs: { id, manifest, files }.
	--- @return table io_fns
	local function vector_fs(packs)
		local dirs, files, texts = {}, {}, {}
		for _, pack in ipairs(packs) do
			local dir = "/ext/" .. pack.id
			dirs[#dirs + 1] = dir
			texts[dir .. "/manifest.toml"] = pack.manifest
			local listed = {}
			for _, stem in ipairs(pack.files) do listed[#listed + 1] = dir .. "/hotstrings/" .. stem .. ".toml" end
			files[dir .. "/hotstrings"] = listed
		end
		return {
			list_dirs = function(root) return root == "/ext" and dirs or {} end,
			list_files = function(dir) return files[dir] or {} end,
			read_file = function(path) return texts[path] end,
		}
	end

	--- The vector spelling of a discovered path.
	--- @param path string Absolute fake path.
	--- @return string <pack id>/<file stem>
	local function vector_path(path)
		local id, stem = path:match("^/ext/([^/]+)/hotstrings/([^/]+)%.toml$")
		assert(id and stem, "the scanner returned a path outside the vector filesystem: " .. tostring(path))
		return id .. "/" .. stem
	end

	helpers.describe("extensions: shared historical binding vectors", function()
		helpers.it("(layout-extension-binding) the vectors cover acceptance, refusal and conflicts", function()
			local valid, invalid = 0, 0
			for _, case in ipairs(vectors.cases) do
				if case.valid then valid = valid + 1 else invalid = invalid + 1 end
			end
			helpers.assert_true(valid >= 3 and invalid >= 5, "the shared vectors lost their coverage")
		end)

		for _, case in ipairs(vectors.cases) do
			helpers.it("(layout-extension-binding) " .. case.name, function()
				local ok, found = pcall(Extensions.scan, { "/ext" }, vector_fs(case.packs))
				helpers.assert_eq(ok, case.valid, tostring(found))
				if not case.valid then return end
				-- A bound file is the source of a bundled category, so it must never
				-- also be offered as an ext: pack through toml_files.
				local bindings, unbound = {}, {}
				for _, pack in ipairs(found) do
					for _, file in ipairs(pack.bound_files) do
						helpers.assert_true(file.binding ~= nil, "bound_files lists only bound files")
						bindings[vector_path(file.path)] = file.binding
					end
					for _, file in ipairs(pack.toml_files) do
						helpers.assert_nil(file.binding, "toml_files lists only ext: packs")
						unbound[#unbound + 1] = vector_path(file.path)
					end
				end
				helpers.assert_eq(bindings, case.bindings)
				table.sort(unbound)
				local expected_unbound = {}
				for _, path in ipairs(case.unbound) do expected_unbound[#expected_unbound + 1] = path end
				table.sort(expected_unbound)
				helpers.assert_eq(unbound, expected_unbound)
				for _, query in ipairs(case.queries) do
					local section = query.section ~= "" and query.section or nil
					local resolved, source = pcall(Extensions.bound_source, found, query.category, section)
					local label = query.category .. "." .. query.section
					if query.source == "error" then
						helpers.assert_eq(resolved, false, label .. " must be refused")
					else
						helpers.assert_true(resolved, label .. ": " .. tostring(source))
						helpers.assert_eq(source and vector_path(source) or "", query.source, label)
					end
				end
			end)
		end
	end)
end
