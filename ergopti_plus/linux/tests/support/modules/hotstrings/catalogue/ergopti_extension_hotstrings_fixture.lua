--- tests/support/modules/hotstrings/catalogue/ergopti_extension_hotstrings_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_ergopti_extension_hotstrings
--- DESCRIPTION:
--- Prelude shared by the test_ergopti_extension_hotstrings_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

local Paths      = require("infra.paths")

local Json       = require("json")

local Extension  = require("layouts.extension")

local Extensions = require("hotstrings.extensions")

--- The registry settings the drivers read, from the shared defaults.
--- @return table
local function registry_settings()
	local fh = assert(io.open(Paths.shared("modules/layouts/defaults.json"), "r"))
	local text = fh:read("*a")
	fh:close()
	return Json.decode(text).registry
end

--- Whether a file exists.
--- @param path string
--- @return boolean
local function exists(path)
	local fh = io.open(path, "r")
	if fh then fh:close() end
	return fh ~= nil
end

--- The shipped roots: bundled extensions, then the Ergopti extension when shipped.
--- @param with_ergopti boolean Whether the registry ships the Ergopti extension.
--- @return table
local function roots(with_ergopti)
	local out = { Paths.shared_root() .. "/../extensions" }
	if with_ergopti then
		local registry = Paths.shared_root() .. "/../../layouts/registry/"
		out[#out + 1] = Extension.shipped_root(registry, registry_settings(), exists)
	end
	return out
end

--- Discovers, routes and loads the shipped catalogue like load_all() does.
--- @param with_ergopti boolean
--- @return table catalogue
--- @return table found
local function load(with_ergopti)
	local Loader = helpers.load_module("modules.hotstrings.loader")
	local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
	local found = Extensions.scan(roots(with_ergopti), {
		list_dirs = Loader.list_subdirs, list_files = Loader.find_toml_files, read_file = Loader.read_file,
	})
	local paths, language_sources = {}, {}
	local root = Paths.shared("modules/hotstrings")
	local Languages = require("hotstrings.languages")
	for _, pack in ipairs(Config.language_packs()) do
		for _, stem in ipairs(pack.categories) do
			local path = root .. "/" .. pack.id .. "/" .. stem .. ".toml"
			language_sources[path] = { path = path, category = Languages.group_id(pack.id, stem) }
		end
	end
	for _, path in ipairs(Loader.find_toml_files(root)) do
		paths[#paths + 1] = language_sources[path] or path
	end
	local catalogue = Loader.load_catalogue(Config.route_bound_sources(paths, found))
	return catalogue, found
end

--- The mapping registered for a trigger in one category.
--- @param catalogue table
--- @param group string
--- @param trigger string
--- @return table|nil
local function mapping(catalogue, group, trigger)
	for _, m in ipairs(catalogue.mappings) do
		if m.group == group and m.trigger == trigger then return m end
	end
	return nil
end

--- The independent pre-move reference shared by all three native suites.
--- @return table
local function distance_reference()
	local text = assert(require("modules.hotstrings.loader").read_file(
		Paths.shared("tests/corpus/hotstrings/distance_reduction_entries.json")))
	return Json.decode(text)
end

--- Creates an empty temporary folder standing for the user's hotstrings folder.
--- @return string
local function user_folder()
	local dir = os.tmpname()
	os.remove(dir)
	assert(os.execute("mkdir '" .. dir .. "'"))
	return dir
end

--- Writes one file.
--- @param path string
--- @param text string
local function write(path, text)
	local fh = assert(io.open(path, "w"))
	fh:write(text)
	fh:close()
end

--- A one-section pack with one entry, as a user writes an override.
--- @param section string
--- @param trigger string
--- @param output string
--- @return string
local function one_entry_pack(section, trigger, output)
	return "[_meta]\nsections_order = [\"" .. section .. "\"]\n\n[[" .. section .. "]]\n\"" .. trigger
		.. "\" = { output = \"" .. output .. "\", is_word = false, auto_expand = true,"
		.. " is_case_sensitive = false, final_result = false }\n"
end

--- Loads the catalogue the way the daemon does, with `dir` as the user's folder.
--- @param dir string
--- @return table categories
local function load_with_user_folder(dir)
	local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
	-- The engine accepts the catalogue: the owner publishes a catalogue only
	-- once its engine has, so a silent stub would leave every category out.
	Config.init({ load_mappings = function() return true end }, dir)
	Config.load_all()
	return Config.get_categories()
end

--- Reaches actual shipped resolution while refusing accidental runtime dependencies.
--- @param body function Test receiving the real registry and observed native reads.
local function with_offline_shipped_probe(body)
	local updater_name, registry_name = "modules.updater.manager", "modules.keymap.layout_registry"
	local previous_updater, previous_preload = package.loaded[updater_name], package.preload[updater_name]
	local previous_registry = package.loaded[registry_name]
	local Http, FileSystem = require("adapters.http_client"), require("adapters.file_system")
	local previous_get, previous_read = Http.get, FileSystem.read
	local observed = { updater = 0, network = 0, reads = {} }
	package.loaded[updater_name] = nil
	package.preload[updater_name] = function()
		observed.updater = observed.updater + 1
		error("the offline shipped source must not initialize the updater")
	end
	Http.get = function()
		observed.network = observed.network + 1
		error("the offline shipped source must not fetch network data")
	end
	FileSystem.read = function(path)
		observed.reads[#observed.reads + 1] = path
		if observed.refuse and path == Paths.shared(observed.refuse) then return nil end
		return previous_read(path)
	end
	local ok, err = pcall(function()
		local Registry = helpers.load_module(registry_name)
		body(Registry, observed)
	end)
	Http.get, FileSystem.read = previous_get, previous_read
	package.loaded[updater_name], package.preload[updater_name] = previous_updater, previous_preload
	package.loaded[registry_name] = previous_registry
	if not ok then error(err, 0) end
end

--- Runs handwritten metadata through actual constructors and restores all ports.
--- @param configure function Receives the recording native ports and actual owner list.
--- @param body function Receives the fresh actual Loader.
local function with_exact_loader_ports(configure, body)
	local names = { "lfs", "luv", "modules.hotstrings.loader", "infra.curl_identity" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local Exact = require("infra.curl_identity")
	local original_new = Exact.new
	local Ports = require("tests.support.exact_identity_ports")
	local native, state = Ports.new({ planned_inode = "9223372036855917341" })
	local owners = {}
	Exact.new = function(...)
		local owner = original_new(...)
		owners[#owners + 1] = owner
		return owner
	end
	package.loaded.luv = native
	package.loaded.lfs = { attributes = function() return { mode = "file", dev = 11, ino = 100 } end }
	package.loaded["modules.hotstrings.loader"] = nil
	local ok, err = pcall(function()
		local Loader = require("modules.hotstrings.loader")
		configure(Loader, native, state, owners, Exact)
		body(Loader, native, state, owners)
	end)
	Exact.new = original_new
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

return {
	helpers = helpers,
	Paths = Paths,
	Json = Json,
	Extension = Extension,
	Extensions = Extensions,
	registry_settings = registry_settings,
	exists = exists,
	roots = roots,
	load = load,
	mapping = mapping,
	distance_reference = distance_reference,
	user_folder = user_folder,
	write = write,
	one_entry_pack = one_entry_pack,
	load_with_user_folder = load_with_user_folder,
	with_offline_shipped_probe = with_offline_shipped_probe,
	with_exact_loader_ports = with_exact_loader_ports,
}
