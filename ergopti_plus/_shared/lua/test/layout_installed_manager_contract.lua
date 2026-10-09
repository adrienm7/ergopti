--- _shared/lua/test/layout_installed_manager_contract.lua

--- Exercises actual driver managers with private real installed-record files.
--- Native installation, transport and input-source ports remain controlled.
return function(helpers, Json, ports)
	local path = helpers.driver_root() .. "/../_shared/tests/corpus/layouts/installed_record_preservation.json"
	local vector_file = assert(io.open(path, "rb"))
	local vectors = assert(Json.decode_lossless(assert(vector_file:read("*a"))))
	assert(vector_file:close())

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
			function(value) refuse = value end, function() return writes end)
		assert(os.remove(private_path))
		if not ok then error(err, 0) end
	end

	local function assert_model(text, expected, label)
		local actual = assert(Json.decode_lossless(text))
		helpers.assert_eq(Json.encode(actual), Json.encode(expected), label .. ": complete model")
		helpers.assert_true(Json.is_array(actual.future_root.empty), label .. ": empty array")
		helpers.assert_true(Json.is_null(actual.future_root.nothing), label .. ": null")
		helpers.assert_eq(actual.future_flag, false, label .. ": Boolean false")
	end

	helpers.describe("driver installed-record publication preservation", function()
		helpers.it("keeps future roots and obsolete values through real-file install/remove (config-outdated-installed-manager)", function()
			with_manager(vectors.manager_source, function(registry, deps, _state, read_source, _refuse, write_count)
				local generic_decode = deps.decode_json
				deps.decode_json = function(text)
					helpers.assert_true(text ~= vectors.manager_source,
						"the generic/index decoder must not consume the installed record")
					return generic_decode(text)
				end
				local expected = assert(Json.decode_lossless(vectors.manager_source))
				local installed = ports.run(function(done) registry.install("ergol", done, deps) end)
				helpers.assert_eq(installed.ok, true, tostring(installed.extra))
				expected.layouts.ergol = ports.entry
				assert_model(read_source(), expected, "install")
				local removed = ports.run(function(done) registry.uninstall("ergol", done, deps) end)
				helpers.assert_eq(removed.ok, true, tostring(removed.extra))
				expected.layouts.ergol = nil
				assert_model(read_source(), expected, "remove")
				helpers.assert_eq(write_count(), 2)
			end)
		end)

		helpers.it("keeps obsolete source and future roots on refused publication, then retries (config-outdated-installed-manager)", function()
			with_manager(vectors.manager_source, function(registry, deps, state, read_source, refuse, write_count)
				refuse(true)
				local refused = ports.run(function(done) registry.install("ergol", done, deps) end)
				helpers.assert_eq(refused.ok, false)
				helpers.assert_eq(read_source(), vectors.manager_source, "refusal keeps exact source bytes")
				refuse(false)
				if ports.repair_partial_copy then
					-- The existing macOS installer copies before record publication;
					-- its retry must keep refusing that unrecorded native copy.
					local blocked = ports.run(function(done) registry.install("ergol", done, deps) end)
					helpers.assert_eq(blocked.ok, false)
					helpers.assert_eq(blocked.detail, registry.FAILURE_FOREIGN_FILE)
					helpers.assert_eq(read_source(), vectors.manager_source)
					helpers.assert_eq(write_count(), 1)
					ports.repair_partial_copy(state)
				end
				local installed = ports.run(function(done) registry.install("ergol", done, deps) end)
				helpers.assert_eq(installed.ok, true, tostring(installed.extra))
				local expected = assert(Json.decode_lossless(vectors.manager_source))
				expected.layouts.ergol = ports.entry
				assert_model(read_source(), expected, "retry")
				helpers.assert_eq(write_count(), 2)
			end)
		end)

		helpers.it("replaces an obsolete same-id row only after a verified installation (config-outdated-installed-manager)", function()
			local input = assert(Json.decode_lossless(vectors.manager_source))
			input.layouts.ergol = false
			with_manager(Json.encode(input), function(registry, deps, _state, read_source)
				local installed = ports.run(function(done) registry.install("ergol", done, deps) end)
				helpers.assert_eq(installed.ok, true, tostring(installed.extra))
				local expected = assert(Json.decode_lossless(vectors.manager_source))
				expected.layouts.ergol = ports.entry
				assert_model(read_source(), expected, "verified replacement")
				local removed = ports.run(function(done) registry.uninstall("ergol", done, deps) end)
				helpers.assert_eq(removed.ok, true, tostring(removed.extra))
				expected.layouts.ergol = nil
				assert_model(read_source(), expected, "no obsolete resurrection")
			end)
		end)

		helpers.it("refuses array/null owned layouts before uninstalling or publishing (config-outdated-installed-manager)", function()
			for _, text in ipairs({ '{"schema_version":1,"layouts":[]}', '{"schema_version":1,"layouts":null}' }) do
				with_manager(text, function(registry, deps, state, read_source, _refuse, write_count)
					local result = ports.run(function(done) registry.uninstall("ergol", done, deps) end)
					helpers.assert_eq(result.ok, false)
					helpers.assert_eq(result.detail, registry.FAILURE_RECORD)
					helpers.assert_eq(read_source(), text)
					helpers.assert_eq(write_count(), 0)
					helpers.assert_eq(#state.deleted, 0)
				end)
			end
		end)
	end)
end
