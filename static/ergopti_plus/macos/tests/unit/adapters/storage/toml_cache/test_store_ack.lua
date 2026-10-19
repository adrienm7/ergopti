--- tests/unit/adapters/storage/toml_cache/test_store_ack.lua

--- ==============================================================================
--- MODULE: TOML Cache Native Write Receipts
--- DESCRIPTION:
--- A protected native call may return nil plus an I/O error without throwing.
--- Snapshot success requires the exact file write receipt and a true close ACK.
--- These portable ports model Lua's returns; the healthy case uses real files.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reconstructs no filename policy: the native open port observes the actual path.
local function fixture(mode, callback)
	local previous_open, previous_hs, previous_lfs = io.open, rawget(_G, "hs"), rawget(_G, "lfs")
	local fs, root
	local ok, detail = xpcall(function()
		helpers.with_fresh_modules({ "adapters.toml_cache", "infra.logger", "lfs" }, function()
			rawset(_G, "lfs", nil)
			fs = require("lfs")
			root = os.tmpname()
			assert(os.remove(root))
			assert(fs.mkdir(root))
			local cache_dir = root .. "/cache"
			assert(fs.mkdir(cache_dir))
			local source = root .. "/source.toml"
			local source_file = assert(previous_open(source, "wb"))
			assert(source_file:write('value = "healthy"\n'))
			assert(source_file:close())
			_G.hs = { fs = { attributes = fs.attributes, mkdir = fs.mkdir } }
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local cache = require("adapters.toml_cache")
			cache.init(cache_dir)
			local identity = assert(cache.capture_source(source))
			local state = { writes = 0, closes = 0, source = source, before = cache.stats() }
			io.open = function(path, access)
				if access ~= "w" then return previous_open(path, access) end
				assert(path:sub(1, #cache_dir + 1) == cache_dir .. "/")
				state.snapshot = path
				local native = assert(previous_open(path, access))
				if mode == "healthy" then return native end
				local file = {}
				function file:write(body)
					state.writes = state.writes + 1
					if mode == "write raises" then error("snapshot write raised") end
					if mode == "write nil" then return nil, "snapshot write refused" end
					if mode == "write false" then return false, "snapshot write refused" end
					if mode == "write foreign ACK" then return true end
					assert(native:write(body))
					return self
				end
				function file:close()
					state.closes = state.closes + 1
					assert(state.closes == 1, "a consumed stream must not be closed again")
					-- Lua consumes the stream even when fclose reports a late failure.
					assert(native:close())
					if mode == "close raises" then error("snapshot close raised") end
					if mode == "close nil" then return nil, "snapshot close refused" end
					if mode == "close false" then return false, "snapshot close refused" end
					if mode == "close foreign ACK" then return "closed" end
					return true
				end
				return file
			end
			callback(cache, identity, state)
		end)
	end, debug.traceback)
	io.open, _G.hs = previous_open, previous_hs
	local cleaned, cleanup_error = pcall(function()
		if root then
			for name in fs.dir(root .. "/cache") do
				if name ~= "." and name ~= ".." then assert(os.remove(root .. "/cache/" .. name)) end
			end
			assert(fs.rmdir(root .. "/cache"))
			assert(os.remove(root .. "/source.toml"))
			assert(fs.rmdir(root))
		end
	end)
	rawset(_G, "lfs", previous_lfs)
	if not ok then error(detail, 0) end
	assert(cleaned, cleanup_error)
end

helpers.describe("TOML cache requires native write and close receipts", function()
	helpers.it("stores a real snapshot after both actual file operations succeed", function()
		fixture("healthy", function(cache, identity, state)
			local parsed = { value = "healthy" }
			helpers.assert_true(cache.store(state.source, parsed, identity))
			helpers.assert_eq(cache.stats().writes, 1)
			helpers.assert_true(helpers.deep_equal(cache.load(state.source), parsed))
		end)
	end)

	for _, mode in ipairs({ "write nil", "write false", "write foreign ACK", "write raises",
		"close nil", "close false", "close foreign ACK", "close raises" }) do
		helpers.it("refuses " .. mode .. " and attempts close exactly once", function()
			fixture(mode, function(cache, identity, state)
				helpers.assert_true(cache.store(state.source, { value = "healthy" }, identity) == false,
					"a protected call alone does not prove the snapshot committed")
				helpers.assert_eq(state.writes, 1)
				helpers.assert_eq(state.closes, 1, "write refusal must not bypass stream retirement")
				helpers.assert_true(helpers.deep_equal(cache.stats(), state.before),
					"refusal must leave every cache statistic unchanged")
			end)
		end)
	end
end)
