--- tests/unit/lib/test_toml_publication_receipt_contract.lua

--- Protects ordinary cleanup callbacks and private opaque publication receipts.
local helpers = require("tests.helpers")
local function with_writer(body)
	helpers.with_fresh_modules({ "toml_codec.writer", "infra.logger" }, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		body(require("toml_codec.writer"))
	end)
end
local function source_adapter()
	return { read_with_status = function() return "original source", "ok" end }
end

helpers.describe("toml publication dual receipt boundary", function()
	helpers.it("preserves a generic two-argument publisher's exact cleanup callback on refusal", function()
		with_writer(function(writer)
			local adapter, writes, retries = source_adapter(), 0, 0
			local cleanup = function() retries = retries + 1; return true, nil, true end
			adapter.write = function(...)
				helpers.assert_eq(select("#", ...), 2)
				local path, content = ...
				helpers.assert_eq(path, "config"); helpers.assert_eq(content, "candidate")
				writes = writes + 1; return false, "release refused", cleanup
			end
			local committed, detail, receipt = writer.publish_if_unchanged("config", "candidate", adapter, { status = "ok", content = "original source" })
			helpers.assert_eq(committed, false); helpers.assert_eq(detail, "release refused")
			helpers.assert_eq(receipt, cleanup)
			local record = { publication_cleanup = receipt }
			local settled, _, published = writer.retry_publication_cleanup(record)
			helpers.assert_eq(settled, true); helpers.assert_eq(published, true)
			helpers.assert_eq(record.publication_cleanup, nil)
			helpers.assert_eq(writes, 1); helpers.assert_eq(retries, 1)
		end)
	end)

	helpers.it("preserves conditional ordinary cleanup with a nil diagnostic owner and exact refused retry", function()
		with_writer(function(writer)
			local adapter, admitted, retries = source_adapter(), false, 0
			local expected = { status = "ok", content = "original source" }
			local cleanup = function() retries = retries + 1; return admitted, "cleanup pending", false end
			adapter.write_if_unchanged = function(...)
				helpers.assert_eq(select("#", ...), 4)
				local _, _, source, on_error = ...
				helpers.assert_true(source == expected); helpers.assert_eq(on_error, nil)
				return false, "release refused", cleanup
			end
			local committed, _, receipt = writer.publish_if_unchanged("config", "candidate", adapter, expected)
			helpers.assert_eq(committed, false); helpers.assert_eq(receipt, cleanup)
			local record = { publication_cleanup = receipt }
			helpers.assert_eq(writer.retry_publication_cleanup(record), false)
			helpers.assert_eq(record.publication_cleanup, cleanup)
			admitted = true
			local settled, _, published = writer.retry_publication_cleanup(record)
			helpers.assert_eq(settled, true); helpers.assert_eq(published, false)
			helpers.assert_eq(record.publication_cleanup, nil); helpers.assert_eq(retries, 2)
		end)
	end)

	for _, committed in ipairs({ false, true }) do
		helpers.it("preserves the private opaque table and exact reporter with commit=" .. tostring(committed), function()
			with_writer(function(writer)
				local adapter, expected = source_adapter(), { status = "ok", content = "original source" }
				local reporter = function() end
				local receipt = setmetatable({}, { __newindex = function() error("immutable") end, __metatable = false })
				adapter.write_if_unchanged = function(...)
					helpers.assert_eq(select("#", ...), 4)
					local _, _, source, on_error = ...
					helpers.assert_true(source == expected); helpers.assert_true(on_error == reporter)
					return committed, nil, receipt
				end
				local written, _, returned = writer.publish_if_unchanged("config", "candidate", adapter, expected, reporter)
				helpers.assert_eq(written, committed); helpers.assert_true(returned == receipt)
				helpers.assert_eq(type(returned), "table")
			end)
		end)
	end

	helpers.it("does not fabricate a receipt when the conditional publisher throws", function()
		with_writer(function(writer)
			local adapter = source_adapter()
			adapter.write_if_unchanged = function() error("closed fixture refusal") end
			local committed, _, receipt = writer.publish_if_unchanged("config", "candidate", adapter, { status = "ok", content = "original source" }, function() end)
			helpers.assert_eq(committed, false); helpers.assert_nil(receipt)
		end)
	end)
end)


helpers.describe("merged hotstring and program publication boundary", function()
	helpers.it("does not expose an unrelated opaque table to an ordinary publication caller", function()
		with_writer(function(writer)
			for _, acknowledged in ipairs({ false, true }) do
				local adapter = source_adapter()
				local foreign = setmetatable({}, { __index = function() error("must not inspect another owner") end })
				adapter.write_if_unchanged = function() return acknowledged, "fixture", foreign end
				local written, _, receipt = writer.publish_if_unchanged("config", "candidate", adapter,
					{ status = "ok", content = "original source" })
				helpers.assert_eq(written, acknowledged)
				helpers.assert_nil(receipt)
			end
		end)
	end)

	helpers.it("keeps the ordinary function receipt a refusal-only capability", function()
		with_writer(function(writer)
			local adapter, calls = source_adapter(), 0
			local cleanup = function() calls = calls + 1; return true, nil, true end
			adapter.write_if_unchanged = function() return true, nil, cleanup end
			local written, _, receipt = writer.publish_if_unchanged("config", "candidate", adapter,
				{ status = "ok", content = "original source" })
			helpers.assert_eq(written, true)
			helpers.assert_nil(receipt)
			helpers.assert_eq(calls, 0, "publication cannot invoke an ordinary cleanup owner implicitly")
		end)
	end)

	helpers.it("updates a literal dotted hotstring leaf without borrowing the distinct dotted TOML path", function()
		with_writer(function(writer)
			local original = '[custom]\n"a.b" = true\na.b = true\nkeep = 41\n'
			local adapter = { read_with_status = function() return original, "ok" end }
			local prepared, _, candidate = writer.prepare_batch("config", {
				{ section = "custom", key = "a.b", value = false, literal_key = true }
			}, adapter, { status = "ok", content = original })
			helpers.assert_eq(prepared, true)
			helpers.assert_eq(candidate, '[custom]\n"a.b" = false\na.b = true\nkeep = 41\n')
		end)
	end)
end)

-- Existing generic adapters own reference-bearing receipts, not config authority.
helpers.describe("configuration detachment preserves ordinary publication contracts", function()
	for _, mode in ipairs({ "nil", "false", "opaque" }) do
		helpers.it("retains exact generic source, reporter and receipt with " .. mode, function()
			with_writer(function(writer)
				local adapter, expected = source_adapter(), { status = "ok", content = "original source", marker = {} }
				local reporter = mode == "opaque" and function() end or mode == "false" and false or nil
				if mode == "false" then reporter = false end
				local receipt = mode == "opaque" and setmetatable({}, { __metatable = false }) or function() return true end
				local seen_source, seen_reporter, seen_count, writes
				adapter.write_if_unchanged = function(...)
					seen_count = select("#", ...)
					local _, _, source, on_error = ...
					seen_source, seen_reporter, writes = source, on_error, (writes or 0) + 1
					return false, "ordinary owner refused", receipt
				end
				local committed, detail, returned = writer.publish_if_unchanged("ordinary-data", "candidate", adapter, expected, reporter)
				helpers.assert_eq(committed, false); helpers.assert_eq(detail, "ordinary owner refused")
				helpers.assert_true(rawequal(seen_source, expected), "the original generic source reference crosses unchanged")
				helpers.assert_true(rawequal(seen_reporter, reporter), "nil/false/function reporter identities remain exact")
				helpers.assert_true(rawequal(returned, receipt), "opaque or ordinary cleanup owner is not lost")
				helpers.assert_eq(seen_count, 4); helpers.assert_eq(writes, 1)
			end)
		end)
	end

	helpers.it("keeps a generic caller admission from detaching its ordinary source owner", function()
		with_writer(function(writer)
			local adapter, expected = source_adapter(), { status = "ok", content = "original source" }
			local observed, checks = nil, 0
			adapter.write_if_unchanged_admitted = function(_, _, source, _, admission)
				observed = source
				return admission() == true
			end
			local committed = writer.publish_if_unchanged("ordinary-admitted-data", "candidate", adapter, expected, nil,
				function() checks = checks + 1; return true end)
			helpers.assert_eq(committed, true)
			helpers.assert_true(rawequal(observed, expected), "a caller gate cannot mint schema-owned detachment")
			helpers.assert_eq(checks, 1)
		end)
	end)
end)

--- Runs an actual current-schema native file inside a fresh constructor cohort.
--- @param body function Callback receiving Writer, source image, path and byte reader.
local function with_current_native_source(body)
	helpers.with_fresh_modules({ "toml_codec.writer", "config_migrate", "adapters.file_system", "infra.logger" }, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local writer, engine = require("toml_codec.writer"), require("config_migrate")
		local registry = assert(engine.load_registry(helpers.shared("core/config_schema/migrations.toml")))
		local path = os.tmpname()
		local original = "# genuine native source\n[_meta]\nschema_version = " .. registry.current .. "\n[llm]\nenabled = false\n"
		local function read()
			local file = assert(io.open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
		end
		local file = assert(io.open(path, "wb")); assert(file:write(original)); assert(file:close())
		local ok, detail = xpcall(function()
			local result = engine.boot({ path = path, driver = "hs", registry = registry })
			helpers.assert_eq(result.status, "current", "the genuine registered destination reaches READY")
			body(writer, { status = "ok", content = original }, path, read)
		end, debug.traceback)
		os.remove(path)
		if not ok then error(detail, 0) end
	end)
end

helpers.describe("genuine configuration keeps detached publication admission", function()
	helpers.it("captures original source fields before a real read mutates the caller table", function()
		with_current_native_source(function(writer, expected, path, read)
			local original, open, mutations = expected.content, io.open, 0
			local candidate = original:gsub("enabled = false", "enabled = true")
			io.open = function(target, mode)
				local file, detail, code = open(target, mode)
				if file and target == path and mode == "r" and mutations == 0 then
					return { read = function(_, format)
						local bytes = file:read(format)
						mutations = mutations + 1; expected.status, expected.content = "absent", "unrelated caller mutation"
						return bytes
					end, close = function() return file:close() end }
				end
				return file, detail, code
			end
			local called, committed = pcall(writer.publish_if_unchanged, path, candidate, nil, expected)
			io.open = open
			helpers.assert_true(called); helpers.assert_eq(mutations, 1)
			helpers.assert_eq(expected.status, "absent", "the genuine callback did mutate its caller source")
			helpers.assert_eq(committed, true, "the captured native source remains the original physical precondition")
			helpers.assert_eq(read(), candidate)
		end)
	end)

	helpers.it("refuses a replaced genuine registered reader before any callback or publication", function()
		with_current_native_source(function(writer, expected, path, read)
			local native = require("adapters.file_system")
			local original, calls = native.read_with_status, 0
			native.read_with_status = function() calls = calls + 1; return expected.content, "ok" end
			local called, committed = pcall(writer.publish_if_unchanged, path, expected.content, native, expected)
			native.read_with_status = original
			helpers.assert_true(called); helpers.assert_eq(committed, false)
			helpers.assert_eq(calls, 0, "a generic-looking replacement never gains registered config authority")
			helpers.assert_eq(read(), expected.content)
		end)
	end)
end)

helpers.describe("schema admission and native CAS share one exact source snapshot", function()
	for _, race in ipairs({ false, true }) do
		helpers.it("reads source fields once and preserves physical capture race=" .. tostring(race), function()
			with_current_native_source(function(writer, expected, path, read)
				local engine = require("config_migrate")
				local registry = assert(engine.load_registry(helpers.shared("core/config_schema/migrations.toml")))
				local original = expected.content
				local future = "[_meta]\nschema_version = " .. (registry.current + 1) .. "\n[future]\nkeep = \"must survive\"\n"
				local candidate = original:gsub("enabled = false", "enabled = true")
				local status_reads, content_reads, replacements = 0, 0, 0
				local source = setmetatable({}, { __index = function(_, key)
					if key == "status" then status_reads = status_reads + 1; return "ok" end
					if key == "content" then
						content_reads = content_reads + 1
						if race or content_reads > 1 then
							local file = assert(io.open(path, "wb")); assert(file:write(future)); assert(file:close())
							replacements = replacements + 1
						end
						return content_reads == 1 and original or future
					end
				end })
				local called, committed = pcall(writer.publish_if_unchanged, path, candidate, nil, source)
				helpers.assert_true(called)
				helpers.assert_eq(status_reads, 1, "the classifier and publisher use the same status snapshot")
				helpers.assert_eq(content_reads, 1, "a second alias read cannot retarget the native precondition")
				helpers.assert_eq(replacements, race and 1 or 0)
				helpers.assert_eq(committed, not race)
				helpers.assert_eq(read(), race and future or candidate, "a physical successor is never overwritten")
			end)
		end)
	end
end)
