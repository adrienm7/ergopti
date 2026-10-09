--- static/ergopti_plus/linux/tests/unit/meta/test_corpus_keymap_layers.lua

--- ==============================================================================
--- MODULE: Layer-File Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/keymap_layers/vectors.json through the shared
--- Lua loader (_shared/lua/keymap/layers.lua) under the Linux runtime (LuaJIT in
--- CI), with the shared TOML codec and the shared JSON decoder the daemon reads
--- its data with. The JS gate, the macOS suite and the AHK suite replay the
--- same vectors, so every implementation of the layer-file schema answers every
--- file identically.
---
--- COVERAGE:
--- 1. Every vector: the sorted error signatures and the resolved layers equal
---    the hand-written expectation, and `ok` is exactly "no error".
--- 2. The user's layers.toml: an absent file is no layer, an unreadable one is
---    an error, never an empty layer.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local toml_codec = require("toml_codec")
local Layers = require("keymap.layers")

local shared_root = helpers.driver_root() .. "/../_shared"

-- Floor: a corpus that stopped being read would otherwise pass with nothing replayed.
local MIN_VECTORS = 25

--- Reads a whole file; raises when it cannot, so a moved corpus fails here.
--- @param path string Absolute path.
--- @return string content
local function read_file(path)
	local fh, err = io.open(path, "rb")
	if not fh then error("cannot open " .. path .. ": " .. tostring(err)) end
	local content = fh:read("*a")
	fh:close()
	return content
end

local corpus = json.decode(read_file(shared_root .. "/tests/corpus/keymap_layers/vectors.json"))
local ctx = Layers.load_context({
	shared_root = shared_root,
	json_decode = json.decode,
	toml_decode = toml_codec.decode,
	read_file = read_file,
})

--- @return table signatures The result's error signatures, sorted.
local function signatures(result)
	local out = {}
	for i, err in ipairs(result.errors) do out[i] = Layers.error_signature(err) end
	table.sort(out)
	return out
end

--- @return table layers layer id -> key code -> canonical resolution text.
local function formatted_layers(result)
	local out = {}
	for layer_id, bindings in pairs(result.layers) do
		out[layer_id] = {}
		for code, resolution in pairs(bindings) do out[layer_id][code] = Layers.format_resolution(resolution) end
	end
	return out
end

--- @return table sorted A sorted copy of a list of strings.
local function sorted_copy(list)
	local out = {}
	for i, v in ipairs(list) do out[i] = v end
	table.sort(out)
	return out
end

--- The text a vector hands the loader. _shared/lua/json.lua decodes a JSON null
--- inside an object to its own sentinel table, not to nil, and the JS gate lets
--- "toml" be only a string or null: anything else here is that null, the absent
--- file, which load() takes as nil.
--- @param v table One vector.
--- @return string|nil text
local function vector_text(v)
	if v.file then return read_file(shared_root .. "/keymap/" .. v.file) end
	if type(v.toml) == "string" then return v.toml end
	return nil
end





-- =======================================
-- =======================================
-- ======= 1/ Every vector replays =======
-- =======================================
-- =======================================

helpers.describe("keymap_layers corpus — replay through the shared Lua loader", function()
	helpers.it("the corpus holds enough vectors to mean something", function()
		helpers.assert_true(type(corpus) == "table" and type(corpus.vectors) == "table",
			"the corpus did not decode into a vectors list")
		helpers.assert_true(#corpus.vectors >= MIN_VECTORS,
			"only " .. #corpus.vectors .. " vectors (floor " .. MIN_VECTORS .. ")")
	end)

	helpers.it("at least one vector hands the loader an absent file", function()
		local absent = 0
		for _, v in ipairs(corpus.vectors) do
			if vector_text(v) == nil then absent = absent + 1 end
		end
		helpers.assert_true(absent >= 1, "no vector replays the absent layers.toml (nil)")
	end)

	for _, v in ipairs(corpus.vectors) do
		helpers.it("vector " .. v.id, function()
			local result = Layers.load(vector_text(v), v.os, ctx, toml_codec.decode)
			local actual_errors = signatures(result)
			helpers.assert_eq(actual_errors, sorted_copy(v.expected.errors), v.id .. ": errors")
			helpers.assert_eq(formatted_layers(result), v.expected.layers, v.id .. ": layers")
			helpers.assert_eq(result.ok, #actual_errors == 0, v.id .. ": ok is exactly 'no error'")
		end)
	end
end)





-- =========================================
-- =========================================
-- ======= 2/ The user's layers.toml =======
-- =========================================
-- =========================================

helpers.describe("keymap_layers — the user's layers.toml on Linux", function()
	local config_dir = "/home/someone/.config/ergopti_plus"

	helpers.it("an absent file is no layer and no error", function()
		local asked
		local result = Layers.load_user_file({
			config_dir = config_dir, os = "linux", ctx = ctx, toml_decode = toml_codec.decode,
			read_file = function(path) asked = path; return nil end,
		})
		helpers.assert_eq(asked, config_dir .. "/layers.toml")
		helpers.assert_true(result.ok, "an absent layers.toml must load cleanly")
		helpers.assert_eq(result.layers, {})
	end)

	helpers.it("an unreadable file is an error, not an empty layer", function()
		local result = Layers.load_user_file({
			config_dir = config_dir, os = "linux", ctx = ctx, toml_decode = toml_codec.decode,
			read_file = function() error("permission denied") end,
		})
		helpers.assert_eq(signatures(result), { "file_unreadable||||" })
		helpers.assert_true(result.ok == false, "an unreadable layers.toml must not report ok")
	end)

	helpers.it("a text that is neither a string nor nil raises instead of reading as no layer", function()
		helpers.assert_throws(function() Layers.load({}, "linux", ctx, toml_codec.decode) end)
	end)
end)
