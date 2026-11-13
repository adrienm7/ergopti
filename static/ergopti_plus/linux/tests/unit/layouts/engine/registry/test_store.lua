--- tests/unit/layouts/engine/registry/test_store.lua

--- ==============================================================================
--- MODULE: Layout Registry Store Tests (Linux)
--- DESCRIPTION:
--- Pins the shared store (_shared/layouts/engine/registry/store.lua) both layout
--- registry clients build: the installed record round trip, the shipped index
--- read once, the parent-folder step failing loudly, and a refresh whose
--- result arrives after the owner's lifetime ended being dropped without
--- writing the cache.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
local RegistryStore = require("layouts.engine.registry.store")

local function silent_logger()
	local seen = { warn = {}, error = {} }
	local logger = {}
	for _, level in ipairs({ "start", "success", "info", "debug" }) do logger[level] = function() end end
	logger.warn = function(_, fmt, ...) seen.warn[#seen.warn + 1] = string.format(fmt, ...) end
	logger.error = function(_, fmt, ...) seen.error[#seen.error + 1] = string.format(fmt, ...) end
	return logger, seen
end

local function new_store(prepare)
	local logger, seen = silent_logger()
	local store = RegistryStore.new({
		logger = logger, log = "test.store", shipped_noun = "package",
		prepare_parent = prepare or function() return true, nil end,
	})
	return store, seen
end

local SETTINGS = { index_file = "index.json", etag_file = "index.etag", installed_file = "installed.json",
	max_file_bytes = 1048576 }

local function deps_over(files)
	return {
		settings = SETTINGS, local_dir = "/cfg/", decode_json = Json.decode, encode_json = Json.encode,
		exists = function(path) return files[path] ~= nil end,
		read = function(path) return files[path] end,
		write = function(path, text) files[path] = text; return true, nil end,
		delete = function(path) files[path] = nil; return true end,
	}
end

helpers.describe("layout registry store (linux)", function()
	helpers.it("rejects a store built without its ports", function()
		local ok = pcall(RegistryStore.new, { log = "x" })
		helpers.assert_eq(ok, false)
	end)

	helpers.it("round-trips the installed record through the file", function()
		local store = new_store()
		local files = {}
		local deps = deps_over(files)
		local record = assert(store.read_installed(deps))
		helpers.assert_true(store.write_installed(deps, record))
		helpers.assert_true(files["/cfg/installed.json"] ~= nil)
		helpers.assert_true(store.read_installed(deps) ~= nil)
	end)

	helpers.it("refuses an unreadable installed record instead of treating it as empty", function()
		local store = new_store()
		local deps = deps_over({})
		deps.exists = function() return true end
		deps.read = function() return nil end
		local record, err = store.read_installed(deps)
		helpers.assert_eq(record, nil)
		helpers.assert_eq(err, "cannot read /cfg/installed.json")
	end)

	helpers.it("reports the parent-folder failure the platform step names", function()
		local store = new_store(function() return false, "no folder" end)
		local files = {}
		local ok, err = store.write_file(deps_over(files), "/cfg/a", "x")
		helpers.assert_eq(ok, false)
		helpers.assert_eq(err, "no folder")
		helpers.assert_eq(files["/cfg/a"], nil)
	end)

	helpers.it("reports a write failure with the path", function()
		local store = new_store()
		local deps = deps_over({})
		deps.write = function() return false, "disk full" end
		local ok, err = store.write_file(deps, "/cfg/a", "x")
		helpers.assert_eq(ok, false)
		helpers.assert_eq(err, "cannot write /cfg/a: disk full")
	end)

	helpers.it("reads the shipped index once outside a source checkout", function()
		local store = new_store()
		local reads = 0
		local deps = deps_over({})
		deps.bundled_dir = "/pkg/"
		deps.read = function() reads = reads + 1; return '{"schema_version":1,"layouts":[]}' end
		store.bundled_index(deps)
		store.bundled_index(deps)
		helpers.assert_eq(reads, 1)
		deps.local_source = true
		store.bundled_index(deps)
		helpers.assert_eq(reads, 2)
		store.reset()
		deps.local_source = false
		store.bundled_index(deps)
		helpers.assert_eq(reads, 3)
	end)

	-- The keyboard-layout menu asks for the index on every rebuild: decoding the
	-- unchanged file each time held most of its number-row rows (2026-10-31).
	helpers.it("(menu-rebuild-2026-10-31) decodes an unchanged shipped index once in a source checkout", function()
		local store = new_store()
		local text, decodes = '{"schema_version":1,"layouts":[]}', 0
		local deps = deps_over({})
		deps.bundled_dir, deps.local_source = "/pkg/", true
		deps.read = function() return text end
		deps.decode_json = function(raw) decodes = decodes + 1; return Json.decode(raw) end
		local first = store.bundled_index(deps)
		helpers.assert_true(type(first) == "table", "the shipped index must decode")
		helpers.assert_true(store.bundled_index(deps) == first, "identical bytes must reuse the decoded index")
		helpers.assert_eq(decodes, 1)
		text = '{"schema_version":1,"layouts":[] }'
		local edited = store.bundled_index(deps)
		helpers.assert_eq(decodes, 2)
		helpers.assert_true(edited ~= first, "a local edit must be decoded again")
		deps.settings = { index_file = "index.json", max_file_bytes = 4 }
		helpers.assert_eq(store.bundled_index(deps), nil)
		helpers.assert_eq(decodes, 2)
	end)

	helpers.it("warns about a missing shipped folder only when the port names a notice", function()
		local logger, seen = silent_logger()
		local store = RegistryStore.new({ logger = logger, log = "t", shipped_noun = "x",
			prepare_parent = function() return true end, missing_bundle_notice = "none shipped" })
		helpers.assert_eq(store.bundled_index(deps_over({})), nil)
		helpers.assert_eq(seen.warn[1], "none shipped")
		local silent, silent_seen = new_store()
		helpers.assert_eq(silent.bundled_index(deps_over({})), nil)
		helpers.assert_eq(#silent_seen.warn, 0)
	end)

	helpers.it("drops a refresh whose owner stopped, without touching the cache", function()
		local store = new_store()
		local files = {}
		local deps = deps_over(files)
		deps.settings = assert(require("layouts.engine.registry.registry").settings())
		deps.bundled_index = false
		deps.transport = { get = function(_, _, _, callback)
			callback(200, '{"schema_version":1,"layouts":[]}', nil, { etag = '"v1"' })
		end, sha256 = function(_, callback) callback("", nil) end }
		local done = 0
		store.refresh(deps, function() return false end, function() done = done + 1 end)
		helpers.assert_eq(done, 0)
		helpers.assert_eq(files["/cfg/index.json"], nil)
		helpers.assert_eq(store.catalogue().index, nil)
	end)
end)

require("tests.lua.layouts.catalogue_source_contract")(helpers, RegistryStore, require("layouts.engine.composer.catalogue"), Json,
	assert(require("layouts.engine.registry.registry").settings()))
