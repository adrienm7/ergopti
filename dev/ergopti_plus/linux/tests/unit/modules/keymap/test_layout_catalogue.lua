--- tests/unit/modules/keymap/test_layout_catalogue.lua

--- ==============================================================================
--- MODULE: Layout Catalogue Decisions (shared, replayed on Linux)
--- DESCRIPTION:
--- The Linux layout manager takes its catalogue decisions from the module the
--- macOS driver shares (_shared/layouts/engine/composer/catalogue.lua). CI runs this suite
--- under LuaJIT, so replaying the shared vectors here proves the module loads
--- and decides the same way on the interpreter the daemon runs
--- (layout-catalogue).
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
local Catalogue = require("layouts.engine.composer.catalogue")

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

require("tests.lua.layouts.catalogue_local_contract")(helpers, Catalogue, Json,
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

helpers.describe("layout catalogue: a 304 the refresh did not ask for (catalogue-not-modified)", function()
	local settings = { url_template = "https://registry.test/{path}", owner = "o", repo = "r", branch = "b",
		folder = "f", index_file = "index.json", timeout_ms = 1000, max_file_bytes = vectors.max_bytes }

	--- Runs one refresh against scripted answers; returns the outcome and the headers sent.
	local function refresh(cache, answers)
		local sent, outcome = {}, nil
		Catalogue.refresh(settings, {
			read_cache = function() return cache end,
			write_cache = function() return true end,
			bundled_index = vectors.indexes.shipped,
			decode_json = Json.decode,
			transport = { get = function(_, headers, _, callback)
				sent[#sent + 1] = headers
				local answer = table.remove(answers, 1)
				callback(answer.status, answer.body, nil, { etag = answer.etag })
			end },
		}, function(result) outcome = result end)
		return outcome, sent
	end

	helpers.it("asks once more without a validator when no index is cached (catalogue-not-modified)", function()
		local outcome, sent = refresh(nil, {
			{ status = 304, body = "" },
			{ status = 200, body = Json.encode(vectors.indexes.fresh), etag = "\"v2\"" },
		})
		helpers.assert_eq(#sent, 2, "the unrequested 304 is asked again once")
		helpers.assert_eq(sent[2]["If-None-Match"], nil, "the second request carries no validator")
		helpers.assert_eq(outcome.source, Catalogue.SOURCE_NETWORK, "the published index is shown")
		helpers.assert_eq(index_name(outcome.index), "fresh")
	end)

	helpers.it("asks only once, then keeps the fallback, when the 304 repeats (catalogue-not-modified)", function()
		local outcome, sent = refresh(nil, { { status = 304, body = "" }, { status = 304, body = "" } })
		helpers.assert_eq(#sent, 2, "a second 304 is not asked again")
		helpers.assert_eq(outcome.source, Catalogue.SOURCE_BUNDLED)
		helpers.assert_eq(outcome.error and outcome.error.code, Catalogue.ERROR_NOT_MODIFIED_WITHOUT_CACHE)
	end)

	helpers.it("reuses the cached index on the 304 it asked for (catalogue-not-modified)", function()
		local outcome, sent = refresh({ text = Json.encode(vectors.indexes.cached), etag = "\"v1\"" },
			{ { status = 304, body = "" } })
		helpers.assert_eq(#sent, 1)
		helpers.assert_eq(sent[1]["If-None-Match"], "\"v1\"")
		helpers.assert_eq(outcome.source, Catalogue.SOURCE_CACHE)
		helpers.assert_eq(outcome.error, nil, "the cached copy is current: no error")
	end)
end)

require("tests.lua.layouts.installed_record_contract")(helpers, Catalogue, Json)

require("tests.lua.layouts.installed_update_contract")(helpers, Catalogue, Json)

require("tests.lua.layouts.installed_extension_contract")(helpers, Catalogue, Json)
