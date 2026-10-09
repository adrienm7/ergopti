--- tests/unit/modules/keymap/test_layout_catalogue.lua

--- ==============================================================================
--- MODULE: Layout Catalogue Decisions (shared, replayed on Linux)
--- DESCRIPTION:
--- The Linux layout manager takes its catalogue decisions from the module the
--- macOS driver shares (_shared/lua/layouts/catalogue.lua). CI runs this suite
--- under LuaJIT, so replaying the shared vectors here proves the module loads
--- and decides the same way on the interpreter the daemon runs
--- (layout-catalogue).
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Catalogue = require("layouts.catalogue")

local VECTORS_PATH = helpers.driver_root() .. "/../_shared/tests/corpus/layouts/catalogue_vectors.json"

--- Reads a whole file.
--- @param path string
--- @return string
local function read(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local vectors = Json.decode(read(VECTORS_PATH))

require("test.layout_catalogue_local_contract")(helpers, Catalogue, Json,
	{ max_file_bytes = vectors.max_bytes }, vectors.indexes.shipped)

--- An empty vector string stands for none.
--- @param value string
--- @return string|nil
local function none_if_empty(value)
	if value == "" then return nil end
	return value
end

--- The body a vector names.
--- @param name string
--- @return string
local function body_of(name)
	if vectors.indexes[name] then return Json.encode(vectors.indexes[name]) end
	if name == "not_json" then return "<html>proxy</html>" end
	if name == "no_layouts" then return '{"schema_version": 1}' end
	if name == "oversized" then return Json.encode(vectors.indexes.fresh) .. string.rep(" ", vectors.max_bytes) end
	return ""
end

--- Which named index a resolved index is (by its version).
--- @param index table|nil
--- @return string|nil
local function index_name(index)
	if index == nil then return nil end
	for name, candidate in pairs(vectors.indexes) do
		if candidate.layouts[1].version == index.layouts[1].version then return name end
	end
	return "unknown"
end

helpers.describe("layout catalogue (Linux): which index a refresh shows", function()
	helpers.it("replays every shared vector (layout-catalogue)", function()
		helpers.assert_true(#vectors.cases >= 10, "the shared vectors must cover every outcome")
		for _, case in ipairs(vectors.cases) do
			local outcome = Catalogue.resolve_index({
				status = case.response.status,
				body = body_of(case.response.body),
				headers = { etag = none_if_empty(case.response.etag) },
			}, case.cache and { index = vectors.indexes.cached, etag = none_if_empty(case.cached_etag) } or nil,
				case.shipped and vectors.indexes.shipped or nil, Json.decode, vectors.max_bytes)
			helpers.assert_eq(index_name(outcome.index), none_if_empty(case.expect.index), case.id .. ": index")
			helpers.assert_eq(outcome.source, case.expect.source, case.id .. ": source")
			helpers.assert_eq(outcome.store, case.expect.store, case.id .. ": store")
			helpers.assert_eq(outcome.etag, none_if_empty(case.expect.etag), case.id .. ": etag")
			helpers.assert_eq(outcome.error and outcome.error.code or nil, none_if_empty(case.expect.error),
				case.id .. ": error")
		end
	end)
end)

require("test.layout_installed_record_contract")(helpers, Catalogue, Json)

require("test.layout_installed_update_contract")(helpers, Catalogue, Json)

require("test.layout_installed_extension_contract")(helpers, Catalogue, Json)
