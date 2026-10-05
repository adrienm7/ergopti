--- _shared/lua/test/layout_installed_extension_manager_contract.lua

--- Actual record owners, real private files; native installation and input ports controlled.
return function(helpers, Json, ports)
	local file = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/layouts/installed_record_extensions.json", "rb"))
	local vectors = assert(Json.decode_lossless(assert(file:read("*a"))))
	assert(file:close())

	local function with_manager(source, body)
		local private_path = os.tmpname()
		local initial = assert(io.open(private_path, "wb"))
		assert(initial:write(source))
		assert(initial:close())
		local files = ports.files()
		files[ports.local_dir .. "installed.json"] = source
		local receipts = {}
		for index = 1, 12 do
			receipts[index] = index % 2 == 1 and ports.probe_receipt or ports.install_receipt
		end
		local registry, deps, state = ports.manager({ files = files, runs = receipts })
		deps.local_source = true
		local record_path = ports.local_dir .. "installed.json"
		local original_read, original_exists, original_write = deps.read, deps.exists, deps.write
		local writes, refuse = 0, false
		local function read_source()
			local file = assert(io.open(private_path, "rb"))
			local text = assert(file:read("*a"))
			assert(file:close())
			return text
		end
		deps.read = function(file_path)
			if file_path == record_path then return read_source() end
			return original_read(file_path)
		end
		deps.exists = function(file_path)
			if file_path == record_path then return true end
			return original_exists(file_path)
		end
		deps.write = function(file_path, content)
			if file_path ~= record_path then return original_write(file_path, content) end
			writes = writes + 1
			if refuse then return false, "record publication refused" end
			local file = assert(io.open(private_path, "wb"))
			assert(file:write(content))
			assert(file:close())
			state.files[file_path] = content
			return true
		end
		local ok, err = pcall(body, registry, deps, state, read_source,
			function(value) refuse = value end, function() return writes end,
			function(text)
				local file = assert(io.open(private_path, "wb"))
				assert(file:write(text))
				assert(file:close())
			end)
		assert(os.remove(private_path))
		if not ok then error(err, 0) end
	end


	helpers.describe("driver invalid optional extension preservation", function()
		for _, vector in ipairs(vectors.cases) do
			helpers.it("boot warns once and publication retains extension " .. vector.id .. " (installed-extension-manager)", function()
				with_manager(vector.source, function(registry, deps, state, read_source, _refuse, write_count)
					local Logger, Outdated = require("logger.shim"), require("config_outdated")
					Outdated.reset_for_tests()
					local previous_warn, warnings = Logger.warn, {}
					Logger.warn = function(tag, fmt, ...)
						if tag == "config_outdated" then warnings[#warnings + 1] = string.format(fmt, ...) end
					end
					local ok, err = pcall(function()
						local roots = registry.extension_roots(deps)
						helpers.assert_eq(#roots, 1)
						helpers.assert_eq(roots[1], ports.local_dir .. "extensions/stable/" .. string.rep("a", 64))
						helpers.assert_eq(#registry.extension_roots(deps), 1)
						helpers.assert_eq(#warnings, 1, "one warning per file/path/reason")
						helpers.assert_contains(warnings[1], ports.local_dir .. "installed.json")
						helpers.assert_contains(warnings[1], "layouts.retired")
						helpers.assert_contains(warnings[1], "extension")
						local ignored = ports.run(function(done) registry.uninstall("retired", done, deps) end)
						helpers.assert_eq(ignored.ok, false)
						helpers.assert_eq(ignored.detail, registry.FAILURE_NOT_INSTALLED)
						helpers.assert_eq(#state.deleted, 0, "unverified files must not be deleted")
						helpers.assert_eq(write_count(), 0)
						helpers.assert_eq(read_source(), vector.source, "ignored removal retains exact source")
						local installed = ports.run(function(done) registry.install("ergol", done, deps) end)
						helpers.assert_eq(installed.ok, true, tostring(installed.extra))
						local expected = assert(Json.decode_lossless(vector.source))
						expected.layouts.ergol = ports.entry -- independent existing verified index fixture
						helpers.assert_eq(Json.encode(assert(Json.decode_lossless(read_source()))), Json.encode(expected))
						local removed = ports.run(function(done) registry.uninstall("ergol", done, deps) end)
						helpers.assert_eq(removed.ok, true, tostring(removed.extra))
						helpers.assert_eq(Json.encode(assert(Json.decode_lossless(read_source()))),
							Json.encode(assert(Json.decode_lossless(vector.source))), "complete original source model")
						helpers.assert_eq(write_count(), 2)
						helpers.assert_eq(#warnings, 1, "install/remove cannot flood the warning")
					end)
					Logger.warn = previous_warn
					Outdated.reset_for_tests()
					if not ok then error(err, 0) end
				end)
			end)
		end
		helpers.it("refuses publication without changing invalid source, then preserves it on an explicit retry (installed-extension-manager)", function()
			local source = vectors.cases[2].source -- independently handwritten false extension
			with_manager(source, function(registry, deps, state, read_source, refuse, write_count)
				require("config_outdated").reset_for_tests()
				helpers.assert_eq(#registry.extension_roots(deps), 1)
				refuse(true)
				local refused = ports.run(function(done) registry.install("ergol", done, deps) end)
				helpers.assert_eq(refused.ok, false)
				helpers.assert_eq(read_source(), source)
				refuse(false)
				if ports.repair_partial_copy then
					local blocked = ports.run(function(done) registry.install("ergol", done, deps) end)
					helpers.assert_eq(blocked.ok, false)
					helpers.assert_eq(blocked.detail, registry.FAILURE_FOREIGN_FILE)
					helpers.assert_eq(read_source(), source)
					ports.repair_partial_copy(state)
				end
				local retried = ports.run(function(done) registry.install("ergol", done, deps) end)
				helpers.assert_eq(retried.ok, true, tostring(retried.extra))
				local expected = assert(Json.decode_lossless(source))
				expected.layouts.ergol = ports.entry
				helpers.assert_eq(Json.encode(assert(Json.decode_lossless(read_source()))), Json.encode(expected))
				helpers.assert_eq(write_count(), 2)
			end)
		end)
		helpers.it("an explicitly repaired inventory becomes usable on the next real-file read (installed-extension-manager)", function()
			with_manager(vectors.cases[2].source, function(registry, deps, _state, read_source, _refuse, write_count, repair_source)
				require("config_outdated").reset_for_tests()
				helpers.assert_eq(#registry.extension_roots(deps), 1)
				local repaired = assert(Json.decode_lossless(vectors.cases[2].source))
				repaired.layouts.retired.extension = {
					id = "retired", name = "Retired", sha256 = string.rep("d", 64),
					files = Json.array({
						{ path = "manifest.toml", file = "retired/manifest.toml", size = 1, sha256 = string.rep("b", 64) },
						{ path = "retired.keylayout", file = "retired/retired.keylayout", size = 1, sha256 = string.rep("c", 64) },
					}),
				}
				local text = Json.encode(repaired)
				repair_source(text) -- explicit manual edit, outside the ordinary settings writer
				local roots = registry.extension_roots(deps)
				helpers.assert_eq(#roots, 2)
				helpers.assert_eq(roots[1], ports.local_dir .. "extensions/retired/" .. string.rep("d", 64))
				helpers.assert_eq(roots[2], ports.local_dir .. "extensions/stable/" .. string.rep("a", 64))
				helpers.assert_eq(read_source(), text)
				helpers.assert_eq(write_count(), 0, "a reread does not rewrite the manually repaired source")
			end)
		end)

	end)
end
