--- _shared/lua/test/layout_installed_update_manager_contract.lua

--- Actual registry managers and real private record files; native ports are controlled.
return function(helpers, Json, ports)
	local source = '{"schema_version":1,"layouts":{"ergol":{"id":"ergol","sha256":"old","version":"old",'
		.. '"future":{"nothing":null,"empty":[],"flag":false},"Version":9},"retired":false},"future_root":null}'

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


	local function expected_model()
		-- The existing verified index fixture supplies the new owned entry;
		-- retained members and the entire surrounding source model are handwritten.
		local expected = assert(Json.decode_lossless('{"schema_version":1,"layouts":{"retired":false},"future_root":null}'))
		expected.layouts.ergol = assert(Json.decode_lossless(Json.encode(ports.entry)))
		expected.layouts.ergol.future = assert(Json.decode_lossless('{"nothing":null,"empty":[],"flag":false}'))
		expected.layouts.ergol.Version = 9
		return expected
	end

	local function assert_model(text, expected)
		local actual = assert(Json.decode_lossless(text))
		helpers.assert_eq(Json.encode(actual), Json.encode(expected), "complete published source model")
		helpers.assert_true(Json.is_null(actual.future_root))
		helpers.assert_eq(actual.layouts.retired, false)
		if actual.layouts.ergol then
			helpers.assert_true(Json.is_array(actual.layouts.ergol.future.empty))
			helpers.assert_true(Json.is_null(actual.layouts.ergol.future.nothing))
			helpers.assert_eq(actual.layouts.ergol.future.flag, false)
		end
	end

	helpers.describe("driver verified same-id update preservation", function()
		helpers.it("publishes retained future fields on update and removes only the verified id (installed-future-update-manager)", function()
			with_manager(source, function(registry, deps, _state, read_source, _refuse, write_count)
				local result = ports.run(function(done) registry.install("ergol", done, deps) end)
				helpers.assert_eq(result.ok, true, tostring(result.extra))
				local expected = expected_model()
				assert_model(read_source(), expected)
				local removed = ports.run(function(done) registry.uninstall("ergol", done, deps) end)
				helpers.assert_eq(removed.ok, true, tostring(removed.extra))
				expected.layouts.ergol = nil
				assert_model(read_source(), expected)
				helpers.assert_eq(write_count(), 2)
			end)
		end)
		helpers.it("refused same-id publication retains exact source and a successful retry preserves futures (installed-future-update-manager)", function()
			with_manager(source, function(registry, deps, _state, read_source, refuse, write_count)
				refuse(true)
				local result = ports.run(function(done) registry.install("ergol", done, deps) end)
				helpers.assert_eq(result.ok, false)
				helpers.assert_eq(read_source(), source, "exact preimage survives refusal")
				refuse(false)
				local retried = ports.run(function(done) registry.install("ergol", done, deps) end)
				helpers.assert_eq(retried.ok, true, tostring(retried.extra))
				assert_model(read_source(), expected_model())
				helpers.assert_eq(write_count(), 2)
			end)
		end)
	end)
end
