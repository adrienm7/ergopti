--- tests/fixtures/config_directory_target.lua

--- ==============================================================================
--- MODULE: Native Configuration Directory Target Probe
--- DESCRIPTION:
--- Exercises actual bootstrap storage and loading in a child with private XDG
--- directories. Only window visibility and reload are recording UI ports.
--- ==============================================================================

local driver, root, entry, mode = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
	.. driver .. "/../_shared/lua/?.lua;" .. driver .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local Shell, Json = require("adapters.shell_runner"), require("json")
local Paths, Writer = require("infra.config_paths"), require("toml_codec.writer")

--- Writes and closes the exact native fixture bytes.
--- @param path string Private destination.
--- @param bytes string Complete source.
local function write(path, bytes)
	local file = assert(io.open(path, "wb")); assert(file:write(bytes)); assert(file:close())
end

--- Reads the real durable locator, independently of the storage cache.
--- @return string bytes
local function locator()
	local file = assert(io.open(Paths.config_home() .. "/ergopti_plus/storage.json", "rb"))
	local bytes = assert(file:read("*a")); assert(file:close()); return bytes
end

local previous, existing = root .. "/previous config", root .. "/existing config"
assert(Shell.run("mkdir -p -- " .. Shell.quote(previous) .. " " .. Shell.quote(existing)))
write(previous .. "/config.toml", "[shortcuts]\nenabled = true\n")
write(existing .. "/config.toml", "[shortcuts]\nenabled = false\n")
write(root .. "/ordinary-file", "sentinel")
assert(Shell.run("ln -s -- " .. Shell.quote(existing) .. " " .. Shell.quote(root .. "/directory-link")))
assert(Shell.run("ln -s -- " .. Shell.quote(root .. "/missing referent") .. " " .. Shell.quote(root .. "/broken-link")))
assert(Paths.set_paths(previous, root .. "/previous logs"))
local old_bytes, old_logs = locator(), Paths.get_logs_dir()
local targets = {
	file = root .. "/ordinary-file", parent_file = root .. "/ordinary-file/child",
	broken_link = root .. "/broken-link", existing = existing,
	symlink = root .. "/directory-link", create = root .. "/new folder/child",
	default = "",
}
local target = assert(targets[mode])
local hides, reloads = 0, 0
local saved, hidden, reloaded
if entry == "single" then saved = Paths.set_config_dir(target)
elseif entry == "batch" then saved = Paths.set_paths(target, root .. "/new logs")
else
	local result = require("ui.paths_editor.bridge").on_message({ action = "save", configDir = target }, {
		webview_manager = { hide = function() hides = hides + 1; return true end },
		on_reload = function() reloads = reloads + 1; return true end,
	})
	saved, hidden, reloaded = result.saved, result.hidden, result.reloaded
end
local selected = Paths.get_config_dir()
local _, status = Writer.read_classified(Paths.config("config.toml"))
local sentinel = assert(io.open(root .. "/ordinary-file", "rb"))
local unchanged = sentinel:read("*a") == "sentinel"; assert(sentinel:close())
print("DIRECTORY_TARGET_RESULT " .. Json.encode({ saved = saved, hidden = hidden, reloaded = reloaded,
	hides = hides, reloads = reloads, previous_choice_preserved = selected == previous,
	store_bytes_preserved = old_bytes == locator(), logs_preserved = old_logs == Paths.get_logs_dir(),
	sentinel_preserved = unchanged, loader_status = status,
	directory_exists = Shell.run("test -d " .. Shell.quote(selected)),
	default_selected = selected == Paths.default_config_dir(),
}))
