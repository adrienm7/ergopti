--- tests/unit/modules/keymap/test_layout_catalogue.lua

--- ==============================================================================
--- MODULE: Layout Catalogue Decisions (shared, replayed on macOS)
--- DESCRIPTION:
--- The layout manager shows the registry index after a conditional refresh,
--- keeps a record of the installed layouts and takes a layout's bytes from the
--- copy shipped with the app when that copy is the file the index describes
--- (layout-catalogue). These tests replay the shared vectors every driver
--- replays (_shared/tests/corpus/layouts/catalogue_vectors.json), then pin the
--- refresh's conditional request, the installed record's refusal of damaged
--- data (an entry it cannot use is left out alone), and the offline
--- installation of a shipped layout.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Catalogue = require("layouts.catalogue")
local Registry = require("layouts.registry")

local VECTORS_PATH = helpers.shared("tests/corpus/layouts/catalogue_vectors.json")
local REGISTRY_DIR = helpers.driver_root() .. "/../../layouts/registry/"

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

--- The body a vector names.
--- @param name string
--- @return string
local function body_of(name)
	if vectors.indexes[name] then return Json.encode(vectors.indexes[name]) end
	if name == "not_json" then return "<html>proxy</html>" end
	if name == "no_layouts" then return '{"schema_version": 1}' end
	if name == "oversized" then
		return Json.encode(vectors.indexes.fresh) .. string.rep(" ", vectors.max_bytes)
	end
	return ""
end

--- An empty vector string stands for none.
--- @param value string
--- @return string|nil
local function none_if_empty(value)
	if value == "" then return nil end
	return value
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

--- A settings table pointing at the real registry location.
--- @return table
local function settings()
	local LayoutRegistry = helpers.load_with_stubs("modules.keymap.layout_registry")
	return assert(LayoutRegistry.settings())
end

helpers.describe("layout catalogue: which index a refresh shows", function()
	helpers.it("replays every shared vector (layout-catalogue)", function()
		helpers.assert_true(#vectors.cases >= 10, "the shared vectors must cover every outcome")
		for _, case in ipairs(vectors.cases) do
			local response = {
				status = case.response.status,
				body = body_of(case.response.body),
				headers = { ETag = none_if_empty(case.response.etag) },
			}
			local cached = case.cache and { index = vectors.indexes.cached, etag = none_if_empty(case.cached_etag) } or nil
			local shipped = case.shipped and vectors.indexes.shipped or nil
			local outcome = Catalogue.resolve_index(response, cached, shipped, Json.decode, vectors.max_bytes)
			local expect = case.expect
			helpers.assert_eq(index_name(outcome.index), none_if_empty(expect.index), case.id .. ": index")
			helpers.assert_eq(outcome.source, expect.source, case.id .. ": source")
			helpers.assert_eq(outcome.store, expect.store, case.id .. ": store")
			helpers.assert_eq(outcome.etag, none_if_empty(expect.etag), case.id .. ": etag")
			local code = outcome.error and outcome.error.code or nil
			helpers.assert_eq(code, none_if_empty(expect.error), case.id .. ": error")
			if outcome.error then
				helpers.assert_type(outcome.error.detail, "string", case.id .. ": every error says why")
			end
			if outcome.store then
				helpers.assert_eq(outcome.text, response.body, case.id .. ": the stored text is the served text")
			end
		end
	end)

	helpers.it("sends the cached ETag and stores the fresh index with its own (layout-catalogue)", function()
		local requests, stored = {}, {}
		local outcome
		Catalogue.refresh(settings(), {
			read_cache = function() return { text = Json.encode(vectors.indexes.cached), etag = '"v1"' } end,
			write_cache = function(text, etag) stored[#stored + 1] = { text = text, etag = etag }; return true end,
			bundled_index = vectors.indexes.shipped,
			decode_json = Json.decode,
			transport = {
				get = function(url, headers, timeout_ms, callback)
					requests[#requests + 1] = { url = url, headers = headers, timeout_ms = timeout_ms }
					callback(200, Json.encode(vectors.indexes.fresh), nil, { etag = '"v2"' })
				end,
			},
		}, function(result) outcome = result end)
		helpers.assert_eq(#requests, 1)
		helpers.assert_contains(requests[1].url, "/static/layouts/registry/index.json")
		helpers.assert_eq(requests[1].headers["If-None-Match"], '"v1"')
		helpers.assert_eq(requests[1].timeout_ms, 30000)
		helpers.assert_eq(outcome.source, Catalogue.SOURCE_NETWORK)
		helpers.assert_eq(#stored, 1)
		helpers.assert_eq(stored[1].etag, '"v2"')
	end)

	helpers.it("sends no condition without a usable cache and reports a failed store (layout-catalogue)", function()
		local requests = {}
		local outcome
		Catalogue.refresh(settings(), {
			read_cache = function() return { text = "{ damaged", etag = '"v1"' } end,
			write_cache = function() return false, "disk full" end,
			bundled_index = nil,
			decode_json = Json.decode,
			transport = {
				get = function(url, headers, _, callback)
					requests[#requests + 1] = headers
					callback(200, Json.encode(vectors.indexes.fresh), nil, {})
				end,
			},
		}, function(result) outcome = result end)
		helpers.assert_nil(requests[1]["If-None-Match"], "a damaged cache must not make the server answer 304")
		helpers.assert_eq(outcome.source, Catalogue.SOURCE_NETWORK)
		helpers.assert_contains(outcome.cache_error, "disk full")
	end)

	helpers.it("says why a cached index was set aside (layout-catalogue-cache-report)", function()
		-- Offline, a damaged cache changes what the catalogue shows: the driver
		-- must be able to log why the last index it stored is not the one shown.
		local outcome
		Catalogue.refresh(settings(), {
			read_cache = function() return { text = "{ damaged", etag = '"v1"' } end,
			write_cache = function() error("nothing is stored offline") end,
			bundled_index = vectors.indexes.shipped,
			decode_json = Json.decode,
			transport = { get = function(_, _, _, callback) callback(0, "", "could not connect", nil) end },
		}, function(result) outcome = result end)
		helpers.assert_eq(outcome.source, Catalogue.SOURCE_BUNDLED)
		helpers.assert_contains(tostring(outcome.cache_warning), "not valid JSON")
		local clean
		Catalogue.refresh(settings(), {
			read_cache = function() return nil end,
			write_cache = function() error("nothing is stored offline") end,
			bundled_index = vectors.indexes.shipped,
			decode_json = Json.decode,
			transport = { get = function(_, _, _, callback) callback(0, "", "could not connect", nil) end },
		}, function(result) clean = result end)
		helpers.assert_nil(clean.cache_warning, "no cache is not a damaged cache")
	end)
end)

helpers.describe("layout catalogue: the installed-layouts record", function()
	helpers.it("reads a missing record as empty and round-trips entries (layout-catalogue)", function()
		local record = assert(Catalogue.decode_installed(nil, Json.decode))
		helpers.assert_eq(#Catalogue.installed_list(record), 0)
		local entry = vectors.indexes.fresh.layouts[1]
		record = Catalogue.with_installed(record, entry)
		local decoded = assert(Catalogue.decode_installed(Json.encode(record), Json.decode))
		helpers.assert_eq(Catalogue.installed_list(decoded)[1].sha256, entry.sha256)
		helpers.assert_eq(#Catalogue.installed_list(Catalogue.without_installed(decoded, "sample")), 0)
	end)

	helpers.it("refuses a damaged record instead of reading it as empty (layout-catalogue)", function()
		local cases = {
			"{ damaged",
			'{"schema_version": 2, "layouts": {}}',
			'{"schema_version": 1}',
		}
		for _, text in ipairs(cases) do
			local record, err = Catalogue.decode_installed(text, Json.decode)
			helpers.assert_nil(record, "accepted: " .. text)
			helpers.assert_type(err, "string")
		end
	end)

	helpers.it("leaves out an entry it cannot use, keeps the rest and never erases it (config-outdated-installed)", function()
		local entry = vectors.indexes.fresh.layouts[1]
		local layouts = {
			[entry.id] = entry,
			renamed = { id = "other", sha256 = "x", version = "1" },
			["../evil"] = { id = "../evil", sha256 = "x", version = "1" },
			ergopti_v1 = { id = "ergopti_v1", version = "1.0" },
		}
		local record, err = Catalogue.decode_installed(Json.encode({ schema_version = 1, layouts = layouts }),
			Json.decode)
		helpers.assert_nil(err, tostring(err))
		helpers.assert_eq(#Catalogue.installed_list(record), 1, "only the valid layout is installed")
		helpers.assert_eq(Catalogue.installed_list(record)[1].id, entry.id)
		for _, id in ipairs({ "renamed", "../evil", "ergopti_v1" }) do
			helpers.assert_type(record.outdated[id] and record.outdated[id].detail, "string", id .. " is reported")
		end
		local written = Json.decode(Json.encode(Catalogue.without_installed(record, entry.id)))
		helpers.assert_eq(written.layouts.ergopti_v1, layouts.ergopti_v1,
			"writing the record keeps what the user was told to fix")
		helpers.assert_nil(written.layouts[entry.id])
		local rewritten = Json.decode(Json.encode(Catalogue.with_installed(record, entry)))
		helpers.assert_eq(rewritten.layouts["../evil"], layouts["../evil"])
		helpers.assert_eq(rewritten.layouts[entry.id].sha256, entry.sha256)
	end)

	helpers.it("tells the Ergopti family apart (layout-catalogue)", function()
		local index = Json.decode(read(REGISTRY_DIR .. "index.json"))
		local family = settings().ergopti_family
		helpers.assert_eq(family, "ergopti")
		helpers.assert_true(Catalogue.is_ergopti(Registry.find_entry(index, "ergopti_plus"), family))
		helpers.assert_true(not Catalogue.is_ergopti(Registry.find_entry(index, "ergol"), family))
	end)
end)

helpers.describe("layout catalogue: where a layout's bytes come from", function()
	local index = Json.decode(read(REGISTRY_DIR .. "index.json"))
	local entry = Registry.find_entry(index, "ergopti")
	local text = read(REGISTRY_DIR .. "ergopti/ergopti.keylayout")

	--- Runs one acquisition and returns its terminal result.
	local function acquire(bundled, shipped_text, served)
		local reads, requests = {}, {}
		local bodies, digests = {}, {}
		for _, file in ipairs(entry.extension.files) do
			bodies[file.file] = read(REGISTRY_DIR .. file.file)
			digests[bodies[file.file]] = file.sha256
		end
		local result = { calls = 0 }
		Catalogue.acquire(settings(), entry, {
			bundled_index = bundled,
			read_bundled = function(rel)
				reads[#reads + 1] = rel
				if rel == entry.file then return shipped_text end
				return shipped_text and bodies[rel] or nil
			end,
			transport = {
				get = function(url, _, _, callback)
					requests[#requests + 1] = url
					if served then callback(200, served, nil, {}) else callback(0, "", "offline", nil) end
				end,
				sha256 = function(bytes, callback)
					callback(digests[bytes] or string.rep("0", 64), nil)
				end,
			},
		}, function(ok, detail)
			result.calls = result.calls + 1
			result.ok, result.detail = ok, detail
		end)
		helpers.assert_eq(result.calls, 1, "on_done must be called exactly once")
		return result, reads, requests
	end

	helpers.it("installs the shipped Ergopti offline (layout-catalogue)", function()
		local result, reads, requests = acquire(index, text, nil)
		helpers.assert_true(result.ok, tostring(result.detail))
		helpers.assert_eq(result.detail.source, Catalogue.SOURCE_BUNDLED)
		helpers.assert_true(result.detail.text == text)
		helpers.assert_eq(reads[1], "ergopti/ergopti.keylayout")
		helpers.assert_eq(#requests, 0, "no request when the shipped copy is the described file")
	end)

	helpers.it("downloads when the shipped copy is another version, and refuses a mismatch (layout-catalogue)", function()
		local other = Json.decode(Json.encode(index))
		Registry.find_entry(other, "ergopti").sha256 = string.rep("a", 64)
		local result, reads, requests = acquire(other, text, text)
		helpers.assert_true(result.ok, tostring(result.detail))
		helpers.assert_eq(result.detail.source, Catalogue.SOURCE_NETWORK)
		helpers.assert_eq(#reads, #entry.extension.files, "the extension verifies each independently versioned bundled file")
		helpers.assert_eq(#requests, 1)

		result = acquire(other, text, text .. " ")
		helpers.assert_true(result.ok == false)
		helpers.assert_contains(result.detail, "bytes instead of")
		result = acquire(other, text, text:gsub("Ergopti", "Ergoptj", 1))
		helpers.assert_contains(result.detail, "checksum")
		result = acquire(nil, nil, nil)
		helpers.assert_true(result.ok == false)
		helpers.assert_contains(result.detail, "offline")
	end)

	helpers.it("refuses a damaged shipped copy instead of installing it (layout-catalogue)", function()
		local result, _, requests = acquire(index, text:gsub("Ergopti", "Ergoptj", 1), nil)
		helpers.assert_true(result.ok == false)
		helpers.assert_contains(result.detail, "shipped copy is damaged")
		helpers.assert_eq(#requests, 0)
	end)
end)

require("test.layout_installed_record_contract")(helpers, Catalogue, Json)
