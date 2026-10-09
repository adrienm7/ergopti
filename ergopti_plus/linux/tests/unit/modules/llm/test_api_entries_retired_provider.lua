--- tests/unit/modules/llm/test_api_entries_retired_provider.lua

--- ==============================================================================
--- MODULE: Stored Provider Publication Boundaries
--- DESCRIPTION:
--- Actual catalogue/store owners read real private files. Handwritten complete
--- source models retain retired rows until explicit cleanup; empty or refused
--- catalogue receipts cannot prove retirement. No HTTP request is dispatched.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Paths = require("infra.paths")
local Logger = require("logger.shim")

local CLOUD = [[{"provider_order":["cerebras"],"providers":{"cerebras":{"label":"Cerebras","base_url":"https://example.invalid/v1","default_model":"fixture","format":"openai"}}}]]
local LOCAL = [[{"server_order":["lmstudio"],"servers":{"lmstudio":{"label":"LM Studio","base_url":"http://127.0.0.1:1234/v1","auth":"optional"}}}]]
local SOURCE = [[{"version":1,"active_id":"retired-1","entries":[{"id":"retired-1","provider":"removed_vendor_for_probe","label":"Old provider","token":"invented-fixture-token","future":{"empty":[],"nothing":null}},{"id":"usable-1","provider":"cerebras","label":"Usable provider","token":"invented-fixture-token"},{"id":"local-1","provider":"lmstudio","label":"Local provider","token":"","model":"first-model","base_url":"http://127.0.0.1:1234/v1"}],"future_root":{"flag":false}}]]
local SELECTED = [[{"version":1,"active_id":"usable-1","entries":[{"id":"retired-1","provider":"removed_vendor_for_probe","label":"Old provider","token":"invented-fixture-token","future":{"empty":[],"nothing":null}},{"id":"usable-1","provider":"cerebras","label":"Usable provider","token":"invented-fixture-token","model":"","base_url":""},{"id":"local-1","provider":"lmstudio","label":"Local provider","token":"","model":"first-model","base_url":"http://127.0.0.1:1234/v1"}],"future_root":{"flag":false}}]]
local LOCAL_UPDATED = [[{"version":1,"active_id":"retired-1","entries":[{"id":"retired-1","provider":"removed_vendor_for_probe","label":"Old provider","token":"invented-fixture-token","future":{"empty":[],"nothing":null}},{"id":"usable-1","provider":"cerebras","label":"Usable provider","token":"invented-fixture-token","model":"","base_url":""},{"id":"local-1","provider":"lmstudio","label":"Local provider","token":"","model":"second-model","base_url":"http://127.0.0.1:1234/v1"}],"future_root":{"flag":false}}]]

local function write(path, bytes)
	local file = assert(io.open(path, "wb"))
	assert(file:write(bytes))
	assert(file:close())
end

local function read(path)
	local file = assert(io.open(path, "rb"))
	local bytes = assert(file:read("*a"))
	assert(file:close())
	return bytes
end

local function assert_model(actual, expected, path)
	path = path or "root"
	helpers.assert_eq(type(actual), type(expected), path .. ": value type")
	helpers.assert_eq(Json.is_array(actual), Json.is_array(expected), path .. ": array identity")
	helpers.assert_eq(Json.is_null(actual), Json.is_null(expected), path .. ": null identity")
	if type(expected) ~= "table" or Json.is_null(expected) then
		if not Json.is_null(expected) then helpers.assert_eq(actual, expected, path) end
		return
	end
	for key, value in pairs(expected) do assert_model(actual[key], value, path .. "." .. tostring(key)) end
	for key in pairs(actual) do helpers.assert_true(expected[key] ~= nil, path .. ": unexpected member " .. tostring(key)) end
end

--- Stock Lua has no FFI: this fixture uses actual libuv private-file syscalls.
--- The driver runtime (LuaJIT) keeps its unchanged production libc owner.
local function create_private(path, bytes)
	local uv = require("luv")
	local fd, detail = uv.fs_open(path, "wx", 384)
	if not fd then return false, detail end
	local written = uv.fs_write(fd, bytes, 0)
	local synced = uv.fs_fsync(fd)
	local closed = uv.fs_close(fd)
	return written == #bytes and synced == true and closed == true
end

local function with_case(options, body)
	local names = { "modules.llm.api_entries", "modules.llm.api_remote", "modules.llm.local_server_catalogue" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
	local path = os.tmpname()
	local cloud, local_path = path .. ".cloud", path .. ".local"
	write(path, SOURCE)
	if options.cloud ~= false then write(cloud, options.cloud or CLOUD) end
	if options.local_source ~= false then write(local_path, options.local_source or LOCAL) end
	local original_shared, original_open = Paths.shared, io.open
	local original_warn, original_error = Logger.warn, Logger.error
	local warnings, errors = {}, {}
	Paths.shared = function(name)
		if name == "modules/llm/api_providers.json" then return cloud end
		if name == "modules/llm/local_servers.json" then return local_path end
		return original_shared(name)
	end
	Logger.warn = function(_, format, ...) warnings[#warnings + 1] = string.format(format, ...) end
	Logger.error = function(_, format, ...) errors[#errors + 1] = string.format(format, ...) end
	require("config_outdated").reset_for_tests()
	local fault = options.fault
	if fault then
		io.open = function(file_path, mode)
			local file, detail = original_open(file_path, mode)
			local selected = fault.lane == "cloud" and cloud or local_path
			if not file or file_path ~= selected or not mode:match("r") then return file, detail end
			return {
				read = function(_, ...)
					local bytes = file:read(...)
					if fault.stage ~= "read" then return bytes end
					if fault.kind == "throw" then error("catalogue read refused") end
					return fault.value
				end,
				close = function()
					local closed = file:close()
					if fault.stage ~= "close" then return closed end
					if fault.kind == "throw" then error("catalogue close refused") end
					return fault.value
				end,
			}
		end
	end
	local ok, detail = pcall(function()
		local remote
		if options.remote_first then
			remote = require("modules.llm.api_remote")
			remote.provider("cerebras")
		end
		local entries = require("modules.llm.api_entries")
		entries._set_path_for_test(path)
		if not jit then entries._set_private_create_for_test(create_private) end
		remote = remote or require("modules.llm.api_remote")
		body({ entries = entries, remote = remote, path = path, cloud = cloud, local_path = local_path,
			warnings = warnings, errors = errors, read = function() return read(path) end,
			write = function(bytes) write(path, bytes) end, create_private = create_private })
	end)
	io.open, Paths.shared = original_open, original_shared
	Logger.warn, Logger.error = original_warn, original_error
	for _, owned in ipairs({ path, cloud, local_path, path .. ".tmp", path .. ".corrupt" }) do os.remove(owned) end
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(detail, 0) end
end

helpers.describe("retired API provider source ownership", function()
	for _, remote_first in ipairs({ false, true }) do
		helpers.it("partitions stored rows after actual publication, remote-first=" .. tostring(remote_first) .. " (retired-provider-source-contract)", function()
			with_case({ remote_first = remote_first }, function(f)
				helpers.assert_nil(f.remote.provider("removed_vendor_for_probe"))
				helpers.assert_type(f.remote.provider("cerebras"), "table")
				local rows = f.entries.list()
				helpers.assert_eq(#rows, 2)
				helpers.assert_eq(rows[1].id, "usable-1")
				helpers.assert_eq(rows[2].id, "local-1")
				helpers.assert_nil(f.entries.active())
				helpers.assert_eq(f.read(), SOURCE)
				helpers.assert_eq(#f.warnings, 2)
				helpers.assert_eq(#f.errors, 0)
				f.entries._set_path_for_test(f.path)
				f.entries.list()
				helpers.assert_eq(#f.warnings, 2, "repeated actual reads use the same warning identity")
				helpers.assert_eq(f.remote.is_active(), false, "configuration reads dispatch no HTTP request")
				helpers.assert_true(not table.concat(f.warnings, "\n"):find("invented-fixture-token", 1, true))
			end)
		end)
	end

	helpers.it("ordinary selection retains the independently handwritten complete ignored-row model (retired-provider-source-contract)", function()
		with_case({}, function(f)
			helpers.assert_eq(f.entries.set_active("usable-1"), true)
			assert_model(assert(Json.decode_lossless(f.read())), assert(Json.decode_lossless(SELECTED)))
			f.entries._set_path_for_test(f.path)
			helpers.assert_eq(f.entries.active().id, "usable-1")
			helpers.assert_nil(f.entries.get("retired-1"))
		end)
	end)

	helpers.it("an unrelated local update retains the obsolete active reference and source row (retired-provider-source-contract)", function()
		with_case({}, function(f)
			f.entries.list()
			local source = assert(f.entries.capture_source())
			local updated = f.entries.upsert_local("lmstudio", { model = "second-model" }, source,
				function() return true end, false)
			helpers.assert_type(updated, "table")
			assert_model(assert(Json.decode_lossless(f.read())), assert(Json.decode_lossless(LOCAL_UPDATED)))
			helpers.assert_nil(f.entries.active())
		end)
	end)

	helpers.it("ignored identities cannot be selected or deleted by ordinary entry operations (retired-provider-source-contract)", function()
		with_case({}, function(f)
			helpers.assert_eq(f.entries.set_active("retired-1"), false)
			helpers.assert_eq(f.entries.remove("retired-1"), false)
			helpers.assert_eq(f.read(), SOURCE)
		end)
	end)

	helpers.it("a refused private publication retains rows and the dangling selection for retry (retired-provider-source-contract)", function()
		with_case({}, function(f)
			f.entries._set_private_create_for_test(function() return false, "fixture creation refused" end)
			helpers.assert_eq(f.entries.set_active("usable-1"), false)
			helpers.assert_nil(f.entries.active())
			helpers.assert_eq(f.read(), SOURCE)
			f.entries._set_private_create_for_test(f.create_private)
			helpers.assert_eq(f.entries.set_active("usable-1"), true)
			assert_model(assert(Json.decode_lossless(f.read())), assert(Json.decode_lossless(SELECTED)))
		end)
	end)

	local unavailable = {
		{ lane = "cloud", source = false, label = "missing" },
		{ lane = "cloud", source = "{bad", label = "malformed" },
		{ lane = "cloud", source = '{"provider_order":[],"providers":{}}', label = "empty" },
		{ lane = "cloud", source = '{"provider_order":["invalid"],"providers":{"invalid":{}}}', label = "zero projected" },
		{ lane = "local", source = false, label = "missing" },
		{ lane = "local", source = "{bad", label = "malformed" },
		{ lane = "local", source = '{"server_order":[],"servers":{}}', label = "empty" },
		{ lane = "local", source = '{"server_order":["invalid"],"servers":{"invalid":{}}}', label = "zero projected" },
	}
	for _, vector in ipairs(unavailable) do
		helpers.it(vector.lane .. " " .. vector.label .. " cannot prove retirement", function()
			local options = {}
			options[vector.lane == "cloud" and "cloud" or "local_source"] = vector.source
			with_case(options, function(f)
				helpers.assert_eq(f.remote.provider_config_receipt().published, false)
				helpers.assert_eq(#f.entries.list(), 3, "a pending catalogue keeps existing choices")
				helpers.assert_eq(f.entries.active().id, "retired-1")
				helpers.assert_eq(f.read(), SOURCE)
				for _, message in ipairs(f.warnings) do
					helpers.assert_true(not message:find("absent from the published", 1, true))
				end
			end)
		end)
	end

	for _, lane in ipairs({ "cloud", "local" }) do
		for _, stage in ipairs({ "read", "close" }) do
			for _, refusal in ipairs({ { label = "nil" }, { label = "false", value = false },
				{ label = "truthy string", value = "accepted" }, { label = "wrong object", value = {} },
				{ label = "exception", kind = "throw" } }) do
				helpers.it(lane .. " " .. stage .. " " .. refusal.label .. " cannot publish retirement authority", function()
					with_case({ fault = { lane = lane, stage = stage, value = refusal.value, kind = refusal.kind } }, function(f)
						helpers.assert_eq(f.remote.provider_config_receipt().published, false)
						helpers.assert_type(f.entries.get("retired-1"), "table")
						helpers.assert_eq(f.read(), SOURCE)
						for _, message in ipairs(f.warnings) do
							helpers.assert_true(not message:find("absent from the published", 1, true))
						end
					end)
				end)
			end
		end
	end

	helpers.it("explicit reload of both owners after a catalogue repair admits a fresh proof", function()
		with_case({ local_source = false }, function(f)
			helpers.assert_type(f.entries.get("retired-1"), "table")
			write(f.local_path, LOCAL)
			f.remote._reset_for_test()
			f.entries._set_path_for_test(f.path)
			helpers.assert_nil(f.entries.get("retired-1"))
			helpers.assert_nil(f.entries.active())
			helpers.assert_eq(f.read(), SOURCE)
			helpers.assert_eq(#f.warnings, 2)
		end)
	end)

	helpers.it("configuration snapshots cannot mutate the actual registered provider inventory", function()
		with_case({}, function(f)
			local receipt = f.remote.provider_config_receipt()
			helpers.assert_eq(receipt.published, true)
			receipt.ids.cerebras, receipt.ids.removed_vendor_for_probe = nil, true
			helpers.assert_type(f.remote.provider("cerebras"), "table")
			helpers.assert_nil(f.remote.provider("removed_vendor_for_probe"))
			helpers.assert_nil(f.entries.get("retired-1"))
		end)
	end)
end)
