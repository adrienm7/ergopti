--- tests/fixtures/core/native_hotstring_path_admission.lua
--- Isolated real FIFO admission, bounded by the invoking unit test.
local root, mode = assert(arg[1]), assert(arg[2])
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local driver = assert(source:match("^(.*)/tests/fixtures/core/native_hotstring_path_admission%.lua$"))
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. driver .. "/../_shared/?.lua;"
	.. driver .. "/../_shared/?/init.lua;" .. package.path
require("core.lifecycle.engine.compat.utf8").install()
local Paths = require("core.fs.engine.paths")
if mode == "index" then
	local shared = Paths.shared
	Paths.shared = function(path)
		if path == "hotstrings/data/catalogue/_index.toml" then return root .. "/index.toml" end
		return shared(path)
	end
end
local Config = require("hotstrings.engine.catalogue.config")
Config._set_override_config_dir_for_test(root)
Config._set_config_file_for_test(root .. "/choices.toml")
if mode == "index" then
	local ok = pcall(Config.language_packs)
	assert(not ok, "a FIFO index must be refused")
elseif mode == "default" then
	local ConfigPaths = require("settings.engine.paths")
	ConfigPaths.home = function() return root end
	assert(Config.init({}, nil) == false, "a FIFO directory must be refused")
elseif mode == "override" or mode == "denied" then
	assert(Config.init({}, root))
	local _, committed, reason = Config.load_all()
	assert(committed == false and reason == "source-unavailable",
		"an unreadable language override must not fall back to bundled data")
elseif mode == "retained" then
	local loads = 0
	assert(Config.init({ load_mappings = function() loads = loads + 1; return true end }, root))
	local Loader = require("hotstrings.engine.loader")
	Loader.load_catalogue = function() return { committed = true, errors = 0, mappings = {}, categories = {} } end
	local _, committed = Config.load_all()
	assert(committed and loads == 1, "healthy catalogue must be published first")
	local target = root .. "/french/autocorrection.toml"
	assert(require("core.process.adapters.shell_runner").run("mkfifo " .. require("core.process.adapters.shell_runner").quote(target)))
	local _, next_committed, reason = Config.load_all()
	assert(not next_committed and reason == "source-unavailable" and loads == 1,
		"refused override must preserve the active catalogue")
elseif mode == "missing" then
	assert(Config.init({}, root))
	local Loader = require("hotstrings.engine.loader")
	local observed = false
	Loader.load_catalogue = function(paths)
		for _, source in ipairs(paths) do
			if type(source) == "table" and source.category == "french_autocorrection" then
				assert(source.path ~= root .. "/french/autocorrection.toml")
				observed = true
			end
		end
		return { committed = false, errors = 1 }
	end
	local _, committed = Config.load_all()
	assert(observed and committed == false, "only an absent override selects the bundled source")
else error("unknown fixture mode") end
