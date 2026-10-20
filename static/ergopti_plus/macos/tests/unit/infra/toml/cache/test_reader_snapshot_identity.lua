--- tests/unit/infra/toml/cache/test_reader_snapshot_identity.lua

--- ==============================================================================
--- MODULE: Shared TOML Reader Snapshot Identity
--- DESCRIPTION:
--- Optional cache snapshots must bind the parsed text to its capture receipt.
--- Real files distinguish captured A from fallback B; refused snapshot hooks
--- permit a normal parse but cannot publish against the old receipt.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED = {
	"infra.logger", "toml_codec.reader", "toml_codec.bom", "toml_codec.basic_string",
	"toml_codec.key_path", "toml_codec.record_scanner", "compat.utf8",
}
local A = '[[alpha]]\n"key" = { output = "CAPTURED" }\n'
local B = '[[alpha]]\n"key" = { output = "FALLBACK" }\n'

local function output(document) return document.sections.alpha.entries[1].output end

--- Captures actual closed file bytes before a real replacement is read by fallback.
local function with_reader(run)
	local source = os.tmpname()
	local ok, detail = xpcall(function()
		helpers.with_stub_scope(OWNED, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local reader = require("toml_codec.reader")
			local state = { source = source, capture_calls = 0, reads = 0, stores = 0 }
			function state.write(bytes)
				local file = assert(io.open(source, "wb"))
				assert(file:write(bytes)); assert(file:close())
			end
			state.write(A)
			local captures, provider = {}, {}
			provider.load = function() return nil end
			provider.capture_source = function(path)
				helpers.assert_eq(path, source)
				local file = assert(io.open(path, "rb"))
				local bytes = assert(file:read("*a")); assert(file:close())
				local token = {}
				captures[token] = bytes
				state.token = token; state.capture_calls = state.capture_calls + 1
				state.write(B)
				return token
			end
			provider.read_snapshot = function(path, token)
				state.reads = state.reads + 1
				helpers.assert_eq(path, source)
				helpers.assert_true(token == state.token, "snapshot must use the exact capture receipt")
				return captures[token]
			end
			provider.store = function(path, data, token)
				state.stores = state.stores + 1
				state.stored_path, state.stored_data, state.stored_token = path, data, token
			end
			run(reader, provider, state)
		end)
	end, debug.traceback)
	local removed, remove_error = os.remove(source)
	if not ok then error(detail, 0) end
	assert(removed, remove_error)
end

helpers.describe("shared Reader binds optional snapshots to publication receipts", function()
	helpers.it("parses the exact captured A bytes and stores the same token and result", function()
		with_reader(function(reader, provider, state)
			reader.set_cache_provider(provider)
			local data, committed = reader.parse(state.source)
			helpers.assert_true(committed)
			helpers.assert_eq(output(data), "CAPTURED", "the second file now contains FALLBACK instead")
			helpers.assert_eq(state.reads, 1)
			helpers.assert_eq(state.stores, 1)
			helpers.assert_true(state.stored_data == data)
			helpers.assert_true(state.stored_token == state.token)
			helpers.assert_eq(state.stored_path, state.source)
		end)
	end)

	helpers.it("preserves a legacy provider without a snapshot hook", function()
		with_reader(function(reader, provider, state)
			provider.read_snapshot = nil
			reader.set_cache_provider(provider)
			local data, committed = reader.parse(state.source)
			helpers.assert_true(committed)
			helpers.assert_eq(output(data), "FALLBACK")
			helpers.assert_eq(state.stores, 1)
			helpers.assert_true(state.stored_token == state.token)
		end)
	end)

	for _, mode in ipairs({ "nil", "false", "table", "raises" }) do
		helpers.it("a snapshot hook returning " .. mode .. " cannot authorize fallback publication", function()
			with_reader(function(reader, provider, state)
				provider.read_snapshot = function()
					state.reads = state.reads + 1
					if mode == "raises" then error("snapshot source refused") end
					if mode == "false" then return false end
					if mode == "table" then return {} end
					return nil
				end
				reader.set_cache_provider(provider)
				local data, committed = reader.parse(state.source)
				helpers.assert_true(committed, "fallback still reads and closes a real valid file")
				helpers.assert_eq(output(data), "FALLBACK")
				helpers.assert_eq(state.reads, 1)
				helpers.assert_eq(state.stores, 0, "fallback bytes have no attested snapshot token")
				if mode == "false" or mode == "table" then
					if mode == "false" then provider.read_snapshot = false else provider.read_snapshot = {} end
					local fallback, fallback_ok = reader.parse(state.source)
					helpers.assert_true(fallback_ok)
					helpers.assert_eq(output(fallback), "FALLBACK")
					helpers.assert_eq(state.stores, 0, "a non-function configured hook cannot borrow a legacy receipt")
				end
			end)
		end)
	end

	helpers.it("invalid captured syntax cannot borrow a later healthy file", function()
		with_reader(function(reader, provider, state)
			state.write('[[alpha]\n')
			reader.set_cache_provider(provider)
			local _, committed = reader.parse(state.source)
			helpers.assert_eq(committed, false, "the actual captured source was malformed")
			helpers.assert_eq(state.reads, 1)
			helpers.assert_eq(state.stores, 0)
		end)
	end)

	helpers.it("a missing capture receipt parses the file without invoking or publishing the hook", function()
		with_reader(function(reader, provider, state)
			provider.capture_source = function() state.write(B); return nil end
			reader.set_cache_provider(provider)
			local data, committed = reader.parse(state.source)
			helpers.assert_true(committed)
			helpers.assert_eq(output(data), "FALLBACK")
			helpers.assert_eq(state.reads, 0)
			helpers.assert_eq(state.stores, 0)
		end)
	end)
end)
