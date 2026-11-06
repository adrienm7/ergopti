--- ui/desktop_application_resolution_worker.lua

--- One-shot Gio desktop ID lookup. Each invocation owns a fresh XDG cache.
-- This entry point uses exact loadfile paths, not package.path templates, so
-- driver roots containing ';' or '?' retain their literal spelling.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = source:match("^(/.*)/ui/desktop_application_resolution_worker%.lua$")
if not root then os.exit(69) end
local loaded, runtime = pcall(function() return assert(loadfile(root .. "/_generated/native_runtime.lua"))() end)
if not loaded or type(runtime) ~= "table" or type(runtime.network_runtime) ~= "table"
	or type(runtime.network_runtime.libraries) ~= "table" then os.exit(69) end
local libs = runtime.network_runtime.libraries
local id = type(arg) == "table" and arg[1] or nil
if type(id) ~= "string" or id == "" or id:find("\0", 1, true) then os.exit(2) end
local ok, ffi = pcall(require, "ffi")
if not ok then os.exit(69) end
local declared = pcall(ffi.cdef, [[
	void *g_desktop_app_info_new(const char *desktop_id);
	const char *g_desktop_app_info_get_filename(void *info);
	void g_object_unref(void *object);
]])
if not declared then os.exit(69) end
local loaded_gio, gio = pcall(ffi.load, libs.gio)
local loaded_object, object = pcall(ffi.load, libs.gobject)
if not loaded_gio or not loaded_object then os.exit(69) end
-- gtk-launch keeps an explicit suffix and appends one otherwise.
local desktop_id = id:sub(-8) == ".desktop" and id or id .. ".desktop"
local opened, info = pcall(function() return gio.g_desktop_app_info_new(desktop_id) end)
if not opened or info == nil then os.exit(69) end
local read, filename = pcall(function()
	local value = gio.g_desktop_app_info_get_filename(info)
	return value ~= nil and ffi.string(value) or nil
end)
local released = pcall(function() object.g_object_unref(info) end)
if not read or not released or type(filename) ~= "string" or filename:find("[\r\n]") then os.exit(69) end
local written, accepted = pcall(io.write, filename, "\n")
local flushed, flushed_ok = pcall(io.flush)
if not written or not accepted or not flushed or flushed_ok ~= true then os.exit(74) end
